{ MCP.Events — the Events extension (io.modelcontextprotocol/events,
  #118): event types a server declares, listed by events/list and read
  by poll delivery (events/poll), on the 2026-07-28 revision. Verified
  2026-11-27 against modelcontextprotocol/ext-events
  specification/beta/events/events.mdx at c77b843 (Beta; SEP-3415).
  The server holds no state per client: each poll carries the event
  name, the arguments and the cursor, and the check the server author
  registers answers it. Push and webhook delivery are not served, and
  neither is notifications/events/list_changed, which needs
  subscriptions/listen.

  An event type the check reads from an upstream with a position: one
  page from the cursor, its own next position and HasMore (see the
  Events guide for a fuller example).

    function NewMail(const AQuery: TMCPEventQuery;
      const ACtx: TMCPRequestContext): TMCPEventPoll;
    begin
      if AQuery.FromNow then
        Exit(MCPEventPoll(Inbox.Position));
      Page := Inbox.ReadFrom(AQuery.Cursor, AQuery.MaxAgeMs,
        AQuery.MaxEvents);
      Result := MCPEventPoll(Page.NextPosition, Page.Occurrences);
      Result.HasMore := Page.HasMore;
    end;

    RegisterEvent(Server, 'email.received', 'Fires when an email arrives',
      ObjectSchema.AddString('from'), ObjectSchema.AddString('subject'),
      NewMail); }

unit MCP.Events;

{$I MCP.inc}

interface

uses
  SysUtils,

  fpjson,
  MCP.Protocol,
  MCP.Schema,
  MCP.Server;

const
  MCP_EVENTS_EXTENSION = 'io.modelcontextprotocol/events';
  // nextPollMs when a registration names none: the specification's
  // example interval.
  MCP_EVENT_DEFAULT_POLL_MS = 30000;

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
  TMCPEventPoll = record
    Events: TJSONArray;
    Cursor: string;
    NoReplay: Boolean;
    HasMore: Boolean;
    Truncated: Boolean;
    NextPollMs: Integer;
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
// poll: AInputSchema (owned) describes the arguments, with root type
// object and x-mcp-header annotations as for tools; APayloadSchema
// (owned) describes each occurrence's data, which is checked when the
// schema lies in the subset the server enforces. The first call
// declares the extension and serves events/list and events/poll; a
// classic-handshake client gets -32601, as the extension is defined
// for 2026-07-28. On Streamable HTTP, events/poll carries Mcp-Name and
// the Mcp-Param-* headers. A duplicate or empty name, a bad schema or a
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
    function HeaderParameters(const AName: string): TMCPHeaderParameters;
    function PollResult(AType: Integer; const AQuery: TMCPEventQuery;
      var APoll: TMCPEventPoll): TJSONObject;
  public
    constructor Create(AServer: TMCPServer);
    destructor Destroy; override;
    procedure Add(const AName, ADescription: string; AInputSchema,
      APayloadSchema: TJSONObject; ACheck: TMCPEventCheck;
      ACheckMethod: TMCPEventCheckMethod; ANextPollMs: Integer);
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
  Index, I: Integer;
begin
  Result := nil;
  Index := FindType(AName);
  if Index < 0 then
    Exit;
  Result := Copy(FTypes[Index].Headers);
  for I := 0 to High(Result) do
    Result[I].Path := Copy(FTypes[Index].Headers[I].Path);
end;

procedure TEventCatalog.Add(const AName, ADescription: string;
  AInputSchema, APayloadSchema: TJSONObject; ACheck: TMCPEventCheck;
  ACheckMethod: TMCPEventCheckMethod; ANextPollMs: Integer);
var
  Slot: Integer;
  Headers: TMCPHeaderParameters;
  Problem: string;
  RootType: TJSONData;
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
    // inputSchema "mirrors the inputSchema/arguments pairing on tools"
    // (events.mdx, Listing Available Events): an object root, and
    // x-mcp-header annotations a client accepts.
    RootType := AInputSchema.Find('type');
    if (RootType = nil) or (RootType.JSONType <> jtString) or
      (RootType.AsString <> 'object') then
      raise EMCPServer.CreateFmt('Event type "%s" inputSchema must have ' +
        'root type "object"', [AName]);
    Problem := MCPHeaderParameters(AInputSchema, Headers);
    if Problem <> '' then
      raise EMCPServer.CreateFmt('Event type "%s" inputSchema: %s',
        [AName, Problem]);
  except
    AInputSchema.Free;
    APayloadSchema.Free;
    raise;
  end;
  NilChildrenToNull(AInputSchema);
  NilChildrenToNull(APayloadSchema);
  Slot := Length(FTypes);
  SetLength(FTypes, Slot + 1);
  FTypes[Slot].Name := AName;
  FTypes[Slot].Description := ADescription;
  FTypes[Slot].InputSchema := AInputSchema;
  FTypes[Slot].PayloadSchema := APayloadSchema;
  FTypes[Slot].CheckArguments := MCPSchemaSubsetViolation(AInputSchema,
    True) = '';
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
        FTypes[I].Description, 'delivery', TJSONArray.Create(['poll']),
        'inputSchema', FTypes[I].InputSchema.Clone, 'payloadSchema',
        FTypes[I].PayloadSchema.Clone]));
    if Last < High(FTypes) then
      Result.Add('nextCursor', ListCursor('events/list', Last + 1));
  except
    Result.Free;
    raise;
  end;
