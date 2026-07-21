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
  SECRET_ERROR_DETAIL = 'käputt — Pfad /tmp/geheim';
  CANCELLED_REQUEST_ID = 'réq-42';

type
  TDispatchSuite = class(TTestSuite)
  protected
    FServer: TMCPServer;
    FSession: TMCPSession;
    FLineSink: TMCPLineSink;
    FLineSinkData: Pointer;
    procedure BeforeEach; override;
    procedure AfterEach; override;
    function Dispatch(const ALine: string; out AResponse: string): Boolean;
    // One request through the server; parsed response (caller frees).
    function Call(const ALine: string): TJSONObject;
    procedure SendNotification(const ALine: string);
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
    procedure TestCallHandlerRaisesRedacted;
    procedure TestDeliberateErrorNotRedacted;
    procedure TestCallUnknown;
    procedure TestCallBadName;
    procedure TestTypedArgsBound;
    procedure TestTypedArgsMissing;
    procedure TestTypedArgsMistyped;
    procedure TestTypedArgsMistypedNotRedacted;
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
    procedure TestReadHandlerRaises;
    procedure TestReadHandlerRaisesRedacted;
  end;

  TRegistrationGuards = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestDuplicateTool;
    procedure TestBadSchema;
    procedure TestNilToolHandler;
    procedure TestNilToolMethod;
    procedure TestNilTypedToolHandler;
    procedure TestNilTypedToolMethod;
    procedure TestNilTypedToolClass;
    procedure TestNilTypedToolOutputClass;
    procedure TestNilToolDefinition;
    procedure TestMissingDefinitionInputSchema;
    procedure TestNonObjectDefinitionInputSchema;
    procedure TestMissingInputSchemaRoot;
    procedure TestWrongInputSchemaRoot;
    procedure TestNonObjectOutputSchema;
    procedure TestWrongOutputSchemaRoot;
    procedure TestValidInputAndOutputSchemaRoots;
    procedure TestDuplicateResource;
    procedure TestNilResourceReader;
    procedure TestNilResourceMethod;
    procedure TestEmptyResourceName;
    procedure TestNilTemplateReader;
    procedure TestNilTemplateMethod;
    procedure TestEmptyTemplateName;
    procedure TestNilPromptHandler;
    procedure TestNilPromptMethod;
    procedure TestEmptyPromptName;
    procedure TestEmptyServerName;
    procedure TestEmptyServerVersion;
    procedure TestNegativeCacheTtl;
    procedure TestInvalidCacheScope;
    procedure TestSchemaConsumedByRegistration;
    procedure TestSameSchemaRejectedWithoutLeak;
    procedure TestPromptArgumentsBuildReuse;
    procedure TestPromptArgumentsAddReuse;
    procedure TestPromptArgumentsConsumedByRegistration;
    procedure TestRegistryFrozenAfterSessionCreation;
    procedure TestEmptyResourceTemplate;
    procedure TestEmptyTemplateVariable;
    procedure TestUnclosedTemplateVariable;
    procedure TestAdjacentTemplateVariables;
    procedure TestStrayTemplateCloseBrace;
    procedure TestInvalidTemplateVariableCharacter;
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
    procedure TestMatcherPathologicalNoMatch;
    procedure TestMatcherPreservesPercentEncoding;
    procedure TestTemplatesList;
    procedure TestEmptyMimeTypeOmitted;
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

  TCancellationDispatch = class(TDispatchSuite)
  private
    FLines: TStringList;
    procedure InitializeLegacy;
    procedure ExpectCancellationSuppressed(const ARequestId,
      ACancellationId: string);
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;
    procedure TestNormalRequestProbeFalse;
    procedure TestCancelledResponseSuppressed;
    procedure TestCancelledNotificationsSuppressed;
    procedure TestFloatRequestCancelledByInteger;
    procedure TestIntegerRequestCancelledByFloat;
    procedure TestLargeIntegerMatchingPreservesPrecision;
    procedure TestMalformedReasonIgnored;
    procedure TestStringReasonAccepted;
    procedure TestModernUnknownAndMalformedIgnored;
    procedure TestLegacyFinishedAndRepeatedIgnored;
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
    procedure TestGetHandlerRaisesRedacted;
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
    procedure TestRequestAwaitingInitialized;
    procedure TestInitializedMakesReady;
    procedure TestDoubleInitializeRejected;
    procedure TestInitializedBeforeInitializeIgnored;
    procedure TestFailedInitializeDoesNotAdvance;
    procedure TestInitializeCancellationIgnored;
    procedure TestLegacyToolCall;
    procedure TestParamslessToolCall;
    procedure TestParamslessResourceRead;
    procedure TestParamslessPromptGet;
    procedure TestLegacyResponsesUnstamped;
    procedure TestLegacyContextVisibleToHandlers;
    procedure TestLegacyResourceNotFound;
    procedure TestErasServedConcurrently;
  end;

  TSessionIsolation = class(TTestSuite)
  private
    FServer: TMCPServer;
    FSessionA: TMCPSession;
    FSessionB: TMCPSession;
    FLinesA: TStringList;
    FLinesB: TStringList;
    function Call(ASession: TMCPSession; const ALine: string;
      ASink: TMCPLineSink = nil; ASinkData: Pointer = nil): TJSONObject;
    procedure SendNotification(ASession: TMCPSession;
      const ALine: string);
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;
    procedure TestIndependentLegacyNegotiation;
    procedure TestIndependentNotificationSinks;
    procedure TestLifecycleIsolation;
    procedure TestForeignSessionRejected;
    procedure TestNilSessionRejected;
  end;

  TWireEncoding = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestModernToolsListLine;
    procedure TestLegacyInitializeLine;
    procedure TestProgressNotificationLine;
  end;

{ ───────── handlers under test ───────── }

var
  CancellationServer: TMCPServer;
  CancellationSession: TMCPSession;
  CancellationTargetJson: string;
  CancellationNotificationLine: string;
  CancellationObserved: Boolean;
  CancellationProbePresent: Boolean;

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

function DeliberateErrorHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPErrorResult('correctable detail');
end;

// Mirrors the request context so era plumbing is handler-observable.
function WhoAmIHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  CapabilityMarker: string;
begin
  CapabilityMarker := 'no-roots';
  if (ACtx.ClientCapabilities <> nil) and
     (ACtx.ClientCapabilities.Find('roots') <> nil) then
    CapabilityMarker := 'roots';
  Result := MCPTextResult(ACtx.ProtocolVersion + '|' + ACtx.ClientName +
    '|' + ACtx.ClientVersion + '|' + CapabilityMarker);
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

