{ MCP.Server.Test — the full dispatch surface through HandleMessage,
  line in / line out, no transport: server/discover shape, tools/list /
  tools/call (success, structured content, handler exception → isError,
  unknown tool → -32602, missing arguments default to {}), resources
  (list, static read, dynamic reader, not found → -32602 + data.uri),
  the initialize rejection naming supported versions, method-not-found,
  notifications producing no response, malformed lines answered with
  the right JSON-RPC error, and registration guards (duplicate names,
  bad schema JSON → EMCPServer). }

program MCP.Server.Test;

{$I Shared.inc}

uses
  SysUtils,

  fpjson,
  jsonparser,
  MCP.JSONRPC,
  MCP.Protocol,
  MCP.Schema,
  MCP.Server,
  TestingPascalLibrary;

const
  META_MODERN =
    '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{}}';

type
  TDispatchSuite = class(TTestSuite)
  protected
    FServer: TMCPServer;
    procedure BeforeEach; override;
    procedure AfterEach; override;
    // One request through the server; parsed response (caller frees).
    function Call(const ALine: string): TJSONObject;
  end;

  TDiscoverAndErrors = class(TDispatchSuite)
  public
    procedure SetupTests; override;
    procedure TestDiscover;
    procedure TestInitializeRejected;
    procedure TestMethodNotFound;
    procedure TestNotificationSilent;
    procedure TestMalformedLine;
    procedure TestMissingMeta;
  end;

  TToolDispatch = class(TDispatchSuite)
  public
    procedure SetupTests; override;
    procedure TestList;
    procedure TestCallText;
    procedure TestCallStructured;
    procedure TestCallDefaultArguments;
    procedure TestCallHandlerRaises;
    procedure TestCallUnknown;
    procedure TestCallBadName;
    procedure TestTypedArgsBound;
    procedure TestTypedArgsMissing;
    procedure TestTypedArgsMistyped;
    procedure TestTypedArgsSchemaDerived;
  end;

  TResourceDispatch = class(TDispatchSuite)
  public
    procedure SetupTests; override;
    procedure TestList;
    procedure TestReadStatic;
    procedure TestReadDynamic;
    procedure TestReadNotFound;
  end;

  TRegistrationGuards = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestDuplicateTool;
    procedure TestBadSchema;
    procedure TestDuplicateResource;
  end;

  TLegacyEra = class(TDispatchSuite)
  private
    procedure DoInitialize(const AVersion: string);
  public
    procedure SetupTests; override;
    procedure TestKnownVersionEchoed;
    procedure TestUnknownVersionAnswersLatestLegacy;
    procedure TestInitializeResultShape;
    procedure TestRequestBeforeInitialize;
    procedure TestPingBeforeInitialize;
    procedure TestLegacyToolCall;
    procedure TestLegacyResponsesUnstamped;
    procedure TestLegacyContextVisibleToHandlers;
    procedure TestLegacyResourceNotFound;
    procedure TestErasServedConcurrently;
  end;

{ ───────── handlers under test ───────── }

function EchoHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPTextResult(AArguments.Get('message', '(no message)'));
end;

function SumHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Structured: TJSONObject;
begin
  Structured := TJSONObject.Create;
  Structured.Add('sum', AArguments.Get('a', 0.0) + AArguments.Get('b', 0.0));
  Result := MCPStructuredResult('sum computed', Structured);
end;

function BoomHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  raise Exception.Create('boom');
end;

// Mirrors the request context so era plumbing is handler-observable.
function WhoAmIHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPTextResult(ACtx.ProtocolVersion + '|' + ACtx.ClientName);
end;

type
  TScaleArgs = class(TMCPArgs)
  private
    FValue: Double;
    FTimes: Integer;
  published
    property value: Double read FValue write FValue;
    property times: Integer read FTimes write FTimes;
  end;

