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

{$I MCP.inc}

uses
  Classes,
  Math,
  SysUtils,

  fpjson,
  jsonparser,
  MCP.Content,
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
    procedure TestInvalidNotificationDropped;
    procedure TestInvalidRequestAnswered;
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
  private
    // Shared raise-expectation shapes. FPC 3.2.2 has no anonymous
    // procedures, so each shape gets its own helper rather than one
    // generic ExpectRaises; only sites with identical assertions
    // share one.
    //
    // ADefinition is handed to RegisterTool, which owns it either way
    // (a rejected definition is freed by the registration guard).
    // ToolCount is asserted here because every definition-rejection
    // site checks it.
    procedure ExpectToolDefinitionRejected(AServer: TMCPServer;
      ADefinition: TJSONObject);
    // The string-schema overload. Callers assert ToolCount themselves
    // — the expected count differs per site.
    procedure ExpectToolSchemaRejected(AServer: TMCPServer;
      const AName, ADescription, AInputSchemaJson: string);
    procedure ExpectServerCreateRejected(const AName, AVersion: string);
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
    procedure TestBadHeaderAnnotationRejected;
    procedure TestHeaderAnnotatedToolValidated;
    procedure TestHeaderParametersAreCopies;
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
    procedure TestPromptArgumentsCopyConsumed;
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
    procedure TestNonFiniteTotalRejected;
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
    procedure TestTransportPollCancels;
    procedure TestActiveRequestIdMatches;
    procedure TestOptedOutNotificationsDoNotPoll;
    procedure TestTransportPollOnlyDuringRequests;
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

  // #4: MRTR (input_required) — result-driven re-entry for tools and
  // prompts: interim result shape, retry with inputResponses +
  // requestState, capability gating (-32021), era gating, and the
  // at-least-one-of guard.
  TMRTRDispatch = class(TDispatchSuite)
  protected
    procedure BeforeEach; override;
    function SealedState(const AFirstRound: string): string;
  public
    procedure SetupTests; override;
    procedure TestFirstRoundInputRequired;
    procedure TestRetryCompletes;
    procedure TestStateOnlyRound;
    procedure TestMissingCapabilityRejected;
    procedure TestUnknownKindRejected;
    procedure TestMissingMethodEntryRejected;
    procedure TestNonObjectEntryRejected;
    procedure TestPromptMissingCapabilityRejected;
    procedure TestPromptUnknownKindRejected;
    procedure TestPromptMalformedEntryRejected;
    procedure TestEmptyInputRequiredGuard;
    procedure TestLegacyToolGetsInBandError;
    procedure TestPromptRoundTrip;
    procedure TestSamplingAndRootsBuilders;
  end;

  // requestState sealing (#89): what reaches the client is a token,
  // the handler sees only its own state, and every token that is
  // altered, expired, or presented for another tool, other arguments
  // or another server is answered -32602 before the handler runs.
  TRequestStateSealing = class(TDispatchSuite)
  protected
    procedure BeforeEach; override;
  public
    procedure SetupTests; override;
    procedure TestRoundTripNonASCIIState;
    procedure TestTamperedTokenRejected;
    procedure TestPlainStateRejected;
    procedure TestOtherToolRejected;
    procedure TestOtherArgumentsRejected;
    procedure TestExpiredRejected;
    procedure TestSharedKeyAcrossInstances;
    procedure TestOtherAudienceRejected;
    procedure TestKeyRotation;
    procedure TestResourceReadDropsState;
    procedure TestConfigurationGuards;
    procedure TestSeededDefaultKeepsTokenValid;
    procedure TestDefaultKeysPerInstance;
    procedure TestFirstKeySeals;
    procedure TestNumberSpellingKeepsTokenValid;
    procedure TestPromptStateRestored;
    procedure TestExplicitEmptyStateRejected;
  protected
    function Token(const ATool, AArguments: string): string;
    procedure ExpectRefused(const ALine: string);
  end;

  // #23: call-time validation of raw-handler tool arguments against
  // the registered schema's enforceable subset, plus the freeze-time
  // subset gate and its ApplicationValidated escape hatch.
  TSubsetValidation = class(TDispatchSuite)
  protected
    procedure BeforeEach; override;
  public
    procedure SetupTests; override;
    procedure TestMissingRequiredRejected;
    procedure TestMistypedStringRejected;
    procedure TestEnumViolationRejected;
    procedure TestEnumAcceptedAndDefaultSeeded;
    procedure TestFloatForIntegerRejected;
    procedure TestUnknownArgumentIgnored;
    procedure TestOutOfSubsetSchemaFailsFreeze;
    procedure TestApplicationValidatedSkipsChecks;
  end;

  // MCPAudioResult, MCPContentResult and MCPContentMessage: the
  // non-text blocks of MCP.Content reach tools/call and prompts/get
  // results unchanged, in order, on the exact wire line.
  TContentResults = class(TDispatchSuite)
  protected
    procedure BeforeEach; override;
  public
    procedure SetupTests; override;
    procedure TestAudioResultLine;
    procedure TestMixedContentInOrder;
    procedure TestPromptContentMessages;
    procedure TestNilBlockRejected;
    procedure TestRepeatedBlockRejected;
  end;

  // EMCPProtocolError (#88): a handler's deliberate JSON-RPC error
  // reaches the wire with its own code, message and data from every
  // handler kind and both eras, unredacted; reserved codes are refused
  // at construction.
  THandlerProtocolErrors = class(TDispatchSuite)
  protected
    procedure BeforeEach; override;
  public
    procedure SetupTests; override;
    procedure TestToolErrorLineByteExact;
    procedure TestRedactionLeavesItAlone;
    procedure TestTypedToolError;
    procedure TestPromptError;
    procedure TestResourceError;
    procedure TestTemplateError;
    procedure TestLegacyEraToolError;
    procedure TestMissingCapabilityHelper;
    procedure TestReservedCodesRefused;
    procedure TestAllowedCodesAccepted;
    procedure TestCapabilityDataShape;
    procedure TestChangedDataSentAsInternalError;
  end;

  // #91: any outputSchema root, structured output checked against a
  // subset output schema before it is sent, and the classic dialect's
  // object-only structuredContent.
  TStructuredOutput = class(TDispatchSuite)
  protected
    procedure BeforeEach; override;
  public
    procedure SetupTests; override;
    procedure TestArrayOutputSent;
    procedure TestScalarOutputSent;
    procedure TestMismatchBecomesIsError;
    procedure TestMissingStructuredContent;
    procedure TestHandlerIsErrorNotChecked;
    procedure TestOutOfSubsetOutputNotChecked;
    procedure TestLegacyDialect;
    procedure TestLegacyKeepsCustomText;
    procedure TestErrorWithBadStructuredDropsIt;
    procedure TestErrorWithGoodStructuredKeepsIt;
    procedure TestRicherSchemaPublishedUnchanged;
    procedure TestNonFiniteOutputRefused;
    procedure TestNonFiniteClassicIsAnError;
    procedure TestNilSchemaChildListedInBothEras;
  end;

  // completion/complete (#81): static and callable completions for
  // prompt arguments and template variables, the 100-value cap,
  // context arguments, error cases, and capabilities computed from
  // the registrations.
  TCompletionDispatch = class(TDispatchSuite)
  protected
    procedure BeforeEach; override;
  public
    procedure SetupTests; override;
    procedure TestStaticPromptCompletion;
    procedure TestCallableTemplateCompletion;
    procedure TestHundredValueCap;
    procedure TestUnregisteredArgumentIsEmpty;
    procedure TestErrors;
    procedure TestRegistrationGuards;
    procedure TestCapabilities;
    procedure TestLegacyEra;
    procedure TestFoldPairs;
  end;

  TTypedNested = class(TDispatchSuite)
  protected
    procedure BeforeEach; override;
  public
    procedure SetupTests; override;
    procedure TestNestedArgumentsReachHandler;
    procedure TestNestedErrorIsInBand;
  end;

  // .RequiresClientCapability (#84): a declared need is checked before
  // the handler runs. A request lacking a required client capability
  // is answered -32021 with data.requiredCapabilities (spec verified
  // 2026-11-27:
  // https://modelcontextprotocol.io/specification/2026-07-28/basic/index#_meta).
  TDeclaredCapabilities = class(TDispatchSuite)
  protected
    procedure BeforeEach; override;
  public
    procedure SetupTests; override;
    procedure TestMissingRefusedBeforeHandler;
    procedure TestEveryMissingCapabilityNamed;
    procedure TestMalformedDeclarationIsMissing;
    procedure TestNonASCIIToolName;
    procedure TestCustomCapabilityByPresence;
    procedure TestClassicLookupByPresence;
    procedure TestPresentRuns;
    procedure TestLegacyEraNotChecked;
    procedure TestGuards;
  end;

  // PageSize and cursors on the four list methods (#94).
  TPagination = class(TDispatchSuite)
  protected
    procedure BeforeEach; override;
  public
    procedure SetupTests; override;
    procedure TestPagesConcatenateInOrder;
    procedure TestInvalidCursors;
    procedure TestNoPagingByDefault;
    procedure TestOtherListsPage;
    procedure TestLegacyDialectPages;
  end;

  // MCPImageResult: the spec's image content block, the raw-bytes
  // overload's base64 encoding (asserted against literal fixtures, not
  // against a decode of what we just encoded), mimeType passthrough,
  // and the empty-payload edge.
  TImageResults = class(TDispatchSuite)
  protected
    procedure BeforeEach; override;
  public
    procedure SetupTests; override;
    procedure TestSpecContentBlock;
    procedure TestBytesEncodedToBase64;
    procedure TestNonAsciiBytesSurviveEncoding;
    procedure TestPreEncodedDataPassesThrough;
    procedure TestEmptyDataYieldsEmptyString;
    procedure TestMimeTypePassthrough;
    procedure TestResponseLineByteExact;
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
  // #95: a typed tool with a nested object and an array.
  TBatchItem = class(TMCPArgs)
  private
    FLabel: string;
    FWeights: TStringArray;
  published
    property label_: string read FLabel write FLabel;
    property weights: TStringArray read FWeights write FWeights;
  end;

  TBatchArgs = class(TMCPArgs)
  private
    FItem: TBatchItem;
  published
    property item: TBatchItem read FItem write FItem;
  end;

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

// Reports progress with the non-finite total its `total` argument
// names ('nan', 'inf' or '-inf').
function NonFiniteTotalHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Name: string;
  Total: Double;
begin
  Name := AArguments.Strings['total'];
  if Name = 'nan' then
    Total := NaN
  else if Name = 'inf' then
    Total := Infinity
  else
    Total := NegInfinity;
  MCPReportProgress(ACtx, 0.5, Total);
  Result := MCPTextResult('reported');
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

procedure TDiscoverAndErrors.TestInvalidNotificationDropped;
var
  Response: string;
begin
  // Invalid but notification-shaped (method, no id): dropped, not
  // answered — MCP's fire-and-forget rule for malformed notifications.
  Expect<Boolean>(Dispatch(
    '{"jsonrpc":"2.0","method":"notifications/cancelled",' +
    '"params":[1,2]}', Response)).ToBe(False);
  Expect<string>(Response).ToBe('');
end;

procedure TDiscoverAndErrors.TestInvalidRequestAnswered;
var
  Response: TJSONObject;
begin
  // The same malformation carrying an id keeps the -32600 reply with
  // the id echoed back.
  Response := Call('{"jsonrpc":"2.0","id":6,"method":"tools/call",' +
    '"params":[1,2]}');
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(JSONRPC_INVALID_REQUEST);
  Expect<Integer>(Response.Get('id', 0)).ToBe(6);
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
  Test('invalid notification-shaped message dropped',
    TestInvalidNotificationDropped);
  Test('invalid id-carrying request answered with -32600',
    TestInvalidRequestAnswered);
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

procedure TRegistrationGuards.ExpectToolDefinitionRejected(
  AServer: TMCPServer; ADefinition: TJSONObject);
var
  Raised: Boolean;
begin
  Raised := False;
  try
    AServer.RegisterTool(ADefinition, EchoHandler);
  except
    on EMCPServer do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  Expect<Integer>(AServer.ToolCount).ToBe(0);
end;

procedure TRegistrationGuards.ExpectToolSchemaRejected(AServer: TMCPServer;
  const AName, ADescription, AInputSchemaJson: string);
var
  Raised: Boolean;
begin
  Raised := False;
  try
    AServer.RegisterTool(AName, ADescription, AInputSchemaJson, EchoHandler);
  except
    on EMCPServer do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TRegistrationGuards.ExpectServerCreateRejected(
  const AName, AVersion: string);
var
  Raised: Boolean;
  Server: TMCPServer;
begin
  Server := nil;
  Raised := False;
  try
    Server := TMCPServer.Create(AName, AVersion);
  except
    on EMCPServer do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  Server.Free;
end;

procedure TRegistrationGuards.TestDuplicateTool;
var
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Server.RegisterTool('a', 'first', '{"type":"object"}', EchoHandler);
    ExpectToolSchemaRejected(Server, 'a', 'second', '{"type":"object"}');
    Expect<Integer>(Server.ToolCount).ToBe(1);
  finally
    Server.Free;
  end;
end;

procedure TRegistrationGuards.TestBadSchema;
var
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    ExpectToolSchemaRejected(Server, 'a', 'desc', '{not json');
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
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Definition := TJSONObject.Create;
    Definition.Add('name', 'raw');
    Definition.Add('inputSchema', 'not-an-object');
    ExpectToolDefinitionRejected(Server, Definition);
  finally
    Server.Free;
  end;
end;

procedure TRegistrationGuards.TestMissingInputSchemaRoot;
var
  Definition: TJSONObject;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    ExpectToolSchemaRejected(Server, 'empty-root', 'desc', '{}');

    Definition := TJSONObject.Create;
    Definition.Add('name', 'empty-definition-root');
    Definition.Add('inputSchema', GetJSON('{}'));
    ExpectToolDefinitionRejected(Server, Definition);
  finally
    Server.Free;
  end;
end;

procedure TRegistrationGuards.TestWrongInputSchemaRoot;
var
  Definition: TJSONObject;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    ExpectToolSchemaRejected(Server, 'array-root', 'desc',
      '{"type":"array"}');

    Definition := TJSONObject.Create;
    Definition.Add('name', 'array-definition-root');
    Definition.Add('inputSchema', GetJSON('{"type":"array"}'));
    ExpectToolDefinitionRejected(Server, Definition);
  finally
    Server.Free;
  end;
end;

procedure TRegistrationGuards.TestNonObjectOutputSchema;
var
  Definition: TJSONObject;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Definition := TJSONObject.Create;
    Definition.Add('name', 'bad-output');
    Definition.Add('inputSchema', GetJSON('{"type":"object"}'));
    Definition.Add('outputSchema', 'not-an-object');
    ExpectToolDefinitionRejected(Server, Definition);
  finally
    Server.Free;
  end;
end;

// A client drops a tool whose x-mcp-header breaks a constraint, so the
// server refuses it at registration; verified 2026-11-26 against
// https://modelcontextprotocol.io/specification/2026-07-28/server/tools#x-mcp-header
procedure TRegistrationGuards.TestBadHeaderAnnotationRejected;
var
  Server: TMCPServer;
  Raised: string;
begin
  // A client would drop the whole tool, so registration refuses it
  // (#90).
  Server := TMCPServer.Create('t', '1');
  try
    Raised := '';
    try
      Server.RegisterTool('bad', 'Bad', '{"type":"object","properties":' +
        '{"n":{"type":"number","x-mcp-header":"N"}}}', EchoHandler)
        .ApplicationValidated;
    except
      on E: EMCPServer do
        Raised := E.Message;
    end;
    Expect<string>(Raised).ToBe('Tool "bad" inputSchema: x-mcp-header of ' +
      '"n" needs type string, integer or boolean, not "number"');
  finally
    Server.Free;
  end;
end;

// x-mcp-header is inside the enforced subset: a header-routed tool
// keeps server-side argument validation (#90).
// ToolHeaderParameters hands out a copy: changing it leaves what the
// HTTP binding validates against untouched (#90 review).
procedure TRegistrationGuards.TestHeaderParametersAreCopies;
var
  Server: TMCPServer;
  First, Second: TMCPHeaderParameters;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Server.RegisterTool('routed', 'Routed', '{"type":"object","properties":' +
      '{"region":{"type":"string","x-mcp-header":"Region"}}}', EchoHandler);
    Server.CreateSession.Free;
    First := Server.ToolHeaderParameters('routed');
    First[0].Path[0] := 'changed';
    First[0].Header := 'Changed';
    Second := Server.ToolHeaderParameters('routed');
    Expect<string>(Second[0].Path[0]).ToBe('region');
    Expect<string>(Second[0].Header).ToBe('Region');
  finally
    Server.Free;
  end;
end;

procedure TRegistrationGuards.TestHeaderAnnotatedToolValidated;
var
  Server: TMCPServer;
  Session: TMCPSession;
  Line: string;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Server.RegisterTool('routed', 'Routed', '{"type":"object","properties":' +
      '{"region":{"type":"string","x-mcp-header":"Region"}},' +
      '"required":["region"]}', EchoHandler);
    Session := Server.CreateSession;
    try
      Server.HandleMessage(Session, '{"jsonrpc":"2.0","id":1,"method":' +
        '"tools/call","params":{"name":"routed","arguments":{"region":7},' +
        META_MODERN + '}}', Line);
      Expect<Boolean>(Pos('Argument \"region\" must be a string', Line) > 0)
        .ToBe(True);
    finally
      Session.Free;
    end;
  finally
    Server.Free;
  end;
end;

