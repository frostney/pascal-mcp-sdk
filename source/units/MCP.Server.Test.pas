{ MCP.Server.Test — the full dispatch surface through HandleMessage,
  line in / line out, no transport: server/discover shape, tools/list /
  tools/call (success, structured content, handler exception → isError,
  unknown tool → -32602, missing arguments default to {}), resources
  (list, static read, dynamic reader, not found → -32602 + data.uri),
  the initialize rejection naming supported versions, method-not-found,
  notifications producing no response, malformed lines answered with
  the right JSON-RPC error, and registration guards (duplicate names,
  bad schema JSON and malformed resource templates → EMCPServer). }

program MCP.Server.Test;

{$I Shared.inc}

uses
  Classes,
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
    procedure TestTypedArgsDefaultSeeded;
    procedure TestTypedArgsDefaultOverridden;
    procedure TestTypedOrdinalBounds;
    procedure TestTypedQWordRoundTrip;
    procedure TestTypedOutputClass;
    procedure TestFluentAnnotations;
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
    procedure TestEmptyResourceTemplate;
    procedure TestEmptyTemplateVariable;
    procedure TestUnclosedTemplateVariable;
    procedure TestAdjacentTemplateVariables;
  end;

  TResourceTemplates = class(TDispatchSuite)
  public
    procedure SetupTests; override;
    procedure TestMatcherSingleVar;
    procedure TestMatcherMultiVar;
    procedure TestMatcherRejectsSlash;
    procedure TestMatcherLiteralMismatch;
    procedure TestMatcherTrailingExcess;
    procedure TestMatcherFullFollowingLiteral;
    procedure TestMatcherBacktracks;
    procedure TestMatcherPreservesPercentEncoding;
    procedure TestTemplatesList;
    procedure TestReadViaTemplate;
    procedure TestExactResourceWins;
    procedure TestStillNotFound;
    procedure TestLegacyDialect;
  end;

  TNotificationEmission = class(TDispatchSuite)
  private
    FLines: TStringList;
    function Notification(AIndex: Integer): TJSONObject;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;
    procedure TestProgressEmitted;
    procedure TestProgressWithoutToken;
    procedure TestStringTokenPreserved;
    procedure TestLogEmittedAtLevel;
    procedure TestLogFilteredBelowLevel;
    procedure TestUnknownLogLevelRejected;
    procedure TestWrongCaseLogLevelRejected;
    procedure TestLogWithoutOptIn;
    procedure TestLegacyProgress;
    procedure TestNoSinkStillServes;
  end;

  TPromptDispatch = class(TDispatchSuite)
  public
    procedure SetupTests; override;
    procedure TestList;
    procedure TestGet;
    procedure TestGetNoArgsPrompt;
    procedure TestGetUnknown;
    procedure TestGetMissingRequired;
    procedure TestGetHandlerRaises;
    procedure TestLegacyDialect;
  end;

  TLegacyEra = class(TDispatchSuite)
  private
    procedure DoInitialize(const AVersion: string);
    procedure ExpectInvalidParams(const ALine: string);
  public
    procedure SetupTests; override;
    procedure TestKnownVersionEchoed;
    procedure TestBatchRevisionAnswersLatestLegacy;
    procedure TestUnknownVersionAnswersLatestLegacy;
    procedure TestInitializeResultShape;
    procedure TestInitializeMissingCapabilities;
    procedure TestInitializeNonObjectCapabilities;
    procedure TestInitializeMissingClientInfo;
    procedure TestInitializeIncompleteClientInfo;
    procedure TestRequestBeforeInitialize;
    procedure TestPingBeforeInitialize;
    procedure TestLegacyToolCall;
    procedure TestParamslessToolCall;
    procedure TestParamslessResourceRead;
    procedure TestParamslessPromptGet;
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

type
  TRepeatArgs = class(TMCPArgs)
  private
    FWord: string;
    FCount: Integer;
  published
    property word: string read FWord write FWord;
    property count: Integer read FCount write FCount default 2;
  end;

  TByteArgs = class(TMCPArgs)
  private
    FValue: Byte;
  published
    property value: Byte read FValue write FValue;
  end;

  TWordArgs = class(TMCPArgs)
  private
    FValue: Word;
  published
    property value: Word read FValue write FValue;
  end;

  TCardinalArgs = class(TMCPArgs)
  private
    FValue: Cardinal;
  published
    property value: Cardinal read FValue write FValue;
  end;

  TBoundedOrdinal = 10..20;

  TSubrangeArgs = class(TMCPArgs)
  private
    FValue: TBoundedOrdinal;
  published
    property value: TBoundedOrdinal read FValue write FValue;
  end;

  TInt64Args = class(TMCPArgs)
  private
    FValue: Int64;
  published
    property value: Int64 read FValue write FValue;
  end;

  TQWordArgs = class(TMCPArgs)
  private
    FValue: QWord;
  published
    property value: QWord read FValue write FValue;
  end;