// Typed handler: binding has already validated and populated the
// instance, so this is arithmetic only.
function ScaleHandler(AArgs: TMCPArgs;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Args: TScaleArgs;
begin
  Args := AArgs as TScaleArgs;
  Result := MCPTextResult(FloatToStr(Args.value * Args.times));
end;

function ClockReader(const AUri: string;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  Result := MCPTextContents(AUri, 'text/plain', 'tick');
end;

{ ───────── shared fixture ───────── }

procedure TDispatchSuite.BeforeEach;
begin
  FServer := TMCPServer.Create('test-server', '9.9.9');
  FServer.Instructions := 'test instructions';
  FServer.RegisterTool('echo', 'Echo a message',
    '{"type":"object","properties":{"message":{"type":"string"}}}',
    EchoHandler);
  FServer.RegisterTool('sum', 'Add numbers',
    '{"type":"object","properties":{"a":{"type":"number"},' +
    '"b":{"type":"number"}}}',
    SumHandler);
  FServer.RegisterTool('boom', 'Always raises',
    '{"type":"object"}', BoomHandler);
  FServer.RegisterTool('whoami', 'Mirror the request context',
    '{"type":"object"}', WhoAmIHandler);
  FServer.RegisterTool('scale', 'Multiply value by times',
    TScaleArgs, ScaleHandler);
  FServer.RegisterTextResource('mem://static', 'static', 'text/plain',
    'static text');
  FServer.RegisterResource('mem://clock', 'clock', 'text/plain',
    ClockReader);
end;

procedure TDispatchSuite.AfterEach;
begin
  FreeAndNil(FServer);
end;

function TDispatchSuite.Call(const ALine: string): TJSONObject;
var
  Response: string;
begin
  if not FServer.HandleMessage(ALine, Response) then
    Fail('expected a response, got none');
  Result := TJSONObject(GetJSON(Response));
end;

{ ───────── discover + protocol errors ───────── }

procedure TDiscoverAndErrors.TestDiscover;
var
  Response: TJSONObject;
  ResultObj: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"server/discover",' +
    '"params":{' + META_MODERN + '}}');
  ResultObj := TJSONObject(Response.Find('result'));
  Expect<string>(ResultObj.Get('resultType', '')).ToBe('complete');
  Expect<string>(
    TJSONArray(ResultObj.Find('supportedVersions')).Strings[0])
    .ToBe(MCP_PROTOCOL_VERSION);
  Expect<Boolean>(
    ResultObj.FindPath('capabilities.tools') <> nil).ToBe(True);
  Expect<Boolean>(
    ResultObj.FindPath('capabilities.resources') <> nil).ToBe(True);
  Expect<string>(ResultObj.Get('instructions', '')).ToBe('test instructions');
  // serverInfo is a required TOP-LEVEL DiscoverResult field in the RC
  // wire schema (the official client beta rejects a discover result
  // without it), in addition to the _meta stamp.
  Expect<string>(
    TJSONObject(ResultObj.Find('serverInfo')).Get('name', ''))
    .ToBe('test-server');
  Expect<string>(
    TJSONObject(TJSONObject(ResultObj.Find('_meta'))
      .Find(META_KEY_SERVER_INFO)).Get('name', '')).ToBe('test-server');
  // CacheableResult fields (SEP-2549) are required on discover.
  Expect<Integer>(ResultObj.Get('ttlMs', -1)).ToBe(300000);
  Expect<string>(ResultObj.Get('cacheScope', '')).ToBe('private');
  Response.Free;
end;

procedure TDiscoverAndErrors.TestInitializeRejected;
var
  Response: TJSONObject;
begin
  // Modern-only posture: DualEra off restores the strict rejection.
  FServer.DualEra := False;
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"initialize",' +
    '"params":{"protocolVersion":"2025-11-25","capabilities":{}}}');
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(JSONRPC_METHOD_NOT_FOUND);
  // The reply MUST name the supported versions — the only diagnostic a
  // legacy client can surface.
  Expect<Boolean>(Pos(MCP_PROTOCOL_VERSION,
    TJSONObject(Response.Find('error')).Get('message', '')) > 0).ToBe(True);
  Response.Free;
