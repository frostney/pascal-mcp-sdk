{ MCP.Events.Test — the Events extension (#118, #126): the declaration,
  events/list, poll delivery from now and from a cursor, maxEvents and
  hasMore, truncation, event types without replay, derived event ids,
  the errors (-32023 for an unknown type, -32602 for bad parameters or
  arguments, -32601 for a classic client, -32603 for a check's
  mistakes) and the registration guards; and push delivery
  (events/stream): the active, event, heartbeat, error and terminated
  notifications, the final frame, per-event cursors, gaps, types without
  replay, heartbeat grants and the immediate errors. Shapes verified
  2026-11-27
  against modelcontextprotocol/ext-events
  specification/beta/events/events.mdx at c77b843 (Push-Based Delivery,
  Cursor Lifecycle, Subscription Termination). }

program MCP.Events.Test;

{$I MCP.inc}

uses
  SysUtils,

  fpjson,
  MCP.Events,
  MCP.Extensions,
  MCP.JSONRPC,
  MCP.Protocol,
  MCP.Schema,
  MCP.Server,
  MCP.Streams,
  MCP.Testing,
  TestingPascalLibrary;

const
  META =
    '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{}}';
  // "Grüße", raw UTF-8 bytes.
  GRUSSE = 'Gr' + #$C3#$BC + #$C3#$9F + 'e';

type
  TEventsSuite = class(TTestSuite)
  private
    FServer: TMCPServer;
    FSession: TMCPSession;
    FClient: TMCPTestClient;
    function Send(const ALine: string): string;
    function Poll(const AParams: string): TJSONObject;
    procedure RegisterFixture;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;
    procedure TestDeclaration;
    procedure TestList;
    procedure TestListLine;
    procedure TestPollFromNow;
    procedure TestPollFromCursor;
    procedure TestTruncatedAndNoReplay;
    procedure TestDerivedEventId;
    procedure TestErrors;
    procedure TestCheckMistakes;
    procedure TestClassicEra;
    procedure TestGuards;
    procedure TestListPaging;
    procedure TestUtf8Occurrence;
    procedure TestRouteCopy;
    procedure TestSettingsPinned;
  end;

// The upstream: five occurrences at positions 1 to 5. A cursor is the
// position read last; "old" lies before the retention window.
function ClockCheck(const AQuery: TMCPEventQuery;
  const ACtx: TMCPRequestContext): TMCPEventPoll;
var
  From, Last, I: Integer;
begin
  if AQuery.FromNow then
    Exit(MCPEventPoll('5'));
  Result := MCPEventPoll('5', TJSONArray.Create);
  if AQuery.Cursor = 'old' then
  begin
    Result.Truncated := True;
    Exit;
  end;
  From := StrToInt(AQuery.Cursor) + 1;
  Last := 5;
  if (AQuery.MaxEvents >= 0) and (From + AQuery.MaxEvents - 1 < Last) then
  begin
    Last := From + AQuery.MaxEvents - 1;
    Result.HasMore := True;
  end;
  for I := From to Last do
    Result.Events.Add(MCPEventOccurrence('e' + IntToStr(I),
      '2026-11-27T10:0' + IntToStr(I) + ':00Z', TJSONObject.Create(['n', I,
      'region', AQuery.Arguments.Get('region', '')])));
  Result.Cursor := IntToStr(Last);
end;

function NoReplayCheck(const AQuery: TMCPEventQuery;
  const ACtx: TMCPRequestContext): TMCPEventPoll;
begin
  Result := MCPEventPoll('');
  Result.NoReplay := True;
  Result.Truncated := True;
  Result.NextPollMs := 1000;
end;

function DerivedCheck(const AQuery: TMCPEventQuery;
  const ACtx: TMCPRequestContext): TMCPEventPoll;
begin
  if AQuery.Arguments.Get('order', '') = 'ba' then
    Exit(MCPEventPoll('1', TJSONArray.Create([MCPEventOccurrence('',
      '2026-11-27T10:00:00Z', TJSONObject.Create(['b', 2, 'a', 1])),
      MCPEventOccurrence('', '2026-11-27T10:00:00Z',
      TJSONObject.Create(['a', 1, 'b', 2]))])));
  Result := MCPEventPoll('1', TJSONArray.Create([MCPEventOccurrence('',
    '2026-11-27T10:00:00Z', TJSONObject.Create(['n', 1]))]));
end;

// The occurrences a fault returns as JSON text, '' for a fault built in
// code or raised.
function FaultText(const AKind: string): string;
const
  OCCURRENCE = '{"eventId":"x","timestamp":"2026-11-27T10:00:00Z","data":';
  KINDS: array[0..7] of string = ('payload', 'timestamp', 'many',
    'february', 'idtype', 'meta', 'cursor', 'utf8');
  TEXTS: array[0..7] of string = (
    '[' + OCCURRENCE + '{"n":"not a number"}}]',
    '[{"eventId":"x","timestamp":"yesterday","data":{"n":1}}]',
    '[' + OCCURRENCE + '{"n":1}},{"eventId":"y","timestamp":' +
      '"2026-11-27T10:00:00Z","data":{"n":2}}]',
    '[{"eventId":"x","timestamp":"2026-02-31T10:00:00Z","data":{"n":1}}]',
    '[{"eventId":7,"timestamp":"2026-11-27T10:00:00Z","data":{"n":1}}]',
    '[{"timestamp":"2026-11-27T10:00:00Z","data":{"n":1},"_meta":[]}]',
    '[{"timestamp":"2026-11-27T10:00:00Z","data":{"n":1},"cursor":"c"}]',
    '[{"eventId":"u","timestamp":"2026-11-27T10:00:00Z","data":' +
      '{"n":1,"note":"Gr\u00fc\u00dfe"}}]');
var
  I: Integer;
begin
  for I := 0 to High(KINDS) do
    if KINDS[I] = AKind then
      Exit(TEXTS[I]);
  Result := '';
end;

// An occurrence built in code with a member stored as nil, which goes
// out as a null (#118 review); nil for another fault.
function NilFault(const AKind: string): TJSONObject;
var
  Payload: TJSONObject;
begin
  Result := nil;
  if (AKind = 'nilcursor') or (AKind = 'nilmeta') then
  begin
    Result := MCPEventOccurrence('n', '2026-11-27T10:00:00Z',
      TJSONObject.Create(['n', 1]));
    if AKind = 'nilcursor' then
      Result.Add('cursor', TJSONData(nil))
    else
      Result.Add('_meta', TJSONData(nil));
  end
  else if AKind = 'nildata' then
  begin
    // A payload member the schema leaves open, stored as nil, with a
    // derived id.
    Payload := TJSONObject.Create(['n', 1]);
    Payload.Add('extra', TJSONData(nil));
    Result := MCPEventOccurrence('', '2026-11-27T10:00:00Z', Payload);
  end;
end;

// The extension's error codes, raised by a check.
procedure RaiseFault(const AKind: string);
begin
  if AKind = 'refuse' then
    raise EMCPProtocolError.Create(-32024, 'Forbidden',
      TJSONObject.Create(['reason', 'not yours']))
  else if AKind = 'exhausted' then
    raise EMCPProtocolError.Create(-32025, 'ResourceExhausted',
      TJSONObject.Create(['limit', 'subscriptions']))
  else if AKind = 'unsupported' then
    raise EMCPProtocolError.Create(-32026, 'Unsupported',
      TJSONObject.Create(['feature', 'deliveryMode', 'value', 'push']))
  else if AKind = 'callback' then
    raise EMCPProtocolError.Create(-32027, 'CallbackEndpointError',
      TJSONObject.Create(['reason', 'timeout']));
end;

// What the arguments ask for goes wrong on purpose.
function FaultyCheck(const AQuery: TMCPEventQuery;
  const ACtx: TMCPRequestContext): TMCPEventPoll;
var
  Kind, Text: string;
  Built: TJSONObject;
begin
  Kind := AQuery.Arguments.Get('fault', '');
  RaiseFault(Kind);
  Text := FaultText(Kind);
  if Text <> '' then
    Exit(MCPEventPoll('1', TJSONArray(MCPParseJSON(Text))));
  Result := MCPEventPoll('1', TJSONArray.Create);
  // A null cursor cannot lead to the next page (#118 review).
  Result.NoReplay := Kind = 'noreplaymore';
  Result.HasMore := Result.NoReplay;
  Built := NilFault(Kind);
  if Built <> nil then
    Result.Events.Add(Built);
end;

procedure TEventsSuite.RegisterFixture;
var
  Description: string;
begin
  Description := 'Ticks of the clock, ' + GRUSSE;
  RegisterEvent(FServer, 'clock.tick', Description,
    TJSONObject(MCPParseJSON('{"type":"object","properties":{"region":' +
    '{"type":"string","x-mcp-header":"Region"}}}')),
    ObjectSchema.AddInteger('n').AddString('region').Build, ClockCheck);
  RegisterEvent(FServer, 'no.replay', 'Push-only upstream',
    ObjectSchema, ObjectSchema, NoReplayCheck);
  RegisterEvent(FServer, 'derived.id', 'Ids from the server',
    TJSONObject(MCPParseJSON('{"type":"object","properties":{"order":' +
    '{"type":"string"}}}')), ObjectSchema.Build, DerivedCheck);
  RegisterEvent(FServer, 'faulty', 'Mistakes on request',
    ObjectSchema.AddString('fault').Build, TJSONObject(MCPParseJSON(
    '{"type":"object","properties":{"n":{"type":"integer"},"note":' +
    '{"type":"string"}},"required":["n"]}')), FaultyCheck);
end;

procedure TEventsSuite.BeforeEach;
begin
  FServer := TMCPServer.Create('events', '1.0');
  FSession := nil;
  FClient := nil;
end;

procedure TEventsSuite.AfterEach;
begin
  FreeAndNil(FClient);
  FreeAndNil(FSession);
  FreeAndNil(FServer);
end;

function TEventsSuite.Send(const ALine: string): string;
begin
  if FSession = nil then
    FSession := FServer.CreateSession;
  FServer.HandleMessage(FSession, ALine, Result);
end;

function TEventsSuite.Poll(const AParams: string): TJSONObject;
begin
  if FClient = nil then
    FClient := TMCPTestClient.Create(FServer);
  Result := FClient.Request('events/poll', '{' + AParams + '}');
end;

function Str(AResponse: TJSONObject; const APath: string): string;
var
  Data: TJSONData;
begin
  Data := AResponse.FindPath(APath);
  if Data = nil then
    Exit('<absent>');
  Result := Data.AsJSON;
end;

// events.mdx, Capability Negotiation: {} declares no list changes.
procedure TEventsSuite.TestDeclaration;
begin
  RegisterFixture;
  Expect<Boolean>(Pos('"capabilities" : { "extensions" : ' +
    '{ "io.modelcontextprotocol/events" : {} } }', Send('{"jsonrpc":"2.0",' +
    '"id":1,"method":"server/discover","params":{' + META + '}}')) > 0)
    .ToBe(True);
end;

// events.mdx, Listing Available Events, byte-exact for the first type.
procedure TEventsSuite.TestList;
var
  Line: string;
begin
  RegisterFixture;
  Line := Send('{"jsonrpc":"2.0","id":2,"method":"events/list","params":{' +
    META + '}}');
  Expect<Boolean>(Pos('{ "events" : [{ "name" : "clock.tick", "description" ' +
    ': "Ticks of the clock, ' + GRUSSE + '", "delivery" : ["poll", "push"], ' +
    '"inputSchema" : { "type" : "object", "properties" : { "region" : ' +
    '{ "type" : "string", "x-mcp-header" : "Region" } } }, "payloadSchema" : ' +
    '{ "type" : "object", "properties" : { "n" : { "type" : "integer" }, ' +
    '"region" : { "type" : "string" } }, "required" : ["n", "region"] } }, ' +
    '{ "name" : "no.replay"', Line) >
    0).ToBe(True);
  Expect<Boolean>(Pos('"resultType" : "complete"', Line) > 0).ToBe(True);
end;

// One type alone: the whole events/list line (#118 review).
procedure TEventsSuite.TestListLine;
begin
  RegisterEvent(FServer, 'one', 'One event', ObjectSchema.Build,
    ObjectSchema.AddInteger('n').Build, ClockCheck);
  Expect<string>(Send('{"jsonrpc":"2.0","id":2,"method":"events/list",' +
    '"params":{' + META + '}}')).ToBe('{ "jsonrpc" : "2.0", "id" : 2, ' +
    '"result" : { "events" : [{ "name" : "one", "description" : ' +
    '"One event", "delivery" : ["poll", "push"], "inputSchema" : ' +
    '{ "type" : ' +
    '"object", "properties" : {} }, "payloadSchema" : { "type" : "object", ' +
    '"properties" : { "n" : { "type" : "integer" } }, "required" : ["n"] } }' +
    '], "resultType" : "complete", "_meta" : { ' +
    '"io.modelcontextprotocol/serverInfo" : { "name" : "events", ' +
    '"version" : "1.0" } } } }');
end;

// "null means start from now: the server returns no events and a fresh
// cursor"; an absent cursor is a null one.
procedure TEventsSuite.TestPollFromNow;
begin
  RegisterFixture;
  Expect<string>(Send('{"jsonrpc":"2.0","id":3,"method":"events/poll",' +
    '"params":{"name":"clock.tick","cursor":null,' + META + '}}')).ToBe(
    '{ "jsonrpc" : "2.0", "id" : 3, "result" : { "events" : [], "cursor" : ' +
    '"5", "truncated" : false, "hasMore" : false, "nextPollMs" : 30000, ' +
    '"resultType" : "complete", "_meta" : { ' +
    '"io.modelcontextprotocol/serverInfo" : { "name" : "events", ' +
    '"version" : "1.0" } } } }');
  Expect<Boolean>(Pos('"cursor" : "5"', Send('{"jsonrpc":"2.0","id":4,' +
    '"method":"events/poll","params":{"name":"clock.tick",' + META + '}}')) >
    0).ToBe(True);
end;

// A cursor reads on from its position; maxEvents caps the batch and
// hasMore says more are waiting; arguments reach the check.
procedure TEventsSuite.TestPollFromCursor;
var
  Response: TJSONObject;
begin
  RegisterFixture;
  Response := Poll('"name":"clock.tick","cursor":"2","maxEvents":2,' +
    '"arguments":{"region":"eu"}');
  try
    Expect<string>(Str(Response, 'result.events[0]')).ToBe('{ "eventId" : ' +
      '"e3", "timestamp" : "2026-11-27T10:03:00Z", "data" : { "n" : 3, ' +
      '"region" : "eu" }, "name" : "clock.tick" }');
    Expect<string>(Str(Response, 'result.events[1].eventId')).ToBe('"e4"');
    Expect<string>(Str(Response, 'result.cursor')).ToBe('"4"');
    Expect<string>(Str(Response, 'result.hasMore')).ToBe('true');
  finally
    Response.Free;
  end;
  Response := Poll('"name":"clock.tick","cursor":"4"');
  try
    Expect<Integer>(TJSONArray(Response.FindPath('result.events')).Count)
      .ToBe(1);
    Expect<string>(Str(Response, 'result.hasMore')).ToBe('false');
  finally
    Response.Free;
  end;
end;

// "truncated: true is the single signal that ... events were skipped";
// an event type without replay sends cursor null and truncated false.
procedure TEventsSuite.TestTruncatedAndNoReplay;
var
  Response: TJSONObject;
begin
  RegisterFixture;
  Response := Poll('"name":"clock.tick","cursor":"old"');
  try
    Expect<string>(Str(Response, 'result.truncated')).ToBe('true');
    Expect<string>(Str(Response, 'result.cursor')).ToBe('"5"');
  finally
    Response.Free;
  end;
  Response := Poll('"name":"no.replay","cursor":null');
  try
    Expect<string>(Str(Response, 'result.cursor')).ToBe('null');
    Expect<string>(Str(Response, 'result.truncated')).ToBe('false');
    Expect<string>(Str(Response, 'result.nextPollMs')).ToBe('1000');
  finally
    Response.Free;
  end;
end;

// "A server SDK generates an eventId only when the author supplies
// none": derived from the name, timestamp and data (Python's hashlib
// over the same bytes), so a repeat poll keeps it.
procedure TEventsSuite.TestDerivedEventId;
var
  Response: TJSONObject;
begin
  RegisterFixture;
  Response := Poll('"name":"derived.id","cursor":"0"');
  try
    // sha256("derived.id\0" + timestamp + "\0" + canonical data) from
    // Python's hashlib, the canonical data being {"n":1}.
    Expect<string>(Str(Response, 'result.events[0].eventId'))
      .ToBe('"evt_181c4d23d529a533a0fa1c744107abf4"');
  finally
    Response.Free;
  end;
  // Member order does not change the id (#118 review).
  Response := Poll('"name":"derived.id","cursor":"0","arguments":' +
    '{"order":"ba"}');
  try
    Expect<string>(Str(Response, 'result.events[0].eventId'))
      .ToBe(Str(Response, 'result.events[1].eventId'));
  finally
    Response.Free;
  end;
end;

function ErrorOf(AResponse: TJSONObject): string;
begin
  try
    Result := Str(AResponse, 'error.code') + ' ' + Str(AResponse,
      'error.message') + ' ' + Str(AResponse, 'error.data');
  finally
    AResponse.Free;
  end;
end;

// events.mdx, Error Handling.
procedure TEventsSuite.TestErrors;
var
  Response: TJSONObject;
begin
  RegisterFixture;
  Expect<string>(ErrorOf(Poll('"name":"nope"'))).ToBe('-32023 "Event type ' +
    'not found" { "kind" : "event" }');
  Expect<string>(ErrorOf(Poll(''))).ToBe('-32602 "Invalid params: name ' +
    'must be a string" <absent>');
  Expect<string>(ErrorOf(Poll('"name":"clock.tick","cursor":3'))).ToBe(
    '-32602 "Invalid params: cursor must be a string or null" <absent>');
  Expect<string>(ErrorOf(Poll('"name":"clock.tick","maxEvents":-1'))).ToBe(
    '-32602 "Invalid params: maxEvents must be an integer of at least 1" ' +
    '<absent>');
  // Zero could never move a cursor on (#118 review).
  Expect<string>(ErrorOf(Poll('"name":"clock.tick","maxEvents":0'))).ToBe(
    '-32602 "Invalid params: maxEvents must be an integer of at least 1" ' +
    '<absent>');
  Expect<string>(ErrorOf(Poll('"name":"clock.tick","maxAgeMs":1.5'))).ToBe(
    '-32602 "Invalid params: maxAgeMs must be an integer of at least 0" ' +
    '<absent>');
  Expect<string>(ErrorOf(Poll('"name":"clock.tick","arguments":[]'))).ToBe(
    '-32602 "Invalid params: arguments must be an object" <absent>');
  Expect<Boolean>(Pos('-32602', ErrorOf(Poll('"name":"clock.tick",' +
    '"arguments":{"region":7}'))) = 1).ToBe(True);
  // A check's own protocol errors go out as written, the SEP-3415 codes
  // included.
  Expect<string>(ErrorOf(Poll('"name":"faulty","cursor":"0","arguments":' +
    '{"fault":"refuse"}'))).ToBe('-32024 "Forbidden" { "reason" : ' +
    '"not yours" }');
  // An integral float is the integer it spells, as the schema reads it.
  Response := Poll('"name":"clock.tick","cursor":"2","maxEvents":2e0,' +
    '"maxAgeMs":1e3');
  try
    Expect<Integer>(TJSONArray(Response.FindPath('result.events')).Count)
      .ToBe(2);
  finally
    Response.Free;
  end;
  Expect<string>(ErrorOf(Poll('"name":"faulty","cursor":"0","arguments":' +
    '{"fault":"exhausted"}'))).ToBe('-32025 "ResourceExhausted" ' +
    '{ "limit" : "subscriptions" }');
  Expect<string>(ErrorOf(Poll('"name":"faulty","cursor":"0","arguments":' +
    '{"fault":"unsupported"}'))).ToBe('-32026 "Unsupported" ' +
    '{ "feature" : "deliveryMode", "value" : "push" }');
  Expect<string>(ErrorOf(Poll('"name":"faulty","cursor":"0","arguments":' +
    '{"fault":"callback"}'))).ToBe('-32027 "CallbackEndpointError" ' +
    '{ "reason" : "timeout" }');
end;

// A check's mistakes are the server's: -32603, nothing sent.
procedure TEventsSuite.TestCheckMistakes;
begin
  RegisterFixture;
  Expect<Boolean>(Pos('-32603', ErrorOf(Poll('"name":"faulty","cursor":"0",' +
    '"arguments":{"fault":"payload"}'))) = 1).ToBe(True);
  Expect<Boolean>(Pos('-32603', ErrorOf(Poll('"name":"faulty","cursor":"0",' +
    '"arguments":{"fault":"timestamp"}'))) = 1).ToBe(True);
  Expect<Boolean>(Pos('-32603', ErrorOf(Poll('"name":"faulty","cursor":"0",' +
    '"maxEvents":1,"arguments":{"fault":"many"}'))) = 1).ToBe(True);
  // Events on a poll from now.
  Expect<Boolean>(Pos('-32603', ErrorOf(Poll('"name":"faulty",' +
    '"arguments":{"fault":"many"}'))) = 1).ToBe(True);
  // A date the calendar lacks, an eventId that is no string, a _meta
  // that is no object, and a cursor of the occurrence's own (#118
  // review).
  Expect<Boolean>(Pos('-32603', ErrorOf(Poll('"name":"faulty","cursor":"0",' +
    '"arguments":{"fault":"february"}'))) = 1).ToBe(True);
  Expect<Boolean>(Pos('-32603', ErrorOf(Poll('"name":"faulty","cursor":"0",' +
    '"arguments":{"fault":"idtype"}'))) = 1).ToBe(True);
  Expect<Boolean>(Pos('-32603', ErrorOf(Poll('"name":"faulty","cursor":"0",' +
    '"arguments":{"fault":"meta"}'))) = 1).ToBe(True);
  Expect<Boolean>(Pos('-32603', ErrorOf(Poll('"name":"faulty","cursor":"0",' +
    '"arguments":{"fault":"cursor"}'))) = 1).ToBe(True);
  // The same members stored as nil in code are caught too, and a
  // payload member stored as nil goes out and hashes as null.
  Expect<Boolean>(Pos('-32603', ErrorOf(Poll('"name":"faulty","cursor":"0",' +
    '"arguments":{"fault":"nilcursor"}'))) = 1).ToBe(True);
  Expect<Boolean>(Pos('-32603', ErrorOf(Poll('"name":"faulty","cursor":"0",' +
    '"arguments":{"fault":"nilmeta"}'))) = 1).ToBe(True);
  Expect<Boolean>(Pos('"extra" : null', Send('{"jsonrpc":"2.0","id":8,' +
    '"method":"events/poll","params":{"name":"faulty","cursor":"0",' +
    '"arguments":{"fault":"nildata"},' + META + '}}')) > 0).ToBe(True);
  // hasMore with a null cursor promises a page no poll can reach.
  Expect<Boolean>(Pos('-32603', ErrorOf(Poll('"name":"faulty","cursor":"0",' +
    '"arguments":{"fault":"noreplaymore"}'))) = 1).ToBe(True);
end;

// The extension is defined for 2026-07-28: a classic client is told the
// methods do not exist.
procedure TEventsSuite.TestClassicEra;
begin
  FServer.DeclareExtension('com.example/kept');
  RegisterFixture;
  // The classic initialize declares the other extensions, not Events
  // (#118 review); server/discover declares both.
  Expect<Boolean>(Pos('"extensions" : { "com.example/kept" : {} }',
    Send('{"jsonrpc":"2.0","id":1,"method":"initialize","params":' +
    '{"protocolVersion":"2025-11-25","capabilities":{},' +
    '"clientInfo":{"name":"c","version":"1"}}}')) > 0).ToBe(True);
  Send('{"jsonrpc":"2.0","method":"notifications/initialized"}');
  Expect<string>(Send('{"jsonrpc":"2.0","id":2,"method":"events/poll",' +
    '"params":{"name":"clock.tick"}}')).ToBe('{ "jsonrpc" : "2.0", "id" : 2, ' +
    '"error" : { "code" : -32601, "message" : "Method not found: ' +
    'events/poll" } }');
  FreeAndNil(FSession);
  Expect<Boolean>(Pos('"extensions" : { "com.example/kept" : {}, ' +
    '"io.modelcontextprotocol/events" : {} }', Send('{"jsonrpc":"2.0",' +
    '"id":3,"method":"server/discover","params":{' + META + '}}')) > 0)
    .ToBe(True);
end;

// listChanged needs subscriptions/listen: the declaration stays {}
// whether it is declared before or after (#118 review).
procedure TEventsSuite.TestSettingsPinned;
const
  DISCOVER = '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{' +
    META + '}}';
var
  Line: string;
begin
  FServer.DeclareExtension('io.modelcontextprotocol/events',
    TJSONObject.Create(['listChanged', True]));
  RegisterFixture;
  FServer.DeclareExtension('io.modelcontextprotocol/events',
    TJSONObject.Create(['listChanged', True]));
  // A pin declares on its own, nil settings as {}.
  FServer.PinExtensionSettings('com.example/pinned', nil);
  Line := Send(DISCOVER);
  Expect<Boolean>(Pos('"io.modelcontextprotocol/events" : {}', Line) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('"com.example/pinned" : {}', Line) > 0).ToBe(True);
end;

// events/list pages with PageSize; the cursor leads to the last page.
procedure TEventsSuite.TestListPaging;
var
  Response: TJSONObject;
  Cursor: string;
begin
  FServer.PageSize := 3;
  RegisterFixture;
  if FClient = nil then
    FClient := TMCPTestClient.Create(FServer);
  Response := FClient.Request('events/list', '{}');
  try
    Expect<Integer>(TJSONArray(Response.FindPath('result.events')).Count)
      .ToBe(3);
    Cursor := TJSONData(Response.FindPath('result.nextCursor')).AsString;
  finally
    Response.Free;
  end;
  Response := FClient.Request('events/list', '{"cursor":"' + Cursor + '"}');
  try
    Expect<Integer>(TJSONArray(Response.FindPath('result.events')).Count)
      .ToBe(1);
    Expect<string>(Str(Response, 'result.events[0].name')).ToBe('"faulty"');
    Expect<Boolean>(Response.FindPath('result.nextCursor') = nil).ToBe(True);
  finally
    Response.Free;
  end;
end;

// An occurrence with non-ASCII data, byte-exact on the wire.
procedure TEventsSuite.TestUtf8Occurrence;
begin
  RegisterFixture;
  Expect<Boolean>(Pos('"events" : [{ "eventId" : "u", "timestamp" : ' +
    '"2026-11-27T10:00:00Z", "data" : { "n" : 1, "note" : "' + GRUSSE +
    '" }, "name" : "faulty" }]', Send('{"jsonrpc":"2.0","id":7,' +
    '"method":"events/poll","params":{"name":"faulty","cursor":"0",' +
    '"arguments":{"fault":"utf8"},' + META + '}}')) > 0).ToBe(True);
end;

// The header parameters a route hands out are a copy (#118 review).
procedure TEventsSuite.TestRouteCopy;
var
  NameParam: string;
  Lookup: TMCPHeaderLookup;
  Params: TMCPHeaderParameters;
begin
  RegisterFixture;
  Expect<Boolean>(FServer.MethodRoute('events/poll', NameParam, Lookup))
    .ToBe(True);
  Expect<string>(NameParam).ToBe('name');
  Params := Lookup('clock.tick');
  Expect<Integer>(Length(Params)).ToBe(1);
  Params[0].Header := 'Changed';
  Params[0].Path[0] := 'changed';
  Expect<string>(Lookup('clock.tick')[0].Header).ToBe('Region');
  Expect<string>(Lookup('clock.tick')[0].Path[0]).ToBe('region');
end;

var
  GuardServer: TMCPServer;

function Refused(const AName, AInputSchema: string): Boolean;
begin
  Result := False;
  try
    RegisterEvent(GuardServer, AName, 'd', TJSONObject(MCPParseJSON(
      AInputSchema)), ObjectSchema.Build, ClockCheck);
  except
    on E: EMCPServer do
      Result := True;
  end;
end;

procedure TEventsSuite.TestGuards;
var
  Raised: Boolean;
  Built: TJSONObject;
begin
  GuardServer := FServer;
  try
    Expect<Boolean>(Refused('', '{"type":"object"}')).ToBe(True);
    Expect<Boolean>(Refused('a', '{"type":"string"}')).ToBe(True);
    Expect<Boolean>(Refused('a', '{"type":"object","properties":{"r":' +
      '{"type":"object","x-mcp-header":"R"}}}')).ToBe(True);
    // Outside the subset the server checks arguments against.
    Expect<Boolean>(Refused('a', '{"type":"object","properties":{"r":' +
      '{"type":"string","pattern":"^x"}}}')).ToBe(True);
    // An x-mcp-header stored as nil in code is a null, refused as one
    // (#118 review).
    Built := TJSONObject(MCPParseJSON('{"type":"object","properties":{"r":' +
      '{"type":"string"}}}'));
    TJSONObject(Built.FindPath('properties.r')).Add('x-mcp-header',
      TJSONData(nil));
    Raised := False;
    try
      RegisterEvent(FServer, 'a', 'd', Built, ObjectSchema.Build, ClockCheck);
    except
      on E: EMCPServer do
        Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
    // A root type stored as nil, then set through Items[], is read
    // after the clone that rebuilds the lookup (#118 review).
    Built := TJSONObject.Create;
    Built.Add('type', TJSONData(nil));
    Built.Items[0] := TJSONString.Create('object');
    RegisterEvent(FServer, 'replaced', 'd', Built, ObjectSchema.Build,
      ClockCheck);
    Expect<Boolean>(Refused('a', '{"type":"object"}')).ToBe(False);
    Expect<Boolean>(Refused('a', '{"type":"object"}')).ToBe(True);
    Raised := False;
    try
      RegisterEvent(FServer, 'b', 'd', ObjectSchema, ObjectSchema,
        TMCPEventCheck(nil));
    except
      on E: EMCPServer do
        Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
    Send('{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{' +
      META + '}}');
    Expect<Boolean>(Refused('late', '{"type":"object"}')).ToBe(True);
  finally
    GuardServer := nil;
  end;
end;

procedure TEventsSuite.SetupTests;
begin
  Test('the extension is declared with {}', TestDeclaration);
  Test('events/list: types, poll and push delivery, schemas, non-ASCII',
    TestList);
  Test('a poll from now: no events and a fresh cursor', TestPollFromNow);
  Test('a poll from a cursor, maxEvents and hasMore', TestPollFromCursor);
  Test('truncated, and cursor null for a type without replay',
    TestTruncatedAndNoReplay);
  Test('an eventId the author leaves out is derived', TestDerivedEventId);
  Test('unknown types, bad parameters and a check''s own error',
    TestErrors);
  Test('a check''s mistakes answer -32603', TestCheckMistakes);
  Test('a classic client gets -32601', TestClassicEra);
  Test('names, schemas, checks and late registrations are guarded',
    TestGuards);
  Test('events/list pages to its last page', TestListPaging);
  Test('a non-ASCII occurrence goes out byte-exact', TestUtf8Occurrence);
  Test('a route''s header parameters are a copy', TestRouteCopy);
  Test('the Events declaration stays {} whatever else declares it',
    TestSettingsPinned);
  Test('events/list for one type is one exact line', TestListLine);
end;

{ ───────── push delivery (#126) ───────── }

var
  // The push upstream: occurrences at positions 1 .. UpstreamHead, and
  // a fault the next check call shows ('' for none; 'gap' is spent by
  // one call).
  UpstreamHead: Integer;
  PushFault: string;
  ReplayCursors: string; // the cursors the no-replay check was given
  Captured: string;      // the lines the capture sink took
  AgeLog: string;        // the maxAgeMs each push check call was given
  FakeNow: Int64;        // the streams' clock in these tests
  ProbeCancelled: Boolean; // what the test's cancel probe reports
  SawCancel: Boolean;    // a waiting check saw IsCancelled turn true

function TestClock: Int64;
begin
  Result := FakeNow;
end;

type
  TTestProbe = class
    function Cancelled: Boolean;
  end;

function TTestProbe.Cancelled: Boolean;
begin
  Result := ProbeCancelled;
end;

procedure CaptureSink(const ALine: string; AUserData: Pointer);
begin
  Captured := Captured + ALine + #10;
end;

// Faults that raise, or that make the check behave as a slow, chatty
// or cooperative one.
procedure PushRaise(const ACtx: TMCPRequestContext);
var
  I: Integer;
begin
  if PushFault = 'boom' then
    raise Exception.Create('upstream 503');
  if PushFault = 'servererr' then
    raise EMCPServer.Create('the check''s own EMCPServer');
  if PushFault = 'forbid' then
    raise EMCPProtocolError.Create(-32024, 'Forbidden',
      TJSONObject.Create(['reason', 'Access revoked']));
  if PushFault = 'forbidarray' then
    raise EMCPProtocolError.Create(-32024, 'Forbidden',
      TJSONArray.Create([1]));
  if PushFault = 'chatty' then
    MCPLogMessage(ACtx, 'error', 'from the check');
  if PushFault = 'slow' then
    Inc(FakeNow, 5000);
  // The cancellation arrives while the check runs, which then waits for
  // IsCancelled.
  if PushFault = 'wait' then
    ProbeCancelled := True;
  if PushFault = 'wait' then
    for I := 1 to 1000 do
      if ACtx.IsCancelled then
      begin
        SawCancel := True;
        Break;
      end;
end;

function PushCheck(const AQuery: TMCPEventQuery;
  const ACtx: TMCPRequestContext): TMCPEventPoll;
var
  From, Last, I: Integer;
begin
  AgeLog := AgeLog + IntToStr(AQuery.MaxAgeMs) + ',';
  PushRaise(ACtx);
  Result := MCPEventPoll(IntToStr(UpstreamHead), TJSONArray.Create);
  Result.NextPollMs := 1000;
  if PushFault = 'interval5' then
    Result.NextPollMs := 5000;
  if AQuery.FromNow then
    Exit;
  // More waiting, none delivered yet: the backlog keeps draining.
  if PushFault = 'stall' then
  begin
    Result.HasMore := True;
    Result.Cursor := AQuery.Cursor;
    Exit;
  end;
  if PushFault = 'gap' then
  begin
    PushFault := '';
    Result.Truncated := True;
    Exit;
  end;
  // A gap with the first retained occurrence after it, its resume
  // position given (gapevent) or not (gapevent0).
  if (PushFault = 'gapevent') or (PushFault = 'gapevent0') then
  begin
    if PushFault = 'gapevent' then
      Result.GapCursor := IntToStr(UpstreamHead - 1);
    PushFault := '';
    Result.Truncated := True;
    Result.Events.Add(MCPEventOccurrence('e' + IntToStr(UpstreamHead),
      '2026-11-27T10:00:00Z', TJSONObject.Create(['n', UpstreamHead])));
    Exit;
  end;
  if PushFault = 'mistake' then
  begin
    Result.Events.Add(MCPEventOccurrence('m', 'yesterday',
      TJSONObject.Create(['n', 0])));
    Exit;
  end;
  From := StrToInt(AQuery.Cursor) + 1;
  Last := UpstreamHead;
  if (AQuery.MaxEvents >= 0) and (From + AQuery.MaxEvents - 1 < Last) then
  begin
    Last := From + AQuery.MaxEvents - 1;
    Result.HasMore := True;
  end;
  for I := From to Last do
    Result.Events.Add(MCPEventOccurrence('e' + IntToStr(I),
      '2026-11-27T10:0' + IntToStr(I) + ':00Z', TJSONObject.Create(['n', I])));
  if Last >= From then
    Result.Cursor := IntToStr(Last);
end;

// No replay: the position stays the server's (p0, p1, ...), and one
// occurrence waits at p0.
function NoReplayPushCheck(const AQuery: TMCPEventQuery;
  const ACtx: TMCPRequestContext): TMCPEventPoll;
begin
  ReplayCursors := ReplayCursors + '[' + AQuery.Cursor + ']';
  Result := MCPEventPoll('p0', TJSONArray.Create);
  Result.NoReplay := True;
  Result.NextPollMs := 1000;
  // A cursor the client brought, with more waiting behind it.
  if AQuery.Cursor = 'zzz' then
  begin
    Result.Events.Add(MCPEventOccurrence('x0', '2026-11-27T10:00:00Z',
      TJSONObject.Create(['n', 0])));
    Result.HasMore := True;
  end
  else if AQuery.Cursor = 'p0' then
  begin
    Result.Events.Add(MCPEventOccurrence('x', '2026-11-27T10:00:00Z',
      TJSONObject.Create(['n', 1])));
    Result.Cursor := 'p1';
  end;
end;

function QuietCheck(const AQuery: TMCPEventQuery;
  const ACtx: TMCPRequestContext): TMCPEventPoll;
begin
  Result := MCPEventPoll('0');
end;

// A sink as slow as three seconds of the test clock.
procedure SlowSink(const ALine: string; AUserData: Pointer);
begin
  Captured := Captured + ALine + #10;
  Inc(FakeNow, 3000);
end;

type
  TPushSuite = class(TTestSuite)
  private
    FServer: TMCPServer;
    FSession: TMCPSession;
    FHost: TMCPStreamHost;
    FStream: TMCPStream;
    // events/stream with AParams; the response line, and the stream
    // parked (nil when the request was refused).
    function Open(const AParams: string; const AId: string = '7';
      const AMeta: string = META): string;
    function Step(ANowMs: Int64): Int64;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;
    procedure TestOpenWithBacklog;
    procedure TestHeartbeatThenEvent;
    procedure TestHeartbeatGrant;
    procedure TestGapMidStream;
    procedure TestTransientError;
    procedure TestTerminated;
    procedure TestMistakeTerminates;
    procedure TestNoReplay;
    procedure TestImmediateErrors;
    procedure TestStringIdAndClose;
    procedure TestGapBeforeAnEvent;
    procedure TestFirstCheckQuiet;
    procedure TestCheckSeesCancellation;
    procedure TestCheckEMCPServerRetries;
    procedure TestReplayFloorWhileCatchingUp;
    procedure TestNoReplayCursorAndHasMore;
    procedure TestScheduleFromCheckCompletion;
    procedure TestTerminatedDataIsAnObject;
    procedure TestCutoffAnchoredWhileDraining;
    procedure TestNoIntervalIsTheDefault;
    procedure TestIntervalNotDelayedByWrites;
  end;

procedure TPushSuite.BeforeEach;
begin
  UpstreamHead := 3;
  PushFault := '';
  ReplayCursors := '';
  Captured := '';
  AgeLog := '';
  FakeNow := 0;
  ProbeCancelled := False;
  SawCancel := False;
  FServer := TMCPServer.Create('events', '1.0');
  RegisterEvent(FServer, 'tick', 'Ticks',
    ObjectSchema.AddString('region', '', False).Build,
    ObjectSchema.AddInteger('n').Build, PushCheck);
  RegisterEvent(FServer, 'pulse', 'No replay', ObjectSchema,
    ObjectSchema.AddInteger('n'), NoReplayPushCheck);
  RegisterEvent(FServer, 'quiet', 'No interval', ObjectSchema, ObjectSchema,
    QuietCheck, 0);
  FSession := FServer.CreateSession;
  FHost := TMCPStreamHost.Create;
  FSession.StreamHost := FHost;
  FStream := nil;
end;

procedure TPushSuite.AfterEach;
begin
  FreeAndNil(FStream);
  FreeAndNil(FSession);
  FreeAndNil(FHost);
  FreeAndNil(FServer);
end;

function TPushSuite.Open(const AParams, AId, AMeta: string): string;
begin
  FServer.HandleMessage(FSession, '{"jsonrpc":"2.0","id":' + AId +
    ',"method":"events/stream","params":{' + AParams + AMeta + '}}',
    CaptureSink, nil, Result);
  FStream := FHost.TakeParked;
  if FStream <> nil then
    FStream.Clock := @TestClock;
end;

function TPushSuite.Step(ANowMs: Int64): Int64;
begin
  Captured := '';
  FakeNow := ANowMs;
  Result := FStream.Step(CaptureSink, nil);
end;

const
  SUB = '"_meta" : { "io.modelcontextprotocol/subscriptionId" : 7 }';

// The first frame is active with the client's own cursor; each backlog
// occurrence follows with the exact cursor after it (one per check
// call, hasMore read on at once); then the check waits nextPollMs.
procedure TPushSuite.TestOpenWithBacklog;
begin
  Open('"name":"tick","cursor":"1",');
  Expect<Boolean>(FStream <> nil).ToBe(True);
  Expect<Int64>(Step(0)).ToBe(1000);
  Expect<string>(Captured).ToBe(
    '{ "jsonrpc" : "2.0", "method" : "notifications/events/active", ' +
    '"params" : { "cursor" : "1", "truncated" : false, "heartbeatMs" : ' +
    '30000, ' + SUB + ' } }'#10 +
    '{ "jsonrpc" : "2.0", "method" : "notifications/events/event", ' +
    '"params" : { "eventId" : "e2", "timestamp" : "2026-11-27T10:02:00Z", ' +
    '"data" : { "n" : 2 }, "name" : "tick", "cursor" : "2", ' + SUB +
    ' } }'#10 +
    '{ "jsonrpc" : "2.0", "method" : "notifications/events/event", ' +
    '"params" : { "eventId" : "e3", "timestamp" : "2026-11-27T10:03:00Z", ' +
    '"data" : { "n" : 3 }, "name" : "tick", "cursor" : "3", ' + SUB +
    ' } }'#10);
end;

// A stream from now opens with the fresh cursor; nothing new until the
// heartbeat, which carries the position checked up to; then a new
// occurrence.
procedure TPushSuite.TestHeartbeatThenEvent;
begin
  Open('"name":"tick",');
  Step(0);
  Expect<Boolean>(Pos('"cursor" : "3", "truncated" : false', Captured) > 0)
    .ToBe(True);
  Expect<Int64>(Step(1000)).ToBe(2000);
  Expect<string>(Captured).ToBe('');
  Step(30000);
  Expect<string>(Captured).ToBe('{ "jsonrpc" : "2.0", "method" : ' +
    '"notifications/events/heartbeat", "params" : { "cursor" : "3", ' + SUB +
    ' } }'#10);
  UpstreamHead := 4;
  Step(31000);
  Expect<Boolean>(Pos('"eventId" : "e4"', Captured) > 0).ToBe(True);
  Expect<Boolean>(Pos('"cursor" : "4"', Captured) > 0).ToBe(True);
end;

// The grant is authoritative: a suggestion is clamped to 1 s .. 5 min
// (events.mdx, Lifecycle), and the heartbeat follows the grant.
procedure TPushSuite.TestHeartbeatGrant;
begin
  Open('"name":"tick","heartbeatMs":10,');
  Step(0);
  Expect<Boolean>(Pos('"heartbeatMs" : 1000,', Captured) > 0).ToBe(True);
  Step(1000);
  Expect<Boolean>(Pos('notifications/events/heartbeat', Captured) > 0)
    .ToBe(True);
  FreeAndNil(FStream);
  Open('"name":"tick","heartbeatMs":1e9,');
  Step(0);
  Expect<Boolean>(Pos('"heartbeatMs" : 300000,', Captured) > 0).ToBe(True);
  FreeAndNil(FStream);
  Open('"name":"tick","heartbeatMs":5000,');
  Step(0);
  Expect<Boolean>(Pos('"heartbeatMs" : 5000,', Captured) > 0).ToBe(True);
end;

// A gap mid-stream is a fresh active with truncated and the position
// the server resumed from; the stream goes on.
procedure TPushSuite.TestGapMidStream;
begin
  Open('"name":"tick","cursor":"3",');
  Step(0);
  UpstreamHead := 6;
  PushFault := 'gap';
  Step(1000);
  Expect<string>(Captured).ToBe('{ "jsonrpc" : "2.0", "method" : ' +
    '"notifications/events/active", "params" : { "cursor" : "6", ' +
    '"truncated" : true, "heartbeatMs" : 30000, ' + SUB + ' } }'#10);
  Expect<Boolean>(FStream.Finished).ToBe(False);
end;

// A failure that is not a protocol error is recoverable: an error
// notification, and the next interval tries again.
procedure TPushSuite.TestTransientError;
begin
  Open('"name":"tick","cursor":"3",');
  Step(0);
  PushFault := 'boom';
  Expect<Int64>(Step(1000)).ToBe(2000);
  Expect<string>(Captured).ToBe('{ "jsonrpc" : "2.0", "method" : ' +
    '"notifications/events/error", "params" : { "error" : { "code" : ' +
    '-32603, "message" : "Internal error" }, ' + SUB + ' } }'#10);
  PushFault := '';
  UpstreamHead := 4;
  Step(2000);
  Expect<Boolean>(Pos('"eventId" : "e4"', Captured) > 0).ToBe(True);
end;

// A protocol error from the check ends the subscription: terminated
// with its code, message and data, then the final frame.
procedure TPushSuite.TestTerminated;
begin
  Open('"name":"tick","cursor":"3",');
  Step(0);
  PushFault := 'forbid';
  Step(1000);
  Expect<string>(Captured).ToBe('{ "jsonrpc" : "2.0", "method" : ' +
    '"notifications/events/terminated", "params" : { "error" : { "code" : ' +
    '-32024, "message" : "Forbidden", "data" : { "reason" : ' +
    '"Access revoked" } }, ' + SUB + ' } }'#10 +
    '{ "jsonrpc" : "2.0", "id" : 7, "result" : { "resultType" : ' +
    '"complete", "_meta" : { "io.modelcontextprotocol/subscriptionId" : 7 ' +
    '} } }'#10);
  Expect<Boolean>(FStream.Finished).ToBe(True);
end;

// A result that breaks the occurrence rules is the server's mistake,
// and would recur: the stream terminates with -32603.
procedure TPushSuite.TestMistakeTerminates;
begin
  Open('"name":"tick","cursor":"3",');
  Step(0);
  PushFault := 'mistake';
  Step(1000);
  Expect<string>(Captured).ToBe('{ "jsonrpc" : "2.0", "method" : ' +
    '"notifications/events/terminated", "params" : { "error" : { "code" : ' +
    '-32603, "message" : "Internal error" }, ' + SUB + ' } }'#10 +
    '{ "jsonrpc" : "2.0", "id" : 7, "result" : { "resultType" : ' +
    '"complete", ' + SUB + ' } }'#10);
  Expect<Boolean>(FStream.Finished).ToBe(True);
end;

// A type without replay sends cursor null everywhere and no truncated,
// while the stream keeps the check's own position between calls.
procedure TPushSuite.TestNoReplay;
begin
  Open('"name":"pulse",');
  Step(0);
  Expect<Boolean>(Pos('"cursor" : null, "truncated" : false', Captured) > 0)
    .ToBe(True);
  Step(1000);
  Expect<Boolean>(Pos('"eventId" : "x"', Captured) > 0).ToBe(True);
  Expect<Boolean>(Pos('"cursor" : null, ' + SUB, Captured) > 0).ToBe(True);
  Expect<string>(ReplayCursors).ToBe('[][p0]');
end;

// An invalid subscription is the immediate JSON-RPC error and no stream
// (events.mdx, Event delivery); a transport that cannot stream gets
// -32026; a classic client -32601.
procedure TPushSuite.TestImmediateErrors;
var
  Session: TMCPSession;
  Line: string;
begin
  Expect<Boolean>(Pos('"code" : -32023', Open('"name":"none",')) > 0)
    .ToBe(True);
  Expect<Boolean>(FStream = nil).ToBe(True);
  Expect<Boolean>(Pos('"code" : -32602', Open('"name":"tick",' +
    '"arguments":{"region":1},')) > 0).ToBe(True);
  Expect<Boolean>(Pos('"code" : -32602', Open('"name":"tick",' +
    '"heartbeatMs":-1,')) > 0).ToBe(True);
  PushFault := 'forbid';
  Line := Open('"name":"tick","cursor":"1",');
  Expect<string>(Line).ToBe('{ "jsonrpc" : "2.0", "id" : 7, "error" : { ' +
    '"code" : -32024, "message" : "Forbidden", "data" : { "reason" : ' +
    '"Access revoked" } } }');
  Expect<Boolean>(FStream = nil).ToBe(True);
  PushFault := '';
  Session := FServer.CreateSession;
  try
    FServer.HandleMessage(Session, '{"jsonrpc":"2.0","id":8,"method":' +
      '"events/stream","params":{"name":"tick",' + META + '}}', Line);
  finally
    Session.Free;
  end;
  Expect<string>(Line).ToBe('{ "jsonrpc" : "2.0", "id" : 8, "error" : { ' +
    '"code" : -32026, "message" : "Unsupported", "data" : { "feature" : ' +
    '"deliveryMode", "value" : "push" } } }');
end;

// A string id is the subscription id as it is; Close is the final frame
// the server sends when it ends the stream.
procedure TPushSuite.TestStringIdAndClose;
begin
  Open('"name":"tick",', '"s-1"');
  Step(0);
  Expect<Boolean>(Pos('"io.modelcontextprotocol/subscriptionId" : "s-1"',
    Captured) > 0).ToBe(True);
  Captured := '';
  FStream.Close(CaptureSink, nil);
  Expect<Boolean>(Pos('{ "jsonrpc" : "2.0", "id" : "s-1", "result" : ',
    Captured) = 1).ToBe(True);
  Expect<Boolean>(FStream.Finished).ToBe(True);
end;

// A gap whose first retained occurrence follows: active carries the
// position before it, the check's GapCursor or else the cursor the
// stream had, so a client that persists it and reconnects is sent the
// occurrence again, never past it (#126 review).
procedure TPushSuite.TestGapBeforeAnEvent;
begin
  Open('"name":"tick","cursor":"3",');
  Step(0);
  UpstreamHead := 6;
  PushFault := 'gapevent';
  Step(1000);
  Expect<Boolean>(Pos('"cursor" : "5", "truncated" : true', Captured) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('"eventId" : "e6"', Captured) >
    Pos('notifications/events/active', Captured)).ToBe(True);
  Expect<Boolean>(Pos('"cursor" : "6", ' + SUB, Captured) > 0).ToBe(True);
  // Without a GapCursor the cursor is the fresh one, after the event:
  // the event is part of the gap truncated signals.
  PushFault := 'gapevent0';
  UpstreamHead := 8;
  Step(2000);
  Expect<Boolean>(Pos('"cursor" : "8", "truncated" : true', Captured) > 0)
    .ToBe(True);
  // Reconnecting from the gap's position delivers the occurrence.
  FreeAndNil(FStream);
  UpstreamHead := 6;
  Open('"name":"tick","cursor":"5",');
  Step(0);
  Expect<Boolean>(Pos('"eventId" : "e6"', Captured) > 0).ToBe(True);
end;

// The first check runs without a notifier, so a check that logs cannot
// open the transport's response before the stream does, whether the
// subscription is accepted or refused (#126 review).
procedure TPushSuite.TestFirstCheckQuiet;
const
  LOUD = '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{},' +
    '"io.modelcontextprotocol/logLevel":"debug","progressToken":"p"}';
var
  Line: string;
begin
  PushFault := 'chatty';
  Captured := '';
  Open('"name":"tick","cursor":"3",', '7', LOUD);
  Expect<string>(Captured).ToBe('');
  Expect<Boolean>(FStream <> nil).ToBe(True);
  FreeAndNil(FStream);
  PushFault := 'forbid';
  Line := Open('"name":"tick","cursor":"3",', '8', LOUD);
  Expect<string>(Captured).ToBe('');
  Expect<Boolean>(Pos('"code" : -32024', Line) > 0).ToBe(True);
end;

// A later check that waits on IsCancelled sees the transport's probe,
// and nothing is written after the cancellation (#126 review).
procedure TPushSuite.TestCheckSeesCancellation;
var
  Probe: TTestProbe;
begin
  Probe := TTestProbe.Create;
  try
    Open('"name":"tick","cursor":"3",');
    FStream.CancelProbe := Probe.Cancelled;
    Step(0);
    // The probe turns true only once the check is running.
    PushFault := 'wait';
    UpstreamHead := 4;
    Step(1000);
    Expect<Boolean>(SawCancel).ToBe(True);
    Expect<string>(Captured).ToBe('');
    Expect<Boolean>(FStream.Finished).ToBe(True);
  finally
    FStream.CancelProbe := nil;
    Probe.Free;
  end;
end;

// An EMCPServer the check itself raises is an ordinary failure: an
// error notification and a retry, not the end (#126 review).
procedure TPushSuite.TestCheckEMCPServerRetries;
begin
  Open('"name":"tick","cursor":"3",');
  Step(0);
  PushFault := 'servererr';
  Step(1000);
  Expect<Boolean>(Pos('notifications/events/error', Captured) > 0)
    .ToBe(True);
  Expect<Boolean>(FStream.Finished).ToBe(False);
end;

// maxAgeMs bounds the whole first backlog, not only its first page,
// and is dropped once the stream has caught up (#126 review).
procedure TPushSuite.TestReplayFloorWhileCatchingUp;
begin
  Open('"name":"tick","cursor":"0","maxAgeMs":60000,');
  Step(0);
  Step(1000);
  Expect<string>(AgeLog).ToBe('60000,60000,60000,-1,');
end;

// A type without replay sends null from the first frame even when the
// client brought a cursor, and drains hasMore from its own position
// (#126 review).
procedure TPushSuite.TestNoReplayCursorAndHasMore;
begin
  Open('"name":"pulse","cursor":"zzz",');
  Step(0);
  Expect<Boolean>(Pos('"cursor" : null, "truncated" : false', Captured) > 0)
    .ToBe(True);
  Expect<Integer>(Pos('"zzz"', Captured)).ToBe(0);
  Expect<Boolean>(Pos('"eventId" : "x0"', Captured) > 0).ToBe(True);
  Expect<Boolean>(Pos('"eventId" : "x"', Captured) > 0).ToBe(True);
  Expect<string>(ReplayCursors).ToBe('[zzz][p0]');
end;

// The next check is timed from when the check returned, not from when
// the step began (#126 review).
procedure TPushSuite.TestScheduleFromCheckCompletion;
begin
  Open('"name":"tick","cursor":"3",');
  Step(0);
  PushFault := 'slow';
  Expect<Int64>(Step(1000)).ToBe(7000);
end;

// Error data that is no object is left out of terminated (events.mdx,
// Subscription Termination: data?: object).
procedure TPushSuite.TestTerminatedDataIsAnObject;
begin
  Open('"name":"tick","cursor":"3",');
  Step(0);
  PushFault := 'forbidarray';
  Step(1000);
  Expect<Boolean>(Pos('"error" : { "code" : -32024, "message" : ' +
    '"Forbidden" }', Captured) > 0).ToBe(True);
end;

// The replay cutoff holds where replay began: a page drained later
// gets an age grown by the time since (#126 review).
procedure TPushSuite.TestCutoffAnchoredWhileDraining;
begin
  PushFault := 'stall';
  Open('"name":"tick","cursor":"0","maxAgeMs":60000,');
  Step(0);
  Step(500);
  Expect<Boolean>(Pos('60500,', AgeLog) > 0).ToBe(True);
  Expect<Integer>(Pos('-1,', AgeLog)).ToBe(0);
end;

// A registration and a check with no interval do not make a quiet
// stream ask again at once (#126 review).
procedure TPushSuite.TestNoIntervalIsTheDefault;
begin
  Open('"name":"quiet",');
  Expect<Int64>(Step(0)).ToBe(30000);
end;

// Writes that take time do not delay the next check: it is timed from
// the check's return (#126 review).
procedure TPushSuite.TestIntervalNotDelayedByWrites;
begin
  Open('"name":"tick","cursor":"3",');
  Step(0);
  UpstreamHead := 4;
  PushFault := 'interval5';
  FakeNow := 1000;
  Captured := '';
  Expect<Int64>(FStream.Step(SlowSink, nil)).ToBe(6000);
  Expect<Boolean>(Pos('"eventId" : "e4"', Captured) > 0).ToBe(True);
end;

procedure TPushSuite.SetupTests;
begin
  Test('a stream opens with active, then the backlog one cursor each',
    TestOpenWithBacklog);
  Test('a heartbeat carries the checked position, then a new event',
    TestHeartbeatThenEvent);
  Test('the heartbeat grant is clamped and followed', TestHeartbeatGrant);
  Test('a gap mid-stream is a fresh active with truncated',
    TestGapMidStream);
  Test('a transient failure is an error notification and a retry',
    TestTransientError);
  Test('a protocol error terminates with the final frame', TestTerminated);
  Test('a check''s mistake terminates with -32603', TestMistakeTerminates);
  Test('a type without replay keeps its position off the wire',
    TestNoReplay);
  Test('invalid subscriptions answer at once; no host is -32026',
    TestImmediateErrors);
  Test('a string id is the subscription id; Close sends the final frame',
    TestStringIdAndClose);
  Test('a gap before an event resumes before it', TestGapBeforeAnEvent);
  Test('the first check runs without a notifier', TestFirstCheckQuiet);
  Test('a waiting check sees the transport''s cancellation',
    TestCheckSeesCancellation);
  Test('the check''s own EMCPServer is an error and a retry',
    TestCheckEMCPServerRetries);
  Test('maxAgeMs bounds the whole first backlog',
    TestReplayFloorWhileCatchingUp);
  Test('no replay: null from the first frame, hasMore drained',
    TestNoReplayCursorAndHasMore);
  Test('the next check is timed from the check''s return',
    TestScheduleFromCheckCompletion);
  Test('terminated carries object data only', TestTerminatedDataIsAnObject);
  Test('the replay cutoff holds while the backlog drains',
    TestCutoffAnchoredWhileDraining);
  Test('no interval is the default one', TestNoIntervalIsTheDefault);
  Test('writes do not delay the next check', TestIntervalNotDelayedByWrites);
end;

begin
  TestRunnerProgram.AddSuite(TEventsSuite.Create('Events: poll delivery'));
  TestRunnerProgram.AddSuite(TPushSuite.Create('Events: push delivery'));
  TestRunnerProgram.Run;
end.