// Typed output: copies the bound input into a fresh instance and
// returns it as structuredContent.
function MirrorHandler(AArgs: TMCPArgs;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Args, Copy: TScaleArgs;
begin
  Args := AArgs as TScaleArgs;
  Copy := TScaleArgs.Create;
  Copy.value := Args.value;
  Copy.times := Args.times;
  Result := MCPStructuredResult('mirrored', Copy);
end;

function RepeatHandler(AArgs: TMCPArgs;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Args: TRepeatArgs;
  I: Integer;
  S: string;
begin
  Args := AArgs as TRepeatArgs;
  S := '';
  for I := 1 to Args.count do
    S := S + Args.word;
  Result := MCPTextResult(S);
end;

function OrdinalHandler(AArgs: TMCPArgs;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPStructuredResult('bound', MCPSerialize(AArgs));
end;

function ClockReader(const AUri: string;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  Result := MCPTextContents(AUri, 'text/plain', 'tick');
end;

function ReviewPromptHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  Result := MCPMessages([
    MCPUserMessage('Review this: ' + AArguments.Get('code', '')),
    MCPAssistantMessage('Certainly.')]);
end;

function HelloPromptHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  Result := MCPMessages([MCPUserMessage('Say hello.')]);
end;

function BoomPromptHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  raise Exception.Create('prompt boom');
end;

// Emits progress and two log severities; every emission is gated on
// the client's own opt-ins, so the same tool serves all the cases.
function NoisyHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  MCPReportProgress(ACtx, 0.25, 1.0, 'working');
  MCPLogMessage(ACtx, 'warning', 'careful');
  MCPLogMessage(ACtx, 'debug', 'details');
  Result := MCPTextResult('noise done');
end;

procedure CaptureSink(const ALine: string; AUserData: Pointer);
begin
  TStringList(AUserData).Add(ALine);
end;

function PairReader(const AUri: string; AVars: TJSONObject;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  Result := MCPTextContents(AUri, 'text/plain',
    AVars.Get('a', '') + '|' + AVars.Get('b', ''));
end;

procedure ExpectTemplateRegistrationError(const ATemplate,
  AExpectedMessage: string);
var
  ErrorMessage: string;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    ErrorMessage := '';
    try
      Server.RegisterResourceTemplate(ATemplate, 'template', 'text/plain',
        PairReader);
    except
      on E: EMCPServer do
        ErrorMessage := E.Message;
    end;
    Expect<string>(ErrorMessage).ToBe(AExpectedMessage);
  finally
    Server.Free;
  end;
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
  FServer.RegisterTool('repeat', 'Repeat a word count times',
    TRepeatArgs, RepeatHandler);
  FServer.RegisterTextResource('mem://static', 'static', 'text/plain',
    'static text');
  FServer.RegisterResource('mem://clock', 'clock', 'text/plain',
    ClockReader);
  FServer.RegisterResourceTemplate('mem://pair/{a}/{b}', 'pair',
    'text/plain', PairReader, 'Joins two path segments');
  // Registered after the template but must win over it on exact match.
  FServer.RegisterTextResource('mem://pair/one/two', 'fixed-pair',
    'text/plain', 'exact wins');
  FServer.RegisterTool('noisy', 'Emits notifications',
    '{"type":"object"}', NoisyHandler);
  FServer.RegisterPrompt('review', 'Ask for a code review',
    PromptArguments.Add('code', 'The code to review')
                   .Add('style', 'Review style', False),
    ReviewPromptHandler);
  FServer.RegisterPrompt('hello', 'A canned hello', HelloPromptHandler);
  FServer.RegisterPrompt('promptboom', 'Always raises', BoomPromptHandler);
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
    '"params":{"protocolVersion":"2025-11-25","capabilities":{},' +
    '"clientInfo":{"name":"legacy-client","version":"1.2.3"}}}');
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
  Expect<Integer>(Tools.Count).ToBe(7);
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
  Test('typed args: default directive seeds missing argument',
    TestTypedArgsDefaultSeeded);
  Test('typed args: explicit value overrides default',
    TestTypedArgsDefaultOverridden);
  Test('typed args: ordinal RTTI bounds enforced',
    TestTypedOrdinalBounds);
  Test('typed args: QWord boundaries round-trip exactly',
    TestTypedQWordRoundTrip);
  Test('typed output class: derived outputSchema + serialized result',
    TestTypedOutputClass);
  Test('fluent decoration: title + annotation hints',
    TestFluentAnnotations);
end;

procedure TToolDispatch.TestTypedOrdinalBounds;

  procedure ExpectBound(const ATool, AValue: string;
    const AExpected: QWord);
  var
    Response: TJSONObject;
  begin
    Response := Call('{' +
      '"jsonrpc":"2.0","id":1,"method":"tools/call",' +
      '"params":{"name":"' + ATool + '","arguments":{"value":' +
      AValue + '},' + META_MODERN + '}}');
    Expect<QWord>(
      TJSONData(Response.FindPath('result.structuredContent.value')).AsQWord)
      .ToBe(AExpected);
    Response.Free;
  end;

  procedure ExpectIntegerError(const ATool, AValue: string);
  var
    Response: TJSONObject;
  begin
    Response := Call('{' +
      '"jsonrpc":"2.0","id":1,"method":"tools/call",' +
      '"params":{"name":"' + ATool + '","arguments":{"value":' +
      AValue + '},' + META_MODERN + '}}');
    Expect<Boolean>(
      TJSONData(Response.FindPath('result.isError')).AsBoolean).ToBe(True);
    Expect<string>(
      TJSONData(Response.FindPath('result.content[0].text')).AsString)
      .ToBe('Argument "value" must be an integer');
    Response.Free;
  end;

begin
  FServer.RegisterTool('byte', 'Bind Byte', TByteArgs, OrdinalHandler);
  FServer.RegisterTool('word', 'Bind Word', TWordArgs, OrdinalHandler);
  FServer.RegisterTool('cardinal', 'Bind Cardinal',
    TCardinalArgs, OrdinalHandler);
  FServer.RegisterTool('subrange', 'Bind subrange',
    TSubrangeArgs, OrdinalHandler);
  FServer.RegisterTool('int64', 'Bind Int64', TInt64Args, OrdinalHandler);

  ExpectBound('byte', '0', 0);
  ExpectBound('byte', '255', 255);
  ExpectIntegerError('byte', '300');
  ExpectIntegerError('byte', '-5');
  ExpectIntegerError('byte', '4294967596');
  ExpectBound('word', '0', 0);
  ExpectBound('word', '65535', 65535);
  ExpectIntegerError('word', '65536');
  ExpectBound('cardinal', '0', 0);
  ExpectBound('cardinal', '4294967295', 4294967295);
  ExpectIntegerError('cardinal', '-1');
  ExpectIntegerError('cardinal', '4294967296');
  ExpectBound('subrange', '10', 10);
  ExpectBound('subrange', '20', 20);
  ExpectIntegerError('subrange', '9');
  ExpectIntegerError('subrange', '21');
  ExpectBound('int64', '9223372036854775807', QWord(High(Int64)));
  ExpectIntegerError('int64', '9223372036854775808');
end;

procedure TToolDispatch.TestTypedQWordRoundTrip;
var
  Response: TJSONObject;
  Value: TJSONData;
begin
  FServer.RegisterTool('qword', 'Bind QWord', TQWordArgs, OrdinalHandler);

  Response := Call('{' +
    '"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"qword","arguments":' +
    '{"value":9223372036854775807},' + META_MODERN + '}}');
  Value := Response.FindPath('result.structuredContent.value');
  Expect<QWord>(Value.AsQWord).ToBe(QWord(High(Int64)));
  Response.Free;

  Response := Call('{' +
    '"jsonrpc":"2.0","id":2,"method":"tools/call",' +
    '"params":{"name":"qword","arguments":' +
    '{"value":9223372036854775808},' + META_MODERN + '}}');
  Value := Response.FindPath('result.structuredContent.value');
  Expect<QWord>(Value.AsQWord).ToBe(QWord(High(Int64)) + 1);
  Response.Free;

  Response := Call('{' +
    '"jsonrpc":"2.0","id":3,"method":"tools/call",' +
    '"params":{"name":"qword","arguments":' +
    '{"value":18446744073709551615},' + META_MODERN + '}}');
  Value := Response.FindPath('result.structuredContent.value');
  Expect<Integer>(Ord(TJSONNumber(Value).NumberType)).ToBe(Ord(ntQWord));
  Expect<QWord>(Value.AsQWord).ToBe(High(QWord));
  Response.Free;

  Response := Call('{' +
    '"jsonrpc":"2.0","id":4,"method":"tools/call",' +
    '"params":{"name":"qword","arguments":{"value":-1},' +
    META_MODERN + '}}');
  Expect<Boolean>(
    TJSONData(Response.FindPath('result.isError')).AsBoolean).ToBe(True);
  Expect<string>(
    TJSONData(Response.FindPath('result.content[0].text')).AsString)
    .ToBe('Argument "value" must be an integer');
  Response.Free;
end;

procedure TToolDispatch.TestFluentAnnotations;
var
  Response: TJSONObject;
  Tools: TJSONArray;
  Decorated: TJSONObject;
begin
  FServer.RegisterTool('careful', 'A decorated tool',
    '{"type":"object"}', EchoHandler)
    .Title('Careful Tool').ReadOnlyHint.DestructiveHint(False)
    .IdempotentHint;
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/list",' +
    '"params":{' + META_MODERN + '}}');
  Tools := TJSONArray(TJSONObject(Response.Find('result')).Find('tools'));
  Decorated := TJSONObject(Tools[Tools.Count - 1]);
  Expect<string>(Decorated.Get('title', '')).ToBe('Careful Tool');
  Expect<Boolean>(
    TJSONData(Decorated.FindPath('annotations.readOnlyHint')).AsBoolean)
    .ToBe(True);
  Expect<Boolean>(
    TJSONData(Decorated.FindPath('annotations.destructiveHint')).AsBoolean)
    .ToBe(False);
  Expect<Boolean>(
    TJSONData(Decorated.FindPath('annotations.idempotentHint')).AsBoolean)
    .ToBe(True);
  Expect<Boolean>(
    Decorated.FindPath('annotations.openWorldHint') = nil).ToBe(True);
  Response.Free;
end;

procedure TToolDispatch.TestTypedOutputClass;
var
  Response: TJSONObject;
  Tools: TJSONArray;
begin
  FServer.RegisterTool('mirror', 'Mirror the scale arguments',
    TScaleArgs, TScaleArgs, MirrorHandler);
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/list",' +
    '"params":{' + META_MODERN + '}}');
  Tools := TJSONArray(TJSONObject(Response.Find('result')).Find('tools'));
  Expect<string>(
    TJSONData(TJSONObject(Tools[Tools.Count - 1])
    .FindPath('outputSchema.properties.value.type')).AsString)
    .ToBe('number');
  Response.Free;

  Response := Call('{"jsonrpc":"2.0","id":2,"method":"tools/call",' +
    '"params":{"name":"mirror","arguments":{"value":2.5,"times":4},' +
    META_MODERN + '}}');
  Expect<Boolean>(
    TJSONData(Response.FindPath('result.structuredContent.value'))
    .AsFloat = 2.5).ToBe(True);
  Expect<Integer>(
    TJSONData(Response.FindPath('result.structuredContent.times'))
    .AsInteger).ToBe(4);
  Response.Free;
end;

procedure TToolDispatch.TestTypedArgsDefaultSeeded;
var
  Response: TJSONObject;
begin
  // count omitted → default 2 applies.
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"repeat","arguments":{"word":"ha"},' +
    META_MODERN + '}}');
  Expect<string>(
    TJSONData(Response.FindPath('result.content[0].text')).AsString)
    .ToBe('haha');
  Response.Free;
end;

procedure TToolDispatch.TestTypedArgsDefaultOverridden;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"repeat","arguments":{"word":"ha","count":3},' +
    META_MODERN + '}}');
  Expect<string>(
    TJSONData(Response.FindPath('result.content[0].text')).AsString)
    .ToBe('hahaha');
  Response.Free;
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
  Expect<Integer>(Resources.Count).ToBe(3);
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

