{ MCP.Events — the Events extension (io.modelcontextprotocol/events,
  #118, #126): event types a server declares, listed by events/list and
  read by poll delivery (events/poll) and push delivery (events/stream),
  on the 2026-07-28 revision. Verified 2026-11-27 against
  modelcontextprotocol/ext-events specification/beta/events/events.mdx
  at c77b843 (Beta; SEP-3415). A poll holds no state per client: it
  carries the event name, the arguments and the cursor, and the check
  the server author registers answers it. A push stream polls the same
  check on its own behalf, one occurrence per call, and holds its
  position only while it is open (MCP.Streams). Webhook delivery is not
  served, and neither is notifications/events/list_changed, which needs
  subscriptions/listen.

  The Events guide (docs/guides/events.md) shows a check that reads from
  an upstream with a position.
}

unit MCP.Events;

{$I MCP.inc}

interface

uses
  SysUtils,

  fpjson,
  MCP.Protocol,
  MCP.Schema,
  MCP.Server,
  MCP.Streams;

const
  MCP_EVENTS_EXTENSION = 'io.modelcontextprotocol/events';
  // nextPollMs when a registration names none: the specification's
  // example interval.
  MCP_EVENT_DEFAULT_POLL_MS = 30000;
  // A push stream's heartbeat interval (events.mdx, Lifecycle): 30
  // seconds unless the client suggests another, which is clamped to
  // these bounds.
  MCP_EVENT_DEFAULT_HEARTBEAT_MS = 30000;
  MCP_EVENT_MIN_HEARTBEAT_MS = 1000;
  MCP_EVENT_MAX_HEARTBEAT_MS = 300000;
  // The key every push notification carries the stream's request id
  // under, in params._meta (events.mdx, Event delivery).
  MCP_SUBSCRIPTION_ID_KEY = 'io.modelcontextprotocol/subscriptionId';

type
  // A poll as the check sees it. Arguments is borrowed for the call ({}
  // when the request has none) and checked against the input schema
  // when that schema lies in the subset the server enforces. FromNow is
  // true for a null or absent cursor: "start from now", so the check
  // returns no events and a fresh cursor. MaxAgeMs and MaxEvents are -1
  // when absent.
  TMCPEventQuery = record
    Arguments: TJSONObject;
    Cursor: string;
    FromNow: Boolean;
    MaxAgeMs: Int64;
    MaxEvents: Integer;
  end;

  // What a check found. Events (owned; nil for none) holds occurrences
  // built with MCPEventOccurrence, at most MaxEvents of them; Cursor is
  // the position after them, and NoReplay sends it as null for a type
  // without replay. NextPollMs 0 takes the registration's interval.
  // GapCursor, with Truncated and events, is the position delivery
  // resumed from, before them: a push stream sends it in its gap's
  // active notification ('' repeats the cursor the stream had, from
  // which resuming delivers the events again). Poll ignores it.
  TMCPEventPoll = record
    Events: TJSONArray;
    Cursor: string;
    NoReplay: Boolean;
    HasMore: Boolean;
    Truncated: Boolean;
    NextPollMs: Integer;
    GapCursor: string;
  end;

  TMCPEventCheck = function(const AQuery: TMCPEventQuery;
    const ACtx: TMCPRequestContext): TMCPEventPoll;
  TMCPEventCheckMethod = function(const AQuery: TMCPEventQuery;
    const ACtx: TMCPRequestContext): TMCPEventPoll of object;

// A poll result: the cursor after AEvents (owned; nil for none).
function MCPEventPoll(const ACursor: string;
  AEvents: TJSONArray = nil): TMCPEventPoll;

// One occurrence: AData (owned) is the payload, an object;
// ATimestamp when it happened (RFC 3339 with a time zone, as
// 2026-11-27T10:00:00Z); AEventId the upstream's stable id ('' lets the
// server derive one from the name, timestamp and data, so the same
// event polled twice keeps its id); AMeta (owned; nil for none) its
// _meta. The server adds the event's name.
function MCPEventOccurrence(const AEventId, ATimestamp: string;
  AData: TJSONObject; AMeta: TJSONObject = nil): TJSONObject;

// Registers event type AName, before the server starts, delivered by
// poll and push: AInputSchema (owned) describes the arguments, with root type
// object and x-mcp-header annotations as for tools; APayloadSchema
// (owned) describes each occurrence's data, which is checked when the
// schema lies in the subset the server enforces. The first call
// declares the extension and serves events/list, events/poll and
// events/stream; a classic-handshake client gets -32601, as the
// extension is defined for 2026-07-28. On Streamable HTTP, events/poll
// and events/stream carry Mcp-Name and the Mcp-Param-* headers. A duplicate or empty name, a bad schema or a
// nil check raises EMCPServer, as does a call after the server started.
procedure RegisterEvent(AServer: TMCPServer; const AName,
  ADescription: string; AInputSchema, APayloadSchema: TJSONObject;
  ACheck: TMCPEventCheck; ANextPollMs: Integer = MCP_EVENT_DEFAULT_POLL_MS);
  overload;
procedure RegisterEvent(AServer: TMCPServer; const AName,
  ADescription: string; AInputSchema, APayloadSchema: TJSONObject;
  ACheck: TMCPEventCheckMethod;
  ANextPollMs: Integer = MCP_EVENT_DEFAULT_POLL_MS); overload;
procedure RegisterEvent(AServer: TMCPServer; const AName,
  ADescription: string; constref AInputSchema, APayloadSchema: TMCPSchema;
  ACheck: TMCPEventCheck; ANextPollMs: Integer = MCP_EVENT_DEFAULT_POLL_MS);
  overload;

implementation

uses
  MCP.Crypto,
  MCP.Errors,
  MCP.Extensions,
  MCP.JSONRPC,
  MCP.Metadata,
  MCP.Pagination,
  MCP.RequestState;

type
  // A check's result that breaks the occurrence rules: the server's
  // mistake, told apart from an EMCPServer the check itself raises
  // (#126 review).
  EEventMistake = class(EMCPServer);

  TEventCatalog = class
  private
    FServer: TMCPServer; // borrowed: owns this catalog
    FTypes: array of record
      Name, Description: string;
      InputSchema, PayloadSchema: TJSONObject; // owned
      CheckArguments, CheckPayload: Boolean;
      Headers: TMCPHeaderParameters;
      Check: TMCPEventCheck;
      CheckMethod: TMCPEventCheckMethod;
      NextPollMs: Integer;
    end;
    function FindType(const AName: string): Integer;
    function List(AParams: TJSONObject; const ACtx: TMCPRequestContext;
      ALegacy: Boolean): TJSONObject;
    function Poll(AParams: TJSONObject; const ACtx: TMCPRequestContext;
      ALegacy: Boolean): TJSONObject;
    function Stream(AParams: TJSONObject; const ACtx: TMCPRequestContext;
      ALegacy: Boolean): TJSONObject;
    function HeaderParameters(const AName: string): TMCPHeaderParameters;
    function PollResult(AType: Integer; const AQuery: TMCPEventQuery;
      var APoll: TMCPEventPoll): TJSONObject;
    procedure ReadSubscription(AParams: TJSONObject; out AIndex: Integer;
      out AQuery: TMCPEventQuery; out AOwned: TJSONObject);
    function CheckPage(AType: Integer; const AQuery: TMCPEventQuery;
      const ACtx: TMCPRequestContext; out ACursor, AGap: string;
      out ANoReplay: Boolean): TJSONObject;
  public
    constructor Create(AServer: TMCPServer);
    destructor Destroy; override;
    procedure Add(const AName, ADescription: string; AInputSchema,
      APayloadSchema: TJSONObject; ACheck: TMCPEventCheck;
      ACheckMethod: TMCPEventCheckMethod; ANextPollMs: Integer);
  end;

  // One push subscription (events/stream, #126): the type's check
  // polled on the stream's behalf, one occurrence per call.
  TEventStream = class(TMCPStream)
  private
    FCatalog: TEventCatalog; // borrowed
    FType: Integer;
    FArguments: TJSONObject; // owned
    // The stream's position: what the check gave last, which a type
    // without replay keeps off the wire (FNull).
    FCursor: string;
    FNull: Boolean;
    FHeartbeatMs: Int64;
    FPending: TJSONObject; // owned: the first page, sent by the first Step
    FPendingCursor, FPendingGap: string;
    FPendingNoReplay: Boolean;
    FNextCheck, FLastWrite: Int64;
    // The check's last nextPollMs, also the retry after a failure.
    FInterval: Int64;
    // The client's maxAgeMs, passed on while the first backlog drains.
    FMaxAgeMs: Int64;
    FCatchingUp: Boolean;
    FProtocolVersion, FClientName, FClientVersion, FLogLevel: string;
    FCapabilities, FMeta: TJSONObject; // owned copies of the request's
    function IsCancelled: Boolean;
    function Context: TMCPRequestContext;
    function WireCursor: TJSONData;
    procedure Send(const AMethod: string; AParams: TJSONObject;
      ASink: TMCPLineSink; ASinkData: Pointer);
    procedure Terminate(ACode: Integer; const AMessage: string;
      AData: TJSONData; ASink: TMCPLineSink; ASinkData: Pointer);
    procedure SendPage(APage: TJSONObject; const AAfter, AGap: string;
      ANoReplay, AFirst: Boolean; ASink: TMCPLineSink; ASinkData: Pointer);
    procedure CheckAgain(ASink: TMCPLineSink; ASinkData: Pointer);
    procedure LogStreamFailure(E: Exception);
  public
    // APage (owned) is the first check's result, AAfter and AGap its
    // cursor and GapCursor.
    constructor Create(ACatalog: TEventCatalog; AType: Integer;
      const AQuery: TMCPEventQuery; const AAfter, AGap: string;
      ANoReplay: Boolean; AHeartbeatMs: Int64; APage: TJSONObject;
      const ACtx: TMCPRequestContext);
    destructor Destroy; override;
    function Step(ASink: TMCPLineSink; ASinkData: Pointer): Int64; override;
    procedure Close(ASink: TMCPLineSink; ASinkData: Pointer); override;
  end;

function MCPEventPoll(const ACursor: string; AEvents: TJSONArray): TMCPEventPoll;
begin
  Result := Default(TMCPEventPoll);
  Result.Cursor := ACursor;
  Result.Events := AEvents;
end;

function MCPEventOccurrence(const AEventId, ATimestamp: string;
  AData: TJSONObject; AMeta: TJSONObject): TJSONObject;
begin
  Result := TJSONObject.Create;
  if AEventId <> '' then
    Result.Add('eventId', AEventId);
  Result.Add('timestamp', ATimestamp);
  if AData = nil then
    AData := TJSONObject.Create;
  Result.Add('data', AData);
  if AMeta <> nil then
    Result.Add('_meta', AMeta);
end;

constructor TEventCatalog.Create(AServer: TMCPServer);
begin
  inherited Create;
  FServer := AServer;
end;

destructor TEventCatalog.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FTypes) do
  begin
    FTypes[I].InputSchema.Free;
    FTypes[I].PayloadSchema.Free;
  end;
  inherited Destroy;