procedure TRegistrationGuards.TestWrongOutputSchemaRoot;
var
  Definition: TJSONObject;
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('t', '1');
  try
    Definition := TJSONObject.Create;
    // Any root type is fine since SEP-2106 (#91), verified 2026-11-26
    // against https://modelcontextprotocol.io/specification/2026-07-28/server/tools#output-schema.
    Definition.Add('name', 'array-output');
    Definition.Add('inputSchema', GetJSON('{"type":"object"}'));
    Definition.Add('outputSchema', GetJSON('{"type":"array"}'));
    Server.RegisterTool(Definition, EchoHandler);
    Expect<Integer>(Server.ToolCount).ToBe(1);
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
begin
  ExpectServerCreateRejected('', '1');
end;

procedure TRegistrationGuards.TestEmptyServerVersion;
begin
  ExpectServerCreateRejected('t', '');
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

procedure TRegistrationGuards.TestPromptArgumentsCopyConsumed;
var
  Original, Copied: TMCPPromptArguments;
  BuiltArguments: TJSONArray;
  ErrorMessage: string;
begin
  // The reuse guard must survive record copies (issue #29).
  Original := PromptArguments.Add('value');
  Copied := Original;
  BuiltArguments := Original.Build;
  ErrorMessage := '';
  try
    Copied.Build;
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
  Test('invalid x-mcp-header annotation rejected at registration',
    TestBadHeaderAnnotationRejected);
  Test('a header-annotated tool keeps server-side argument checks',
    TestHeaderAnnotatedToolValidated);
  Test('ToolHeaderParameters returns independent copies',
    TestHeaderParametersAreCopies);
  Test('inputSchema array root rejected', TestWrongInputSchemaRoot);
  Test('non-object outputSchema rejected', TestNonObjectOutputSchema);
  Test('outputSchema with an array root accepted',
    TestWrongOutputSchemaRoot);
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
  Test('prompt arguments record copy sees consumed state',
    TestPromptArgumentsCopyConsumed);
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
  FServer.RegisterTool('nonfinite', 'Reports a non-finite progress total',
    '{"type":"object","properties":{"total":{"type":"string"}}}',
    NonFiniteTotalHandler);
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

// NaN and the infinities have no JSON form: a progress report with
// one as its total raises (MCPWireNumber), so the call becomes an
// isError result and no notification reaches the wire. (The compact
// number text itself is pinned byte for byte by the wire-pin test
// and by MCP.Schema's wire-number suite.)
procedure TNotificationEmission.TestNonFiniteTotalRejected;
var
  Response: TJSONObject;
  Total: string;
begin
  for Total in ['nan', 'inf', '-inf'] do
  begin
    FLines.Clear;
    Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
      '"params":{"name":"nonfinite","arguments":{"total":"' + Total +
      '"},"_meta":{' +
      '"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
      '"io.modelcontextprotocol/clientCapabilities":{},' +
      '"progressToken":7}}}');
    try
      Expect<Integer>(FLines.Count).ToBe(0);
      Expect<Boolean>(
        TJSONData(Response.FindPath('result.isError')).AsBoolean).ToBe(True);
    finally
      Response.Free;
    end;
  end;
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
  Test('a NaN or infinite progress total becomes an isError result',
    TestNonFiniteTotalRejected);
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

// Reports progress and logs a debug line, never asking IsCancelled.
function ReporterHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  MCPReportProgress(ACtx, 0.5, 1.0);
  MCPLogMessage(ACtx, 'debug', 'detail');
  Result := MCPTextResult('reported');
end;

procedure TCancellationDispatch.BeforeEach;
begin
  inherited BeforeEach;
  FServer.RegisterTool('cancellation-aware', 'Polls cancellation',
    '{"type":"object"}', CancellationAwareHandler);
  FServer.RegisterTool('self-cancel', 'Cancels its own request',
    '{"type":"object"}', SelfCancellingHandler);
  FServer.RegisterTool('notification-cancel', 'Receives cancellation',
    '{"type":"object"}', NotificationCancellingHandler);
  FServer.RegisterTool('reporter', 'Reports progress and logs',
    '{"type":"object"}', ReporterHandler);
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

var
  PollCalls: Integer;
  PollAnswer: Boolean;

// A transport poll (#93) that counts its calls and answers PollAnswer.
function CountingPoll(ASession: TMCPSession; AUserData: Pointer): Boolean;
begin
  Inc(PollCalls);
  Result := PollAnswer;
end;

var
  // What CancelsActiveRequest said, from inside the poll, for each of
  // CANCEL_PROBES.
  ActiveAnswers: string;

const
  CANCEL_PROBES: array[0..6] of string = (
    '{"jsonrpc":"2.0","method":"notifications/cancelled",' +
      '"params":{"requestId":9}}',
    '{"jsonrpc":"2.0","method":"notifications/cancelled",' +
      '"params":{"requestId":"9"}}',
    '{"jsonrpc":"2.0","method":"notifications/cancelled",' +
      '"params":{"requestId":9.0,"reason":"user"}}',
    '{"jsonrpc":"2.0","method":"notifications/cancelled",' +
      '"params":{"requestId":10}}',
    // A numeric reason invalidates the notification, as dispatch has it.
    '{"jsonrpc":"2.0","method":"notifications/cancelled",' +
      '"params":{"requestId":9,"reason":5}}',
    '{"jsonrpc":"2.0","method":"notifications\/cancelled",' +
      '"params":{"requestId":9}}',
    'not json');

function RecordingPoll(ASession: TMCPSession; AUserData: Pointer): Boolean;
var
  Probe: string;
begin
  ActiveAnswers := '';
  for Probe in CANCEL_PROBES do
    if ASession.CancelsActiveRequest(Probe) then
      ActiveAnswers := ActiveAnswers + 'y'
    else
      ActiveAnswers := ActiveAnswers + 'n';
  Result := False;
end;

// A transport picks out the cancellation for the running request by
// the core's own rule: numbers by value, strings apart, a malformed
// reason refused, the method decoded (#93 review).
procedure TCancellationDispatch.TestActiveRequestIdMatches;
var
  Response: TJSONObject;
  Target: TJSONData;
begin
  FSession.SetCancellationPoll(RecordingPoll, nil);
  Response := Call('{"jsonrpc":"2.0","id":9,"method":"tools/call",' +
    '"params":{"name":"cancellation-aware",' + META_MODERN + '}}');
  Response.Free;
  Expect<string>(ActiveAnswers).ToBe('ynynnyn');
  // No request running: nothing is active.
  Expect<Boolean>(FSession.CancelsActiveRequest(CANCEL_PROBES[0]))
    .ToBe(False);
  Expect<Boolean>(FSession.IsActiveRequestId(TJSONData(nil))).ToBe(False);
  // MCPCancellationTarget: the requestId of an accepted cancellation
  // only.
  Target := MCPCancellationTarget(CANCEL_PROBES[2]);
  try
    Expect<string>(Target.AsJSON).ToBe('9.0000000000000000E+000');
  finally
    Target.Free;
  end;
  Expect<Boolean>(MCPCancellationTarget(CANCEL_PROBES[4]) = nil).ToBe(True);
  Expect<Boolean>(MCPCancellationTarget(CANCEL_PROBES[6]) = nil).ToBe(True);
end;

// A progress or log call the client did not opt into (no progressToken,
// a log floor above the level) is a no-op: it does not reach the
// transport's poll; an eligible one polls once, at emission (#93
// review).
procedure TCancellationDispatch.TestOptedOutNotificationsDoNotPoll;
var
  ResponseLine: string;
begin
  PollCalls := 0;
  PollAnswer := False;
  FSession.SetCancellationPoll(CountingPoll, nil);
  Expect<Boolean>(Dispatch('{"jsonrpc":"2.0","id":11,"method":"tools/call",' +
    '"params":{"name":"reporter",' + META_MODERN + '}}', ResponseLine))
    .ToBe(True);
  Expect<Integer>(PollCalls).ToBe(0);
  Expect<Boolean>(Dispatch('{"jsonrpc":"2.0","id":12,"method":"tools/call",' +
    '"params":{"name":"reporter","_meta":{' +
    '"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{},' +
    '"io.modelcontextprotocol/logLevel":"error","progressToken":1}}}',
    ResponseLine)).ToBe(True);
  Expect<Integer>(PollCalls).ToBe(1);
end;

// Spec verified 2026-11-27: the receiver SHOULD stop processing a
// cancelled request and not send a response,
// https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/cancellation.
procedure TCancellationDispatch.TestTransportPollCancels;
var
  ResponseLine: string;
begin
  PollCalls := 0;
  PollAnswer := True;
  FSession.SetCancellationPoll(CountingPoll, nil);
  // The handler's IsCancelled consults the poll, which cancels: the
  // response is withheld like any cancelled request's.
  Expect<Boolean>(Dispatch('{"jsonrpc":"2.0","id":5,"method":"tools/call",' +
    '"params":{"name":"cancellation-aware",' + META_MODERN + '}}',
    ResponseLine)).ToBe(False);
  Expect<string>(ResponseLine).ToBe('');
  Expect<Boolean>(CancellationObserved).ToBe(True);
  Expect<Boolean>(PollCalls >= 1).ToBe(True);
end;

procedure TCancellationDispatch.TestTransportPollOnlyDuringRequests;
var
  Response: TJSONObject;
begin
  PollCalls := 0;
  PollAnswer := False;
  FSession.SetCancellationPoll(CountingPoll, nil);
  Response := Call('{"jsonrpc":"2.0","id":6,"method":"tools/call",' +
    '"params":{"name":"cancellation-aware",' + META_MODERN + '}}');
  Expect<string>(TJSONData(Response.FindPath('result.content[0].text'))
    .AsString).ToBe('not cancelled');
  Response.Free;
  Expect<Integer>(PollCalls).ToBe(1);
  // A request whose handler never asks does not poll, and nil removes
  // the poll.
  Response := Call('{"jsonrpc":"2.0","id":7,"method":"tools/list",' +
    '"params":{' + META_MODERN + '}}');
  Response.Free;
  Expect<Integer>(PollCalls).ToBe(1);
  FSession.SetCancellationPoll(nil, nil);
  Response := Call('{"jsonrpc":"2.0","id":8,"method":"tools/call",' +
    '"params":{"name":"cancellation-aware",' + META_MODERN + '}}');
  Response.Free;
  Expect<Integer>(PollCalls).ToBe(1);
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
  Test('a transport poll that reports cancellation cancels the request',
    TestTransportPollCancels);
  Test('opted-out progress and log calls do not poll the transport',
    TestOptedOutNotificationsDoNotPoll);
  Test('CancelsActiveRequest follows the dispatch rule for cancellations',
    TestActiveRequestIdMatches);
  Test('the poll runs only when a handler asks, and nil removes it',
    TestTransportPollOnlyDuringRequests);
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
    // Capabilities follow the registrations (#81): a tool and a
    // resource here, no prompts and no completions. Schema
    // ServerCapabilities ("Present if the server offers ..."), verified
    // 2026-11-26 against
    // https://modelcontextprotocol.io/specification/2026-07-28/schema#servercapabilities
    Server.RegisterTool('echo', 'Echo', '{"type":"object"}', EchoHandler);
    Server.RegisterTextResource('mem://w', 'w', 'text/plain', 'w');
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
        '"tools" : {}, "resources" : {} }, ' +
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
        // Compact number forms (shortest round-trip decimal for
        // fractional values, JSON integers for integral ones) —
        // matching the plain decimals the official SDKs emit.
        Expect<string>(Lines[0]).ToBe(
          '{ "jsonrpc" : "2.0", "method" : "notifications/progress", ' +
          '"params" : { "progressToken" : "wire-token", ' +
          '"progress" : 0.25, ' +
          '"total" : 1, ' +
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

{ ───────── MRTR (#4) ───────── }

const
  // Modern _meta declaring the elicitation capability MRTR tests need.
  META_MRTR =
    '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{"elicitation":{}}}';

// Round 1: elicit a name; retry: greet it, proving the state echo and
// the response accessor.
function GreetUserHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Content: TJSONObject;
begin
  Content := MCPElicitationContent(ACtx, 'who');
  if Content = nil then
    Exit(MCPInputRequired(TJSONObject.Create(['who',
      MCPElicitFormRequest('Who should be greeted?',
      ObjectSchema.AddString('name'))]), 'state-42'));
  Result := MCPTextResult('Hello, ' + Content.Get('name', '') +
    ' [' + ACtx.RequestState + ']');
end;

// Load-shedding shape: requestState only, no inputRequests.
function StateOnlyHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  if ACtx.RequestState = '' then
    Exit(MCPInputRequired(nil, 'opaque-state'));
  Result := MCPTextResult('resumed:' + ACtx.RequestState);
end;

// A hand-crafted entry outside the three MRTR kinds.
function BadKindHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Entry: TJSONObject;
begin
  Entry := TJSONObject.Create;
  Entry.Add('method', 'weird/thing');
  Result := MCPInputRequired(TJSONObject.Create(['x', Entry]));
end;

// Malformed entries the capability gate must reject just as firmly:
// an object carrying no "method" string, and an entry that is not an
// object at all. Neither names a kind, so neither may reach the wire.
function NoMethodEntryHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Requests: TJSONObject;
begin
  Requests := TJSONObject.Create;
  Requests.Add('x', TJSONObject.Create);
  Result := MCPInputRequired(Requests);
end;

function NonObjectEntryHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Requests: TJSONObject;
begin
  Requests := TJSONObject.Create;
  Requests.Add('x', 'elicitation/create');
  Result := MCPInputRequired(Requests);
end;

// The at-least-one-of guard: neither requests nor state.
function EmptyInputRequiredHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPInputRequired(nil, '');
end;

function SetupPromptHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPPromptResult;
var
  Content: TJSONObject;
begin
  Content := MCPElicitationContent(ACtx, 'project');
  if Content = nil then
    Exit(MCPPromptInputRequired(TJSONObject.Create(['project',
      MCPElicitFormRequest('Which project?',
      ObjectSchema.AddString('name'))]), 'p-state'));
  Result := MCPPromptMessagesResult(MCPMessages([
    MCPUserMessage('Set up ' + Content.Get('name', ''))]));
end;

// Prompt-side mirrors of the tools-side rejection handlers: the gate
// lives in one shared helper, so both arms must prove it fires.
function PromptBadKindHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPPromptResult;
var
  Entry: TJSONObject;
begin
  Entry := TJSONObject.Create;
  Entry.Add('method', 'weird/thing');
  Result := MCPPromptInputRequired(TJSONObject.Create(['x', Entry]));
end;

function PromptNoMethodEntryHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPPromptResult;
var
  Requests: TJSONObject;
begin
  Requests := TJSONObject.Create;
  Requests.Add('x', TJSONObject.Create);
  Result := MCPPromptInputRequired(Requests);
end;

procedure TMRTRDispatch.BeforeEach;
begin
  inherited BeforeEach;
  FServer.RegisterTool('greet_user', 'Greets a person it asks about',
    '{"type":"object"}', GreetUserHandler);
  FServer.RegisterTool('resume', 'State-only round trip',
    '{"type":"object"}', StateOnlyHandler);
  FServer.RegisterTool('badkind', 'Unsupported request kind',
    '{"type":"object"}', BadKindHandler);
  FServer.RegisterTool('nomethod', 'Entry without a method',
    '{"type":"object"}', NoMethodEntryHandler);
  FServer.RegisterTool('nonobject', 'Entry that is not an object',
    '{"type":"object"}', NonObjectEntryHandler);
  FServer.RegisterTool('emptyround', 'Neither requests nor state',
    '{"type":"object"}', EmptyInputRequiredHandler);
  FServer.RegisterPrompt('setup', 'Elicits the project first',
    SetupPromptHandler);
  FServer.RegisterPrompt('badkindprompt', 'Unsupported request kind',
    PromptBadKindHandler);
  FServer.RegisterPrompt('nomethodprompt', 'Entry without a method',
    PromptNoMethodEntryHandler);
end;

function GreetCall(const AExtraParams: string): string;
begin
  Result := '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{' +
    '"name":"greet_user",' + AExtraParams + META_MRTR + '}}';
end;

procedure TMRTRDispatch.TestFirstRoundInputRequired;
var
  Response: TJSONObject;
begin
  Response := Call(GreetCall(''));
  Expect<string>(
    TJSONData(Response.FindPath('result.resultType')).AsString)
    .ToBe('input_required');
  Expect<string>(
    TJSONData(Response.FindPath('result.inputRequests.who.method'))
    .AsString).ToBe('elicitation/create');
  Expect<string>(
    TJSONData(Response.FindPath(
    'result.inputRequests.who.params.mode')).AsString).ToBe('form');
  // The client receives the handler's state sealed (#89), never plain.
  Expect<Boolean>(Pos('v1.',
    TJSONData(Response.FindPath('result.requestState')).AsString) = 1)
    .ToBe(True);
  Expect<Boolean>(Pos('state-42',
    TJSONData(Response.FindPath('result.requestState')).AsString) = 0)
    .ToBe(True);
  // An interim result still carries the serverInfo stamp.
  Expect<Boolean>(
    Response.FindPath('result._meta') <> nil).ToBe(True);
  Response.Free;
end;

// The sealed requestState a first round returns, for echoing back.
function TMRTRDispatch.SealedState(const AFirstRound: string): string;
var
  Response: TJSONObject;
begin
  Response := Call(AFirstRound);
  try
    Result := TJSONData(Response.FindPath('result.requestState')).AsString;
  finally
    Response.Free;
  end;
end;

procedure TMRTRDispatch.TestRetryCompletes;
var
  Response: TJSONObject;
begin
  Response := Call(GreetCall(
    '"inputResponses":{"who":{"action":"accept",' +
    '"content":{"name":"Ada"}}},"requestState":"' +
    SealedState(GreetCall('')) + '",'));
  Expect<string>(
    TJSONData(Response.FindPath('result.resultType')).AsString)
    .ToBe('complete');
  Expect<string>(
    TJSONData(Response.FindPath('result.content[0].text')).AsString)
    .ToBe('Hello, Ada [state-42]');
  Response.Free;
end;

procedure TMRTRDispatch.TestStateOnlyRound;
var
  Response: TJSONObject;
  State: string;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"resume",' + META_MRTR + '}}');
  Expect<string>(
    TJSONData(Response.FindPath('result.resultType')).AsString)
    .ToBe('input_required');
  Expect<Boolean>(
    Response.FindPath('result.inputRequests') = nil).ToBe(True);
  State := TJSONData(Response.FindPath('result.requestState')).AsString;
  Response.Free;

  Response := Call('{"jsonrpc":"2.0","id":2,"method":"tools/call",' +
    '"params":{"name":"resume","requestState":"' + State + '",' +
    META_MRTR + '}}');
  Expect<string>(
    TJSONData(Response.FindPath('result.content[0].text')).AsString)
    .ToBe('resumed:opaque-state');
  Response.Free;
end;

procedure TMRTRDispatch.TestMissingCapabilityRejected;
var
  Response: TJSONObject;
begin
  // Same tool, but the client declares no elicitation capability:
  // the spec forbids sending the request kind, so -32021.
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"greet_user",' + META_MODERN + '}}');
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(-32021);
  Expect<Boolean>(Response.FindPath(
    'error.data.requiredCapabilities.elicitation') <> nil).ToBe(True);
  Response.Free;