procedure TRegistrationGuards.TestEmptyResourceTemplate;
begin
  ExpectTemplateRegistrationError('',
    'Resource template registration requires a non-empty uriTemplate');
end;

procedure TRegistrationGuards.TestEmptyTemplateVariable;
begin
  ExpectTemplateRegistrationError('mem://item/{}',
    'Invalid resource template "mem://item/{}": variable name must not be empty');
end;

procedure TRegistrationGuards.TestUnclosedTemplateVariable;
begin
  ExpectTemplateRegistrationError('mem://item/{name',
    'Invalid resource template "mem://item/{name": unclosed variable at character 12');
end;

procedure TRegistrationGuards.TestAdjacentTemplateVariables;
begin
  ExpectTemplateRegistrationError('mem://item/{group}{name}',
    'Invalid resource template "mem://item/{group}{name}": adjacent variables require separating literal text');
end;

procedure TRegistrationGuards.SetupTests;
begin
  Test('duplicate tool name rejected', TestDuplicateTool);
  Test('invalid schema JSON rejected', TestBadSchema);
  Test('duplicate resource uri rejected', TestDuplicateResource);
  Test('empty resource template rejected', TestEmptyResourceTemplate);
  Test('empty template variable rejected', TestEmptyTemplateVariable);
  Test('unclosed template variable rejected', TestUnclosedTemplateVariable);
  Test('adjacent template variables rejected', TestAdjacentTemplateVariables);