end;

// A non-negative integer member AName of AParams, or -1 when absent.
function OptionalCount(AParams: TJSONObject; const AName: string): Int64;
var
  Value: TJSONData;
begin
  Result := -1;
  Value := AParams.Find(AName);
  if Value = nil then
    Exit;
  if (Value.JSONType <> jtNumber) or
    (TJSONNumber(Value).NumberType = ntFloat) or (Value.AsInt64 < 0) then
    raise InvalidParams(AName + ' must be a non-negative integer');
  Result := Value.AsInt64;
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
begin
  if APoll.Events = nil then
    APoll.Events := TJSONArray.Create;
  if AQuery.FromNow and (APoll.Events.Count > 0) then
    raise EMCPServer.CreateFmt('Event type "%s" returned events for a poll ' +
      'from now', [FTypes[AType].Name]);
  if (AQuery.MaxEvents >= 0) and (APoll.Events.Count > AQuery.MaxEvents) then
    raise EMCPServer.CreateFmt('Event type "%s" returned more than ' +
      'maxEvents events', [FTypes[AType].Name]);
  for I := 0 to APoll.Events.Count - 1 do
  begin
    Occurrence := APoll.Events.Items[I];
    if (Occurrence = nil) or (Occurrence.JSONType <> jtObject) then
      raise EMCPServer.CreateFmt('Event type "%s" returned an occurrence ' +
        'that is no object', [FTypes[AType].Name]);
    Data := TJSONObject(Occurrence).Find('data');
    Timestamp := TJSONObject(Occurrence).Find('timestamp');
    // An eventId is a string, _meta an object, and a poll's cursor is
    // the result's alone (events.mdx, Event Occurrences).
    Field := TJSONObject(Occurrence).Find('eventId');
    if ((Field <> nil) and (Field.JSONType <> jtString)) or
      (TJSONObject(Occurrence).IndexOfName('cursor') >= 0) then
      raise EMCPServer.CreateFmt('Event type "%s" returned an occurrence ' +
        'with a bad eventId or a cursor of its own', [FTypes[AType].Name]);
    Field := TJSONObject(Occurrence).Find('_meta');
    if (Field <> nil) and (Field.JSONType <> jtObject) then
      raise EMCPServer.CreateFmt('Event type "%s" returned an occurrence ' +
        'whose _meta is no object', [FTypes[AType].Name]);
    if (Data = nil) or (Data.JSONType <> jtObject) or (Timestamp = nil) or
      (Timestamp.JSONType <> jtString) or
      not ValidTimestamp(Timestamp.AsString) then
      raise EMCPServer.CreateFmt('Event type "%s" returned an occurrence ' +
        'without an object data or an RFC 3339 timestamp',
        [FTypes[AType].Name]);
    if FTypes[AType].CheckPayload and not MCPValidateAgainstSchema(
      FTypes[AType].PayloadSchema, Data, 'payload', False, Violation) then
      raise EMCPServer.CreateFmt('Event type "%s" returned data that does ' +
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

// events/poll (events.mdx, Poll-Based Delivery): one subscription per
// request, no state held; -32023 for an unknown name, -32602 for
// arguments that do not match the input schema.
function TEventCatalog.Poll(AParams: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
var
  NameData, CursorData, ArgumentsData: TJSONData;
  Index: Integer;
  Query: TMCPEventQuery;
  Poll: TMCPEventPoll;
  OwnedArguments: TJSONObject;
  Violation: string;
  Count: Int64;
begin
  RefuseLegacy(ALegacy, 'events/poll');
  if AParams = nil then
    raise InvalidParams('params are required');
  NameData := AParams.Find('name');
  if (NameData = nil) or (NameData.JSONType <> jtString) then
    raise InvalidParams('name must be a string');
  Index := FindType(NameData.AsString);
  if Index < 0 then
    raise EMCPProtocolError.Create(MCP_ERROR_NOT_FOUND, 'Event type not ' +
      'found', TJSONObject.Create(['kind', 'event']));
  Query := Default(TMCPEventQuery);
  // An absent cursor is a null one (events.mdx, Cursor Lifecycle).
  CursorData := AParams.Find('cursor');
  Query.FromNow := (CursorData = nil) or (CursorData.JSONType = jtNull);
  if not Query.FromNow then
  begin
    if CursorData.JSONType <> jtString then
      raise InvalidParams('cursor must be a string or null');
    Query.Cursor := CursorData.AsString;
  end;
  // maxAgeMs is ignored for a poll from now.
  Query.MaxAgeMs := OptionalCount(AParams, 'maxAgeMs');
  Count := OptionalCount(AParams, 'maxEvents');
  if Count > MaxInt then
    Count := MaxInt;
  Query.MaxEvents := Count;
  ArgumentsData := AParams.Find('arguments');
  OwnedArguments := nil;
  if ArgumentsData = nil then
  begin
    OwnedArguments := TJSONObject.Create;
    ArgumentsData := OwnedArguments;
  end
  else if ArgumentsData.JSONType <> jtObject then
    raise InvalidParams('arguments must be an object');
  try
    if FTypes[Index].CheckArguments and not MCPValidateAgainstSchema(
      FTypes[Index].InputSchema, ArgumentsData, 'argument', True,
      Violation) then
      raise InvalidParams(Violation);
    Query.Arguments := TJSONObject(ArgumentsData);
    if Assigned(FTypes[Index].CheckMethod) then
      Poll := FTypes[Index].CheckMethod(Query, ACtx)
    else
      Poll := FTypes[Index].Check(Query, ACtx);
    try
      Result := PollResult(Index, Query, Poll);
    finally
      Poll.Events.Free;
    end;
  finally
    OwnedArguments.Free;
  end;
end;

procedure RegisterType(AServer: TMCPServer; const AName, ADescription: string;
  AInputSchema, APayloadSchema: TJSONObject; ACheck: TMCPEventCheck;
  ACheckMethod: TMCPEventCheckMethod; ANextPollMs: Integer);
const
  METHODS: array[0..1] of string = ('events/list', 'events/poll');
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
    // Mcp-Name carries params.name, and Mcp-Param-* the arguments
    // (events.mdx, Streamable HTTP: Routing Headers).
    AServer.RegisterRoute(METHODS[1], 'name', Catalog.HeaderParameters);
  end;
  // Settings declared first are kept; {} declares no list changes. The
  // classic initialize offers nothing a classic client could call.
  AServer.EnsureExtension(MCP_EVENTS_EXTENSION);
  if Fresh then
    AServer.RestrictExtensionToModern(MCP_EVENTS_EXTENSION);
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