function SecretReader(const AUri: string;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  raise Exception.Create(SECRET_ERROR_DETAIL);
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

function CancellationAwareHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  CancellationProbePresent := Assigned(ACtx.CancellationProbe);
  CancellationObserved := ACtx.IsCancelled;
  Result := MCPTextResult('not cancelled');
end;

function SelfCancellingHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  RequestId: TJSONData;
begin
  RequestId := GetJSON(CancellationTargetJson);
  try
    CancellationSession.CancelRequest(RequestId);
    // Repeated signals are idempotent while the request is active.
    CancellationSession.CancelRequest(RequestId);
  finally
    RequestId.Free;
  end;
  RequestId := GetJSON('"another-request"');
  try
    // An unknown id cannot undo an already accepted cancellation.
    CancellationSession.CancelRequest(RequestId);
  finally
    RequestId.Free;
  end;
  CancellationObserved := ACtx.IsCancelled;
  MCPReportProgress(ACtx, 0.5, 1.0, 'must be suppressed');
  MCPLogMessage(ACtx, 'info', 'must also be suppressed');
  Result := MCPTextResult('must not be emitted');
end;

function NotificationCancellingHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Response: string;
begin
  CancellationServer.HandleMessage(CancellationSession,
    CancellationNotificationLine, Response);
  CancellationObserved := ACtx.IsCancelled;
  Result := MCPTextResult('notification processed');
end;

procedure CaptureSink(const ALine: string; AUserData: Pointer);
begin
  TStringList(AUserData).Add(ALine);
end;

procedure ExpectRedactedExceptionMessage(const AMessage, AGenericMessage,
  ASecret: string);
begin
  Expect<Boolean>(Pos(AGenericMessage + ' (ref mcp-err-', AMessage) = 1)
    .ToBe(True);
  Expect<Boolean>((AMessage <> '') and
    (AMessage[Length(AMessage)] = ')')).ToBe(True);
  Expect<Boolean>(Pos(ASecret, AMessage) = 0).ToBe(True);
end;

function PairReader(const AUri: string; AVars: TJSONObject;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  Result := MCPTextContents(AUri, 'text/plain',
    AVars.Get('a', '') + '|' + AVars.Get('b', ''));
end;

function ResourceTemplateCount(AServer: TMCPServer): Integer;
var
  ResponseLine: string;
  Response: TJSONObject;
  Session: TMCPSession;
begin
  Session := AServer.CreateSession;
  try
    if not AServer.HandleMessage(Session,
      '{"jsonrpc":"2.0","id":1,"method":"resources/templates/list",' +
      '"params":{' + META_MODERN + '}}', ResponseLine) then
      raise Exception.Create(
        'Expected a resource template list response, got none');
    Response := TJSONObject(GetJSON(ResponseLine));
    try
      Result := TJSONArray(
        TJSONObject(Response.Find('result')).Find('resourceTemplates')).Count;
    finally
      Response.Free;
    end;
  finally
    Session.Free;
  end;
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
    Expect<Integer>(ResourceTemplateCount(Server)).ToBe(0);
  finally
    Server.Free;
  end;
end;

{ ───────── shared fixture ───────── }

procedure TDispatchSuite.BeforeEach;
begin
  FSession := nil;
  FLineSink := nil;
  FLineSinkData := nil;
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
  FreeAndNil(FSession);
  FreeAndNil(FServer);
end;

function TDispatchSuite.Dispatch(const ALine: string;
  out AResponse: string): Boolean;
begin
  if FSession = nil then
    FSession := FServer.CreateSession;
  Result := FServer.HandleMessage(FSession, ALine, FLineSink,
    FLineSinkData, AResponse);
end;

function TDispatchSuite.Call(const ALine: string): TJSONObject;
var
  Response: string;
begin
  if not Dispatch(ALine, Response) then
    Fail('expected a response, got none');
  Result := TJSONObject(GetJSON(Response));
end;

procedure TDispatchSuite.SendNotification(const ALine: string);
var
  Response: string;
begin
  Expect<Boolean>(Dispatch(ALine, Response)).ToBe(False);
  Expect<string>(Response).ToBe('');
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
  Expect<Boolean>(Dispatch(
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

procedure TToolDispatch.TestCallHandlerRaisesRedacted;
var
  FirstMessage, SecondMessage: string;
  Response: TJSONObject;
begin
  FServer.RedactErrorDetails := True;
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"boom",' + META_MODERN + '}}');
  FirstMessage := TJSONData(
    Response.FindPath('result.content[0].text')).AsString;
  ExpectRedactedExceptionMessage(FirstMessage, 'Tool execution failed',
    'boom');
  Response.Free;

  Response := Call('{"jsonrpc":"2.0","id":2,"method":"tools/call",' +
    '"params":{"name":"boom",' + META_MODERN + '}}');
  SecondMessage := TJSONData(
    Response.FindPath('result.content[0].text')).AsString;
  ExpectRedactedExceptionMessage(SecondMessage, 'Tool execution failed',
    'boom');
  Expect<Boolean>(FirstMessage <> SecondMessage).ToBe(True);
  Response.Free;
end;

procedure TToolDispatch.TestDeliberateErrorNotRedacted;
var
  Response: TJSONObject;
begin
  FServer.RegisterTool('expected-error', 'Returns an expected error',
    '{"type":"object"}', DeliberateErrorHandler);
  FServer.RedactErrorDetails := True;
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"expected-error",' + META_MODERN + '}}');
  Expect<Boolean>(
    TJSONData(Response.FindPath('result.isError')).AsBoolean).ToBe(True);
  Expect<string>(
    TJSONData(Response.FindPath('result.content[0].text')).AsString)
    .ToBe('correctable detail');
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

procedure TToolDispatch.TestTypedArgsMistypedNotRedacted;
var
  Response: TJSONObject;
begin
  FServer.RedactErrorDetails := True;
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"scale","arguments":{"value":2.5,' +
    '"times":"four"},' + META_MODERN + '}}');
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
  Test('tools/call: handler exception redacted with unique reference',
    TestCallHandlerRaisesRedacted);
  Test('tools/call: deliberate isError survives redaction',
    TestDeliberateErrorNotRedacted);
  Test('tools/call: unknown tool → -32602', TestCallUnknown);
  Test('tools/call: non-string name → -32602', TestCallBadName);
  Test('typed args: bound and populated', TestTypedArgsBound);
  Test('typed args: missing argument → isError', TestTypedArgsMissing);
  Test('typed args: mistyped argument → isError', TestTypedArgsMistyped);
  Test('typed args: binding error survives redaction',
    TestTypedArgsMistypedNotRedacted);
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

procedure TResourceDispatch.TestReadHandlerRaises;
var
  ResponseLine: string;
  Response: TJSONObject;
begin
  FServer.RegisterResource('mem://secret', 'secret', 'text/plain',
    SecretReader);
  Expect<Boolean>(Dispatch(
    '{"jsonrpc":"2.0","id":1,"method":"resources/read",' +
    '"params":{"uri":"mem://secret",' + META_MODERN + '}}',
    ResponseLine)).ToBe(True);
  Expect<string>(ResponseLine).ToBe(
    '{ "jsonrpc" : "2.0", "id" : 1, "error" : { "code" : -32603, ' +
    '"message" : "Internal error: ' + SECRET_ERROR_DETAIL + '" } }');
  Response := TJSONObject(GetJSON(ResponseLine));
  try
    Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
      .ToBe(JSONRPC_INTERNAL_ERROR);
    Expect<string>(TJSONData(Response.FindPath('error.message')).AsString)
      .ToBe('Internal error: ' + SECRET_ERROR_DETAIL);
  finally
    Response.Free;
  end;
end;

procedure TResourceDispatch.TestReadHandlerRaisesRedacted;
var
  ClientMessage, ResponseLine: string;
  Response: TJSONObject;
begin
  FServer.RegisterResource('mem://secret', 'secret', 'text/plain',
    SecretReader);
  FServer.RedactErrorDetails := True;
  Expect<Boolean>(Dispatch(
    '{"jsonrpc":"2.0","id":1,"method":"resources/read",' +
    '"params":{"uri":"mem://secret",' + META_MODERN + '}}',
    ResponseLine)).ToBe(True);
  Response := TJSONObject(GetJSON(ResponseLine));
  try
    Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
      .ToBe(JSONRPC_INTERNAL_ERROR);
    ClientMessage := TJSONData(Response.FindPath('error.message')).AsString;
    ExpectRedactedExceptionMessage(ClientMessage, 'Internal error',
      SECRET_ERROR_DETAIL);
    Expect<string>(ResponseLine).ToBe(
      '{ "jsonrpc" : "2.0", "id" : 1, "error" : { "code" : -32603, ' +
      '"message" : "' + ClientMessage + '" } }');
    Expect<Boolean>(Pos(SECRET_ERROR_DETAIL, ResponseLine) = 0).ToBe(True);
    Expect<Boolean>(Pos('/tmp/geheim', ResponseLine) = 0).ToBe(True);
  finally
    Response.Free;
  end;
end;

procedure TResourceDispatch.SetupTests;
begin
  Test('resources/list: all resources', TestList);
  Test('resources/read: static text', TestReadStatic);
  Test('resources/read: dynamic reader', TestReadDynamic);
  Test('resources/read: not found → -32602 + data.uri', TestReadNotFound);
  Test('resources/read: reader exception verbose by default',
    TestReadHandlerRaises);
  Test('resources/read: reader exception redacted on encoded wire',
    TestReadHandlerRaisesRedacted);
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

procedure TRegistrationGuards.TestNilToolHandler;
var
  ErrorMessage: string;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    ErrorMessage := '';
    try
      Server.RegisterTool('wärkzeug', 'desc', '{"type":"object"}',
        TMCPToolHandler(nil));
    except
      on E: EMCPServer do
        ErrorMessage := E.Message;
    end;
    Expect<string>(ErrorMessage)
      .ToBe('Tool "wärkzeug" must have exactly one callable');
    Expect<Integer>(Server.ToolCount).ToBe(0);
  finally
    Server.Free;
  end;
end;

procedure TRegistrationGuards.TestNilToolMethod;
var
  Raised: Boolean;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Raised := False;
    try
      Server.RegisterTool('method-tool', 'desc', '{"type":"object"}',
        TMCPToolMethod(nil));
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

procedure TRegistrationGuards.TestNilTypedToolHandler;
var
  Raised: Boolean;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Raised := False;
    try
      Server.RegisterTool('typed', 'desc', TScaleArgs,
        TMCPArgsHandler(nil));
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

procedure TRegistrationGuards.TestNilTypedToolMethod;
var
  Raised: Boolean;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Raised := False;
    try
      Server.RegisterTool('typed-method', 'desc', TScaleArgs,
        TMCPArgsMethod(nil));
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