end;

{ ───────── resource templates ───────── }

procedure TResourceTemplates.TestMatcherSingleVar;
var
  Vars: TJSONObject;
begin
  Expect<Boolean>(
    MatchUriTemplate('mem://shout/{text}', 'mem://shout/hello', Vars))
    .ToBe(True);
  Expect<string>(Vars.Get('text', '')).ToBe('hello');
  Vars.Free;
end;

procedure TResourceTemplates.TestMatcherMultiVar;
var
  Vars: TJSONObject;
begin
  Expect<Boolean>(
    MatchUriTemplate('mem://pair/{a}/{b}', 'mem://pair/x/y', Vars))
    .ToBe(True);
  Expect<string>(Vars.Get('a', '')).ToBe('x');
  Expect<string>(Vars.Get('b', '')).ToBe('y');
  Vars.Free;
end;

procedure TResourceTemplates.TestMatcherRejectsSlash;
var
  Vars: TJSONObject;
begin
  // {text} must not swallow a path separator.
  Expect<Boolean>(
    MatchUriTemplate('mem://shout/{text}', 'mem://shout/a/b', Vars))
    .ToBe(False);
end;

procedure TResourceTemplates.TestMatcherLiteralMismatch;
var
  Vars: TJSONObject;
begin
  Expect<Boolean>(
    MatchUriTemplate('mem://shout/{text}', 'mem://whisper/hello', Vars))
    .ToBe(False);
end;

procedure TResourceTemplates.TestMatcherTrailingExcess;
var
  Vars: TJSONObject;
begin
  Expect<Boolean>(
    MatchUriTemplate('mem://pair/{a}/x', 'mem://pair/v/xy', Vars))
    .ToBe(False);
end;

procedure TResourceTemplates.TestMatcherFullFollowingLiteral;
var
  Vars: TJSONObject;
begin
  Expect<Boolean>(
    MatchUriTemplate('mcp://example/{name}.json',
      'mcp://example/a.b.json', Vars)).ToBe(True);
  Expect<string>(Vars.Get('name', '')).ToBe('a.b');
  Vars.Free;
end;

procedure TResourceTemplates.TestMatcherBacktracks;
var
  Vars: TJSONObject;