end;

procedure TMRTRDispatch.TestUnknownKindRejected;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"badkind",' + META_MRTR + '}}');
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(JSONRPC_INTERNAL_ERROR);
  Expect<Boolean>(Pos('weird/thing',
    TJSONObject(Response.Find('error')).Get('message', '')) > 0)
    .ToBe(True);
  Response.Free;
end;

procedure TMRTRDispatch.TestMissingMethodEntryRejected;
var
  Response: TJSONObject;
begin
  // An entry object with no "method" names no kind: the gate must
  // reject it instead of letting an empty unknown-kind signal through.
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"nomethod",' + META_MRTR + '}}');
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(JSONRPC_INTERNAL_ERROR);
  Expect<Boolean>(Pos('(missing method)',
    TJSONObject(Response.Find('error')).Get('message', '')) > 0)
    .ToBe(True);
  Expect<Boolean>(Response.Find('result') = nil).ToBe(True);
  Response.Free;
end;

procedure TMRTRDispatch.TestNonObjectEntryRejected;
var
  Response: TJSONObject;
begin
  // Same verdict when the entry is not an object at all.
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"nonobject",' + META_MRTR + '}}');
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(JSONRPC_INTERNAL_ERROR);
  Expect<Boolean>(Pos('(missing method)',
    TJSONObject(Response.Find('error')).Get('message', '')) > 0)
    .ToBe(True);
  Expect<Boolean>(Response.Find('result') = nil).ToBe(True);
  Response.Free;
end;

procedure TMRTRDispatch.TestPromptMissingCapabilityRejected;
var
  Response: TJSONObject;
begin
  // Prompts share the tools' gate: no declared elicitation capability,
  // so the round is refused rather than sent.
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"prompts/get",' +
    '"params":{"name":"setup",' + META_MODERN + '}}');
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(-32021);
  Expect<Boolean>(Response.FindPath(
    'error.data.requiredCapabilities.elicitation') <> nil).ToBe(True);
  Response.Free;
end;

procedure TMRTRDispatch.TestPromptUnknownKindRejected;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"prompts/get",' +
    '"params":{"name":"badkindprompt",' + META_MRTR + '}}');
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(JSONRPC_INTERNAL_ERROR);
  Expect<Boolean>(Pos('weird/thing',
    TJSONObject(Response.Find('error')).Get('message', '')) > 0)
    .ToBe(True);
  Response.Free;
end;

procedure TMRTRDispatch.TestPromptMalformedEntryRejected;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"prompts/get",' +
    '"params":{"name":"nomethodprompt",' + META_MRTR + '}}');
  Expect<Integer>(TJSONObject(Response.Find('error')).Get('code', 0))
    .ToBe(JSONRPC_INTERNAL_ERROR);
  Expect<Boolean>(Pos('(missing method)',
    TJSONObject(Response.Find('error')).Get('message', '')) > 0)
    .ToBe(True);
  Expect<Boolean>(Response.Find('result') = nil).ToBe(True);
  Response.Free;
end;

procedure TMRTRDispatch.TestEmptyInputRequiredGuard;
var
  Response: TJSONObject;
begin
  // The builder itself raises; the dispatch wrapper surfaces it
  // in-band like any handler failure.
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"emptyround",' + META_MRTR + '}}');
  Expect<Boolean>(
    TJSONData(Response.FindPath('result.isError')).AsBoolean).ToBe(True);
  Response.Free;
end;

procedure TMRTRDispatch.TestLegacyToolGetsInBandError;
var
  Response: TJSONObject;
  Ignored: string;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"initialize",' +
    '"params":{"protocolVersion":"2025-11-25","capabilities":{},' +
    '"clientInfo":{"name":"legacy","version":"1.0"}}}');
  Response.Free;
  Dispatch('{"jsonrpc":"2.0","method":"notifications/initialized"}',
    Ignored);
  Response := Call('{"jsonrpc":"2.0","id":2,"method":"tools/call",' +
    '"params":{"name":"greet_user"}}');
  Expect<Boolean>(
    TJSONData(Response.FindPath('result.isError')).AsBoolean).ToBe(True);
  Expect<Boolean>(Pos('legacy-era',
    TJSONData(Response.FindPath('result.content[0].text')).AsString) > 0)
    .ToBe(True);
  // Legacy results never carry the modern resultType stamp.
  Expect<Boolean>(
    Response.FindPath('result.resultType') = nil).ToBe(True);
  Response.Free;
end;

procedure TMRTRDispatch.TestPromptRoundTrip;
var
  Response: TJSONObject;
  State: string;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"prompts/get",' +
    '"params":{"name":"setup",' + META_MRTR + '}}');
  Expect<string>(
    TJSONData(Response.FindPath('result.resultType')).AsString)
    .ToBe('input_required');
  State := TJSONData(Response.FindPath('result.requestState')).AsString;
  Response.Free;

  Response := Call('{"jsonrpc":"2.0","id":2,"method":"prompts/get",' +
    '"params":{"name":"setup",' +
    '"inputResponses":{"project":{"action":"accept",' +
    '"content":{"name":"herakles"}}},"requestState":"' + State + '",' +
    META_MRTR + '}}');
  Expect<string>(
    TJSONData(Response.FindPath('result.resultType')).AsString)
    .ToBe('complete');
  Expect<Boolean>(Pos('Set up herakles',
    TJSONData(Response.FindPath(
    'result.messages[0].content.text')).AsString) > 0).ToBe(True);
  Response.Free;
end;

procedure TMRTRDispatch.TestSamplingAndRootsBuilders;
var
  Sampling, Roots: TJSONObject;
begin
  Sampling := MCPSamplingTextRequest('What is 2+2?', 50);
  Expect<string>(Sampling.Get('method', ''))
    .ToBe('sampling/createMessage');
  Expect<string>(TJSONData(Sampling.FindPath(
    'params.messages[0].content.text')).AsString).ToBe('What is 2+2?');
  Expect<Integer>(TJSONData(Sampling.FindPath('params.maxTokens'))
    .AsInteger).ToBe(50);
  Sampling.Free;
  Roots := MCPRootsRequest;
  Expect<string>(Roots.Get('method', '')).ToBe('roots/list');
  Roots.Free;
end;

procedure TMRTRDispatch.SetupTests;
begin
  Test('first round → input_required with requests and state',
    TestFirstRoundInputRequired);
  Test('retry with inputResponses completes', TestRetryCompletes);
  Test('state-only round (no inputRequests)', TestStateOnlyRound);
  Test('undeclared capability → -32021', TestMissingCapabilityRejected);
  Test('unknown request kind → -32603', TestUnknownKindRejected);
  Test('entry without a method → -32603',
    TestMissingMethodEntryRejected);
  Test('entry that is not an object → -32603',
    TestNonObjectEntryRejected);
  Test('prompt undeclared capability → -32021',
    TestPromptMissingCapabilityRejected);
  Test('prompt unknown request kind → -32603',
    TestPromptUnknownKindRejected);
  Test('prompt entry without a method → -32603',
    TestPromptMalformedEntryRejected);
  Test('neither requests nor state → guarded',
    TestEmptyInputRequiredGuard);
  Test('legacy era → in-band error, no resultType',
    TestLegacyToolGetsInBandError);
  Test('prompt input_required round trip', TestPromptRoundTrip);
  Test('sampling and roots entry builders', TestSamplingAndRootsBuilders);
end;