procedure TRegistrationGuards.TestNilTypedToolClass;
var
  ErrorMessage: string;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    ErrorMessage := '';
    try
      Server.RegisterTool('typed', 'desc', TMCPArgsClass(nil), ScaleHandler);
    except
      on E: EMCPServer do
        ErrorMessage := E.Message;
    end;
    Expect<string>(ErrorMessage)
      .ToBe('Typed tool "typed" requires a non-nil input argument class');
    Expect<Integer>(Server.ToolCount).ToBe(0);
  finally
    Server.Free;
  end;
end;

procedure TRegistrationGuards.TestNilTypedToolOutputClass;
var
  ErrorMessage: string;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    ErrorMessage := '';
    try
      Server.RegisterTool('typed-output', 'desc', TScaleArgs,
        TMCPArgsClass(nil), ScaleHandler);
    except
      on E: EMCPServer do
        ErrorMessage := E.Message;
    end;
    Expect<string>(ErrorMessage)
      .ToBe('Typed tool "typed-output" requires a non-nil output argument class');
    Expect<Integer>(Server.ToolCount).ToBe(0);
  finally
    Server.Free;
  end;
end;

procedure TRegistrationGuards.TestNilToolDefinition;
var
  ErrorMessage: string;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    ErrorMessage := '';
    try
      Server.RegisterTool(TJSONObject(nil), EchoHandler);
    except
      on E: EMCPServer do
        ErrorMessage := E.Message;
    end;
    Expect<string>(ErrorMessage).ToBe('Tool definition must not be nil');
    Expect<Integer>(Server.ToolCount).ToBe(0);
  finally
    Server.Free;
  end;
end;

procedure TRegistrationGuards.TestMissingDefinitionInputSchema;
var
  Definition: TJSONObject;
  ErrorMessage: string;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Definition := TJSONObject.Create;
    Definition.Add('name', 'raw');
    ErrorMessage := '';
    try
      Server.RegisterTool(Definition, EchoHandler);
    except
      on E: EMCPServer do
        ErrorMessage := E.Message;
    end;
    Expect<string>(ErrorMessage)
      .ToBe('Tool "raw" definition must carry an object-valued inputSchema');
    Expect<Integer>(Server.ToolCount).ToBe(0);
  finally
    Server.Free;
  end;
end;

procedure TRegistrationGuards.TestNonObjectDefinitionInputSchema;
var
  Definition: TJSONObject;
  Raised: Boolean;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Definition := TJSONObject.Create;
    Definition.Add('name', 'raw');
    Definition.Add('inputSchema', 'not-an-object');
    Raised := False;
    try
      Server.RegisterTool(Definition, EchoHandler);
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

procedure TRegistrationGuards.TestMissingInputSchemaRoot;
var
  Definition: TJSONObject;
  Raised: Boolean;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Raised := False;
    try
      Server.RegisterTool('empty-root', 'desc', '{}', EchoHandler);
    except
      on EMCPServer do
        Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);

    Definition := TJSONObject.Create;
    Definition.Add('name', 'empty-definition-root');
    Definition.Add('inputSchema', GetJSON('{}'));
    Raised := False;
    try
      Server.RegisterTool(Definition, EchoHandler);
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

procedure TRegistrationGuards.TestWrongInputSchemaRoot;
var
  Definition: TJSONObject;
  Raised: Boolean;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Raised := False;
    try
      Server.RegisterTool('array-root', 'desc', '{"type":"array"}',
        EchoHandler);
    except
      on EMCPServer do
        Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);

    Definition := TJSONObject.Create;
    Definition.Add('name', 'array-definition-root');
    Definition.Add('inputSchema', GetJSON('{"type":"array"}'));
    Raised := False;
    try
      Server.RegisterTool(Definition, EchoHandler);
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

procedure TRegistrationGuards.TestNonObjectOutputSchema;
var
  Definition: TJSONObject;
  Raised: Boolean;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Definition := TJSONObject.Create;
    Definition.Add('name', 'bad-output');
    Definition.Add('inputSchema', GetJSON('{"type":"object"}'));
    Definition.Add('outputSchema', 'not-an-object');
    Raised := False;
    try
      Server.RegisterTool(Definition, EchoHandler);
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

procedure TRegistrationGuards.TestWrongOutputSchemaRoot;
var
  Definition: TJSONObject;
  Raised: Boolean;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Definition := TJSONObject.Create;
    Definition.Add('name', 'array-output');
    Definition.Add('inputSchema', GetJSON('{"type":"object"}'));
    Definition.Add('outputSchema', GetJSON('{"type":"array"}'));
    Raised := False;
    try
      Server.RegisterTool(Definition, EchoHandler);
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

procedure TRegistrationGuards.TestValidInputAndOutputSchemaRoots;
var
  Definition: TJSONObject;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Definition := TJSONObject.Create;
    Definition.Add('name', 'valid-roots');
    Definition.Add('inputSchema', GetJSON('{"type":"object"}'));
    Definition.Add('outputSchema', GetJSON('{"type":"object"}'));
    Server.RegisterTool(Definition, EchoHandler);
    Expect<Integer>(Server.ToolCount).ToBe(1);
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

procedure TRegistrationGuards.TestNilResourceReader;
var
  Raised: Boolean;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Raised := False;
    try
      Server.RegisterResource('mem://nil-reader', 'nil reader', 'text/plain',
        TMCPResourceReader(nil));
    except
      on EMCPServer do
        Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
    Expect<Integer>(Server.ResourceCount).ToBe(0);
  finally
    Server.Free;
  end;
end;

procedure TRegistrationGuards.TestNilResourceMethod;
var
  Raised: Boolean;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Raised := False;
    try
      Server.RegisterResource('mem://nil-method', 'nil method', 'text/plain',
        TMCPResourceMethod(nil));
    except
      on EMCPServer do
        Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
    Expect<Integer>(Server.ResourceCount).ToBe(0);
  finally
    Server.Free;
  end;
end;

procedure TRegistrationGuards.TestEmptyResourceName;
var
  Raised: Boolean;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Raised := False;
    try
      Server.RegisterTextResource('mem://unnamed', '', 'text/plain', 'text');
    except
      on EMCPServer do
        Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
    Expect<Integer>(Server.ResourceCount).ToBe(0);
  finally
    Server.Free;
  end;
end;

procedure TRegistrationGuards.TestNilTemplateReader;
var
  Raised: Boolean;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Raised := False;
    try
      Server.RegisterResourceTemplate('mem://nil/{id}', 'nil reader',
        'text/plain', TMCPTemplateReader(nil));
    except
      on EMCPServer do
        Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
    Expect<Integer>(ResourceTemplateCount(Server)).ToBe(0);
  finally
    Server.Free;
  end;
end;

procedure TRegistrationGuards.TestNilTemplateMethod;
var
  Raised: Boolean;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Raised := False;
    try
      Server.RegisterResourceTemplate('mem://nil-method/{id}', 'nil method',
        'text/plain', TMCPTemplateMethod(nil));
    except
      on EMCPServer do
        Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
    Expect<Integer>(ResourceTemplateCount(Server)).ToBe(0);
  finally
    Server.Free;
  end;
end;

procedure TRegistrationGuards.TestEmptyTemplateName;
var
  Raised: Boolean;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Raised := False;
    try
      Server.RegisterResourceTemplate('mem://unnamed/{id}', '', 'text/plain',
        PairReader);
    except
      on EMCPServer do
        Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
    Expect<Integer>(ResourceTemplateCount(Server)).ToBe(0);
  finally
    Server.Free;
  end;
end;

procedure TRegistrationGuards.TestNilPromptHandler;
var
  Raised: Boolean;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Raised := False;
    try
      Server.RegisterPrompt('nil-handler', 'desc', TMCPPromptHandler(nil));
    except
      on EMCPServer do
        Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
    Expect<Integer>(Server.PromptCount).ToBe(0);
  finally
    Server.Free;
  end;
end;

procedure TRegistrationGuards.TestNilPromptMethod;
var
  Raised: Boolean;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Raised := False;
    try
      Server.RegisterPrompt('nil-method', 'desc', TMCPPromptMethod(nil));
    except
      on EMCPServer do
        Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
    Expect<Integer>(Server.PromptCount).ToBe(0);
  finally
    Server.Free;
  end;
end;

procedure TRegistrationGuards.TestEmptyPromptName;
var
  Raised: Boolean;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Raised := False;
    try
      Server.RegisterPrompt('', 'desc', HelloPromptHandler);
    except
      on EMCPServer do
        Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
    Expect<Integer>(Server.PromptCount).ToBe(0);
  finally
    Server.Free;
  end;
end;

procedure TRegistrationGuards.TestEmptyServerName;
var
  Raised: Boolean;
  Server: TMCPServer;