begin
  Expect<Boolean>(
    MatchUriTemplate('mcp://example/{name}.meta.json',
      'mcp://example/a.meta.meta.json', Vars)).ToBe(True);
  Expect<string>(Vars.Get('name', '')).ToBe('a.meta');
  Vars.Free;
end;

procedure TResourceTemplates.TestMatcherPreservesPercentEncoding;
var
  Vars: TJSONObject;
begin
  Expect<Boolean>(
    MatchUriTemplate('mcp://example/{name}',
      'mcp://example/hello%20world', Vars)).ToBe(True);
  Expect<string>(Vars.Get('name', '')).ToBe('hello%20world');
  Vars.Free;
end;

procedure TResourceTemplates.TestTemplatesList;
var
  Response: TJSONObject;
  Templates: TJSONArray;
begin
  Response := Call(
    '{"jsonrpc":"2.0","id":1,"method":"resources/templates/list",' +
    '"params":{' + META_MODERN + '}}');
  Templates := TJSONArray(
    TJSONObject(Response.Find('result')).Find('resourceTemplates'));
  Expect<Integer>(Templates.Count).ToBe(1);
  Expect<string>(TJSONObject(Templates[0]).Get('uriTemplate', ''))
    .ToBe('mem://pair/{a}/{b}');
  Expect<Integer>(
    TJSONObject(Response.Find('result')).Get('ttlMs', -1)).ToBe(300000);
  Response.Free;
end;

procedure TResourceTemplates.TestReadViaTemplate;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"resources/read",' +
    '"params":{"uri":"mem://pair/left/right",' + META_MODERN + '}}');
  Expect<string>(
    TJSONData(Response.FindPath('result.contents[0].text')).AsString)
    .ToBe('left|right');
  // Template reads are dynamic: ttl 0.
  Expect<Integer>(
    TJSONObject(Response.Find('result')).Get('ttlMs', -1)).ToBe(0);
  Response.Free;
end;

procedure TResourceTemplates.TestExactResourceWins;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"resources/read",' +
    '"params":{"uri":"mem://pair/one/two",' + META_MODERN + '}}');
  Expect<string>(
    TJSONData(Response.FindPath('result.contents[0].text')).AsString)
    .ToBe('exact wins');
  Response.Free;
end;

procedure TResourceTemplates.TestStillNotFound;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"resources/read",' +
    '"params":{"uri":"mem://pair/only-one-segment",' + META_MODERN + '}}');
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(JSONRPC_INVALID_PARAMS);
  Response.Free;
end;

procedure TResourceTemplates.TestLegacyDialect;
var
  Response: TJSONObject;
  ResultObj: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"initialize",' +
    '"params":{"protocolVersion":"2025-11-25","capabilities":{},' +
    '"clientInfo":{"name":"legacy-client","version":"1.2.3"}}}');
  Response.Free;
  Response := Call(
    '{"jsonrpc":"2.0","id":2,"method":"resources/templates/list",' +
    '"params":{}}');
  ResultObj := TJSONObject(Response.Find('result'));
  Expect<Integer>(
    TJSONArray(ResultObj.Find('resourceTemplates')).Count).ToBe(1);
  Expect<Boolean>(ResultObj.Find('ttlMs') = nil).ToBe(True);
  Response.Free;
  Response := Call('{"jsonrpc":"2.0","id":3,"method":"resources/read",' +
    '"params":{"uri":"mem://pair/l/r"}}');
  Expect<string>(
    TJSONData(Response.FindPath('result.contents[0].text')).AsString)
    .ToBe('l|r');
  Response.Free;
end;

procedure TResourceTemplates.SetupTests;
begin
  Test('matcher: single variable', TestMatcherSingleVar);
  Test('matcher: multiple variables', TestMatcherMultiVar);
  Test('matcher: variables never cross /', TestMatcherRejectsSlash);
  Test('matcher: literal mismatch fails', TestMatcherLiteralMismatch);
  Test('matcher: trailing excess fails', TestMatcherTrailingExcess);
  Test('matcher: complete following literal delimits variable',
    TestMatcherFullFollowingLiteral);
  Test('matcher: backtracks to a later following literal',
    TestMatcherBacktracks);
  Test('matcher: percent encoding remains encoded',
    TestMatcherPreservesPercentEncoding);
  Test('resources/templates/list: shape + cache fields',
    TestTemplatesList);
  Test('resources/read: template match with variables',
    TestReadViaTemplate);
  Test('resources/read: exact resource beats template',
    TestExactResourceWins);
  Test('resources/read: no match stays -32602', TestStillNotFound);
  Test('templates served in the legacy dialect', TestLegacyDialect);
end;

{ ───────── notification emission ───────── }

procedure TNotificationEmission.BeforeEach;
begin
  inherited BeforeEach;
  FLines := TStringList.Create;
  FServer.SetLineSink(CaptureSink, FLines);
end;

procedure TNotificationEmission.AfterEach;
begin
  FreeAndNil(FLines);
  inherited AfterEach;
end;

function TNotificationEmission.Notification(AIndex: Integer): TJSONObject;
begin
  Result := TJSONObject(GetJSON(FLines[AIndex]));
end;