end;

procedure TDiscoverAndErrors.TestMethodNotFound;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"no/such",' +
    '"params":{' + META_MODERN + '}}');
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(JSONRPC_METHOD_NOT_FOUND);
  Response.Free;
end;

procedure TDiscoverAndErrors.TestNotificationSilent;
var
  Response: string;
begin
  Expect<Boolean>(FServer.HandleMessage(
    '{"jsonrpc":"2.0","method":"notifications/cancelled",' +
    '"params":{"requestId":1}}', Response)).ToBe(False);
  Expect<string>(Response).ToBe('');
end;

procedure TDiscoverAndErrors.TestMalformedLine;
var
  Response: TJSONObject;
begin
  Response := Call('{broken');
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(JSONRPC_PARSE_ERROR);
  Expect<Integer>(Ord(Response.Find('id').JSONType)).ToBe(Ord(jtNull));
  Response.Free;
end;

procedure TDiscoverAndErrors.TestMissingMeta;
var
  Response: TJSONObject;
begin
  // Modern-only posture: a bare request is a malformed modern request
  // (-32602). In dual-era mode the same line is a legacy request and
  // gets the pre-initialization -32600 instead (see TLegacyEra).
  FServer.DualEra := False;
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/list",' +
    '"params":{}}');
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(JSONRPC_INVALID_PARAMS);
  Response.Free;
end;

procedure TDiscoverAndErrors.SetupTests;
begin
  Test('server/discover result shape', TestDiscover);
  Test('initialize rejected, versions named', TestInitializeRejected);
  Test('unknown method → -32601', TestMethodNotFound);
  Test('notification produces no response', TestNotificationSilent);
  Test('malformed line → -32700, id null', TestMalformedLine);
  Test('missing _meta → -32602', TestMissingMeta);
end;

{ ───────── tools ───────── }

procedure TToolDispatch.TestList;
var
  Response: TJSONObject;
  Tools: TJSONArray;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/list",' +
    '"params":{' + META_MODERN + '}}');
  Tools := TJSONArray(TJSONObject(Response.Find('result')).Find('tools'));
  Expect<Integer>(Tools.Count).ToBe(5);
  Expect<string>(TJSONObject(Tools[0]).Get('name', '')).ToBe('echo');
  Expect<Boolean>(
    TJSONObject(Tools[0]).Find('inputSchema') <> nil).ToBe(True);
  // Required CacheableResult fields (SEP-2549).
  Expect<Integer>(
    TJSONObject(Response.Find('result')).Get('ttlMs', -1)).ToBe(300000);
  Expect<string>(
    TJSONObject(Response.Find('result')).Get('cacheScope', ''))
    .ToBe('private');
  Response.Free;
end;

procedure TToolDispatch.TestCallText;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"echo","arguments":{"message":"hi"},' +
    META_MODERN + '}}');
  Expect<string>(
    TJSONData(Response.FindPath('result.content[0].text')).AsString)
    .ToBe('hi');
  Expect<Boolean>(
    TJSONData(Response.FindPath('result.isError')).AsBoolean).ToBe(False);
  Response.Free;
end;

procedure TToolDispatch.TestCallStructured;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"sum","arguments":{"a":2,"b":3},' +
    META_MODERN + '}}');
  Expect<Integer>(
    TJSONData(Response.FindPath('result.structuredContent.sum')).AsInteger)
    .ToBe(5);
  Response.Free;
end;

procedure TToolDispatch.TestCallDefaultArguments;
var
  Response: TJSONObject;