begin
  Server := nil;
  Raised := False;
  try
    Server := TMCPServer.Create('', '1');
  except
    on EMCPServer do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  Server.Free;
end;

procedure TRegistrationGuards.TestEmptyServerVersion;
var
  Raised: Boolean;
  Server: TMCPServer;
begin
  Server := nil;
  Raised := False;
  try
    Server := TMCPServer.Create('t', '');
  except
    on EMCPServer do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  Server.Free;
end;

procedure TRegistrationGuards.TestNegativeCacheTtl;
var
  Raised: Boolean;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Raised := False;
    try
      Server.CacheTtlMs := -1;
    except
      on EMCPServer do
        Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
    Expect<Integer>(Server.CacheTtlMs).ToBe(300000);
  finally
    Server.Free;
  end;
end;

procedure TRegistrationGuards.TestInvalidCacheScope;
var
  Raised: Boolean;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Raised := False;
    try
      Server.CacheScope := 'Private';
    except
      on EMCPServer do
        Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
    Expect<string>(Server.CacheScope).ToBe(CACHE_SCOPE_PRIVATE);
  finally
    Server.Free;
  end;
end;

procedure TRegistrationGuards.TestSchemaConsumedByRegistration;
var
  Builder: TMCPSchema;
  ErrorMessage: string;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Builder := ObjectSchema.AddString('value');
    Server.RegisterTool('first', 'desc', Builder, EchoHandler);
    ErrorMessage := '';
    try
      Server.RegisterTool('second', 'desc', Builder, EchoHandler);
    except
      on E: EMCPSchema do
        ErrorMessage := E.Message;
    end;
    Expect<string>(ErrorMessage).ToBe('Schema was already built');
    Expect<Integer>(Server.ToolCount).ToBe(1);
  finally
    Server.Free;
  end;
end;

procedure TRegistrationGuards.TestSameSchemaRejectedWithoutLeak;
var
  Builder: TMCPSchema;
  ErrorMessage: string;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Builder := ObjectSchema.AddString('value');
    ErrorMessage := '';
    try
      Server.RegisterTool('same-schema', 'desc', Builder, Builder,
        EchoHandler);
    except
      on E: EMCPSchema do
        ErrorMessage := E.Message;
    end;
    Expect<string>(ErrorMessage).ToBe('Schema was already built');
    Expect<Integer>(Server.ToolCount).ToBe(0);
  finally
    Server.Free;
  end;
end;

procedure TRegistrationGuards.TestPromptArgumentsBuildReuse;
var
  Arguments: TMCPPromptArguments;
  BuiltArguments: TJSONArray;
  ErrorMessage: string;
begin
  Arguments := PromptArguments.Add('value');
  BuiltArguments := Arguments.Build;
  ErrorMessage := '';
  try
    Arguments.Build;
  except
    on E: EMCPServer do
      ErrorMessage := E.Message;
  end;
  Expect<string>(ErrorMessage).ToBe('Prompt arguments were already built');
  BuiltArguments.Free;
end;

procedure TRegistrationGuards.TestPromptArgumentsAddReuse;
var
  Arguments: TMCPPromptArguments;
  BuiltArguments: TJSONArray;
  ErrorMessage: string;
begin
  Arguments := PromptArguments;
  BuiltArguments := Arguments.Build;
  ErrorMessage := '';
  try
    Arguments.Add('late');
  except
    on E: EMCPServer do
      ErrorMessage := E.Message;
  end;
  Expect<string>(ErrorMessage).ToBe('Prompt arguments were already built');
  BuiltArguments.Free;
end;

procedure TRegistrationGuards.TestPromptArgumentsConsumedByRegistration;
var
  Arguments: TMCPPromptArguments;
  ErrorMessage: string;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Arguments := PromptArguments.Add('value');
    Server.RegisterPrompt('first', 'desc', Arguments, HelloPromptHandler);
    ErrorMessage := '';
    try
      Server.RegisterPrompt('second', 'desc', Arguments, HelloPromptHandler);
    except
      on E: EMCPServer do
        ErrorMessage := E.Message;
    end;
    Expect<string>(ErrorMessage).ToBe('Prompt arguments were already built');
    Expect<Integer>(Server.PromptCount).ToBe(1);
  finally
    Server.Free;
  end;
end;

procedure TRegistrationGuards.TestRegistryFrozenAfterSessionCreation;
const
  FROZEN_MESSAGE = 'Server configuration is frozen after session creation';
var
  ErrorMessage: string;
  Options: TMCPToolOptions;
  Server: TMCPServer;
  Session: TMCPSession;

  procedure ExpectFrozen;
  begin
    Expect<string>(ErrorMessage).ToBe(FROZEN_MESSAGE);
  end;

begin
  Server := TMCPServer.Create('t', '1');
  try
    Server.Instructions := 'frozen instructions';
    Server.CacheTtlMs := 1234;
    Server.CacheScope := CACHE_SCOPE_PUBLIC;
    Server.RedactErrorDetails := True;
    Server.DualEra := False;
    Options := Server.RegisterTool('first', 'desc', '{"type":"object"}',
      EchoHandler);
    Session := Server.CreateSession;
    try
      ErrorMessage := '';
      try
        Server.RegisterTool('late', 'desc', '{"type":"object"}',
          EchoHandler);
      except
        on E: EMCPServer do
          ErrorMessage := E.Message;
      end;
      ExpectFrozen;

      ErrorMessage := '';
      try
        Server.RegisterTextResource('mem://late', 'late', 'text/plain',
          'late');
      except
        on E: EMCPServer do
          ErrorMessage := E.Message;
      end;
      ExpectFrozen;

      ErrorMessage := '';
      try
        Server.RegisterResourceTemplate('mem://late/{value}', 'late',
          'text/plain', PairReader);
      except
        on E: EMCPServer do
          ErrorMessage := E.Message;
      end;
      ExpectFrozen;

      ErrorMessage := '';
      try
        Server.RegisterPrompt('late', 'desc', HelloPromptHandler);
      except
        on E: EMCPServer do
          ErrorMessage := E.Message;
      end;
      ExpectFrozen;

      ErrorMessage := '';
      try
        Options.Title('too late');
      except
        on E: EMCPServer do
          ErrorMessage := E.Message;
      end;
      ExpectFrozen;

      ErrorMessage := '';
      try
        Server.Instructions := 'too late';
      except
        on E: EMCPServer do
          ErrorMessage := E.Message;
      end;
      ExpectFrozen;

      ErrorMessage := '';
      try
        Server.CacheTtlMs := 9;
      except
        on E: EMCPServer do
          ErrorMessage := E.Message;
      end;
      ExpectFrozen;

      ErrorMessage := '';
      try
        Server.CacheScope := CACHE_SCOPE_PRIVATE;
      except
        on E: EMCPServer do
          ErrorMessage := E.Message;
      end;
      ExpectFrozen;

      ErrorMessage := '';
      try
        Server.RedactErrorDetails := False;
      except
        on E: EMCPServer do
          ErrorMessage := E.Message;
      end;
      ExpectFrozen;

      ErrorMessage := '';
      try
        Server.DualEra := True;
      except
        on E: EMCPServer do
          ErrorMessage := E.Message;
      end;
      ExpectFrozen;

      Expect<Integer>(Server.ToolCount).ToBe(1);
      Expect<Integer>(Server.ResourceCount).ToBe(0);
      Expect<Integer>(Server.PromptCount).ToBe(0);
      Expect<string>(Server.Instructions).ToBe('frozen instructions');
      Expect<Integer>(Server.CacheTtlMs).ToBe(1234);
      Expect<string>(Server.CacheScope).ToBe(CACHE_SCOPE_PUBLIC);
      Expect<Boolean>(Server.RedactErrorDetails).ToBe(True);
      Expect<Boolean>(Server.DualEra).ToBe(False);
    finally
      Session.Free;
    end;
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

procedure TRegistrationGuards.TestStrayTemplateCloseBrace;
begin
  ExpectTemplateRegistrationError('mem://item/name}',
    'Invalid resource template "mem://item/name}": stray "}" at character 16');
end;

procedure TRegistrationGuards.TestInvalidTemplateVariableCharacter;
begin
  ExpectTemplateRegistrationError('mem://item/{+path}',
    'Invalid resource template "mem://item/{+path}": variable name must contain only A-Z, a-z, 0-9, and _');
end;