procedure TNotificationEmission.TestProgressEmitted;
var
  Response, Note: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"noisy","_meta":{' +
    '"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{},' +
    '"progressToken":7}}}');
  Expect<Integer>(FLines.Count).ToBe(1);
  Note := Notification(0);
  Expect<string>(Note.Get('method', '')).ToBe('notifications/progress');
  Expect<Integer>(
    TJSONData(Note.FindPath('params.progressToken')).AsInteger).ToBe(7);
  Expect<Boolean>(
    TJSONData(Note.FindPath('params.progressToken')).JSONType = jtNumber)
    .ToBe(True);
  Expect<string>(
    TJSONData(Note.FindPath('params.message')).AsString).ToBe('working');
  Expect<Boolean>(Note.Find('id') = nil).ToBe(True);
  Note.Free;
  Response.Free;
end;

procedure TNotificationEmission.TestProgressWithoutToken;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"noisy",' + META_MODERN + '}}');
  Expect<Integer>(FLines.Count).ToBe(0);
  Response.Free;
end;

procedure TNotificationEmission.TestStringTokenPreserved;
var
  Response, Note: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"noisy","_meta":{' +
    '"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{},' +
    '"progressToken":"op-42"}}}');
  Note := Notification(0);
  Expect<string>(
    TJSONData(Note.FindPath('params.progressToken')).AsString)
    .ToBe('op-42');
  Expect<Boolean>(
    TJSONData(Note.FindPath('params.progressToken')).JSONType = jtString)
    .ToBe(True);
  Note.Free;
  Response.Free;
end;

procedure TNotificationEmission.TestLogEmittedAtLevel;
var
  Response, Note: TJSONObject;
begin
  // logLevel debug → warning and debug both pass the filter.
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"noisy","_meta":{' +
    '"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{},' +
    '"io.modelcontextprotocol/logLevel":"debug"}}}');
  Expect<Integer>(FLines.Count).ToBe(2);
  Note := Notification(0);
  Expect<string>(Note.Get('method', '')).ToBe('notifications/message');
  Expect<string>(
    TJSONData(Note.FindPath('params.level')).AsString).ToBe('warning');
  Note.Free;
  Response.Free;
end;

procedure TNotificationEmission.TestLogFilteredBelowLevel;
var
  Response: TJSONObject;
begin
  // logLevel error → warning and debug are both dropped.
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"noisy","_meta":{' +
    '"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{},' +
    '"io.modelcontextprotocol/logLevel":"error"}}}');
  Expect<Integer>(FLines.Count).ToBe(0);
  Response.Free;
end;

procedure TNotificationEmission.TestUnknownLogLevelRejected;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"noisy","_meta":{' +
    '"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{},' +
    '"io.modelcontextprotocol/logLevel":"verbose"}}}');
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(JSONRPC_INVALID_PARAMS);
  Expect<Integer>(FLines.Count).ToBe(0);
  Response.Free;
end;

procedure TNotificationEmission.TestWrongCaseLogLevelRejected;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"noisy","_meta":{' +
    '"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{},' +
    '"io.modelcontextprotocol/logLevel":"INFO"}}}');
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(JSONRPC_INVALID_PARAMS);
  Expect<Integer>(FLines.Count).ToBe(0);
  Response.Free;
end;

procedure TNotificationEmission.TestLogWithoutOptIn;
var
  Response: TJSONObject;
begin
  // No logLevel in _meta: the spec forbids notifications/message.
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"noisy",' + META_MODERN + '}}');
  Expect<Integer>(FLines.Count).ToBe(0);
  Response.Free;
end;

procedure TNotificationEmission.TestLegacyProgress;
var
  Response, Note: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"initialize",' +
    '"params":{"protocolVersion":"2025-11-25","capabilities":{},' +
    '"clientInfo":{"name":"legacy-client","version":"1.2.3"}}}');
  Response.Free;
  // progressToken is per-request in every era; no logLevel opt-in
  // exists in the legacy path, so only progress is emitted.
  Response := Call('{"jsonrpc":"2.0","id":2,"method":"tools/call",' +
    '"params":{"name":"noisy","_meta":{"progressToken":9}}}');
  Expect<Integer>(FLines.Count).ToBe(1);
  Note := Notification(0);
  Expect<string>(Note.Get('method', '')).ToBe('notifications/progress');
  Expect<Integer>(
    TJSONData(Note.FindPath('params.progressToken')).AsInteger).ToBe(9);
  Note.Free;
  Response.Free;
end;

procedure TNotificationEmission.TestNoSinkStillServes;
var
  Response: TJSONObject;
begin
  FServer.SetLineSink(nil, nil);
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"noisy","_meta":{' +
    '"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{},' +
    '"progressToken":7}}}');
  Expect<string>(
    TJSONData(Response.FindPath('result.content[0].text')).AsString)
    .ToBe('noise done');
  Response.Free;
end;

procedure TNotificationEmission.SetupTests;
begin
  Test('progress emitted with numeric token', TestProgressEmitted);
  Test('no progress without a token', TestProgressWithoutToken);
  Test('string token preserved verbatim', TestStringTokenPreserved);
  Test('log messages emitted at requested level', TestLogEmittedAtLevel);
  Test('log messages below requested level dropped',
    TestLogFilteredBelowLevel);
  Test('unknown logLevel rejected with -32602',
    TestUnknownLogLevelRejected);
  Test('wrong-case logLevel rejected with -32602',
    TestWrongCaseLogLevelRejected);
  Test('no log messages without the opt-in', TestLogWithoutOptIn);
  Test('legacy era: progress works, logging stays quiet',
    TestLegacyProgress);
  Test('no sink: handlers still serve', TestNoSinkStillServes);