begin
  // arguments omitted entirely → handler sees an empty object.
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"echo",' + META_MODERN + '}}');
  Expect<string>(
    TJSONData(Response.FindPath('result.content[0].text')).AsString)
    .ToBe('(no message)');
  Response.Free;
end;

procedure TToolDispatch.TestCallHandlerRaises;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"boom",' + META_MODERN + '}}');
  // Execution error: in-band isError result, not a JSON-RPC error.
  Expect<Boolean>(Response.Find('error') = nil).ToBe(True);
  Expect<Boolean>(
    TJSONData(Response.FindPath('result.isError')).AsBoolean).ToBe(True);
  Expect<Boolean>(Pos('boom',
    TJSONData(Response.FindPath('result.content[0].text')).AsString) > 0)
    .ToBe(True);
  Response.Free;
end;

procedure TToolDispatch.TestCallUnknown;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"nope",' + META_MODERN + '}}');
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(JSONRPC_INVALID_PARAMS);
  Response.Free;
end;

procedure TToolDispatch.TestCallBadName;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":42,' + META_MODERN + '}}');
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(JSONRPC_INVALID_PARAMS);
  Response.Free;
end;

procedure TToolDispatch.TestTypedArgsBound;
var
  Response: TJSONObject;
begin
  // value=2.5, times=4 → the handler sees populated typed fields.
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"scale","arguments":{"value":2.5,"times":4},' +
    META_MODERN + '}}');
  Expect<string>(
    TJSONData(Response.FindPath('result.content[0].text')).AsString)
    .ToBe('10');
  Response.Free;
end;

procedure TToolDispatch.TestTypedArgsMissing;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"scale","arguments":{"value":2.5},' +
    META_MODERN + '}}');
  Expect<Boolean>(
    TJSONData(Response.FindPath('result.isError')).AsBoolean).ToBe(True);
  Expect<string>(
    TJSONData(Response.FindPath('result.content[0].text')).AsString)
    .ToBe('Missing required argument "times"');
  Response.Free;
end;

procedure TToolDispatch.TestTypedArgsMistyped;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"scale","arguments":{"value":2.5,"times":"four"},' +
    META_MODERN + '}}');
  Expect<Boolean>(
    TJSONData(Response.FindPath('result.isError')).AsBoolean).ToBe(True);
  Expect<string>(
    TJSONData(Response.FindPath('result.content[0].text')).AsString)
    .ToBe('Argument "times" must be an integer');
  Response.Free;
end;

procedure TToolDispatch.TestTypedArgsSchemaDerived;
var
  Response: TJSONObject;
  Tools: TJSONArray;
  Scale: TJSONObject;
begin
  // tools/list carries the schema derived from TScaleArgs.
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/list",' +
    '"params":{' + META_MODERN + '}}');
  Tools := TJSONArray(TJSONObject(Response.Find('result')).Find('tools'));
  Scale := TJSONObject(Tools[4]);
  Expect<string>(
    TJSONData(Scale.FindPath('inputSchema.properties.value.type')).AsString)
    .ToBe('number');
  Expect<string>(
    TJSONData(Scale.FindPath('inputSchema.properties.times.type')).AsString)
    .ToBe('integer');
  Response.Free;
end;

procedure TToolDispatch.SetupTests;
begin
  Test('tools/list: all tools, registration order', TestList);
  Test('tools/call: text result', TestCallText);
  Test('tools/call: structured content', TestCallStructured);
  Test('tools/call: absent arguments become {}', TestCallDefaultArguments);
  Test('tools/call: handler exception → isError', TestCallHandlerRaises);
  Test('tools/call: unknown tool → -32602', TestCallUnknown);
  Test('tools/call: non-string name → -32602', TestCallBadName);
  Test('typed args: bound and populated', TestTypedArgsBound);
  Test('typed args: missing argument → isError', TestTypedArgsMissing);
  Test('typed args: mistyped argument → isError', TestTypedArgsMistyped);
  Test('typed args: schema derived from the class',
    TestTypedArgsSchemaDerived);