procedure TRegistrationGuards.SetupTests;
begin
  Test('duplicate tool name rejected', TestDuplicateTool);
  Test('invalid schema JSON rejected', TestBadSchema);
  Test('nil tool handler rejected with UTF-8 name', TestNilToolHandler);
  Test('nil tool method rejected', TestNilToolMethod);
  Test('nil typed-tool handler rejected', TestNilTypedToolHandler);
  Test('nil typed-tool method rejected', TestNilTypedToolMethod);
  Test('nil typed-tool argument class rejected', TestNilTypedToolClass);
  Test('nil typed-tool output class rejected', TestNilTypedToolOutputClass);
  Test('nil tool definition rejected', TestNilToolDefinition);
  Test('missing definition inputSchema rejected',
    TestMissingDefinitionInputSchema);
  Test('non-object definition inputSchema rejected',
    TestNonObjectDefinitionInputSchema);
  Test('inputSchema without root type rejected', TestMissingInputSchemaRoot);
  Test('inputSchema array root rejected', TestWrongInputSchemaRoot);
  Test('non-object outputSchema rejected', TestNonObjectOutputSchema);
  Test('outputSchema array root rejected', TestWrongOutputSchemaRoot);
  Test('object inputSchema and outputSchema accepted',
    TestValidInputAndOutputSchemaRoots);
  Test('duplicate resource uri rejected', TestDuplicateResource);
  Test('nil resource reader rejected', TestNilResourceReader);
  Test('nil resource method rejected', TestNilResourceMethod);
  Test('empty resource display name rejected', TestEmptyResourceName);
  Test('nil resource-template reader rejected', TestNilTemplateReader);
  Test('nil resource-template method rejected', TestNilTemplateMethod);
  Test('empty resource-template display name rejected',
    TestEmptyTemplateName);
  Test('nil prompt handler rejected', TestNilPromptHandler);
  Test('nil prompt method rejected', TestNilPromptMethod);
  Test('empty prompt name rejected', TestEmptyPromptName);
  Test('empty server name rejected', TestEmptyServerName);
  Test('empty server version rejected', TestEmptyServerVersion);
  Test('negative cache TTL rejected', TestNegativeCacheTtl);
  Test('invalid cache scope rejected', TestInvalidCacheScope);
  Test('tool registration consumes schema builder',
    TestSchemaConsumedByRegistration);
  Test('same input/output schema rejects reuse without leaking',
    TestSameSchemaRejectedWithoutLeak);
  Test('prompt argument Build rejects reuse', TestPromptArgumentsBuildReuse);
  Test('prompt argument Add rejects reuse', TestPromptArgumentsAddReuse);
  Test('prompt registration consumes argument builder',
    TestPromptArgumentsConsumedByRegistration);
  Test('session creation freezes registries and request configuration',
    TestRegistryFrozenAfterSessionCreation);
  Test('empty resource template rejected', TestEmptyResourceTemplate);
  Test('empty template variable rejected', TestEmptyTemplateVariable);
  Test('unclosed template variable rejected', TestUnclosedTemplateVariable);
  Test('adjacent template variables rejected', TestAdjacentTemplateVariables);
  Test('stray template close brace rejected', TestStrayTemplateCloseBrace);
  Test('invalid template variable character rejected',
    TestInvalidTemplateVariableCharacter);
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

procedure TResourceTemplates.TestMatcherPathologicalNoMatch;
var
  StartedAt: QWord;
  Vars: TJSONObject;
begin
  StartedAt := GetTickCount64;
  Expect<Boolean>(MatchUriTemplate('{a}x{b}x{c}x{d}x{e}x{f}xZ',
    StringOfChar('x', 4096), Vars)).ToBe(False);
  Expect<Boolean>(GetTickCount64 - StartedAt < 2000).ToBe(True);
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

procedure TResourceTemplates.TestEmptyMimeTypeOmitted;
var
  Response: TJSONObject;
  Templates: TJSONArray;
begin
  FServer.RegisterResourceTemplate('mem://optional/{id}', 'optional', '',
    PairReader);
  Response := Call(
    '{"jsonrpc":"2.0","id":1,"method":"resources/templates/list",' +
    '"params":{' + META_MODERN + '}}');
  Templates := TJSONArray(
    TJSONObject(Response.Find('result')).Find('resourceTemplates'));
  Expect<Integer>(Templates.Count).ToBe(2);
  Expect<Boolean>(TJSONObject(Templates[1]).Find('mimeType') = nil).ToBe(True);
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
  SendNotification(
    '{"jsonrpc":"2.0","method":"notifications/initialized"}');
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
  Test('matcher: bounds pathological backtracking',
    TestMatcherPathologicalNoMatch);
  Test('matcher: percent encoding remains encoded',
    TestMatcherPreservesPercentEncoding);
  Test('resources/templates/list: shape + cache fields',
    TestTemplatesList);
  Test('resources/templates/list: empty mimeType omitted',
    TestEmptyMimeTypeOmitted);
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
  FLineSink := CaptureSink;
  FLineSinkData := FLines;
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
  SendNotification(
    '{"jsonrpc":"2.0","method":"notifications/initialized"}');
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
  FLineSink := nil;
  FLineSinkData := nil;
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

{ ───────── cooperative cancellation ───────── }

procedure TCancellationDispatch.BeforeEach;
begin
  inherited BeforeEach;
  FServer.RegisterTool('cancellation-aware', 'Polls cancellation',
    '{"type":"object"}', CancellationAwareHandler);
  FServer.RegisterTool('self-cancel', 'Cancels its own request',
    '{"type":"object"}', SelfCancellingHandler);
  FServer.RegisterTool('notification-cancel', 'Receives cancellation',
    '{"type":"object"}', NotificationCancellingHandler);
  FLines := TStringList.Create;
  FLineSink := CaptureSink;
  FLineSinkData := FLines;
  FSession := FServer.CreateSession;
  CancellationServer := FServer;
  CancellationSession := FSession;
  CancellationTargetJson := '"r\u00e9q-42"';
  CancellationNotificationLine := '';
  CancellationObserved := False;
  CancellationProbePresent := False;
end;

procedure TCancellationDispatch.AfterEach;
begin
  CancellationServer := nil;
  CancellationSession := nil;
  FreeAndNil(FLines);
  inherited AfterEach;
end;

procedure TCancellationDispatch.ExpectCancellationSuppressed(
  const ARequestId, ACancellationId: string);
var
  ResponseLine: string;
begin
  CancellationTargetJson := ACancellationId;
  Expect<Boolean>(Dispatch(
    '{"jsonrpc":"2.0","id":' + ARequestId + ',' +
    '"method":"tools/call","params":{"name":"self-cancel",' +
    META_MODERN + '}}', ResponseLine)).ToBe(False);
  Expect<string>(ResponseLine).ToBe('');
  Expect<Boolean>(CancellationObserved).ToBe(True);
end;

procedure TCancellationDispatch.InitializeLegacy;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":100,"method":"initialize",' +
    '"params":{"protocolVersion":"2025-11-25","capabilities":{},' +
    '"clientInfo":{"name":"cancel-test","version":"1"}}}');
  Response.Free;
  SendNotification(
    '{"jsonrpc":"2.0","method":"notifications/initialized"}');
end;

procedure TCancellationDispatch.TestNormalRequestProbeFalse;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"cancellation-aware",' + META_MODERN + '}}');
  Expect<Boolean>(CancellationObserved).ToBe(False);
  Expect<Boolean>(CancellationProbePresent).ToBe(True);
  Expect<string>(TJSONData(Response.FindPath('result.content[0].text'))
    .AsString).ToBe('not cancelled');
  Response.Free;
end;

procedure TCancellationDispatch.TestCancelledResponseSuppressed;
var
  ResponseLine: string;
  Response: TJSONObject;
begin
  Expect<Boolean>(Dispatch(
    '{"jsonrpc":"2.0","id":"' + CANCELLED_REQUEST_ID + '",' +
    '"method":"tools/call","params":{"name":"self-cancel",' +
    META_MODERN + '}}', ResponseLine)).ToBe(False);
  Expect<string>(ResponseLine).ToBe('');
  Expect<Boolean>(CancellationObserved).ToBe(True);

  Response := Call('{"jsonrpc":"2.0","id":43,"method":"tools/call",' +
    '"params":{"name":"cancellation-aware",' + META_MODERN + '}}');
  Expect<Boolean>(CancellationObserved).ToBe(False);
  Expect<string>(TJSONData(Response.FindPath('result.content[0].text'))
    .AsString).ToBe('not cancelled');
  Response.Free;
end;

procedure TCancellationDispatch.TestCancelledNotificationsSuppressed;
var
  ResponseLine: string;
begin
  Expect<Boolean>(Dispatch(
    '{"jsonrpc":"2.0","id":"' + CANCELLED_REQUEST_ID + '",' +
    '"method":"tools/call","params":{"name":"self-cancel",' +
    '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{},' +
    '"io.modelcontextprotocol/logLevel":"debug",' +
    '"progressToken":"cancel-progress"}}}', ResponseLine)).ToBe(False);
  Expect<string>(ResponseLine).ToBe('');
  Expect<Integer>(FLines.Count).ToBe(0);