{ ───────── subset validation (#23) ───────── }

// Mirrors the arguments the handler actually received, so tests can
// observe default seeding and unvalidated passthrough.
function ArgsMirrorHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPTextResult(AArguments.AsJSON);
end;

procedure TSubsetValidation.BeforeEach;
begin
  inherited BeforeEach;
  // Raw-handler tool exercising every subset keyword: required,
  // enum, default, integer.
  FServer.RegisterTool('pick', 'Pick a color',
    '{"type":"object","properties":{' +
    '"color":{"type":"string","enum":["red","green"]},' +
    '"count":{"type":"integer","default":3}},' +
    '"required":["color"]}',
    ArgsMirrorHandler);
end;

function PickLine(const AArgumentsJson: string): string;
begin
  Result := '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{' +
    '"name":"pick","arguments":' + AArgumentsJson + ',' + META_MODERN +
    '}}';
end;

procedure TSubsetValidation.TestMissingRequiredRejected;
var
  Response: TJSONObject;
begin
  Response := Call(PickLine('{}'));
  Expect<Boolean>(
    TJSONData(Response.FindPath('result.isError')).AsBoolean).ToBe(True);
  Expect<string>(
    TJSONData(Response.FindPath('result.content[0].text')).AsString)
    .ToBe('Missing required argument "color"');
  Response.Free;
end;

procedure TSubsetValidation.TestMistypedStringRejected;
var
  Response: TJSONObject;
begin
  Response := Call(PickLine('{"color":7}'));
  Expect<Boolean>(
    TJSONData(Response.FindPath('result.isError')).AsBoolean).ToBe(True);
  Expect<string>(
    TJSONData(Response.FindPath('result.content[0].text')).AsString)
    .ToBe('Argument "color" must be a string');
  Response.Free;
end;

procedure TSubsetValidation.TestEnumViolationRejected;
var
  Response: TJSONObject;
begin
  Response := Call(PickLine('{"color":"blue"}'));
  Expect<Boolean>(
    TJSONData(Response.FindPath('result.isError')).AsBoolean).ToBe(True);
  Expect<string>(
    TJSONData(Response.FindPath('result.content[0].text')).AsString)
    .ToBe('Argument "color" must be a string from the declared enum values');
  Response.Free;
end;

procedure TSubsetValidation.TestEnumAcceptedAndDefaultSeeded;
var
  Response: TJSONObject;
  MirroredText: string;
begin
  Response := Call(PickLine('{"color":"red"}'));
  Expect<Boolean>(
    TJSONData(Response.FindPath('result.isError')).AsBoolean).ToBe(False);
  // The absent optional argument arrives seeded with its default,
  // the same view a typed handler gets.
  MirroredText :=
    TJSONData(Response.FindPath('result.content[0].text')).AsString;
  Expect<Boolean>(Pos('"count" : 3', MirroredText) > 0).ToBe(True);
  Response.Free;
end;

procedure TSubsetValidation.TestFloatForIntegerRejected;
var
  Response: TJSONObject;
begin
  Response := Call(PickLine('{"color":"red","count":2.5}'));
  Expect<Boolean>(
    TJSONData(Response.FindPath('result.isError')).AsBoolean).ToBe(True);
  Expect<string>(
    TJSONData(Response.FindPath('result.content[0].text')).AsString)
    .ToBe('Argument "count" must be an integer');
  Response.Free;
end;

procedure TSubsetValidation.TestUnknownArgumentIgnored;
var
  Response: TJSONObject;
begin
  // Unknown properties pass through untouched — the same tolerance
  // the typed path applies to unknown keys (documented policy).
  Response := Call(PickLine('{"color":"green","extra":"x"}'));
  Expect<Boolean>(
    TJSONData(Response.FindPath('result.isError')).AsBoolean).ToBe(False);
  Response.Free;
end;

procedure TSubsetValidation.TestOutOfSubsetSchemaFailsFreeze;
var
  ErrorMessage, Response: string;
begin
  // "format" is outside the enforced subset (#91 added arrays and
  // nesting, not string formats).
  FServer.RegisterTool('rich', 'Formatted input',
    '{"type":"object","properties":{"data":{"type":"string","format":"uri"}}}',
    ArgsMirrorHandler);
  ErrorMessage := '';
  try
    Dispatch('{"jsonrpc":"2.0","id":1,"method":"tools/list",' +
      '"params":{' + META_MODERN + '}}', Response);
  except
    on E: EMCPServer do
      ErrorMessage := E.Message;
  end;
  Expect<Boolean>(Pos('Tool "rich"', ErrorMessage) > 0).ToBe(True);
  Expect<Boolean>(Pos('ApplicationValidated', ErrorMessage) > 0)
    .ToBe(True);
end;

procedure TSubsetValidation.TestApplicationValidatedSkipsChecks;
var
  Response: TJSONObject;
  MirroredText: string;
begin
  FServer.RegisterTool('rich', 'Array-typed input',
    '{"type":"object","properties":{"data":{"type":"array"}}}',
    ArgsMirrorHandler).ApplicationValidated;
  // Arguments that would fail any schema check flow through to the
  // handler untouched: validation is the application's contract now.
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"rich","arguments":{"data":42},' + META_MODERN +
    '}}');
  Expect<Boolean>(
    TJSONData(Response.FindPath('result.isError')).AsBoolean).ToBe(False);
  MirroredText :=
    TJSONData(Response.FindPath('result.content[0].text')).AsString;
  Expect<Boolean>(Pos('"data" : 42', MirroredText) > 0).ToBe(True);
  Response.Free;
end;

procedure TSubsetValidation.SetupTests;
begin
  Test('missing required argument → isError', TestMissingRequiredRejected);
  Test('mistyped argument → isError', TestMistypedStringRejected);
  Test('enum violation → isError', TestEnumViolationRejected);
  Test('valid enum accepted, default seeded',
    TestEnumAcceptedAndDefaultSeeded);
  Test('float for integer → isError', TestFloatForIntegerRejected);
  Test('unknown argument ignored', TestUnknownArgumentIgnored);
  Test('out-of-subset schema fails at freeze',
    TestOutOfSubsetSchemaFailsFreeze);
  Test('ApplicationValidated skips call-time checks',
    TestApplicationValidatedSkipsChecks);
end;

{ ───────── handler-raised protocol errors (#88) ───────── }

const
  PROTOCOL_ERROR_TEXT = 'Ung' + #$C3#$BC + 'ltig: ' + #$F0#$9F#$98#$80;

function ProtocolErrorData: TJSONObject;
begin
  // The escape keeps the source ASCII: the parser stores U+00E9 as
  // the UTF-8 bytes C3 A9, which the wire line must carry unchanged.
  Result := TJSONObject(GetJSON('{"field":"w\u00e9rt"}'));
end;

function RefusingToolHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := Default(TMCPToolResult);
  raise EMCPProtocolError.Create(JSONRPC_INVALID_PARAMS, PROTOCOL_ERROR_TEXT,
    ProtocolErrorData);
end;

function RefusingTypedHandler(AArgs: TMCPArgs;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := Default(TMCPToolResult);
  raise EMCPProtocolError.Create(-1, 'application refusal');
end;

function NeedsSamplingHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := Default(TMCPToolResult);
  if not ACtx.HasCapability('sampling') then
    raise MCPMissingCapabilityError('sampling');
end;

// Changes the borrowed data after construction, which the dispatch
// check catches (#88 review round 3).
function ChangedRefusalHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  E: EMCPProtocolError;
begin
  Result := Default(TMCPToolResult);
  E := MCPMissingCapabilityError('sampling');
  TJSONObject(E.Data).Clear;
  raise E;
end;

function RefusingPromptHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  Result := nil;
  raise EMCPProtocolError.Create(JSONRPC_INVALID_PARAMS, PROTOCOL_ERROR_TEXT);
end;

function RefusingReader(const AUri: string;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  Result := nil;
  raise EMCPProtocolError.Create(4030, 'not shared with you: ' + AUri);
end;

function RefusingTemplateReader(const AUri: string; AVars: TJSONObject;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  Result := nil;
  // An application refusal: a resource that does not exist is the
  // reader returning nil, which the server answers era-appropriately.
  raise EMCPProtocolError.Create(4290, 'quota exhausted for ' +
    AVars.Get('id', ''));
end;

procedure THandlerProtocolErrors.BeforeEach;
begin
  inherited BeforeEach;
  FServer.RegisterTool('refuse', 'Refuses', '{"type":"object"}',
    RefusingToolHandler);
  FServer.RegisterTool('refuse_typed', 'Refuses typed', TScaleArgs,
    RefusingTypedHandler);
  FServer.RegisterTool('needs_sampling', 'Needs sampling',
    '{"type":"object"}', NeedsSamplingHandler);
  FServer.RegisterTool('changed_refusal', 'Changes its refusal',
    '{"type":"object"}', ChangedRefusalHandler);
  FServer.RegisterPrompt('refuse_prompt', 'Refuses', RefusingPromptHandler);
  FServer.RegisterResource('mem://refuse', 'refuse', 'text/plain',
    RefusingReader);
  FServer.RegisterResourceTemplate('mem://item/{id}', 'item', 'text/plain',
    RefusingTemplateReader);
end;

function ToolCallLine(const AName, AArguments: string): string;
begin
  Result := '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{' +
    '"name":"' + AName + '","arguments":' + AArguments + ',' +
    META_MODERN + '}}';
end;

const
  REFUSE_LINE =
    '{ "jsonrpc" : "2.0", "id" : 7, "error" : { "code" : -32602, ' +
    '"message" : "' + PROTOCOL_ERROR_TEXT + '", "data" : { ' +
    '"field" : "w' + #$C3#$A9 + 'rt" } } }';

procedure THandlerProtocolErrors.TestToolErrorLineByteExact;
var
  Response: string;
begin
  Expect<Boolean>(Dispatch(ToolCallLine('refuse', '{}'), Response)).ToBe(True);
  Expect<string>(Response).ToBe(REFUSE_LINE);
end;

procedure THandlerProtocolErrors.TestRedactionLeavesItAlone;
var
  Response: string;
begin
  FServer.RedactErrorDetails := True;
  Expect<Boolean>(Dispatch(ToolCallLine('refuse', '{}'), Response)).ToBe(True);
  Expect<string>(Response).ToBe(REFUSE_LINE);
end;

procedure THandlerProtocolErrors.TestTypedToolError;
var
  Response: string;
begin
  Expect<Boolean>(Dispatch(ToolCallLine('refuse_typed',
    '{"value":1,"times":2}'), Response)).ToBe(True);
  Expect<string>(Response).ToBe('{ "jsonrpc" : "2.0", "id" : 7, "error" : ' +
    '{ "code" : -1, "message" : "application refusal" } }');
end;

procedure THandlerProtocolErrors.TestPromptError;
var
  Response: string;
begin
  Expect<Boolean>(Dispatch('{"jsonrpc":"2.0","id":7,"method":"prompts/get",' +
    '"params":{"name":"refuse_prompt",' + META_MODERN + '}}', Response))
    .ToBe(True);
  Expect<string>(Response).ToBe('{ "jsonrpc" : "2.0", "id" : 7, "error" : ' +
    '{ "code" : -32602, "message" : "' + PROTOCOL_ERROR_TEXT + '" } }');
end;

procedure THandlerProtocolErrors.TestResourceError;
var
  Response: string;
begin
  Expect<Boolean>(Dispatch('{"jsonrpc":"2.0","id":7,"method":"resources/read",' +
    '"params":{"uri":"mem://refuse",' + META_MODERN + '}}', Response))
    .ToBe(True);
  Expect<string>(Response).ToBe('{ "jsonrpc" : "2.0", "id" : 7, "error" : ' +
    '{ "code" : 4030, "message" : "not shared with you: mem://refuse" } }');
end;

procedure THandlerProtocolErrors.TestTemplateError;
var
  Response: string;
begin
  Expect<Boolean>(Dispatch('{"jsonrpc":"2.0","id":7,"method":"resources/read",' +
    '"params":{"uri":"mem://item/42",' + META_MODERN + '}}', Response))
    .ToBe(True);
  Expect<string>(Response).ToBe('{ "jsonrpc" : "2.0", "id" : 7, "error" : ' +
    '{ "code" : 4290, "message" : "quota exhausted for 42" } }');
end;

procedure THandlerProtocolErrors.TestLegacyEraToolError;
var
  Response: TJSONObject;
  Line: string;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"initialize",' +
    '"params":{"protocolVersion":"2025-11-25","capabilities":{},' +
    '"clientInfo":{"name":"legacy-client","version":"1.2.3"}}}');
  Response.Free;
  SendNotification(
    '{"jsonrpc":"2.0","method":"notifications/initialized"}');
  Expect<Boolean>(Dispatch('{"jsonrpc":"2.0","id":7,"method":"tools/call",' +
    '"params":{"name":"refuse","arguments":{}}}', Line)).ToBe(True);
  Expect<string>(Line).ToBe(REFUSE_LINE);
end;

procedure THandlerProtocolErrors.TestMissingCapabilityHelper;
var
  Response: string;
begin
  Expect<Boolean>(Dispatch(ToolCallLine('needs_sampling', '{}'), Response))
    .ToBe(True);
  Expect<string>(Response).ToBe('{ "jsonrpc" : "2.0", "id" : 7, "error" : ' +
    '{ "code" : -32021, "message" : "Missing required client capability: ' +
    'sampling", "data" : { "requiredCapabilities" : { "sampling" : {} } } } }');
end;

procedure THandlerProtocolErrors.TestReservedCodesRefused;
const
  RESERVED: array[0..7] of Integer =
    (-32768, -32604, -32000, -32002, -32019, -32020, -32022, -32099);
var
  I: Integer;
  Raised: Boolean;
begin
  for I := Low(RESERVED) to High(RESERVED) do
  begin
    Raised := False;
    try
      EMCPProtocolError.Create(RESERVED[I], 'x', ProtocolErrorData).Free;
    except
      on E: EMCPServer do
        Raised := Pos(IntToStr(RESERVED[I]), E.Message) > 0;
    end;
    Expect<Boolean>(Raised).ToBe(True);
  end;
end;

// Error-code policy verified 2026-11-26 against
// https://modelcontextprotocol.io/specification/2026-07-28/basic/index#error-codes
// and the schema's MissingRequiredClientCapabilityError.
procedure THandlerProtocolErrors.TestAllowedCodesAccepted;
const
  ALLOWED: array[0..8] of Integer =
    (-32700, -32600, -32601, -32602, -32603, -32769, -1, 0, 4040);
var
  I: Integer;
  E: EMCPProtocolError;
  Raised: Boolean;
begin
  for I := Low(ALLOWED) to High(ALLOWED) do
  begin
    E := EMCPProtocolError.Create(ALLOWED[I], 'x');
    try
      Expect<Integer>(E.Code).ToBe(ALLOWED[I]);
    finally
      E.Free;
    end;
  end;
  // -32021 needs its requiredCapabilities data (#88 review).
  Raised := False;
  try
    EMCPProtocolError.Create(-32021, 'missing sampling').Free;
  except
    on E2: EMCPServer do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  Raised := False;
  try
    EMCPProtocolError.Create(-32021, 'missing',
      TJSONObject(GetJSON('{"requiredCapabilities":{}}'))).Free;
  except
    on E2: EMCPServer do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  // Each capability must be an object, as the schema has it.
  Raised := False;
  try
    EMCPProtocolError.Create(-32021, 'missing',
      TJSONObject(GetJSON('{"requiredCapabilities":{"sampling":true}}'))).Free;
  except
    on E2: EMCPServer do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  MCPMissingCapabilityError('roots').Free;
end;

// True when constructing -32021 with AData raises EMCPServer (and no
// other exception: the constructor owns AData on every path).
function CapabilityDataRefused(AData: TJSONData): Boolean;
begin
  Result := False;
  try
    EMCPProtocolError.Create(-32021, 'missing', AData).Free;
  except
    on E: EMCPServer do
      Result := True;
  end;
end;

// requiredCapabilities is a ClientCapabilities object: the members the
// schema types must be objects too. Verified 2026-11-27 against
// schema/2026-07-28/schema.json (ClientCapabilities,
// MissingRequiredClientCapabilityError).
procedure THandlerProtocolErrors.TestCapabilityDataShape;
var
  WithNil, Capabilities: TJSONObject;
begin
  Expect<Boolean>(CapabilityDataRefused(GetJSON(
    '{"requiredCapabilities":{"sampling":{"tools":false}}}'))).ToBe(True);
  Expect<Boolean>(CapabilityDataRefused(GetJSON(
    '{"requiredCapabilities":{"elicitation":{"form":1}}}'))).ToBe(True);
  Expect<Boolean>(CapabilityDataRefused(GetJSON(
    '{"requiredCapabilities":{"extensions":{"io.example/x":true}}}')))
    .ToBe(True);
  Expect<Boolean>(CapabilityDataRefused(GetJSON(
    '{"requiredCapabilities":{"experimental":{"x":null}}}'))).ToBe(True);
  // A nil member serializes as null; it is refused, not dereferenced.
  Capabilities := TJSONObject.Create;
  Capabilities.Add('sampling', TJSONData(nil));
  WithNil := TJSONObject.Create;
  WithNil.Add('requiredCapabilities', Capabilities);
  Expect<Boolean>(CapabilityDataRefused(WithNil)).ToBe(True);
  // A capability of the client's own is valid with any value, a member
  // stored as nil included: its key is present (#84 review).
  Capabilities := TJSONObject.Create;
  Capabilities.Add('com.example/feature', TJSONData(nil));
  WithNil := TJSONObject.Create;
  WithNil.Add('requiredCapabilities', Capabilities);
  Expect<Boolean>(CapabilityDataRefused(WithNil)).ToBe(False);
  EMCPProtocolError.Create(-32021, 'missing', GetJSON(
    '{"requiredCapabilities":{"sampling":{"tools":{}},' +
    '"extensions":{"io.modelcontextprotocol/ui":{}}}}')).Free;
end;

procedure THandlerProtocolErrors.TestChangedDataSentAsInternalError;
var
  Response: string;
begin
  Expect<Boolean>(Dispatch(ToolCallLine('changed_refusal', '{}'), Response))
    .ToBe(True);
  Expect<string>(Response).ToBe('{ "jsonrpc" : "2.0", "id" : 7, "error" : ' +
    '{ "code" : -32603, "message" : "Internal error" } }');
end;

procedure THandlerProtocolErrors.SetupTests;
begin
  Test('tool error line is byte-exact (code, message, data)',
    TestToolErrorLineByteExact);
  Test('RedactErrorDetails leaves a deliberate error alone',
    TestRedactionLeavesItAlone);
  Test('typed-argument tool error', TestTypedToolError);
  Test('prompt handler error keeps its code', TestPromptError);
  Test('resource reader error keeps its code', TestResourceError);
  Test('template reader refusal with an application code', TestTemplateError);
  Test('legacy-era tools/call gets the same error', TestLegacyEraToolError);
  Test('MCPMissingCapabilityError builds -32021 with requiredCapabilities',
    TestMissingCapabilityHelper);
  Test('reserved codes refused at construction', TestReservedCodesRefused);
  Test('JSON-RPC and application codes accepted; -32021 needs its data',
    TestAllowedCodesAccepted);
  Test('-32021 data follows the ClientCapabilities shapes; nil refused',
    TestCapabilityDataShape);
  Test('-32021 data changed after construction is sent as -32603',
    TestChangedDataSentAsInternalError);
end;

{ ───────── structured output (#91) ───────── }

const
  USERS_SCHEMA = '{"type":"array","items":{"type":"object","properties":' +
    '{"id":{"type":"string"},"name":{"type":"string"}},"required":["id"]}}';

function OutputTool(const AName, AOutputSchema: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('name', AName);
  Result.Add('inputSchema', GetJSON('{"type":"object"}'));
  Result.Add('outputSchema', GetJSON(AOutputSchema));
end;

function UsersHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPStructuredResult(GetJSON('[{"id":"1","name":"Ada"}]'));
end;

function BadUsersHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPStructuredResult(GetJSON('[{"id":"1"},{"name":"no id"}]'));
end;

function NoStructuredHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPTextResult('forgot the structured part');
end;

function FailingOutputHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPErrorResult('upstream unavailable');
end;

function CountHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPStructuredResult(TJSONIntegerNumber.Create(42));
end;

// Custom text beside non-object output: classic clients get both.
function LabelledUsersHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPStructuredResult('Found ' + #$C3#$BC + 'sers',
    GetJSON('[{"id":"1","name":"Ada"}]'));
end;

function ErrorWithBadStructuredHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPStructuredResult('quota exceeded', GetJSON('"not users"'));
  Result.IsError := True;
end;

// NaN has no JSON form; the two-argument builder takes it as given.
function NaNHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPStructuredResult('nan', TJSONFloatNumber.Create(NaN));
end;

// A wire number set to NaN after construction: serializing it raises.
function WireNaNHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Value: TJSONData;
begin
  Value := MCPWireNumber(1.5);
  Value.AsFloat := NaN;
  Result := MCPStructuredResult('nan', Value);
end;

function ErrorWithGoodStructuredHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPStructuredResult('partial', GetJSON('[{"id":"1"}]'));
  Result.IsError := True;
end;

procedure TStructuredOutput.BeforeEach;
begin
  inherited BeforeEach;
  FServer.RegisterTool(OutputTool('users', USERS_SCHEMA), UsersHandler);
  FServer.RegisterTool(OutputTool('bad_users', USERS_SCHEMA), BadUsersHandler);
  FServer.RegisterTool(OutputTool('no_structured', USERS_SCHEMA),
    NoStructuredHandler);
  FServer.RegisterTool(OutputTool('failing', USERS_SCHEMA),
    FailingOutputHandler);
  FServer.RegisterTool(OutputTool('count', '{"type":"integer"}'), CountHandler);
  // "format" is outside the subset: the output is the handler's to honour.
  FServer.RegisterTool(OutputTool('formatted',
    '{"type":"string","format":"uri"}'), CountHandler);
  FServer.RegisterTool(OutputTool('labelled', USERS_SCHEMA),
    LabelledUsersHandler);
  FServer.RegisterTool(OutputTool('error_bad', USERS_SCHEMA),
    ErrorWithBadStructuredHandler);
  FServer.RegisterTool(OutputTool('error_good', USERS_SCHEMA),
    ErrorWithGoodStructuredHandler);
  FServer.RegisterTool(OutputTool('nan_number', '{"type":"number"}'),
    NaNHandler);
  FServer.RegisterTool('nan_unchecked', 'NaN, no output schema',
    '{"type":"object"}', WireNaNHandler);
end;

function OutputCall(const ATool: string): string;
begin
  Result := '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{' +
    '"name":"' + ATool + '",' + META_MODERN + '}}';
end;

procedure TStructuredOutput.TestArrayOutputSent;
var
  Response: string;
begin
  Expect<Boolean>(Dispatch(OutputCall('users'), Response)).ToBe(True);
  // The text block carries the serialized JSON (SHOULD, SEP-2106),
  // verified 2026-11-26 against
  // https://modelcontextprotocol.io/specification/2026-07-28/server/tools#structured-content
  Expect<Boolean>(Pos('"content" : [{ "type" : "text", "text" : ' +
    '"[{ \"id\" : \"1\", \"name\" : \"Ada\" }]" }], "isError" : false, ' +
    '"structuredContent" : [{ "id" : "1", "name" : "Ada" }]', Response) > 0)
    .ToBe(True);
end;

procedure TStructuredOutput.TestScalarOutputSent;
var
  Response: TJSONObject;
begin
  Response := Call(OutputCall('count'));
  Expect<Integer>(TJSONData(Response.FindPath('result.structuredContent'))
    .AsInteger).ToBe(42);
  Response.Free;
end;

procedure TStructuredOutput.TestMismatchBecomesIsError;
var
  Response: TJSONObject;
begin
  Response := Call(OutputCall('bad_users'));
  Expect<Boolean>(TJSONData(Response.FindPath('result.isError')).AsBoolean)
    .ToBe(True);
  Expect<string>(TJSONData(Response.FindPath('result.content[0].text')).AsString)
    .ToBe('Tool "bad_users" produced output that does not match its ' +
    'outputSchema: Missing required structured output "[1].id"');
  Expect<Boolean>(Response.FindPath('result.structuredContent') = nil)
    .ToBe(True);
  Response.Free;
end;

procedure TStructuredOutput.TestMissingStructuredContent;
var
  Response: TJSONObject;
begin
  Response := Call(OutputCall('no_structured'));
  Expect<string>(TJSONData(Response.FindPath('result.content[0].text')).AsString)
    .ToBe('Tool "no_structured" produced output that does not match its ' +
    'outputSchema: no structuredContent was returned');
  Response.Free;
end;

procedure TStructuredOutput.TestHandlerIsErrorNotChecked;
var
  Response: TJSONObject;
begin
  Response := Call(OutputCall('failing'));
  Expect<string>(TJSONData(Response.FindPath('result.content[0].text')).AsString)
    .ToBe('upstream unavailable');
  Response.Free;
end;

procedure TStructuredOutput.TestOutOfSubsetOutputNotChecked;
var
  Response: TJSONObject;
begin
  // 42 is not a string, but the schema is outside the subset.
  Response := Call(OutputCall('formatted'));
  Expect<Boolean>(TJSONData(Response.FindPath('result.isError')).AsBoolean)
    .ToBe(False);
  Response.Free;
end;

procedure TStructuredOutput.TestLegacyDialect;
var
  Response: TJSONObject;
  Tools: TJSONArray;
  I: Integer;
  Found: Boolean;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"initialize",' +
    '"params":{"protocolVersion":"2025-11-25","capabilities":{},' +
    '"clientInfo":{"name":"legacy-client","version":"1.2.3"}}}');
  Response.Free;
  SendNotification(
    '{"jsonrpc":"2.0","method":"notifications/initialized"}');
  // The tool stays in the classic listing, without its non-object
  // outputSchema (2025-11-25 schema, Tool.outputSchema), verified
  // 2026-11-27 against
  // https://modelcontextprotocol.io/specification/2025-11-25/schema#tool
  Found := False;
  Response := Call('{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}');
  Tools := TJSONArray(Response.FindPath('result.tools'));
  for I := 0 to Tools.Count - 1 do
    if TJSONObject(Tools[I]).Get('name', '') = 'users' then
    begin
      Found := True;
      Expect<Boolean>(TJSONObject(Tools[I]).Find('outputSchema') = nil)
        .ToBe(True);
    end;
  Expect<Boolean>(Found).ToBe(True);
  Response.Free;
  // ...and its array output travels in the text block only
  // (CallToolResult.structuredContent is an object there, same source,
  // https://modelcontextprotocol.io/specification/2025-11-25/schema#calltoolresult).
  Response := Call('{"jsonrpc":"2.0","id":3,"method":"tools/call",' +
    '"params":{"name":"users","arguments":{}}}');
  Expect<Boolean>(Response.FindPath('result.structuredContent') = nil)
    .ToBe(True);
  Expect<Boolean>(Pos('Ada', TJSONData(Response.FindPath(
    'result.content[0].text')).AsString) > 0).ToBe(True);
  Response.Free;
end;

procedure TStructuredOutput.TestLegacyKeepsCustomText;
var
  Response: TJSONObject;
  Line: string;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"initialize",' +
    '"params":{"protocolVersion":"2025-11-25","capabilities":{},' +
    '"clientInfo":{"name":"legacy-client","version":"1.2.3"}}}');
  Response.Free;
  SendNotification(
    '{"jsonrpc":"2.0","method":"notifications/initialized"}');
  Expect<Boolean>(Dispatch('{"jsonrpc":"2.0","id":3,"method":"tools/call",' +
    '"params":{"name":"labelled","arguments":{}}}', Line)).ToBe(True);
  Expect<Boolean>(Pos('"content" : [{ "type" : "text", "text" : "Found ' +
    #$C3#$BC + 'sers" }, { "type" : "text", "text" : "[{ \"id\" : \"1\", ' +
    '\"name\" : \"Ada\" }]" }], "isError" : false }', Line) > 0).ToBe(True);
end;

procedure TStructuredOutput.TestErrorWithBadStructuredDropsIt;
var
  Response: string;
begin
  Expect<Boolean>(Dispatch(OutputCall('error_bad'), Response)).ToBe(True);
  Expect<Boolean>(Pos('"content" : [{ "type" : "text", "text" : ' +
    '"quota exceeded" }], "isError" : true', Response) > 0).ToBe(True);
  Expect<Boolean>(Pos('structuredContent', Response) = 0).ToBe(True);
end;

procedure TStructuredOutput.TestErrorWithGoodStructuredKeepsIt;
var
  Response: TJSONObject;
begin
  Response := Call(OutputCall('error_good'));
  Expect<string>(TJSONData(Response.FindPath('result.structuredContent[0].id'))
    .AsString).ToBe('1');
  Response.Free;
end;

procedure TStructuredOutput.TestRicherSchemaPublishedUnchanged;
var
  Response: TJSONObject;
  Tools: TJSONArray;
  I: Integer;
  Found: Boolean;
begin
  Found := False;
  Response := Call('{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{' +
    META_MODERN + '}}');
  Tools := TJSONArray(Response.FindPath('result.tools'));
  for I := 0 to Tools.Count - 1 do
    if TJSONObject(Tools[I]).Get('name', '') = 'formatted' then
    begin
      Found := True;
      Expect<string>(TJSONObject(Tools[I]).Find('outputSchema').AsJSON)
        .ToBe('{ "type" : "string", "format" : "uri" }');
    end;
  Expect<Boolean>(Found).ToBe(True);
  Response.Free;
end;

procedure TStructuredOutput.TestNonFiniteOutputRefused;
var
  Response: TJSONObject;
begin
  // Parseable: the bad value never reaches the wire.
  Response := Call(OutputCall('nan_number'));
  Expect<string>(TJSONData(Response.FindPath('result.content[0].text')).AsString)
    .ToBe('Tool "nan_number" produced output that does not match its ' +
    'outputSchema: Structured output must be a number');
  Response.Free;
end;

// The classic text fallback serializes the value; when that raises,
// the call answers -32603 and frees the result (no leak under heaptrc).
procedure TStructuredOutput.TestNonFiniteClassicIsAnError;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"initialize",' +
    '"params":{"protocolVersion":"2025-11-25","capabilities":{},' +
    '"clientInfo":{"name":"legacy-client","version":"1.2.3"}}}');
  Response.Free;
  SendNotification(
    '{"jsonrpc":"2.0","method":"notifications/initialized"}');
  Response := Call('{"jsonrpc":"2.0","id":3,"method":"tools/call",' +
    '"params":{"name":"nan_unchecked","arguments":{}}}');
  Expect<Integer>(TJSONData(Response.FindPath('error.code')).AsInteger)
    .ToBe(-32603);
  Response.Free;
end;

// A raw definition whose enum holds a nil item (null on the wire):
// listing clones every definition, which fpjson cannot do with a nil
// child, so registration stores a JSON null instead.
procedure TStructuredOutput.TestNilSchemaChildListedInBothEras;
var
  Definition, Schema, Prop, Props: TJSONObject;
  Enum: TJSONArray;
  Response: TJSONObject;
begin
  Enum := TJSONArray.Create;
  Enum.Add(TJSONData(nil));
  Prop := TJSONObject.Create;
  Prop.Add('type', 'null');
  Prop.Add('enum', Enum);
  Props := TJSONObject.Create;
  Props.Add('n', Prop);
  Schema := TJSONObject.Create;
  Schema.Add('type', 'object');
  Schema.Add('properties', Props);
  Definition := TJSONObject.Create;
  Definition.Add('name', 'nil_enum');
  Definition.Add('inputSchema', Schema);
  FServer.RegisterTool(Definition, NaNHandler);
  Response := Call('{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{' +
    META_MODERN + '}}');
  Expect<Boolean>(Pos('"enum" : [null]', Response.AsJSON) > 0).ToBe(True);
  Response.Free;
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"initialize",' +
    '"params":{"protocolVersion":"2025-11-25","capabilities":{},' +
    '"clientInfo":{"name":"legacy-client","version":"1.2.3"}}}');
  Response.Free;
  SendNotification(
    '{"jsonrpc":"2.0","method":"notifications/initialized"}');
  Response := Call('{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}');
  Expect<Boolean>(Response.FindPath('result.tools') <> nil).ToBe(True);
  Response.Free;
end;

procedure TStructuredOutput.SetupTests;
begin
  Test('array output is sent, with its JSON as the text block',
    TestArrayOutputSent);
  Test('scalar output is sent', TestScalarOutputSent);
  Test('output that breaks the schema becomes isError, naming the path',
    TestMismatchBecomesIsError);
  Test('missing structuredContent becomes isError',
    TestMissingStructuredContent);
  Test('a handler''s own isError may omit structured output',
    TestHandlerIsErrorNotChecked);
  Test('an output schema outside the subset is not checked',
    TestOutOfSubsetOutputNotChecked);
  Test('classic dialect: no non-object outputSchema or structuredContent',
    TestLegacyDialect);
  Test('classic dialect: custom text kept, output JSON added as text',
    TestLegacyKeepsCustomText);
  Test('isError with non-conforming structured output drops it',
    TestErrorWithBadStructuredDropsIt);
  Test('isError with conforming structured output keeps it',
    TestErrorWithGoodStructuredKeepsIt);
  Test('an out-of-subset output schema is listed unchanged',
    TestRicherSchemaPublishedUnchanged);
  Test('NaN output under a number schema becomes isError',
    TestNonFiniteOutputRefused);
  Test('classic fallback of a NaN value answers -32603',
    TestNonFiniteClassicIsAnError);
  Test('a nil schema child is listed as null in both eras',
    TestNilSchemaChildListedInBothEras);
end;

{ ───────── requestState sealing (#89) ───────── }

// Expected behavior from the MRTR page, verified 2026-11-26:
// https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr
// (requestState is attacker-controlled; integrity MUST be protected and
// state failing verification MUST be rejected).

const
  SEAL_KEY_A = 'k-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  SEAL_KEY_B = 'k-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  // 'é😀': a handler's state with two- and four-byte sequences.
  SEAL_STATE = 'st-' + #$C3#$A9#$F0#$9F#$98#$80;

var
  SealedHandlerRuns: Integer;

// First round: asks for nothing and mints SEAL_STATE; second round:
// echoes the state it was handed back.
function StatefulHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Inc(SealedHandlerRuns);
  if ACtx.RequestState = '' then
    Exit(MCPInputRequired(nil, SEAL_STATE));
  Result := MCPTextResult('got:' + ACtx.RequestState);
end;

function StatefulPrompt(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPPromptResult;
begin
  Inc(SealedHandlerRuns);
  if ACtx.RequestState = '' then
    Exit(MCPPromptInputRequired(nil, SEAL_STATE));
  Result := MCPPromptMessagesResult(MCPMessages([MCPUserMessage(
    'got:' + ACtx.RequestState)]));
end;

function PromptCall(const AArguments, AState: string): string;
begin
  Result := '{"jsonrpc":"2.0","id":3,"method":"prompts/get","params":{' +
    '"name":"stateful_prompt","arguments":' + AArguments + ',';
  if AState <> '' then
    Result := Result + '"requestState":"' + AState + '",';
  Result := Result + META_MODERN + '}}';
end;

function StateEchoReader(const AUri: string;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  Result := MCPTextContents(AUri, 'text/plain', '[' + ACtx.RequestState + ']');
end;

procedure TRequestStateSealing.BeforeEach;
begin
  inherited BeforeEach;
  SealedHandlerRuns := 0;
  FServer.RegisterTool('stateful', 'Stateful', '{"type":"object"}',
    StatefulHandler);
  FServer.RegisterTool('stateful2', 'Stateful too', '{"type":"object"}',
    StatefulHandler);
  FServer.RegisterResource('mem://state', 'state', 'text/plain',
    StateEchoReader);
  FServer.RegisterPrompt('stateful_prompt', 'Stateful prompt',
    StatefulPrompt);
  // Validation seeds "mode" into the arguments the handler sees.
  FServer.RegisterTool('stateful_default', 'Stateful with a default',
    '{"type":"object","properties":{"mode":{"type":"string",' +
    '"default":"fast"}}}', StatefulHandler);
end;

function StatefulCall(const ATool, AArguments, AState: string): string;
begin
  Result := '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{' +
    '"name":"' + ATool + '","arguments":' + AArguments + ',';
  if AState <> '' then
    Result := Result + '"requestState":"' + AState + '",';
  Result := Result + META_MODERN + '}}';
end;

// The token a first round on AServer hands out.
function FirstRoundToken(AServer: TMCPServer; ASession: TMCPSession;
  const ATool, AArguments: string): string;
var
  Line: string;
  Response: TJSONObject;
begin
  AServer.HandleMessage(ASession, StatefulCall(ATool, AArguments, ''), Line);
  Response := TJSONObject(GetJSON(Line));
  try
    Result := TJSONData(Response.FindPath('result.requestState')).AsString;
  finally
    Response.Free;
  end;
end;

function TRequestStateSealing.Token(const ATool, AArguments: string): string;
begin
  if FSession = nil then
    FSession := FServer.CreateSession;
  Result := FirstRoundToken(FServer, FSession, ATool, AArguments);
end;

const
  INVALID_STATE_LINE = '{ "jsonrpc" : "2.0", "id" : 3, "error" : { ' +
    '"code" : -32602, "message" : "Invalid or expired requestState" } }';

// Asserts the retry is refused before the handler runs.
procedure TRequestStateSealing.ExpectRefused(const ALine: string);
var
  Response: string;
  RunsBefore: Integer;
begin
  RunsBefore := SealedHandlerRuns;
  Expect<Boolean>(Dispatch(ALine, Response)).ToBe(True);
  Expect<string>(Response).ToBe(INVALID_STATE_LINE);
  Expect<Integer>(SealedHandlerRuns).ToBe(RunsBefore);
end;

procedure TRequestStateSealing.TestRoundTripNonASCIIState;
var
  State, Line: string;
begin
  State := Token('stateful', '{"q":"' + #$C3#$BC + '"}');
  Expect<Boolean>(Pos('v1.', State) = 1).ToBe(True);
  // The wire line itself carries the state's UTF-8 bytes unchanged.
  Expect<Boolean>(Dispatch(StatefulCall('stateful', '{"q":"' + #$C3#$BC +
    '"}', State), Line)).ToBe(True);
  Expect<Boolean>(Pos('"text" : "got:st-' + #$C3#$A9#$F0#$9F#$98#$80 + '"',
    Line) > 0).ToBe(True);
end;

// The token binds the arguments the client sent, not the ones the
// handler saw after defaults were seeded.
procedure TRequestStateSealing.TestSeededDefaultKeepsTokenValid;
var
  Response: TJSONObject;
begin
  Response := Call(StatefulCall('stateful_default', '{}',
    Token('stateful_default', '{}')));
  Expect<string>(TJSONData(Response.FindPath('result.content[0].text')).AsString)
    .ToBe('got:' + SEAL_STATE);
  Response.Free;
end;

// A supplied empty requestState is no token we issued; it is refused,
// never handed to the handler as a fresh call.
procedure TRequestStateSealing.TestExplicitEmptyStateRejected;
begin
  ExpectRefused('{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{' +
    '"name":"stateful","arguments":{},"requestState":"",' + META_MODERN + '}}');
end;

procedure TRequestStateSealing.TestTamperedTokenRejected;
var
  State: string;
begin
  State := Token('stateful', '{}');
  // Flip one character of the envelope part, then truncate the tag.
  if State[6] = 'A' then State[6] := 'B' else State[6] := 'A';
  ExpectRefused(StatefulCall('stateful', '{}', State));
  State := Token('stateful', '{}');
  ExpectRefused(StatefulCall('stateful', '{}', Copy(State, 1, Length(State) - 1)));
end;

procedure TRequestStateSealing.TestPlainStateRejected;
begin
  ExpectRefused(StatefulCall('stateful', '{}', 'st-plain'));
  ExpectRefused(StatefulCall('stateful', '{}', 'v1.e30.'));
end;

procedure TRequestStateSealing.TestOtherToolRejected;
begin
  ExpectRefused(StatefulCall('stateful2', '{}', Token('stateful', '{}')));
end;

procedure TRequestStateSealing.TestOtherArgumentsRejected;
var
  State: string;
  Response: TJSONObject;
begin
  State := Token('stateful', '{"a":1,"b":[true,null]}');
  ExpectRefused(StatefulCall('stateful', '{"a":2,"b":[true,null]}', State));
  // Member order does not matter: the digest is over canonical JSON.
  Response := Call(StatefulCall('stateful', '{"b":[true,null],"a":1}', State));
  Expect<Boolean>(Response.FindPath('result.content') <> nil).ToBe(True);
  Response.Free;
end;

procedure TRequestStateSealing.TestExpiredRejected;
var
  State: string;
begin
  FServer.RequestStateTtlMs := 1;
  State := Token('stateful', '{}');
  Sleep(20);
  ExpectRefused(StatefulCall('stateful', '{}', State));
end;

// Builds a second server like the suite's, with AName and AKeys.
function PeerServer(const AName: string;
  const AKeys: array of RawByteString): TMCPServer;
begin
  Result := TMCPServer.Create(AName, '9.9.9');
  Result.RegisterTool('stateful', 'Stateful', '{"type":"object"}',
    StatefulHandler);
  if Length(AKeys) > 0 then
    Result.SetRequestStateKeys(AKeys);
end;

// AToken presented to APeer: True when it completes there.
function PeerAccepts(APeer: TMCPServer; const AToken: string): Boolean;
var
  Session: TMCPSession;
  Line: string;
begin
  Session := APeer.CreateSession;
  try
    APeer.HandleMessage(Session, StatefulCall('stateful', '{}', AToken), Line);
    Result := Pos('"error"', Line) = 0;
  finally
    Session.Free;
  end;
end;

procedure TRequestStateSealing.TestSharedKeyAcrossInstances;
var
  Peer: TMCPServer;
begin
  FServer.SetRequestStateKeys([SEAL_KEY_A]);
  Peer := PeerServer('test-server', [SEAL_KEY_A]);
  try
    Expect<Boolean>(PeerAccepts(Peer, Token('stateful', '{}'))).ToBe(True);
  finally
    Peer.Free;
  end;
end;

// Without configured keys each instance has its own random key, even
// two instances of the same name in one process.
procedure TRequestStateSealing.TestDefaultKeysPerInstance;
var
  Minter, Peer: TMCPServer;
  Session: TMCPSession;
  State: string;
begin
  Minter := PeerServer('test-server', []);
  Peer := PeerServer('test-server', []);
  try
    Session := Minter.CreateSession;
    try
      State := FirstRoundToken(Minter, Session, 'stateful', '{}');
    finally
      Session.Free;
    end;
    Expect<Boolean>(PeerAccepts(Minter, State)).ToBe(True);
    Expect<Boolean>(PeerAccepts(Peer, State)).ToBe(False);
  finally
    Peer.Free;
    Minter.Free;
  end;
end;

procedure TRequestStateSealing.TestOtherAudienceRejected;
var
  Peer: TMCPServer;
begin
  FServer.SetRequestStateKeys([SEAL_KEY_A]);
  Peer := PeerServer('another-server', [SEAL_KEY_A]);
  try
    Expect<Boolean>(PeerAccepts(Peer, Token('stateful', '{}'))).ToBe(False);
  finally
    Peer.Free;
  end;
end;

procedure TRequestStateSealing.TestKeyRotation;
var
  Peer: TMCPServer;
  State: string;
begin
  FServer.SetRequestStateKeys([SEAL_KEY_A]);
  State := Token('stateful', '{}');
  // Phase two of a rotation: the new key seals, the old one verifies.
  Peer := PeerServer('test-server', [SEAL_KEY_B, SEAL_KEY_A]);
  try
    Expect<Boolean>(PeerAccepts(Peer, State)).ToBe(True);
  finally
    Peer.Free;
  end;
  // Old key dropped: its tokens stop verifying.
  Peer := PeerServer('test-server', [SEAL_KEY_B]);
  try
    Expect<Boolean>(PeerAccepts(Peer, State)).ToBe(False);
  finally
    Peer.Free;
  end;
end;

// The first key seals: a token minted with [New, Old] verifies on an
// instance that keeps only New.
procedure TRequestStateSealing.TestFirstKeySeals;
var
  Minter, Peer: TMCPServer;
  Session: TMCPSession;
  State: string;
begin
  Minter := PeerServer('test-server', [SEAL_KEY_B, SEAL_KEY_A]);
  Peer := PeerServer('test-server', [SEAL_KEY_B]);
  try
    Session := Minter.CreateSession;
    try
      State := FirstRoundToken(Minter, Session, 'stateful', '{}');
    finally
      Session.Free;
    end;
    Expect<Boolean>(PeerAccepts(Peer, State)).ToBe(True);
  finally
    Peer.Free;
    Minter.Free;
  end;
end;

// A retry that spells an equal number differently still verifies; a
// changed value does not.
procedure TRequestStateSealing.TestNumberSpellingKeepsTokenValid;
var
  State: string;
  Response: TJSONObject;
begin
  State := Token('stateful', '{"n":1}');
  Response := Call(StatefulCall('stateful', '{"n":1.0}', State));
  Expect<string>(TJSONData(Response.FindPath('result.content[0].text')).AsString)
    .ToBe('got:' + SEAL_STATE);
  Response.Free;
  ExpectRefused(StatefulCall('stateful', '{"n":1.5}', Token('stateful',
    '{"n":1}')));
end;

// prompts/get: the restored state reaches the prompt, and a tampered
// token is refused before the prompt runs.
procedure TRequestStateSealing.TestPromptStateRestored;
var
  Line, State: string;
  Response: TJSONObject;
  RunsBefore: Integer;
begin
  Expect<Boolean>(Dispatch(PromptCall('{}', ''), Line)).ToBe(True);
  Response := TJSONObject(GetJSON(Line));
  try
    State := TJSONData(Response.FindPath('result.requestState')).AsString;
  finally
    Response.Free;
  end;
  Expect<Boolean>(Dispatch(PromptCall('{}', State), Line)).ToBe(True);
  Expect<Boolean>(Pos('"text" : "got:st-' + #$C3#$A9#$F0#$9F#$98#$80 + '"',
    Line) > 0).ToBe(True);
  RunsBefore := SealedHandlerRuns;
  if State[6] = 'A' then State[6] := 'B' else State[6] := 'A';
  Expect<Boolean>(Dispatch(PromptCall('{}', State), Line)).ToBe(True);
  Expect<Boolean>(Pos('"code" : -32602', Line) > 0).ToBe(True);
  Expect<Integer>(SealedHandlerRuns).ToBe(RunsBefore);
end;

procedure TRequestStateSealing.TestResourceReadDropsState;
var
  Response: TJSONObject;
begin
  // No resource handler here mints state, so a client-sent value is
  // never handed to one.
  Response := Call('{"jsonrpc":"2.0","id":3,"method":"resources/read",' +
    '"params":{"uri":"mem://state","requestState":"forged",' +
    META_MODERN + '}}');
  Expect<string>(TJSONData(Response.FindPath('result.contents[0].text')).AsString)
    .ToBe('[]');
  Response.Free;
end;

procedure TRequestStateSealing.TestConfigurationGuards;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    FServer.SetRequestStateKeys(['too-short']);
  except
    on E: EMCPServer do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  Raised := False;
  try
    FServer.RequestStateTtlMs := 0;
  except
    on E: EMCPServer do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  FServer.CreateSession.Free;
  Raised := False;
  try
    FServer.SetRequestStateKeys([SEAL_KEY_A]);
  except
    on E: EMCPServer do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TRequestStateSealing.SetupTests;
begin
  Test('sealed round trip keeps a non-ASCII state byte-exact',
    TestRoundTripNonASCIIState);
  Test('altered or truncated token → -32602, handler not run',
    TestTamperedTokenRejected);
  Test('plain or forged state → -32602', TestPlainStateRejected);
  Test('token from another tool → -32602', TestOtherToolRejected);
  Test('token with other arguments → -32602; member order irrelevant',
    TestOtherArgumentsRejected);
  Test('expired token → -32602', TestExpiredRejected);
  Test('shared key verifies across instances; random keys do not',
    TestSharedKeyAcrossInstances);
  Test('token from a server with another name → rejected',
    TestOtherAudienceRejected);
  Test('key rotation: old key verifies until dropped', TestKeyRotation);
  Test('requestState on resources/read never reaches the reader',
    TestResourceReadDropsState);
  Test('short keys, a non-positive TTL and post-freeze keys refused',
    TestConfigurationGuards);
  Test('a seeded default leaves the token valid on an unchanged retry',
    TestSeededDefaultKeepsTokenValid);
  Test('default keys are per instance, even with the same name',
    TestDefaultKeysPerInstance);
  Test('the first key seals: [New, Old] tokens verify on [New]',
    TestFirstKeySeals);
  Test('an equal number respelled keeps the token valid',
    TestNumberSpellingKeepsTokenValid);
  Test('prompts/get: state restored; tampered token refused before the prompt',
    TestPromptStateRestored);
  Test('an explicit empty requestState → -32602, handler not run',
    TestExplicitEmptyStateRejected);
end;

{ ───────── completion (#81) ───────── }

function LanguagePrompt(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  Result := MCPMessages([MCPUserMessage('code_review')]);
end;

function TextReader(const AUri: string; AVars: TJSONObject;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  Result := MCPTextContents(AUri, 'text/plain', 'x');
end;

// Completes a city from the country already chosen in the context.
function CityCompletion(const AArgument, AValue: string; AContext: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPCompletion;
begin
  if (AContext <> nil) and (AContext.Get('country', '') = 'de') then
    Result := MCPCompleteFrom(AValue, ['Berlin', 'Bonn', 'K' + #$C3#$B6 + 'ln'])
  else
    Result := MCPCompleteFrom(AValue, ['Paris', 'Pau']);
end;

// Pre-trimmed to 100 values with the total known: hasMore follows.
function TrimmedCompletion(const AArgument, AValue: string;
  AContext: TJSONObject; const ACtx: TMCPRequestContext): TMCPCompletion;
var
  I: Integer;
begin
  Result := Default(TMCPCompletion);
  SetLength(Result.Values, 100);
  for I := 0 to 99 do
    Result.Values[I] := 'w' + IntToStr(I);
  Result.Total := 150;
end;

function ManyCompletion(const AArgument, AValue: string; AContext: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPCompletion;
var
  I: Integer;
begin
  Result := Default(TMCPCompletion);
  SetLength(Result.Values, 150);
  for I := 0 to 149 do
    Result.Values[I] := 'v' + IntToStr(I);
  Result.Total := -1;
end;

procedure TCompletionDispatch.BeforeEach;
begin
  inherited BeforeEach;
  FServer.RegisterPrompt('code_review', 'Review code',
    PromptArguments.Add('language').Add('style', '', False), LanguagePrompt);
  FServer.RegisterPromptCompletion('code_review', 'language',
    ['Pascal', 'Python', 'PHP', 'Go']);
  FServer.RegisterResourceTemplate('geo://{country}/{city}', 'city',
    'text/plain', TextReader);
  FServer.RegisterTemplateCompletion('geo://{country}/{city}', 'city',
    CityCompletion);
  FServer.RegisterTemplateCompletion('geo://{country}/{city}', 'country',
    ManyCompletion);
  FServer.RegisterResourceTemplate('page://{n}', 'page', 'text/plain',
    TextReader);
  FServer.RegisterTemplateCompletion('page://{n}', 'n', TrimmedCompletion);
end;

function CompleteLine(const ARef, AArgument, AValue: string;
  const AExtra: string = ''): string;
begin
  Result := '{"jsonrpc":"2.0","id":9,"method":"completion/complete",' +
    '"params":{"ref":' + ARef + ',"argument":{"name":"' + AArgument +
    '","value":"' + AValue + '"},' + AExtra + META_MODERN + '}}';
end;

// The JSON at APath of the response to ALine ('' when absent). The
// response is freed here, whatever an assertion does after.
function ResponsePath(ASuite: TDispatchSuite; const ALine,
  APath: string): string;
var
  Response: TJSONObject;
  Data: TJSONData;
begin
  Response := ASuite.Call(ALine);
  try
    Data := Response.FindPath(APath);
    if Data = nil then
      Result := ''
    else
      Result := Data.AsJSON;
  finally
    Response.Free;
  end;
end;

// completion/complete, verified 2026-11-26 against
// https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/completion
// (CompleteRequest, CompleteResult at most 100 values, the completions
// capability).
procedure TCompletionDispatch.TestStaticPromptCompletion;
var
  Response: string;
begin
  Expect<Boolean>(Dispatch(CompleteLine('{"type":"ref/prompt","name":"code_review"}',
    'language', 'p'), Response)).ToBe(True);
  Expect<Boolean>(Pos('"result" : { "completion" : { "values" : ' +
    '["Pascal", "Python", "PHP"], "total" : 3, "hasMore" : false }, ' +
    '"resultType" : "complete"', Response) > 0).ToBe(True);
end;

procedure TCompletionDispatch.TestCallableTemplateCompletion;
var
  Line: string;
begin
  // A non-ASCII prefix in another case still matches, and the
  // suggestion goes out byte-exact.
  Expect<Boolean>(Dispatch(CompleteLine(
    '{"type":"ref/resource","uri":"geo://{country}/{city}"}', 'city',
    'k' + #$C3#$96, '"context":{"arguments":{"country":"de"}},'), Line))
    .ToBe(True);
  Expect<Boolean>(Pos('"values" : ["K' + #$C3#$B6 + 'ln"]', Line) > 0)
    .ToBe(True);
  // An empty context is as good as none.
  Expect<string>(ResponsePath(Self, CompleteLine(
    '{"type":"ref/resource","uri":"geo://{country}/{city}"}', 'city', 'pa',
    '"context":{},'), 'result.completion.values'))
    .ToBe('["Paris", "Pau"]');
  Expect<string>(ResponsePath(Self, CompleteLine(
    '{"type":"ref/resource","uri":"geo://{country}/{city}"}', 'city', 'pa'),
    'result.completion.values')).ToBe('["Paris", "Pau"]');
end;

procedure TCompletionDispatch.TestHundredValueCap;
var
  Line: string;
begin
  Line := CompleteLine(
    '{"type":"ref/resource","uri":"geo://{country}/{city}"}', 'country', '');
  // The first 100, in order, and more exist.
  Expect<string>(ResponsePath(Self, Line, 'result.completion.values[0]'))
    .ToBe('"v0"');
  Expect<string>(ResponsePath(Self, Line, 'result.completion.values[99]'))
    .ToBe('"v99"');
  Expect<string>(ResponsePath(Self, Line, 'result.completion.values[100]'))
    .ToBe('');
  Expect<string>(ResponsePath(Self, Line, 'result.completion.hasMore'))
    .ToBe('true');
  // Total unknown (-1): left out.
  Expect<string>(ResponsePath(Self, Line, 'result.completion.total')).ToBe('');
  // A handler that trimmed to 100 itself, total 150, HasMore unset:
  // more exist, so hasMore is true.
  Line := CompleteLine('{"type":"ref/resource","uri":"page://{n}"}', 'n', '');
  Expect<string>(ResponsePath(Self, Line, 'result.completion.total'))
    .ToBe('150');
  Expect<string>(ResponsePath(Self, Line, 'result.completion.hasMore'))
    .ToBe('true');
end;

procedure TCompletionDispatch.TestUnregisteredArgumentIsEmpty;
begin
  Expect<string>(ResponsePath(Self, CompleteLine(
    '{"type":"ref/prompt","name":"code_review"}', 'style', 'x'),
    'result.completion.values')).ToBe('[]');
end;

function ErrorCode(ASuite: TDispatchSuite; const ALine: string): Integer;
var
  Response: TJSONObject;
begin
  Response := ASuite.Call(ALine);
  try
    Result := TJSONData(Response.FindPath('error.code')).AsInteger;
  finally
    Response.Free;
  end;
end;

procedure TCompletionDispatch.TestErrors;
begin
  Expect<Integer>(ErrorCode(Self, CompleteLine(
    '{"type":"ref/prompt","name":"nope"}', 'language', ''))).ToBe(-32602);
  Expect<Integer>(ErrorCode(Self, CompleteLine(
    '{"type":"ref/prompt","name":"code_review"}', 'nope', ''))).ToBe(-32602);
  Expect<Integer>(ErrorCode(Self, CompleteLine(
    '{"type":"ref/resource","uri":"geo://other"}', 'city', ''))).ToBe(-32602);
  Expect<Integer>(ErrorCode(Self, CompleteLine(
    '{"type":"ref/tool","name":"echo"}', 'x', ''))).ToBe(-32602);
  Expect<Integer>(ErrorCode(Self, '{"jsonrpc":"2.0","id":9,' +
    '"method":"completion/complete","params":{"ref":' +
    '{"type":"ref/prompt","name":"code_review"},' + META_MODERN + '}}'))
    .ToBe(-32602);
  // A name spanning two variables is no variable of the template.
  Expect<Integer>(ErrorCode(Self, CompleteLine(
    '{"type":"ref/resource","uri":"geo://{country}/{city}"}',
    'country}/{city', ''))).ToBe(-32602);
  // Supplied context must be an object whose arguments map strings to
  // strings (CompleteRequestParams.context).
  Expect<Integer>(ErrorCode(Self, CompleteLine(
    '{"type":"ref/prompt","name":"code_review"}', 'language', '',
    '"context":"de",'))).ToBe(-32602);
  Expect<Integer>(ErrorCode(Self, CompleteLine(
    '{"type":"ref/prompt","name":"code_review"}', 'language', '',
    '"context":{"arguments":["de"]},'))).ToBe(-32602);
  Expect<Integer>(ErrorCode(Self, CompleteLine(
    '{"type":"ref/prompt","name":"code_review"}', 'language', '',
    '"context":{"arguments":{"country":1}},'))).ToBe(-32602);
end;

function RegistrationRefused(AServer: TMCPServer; const APrompt,
  AArgument: string): Boolean;
begin
  Result := False;
  try
    AServer.RegisterPromptCompletion(APrompt, AArgument, ['a']);
  except
    on E: EMCPServer do
      Result := True;
  end;
end;

procedure TCompletionDispatch.TestRegistrationGuards;
var
  Raised: Boolean;
begin
  Expect<Boolean>(RegistrationRefused(FServer, 'nope', 'language')).ToBe(True);
  Expect<Boolean>(RegistrationRefused(FServer, 'code_review', 'nope')).ToBe(True);
  // Already registered.
  Expect<Boolean>(RegistrationRefused(FServer, 'code_review', 'language'))
    .ToBe(True);
  Raised := False;
  try
    FServer.RegisterTemplateCompletion('geo://{country}/{city}', 'street', ['a']);
  except
    on E: EMCPServer do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  // A name spanning two variables.
  Raised := False;
  try
    FServer.RegisterTemplateCompletion('geo://{country}/{city}',
      'country}/{city', ['a']);
  except
    on E: EMCPServer do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  // A nil callable is a mistake, not an empty list; the argument stays
  // free for a real registration.
  Raised := False;
  try
    FServer.RegisterPromptCompletion('code_review', 'style',
      TMCPCompletionHandler(nil));
  except
    on E: EMCPServer do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  FServer.RegisterPromptCompletion('code_review', 'style', ['terse']);
end;

// What server/discover declares for AServer.
function DiscoveredCapabilities(AServer: TMCPServer): string;
var
  Session: TMCPSession;
  Line: string;
  Response: TJSONObject;
begin
  Session := AServer.CreateSession;
  try
    AServer.HandleMessage(Session, '{"jsonrpc":"2.0","id":1,' +
      '"method":"server/discover","params":{' + META_MODERN + '}}', Line);
  finally
    Session.Free;
  end;
  Response := TJSONObject(GetJSON(Line));
  try
    Result := Response.FindPath('result.capabilities').AsJSON;
  finally
    Response.Free;
  end;
end;

// The error code AServer answers completion/complete with for its
// code_review prompt, in the modern era or (ALegacy) after initialize.
function CompletionErrorCode(AServer: TMCPServer; ALegacy: Boolean): Integer;
var
  Session: TMCPSession;
  Line: string;
  Response: TJSONObject;
begin
  Session := AServer.CreateSession;
  try
    if ALegacy then
    begin
      AServer.HandleMessage(Session, '{"jsonrpc":"2.0","id":1,' +
        '"method":"initialize","params":{"protocolVersion":"2025-11-25",' +
        '"capabilities":{},"clientInfo":{"name":"c","version":"1"}}}', Line);
      AServer.HandleMessage(Session,
        '{"jsonrpc":"2.0","method":"notifications/initialized"}', Line);
      AServer.HandleMessage(Session, '{"jsonrpc":"2.0","id":2,' +
        '"method":"completion/complete","params":{"ref":{"type":' +
        '"ref/prompt","name":"code_review"},"argument":{"name":' +
        '"language","value":"p"}}}', Line);
    end
    else
      AServer.HandleMessage(Session, CompleteLine(
        '{"type":"ref/prompt","name":"code_review"}', 'language', 'p'), Line);
  finally
    Session.Free;
  end;
  Response := TJSONObject(GetJSON(Line));
  try
    Result := Response.Get('error', TJSONObject(nil)).Get('code', 0);
  finally
    Response.Free;
  end;
end;

// Schema ServerCapabilities ("Present if the server offers ..."),
// verified 2026-11-26 against
// https://modelcontextprotocol.io/specification/2026-07-28/schema#servercapabilities
procedure TCompletionDispatch.TestCapabilities;
var
  Other: TMCPServer;
begin
  Expect<Boolean>(Pos('"completions" : {}',
    DiscoveredCapabilities(FServer)) > 0).ToBe(True);
  // Nothing registered: nothing declared.
  Other := TMCPServer.Create('bare', '1');
  try
    Expect<string>(DiscoveredCapabilities(Other)).ToBe('{}');
  finally
    Other.Free;
  end;
  // A prompt without a completion: prompts, and no completions.
  Other := TMCPServer.Create('prompts-only', '1');
  try
    Other.RegisterPrompt('code_review', 'Review code',
      PromptArguments.Add('language'), LanguagePrompt);
    Expect<string>(DiscoveredCapabilities(Other)).ToBe('{ "prompts" : {} }');
    // ...and does not support the method: -32601 in both eras
    // (completion#error-handling, verified 2026-11-27).
    Expect<Integer>(CompletionErrorCode(Other, False)).ToBe(-32601);
    Expect<Integer>(CompletionErrorCode(Other, True)).ToBe(-32601);
  finally
    Other.Free;
  end;
end;

procedure TCompletionDispatch.TestLegacyEra;
var
  Line: string;
begin
  Expect<Boolean>(ResponsePath(Self, '{"jsonrpc":"2.0","id":1,' +
    '"method":"initialize","params":{"protocolVersion":"2025-11-25",' +
    '"capabilities":{},"clientInfo":{"name":"legacy-client",' +
    '"version":"1.2.3"}}}', 'result.capabilities.completions') <> '')
    .ToBe(True);
  SendNotification(
    '{"jsonrpc":"2.0","method":"notifications/initialized"}');
  Line := '{"jsonrpc":"2.0","id":2,"method":"completion/complete",' +
    '"params":{"ref":{"type":"ref/prompt","name":"code_review"},' +
    '"argument":{"name":"language","value":"g"}}}';
  Expect<string>(ResponsePath(Self, Line, 'result.completion.values'))
    .ToBe('["Go"]');
  // The classic dialect carries no resultType.
  Expect<string>(ResponsePath(Self, Line, 'result.resultType')).ToBe('');
end;

// Unicode simple case folding across the documented blocks (verified
// 2026-11-27 against https://www.unicode.org/Public/16.0.0/ucd/CaseFolding.txt):
// long s, Latin-1 y with diaeresis, a Greek capital with tonos, final
// sigma and Cyrillic ghe with upturn match their pairs; a script outside
// the blocks compares exactly. Values come back byte-exact.
procedure TCompletionDispatch.TestFoldPairs;
var
  Got: TMCPCompletion;
begin
  Got := MCPCompleteFrom('NIKLAU' + #$C5#$BF, ['Niklaus']);
  Expect<Integer>(Length(Got.Values)).ToBe(1);
  Got := MCPCompleteFrom(#$C5#$B8, [#$C3#$BF + 'ber']);
  Expect<Integer>(Length(Got.Values)).ToBe(1);
  Expect<string>(Got.Values[0]).ToBe(#$C3#$BF + 'ber');
  Got := MCPCompleteFrom(#$CE#$86, [#$CE#$AC + #$CE#$B8#$CE#$AE#$CE#$BD#$CE#$B1]);
  Expect<Integer>(Length(Got.Values)).ToBe(1);
  Got := MCPCompleteFrom(#$CF#$82, [#$CE#$A3]);
  Expect<Integer>(Length(Got.Values)).ToBe(1);
  Got := MCPCompleteFrom(#$D2#$90, [#$D2#$91 + #$D0#$B0]);
  Expect<Integer>(Length(Got.Values)).ToBe(1);
  // Armenian is outside the blocks: no fold.
  Got := MCPCompleteFrom(#$D4#$B1, [#$D5#$A1]);
  Expect<Integer>(Length(Got.Values)).ToBe(0);
end;

procedure TCompletionDispatch.SetupTests;
begin
  Test('the case fold covers its documented blocks, and only those',
    TestFoldPairs);
  Test('static prompt completion by case-insensitive prefix',
    TestStaticPromptCompletion);
  Test('callable template completion sees context arguments, UTF-8',
    TestCallableTemplateCompletion);
  Test('more than 100 values: first 100, hasMore', TestHundredValueCap);
  Test('argument without a completion answers an empty list',
    TestUnregisteredArgumentIsEmpty);
  Test('unknown prompt, argument, template or ref type → -32602',
    TestErrors);
  Test('registration refuses unknown targets and duplicates',
    TestRegistrationGuards);
  Test('capabilities follow the registrations', TestCapabilities);
  Test('classic era: capability and completion/complete', TestLegacyEra);
end;

{ ───────── typed tools with nested arguments (#95) ───────── }

function BatchHandler(AArgs: TMCPArgs;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Batch: TBatchArgs;
begin
  Batch := AArgs as TBatchArgs;
  Result := MCPTextResult(Batch.item.label_ + ':' +
    IntToStr(Length(Batch.item.weights)) + ':' + Batch.item.weights[0]);
end;

procedure TTypedNested.BeforeEach;
begin
  inherited BeforeEach;
  FServer.RegisterTool('batch', 'Batch', TBatchArgs, BatchHandler);
end;

procedure TTypedNested.TestNestedArgumentsReachHandler;
var
  Line: string;
begin
  // The handler's text carries the nested array's UTF-8 element; the
  // wire line is asserted as bytes.
  Expect<Boolean>(Dispatch('{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"batch","arguments":{"item":{"label_":"x",' +
    '"weights":["\u00e9","b"]}},' + META_MODERN + '}}', Line)).ToBe(True);
  Expect<Boolean>(Pos('"text" : "x:2:' + #$C3#$A9 + '"', Line) > 0)
    .ToBe(True);
end;

procedure TTypedNested.TestNestedErrorIsInBand;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{' +
    '"name":"batch","arguments":{"item":{"label_":"x","weights":[1]}},' +
    META_MODERN + '}}');
  Expect<Boolean>(TJSONData(Response.FindPath('result.isError')).AsBoolean)
    .ToBe(True);
  Expect<string>(TJSONData(Response.FindPath('result.content[0].text'))
    .AsString).ToBe('Argument "item.weights[0]" must be a string');
  Response.Free;
end;

procedure TTypedNested.SetupTests;
begin
  Test('nested object and array arguments reach a typed handler',
    TestNestedArgumentsReachHandler);
  Test('a nested binding error is an in-band isError naming the path',
    TestNestedErrorIsInBand);
end;

{ ───────── declared client capabilities (#84) ───────── }

var
  NeedyRuns: Integer;

function NeedyHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Inc(NeedyRuns);
  Result := MCPTextResult('ran');
end;

var
  SawSampling: Boolean;

// Records what HasCapability says about sampling.
function SamplingProbeHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  SawSampling := ACtx.HasCapability('sampling');
  Result := MCPTextResult('probed');
end;

// Undeclared: asks for sampling at run time.
function AskerHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Requests: TJSONObject;
begin
  Inc(NeedyRuns);
  Requests := TJSONObject.Create;
  try
    Requests.Add('s', MCPSamplingTextRequest('Say hi', 10));
  except
    Requests.Free;
    raise;
  end;
  Result := MCPInputRequired(Requests);
end;

procedure TDeclaredCapabilities.BeforeEach;
begin
  inherited BeforeEach;
  NeedyRuns := 0;
  FServer.RegisterTool('needy', 'Needs two', '{"type":"object"}', NeedyHandler)
    .RequiresClientCapability('elicitation')
    .RequiresClientCapability('sampling');
  FServer.RegisterTool('asker', 'Asks at run time', '{"type":"object"}',
    AskerHandler);
  FServer.RegisterTool('sampling_probe', 'Reports HasCapability',
    '{"type":"object"}', SamplingProbeHandler);
  FServer.RegisterTool('custom', 'Needs a client capability of its own',
    '{"type":"object"}', NeedyHandler)
    .RequiresClientCapability('com.example/feature');
  FServer.RegisterTool('pr' + #$C3#$BC + 'f' + #$F0#$9F#$98#$80, 'Needs one',
    '{"type":"object"}', NeedyHandler).RequiresClientCapability('sampling');
end;

function ToolCall(const ATool, ACapabilities: string): string;
begin
  Result := '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{' +
    '"name":"' + ATool + '","_meta":{' +
    '"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":' + ACapabilities + '}}}';
end;

function NeedyCall(const ACapabilities: string): string;
begin
  Result := ToolCall('needy', ACapabilities);
end;

// The exact -32021 line for the needy tool lacking ANames ('"a"' or
// '"a", "b"') with AData the requiredCapabilities members.
function NeedyRefusal(const AWord, ANames, AData: string): string;
begin
  Result := '{ "jsonrpc" : "2.0", "id" : 4, "error" : ' +
    '{ "code" : -32021, "message" : "Tool \"needy\" requires the client ' +
    AWord + ' ' + ANames + '", "data" : { "requiredCapabilities" : ' +
    '{ ' + AData + ' } } } }';
end;

procedure TDeclaredCapabilities.TestMissingRefusedBeforeHandler;
var
  Response: string;
begin
  Expect<Boolean>(Dispatch(NeedyCall('{"elicitation":{}}'), Response))
    .ToBe(True);
  Expect<string>(Response).ToBe(NeedyRefusal('capability', '\"sampling\"',
    '"sampling" : {}'));
  // Only the first declared one missing.
  Expect<Boolean>(Dispatch(NeedyCall('{"sampling":{}}'), Response))
    .ToBe(True);
  Expect<string>(Response).ToBe(NeedyRefusal('capability',
    '\"elicitation\"', '"elicitation" : {}'));
  Expect<Integer>(NeedyRuns).ToBe(0);
end;

// Every missing one in one refusal, so the client needs no second try
// to learn the rest (#84 review).
procedure TDeclaredCapabilities.TestEveryMissingCapabilityNamed;
var
  Response: string;
begin
  Expect<Boolean>(Dispatch(NeedyCall('{}'), Response)).ToBe(True);
  Expect<string>(Response).ToBe(NeedyRefusal('capabilities',
    '\"elicitation\", \"sampling\"', '"elicitation" : {}, "sampling" : {}'));
  Expect<Integer>(NeedyRuns).ToBe(0);
end;

// null, false, or an entry whose typed members are not objects declares
// nothing: refused before the handler, and a run-time request for it is
// refused too (#84 review).
procedure TDeclaredCapabilities.TestMalformedDeclarationIsMissing;
var
  Response: string;
begin
  Expect<Boolean>(Dispatch(NeedyCall('{"elicitation":null,"sampling":false}'),
    Response)).ToBe(True);
  Expect<string>(Response).ToBe(NeedyRefusal('capabilities',
    '\"elicitation\", \"sampling\"', '"elicitation" : {}, "sampling" : {}'));
  Expect<Boolean>(Dispatch(NeedyCall(
    '{"elicitation":{},"sampling":{"tools":5}}'), Response)).ToBe(True);
  Expect<string>(Response).ToBe(NeedyRefusal('capability', '\"sampling\"',
    '"sampling" : {}'));
  Expect<Integer>(NeedyRuns).ToBe(0);
  Expect<Boolean>(Dispatch(ToolCall('asker', '{"sampling":null}'), Response))
    .ToBe(True);
  Expect<Boolean>(Pos('"code" : -32021', Response) > 0).ToBe(True);
  Expect<Integer>(NeedyRuns).ToBe(1);
end;

// A capability the schema does not define is the client's own, with any
// value: declared by presence (#84 review).
procedure TDeclaredCapabilities.TestCustomCapabilityByPresence;
var
  Response: string;
begin
  Expect<Boolean>(Dispatch(ToolCall('custom', '{"com.example/feature":true}'),
    Response)).ToBe(True);
  Expect<Boolean>(Pos('"text" : "ran"', Response) > 0).ToBe(True);
  Expect<Integer>(NeedyRuns).ToBe(1);
  Expect<Boolean>(Dispatch(ToolCall('custom', '{}'), Response)).ToBe(True);
  Expect<Boolean>(Pos('"code" : -32021', Response) > 0).ToBe(True);
  Expect<Integer>(NeedyRuns).ToBe(1);
end;

// A classic client's capabilities follow its own revision's schema
// (2025-06-18 has "sampling": {"tools": true}), so the 2026-07-28 shape
// check does not apply: presence counts, as before #84 (review).
procedure TDeclaredCapabilities.TestClassicLookupByPresence;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"initialize",' +
    '"params":{"protocolVersion":"2025-06-18","capabilities":' +
    '{"sampling":{"tools":true}},' +
    '"clientInfo":{"name":"legacy-client","version":"1.2.3"}}}');
  Response.Free;
  SendNotification('{"jsonrpc":"2.0","method":"notifications/initialized"}');
  SawSampling := False;
  Response := Call('{"jsonrpc":"2.0","id":2,"method":"tools/call",' +
    '"params":{"name":"sampling_probe","arguments":{}}}');
  try
    Expect<string>(TJSONData(Response.FindPath('result.content[0].text'))
      .AsString).ToBe('probed');
  finally
    Response.Free;
  end;
  Expect<Boolean>(SawSampling).ToBe(True);
  // The same declaration on a 2026-07-28 request is malformed there.
  SawSampling := True;
  Response := Call(ToolCall('sampling_probe', '{"sampling":{"tools":true}}'));
  Response.Free;
  Expect<Boolean>(SawSampling).ToBe(False);
end;

// The tool name goes out byte-exact: two-byte and astral characters.
procedure TDeclaredCapabilities.TestNonASCIIToolName;
var
  Response: string;
begin
  Expect<Boolean>(Dispatch(ToolCall('pr' + #$C3#$BC + 'f' + #$F0#$9F#$98#$80,
    '{}'), Response)).ToBe(True);
  Expect<string>(Response).ToBe('{ "jsonrpc" : "2.0", "id" : 4, "error" : ' +
    '{ "code" : -32021, "message" : "Tool \"pr' + #$C3#$BC + 'f' +
    #$F0#$9F#$98#$80 + '\" requires the client capability \"sampling\"", ' +
    '"data" : { "requiredCapabilities" : { "sampling" : {} } } } }');
end;

procedure TDeclaredCapabilities.TestPresentRuns;
var
  Response: TJSONObject;
begin
  Response := Call(NeedyCall('{"elicitation":{},"sampling":{}}'));
  try
    Expect<string>(TJSONData(Response.FindPath('result.content[0].text'))
      .AsString).ToBe('ran');
  finally
    Response.Free;
  end;
  Expect<Integer>(NeedyRuns).ToBe(1);
end;

procedure TDeclaredCapabilities.TestLegacyEraNotChecked;
var
  Response: TJSONObject;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"initialize",' +
    '"params":{"protocolVersion":"2025-11-25","capabilities":{},' +
    '"clientInfo":{"name":"legacy-client","version":"1.2.3"}}}');
  Response.Free;
  SendNotification('{"jsonrpc":"2.0","method":"notifications/initialized"}');
  Response := Call('{"jsonrpc":"2.0","id":2,"method":"tools/call",' +
    '"params":{"name":"needy","arguments":{}}}');
  try
    Expect<string>(TJSONData(Response.FindPath('result.content[0].text'))
      .AsString).ToBe('ran');
  finally
    Response.Free;
  end;
end;

procedure TDeclaredCapabilities.TestGuards;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    FServer.RegisterTool('nameless', 'x', '{"type":"object"}', NeedyHandler)
      .RequiresClientCapability('');
  except
    on E: EMCPServer do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  // A second declaration of the same capability is a mistake.
  Raised := False;
  try
    FServer.RegisterTool('twice', 'x', '{"type":"object"}', NeedyHandler)
      .RequiresClientCapability('sampling')
      .RequiresClientCapability('sampling');
  except
    on E: EMCPServer do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TDeclaredCapabilities.SetupTests;
begin
  Test('a missing declared capability → -32021 before the handler runs',
    TestMissingRefusedBeforeHandler);
  Test('every missing declared capability is named in one refusal',
    TestEveryMissingCapabilityNamed);
  Test('a null, false or malformed declaration counts as missing',
    TestMalformedDeclarationIsMissing);
  Test('a non-ASCII tool name goes out byte-exact in the refusal',
    TestNonASCIIToolName);
  Test('a client capability of its own counts when present',
    TestCustomCapabilityByPresence);
  Test('classic clients: HasCapability by presence, as before',
    TestClassicLookupByPresence);
  Test('declared capabilities present → the handler runs', TestPresentRuns);
  Test('classic era: not checked (no MRTR there)', TestLegacyEraNotChecked);
  Test('an empty or repeated capability name is refused', TestGuards);
end;

{ ───────── pagination (#94) ───────── }

procedure TPagination.BeforeEach;
var
  I: Integer;
begin
  inherited BeforeEach;
  // The suite's server already has seven tools; add four more.
  for I := 1 to 4 do
    FServer.RegisterTool('extra' + IntToStr(I), 'Extra', '{"type":"object"}',
      EchoHandler);
  FServer.PageSize := 4;
end;

function ListLine(const AMethod, ACursor: string): string;
begin
  Result := '{"jsonrpc":"2.0","id":3,"method":"' + AMethod + '","params":{';
  if ACursor <> '' then
    Result := Result + '"cursor":"' + ACursor + '",';
  Result := Result + META_MODERN + '}}';
end;

procedure TPagination.TestPagesConcatenateInOrder;
var
  Response: TJSONObject;
  Cursor, Names: string;
  Pages, I: Integer;
  Tools: TJSONArray;
begin
  Cursor := '';
  Names := '';
  Pages := 0;
  repeat
    Response := Call(ListLine('tools/list', Cursor));
    Tools := TJSONArray(Response.FindPath('result.tools'));
    Expect<Boolean>(Tools.Count <= 4).ToBe(True);
    for I := 0 to Tools.Count - 1 do
      Names := Names + TJSONObject(Tools[I]).Get('name', '') + ',';
    // Caching fields on every page.
    Expect<Boolean>(Response.FindPath('result.ttlMs') <> nil).ToBe(True);
    if Response.FindPath('result.nextCursor') <> nil then
      Cursor := TJSONData(Response.FindPath('result.nextCursor')).AsString
    else
      Cursor := '';
    Response.Free;
    Inc(Pages);
  until (Cursor = '') or (Pages > 10);
  Expect<Integer>(Pages).ToBe(3);
  Expect<string>(Names).ToBe('echo,sum,boom,whoami,scale,repeat,noisy,' +
    'extra1,extra2,extra3,extra4,');
end;

function ErrorCodeOfLine(ASuite: TDispatchSuite; const ALine: string): Integer;
var
  Response: TJSONObject;
begin
  Response := ASuite.Call(ALine);
  try
    Result := TJSONData(Response.FindPath('error.code')).AsInteger;
  finally
    Response.Free;
  end;
end;

procedure TPagination.TestInvalidCursors;
var
  Response: TJSONObject;
  ToolsCursor: string;
begin
  Response := Call(ListLine('tools/list', ''));
  ToolsCursor := TJSONData(Response.FindPath('result.nextCursor')).AsString;
  Response.Free;
  Expect<Integer>(ErrorCodeOfLine(Self, ListLine('tools/list', 'not-ours')))
    .ToBe(-32602);
  // A cursor names its list: tools/list's is not prompts/list's.
  Expect<Integer>(ErrorCodeOfLine(Self, ListLine('prompts/list', ToolsCursor)))
    .ToBe(-32602);
  // Past the end ("tools/list:99").
  Expect<Integer>(ErrorCodeOfLine(Self, ListLine('tools/list',
    'dG9vbHMvbGlzdDo5OQ=='))).ToBe(-32602);
  Expect<Integer>(ErrorCodeOfLine(Self, '{"jsonrpc":"2.0","id":3,' +
    '"method":"tools/list","params":{"cursor":7,' + META_MODERN + '}}'))
    .ToBe(-32602);
end;

procedure TPagination.TestNoPagingByDefault;
var
  Bare: TMCPServer;
  Session: TMCPSession;
  Line: string;
begin
  Bare := TMCPServer.Create('bare', '1');
  try
    Bare.RegisterTool('a', 'A', '{"type":"object"}', EchoHandler);
    Bare.RegisterTool('b', 'B', '{"type":"object"}', EchoHandler);
    Session := Bare.CreateSession;
    try
      Bare.HandleMessage(Session, ListLine('tools/list', ''), Line);
      Expect<Boolean>(Pos('nextCursor', Line) = 0).ToBe(True);
      Expect<Boolean>(Pos('"name" : "b"', Line) > 0).ToBe(True);
    finally
      Session.Free;
    end;
  finally
    Bare.Free;
  end;
end;

procedure TPagination.TestOtherListsPage;
var
  Response: TJSONObject;
begin
  // Fewer entries than a page: one page, no cursor.
  Response := Call(ListLine('resources/list', ''));
  Expect<Boolean>(Response.FindPath('result.nextCursor') = nil).ToBe(True);
  Response.Free;
  Response := Call(ListLine('resources/templates/list', ''));
  Expect<Boolean>(Response.FindPath('result.resourceTemplates') <> nil)
    .ToBe(True);
  Response.Free;
end;

procedure TPagination.TestLegacyDialectPages;
var
  Response: TJSONObject;
  Cursor: string;
begin
  Response := Call('{"jsonrpc":"2.0","id":1,"method":"initialize",' +
    '"params":{"protocolVersion":"2025-11-25","capabilities":{},' +
    '"clientInfo":{"name":"legacy-client","version":"1.2.3"}}}');
  Response.Free;
  SendNotification('{"jsonrpc":"2.0","method":"notifications/initialized"}');
  Response := Call('{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}');
  Cursor := TJSONData(Response.FindPath('result.nextCursor')).AsString;
  Expect<Boolean>(Response.FindPath('result.ttlMs') = nil).ToBe(True);
  Response.Free;
  Response := Call('{"jsonrpc":"2.0","id":3,"method":"tools/list",' +
    '"params":{"cursor":"' + Cursor + '"}}');
  Expect<Integer>(TJSONArray(Response.FindPath('result.tools')).Count).ToBe(4);
  Response.Free;
end;

procedure TPagination.SetupTests;
begin
  Test('pages concatenate to the whole list in registration order',
    TestPagesConcatenateInOrder);
  Test('foreign, garbled, past-the-end and non-string cursors → -32602',
    TestInvalidCursors);
  Test('PageSize 0 lists everything with no cursor', TestNoPagingByDefault);
  Test('resources and templates lists page too', TestOtherListsPage);
  Test('classic dialect pages without caching fields',
    TestLegacyDialectPages);
end;

{ ───────── image results ───────── }

const
  // The eight-byte signature every PNG file starts with; base64
  // 'iVBORw0KGgo=' (padded, since 8 bytes is not a multiple of 3).
  PNG_SIGNATURE: array[0..7] of Byte =
    ($89, $50, $4E, $47, $0D, $0A, $1A, $0A);
  // UTF-8 for 'é😀' — a two-byte sequence adjacent to an astral-plane
  // four-byte one. Image payloads are opaque bytes, so the fixture is
  // deliberately one that a codepage conversion would mangle; the
  // expected base64 is written out literally rather than recomputed,
  // so an encode/decode regression cannot cancel itself out (#10, #26).
  ASTRAL_UTF8_BYTES: array[0..5] of Byte =
    ($C3, $A9, $F0, $9F, $98, $80);

function BytesOf(const AValues: array of Byte): TBytes;
var
  I: Integer;
begin
  SetLength(Result, Length(AValues));
  for I := 0 to High(AValues) do
    Result[I] := AValues[I];
end;

function PngImageHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPImageResult(BytesOf(PNG_SIGNATURE), 'image/png');
end;

function AstralImageHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPImageResult(BytesOf(ASTRAL_UTF8_BYTES), 'image/png');
end;

// Already-base64 payload plus a media type carrying a parameter: both
// reach the wire verbatim, the same contract as MCPBlobContents.
function PreEncodedImageHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPImageResult('iVBORw0KGgo=', 'image/svg+xml;charset=utf-8');
end;

function EmptyImageHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  NoBytes: TBytes;
begin
  NoBytes := nil;
  Result := MCPImageResult(NoBytes, 'image/png');
end;

procedure TImageResults.BeforeEach;
begin
  inherited BeforeEach;
  FServer.RegisterTool('png', 'Returns the PNG signature bytes',
    '{"type":"object"}', PngImageHandler);
  FServer.RegisterTool('astral', 'Returns astral-plane UTF-8 bytes',
    '{"type":"object"}', AstralImageHandler);
  FServer.RegisterTool('preencoded', 'Returns already-base64 data',
    '{"type":"object"}', PreEncodedImageHandler);
  FServer.RegisterTool('emptyimage', 'Returns a zero-byte payload',
    '{"type":"object"}', EmptyImageHandler);
end;

function ImageCallLine(const AToolName: string): string;
begin
  Result := '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{' +
    '"name":"' + AToolName + '",' + META_MODERN + '}}';
end;

procedure TImageResults.TestSpecContentBlock;
var
  Response: TJSONObject;
begin
  Response := Call(ImageCallLine('png'));
  // One content block, exactly the spec's ImageContent keys.
  Expect<Integer>(
    TJSONArray(Response.FindPath('result.content')).Count).ToBe(1);
  Expect<Integer>(
    TJSONObject(Response.FindPath('result.content[0]')).Count).ToBe(3);
  Expect<string>(
    TJSONData(Response.FindPath('result.content[0].type')).AsString)
    .ToBe('image');
  Expect<Boolean>(
    TJSONData(Response.FindPath('result.isError')).AsBoolean).ToBe(False);
  Response.Free;
end;

procedure TImageResults.TestBytesEncodedToBase64;
var
  Response: TJSONObject;
begin
  Response := Call(ImageCallLine('png'));
  Expect<string>(
    TJSONData(Response.FindPath('result.content[0].data')).AsString)
    .ToBe('iVBORw0KGgo=');
  Response.Free;
end;

procedure TImageResults.TestNonAsciiBytesSurviveEncoding;
var
  Response: string;
begin
  // Asserted on the encoded wire line, not on a decoded value: the
  // payload is bytes, and base64 of those six bytes is this and
  // nothing else.
  Expect<Boolean>(Dispatch(ImageCallLine('astral'), Response)).ToBe(True);
  Expect<Boolean>(Pos('"data" : "w6nwn5iA"', Response) > 0).ToBe(True);
end;

procedure TImageResults.TestPreEncodedDataPassesThrough;
var
  Response: TJSONObject;
begin
  Response := Call(ImageCallLine('preencoded'));
  Expect<string>(
    TJSONData(Response.FindPath('result.content[0].data')).AsString)
    .ToBe('iVBORw0KGgo=');
  Response.Free;
end;

procedure TImageResults.TestEmptyDataYieldsEmptyString;
var
  Response: TJSONObject;
begin
  // Zero bytes encode to '' — the key stays present (the spec makes
  // data required), it just carries nothing.
  Response := Call(ImageCallLine('emptyimage'));
  Expect<string>(
    TJSONData(Response.FindPath('result.content[0].data')).AsString)
    .ToBe('');
  Response.Free;
end;

procedure TImageResults.TestMimeTypePassthrough;
var
  Response: TJSONObject;
begin
  Response := Call(ImageCallLine('preencoded'));
  Expect<string>(
    TJSONData(Response.FindPath('result.content[0].mimeType')).AsString)
    .ToBe('image/svg+xml;charset=utf-8');
  Response.Free;
end;

procedure TImageResults.TestResponseLineByteExact;
var
  Response: string;
begin
  Expect<Boolean>(Dispatch(ImageCallLine('png'), Response)).ToBe(True);
  Expect<string>(Response).ToBe(
    '{ "jsonrpc" : "2.0", "id" : 1, "result" : { "content" : [{ ' +
    '"type" : "image", "data" : "iVBORw0KGgo=", ' +
    '"mimeType" : "image/png" }], "isError" : false, ' +
    '"resultType" : "complete", "_meta" : { ' +
    '"io.modelcontextprotocol/serverInfo" : { ' +
    '"name" : "test-server", "version" : "9.9.9" } } } }');
end;

procedure TImageResults.SetupTests;
begin
  Test('image result is one spec ImageContent block',
    TestSpecContentBlock);
  Test('raw bytes are base64-encoded into data',
    TestBytesEncodedToBase64);
  Test('non-ASCII payload bytes survive encoding byte-exactly',
    TestNonAsciiBytesSurviveEncoding);
  Test('pre-encoded base64 reaches the wire verbatim',
    TestPreEncodedDataPassesThrough);
  Test('empty payload yields an empty data string',
    TestEmptyDataYieldsEmptyString);
  Test('mimeType reaches the wire verbatim', TestMimeTypePassthrough);
  Test('image tool result line is byte-exact',
    TestResponseLineByteExact);
end;

{ ───────── content results (#87) ─────────
  Content block shapes verified 2026-11-26 against
  https://modelcontextprotocol.io/specification/2026-07-28/server/tools#tool-result
  and .../server/prompts#promptmessage (embedded resources in prompt
  messages MUST carry a mimeType). }

function AudioHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPAudioResult('UklGRg==', 'audio/wav');
end;

function MixedHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPContentResult([
    MCPTextContent('caf' + #$C3#$A9),
    MCPResourceLink('test://r', 'r'),
    MCPEmbeddedText('test://e', 'text/plain', #$F0#$9F#$98#$80)]);
end;

function NilBlockHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPContentResult([MCPTextContent('before'), nil]);
end;

function ContentPromptHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  Result := MCPMessages([
    MCPContentMessage('user', MCPImageContent('iVBORw0KGgo=', 'image/png')),
    MCPContentMessage('assistant', MCPEmbeddedBlob('test://b',
      'application/octet-stream', 'AA=='))]);
end;

procedure TContentResults.BeforeEach;
begin
  inherited BeforeEach;
  FServer.RegisterTool('audio', 'Audio', '{"type":"object"}', AudioHandler);
  FServer.RegisterTool('mixed', 'Mixed', '{"type":"object"}', MixedHandler);
  FServer.RegisterTool('nilblock', 'Nil block', '{"type":"object"}',
    NilBlockHandler);
  FServer.RegisterPrompt('content', 'Content prompt', ContentPromptHandler);
end;

procedure TContentResults.TestAudioResultLine;
var
  Response: string;
begin
  Expect<Boolean>(Dispatch(ImageCallLine('audio'), Response)).ToBe(True);
  Expect<string>(Response).ToBe(
    '{ "jsonrpc" : "2.0", "id" : 1, "result" : { "content" : [{ ' +
    '"type" : "audio", "data" : "UklGRg==", ' +
    '"mimeType" : "audio/wav" }], "isError" : false, ' +
    '"resultType" : "complete", "_meta" : { ' +
    '"io.modelcontextprotocol/serverInfo" : { ' +
    '"name" : "test-server", "version" : "9.9.9" } } } }');
end;

procedure TContentResults.TestMixedContentInOrder;
var
  Response: string;
begin
  Expect<Boolean>(Dispatch(ImageCallLine('mixed'), Response)).ToBe(True);
  Expect<Boolean>(Pos('"content" : [{ "type" : "text", "text" : "caf' +
    #$C3#$A9 + '" }, { "type" : "resource_link", "uri" : "test://r", ' +
    '"name" : "r" }, { "type" : "resource", "resource" : { ' +
    '"uri" : "test://e", "mimeType" : "text/plain", "text" : "' +
    #$F0#$9F#$98#$80 + '" } }], "isError" : false', Response) > 0)
    .ToBe(True);
end;

procedure TContentResults.TestPromptContentMessages;
var
  Response: string;
begin
  Expect<Boolean>(Dispatch('{"jsonrpc":"2.0","id":1,"method":"prompts/get",' +
    '"params":{"name":"content",' + META_MODERN + '}}', Response)).ToBe(True);
  Expect<Boolean>(Pos('"messages" : [{ "role" : "user", "content" : { ' +
    '"type" : "image", "data" : "iVBORw0KGgo=", "mimeType" : "image/png" } }, ' +
    '{ "role" : "assistant", "content" : { "type" : "resource", ' +
    '"resource" : { "uri" : "test://b", "mimeType" : ' +
    '"application/octet-stream", "blob" : "AA==" } } }]', Response) > 0)
    .ToBe(True);
end;

function RaisesServerError(const ABlocks: array of TJSONObject;
  const AExpected: string): Boolean;
begin
  Result := False;
  try
    MCPContentResult(ABlocks);
  except
    on E: EMCPServer do
      Result := Pos(AExpected, E.Message) > 0;
  end;
end;

procedure TContentResults.TestNilBlockRejected;
var
  Response: TJSONObject;
begin
  Expect<Boolean>(RaisesServerError([MCPTextContent('a'), nil],
    'block 1 is nil')).ToBe(True);
  // Through a handler it is an exception like any other: isError.
  Response := Call(ImageCallLine('nilblock'));
  Expect<Boolean>(TJSONData(Response.FindPath('result.isError')).AsBoolean)
    .ToBe(True);
  Response.Free;
end;

procedure TContentResults.TestRepeatedBlockRejected;
var
  Block: TJSONObject;
begin
  // The repeated block is freed once, not twice.
  Block := MCPTextContent('twice');
  Expect<Boolean>(RaisesServerError([Block, MCPTextContent('b'), Block],
    'block 2 repeats block 0')).ToBe(True);
end;

procedure TContentResults.SetupTests;
begin
  Test('audio tool result line is byte-exact', TestAudioResultLine);
  Test('mixed content blocks keep their order and shapes',
    TestMixedContentInOrder);
  Test('prompt messages carry image and embedded-resource blocks',
    TestPromptContentMessages);
  Test('a nil block raises, freeing the others', TestNilBlockRejected);
  Test('a repeated block raises and is freed once',
    TestRepeatedBlockRejected);
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
  TestRunnerProgram.AddSuite(
    TSubsetValidation.Create('Server: subset argument validation'));
  TestRunnerProgram.AddSuite(
    TMRTRDispatch.Create('Server: MRTR input_required'));
  TestRunnerProgram.AddSuite(
    TImageResults.Create('Server: image tool results'));
  TestRunnerProgram.AddSuite(TPagination.Create('Server: pagination'));
  TestRunnerProgram.AddSuite(
    TTypedNested.Create('Server: typed tools with nested arguments'));
  TestRunnerProgram.AddSuite(
    TDeclaredCapabilities.Create('Server: declared client capabilities'));
  TestRunnerProgram.AddSuite(
    TContentResults.Create('Server: content tool results and prompt messages'));
  TestRunnerProgram.AddSuite(
    TCompletionDispatch.Create('Server: completion/complete'));
  TestRunnerProgram.AddSuite(
    TStructuredOutput.Create('Server: structured output'));
  TestRunnerProgram.AddSuite(
    THandlerProtocolErrors.Create('Server: handler-raised protocol errors'));
  TestRunnerProgram.AddSuite(
    TRequestStateSealing.Create('Server: requestState sealing'));
  TestRunnerProgram.Run;
end.