end;

{ ───────── resources ───────── }

procedure TResourceDispatch.TestList;
var
  Response: TJSONObject;
  Resources: TJSONArray;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"resources/list",' +
    '"params":{' + META_MODERN + '}}');
  Resources := TJSONArray(
    TJSONObject(Response.Find('result')).Find('resources'));
  Expect<Integer>(Resources.Count).ToBe(2);
  Expect<string>(TJSONObject(Resources[0]).Get('uri', ''))
    .ToBe('mem://static');
  Response.Free;
end;

procedure TResourceDispatch.TestReadStatic;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"resources/read",' +
    '"params":{"uri":"mem://static",' + META_MODERN + '}}');
  Expect<string>(
    TJSONData(Response.FindPath('result.contents[0].text')).AsString)
    .ToBe('static text');
  Expect<string>(
    TJSONData(Response.FindPath('result.contents[0].mimeType')).AsString)
    .ToBe('text/plain');
  // Static text is fixed for the process lifetime → registry ttl.
  Expect<Integer>(
    TJSONObject(Response.Find('result')).Get('ttlMs', -1)).ToBe(300000);
  Response.Free;
end;

procedure TResourceDispatch.TestReadDynamic;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"resources/read",' +
    '"params":{"uri":"mem://clock",' + META_MODERN + '}}');
  Expect<string>(
    TJSONData(Response.FindPath('result.contents[0].text')).AsString)
    .ToBe('tick');
  // Dynamic readers advertise ttl 0 — always revalidate.
  Expect<Integer>(
    TJSONObject(Response.Find('result')).Get('ttlMs', -1)).ToBe(0);
  Response.Free;
end;

procedure TResourceDispatch.TestReadNotFound;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"resources/read",' +
    '"params":{"uri":"mem://missing",' + META_MODERN + '}}');
  // -32602 with the uri echoed in data — never the legacy -32002.
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(JSONRPC_INVALID_PARAMS);
  Expect<string>(
    TJSONData(Response.FindPath('error.data.uri')).AsString)
    .ToBe('mem://missing');
  Response.Free;
end;

procedure TResourceDispatch.SetupTests;
begin
  Test('resources/list: all resources', TestList);
  Test('resources/read: static text', TestReadStatic);
  Test('resources/read: dynamic reader', TestReadDynamic);
  Test('resources/read: not found → -32602 + data.uri', TestReadNotFound);
end;

{ ───────── registration guards ───────── }

procedure TRegistrationGuards.TestDuplicateTool;
var
  Server: TMCPServer;
  Raised: Boolean;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Server.RegisterTool('a', 'first', '{"type":"object"}', EchoHandler);
    Raised := False;
    try
      Server.RegisterTool('a', 'second', '{"type":"object"}', EchoHandler);
    except
      on EMCPServer do
        Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
    Expect<Integer>(Server.ToolCount).ToBe(1);
  finally
    Server.Free;
  end;
end;

procedure TRegistrationGuards.TestBadSchema;
var
  Server: TMCPServer;
  Raised: Boolean;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Raised := False;
    try
      Server.RegisterTool('a', 'desc', '{not json', EchoHandler);
    except
      on EMCPServer do
        Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
    Expect<Integer>(Server.ToolCount).ToBe(0);
  finally
    Server.Free;
  end;
end;

procedure TRegistrationGuards.TestDuplicateResource;
var
  Server: TMCPServer;
  Raised: Boolean;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Server.RegisterTextResource('mem://x', 'x', 'text/plain', 'one');
    Raised := False;
    try
      Server.RegisterTextResource('mem://x', 'x', 'text/plain', 'two');
    except
      on EMCPServer do
        Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
    Expect<Integer>(Server.ResourceCount).ToBe(1);
  finally
    Server.Free;
  end;
end;