end;

procedure TCancellationDispatch.TestFloatRequestCancelledByInteger;
begin
  ExpectCancellationSuppressed('1.0', '1');
end;

procedure TCancellationDispatch.TestIntegerRequestCancelledByFloat;
begin
  ExpectCancellationSuppressed('1', '1.0');
end;

procedure TCancellationDispatch.TestLargeIntegerMatchingPreservesPrecision;
var
  ResponseLine: string;
begin
  CancellationTargetJson := '9007199254740992';
  Expect<Boolean>(Dispatch(
    '{"jsonrpc":"2.0","id":9007199254740993,' +
    '"method":"tools/call","params":{"name":"self-cancel",' +
    META_MODERN + '}}', ResponseLine)).ToBe(True);
  Expect<Boolean>(ResponseLine <> '').ToBe(True);
  Expect<Boolean>(CancellationObserved).ToBe(False);

  ExpectCancellationSuppressed('9007199254740993',
    '9007199254740993');
end;

procedure TCancellationDispatch.TestMalformedReasonIgnored;
var
  ResponseLine: string;
begin
  CancellationNotificationLine :=
    '{"jsonrpc":"2.0","method":"notifications/cancelled",' +
    '"params":{"requestId":77,"reason":false}}';
  Expect<Boolean>(Dispatch(
    '{"jsonrpc":"2.0","id":77,"method":"tools/call",' +
    '"params":{"name":"notification-cancel",' + META_MODERN + '}}',
    ResponseLine)).ToBe(True);
  Expect<Boolean>(ResponseLine <> '').ToBe(True);
  Expect<Boolean>(CancellationObserved).ToBe(False);
end;

procedure TCancellationDispatch.TestStringReasonAccepted;
var
  ResponseLine: string;
begin
  CancellationNotificationLine :=
    '{"jsonrpc":"2.0","method":"notifications/cancelled",' +
    '"params":{"requestId":78,"reason":"stop\r\nnow"}}';
  Expect<Boolean>(Dispatch(
    '{"jsonrpc":"2.0","id":78,"method":"tools/call",' +
    '"params":{"name":"notification-cancel",' + META_MODERN + '}}',
    ResponseLine)).ToBe(False);
  Expect<string>(ResponseLine).ToBe('');
  Expect<Boolean>(CancellationObserved).ToBe(True);
end;

procedure TCancellationDispatch.TestModernUnknownAndMalformedIgnored;
var
  Response: TJSONObject;
begin
  SendNotification(
    '{"jsonrpc":"2.0","method":"notifications/cancelled",' +
    '"params":{"requestId":"future"}}');
  SendNotification(
    '{"jsonrpc":"2.0","method":"notifications/cancelled",' +
    '"params":{}}');
  SendNotification(
    '{"jsonrpc":"2.0","method":"notifications/cancelled",' +
    '"params":{"requestId":false}}');
  SendNotification(
    '{"jsonrpc":"2.0","method":"notifications/cancelled",' +
    '"params":{"requestId":{}}}');

  // An unknown cancellation must not poison a later request reusing
  // that id; this is the modern per-request-metadata path.
  Response := Call('{"jsonrpc":"2.0","id":"future",' +
    '"method":"tools/call","params":{"name":"cancellation-aware",' +
    META_MODERN + '}}');
  Expect<Boolean>(CancellationObserved).ToBe(False);
  Expect<Boolean>(Response.Find('result') <> nil).ToBe(True);
  Response.Free;
end;

procedure TCancellationDispatch.TestLegacyFinishedAndRepeatedIgnored;
var
  Response: TJSONObject;
begin
  InitializeLegacy;
  Response := Call('{"jsonrpc":"2.0","id":7,"method":"tools/call",' +
    '"params":{"name":"cancellation-aware"}}');
  Response.Free;

  SendNotification(
    '{"jsonrpc":"2.0","method":"notifications/cancelled",' +
    '"params":{"requestId":7,"reason":"already finished"}}');
  SendNotification(
    '{"jsonrpc":"2.0","method":"notifications/cancelled",' +
    '"params":{"requestId":7}}');
  Response := Call('{"jsonrpc":"2.0","id":8,"method":"tools/call",' +
    '"params":{"name":"cancellation-aware"}}');
  Expect<Boolean>(CancellationObserved).ToBe(False);
  Expect<Boolean>(Response.Find('result') <> nil).ToBe(True);
  Response.Free;
end;

procedure TCancellationDispatch.SetupTests;
begin
  Test('normal handler probe is present and false',
    TestNormalRequestProbeFalse);
  Test('mid-handler cancellation suppresses non-ASCII-id response',
    TestCancelledResponseSuppressed);
  Test('accepted cancellation suppresses progress and log notifications',
    TestCancelledNotificationsSuppressed);
  Test('numeric id 1.0 is cancelled by id 1',
    TestFloatRequestCancelledByInteger);
  Test('numeric id 1 is cancelled by id 1.0',
    TestIntegerRequestCancelledByFloat);
  Test('large integer ids retain Int64 matching precision',
    TestLargeIntegerMatchingPreservesPrecision);
  Test('non-string cancellation reason ignores the whole notification',
    TestMalformedReasonIgnored);
  Test('string cancellation reason is accepted',
    TestStringReasonAccepted);
  Test('modern unknown and malformed cancellations are ignored',
    TestModernUnknownAndMalformedIgnored);
  Test('legacy finished and repeated cancellations are ignored',
    TestLegacyFinishedAndRepeatedIgnored);
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
  Expect<string>(TJSONData(Response.FindPath('error.message')).AsString)
    .ToBe('Prompt handler failed: prompt boom');
  Response.Free;
end;

procedure TPromptDispatch.TestGetHandlerRaisesRedacted;
var
  ClientMessage: string;
  Response: TJSONObject;
begin
  FServer.RedactErrorDetails := True;
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"prompts/get",' +
    '"params":{"name":"promptboom",' + META_MODERN + '}}');
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(JSONRPC_INTERNAL_ERROR);
  ClientMessage := TJSONData(Response.FindPath('error.message')).AsString;
  ExpectRedactedExceptionMessage(ClientMessage, 'Prompt handler failed',
    'prompt boom');
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
  SendNotification(
    '{"jsonrpc":"2.0","method":"notifications/initialized"}');
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
  Test('prompts/get: handler exception redacted',
    TestGetHandlerRaisesRedacted);
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
  SendNotification(
    '{"jsonrpc":"2.0","method":"notifications/initialized"}');
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

procedure TLegacyEra.TestRequestAwaitingInitialized;
var
  ExpectedLine, ResponseLine: string;
  PingResponse: TJSONObject;