end;

function TEventCatalog.FindType(const AName: string): Integer;
begin
  for Result := 0 to High(FTypes) do
    if FTypes[Result].Name = AName then
      Exit;
  Result := -1;
end;

// An independent copy (#118 review): dynamic arrays are shared by
// assignment, and the cached parameters must stay as registered.
function TEventCatalog.HeaderParameters(
  const AName: string): TMCPHeaderParameters;
var
  Index: Integer;
begin
  Result := nil;
  Index := FindType(AName);
  if Index < 0 then
    Exit;
  Result := CopyHeaderParameters(FTypes[Index].Headers);
end;

procedure TEventCatalog.Add(const AName, ADescription: string;
  AInputSchema, APayloadSchema: TJSONObject; ACheck: TMCPEventCheck;
  ACheckMethod: TMCPEventCheckMethod; ANextPollMs: Integer);
var
  Slot: Integer;
  Headers: TMCPHeaderParameters;
  Problem: string;
  RootType: TJSONData;
  Swap: TJSONObject;
begin
  try
    if AName = '' then
      raise EMCPServer.Create('An event type needs a name');
    if FindType(AName) >= 0 then
      raise EMCPServer.CreateFmt('Event type "%s" is already registered',
        [AName]);
    if not Assigned(ACheck) and not Assigned(ACheckMethod) then
      raise EMCPServer.CreateFmt('Event type "%s" needs a check', [AName]);
    if (AInputSchema = nil) or (APayloadSchema = nil) then
      raise EMCPServer.CreateFmt('Event type "%s" needs an input and a ' +
        'payload schema', [AName]);
    if ANextPollMs < 0 then
      raise EMCPServer.CreateFmt('Event type "%s": nextPollMs must not be ' +
        'negative', [AName]);
    // Children stored as nil are nulls, and the clones rebuild fpjson's
    // name lookup, which (FPC 3.2.2) misses a member stored as nil even
    // after Items[] replaces it, so every check below sees what goes
    // out (#118 review).
    NilChildrenToNull(AInputSchema);
    NilChildrenToNull(APayloadSchema);
    Swap := TJSONObject(AInputSchema.Clone);
    AInputSchema.Free;
    AInputSchema := Swap;
    Swap := TJSONObject(APayloadSchema.Clone);
    APayloadSchema.Free;
    APayloadSchema := Swap;
    // inputSchema "mirrors the inputSchema/arguments pairing on tools"
    // (events.mdx, Listing Available Events): an object root, and
    // x-mcp-header annotations a client accepts. Read after the clone,
    // whose lookup sees every member (#118 review).
    RootType := AInputSchema.Find('type');
    if (RootType = nil) or (RootType.JSONType <> jtString) or
      (RootType.AsString <> 'object') then
      raise EMCPServer.CreateFmt('Event type "%s" inputSchema must have ' +
        'root type "object"', [AName]);
    // Arguments are checked as for tools: an input schema outside the
    // subset the server enforces is refused, not left unchecked.
    Problem := MCPSchemaSubsetViolation(AInputSchema, True);
    if Problem <> '' then
      raise EMCPServer.CreateFmt('Event type "%s" inputSchema %s, outside ' +
        'the subset the server checks arguments against', [AName, Problem]);
    Problem := MCPHeaderParameters(AInputSchema, Headers);
    if Problem <> '' then
      raise EMCPServer.CreateFmt('Event type "%s" inputSchema: %s',
        [AName, Problem]);
  except
    AInputSchema.Free;
    APayloadSchema.Free;
    raise;
  end;
  Slot := Length(FTypes);
  SetLength(FTypes, Slot + 1);
  FTypes[Slot].Name := AName;
  FTypes[Slot].Description := ADescription;
  FTypes[Slot].InputSchema := AInputSchema;
  FTypes[Slot].PayloadSchema := APayloadSchema;
  FTypes[Slot].CheckArguments := True;
  FTypes[Slot].CheckPayload := MCPSchemaSubsetViolation(APayloadSchema,
    False) = '';
  FTypes[Slot].Headers := Headers;
  FTypes[Slot].Check := ACheck;
  FTypes[Slot].CheckMethod := ACheckMethod;
  FTypes[Slot].NextPollMs := ANextPollMs;