procedure TRegistrationGuards.SetupTests;
begin
  Test('duplicate tool name rejected', TestDuplicateTool);
  Test('invalid schema JSON rejected', TestBadSchema);
  Test('duplicate resource uri rejected', TestDuplicateResource);
end;

{ ───────── legacy era (dual-era mode) ───────── }

procedure TLegacyEra.DoInitialize(const AVersion: string);
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":100,"method":"initialize",' +
    '"params":{"protocolVersion":"' + AVersion + '",' +
    '"capabilities":{"roots":{}},' +
    '"clientInfo":{"name":"legacy-client","version":"1.2.3"}}}');
  Response.Free;
end;

procedure TLegacyEra.TestKnownVersionEchoed;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"initialize",' +
    '"params":{"protocolVersion":"2025-06-18","capabilities":{}}}');
  Expect<string>(
    TJSONObject(Response.Find('result')).Get('protocolVersion', ''))
    .ToBe('2025-06-18');
  Response.Free;
end;

procedure TLegacyEra.TestUnknownVersionAnswersLatestLegacy;
var
  Response: TJSONObject;
begin
  // Legacy negotiation: an unknown request gets the server's latest
  // legacy revision; the client decides whether to proceed.
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"initialize",' +
    '"params":{"protocolVersion":"1999-01-01","capabilities":{}}}');
  Expect<string>(
    TJSONObject(Response.Find('result')).Get('protocolVersion', ''))
    .ToBe(LATEST_LEGACY_PROTOCOL_VERSION);
  Response.Free;
end;

procedure TLegacyEra.TestInitializeResultShape;
var
  Response: TJSONObject;
  ResultObj: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"initialize",' +
    '"params":{"protocolVersion":"2025-11-25","capabilities":{}}}');
  ResultObj := TJSONObject(Response.Find('result'));
  Expect<string>(
    TJSONObject(ResultObj.Find('serverInfo')).Get('name', ''))
    .ToBe('test-server');
  Expect<Boolean>(
    ResultObj.FindPath('capabilities.tools') <> nil).ToBe(True);
  Expect<string>(ResultObj.Get('instructions', '')).ToBe('test instructions');
  // Legacy dialect: no modern stamps.
  Expect<Boolean>(ResultObj.Find('resultType') = nil).ToBe(True);
  Expect<Boolean>(ResultObj.Find('_meta') = nil).ToBe(True);
  Response.Free;
end;

procedure TLegacyEra.TestRequestBeforeInitialize;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/list",' +
    '"params":{}}');
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(JSONRPC_INVALID_REQUEST);
  Response.Free;
end;

procedure TLegacyEra.TestPingBeforeInitialize;
var
  Response: TJSONObject;
begin
  // ping is valid at any time in the legacy era.
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"ping"}');
  Expect<Boolean>(Response.Find('result') <> nil).ToBe(True);
  Expect<Boolean>(Response.Find('error') = nil).ToBe(True);
  Response.Free;
end;

procedure TLegacyEra.TestLegacyToolCall;
var
  Response: TJSONObject;
begin
  DoInitialize('2025-11-25');
  Response := Call('{"jsonrpc":"2.0","id":2,"method":"tools/call",' +
    '"params":{"name":"echo","arguments":{"message":"legacy hi"}}}');
  Expect<string>(
    TJSONData(Response.FindPath('result.content[0].text')).AsString)
    .ToBe('legacy hi');
  Response.Free;
end;

procedure TLegacyEra.TestLegacyResponsesUnstamped;
var
  Response: TJSONObject;
  ResultObj: TJSONObject;