begin
  PingResponse := Call(
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{' +
    '"protocolVersion":"2025-11-25","capabilities":{},' +
    '"clientInfo":{"name":"legacy-client","version":"1.2.3"}}}');
  PingResponse.Free;

  PingResponse := Call('{"jsonrpc":"2.0","id":2,"method":"ping"}');
  Expect<Boolean>(PingResponse.Find('result') <> nil).ToBe(True);
  PingResponse.Free;

  Expect<Boolean>(Dispatch(
    '{"jsonrpc":"2.0","id":"réq-1","method":"tools/list",' +
    '"params":{}}', ResponseLine)).ToBe(True);
  ExpectedLine := '{ "jsonrpc" : "2.0", "id" : "réq-1", "error" : { ' +
    '"code" : -32600, "message" : "Received request before ' +
    'initialization is complete: send notifications/initialized first" } }';
  Expect<string>(ResponseLine).ToBe(ExpectedLine);
end;

procedure TLegacyEra.TestInitializedMakesReady;
var
  Response: TJSONObject;
begin
  Response := Call(
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{' +
    '"protocolVersion":"2025-11-25","capabilities":{},' +
    '"clientInfo":{"name":"legacy-client","version":"1.2.3"}}}');
  Response.Free;
  SendNotification(
    '{"jsonrpc":"2.0","method":"notifications/initialized"}');
  Response := Call('{"jsonrpc":"2.0","id":2,"method":"tools/list",' +
    '"params":{}}');
  Expect<Boolean>(Response.FindPath('result.tools') <> nil).ToBe(True);
  Response.Free;
end;

procedure TLegacyEra.TestDoubleInitializeRejected;
var
  Response: TJSONObject;
begin
  Response := Call(
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{' +
    '"protocolVersion":"2025-06-18","capabilities":{"roots":{}},' +
    '"clientInfo":{"name":"original-client","version":"1.0.0"}}}');
  Response.Free;
  SendNotification(
    '{"jsonrpc":"2.0","method":"notifications/initialized"}');

  Response := Call(
    '{"jsonrpc":"2.0","id":2,"method":"initialize","params":{' +
    '"protocolVersion":"2025-11-25","capabilities":{"sampling":{}},' +
    '"clientInfo":{"name":"replacement-client","version":"2.0.0"}}}');
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(JSONRPC_INVALID_REQUEST);
  Expect<string>(TJSONData(Response.FindPath('error.message')).AsString)
    .ToBe('Server is already initialized: initialize may only be sent once');
  Response.Free;

  Response := Call('{"jsonrpc":"2.0","id":3,"method":"tools/call",' +
    '"params":{"name":"whoami"}}');
  Expect<string>(TJSONData(Response.FindPath('result.content[0].text'))
    .AsString).ToBe('2025-06-18|original-client|1.0.0|roots');
  Response.Free;
end;

procedure TLegacyEra.TestInitializedBeforeInitializeIgnored;
var
  Response: TJSONObject;
begin
  SendNotification(
    '{"jsonrpc":"2.0","method":"notifications/initialized"}');
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"ping"}');
  Expect<Boolean>(Response.Find('result') <> nil).ToBe(True);
  Response.Free;

  Response := Call('{"jsonrpc":"2.0","id":2,"method":"tools/list",' +
    '"params":{}}');
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(JSONRPC_INVALID_REQUEST);
  Expect<string>(TJSONData(Response.FindPath('error.message')).AsString)
    .ToBe('Received request before initialization: send initialize first ' +
      '(legacy clients), or carry the required per-request _meta ' +
      '(protocol 2026-07-28)');
  Response.Free;
end;

procedure TLegacyEra.TestFailedInitializeDoesNotAdvance;
var
  Response: TJSONObject;
begin
  ExpectInvalidParams(
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{' +
    '"protocolVersion":"2025-11-25",' +
    '"clientInfo":{"name":"legacy-client","version":"1.2.3"}}}');
  Response := Call(
    '{"jsonrpc":"2.0","id":2,"method":"initialize","params":{' +
    '"protocolVersion":"2025-11-25","capabilities":{},' +
    '"clientInfo":{"name":"legacy-client","version":"1.2.3"}}}');
  Expect<string>(TJSONObject(Response.Find('result'))
    .Get('protocolVersion', '')).ToBe('2025-11-25');
  Response.Free;
  SendNotification(
    '{"jsonrpc":"2.0","method":"notifications/initialized"}');
  Response := Call('{"jsonrpc":"2.0","id":3,"method":"tools/list",' +
    '"params":{}}');
  Expect<Boolean>(Response.FindPath('result.tools') <> nil).ToBe(True);
  Response.Free;
end;

procedure TLegacyEra.TestInitializeCancellationIgnored;
var
  RequestId: TJSONData;
  Response: TJSONObject;
begin
  RequestId := GetJSON('55');
  try
    // The session cancellation entry point cannot arm a future initialize.
    FSession := FServer.CreateSession;
    FSession.CancelRequest(RequestId);
    Response := Call(
      '{"jsonrpc":"2.0","id":55,"method":"initialize",' +
      '"params":{"protocolVersion":"2025-11-25",' +
      '"capabilities":{},"clientInfo":{' +
      '"name":"legacy-client","version":"1.2.3"}}}');
    Expect<Boolean>(Response.Find('result') <> nil).ToBe(True);
    Response.Free;
    FSession.CancelRequest(RequestId);
    SendNotification(
      '{"jsonrpc":"2.0","method":"notifications/initialized"}');
    Response := Call(
      '{"jsonrpc":"2.0","id":56,"method":"tools/list",' +
      '"params":{}}');
    Expect<Boolean>(Response.FindPath('result.tools') <> nil).ToBe(True);
    Response.Free;
  finally
    RequestId.Free;
  end;
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
    .ToBe('2025-06-18|legacy-client|1.2.3|roots');
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
  Test('request before initialized notification → -32600',
    TestRequestAwaitingInitialized);
  Test('initialized notification transitions legacy session to ready',
    TestInitializedMakesReady);
  Test('second initialize rejected without renegotiation',
    TestDoubleInitializeRejected);
  Test('initialized notification before initialize is ignored',
    TestInitializedBeforeInitializeIgnored);
  Test('failed initialize leaves legacy session new',
    TestFailedInitializeDoesNotAdvance);
  Test('initialize ignores cancellation and lifecycle reaches ready',
    TestInitializeCancellationIgnored);
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

{ ───────── shared-core session isolation ───────── }

procedure TSessionIsolation.BeforeEach;
begin
  FServer := TMCPServer.Create('shared-server', '1.2.0');
  FServer.RegisterTool('whoami', 'Mirror the request context',
    '{"type":"object"}', WhoAmIHandler);
  FServer.RegisterTool('noisy', 'Emits notifications',
    '{"type":"object"}', NoisyHandler);
  FSessionA := FServer.CreateSession;
  FSessionB := FServer.CreateSession;
  FLinesA := TStringList.Create;
  FLinesB := TStringList.Create;
end;

procedure TSessionIsolation.AfterEach;
begin
  FreeAndNil(FLinesB);
  FreeAndNil(FLinesA);
  FreeAndNil(FSessionB);
  FreeAndNil(FSessionA);
  FreeAndNil(FServer);
end;

function TSessionIsolation.Call(ASession: TMCPSession;
  const ALine: string; ASink: TMCPLineSink;
  ASinkData: Pointer): TJSONObject;
var
  Response: string;
begin
  if not FServer.HandleMessage(ASession, ALine, ASink, ASinkData,
    Response) then
    Fail('expected a response, got none');
  // The returned object is owned by the caller.
  Result := TJSONObject(GetJSON(Response));
end;

procedure TSessionIsolation.SendNotification(ASession: TMCPSession;
  const ALine: string);
var
  Response: string;
begin
  Expect<Boolean>(FServer.HandleMessage(ASession, ALine, Response))
    .ToBe(False);
  Expect<string>(Response).ToBe('');
end;

procedure TSessionIsolation.TestIndependentLegacyNegotiation;
var
  Response: TJSONObject;
begin
  Response := Call(FSessionA,
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{' +
    '"protocolVersion":"2025-06-18","capabilities":{"roots":{}},' +
    '"clientInfo":{"name":"client-a","version":"1.0.0"}}}');
  Response.Free;
  Response := Call(FSessionB,
    '{"jsonrpc":"2.0","id":2,"method":"initialize","params":{' +
    '"protocolVersion":"2025-11-25","capabilities":{"sampling":{}},' +
    '"clientInfo":{"name":"client-b","version":"2.0.0"}}}');
  Response.Free;
  SendNotification(FSessionA,
    '{"jsonrpc":"2.0","method":"notifications/initialized"}');
  SendNotification(FSessionB,
    '{"jsonrpc":"2.0","method":"notifications/initialized"}');

  Response := Call(FSessionA,
    '{"jsonrpc":"2.0","id":3,"method":"tools/call",' +
    '"params":{"name":"whoami"}}');
  Expect<string>(TJSONData(Response.FindPath('result.content[0].text'))
    .AsString).ToBe('2025-06-18|client-a|1.0.0|roots');
  Response.Free;
  Response := Call(FSessionB,
    '{"jsonrpc":"2.0","id":4,"method":"tools/call",' +
    '"params":{"name":"whoami"}}');
  Expect<string>(TJSONData(Response.FindPath('result.content[0].text'))
    .AsString).ToBe('2025-11-25|client-b|2.0.0|no-roots');
  Response.Free;

  Response := Call(FSessionA,
    '{"jsonrpc":"2.0","id":5,"method":"initialize","params":{' +
    '"protocolVersion":"2025-11-25","capabilities":{},' +
    '"clientInfo":{"name":"replacement","version":"9.0.0"}}}');
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(JSONRPC_INVALID_REQUEST);
  Response.Free;

  Response := Call(FSessionA,
    '{"jsonrpc":"2.0","id":6,"method":"tools/call",' +
    '"params":{"name":"whoami"}}');
  Expect<string>(TJSONData(Response.FindPath('result.content[0].text'))
    .AsString).ToBe('2025-06-18|client-a|1.0.0|roots');
  Response.Free;
  Response := Call(FSessionB,
    '{"jsonrpc":"2.0","id":7,"method":"tools/call",' +
    '"params":{"name":"whoami"}}');
  Expect<string>(TJSONData(Response.FindPath('result.content[0].text'))
    .AsString).ToBe('2025-11-25|client-b|2.0.0|no-roots');
  Response.Free;
end;

procedure TSessionIsolation.TestIndependentNotificationSinks;
var
  Note, Response: TJSONObject;
begin
  Response := Call(FSessionA,
    '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{' +
    '"name":"noisy","_meta":{' +
    '"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{},' +
    '"progressToken":"a-1"}}}', CaptureSink, FLinesA);
  Response.Free;
  Response := Call(FSessionB,
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{' +
    '"name":"noisy","_meta":{' +
    '"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{},' +
    '"progressToken":"b-1"}}}', CaptureSink, FLinesB);
  Response.Free;
  Response := Call(FSessionA,
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{' +
    '"name":"noisy","_meta":{' +
    '"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{},' +
    '"progressToken":"a-2"}}}', CaptureSink, FLinesA);
  Response.Free;
  Response := Call(FSessionB,
    '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{' +
    '"name":"noisy","_meta":{' +
    '"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{},' +
    '"progressToken":"b-2"}}}', CaptureSink, FLinesB);
  Response.Free;

  Expect<Integer>(FLinesA.Count).ToBe(2);
  Expect<Integer>(FLinesB.Count).ToBe(2);
  Note := TJSONObject(GetJSON(FLinesA[0]));
  Expect<string>(TJSONData(Note.FindPath('params.progressToken')).AsString)
    .ToBe('a-1');
  Note.Free;
  Note := TJSONObject(GetJSON(FLinesA[1]));
  Expect<string>(TJSONData(Note.FindPath('params.progressToken')).AsString)
    .ToBe('a-2');
  Note.Free;
  Note := TJSONObject(GetJSON(FLinesB[0]));
  Expect<string>(TJSONData(Note.FindPath('params.progressToken')).AsString)
    .ToBe('b-1');
  Note.Free;
  Note := TJSONObject(GetJSON(FLinesB[1]));
  Expect<string>(TJSONData(Note.FindPath('params.progressToken')).AsString)
    .ToBe('b-2');
  Note.Free;
end;

procedure TSessionIsolation.TestLifecycleIsolation;
var
  Response: TJSONObject;
begin
  Response := Call(FSessionA,
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{' +
    '"protocolVersion":"2025-11-25","capabilities":{},' +
    '"clientInfo":{"name":"client-a","version":"1.0.0"}}}');
  Response.Free;
  SendNotification(FSessionA,
    '{"jsonrpc":"2.0","method":"notifications/initialized"}');

  Response := Call(FSessionA,
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}');
  Expect<Boolean>(Response.FindPath('result.tools') <> nil).ToBe(True);
  Response.Free;
  Response := Call(FSessionB,
    '{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}');
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(JSONRPC_INVALID_REQUEST);
  Expect<string>(TJSONData(Response.FindPath('error.message')).AsString)
    .ToBe('Received request before initialization: send initialize first ' +
      '(legacy clients), or carry the required per-request _meta ' +
      '(protocol 2026-07-28)');
  Response.Free;
end;

procedure TSessionIsolation.TestForeignSessionRejected;
var
  ErrorMessage, Response: string;
  ForeignServer: TMCPServer;
  ForeignSession: TMCPSession;
begin
  ForeignServer := TMCPServer.Create('foreign', '1');
  try
    ForeignSession := ForeignServer.CreateSession;
    try
      ErrorMessage := '';
      try
        FServer.HandleMessage(ForeignSession,
          '{"jsonrpc":"2.0","id":1,"method":"tools/list",' +
          '"params":{' + META_MODERN + '}}', Response);
      except
        on E: EMCPServer do
          ErrorMessage := E.Message;
      end;
      Expect<string>(ErrorMessage).ToBe('Session belongs to another server');
    finally
      ForeignSession.Free;
    end;
  finally
    ForeignServer.Free;
  end;
end;

procedure TSessionIsolation.TestNilSessionRejected;
var
  ErrorMessage, Response: string;
begin
  ErrorMessage := '';
  try
    FServer.HandleMessage(nil,
      '{"jsonrpc":"2.0","id":1,"method":"tools/list",' +
      '"params":{' + META_MODERN + '}}', Response);
  except
    on E: EMCPServer do
      ErrorMessage := E.Message;
  end;
  Expect<string>(ErrorMessage).ToBe('Session must not be nil');
end;

procedure TSessionIsolation.SetupTests;
begin
  Test('legacy negotiation and re-initialize are session-local',
    TestIndependentLegacyNegotiation);
  Test('alternating requests retain their own notification sinks',
    TestIndependentNotificationSinks);
  Test('legacy lifecycle transitions are session-local',
    TestLifecycleIsolation);
  Test('session from another server raises EMCPServer',
    TestForeignSessionRejected);
  Test('nil session raises EMCPServer', TestNilSessionRejected);
end;

{ ───────── byte-exact wire compatibility ───────── }

procedure TWireEncoding.TestModernToolsListLine;
var
  Response: string;
  Server: TMCPServer;
  Session: TMCPSession;
begin
  Server := TMCPServer.Create('wire-server', '1.0');
  try
    Session := Server.CreateSession;
    try
      Expect<Boolean>(Server.HandleMessage(Session,
        '{"jsonrpc":"2.0","id":1,"method":"tools/list",' +
        '"params":{' + META_MODERN + '}}', Response)).ToBe(True);
      Expect<string>(Response).ToBe(
        '{ "jsonrpc" : "2.0", "id" : 1, "result" : { "tools" : [], ' +
        '"ttlMs" : 300000, "cacheScope" : "private", ' +
        '"resultType" : "complete", "_meta" : { ' +
        '"io.modelcontextprotocol/serverInfo" : { ' +
        '"name" : "wire-server", "version" : "1.0" } } } }');
    finally
      Session.Free;
    end;
  finally
    Server.Free;
  end;
end;

procedure TWireEncoding.TestLegacyInitializeLine;
var
  Response: string;
  Server: TMCPServer;
  Session: TMCPSession;
begin
  Server := TMCPServer.Create('wire-server', '1.0');
  try
    Session := Server.CreateSession;
    try
      Expect<Boolean>(Server.HandleMessage(Session,
        '{"jsonrpc":"2.0","id":2,"method":"initialize",' +
        '"params":{"protocolVersion":"2025-11-25",' +
        '"capabilities":{},"clientInfo":{' +
        '"name":"wire-client","version":"1.0"}}}', Response)).ToBe(True);
      Expect<string>(Response).ToBe(
        '{ "jsonrpc" : "2.0", "id" : 2, "result" : { ' +
        '"protocolVersion" : "2025-11-25", "capabilities" : { ' +
        '"tools" : {}, "resources" : {}, "prompts" : {} }, ' +
        '"serverInfo" : { "name" : "wire-server", ' +
        '"version" : "1.0" } } }');
    finally
      Session.Free;
    end;
  finally
    Server.Free;
  end;
end;

procedure TWireEncoding.TestProgressNotificationLine;
var
  Lines: TStringList;
  Response: string;
  Server: TMCPServer;
  Session: TMCPSession;
begin
  Server := TMCPServer.Create('wire-server', '1.0');
  try
    Server.RegisterTool('noisy', 'Emits notifications',
      '{"type":"object"}', NoisyHandler);
    Session := Server.CreateSession;
    try
      Lines := TStringList.Create;
      try
        Expect<Boolean>(Server.HandleMessage(Session,
          '{"jsonrpc":"2.0","id":3,"method":"tools/call",' +
          '"params":{"name":"noisy","_meta":{' +
          '"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
          '"io.modelcontextprotocol/clientCapabilities":{},' +
          '"progressToken":"wire-token"}}}', CaptureSink, Lines,
          Response)).ToBe(True);
        Expect<Integer>(Lines.Count).ToBe(1);
        Expect<string>(Lines[0]).ToBe(
          '{ "jsonrpc" : "2.0", "method" : "notifications/progress", ' +
          '"params" : { "progressToken" : "wire-token", ' +
          '"progress" : 2.5000000000000000E-001, ' +
          '"total" : 1.0000000000000000E+000, ' +
          '"message" : "working" } }');
      finally
        Lines.Free;
      end;
    finally
      Session.Free;
    end;
  finally
    Server.Free;
  end;
end;

procedure TWireEncoding.SetupTests;
begin
  Test('modern tools/list response line is byte-exact',
    TestModernToolsListLine);
  Test('legacy initialize response line is byte-exact',
    TestLegacyInitializeLine);
  Test('progress notification line is byte-exact',
    TestProgressNotificationLine);
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
    TCancellationDispatch.Create('Server: cooperative cancellation'));
  TestRunnerProgram.AddSuite(
    TRegistrationGuards.Create('Server: registration guards'));
  TestRunnerProgram.AddSuite(TLegacyEra.Create('Server: legacy era'));
  TestRunnerProgram.AddSuite(
    TSessionIsolation.Create('Server: shared-core session isolation'));
  TestRunnerProgram.AddSuite(
    TWireEncoding.Create('Server: byte-exact wire compatibility'));
  TestRunnerProgram.Run;
end.