end;

// The extension is defined for 2026-07-28 and later (events.mdx,
// Introduction), so a classic client gets the fallback answer: "a
// server that does not offer it answers any events/* request with
// -32601".
procedure RefuseLegacy(ALegacy: Boolean; const AMethod: string);
begin
  if ALegacy then
    raise EMCPProtocolError.Create(JSONRPC_METHOD_NOT_FOUND,
      'Method not found: ' + AMethod);
end;

function InvalidParams(const AWhat: string): EMCPProtocolError;
begin
  Result := EMCPProtocolError.Create(JSONRPC_INVALID_PARAMS,
    'Invalid params: ' + AWhat);
end;

// events/list (events.mdx, Listing Available Events): every type with
// its delivery modes and schemas, paged as tools/list is.
function TEventCatalog.List(AParams: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
var
  Events: TJSONArray;
  Cursor: TJSONData;
  First, Last, I: Integer;
begin
  RefuseLegacy(ALegacy, 'events/list');
  Cursor := nil;
  if AParams <> nil then
    Cursor := AParams.Find('cursor');
  if not PageBounds(Cursor, 'events/list', Length(FTypes), FServer.PageSize,
    First, Last) then
    raise InvalidParams('unknown cursor');
  Result := TJSONObject.Create;
  try
    Events := TJSONArray.Create;
    Result.Add('events', Events);
    for I := First to Last do
      Events.Add(TJSONObject.Create(['name', FTypes[I].Name, 'description',
        FTypes[I].Description, 'delivery', TJSONArray.Create(['poll',
        'push']),
        'inputSchema', FTypes[I].InputSchema.Clone, 'payloadSchema',
        FTypes[I].PayloadSchema.Clone]));
    if Last < High(FTypes) then
      Result.Add('nextCursor', ListCursor('events/list', Last + 1));
  except
    Result.Free;
    raise;
  end;
end;

// An integer member AName of AParams of at least AMin, or -1 when
// absent: read as the schema validator reads integers, so 1e3 is 1000
// and a fraction is refused (#118 review).
function OptionalCount(AParams: TJSONObject; const AName: string;
  AMin: Int64): Int64;
var
  Value: TJSONData;
begin
  Result := -1;
  Value := AParams.Find(AName);
  if Value = nil then
    Exit;
  if not ReadSignedInteger(Value, Result) or (Result < AMin) then
    raise InvalidParams(Format('%s must be an integer of at least %d',
      [AName, AMin]));
end;

// A derived eventId: the same name, timestamp and data give the same
// id, so a client deduplicates an event polled twice; the data in its
// canonical form (sorted members), so member order does not matter.
function DerivedEventId(const AName, ATimestamp: string;
  AData: TJSONData): string;
var
  Digest: TSHA256Digest;
  I: Integer;
  Canonical: UTF8String;
  Bytes: string;
begin
  // The canonical bytes as they are, no code page conversion.
  Canonical := CanonicalJSON(AData);
  SetLength(Bytes, Length(Canonical));
  if Length(Bytes) > 0 then
    Move(Canonical[1], Bytes[1], Length(Bytes));
  Digest := SHA256(AName + #0 + ATimestamp + #0 + Bytes);
  Result := 'evt_';
  for I := 0 to 15 do
    Result := Result + LowerCase(IntToHex(Digest[I], 2));
end;

// The poll result, the check's occurrences checked and completed
// (events.mdx, Event Occurrences): a mistake in them is the server's,
// answered -32603, not sent.
function TEventCatalog.PollResult(AType: Integer; const AQuery: TMCPEventQuery;
  var APoll: TMCPEventPoll): TJSONObject;
var
  I: Integer;
  Occurrence, Data, Timestamp, Field: TJSONData;
  Violation: string;
  Rebuilt: TJSONArray;
begin
  if APoll.Events = nil then
    APoll.Events := TJSONArray.Create;
  // Children stored as nil are nulls, checked and hashed as such, on a
  // clone whose name lookup sees them (#118 review).
  NilChildrenToNull(APoll.Events);
  Rebuilt := TJSONArray(APoll.Events.Clone);
  APoll.Events.Free;
  APoll.Events := Rebuilt;
  if AQuery.FromNow and (APoll.Events.Count > 0) then
    raise EEventMistake.CreateFmt('Event type "%s" returned events for a poll ' +
      'from now', [FTypes[AType].Name]);
  if (AQuery.MaxEvents >= 0) and (APoll.Events.Count > AQuery.MaxEvents) then
    raise EEventMistake.CreateFmt('Event type "%s" returned more than ' +
      'maxEvents events', [FTypes[AType].Name]);
  for I := 0 to APoll.Events.Count - 1 do
  begin
    Occurrence := APoll.Events.Items[I];
    if (Occurrence = nil) or (Occurrence.JSONType <> jtObject) then
      raise EEventMistake.CreateFmt('Event type "%s" returned an occurrence ' +
        'that is no object', [FTypes[AType].Name]);
    Data := TJSONObject(Occurrence).Find('data');
    Timestamp := TJSONObject(Occurrence).Find('timestamp');
    // An eventId is a string, _meta an object, and a poll's cursor is
    // the result's alone (events.mdx, Event Occurrences).
    Field := TJSONObject(Occurrence).Find('eventId');
    if ((Field <> nil) and (Field.JSONType <> jtString)) or
      (TJSONObject(Occurrence).IndexOfName('cursor') >= 0) then
      raise EEventMistake.CreateFmt('Event type "%s" returned an occurrence ' +
        'with a bad eventId or a cursor of its own', [FTypes[AType].Name]);
    Field := TJSONObject(Occurrence).Find('_meta');
    if (Field <> nil) and (Field.JSONType <> jtObject) then
      raise EEventMistake.CreateFmt('Event type "%s" returned an occurrence ' +
        'whose _meta is no object', [FTypes[AType].Name]);
    if (Data = nil) or (Data.JSONType <> jtObject) or (Timestamp = nil) or
      (Timestamp.JSONType <> jtString) or
      not ValidTimestamp(Timestamp.AsString) then
      raise EEventMistake.CreateFmt('Event type "%s" returned an occurrence ' +
        'without an object data or an RFC 3339 timestamp',
        [FTypes[AType].Name]);
    if FTypes[AType].CheckPayload and not MCPValidateAgainstSchema(
      FTypes[AType].PayloadSchema, Data, 'payload', False, Violation) then
      raise EEventMistake.CreateFmt('Event type "%s" returned data that does ' +
        'not match its payloadSchema: %s', [FTypes[AType].Name, Violation]);
    TJSONObject(Occurrence).Delete('name');
    TJSONObject(Occurrence).Add('name', FTypes[AType].Name);
    if TJSONObject(Occurrence).Find('eventId') = nil then
      TJSONObject(Occurrence).Add('eventId', DerivedEventId(
        FTypes[AType].Name, Timestamp.AsString, Data));
  end;
  Result := TJSONObject.Create;
  Result.Add('events', APoll.Events);
  APoll.Events := nil;
  if APoll.NoReplay then
    Result.Add('cursor', TJSONNull.Create)
  else
    Result.Add('cursor', APoll.Cursor);
  Result.Add('truncated', APoll.Truncated and not APoll.NoReplay);
  Result.Add('hasMore', APoll.HasMore);
  if APoll.NextPollMs > 0 then
    Result.Add('nextPollMs', APoll.NextPollMs)
  else
    Result.Add('nextPollMs', FTypes[AType].NextPollMs);
end;

// The subscription a poll or a stream names (events.mdx, Poll-Based
// Delivery): the type's index, the query without maxEvents, and the
// arguments the server made for an absent member (AOwned, the caller's;
// nil when the request has them). -32023 for an unknown name, -32602
// for bad parameters or arguments that do not match the input schema.
procedure TEventCatalog.ReadSubscription(AParams: TJSONObject;
  out AIndex: Integer; out AQuery: TMCPEventQuery; out AOwned: TJSONObject);
var
  NameData, CursorData, ArgumentsData: TJSONData;
  Violation: string;
begin
  AOwned := nil;
  if AParams = nil then
    raise InvalidParams('params are required');
  NameData := AParams.Find('name');
  if (NameData = nil) or (NameData.JSONType <> jtString) then
    raise InvalidParams('name must be a string');
  AIndex := FindType(NameData.AsString);
  if AIndex < 0 then
    raise EMCPProtocolError.Create(MCP_ERROR_NOT_FOUND, 'Event type not ' +
      'found', TJSONObject.Create(['kind', 'event']));
  AQuery := Default(TMCPEventQuery);
  AQuery.MaxEvents := -1;
  // An absent cursor is a null one (events.mdx, Cursor Lifecycle).
  CursorData := AParams.Find('cursor');
  AQuery.FromNow := (CursorData = nil) or (CursorData.JSONType = jtNull);
  if not AQuery.FromNow then
  begin
    if CursorData.JSONType <> jtString then
      raise InvalidParams('cursor must be a string or null');
    AQuery.Cursor := CursorData.AsString;
  end;
  // maxAgeMs is ignored for a poll from now.
  AQuery.MaxAgeMs := OptionalCount(AParams, 'maxAgeMs', 0);
  ArgumentsData := AParams.Find('arguments');
  if ArgumentsData = nil then
  begin
    AOwned := TJSONObject.Create;
    ArgumentsData := AOwned;
  end
  else if ArgumentsData.JSONType <> jtObject then
    raise InvalidParams('arguments must be an object');
  try
    if FTypes[AIndex].CheckArguments and not MCPValidateAgainstSchema(
      FTypes[AIndex].InputSchema, ArgumentsData, 'argument', True,
      Violation) then
      raise InvalidParams(Violation);
  except
    FreeAndNil(AOwned);
    raise;
  end;
  AQuery.Arguments := TJSONObject(ArgumentsData);
end;

// One call of type AType's check, its result checked and completed as
// a poll result (PollResult). ACursor is the position the check gave,
// which a type without replay keeps off the wire, and ANoReplay says so;
// AGap its GapCursor.
function TEventCatalog.CheckPage(AType: Integer; const AQuery: TMCPEventQuery;
  const ACtx: TMCPRequestContext; out ACursor, AGap: string;
  out ANoReplay: Boolean): TJSONObject;
var
  Poll: TMCPEventPoll;
begin
  if Assigned(FTypes[AType].CheckMethod) then
    Poll := FTypes[AType].CheckMethod(AQuery, ACtx)
  else
    Poll := FTypes[AType].Check(AQuery, ACtx);
  try
    Result := PollResult(AType, AQuery, Poll);
  finally
    Poll.Events.Free;
  end;
  ACursor := Poll.Cursor;
  AGap := Poll.GapCursor;
  ANoReplay := Poll.NoReplay;
end;

// events/poll (events.mdx, Poll-Based Delivery): one subscription per
// request, no state held.
function TEventCatalog.Poll(AParams: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
var
  Index: Integer;
  Query: TMCPEventQuery;
  Owned: TJSONObject;
  Count: Int64;
  Cursor, Gap: string;
  NoReplay: Boolean;
begin
  RefuseLegacy(ALegacy, 'events/poll');
  ReadSubscription(AParams, Index, Query, Owned);
  try
    // A cap of zero could never move a cursor on: at least one (#118
    // review).
    Count := OptionalCount(AParams, 'maxEvents', 1);
    if Count > MaxInt then
      Count := MaxInt;
    Query.MaxEvents := Count;
    Result := CheckPage(Index, Query, ACtx, Cursor, Gap, NoReplay);
  finally
    Owned.Free;
  end;
  // A null cursor starts from now, so on the wire it cannot lead to the
  // next page that hasMore promises (events.mdx, Poll-Based Delivery);
  // a push stream keeps the position itself.
  if NoReplay and Result.Get('hasMore', False) then
  begin
    Result.Free;
    raise EEventMistake.CreateFmt('Event type "%s" returned hasMore ' +
      'without replay', [FTypes[Index].Name]);
  end;
end;

// events/stream (events.mdx, Push-Based Delivery, #126): the request
// is checked and the check called once here, so an invalid subscription
// is the immediate JSON-RPC error; then the stream is parked for the
// transport, which drops this placeholder result. A transport that
// cannot stream gets -32026.
function TEventCatalog.Stream(AParams: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
var
  Index: Integer;
  Query: TMCPEventQuery;
  Owned, Page: TJSONObject;
  Heartbeat: Int64;
  Cursor, Gap: string;
  NoReplay: Boolean;
  Quiet: TMCPRequestContext;
begin
  RefuseLegacy(ALegacy, 'events/stream');
  ReadSubscription(AParams, Index, Query, Owned);
  try
    Heartbeat := OptionalCount(AParams, 'heartbeatMs', 0);
    if not (ACtx.StreamHost is TMCPStreamHost) then
      raise EMCPProtocolError.Create(MCP_ERROR_UNSUPPORTED, 'Unsupported',
        TJSONObject.Create(['feature', 'deliveryMode', 'value', 'push']));
    // One occurrence per call, so each event carries the exact cursor
    // after it. The check's progress or log notifications would open
    // the transport's response before the stream does: it runs without
    // a notifier, as the later checks do (#126 review).
    Query.MaxEvents := 1;
    Quiet := ACtx;
    Quiet.Notifier := nil;
    Page := CheckPage(Index, Query, Quiet, Cursor, Gap, NoReplay);
    // A cancellation the check saw: no stream, and the core sends
    // nothing for the request.
    if ACtx.IsCancelled then
      Page.Free
    else
      TMCPStreamHost(ACtx.StreamHost).Park(TEventStream.Create(Self, Index,
        Query, Cursor, Gap, NoReplay, Heartbeat, Page, ACtx));
  finally
    Owned.Free;
  end;
  Result := TJSONObject.Create;
end;

{ TEventStream }

constructor TEventStream.Create(ACatalog: TEventCatalog; AType: Integer;
  const AQuery: TMCPEventQuery; const AAfter, AGap: string;
  ANoReplay: Boolean; AHeartbeatMs: Int64; APage: TJSONObject;
  const ACtx: TMCPRequestContext);
begin
  // Own the page first: an exception in a constructor runs the
  // destructor, which frees what is owned.
  FPending := APage;
  inherited Create(ACtx.RequestId);
  FCatalog := ACatalog;
  FType := AType;
  FArguments := TJSONObject(AQuery.Arguments.Clone);
  // The client's own position, which the first active notification
  // repeats when no gap occurred; then the check's.
  FCursor := AQuery.Cursor;
  FNull := AQuery.FromNow;
  FPendingCursor := AAfter;
  FPendingGap := AGap;
  FPendingNoReplay := ANoReplay;
  FInterval := ACatalog.FTypes[AType].NextPollMs;
  // The replay floor holds while the backlog drains (#126 review).
  FMaxAgeMs := AQuery.MaxAgeMs;
  FCatchingUp := True;
  // The grant: 30 seconds unless the client suggests another, clamped
  // to 1 second .. 5 minutes (events.mdx, Lifecycle).
  if AHeartbeatMs < 0 then
    FHeartbeatMs := MCP_EVENT_DEFAULT_HEARTBEAT_MS
  else if AHeartbeatMs < MCP_EVENT_MIN_HEARTBEAT_MS then
    FHeartbeatMs := MCP_EVENT_MIN_HEARTBEAT_MS
  else if AHeartbeatMs > MCP_EVENT_MAX_HEARTBEAT_MS then
    FHeartbeatMs := MCP_EVENT_MAX_HEARTBEAT_MS
  else
    FHeartbeatMs := AHeartbeatMs;
  // The handler's context lasts only for its call: what later checks
  // see is copied.
  FProtocolVersion := ACtx.ProtocolVersion;
  FClientName := ACtx.ClientName;
  FClientVersion := ACtx.ClientVersion;
  FLogLevel := ACtx.LogLevel;
  if ACtx.ClientCapabilities <> nil then
    FCapabilities := TJSONObject(ACtx.ClientCapabilities.Clone);
  if ACtx.Meta <> nil then
    FMeta := TJSONObject(ACtx.Meta.Clone);
end;

destructor TEventStream.Destroy;
begin
  FPending.Free;
  FArguments.Free;
  FCapabilities.Free;
  FMeta.Free;
  inherited Destroy;
end;

function TEventStream.IsCancelled: Boolean;
begin
  Result := Cancelled;
end;

function TEventStream.Context: TMCPRequestContext;
begin
  Result := Default(TMCPRequestContext);
  Result.ProtocolVersion := FProtocolVersion;
  Result.ClientName := FClientName;
  Result.ClientVersion := FClientVersion;
  Result.ClientCapabilities := FCapabilities;
  Result.LogLevel := FLogLevel;
  Result.Meta := FMeta;
  Result.RequestId := Id;
  // Live: the transport's probe, so a check that waits sees a client
  // that went away (#126 review).
  Result.CancellationProbe := IsCancelled;
end;

// The cursor as the wire carries it: null for a type without replay.
function TEventStream.WireCursor: TJSONData;
begin
  if FNull then
    Result := TJSONNull.Create
  else
    Result := TJSONString.Create(FCursor);
end;

// One notifications/events/* message, AParams (owned) tagged with the
// stream's subscription id (events.mdx, Event delivery); nothing once
// the stream is cancelled.
procedure TEventStream.Send(const AMethod: string; AParams: TJSONObject;
  ASink: TMCPLineSink; ASinkData: Pointer);
var
  Meta: TJSONData;
begin
  try
    if Cancelled then
    begin
      AParams.Free;
      Exit;
    end;
    Meta := AParams.Find('_meta');
    if (Meta = nil) or (Meta.JSONType <> jtObject) then
    begin
      AParams.Delete('_meta');
      Meta := TJSONObject.Create;
      AParams.Add('_meta', Meta);
    end;
    TJSONObject(Meta).Delete(MCP_SUBSCRIPTION_ID_KEY);
    TJSONObject(Meta).Add(MCP_SUBSCRIPTION_ID_KEY, Id.Clone);
  except
    AParams.Free;
    raise;
  end;
  ASink(BuildNotification(AMethod, AParams), ASinkData);
  FLastWrite := Now;
end;

// The error member of error and terminated notifications: data only
// when it is an object, as Subscription Termination shapes it.
function ErrorObject(ACode: Integer; const AMessage: string;
  AData: TJSONData): TJSONObject;
begin
  Result := TJSONObject.Create(['code', ACode, 'message', AMessage]);
  if (AData <> nil) and (AData.JSONType = jtObject) then
    Result.Add('data', AData)
  else
    AData.Free;
end;

// The StreamEventsResult, the final frame when the server closes the
// stream (events.mdx, Lifecycle): resultType and the subscription id in
// _meta, nothing else.
procedure TEventStream.Close(ASink: TMCPLineSink; ASinkData: Pointer);
var
  Final: TJSONObject;
begin
  Final := TJSONObject.Create(['resultType', RESULT_TYPE_COMPLETE]);
  Final.Add('_meta', TJSONObject.Create([MCP_SUBSCRIPTION_ID_KEY,
    Id.Clone]));
  ASink(BuildResultResponse(Id, Final), ASinkData);
  Finish;
end;

// The subscription ends (events.mdx, Subscription Termination): the
// terminated notification, then the final frame, since the server
// closes the stream.
procedure TEventStream.Terminate(ACode: Integer; const AMessage: string;
  AData: TJSONData; ASink: TMCPLineSink; ASinkData: Pointer);
begin
  Send('notifications/events/terminated', TJSONObject.Create(['error',
    ErrorObject(ACode, AMessage, AData)]), ASink, ASinkData);
  if not Cancelled then
    Close(ASink, ASinkData);
end;

// One page from the check (at most one occurrence). The first page and
// a gap send active: the client's own cursor before a first event, the
// gap's resume position (GapCursor, else the cursor the stream had)
// before an event after a gap, the fresh cursor otherwise, and null for
// a type without replay. The occurrence goes out with the cursor after
// it, and hasMore reads on at once.
procedure TEventStream.SendPage(APage: TJSONObject; const AAfter, AGap: string;
  ANoReplay, AFirst: Boolean; ASink: TMCPLineSink; ASinkData: Pointer);
var
  Events: TJSONArray;
  Truncated, HasEvents: Boolean;
  Active: TJSONObject;
  Position: TJSONData;
begin
  Events := TJSONArray(APage.Find('events'));
  Truncated := APage.Get('truncated', False);
  HasEvents := Events.Count > 0;
  if AFirst or Truncated then
  begin
    if ANoReplay then
      Position := TJSONNull.Create
    else if HasEvents and Truncated and (AGap <> '') then
      Position := TJSONString.Create(AGap)
    else if HasEvents then
      // Resuming here delivers the event again, never skips it.
      Position := WireCursor
    else
      Position := TJSONString.Create(AAfter);
    Active := TJSONObject.Create(['cursor', Position, 'truncated',
      Truncated and not ANoReplay, 'heartbeatMs', FHeartbeatMs]);
    Send('notifications/events/active', Active, ASink, ASinkData);
  end;
  FCursor := AAfter;
  FNull := ANoReplay;
  while Events.Count > 0 do
  begin
    Active := TJSONObject(Events.Extract(0));
    Active.Delete('cursor');
    Active.Add('cursor', WireCursor);
    Send('notifications/events/event', Active, ASink, ASinkData);
  end;
  FInterval := APage.Get('nextPollMs', FInterval);
  FCatchingUp := FCatchingUp and APage.Get('hasMore', False);
  // From when the check returned (#126 review).
  if APage.Get('hasMore', False) then
    FNextCheck := Now
  else
    FNextCheck := Now + FInterval;
end;

// The check again, from the stream's own cursor: a protocol error it
// raises ends the subscription, and so does a result that breaks the
// occurrence rules (-32603), which would recur; any other failure,
// EMCPServer included, is reported and retried at the next interval.
procedure TEventStream.CheckAgain(ASink: TMCPLineSink; ASinkData: Pointer);
var
  Query: TMCPEventQuery;
  Page: TJSONObject;
  After, Gap: string;
  NoReplay: Boolean;
begin
  Query := Default(TMCPEventQuery);
  Query.Arguments := FArguments;
  Query.Cursor := FCursor;
  if FCatchingUp then
    Query.MaxAgeMs := FMaxAgeMs
  else
    Query.MaxAgeMs := -1;
  Query.MaxEvents := 1;
  try
    Page := FCatalog.CheckPage(FType, Query, Context, After, Gap, NoReplay);
  except
    on E: EMCPProtocolError do
    begin
      if E.Data <> nil then
        Terminate(E.Code, E.Message, E.Data.Clone, ASink, ASinkData)
      else
        Terminate(E.Code, E.Message, nil, ASink, ASinkData);
      Exit;
    end;
    on E: EEventMistake do
    begin
      LogStreamFailure(E);
      Terminate(JSONRPC_INTERNAL_ERROR, 'Internal error', nil, ASink,
        ASinkData);
      Exit;
    end;
    on E: Exception do
    begin
      LogStreamFailure(E);
      Send('notifications/events/error', TJSONObject.Create(['error',
        ErrorObject(JSONRPC_INTERNAL_ERROR, 'Internal error', nil)]),
        ASink, ASinkData);
      FNextCheck := Now + FInterval;
      Exit;
    end;
  end;
  try
    SendPage(Page, After, Gap, NoReplay, False, ASink, ASinkData);
  finally
    Page.Free;
  end;
end;

// Best effort, through the core's diagnostic writer, which a closed
// stderr cannot stop (#126 review).
procedure TEventStream.LogStreamFailure(E: Exception);
begin
  MCPLogDiagnostic('events/stream ' + FCatalog.FTypes[FType].Name + ': ' +
    E.ClassName + ': ' + E.Message);
end;

// The first page, the checks that are due (at most STEP_BUDGET of them,
// so a long backlog does not hold up a transport's other requests), and
// a heartbeat when heartbeatMs passed without a message (events.mdx,
// Lifecycle). Cancellation is asked between them.
function TEventStream.Step(ASink: TMCPLineSink; ASinkData: Pointer): Int64;
const
  STEP_BUDGET = 50;
var
  Page: TJSONObject;
  Budget: Integer;
begin
  Result := High(Int64);
  if Cancelled then
    Exit;
  if FPending <> nil then
  begin
    Page := FPending;
    FPending := nil;
    try
      SendPage(Page, FPendingCursor, FPendingGap, FPendingNoReplay, True,
        ASink, ASinkData);
    finally
      Page.Free;
    end;
  end;
  Budget := STEP_BUDGET;
  while not Cancelled and (Now >= FNextCheck) and (Budget > 0) do
  begin
    CheckAgain(ASink, ASinkData);
    Dec(Budget);
  end;
  if not Cancelled and (Now - FLastWrite >= FHeartbeatMs) then
    Send('notifications/events/heartbeat', TJSONObject.Create(['cursor',
      WireCursor]), ASink, ASinkData);
  if Finished then
    Exit;
  Result := FNextCheck;
  if FLastWrite + FHeartbeatMs < Result then
    Result := FLastWrite + FHeartbeatMs;
end;

procedure RegisterType(AServer: TMCPServer; const AName, ADescription: string;
  AInputSchema, APayloadSchema: TJSONObject; ACheck: TMCPEventCheck;
  ACheckMethod: TMCPEventCheckMethod; ANextPollMs: Integer);
const
  METHODS: array[0..2] of string = ('events/list', 'events/poll',
    'events/stream');
var
  Catalog: TEventCatalog;
  Fresh: Boolean;
  Problem: string;
begin
  // Every check comes before the server changes, as for Skills.
  try
    if AServer = nil then
      raise EMCPServer.Create('RegisterEvent needs a server');
    Catalog := TEventCatalog(AServer.Adopted(TEventCatalog));
    Fresh := Catalog = nil;
    if Fresh then
      Problem := AServer.HookProblem(METHODS, '')
    else
      Problem := AServer.HookProblem([], '');
    if Problem <> '' then
      raise EMCPServer.Create(Problem);
  except
    AInputSchema.Free;
    APayloadSchema.Free;
    raise;
  end;
  if Fresh then
    Catalog := TEventCatalog.Create(AServer);
  try
    Catalog.Add(AName, ADescription, AInputSchema, APayloadSchema, ACheck,
      ACheckMethod, ANextPollMs);
  except
    if Fresh then
      Catalog.Free;
    raise;
  end;
  if Fresh then
  begin
    AServer.Adopt(Catalog);
    AServer.RegisterMethod(METHODS[0], Catalog.List);
    AServer.RegisterMethod(METHODS[1], Catalog.Poll);
    AServer.RegisterMethod(METHODS[2], Catalog.Stream);
    // Mcp-Name carries params.name, and Mcp-Param-* the arguments
    // (events.mdx, Streamable HTTP: Routing Headers).
    AServer.RegisterRoute(METHODS[1], 'name', Catalog.HeaderParameters);
    AServer.RegisterRoute(METHODS[2], 'name', Catalog.HeaderParameters);
  end;
  // Settings declared first are kept; {} declares no list changes. The
  // classic initialize offers nothing a classic client could call.
  AServer.EnsureExtension(MCP_EVENTS_EXTENSION);
  if Fresh then
  begin
    AServer.RestrictExtensionToModern(MCP_EVENTS_EXTENSION);
    // listChanged needs subscriptions/listen, which this server lacks:
    // {} whatever is declared before or after (#118 review).
    AServer.PinExtensionSettings(MCP_EVENTS_EXTENSION, TJSONObject.Create);
  end;
end;

procedure RegisterEvent(AServer: TMCPServer; const AName,
  ADescription: string; AInputSchema, APayloadSchema: TJSONObject;
  ACheck: TMCPEventCheck; ANextPollMs: Integer);
begin
  RegisterType(AServer, AName, ADescription, AInputSchema, APayloadSchema, ACheck,
    nil, ANextPollMs);
end;

procedure RegisterEvent(AServer: TMCPServer; const AName,
  ADescription: string; AInputSchema, APayloadSchema: TJSONObject;
  ACheck: TMCPEventCheckMethod; ANextPollMs: Integer);
begin
  RegisterType(AServer, AName, ADescription, AInputSchema, APayloadSchema, nil,
    ACheck, ANextPollMs);
end;

procedure RegisterEvent(AServer: TMCPServer; const AName,
  ADescription: string; constref AInputSchema, APayloadSchema: TMCPSchema;
  ACheck: TMCPEventCheck; ANextPollMs: Integer);
var
  Input, Payload: TJSONObject;
begin
  // One at a time, so a failing second build frees the first.
  Input := AInputSchema.Build;
  try
    Payload := APayloadSchema.Build;
  except
    Input.Free;
    raise;
  end;
  RegisterType(AServer, AName, ADescription, Input, Payload, ACheck, nil,
    ANextPollMs);
end;

end.
