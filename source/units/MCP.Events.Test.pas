{ MCP.Events.Test — the Events extension (#118): the declaration,
  events/list, poll delivery from now and from a cursor, maxEvents and
  hasMore, truncation, event types without replay, derived event ids,
  the errors (-32023 for an unknown type, -32602 for bad parameters or
  arguments, -32601 for a classic client, -32603 for a check's
  mistakes) and the registration guards. Shapes verified 2026-11-27
  against modelcontextprotocol/ext-events
  specification/beta/events/events.mdx at c77b843. }

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

// What the arguments ask for goes wrong on purpose.
function FaultyCheck(const AQuery: TMCPEventQuery;
  const ACtx: TMCPRequestContext): TMCPEventPoll;
var
  Kind: string;
begin
  Kind := AQuery.Arguments.Get('fault', '');
  Result := MCPEventPoll('1', TJSONArray.Create);
  if Kind = 'payload' then
    Result.Events.Add(MCPEventOccurrence('x', '2026-11-27T10:00:00Z',
      TJSONObject.Create(['n', 'not a number'])))
  else if Kind = 'timestamp' then
    Result.Events.Add(MCPEventOccurrence('x', 'yesterday',
      TJSONObject.Create(['n', 1])))
  else if Kind = 'many' then
  begin
    Result.Events.Add(MCPEventOccurrence('x', '2026-11-27T10:00:00Z',
      TJSONObject.Create(['n', 1])));
    Result.Events.Add(MCPEventOccurrence('y', '2026-11-27T10:00:00Z',
      TJSONObject.Create(['n', 2])));
  end
  else if Kind = 'february' then
    Result.Events.Add(MCPEventOccurrence('x', '2026-02-31T10:00:00Z',
      TJSONObject.Create(['n', 1])))
  else if Kind = 'idtype' then
  begin
    Result.Events.Add(TJSONObject(MCPParseJSON('{"eventId":7,"timestamp":' +
      '"2026-11-27T10:00:00Z","data":{"n":1}}')));
  end
  else if Kind = 'meta' then
    Result.Events.Add(TJSONObject(MCPParseJSON('{"timestamp":' +
      '"2026-11-27T10:00:00Z","data":{"n":1},"_meta":[]}')))
  else if Kind = 'cursor' then
    Result.Events.Add(TJSONObject(MCPParseJSON('{"timestamp":' +
      '"2026-11-27T10:00:00Z","data":{"n":1},"cursor":"c"}')))
  else if Kind = 'utf8' then
    Result.Events.Add(MCPEventOccurrence('u', '2026-11-27T10:00:00Z',
      TJSONObject(MCPParseJSON('{"n":1,"note":"Gr\u00fc\u00dfe"}'))))
  else if Kind = 'refuse' then
  begin
    Result.Events.Free;
    raise EMCPProtocolError.Create(-32024, 'Forbidden',
      TJSONObject.Create(['reason', 'not yours']));
  end
  else if (Kind = 'exhausted') or (Kind = 'unsupported') or
    (Kind = 'callback') then
  begin
    Result.Events.Free;
    if Kind = 'exhausted' then
      raise EMCPProtocolError.Create(-32025, 'ResourceExhausted',
        TJSONObject.Create(['limit', 'subscriptions']))
    else if Kind = 'unsupported' then
      raise EMCPProtocolError.Create(-32026, 'Unsupported',
        TJSONObject.Create(['feature', 'deliveryMode', 'value', 'push']))
    else
      raise EMCPProtocolError.Create(-32027, 'CallbackEndpointError',
        TJSONObject.Create(['reason', 'timeout']));
  end;
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
    ': "Ticks of the clock, ' + GRUSSE + '", "delivery" : ["poll"], ' +
    '"inputSchema" : { "type" : "object", "properties" : { "region" : ' +
    '{ "type" : "string", "x-mcp-header" : "Region" } } }, "payloadSchema" : ' +
    '{ "type" : "object", "properties" : { "n" : { "type" : "integer" }, ' +
    '"region" : { "type" : "string" } }, "required" : ["n", "region"] } }, ' +
    '{ "name" : "no.replay"', Line) >
    0).ToBe(True);
  Expect<Boolean>(Pos('"resultType" : "complete"', Line) > 0).ToBe(True);
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
begin
  RegisterFixture;
  Expect<string>(ErrorOf(Poll('"name":"nope"'))).ToBe('-32023 "Event type ' +
    'not found" { "kind" : "event" }');
  Expect<string>(ErrorOf(Poll(''))).ToBe('-32602 "Invalid params: name ' +
    'must be a string" <absent>');
  Expect<string>(ErrorOf(Poll('"name":"clock.tick","cursor":3'))).ToBe(
    '-32602 "Invalid params: cursor must be a string or null" <absent>');
  Expect<string>(ErrorOf(Poll('"name":"clock.tick","maxEvents":-1'))).ToBe(
    '-32602 "Invalid params: maxEvents must be a non-negative integer" ' +
    '<absent>');
  Expect<string>(ErrorOf(Poll('"name":"clock.tick","maxAgeMs":1.5'))).ToBe(
    '-32602 "Invalid params: maxAgeMs must be a non-negative integer" ' +
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
  Expect<string>(Lookup('clock.tick')[0].Header).ToBe('Region');
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
begin
  GuardServer := FServer;
  try
    Expect<Boolean>(Refused('', '{"type":"object"}')).ToBe(True);
    Expect<Boolean>(Refused('a', '{"type":"string"}')).ToBe(True);
    Expect<Boolean>(Refused('a', '{"type":"object","properties":{"r":' +
      '{"type":"object","x-mcp-header":"R"}}}')).ToBe(True);
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
  Test('events/list: types, poll delivery, schemas, non-ASCII', TestList);
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
end;

begin
  TestRunnerProgram.AddSuite(TEventsSuite.Create('Events: poll delivery'));
  TestRunnerProgram.Run;
end.