end;

{ ───────── prompts ───────── }

procedure TPromptDispatch.TestList;
var
  Response: TJSONObject;
  Prompts: TJSONArray;
  Review: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"prompts/list",' +
    '"params":{' + META_MODERN + '}}');
  Prompts := TJSONArray(TJSONObject(Response.Find('result')).Find('prompts'));
  Expect<Integer>(Prompts.Count).ToBe(3);
  Review := TJSONObject(Prompts[0]);
  Expect<string>(Review.Get('name', '')).ToBe('review');
  Expect<string>(
    TJSONData(Review.FindPath('arguments[0].name')).AsString).ToBe('code');
  Expect<Boolean>(
    TJSONData(Review.FindPath('arguments[0].required')).AsBoolean)
    .ToBe(True);
  // Optional arguments carry no required flag.
  Expect<Boolean>(
    Review.FindPath('arguments[1].required') = nil).ToBe(True);
  // Required CacheableResult fields (SEP-2549).
  Expect<Integer>(
    TJSONObject(Response.Find('result')).Get('ttlMs', -1)).ToBe(300000);
  Response.Free;
end;

procedure TPromptDispatch.TestGet;
var
  Response: TJSONObject;
  ResultObj: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"prompts/get",' +
    '"params":{"name":"review","arguments":{"code":"x := 1"},' +
    META_MODERN + '}}');
  ResultObj := TJSONObject(Response.Find('result'));
  Expect<string>(ResultObj.Get('description', ''))
    .ToBe('Ask for a code review');
  Expect<string>(
    TJSONData(ResultObj.FindPath('messages[0].content.text')).AsString)
    .ToBe('Review this: x := 1');
  Expect<string>(
    TJSONData(ResultObj.FindPath('messages[1].role')).AsString)
    .ToBe('assistant');
  Expect<string>(ResultObj.Get('resultType', '')).ToBe('complete');
  // GetPromptResult carries no cache fields (they are list/read-only).
  Expect<Boolean>(ResultObj.Find('ttlMs') = nil).ToBe(True);
  Response.Free;
end;

procedure TPromptDispatch.TestGetNoArgsPrompt;
var
  Response: TJSONObject;
begin
  // arguments omitted entirely is valid for an argument-less prompt.
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"prompts/get",' +
    '"params":{"name":"hello",' + META_MODERN + '}}');
  Expect<string>(
    TJSONData(Response.FindPath('result.messages[0].content.text'))
    .AsString).ToBe('Say hello.');
  Response.Free;
end;

procedure TPromptDispatch.TestGetUnknown;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"prompts/get",' +
    '"params":{"name":"nope",' + META_MODERN + '}}');
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(JSONRPC_INVALID_PARAMS);
  Response.Free;
end;

procedure TPromptDispatch.TestGetMissingRequired;
var
  Response: TJSONObject;
begin
  // Prompts surface missing arguments as protocol errors, not isError.
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"prompts/get",' +
    '"params":{"name":"review","arguments":{"style":"brief"},' +
    META_MODERN + '}}');
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(JSONRPC_INVALID_PARAMS);
  Response.Free;
end;

procedure TPromptDispatch.TestGetHandlerRaises;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"prompts/get",' +
    '"params":{"name":"promptboom",' + META_MODERN + '}}');
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(JSONRPC_INTERNAL_ERROR);
  Response.Free;
end;

procedure TPromptDispatch.TestLegacyDialect;
var
  Response: TJSONObject;
  ResultObj: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"initialize",' +
    '"params":{"protocolVersion":"2025-11-25","capabilities":{},' +
    '"clientInfo":{"name":"legacy-client","version":"1.2.3"}}}');
  Expect<Boolean>(
    Response.FindPath('result.capabilities.prompts') <> nil).ToBe(True);
  Response.Free;
  Response := Call('{"jsonrpc":"2.0","id":2,"method":"prompts/list",' +
    '"params":{}}');
  ResultObj := TJSONObject(Response.Find('result'));
  Expect<Integer>(TJSONArray(ResultObj.Find('prompts')).Count).ToBe(3);
  Expect<Boolean>(ResultObj.Find('ttlMs') = nil).ToBe(True);
  Expect<Boolean>(ResultObj.Find('resultType') = nil).ToBe(True);
  Response.Free;
end;

procedure TPromptDispatch.SetupTests;
begin
  Test('prompts/list: definitions + cache fields', TestList);
  Test('prompts/get: messages + description', TestGet);
  Test('prompts/get: argument-less prompt', TestGetNoArgsPrompt);
  Test('prompts/get: unknown prompt → -32602', TestGetUnknown);
  Test('prompts/get: missing required argument → -32602',
    TestGetMissingRequired);
  Test('prompts/get: handler exception → -32603', TestGetHandlerRaises);
  Test('prompts served in the legacy dialect', TestLegacyDialect);
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

procedure TLegacyEra.ExpectInvalidParams(const ALine: string);
var
  Response: TJSONObject;
