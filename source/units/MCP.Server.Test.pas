{ MCP.Server.Test — the full dispatch surface through HandleMessage,
  line in / line out, no transport: server/discover shape, tools/list /
  tools/call (success, structured content, handler exception → isError,
  unknown tool → -32602, missing arguments default to {}), resources
  (list, static read, dynamic reader, not found → -32602 + data.uri),
  the initialize rejection naming supported versions, method-not-found,
  notifications producing no response, malformed lines answered with
  the right JSON-RPC error, and registration guards (duplicate names,
  bad schema JSON → EMcpServer). }

program MCP.Server.Test;

{$I Shared.inc}

uses
  SysUtils,

  fpjson,
  jsonparser,
  MCP.JsonRpc,
  MCP.Protocol,
  MCP.Server,
  TestingPascalLibrary;

const
  META_MODERN =
    '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{}}';

type
  TDispatchSuite = class(TTestSuite)
  protected
    FServer: TMcpServer;
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

{ ───────── handlers under test ───────── }

function EchoHandler(AArguments: TJSONObject;
  const ACtx: TMcpRequestContext): TMcpToolResult;
begin
  Result := McpTextResult(AArguments.Get('message', '(no message)'));
end;

function SumHandler(AArguments: TJSONObject;
  const ACtx: TMcpRequestContext): TMcpToolResult;
var
  Structured: TJSONObject;
begin
  Structured := TJSONObject.Create;
  Structured.Add('sum', AArguments.Get('a', 0.0) + AArguments.Get('b', 0.0));
  Result := McpStructuredResult('sum computed', Structured);
end;

function BoomHandler(AArguments: TJSONObject;
  const ACtx: TMcpRequestContext): TMcpToolResult;
begin
  raise Exception.Create('boom');
end;

function ClockReader(const AUri: string;
  const ACtx: TMcpRequestContext): TJSONArray;
begin
  Result := McpTextContents(AUri, 'text/plain', 'tick');
end;

{ ───────── shared fixture ───────── }

procedure TDispatchSuite.BeforeEach;
begin
  FServer := TMcpServer.Create('test-server', '9.9.9');
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
  Expect<string>(
    TJSONObject(TJSONObject(ResultObj.Find('_meta'))
      .Find(META_KEY_SERVER_INFO)).Get('name', '')).ToBe('test-server');
  Response.Free;
end;

procedure TDiscoverAndErrors.TestInitializeRejected;
var
  Response: TJSONObject;
begin
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
  Expect<Integer>(Tools.Count).ToBe(3);
  Expect<string>(TJSONObject(Tools[0]).Get('name', '')).ToBe('echo');
  Expect<Boolean>(
    TJSONObject(Tools[0]).Find('inputSchema') <> nil).ToBe(True);
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

procedure TToolDispatch.SetupTests;
begin
  Test('tools/list: all tools, registration order', TestList);
  Test('tools/call: text result', TestCallText);
  Test('tools/call: structured content', TestCallStructured);
  Test('tools/call: absent arguments become {}', TestCallDefaultArguments);
  Test('tools/call: handler exception → isError', TestCallHandlerRaises);
  Test('tools/call: unknown tool → -32602', TestCallUnknown);
  Test('tools/call: non-string name → -32602', TestCallBadName);
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
  Server: TMcpServer;
  Raised: Boolean;
begin
  Server := TMcpServer.Create('t', '1');
  try
    Server.RegisterTool('a', 'first', '{"type":"object"}', EchoHandler);
    Raised := False;
    try
      Server.RegisterTool('a', 'second', '{"type":"object"}', EchoHandler);
    except
      on EMcpServer do
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
  Server: TMcpServer;
  Raised: Boolean;
begin
  Server := TMcpServer.Create('t', '1');
  try
    Raised := False;
    try
      Server.RegisterTool('a', 'desc', '{not json', EchoHandler);
    except
      on EMcpServer do
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
  Server: TMcpServer;
  Raised: Boolean;
begin
  Server := TMcpServer.Create('t', '1');
  try
    Server.RegisterTextResource('mem://x', 'x', 'text/plain', 'one');
    Raised := False;
    try
      Server.RegisterTextResource('mem://x', 'x', 'text/plain', 'two');
    except
      on EMcpServer do
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

begin
  TestRunnerProgram.AddSuite(
    TDiscoverAndErrors.Create('Server: discover + protocol errors'));
  TestRunnerProgram.AddSuite(TToolDispatch.Create('Server: tools'));
  TestRunnerProgram.AddSuite(TResourceDispatch.Create('Server: resources'));
  TestRunnerProgram.AddSuite(
    TRegistrationGuards.Create('Server: registration guards'));
  TestRunnerProgram.Run;
end.