begin
  DoInitialize('2025-11-25');
  Response := Call('{"jsonrpc":"2.0","id":2,"method":"tools/list",' +
    '"params":{}}');
  ResultObj := TJSONObject(Response.Find('result'));
  // Legacy dialect: no resultType, no serverInfo _meta, no SEP-2549
  // cache fields (those are all 2026-07-28 vocabulary).
  Expect<Boolean>(ResultObj.Find('resultType') = nil).ToBe(True);
  Expect<Boolean>(ResultObj.Find('_meta') = nil).ToBe(True);
  Expect<Boolean>(ResultObj.Find('ttlMs') = nil).ToBe(True);
  Expect<Boolean>(ResultObj.Find('tools') <> nil).ToBe(True);
  Response.Free;
end;

procedure TLegacyEra.TestLegacyContextVisibleToHandlers;
var
  Response: TJSONObject;
begin
  // Handlers see the negotiated legacy version + clientInfo from the
  // handshake — the same TMCPRequestContext API as the modern era.
  DoInitialize('2025-06-18');
  Response := Call('{"jsonrpc":"2.0","id":2,"method":"tools/call",' +
    '"params":{"name":"whoami"}}');
  Expect<string>(
    TJSONData(Response.FindPath('result.content[0].text')).AsString)
    .ToBe('2025-06-18|legacy-client');
  Response.Free;
end;

procedure TLegacyEra.TestLegacyResourceNotFound;
var
  Response: TJSONObject;
begin
  DoInitialize('2025-11-25');
  Response := Call('{"jsonrpc":"2.0","id":2,"method":"resources/read",' +
    '"params":{"uri":"mem://missing"}}');
  // The legacy code (-32002), never the modern -32602, in this era.
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(MCP_ERROR_LEGACY_RESOURCE_NOT_FOUND);
  Response.Free;
end;

procedure TLegacyEra.TestErasServedConcurrently;
var
  Response: TJSONObject;
begin
  // The spec allows a dual-era server to serve both eras on the same
  // process; a modern _meta request after a legacy handshake stays
  // fully modern (stamps, cache fields, modern error codes).
  DoInitialize('2025-11-25');
  Response := Call('{"jsonrpc":"2.0","id":2,"method":"tools/list",' +
    '"params":{' + META_MODERN + '}}');
  Expect<string>(
    TJSONObject(Response.Find('result')).Get('resultType', ''))
    .ToBe('complete');
  Expect<Integer>(
    TJSONObject(Response.Find('result')).Get('ttlMs', -1)).ToBe(300000);
  Response.Free;

  Response := Call('{"jsonrpc":"2.0","id":3,"method":"resources/read",' +
    '"params":{"uri":"mem://missing",' + META_MODERN + '}}');
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(JSONRPC_INVALID_PARAMS);
  Response.Free;
end;

procedure TLegacyEra.SetupTests;
begin
  Test('initialize echoes a known legacy version', TestKnownVersionEchoed);
  Test('unknown version → latest legacy answered',
    TestUnknownVersionAnswersLatestLegacy);
  Test('initialize result shape, unstamped', TestInitializeResultShape);
  Test('request before initialize → -32600', TestRequestBeforeInitialize);
  Test('ping answered before initialize', TestPingBeforeInitialize);
  Test('legacy tools/call after handshake', TestLegacyToolCall);
  Test('legacy responses carry no modern stamps',
    TestLegacyResponsesUnstamped);
  Test('legacy context reaches handlers', TestLegacyContextVisibleToHandlers);
  Test('legacy resource not found → -32002', TestLegacyResourceNotFound);
  Test('modern and legacy served concurrently', TestErasServedConcurrently);
end;

begin
  TestRunnerProgram.AddSuite(
    TDiscoverAndErrors.Create('Server: discover + protocol errors'));
  TestRunnerProgram.AddSuite(TToolDispatch.Create('Server: tools'));
  TestRunnerProgram.AddSuite(TResourceDispatch.Create('Server: resources'));
  TestRunnerProgram.AddSuite(
    TRegistrationGuards.Create('Server: registration guards'));
  TestRunnerProgram.AddSuite(TLegacyEra.Create('Server: legacy era'));
  TestRunnerProgram.Run;
end.