begin
  Response := Call(ALine);
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(JSONRPC_INVALID_PARAMS);
  Response.Free;
end;

procedure TLegacyEra.TestKnownVersionEchoed;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"initialize",' +
    '"params":{"protocolVersion":"2025-06-18","capabilities":{},' +
    '"clientInfo":{"name":"legacy-client","version":"1.2.3"}}}');
  Expect<string>(
    TJSONObject(Response.Find('result')).Get('protocolVersion', ''))
    .ToBe('2025-06-18');
  Response.Free;
end;

procedure TLegacyEra.TestBatchRevisionAnswersLatestLegacy;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"initialize",' +
    '"params":{"protocolVersion":"2025-03-26","capabilities":{},' +
    '"clientInfo":{"name":"legacy-client","version":"1.2.3"}}}');
  Expect<string>(
    TJSONObject(Response.Find('result')).Get('protocolVersion', ''))
    .ToBe('2025-11-25');
  Response.Free;
end;

procedure TLegacyEra.TestUnknownVersionAnswersLatestLegacy;
var
  Response: TJSONObject;
begin
  // Legacy negotiation: an unknown request gets the server's latest
  // legacy revision; the client decides whether to proceed.
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"initialize",' +
    '"params":{"protocolVersion":"1999-01-01","capabilities":{},' +
    '"clientInfo":{"name":"legacy-client","version":"1.2.3"}}}');
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
    '"params":{"protocolVersion":"2025-11-25","capabilities":{},' +
    '"clientInfo":{"name":"legacy-client","version":"1.2.3"}}}');
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

procedure TLegacyEra.TestInitializeMissingCapabilities;
begin
  ExpectInvalidParams(
    '{"jsonrpc":"2.0","id":1,"method":"initialize",' +
    '"params":{"protocolVersion":"2025-11-25",' +
    '"clientInfo":{"name":"legacy-client","version":"1.2.3"}}}');
end;

procedure TLegacyEra.TestInitializeNonObjectCapabilities;
begin
  ExpectInvalidParams(
    '{"jsonrpc":"2.0","id":1,"method":"initialize",' +
    '"params":{"protocolVersion":"2025-11-25","capabilities":"all",' +
    '"clientInfo":{"name":"legacy-client","version":"1.2.3"}}}');
end;

procedure TLegacyEra.TestInitializeMissingClientInfo;
begin
  ExpectInvalidParams(
    '{"jsonrpc":"2.0","id":1,"method":"initialize",' +
    '"params":{"protocolVersion":"2025-11-25","capabilities":{}}}');
end;

procedure TLegacyEra.TestInitializeIncompleteClientInfo;
begin
  ExpectInvalidParams(
    '{"jsonrpc":"2.0","id":1,"method":"initialize",' +
    '"params":{"protocolVersion":"2025-11-25","capabilities":{},' +
    '"clientInfo":{"name":"legacy-client"}}}');
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

procedure TLegacyEra.TestParamslessToolCall;
begin
  DoInitialize('2025-11-25');
  ExpectInvalidParams(
    '{"jsonrpc":"2.0","id":2,"method":"tools/call"}');
end;

procedure TLegacyEra.TestParamslessResourceRead;
begin
  DoInitialize('2025-11-25');
  ExpectInvalidParams(
    '{"jsonrpc":"2.0","id":2,"method":"resources/read"}');
end;

procedure TLegacyEra.TestParamslessPromptGet;
begin
  DoInitialize('2025-11-25');
  ExpectInvalidParams(
    '{"jsonrpc":"2.0","id":2,"method":"prompts/get"}');
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
  Test('2025-03-26 initialize → 2025-11-25',
    TestBatchRevisionAnswersLatestLegacy);
  Test('unknown version → latest legacy answered',
    TestUnknownVersionAnswersLatestLegacy);
  Test('initialize result shape, unstamped', TestInitializeResultShape);
  Test('initialize without capabilities → -32602',
    TestInitializeMissingCapabilities);
  Test('initialize with non-object capabilities → -32602',
    TestInitializeNonObjectCapabilities);
  Test('initialize without clientInfo → -32602',
    TestInitializeMissingClientInfo);
  Test('initialize with incomplete clientInfo → -32602',
    TestInitializeIncompleteClientInfo);
  Test('request before initialize → -32600', TestRequestBeforeInitialize);
  Test('ping answered before initialize', TestPingBeforeInitialize);
  Test('legacy tools/call after handshake', TestLegacyToolCall);
  Test('legacy tools/call without params → -32602', TestParamslessToolCall);
  Test('legacy resources/read without params → -32602',
    TestParamslessResourceRead);
  Test('legacy prompts/get without params → -32602', TestParamslessPromptGet);
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
    TResourceTemplates.Create('Server: resource templates'));
  TestRunnerProgram.AddSuite(TPromptDispatch.Create('Server: prompts'));
  TestRunnerProgram.AddSuite(
    TNotificationEmission.Create('Server: in-request notifications'));
  TestRunnerProgram.AddSuite(
    TRegistrationGuards.Create('Server: registration guards'));
  TestRunnerProgram.AddSuite(TLegacyEra.Create('Server: legacy era'));
  TestRunnerProgram.Run;
end.
