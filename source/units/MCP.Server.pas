unit MCP.Server;

// Transport-agnostic MCP server core, DUAL-ERA per the 2026-07-28
// spec's compatibility model: requests carrying modern per-request
// _meta are served statelessly (revision 2026-07-28); an `initialize`
// request selects legacy semantics (2025-11-25 and earlier), scoped to
// this server instance (= the stdio process); both eras are served
// concurrently on the same instance, which is what lets current-day
// legacy clients (Claude Code, Claude Desktop) and RC-era clients use
// the same binary. Set DualEra := False for a strict modern-only
// server that rejects initialize with a diagnostic naming its
// supported versions, as the spec recommends.
//
// One instance holds the tool/resource registries and turns one
// decoded JSON-RPC line into at most one response line via
// HandleMessage — the whole protocol surface is testable without a
// transport, mirroring duetto's sans-I/O discipline. Redacted escaped
// exceptions add only the stderr diagnostic described below.
// MCP.Transport.Stdio (and a future MCP.Transport.HTTP) are thin
// byte-moving shells around this.
//
// v1 protocol surface:
//   modern era (per-request _meta):
//     server/discover                  (mandatory in 2026-07-28)
//     tools/list, tools/call
//     resources/list, resources/read
//     prompts/list, prompts/get
//   legacy era (dual-era mode, after initialize + initialized):
//     initialize, ping
//     tools/list, tools/call
//     resources/list, resources/read
//     prompts/list, prompts/get
//     — responses omit the modern-only stamps (resultType, serverInfo
//       _meta, ttlMs/cacheScope) and resource-not-found is the legacy
//       -32002, so each era sees its own wire dialect
//   notifications/initialized          completes the legacy handshake
//   other notifications/*              accepted and ignored; requests
//                                      are handled strictly one at a
//                                      time, so by the time a
//                                      notifications/cancelled arrives
//                                      the request it names has already
//                                      completed. Era selection state
//                                      (legacy lifecycle + negotiated
//                                      version) is the one deliberate
//                                      piece of per-process state the
//                                      compatibility model prescribes.
// Not in v1 (deliberate): subscriptions/listen and the listChanged
// capability flags (registries are fixed after startup, so there is
// nothing to notify), pagination cursors (lists are returned whole),
// MRTR input_required results, and a general JSON-Schema validation
// engine — typed-argument tools (MCP.Schema argument classes) get
// presence and type checking bound from the class; beyond that,
// handlers validate their own inputs and report problems as isError
// tool results, which is what models can act on.
//
// Handlers are synchronous and may be plain functions or methods (both
// overloads are provided). A handler that raises becomes an isError
// tool result carrying the exception message — execution errors belong
// in-band where the model can read them; protocol errors stay JSON-RPC
// errors. RedactErrorDetails preserves that verbose behavior by default;
// when enabled, escaped exceptions carry only a stable generic message
// and correlation reference on the wire, while the full detail is logged
// to stderr under the same reference. Deliberate MCPErrorResult values
// remain verbatim. The stderr/stdout split follows the transport spec
// (verified 2026-07-21):
// https://modelcontextprotocol.io/specification/draft/basic/transports/stdio

{$I Shared.inc}

interface

uses
  SysUtils,
  typinfo,
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}

  fpjson,
  jsonparser,
  jsonscanner,
  MCP.JSONRPC,
  MCP.Protocol,
  MCP.Schema;

type
  TMCPLegacyState = (lsNew, lsAwaitingInitialized, lsReady);

  // Result of one tool invocation. Content is a JSON array of content
  // blocks (owned; use the MCP*Result builders), StructuredContent is
  // the optional machine-readable payload (owned; nil when absent).
  TMCPToolResult = record
    Content: TJSONArray;
    StructuredContent: TJSONData;
    IsError: Boolean;
  end;

  TMCPToolHandler = function(AArguments: TJSONObject;
    const ACtx: TMCPRequestContext): TMCPToolResult;
  TMCPToolMethod = function(AArguments: TJSONObject;
    const ACtx: TMCPRequestContext): TMCPToolResult of object;

  // Typed-argument handlers (MCP.Schema argument classes): the server
  // derives the schema from the class, instantiates and populates it
  // per call, rejects missing/mistyped arguments as in-band isError
  // results before the handler runs, and frees the instance after.
  // Handlers downcast to their concrete class: AArgs as TAddArgs.
  TMCPArgsHandler = function(AArgs: TMCPArgs;
    const ACtx: TMCPRequestContext): TMCPToolResult;
  TMCPArgsMethod = function(AArgs: TMCPArgs;
    const ACtx: TMCPRequestContext): TMCPToolResult of object;

  // Resource readers return the "contents" array of a resources/read
  // result (owned; use MCPTextContents / MCPBlobContents).
  TMCPResourceReader = function(const AUri: string;
    const ACtx: TMCPRequestContext): TJSONArray;
  TMCPResourceMethod = function(const AUri: string;
    const ACtx: TMCPRequestContext): TJSONArray of object;

  TMCPToolRegistration = record
    Definition: TJSONObject; // owned: name/description/inputSchema/...
    Handler: TMCPToolHandler;
    Method: TMCPToolMethod;
    ArgsClass: TMCPArgsClass; // non-nil marks a typed-argument tool
    ArgsHandler: TMCPArgsHandler;
    ArgsMethod: TMCPArgsMethod;
  end;

  TMCPResourceRegistration = record
    Definition: TJSONObject; // owned: uri/name/mimeType/...
    Uri: string;
    StaticText: string;      // used only when HasStaticText is true
    HasStaticText: Boolean;
    Reader: TMCPResourceReader;
    Method: TMCPResourceMethod;
  end;

  // Template readers additionally receive the variables extracted
  // from the URI template match (owned by the server; borrowed by the
  // reader). Matching is the RFC 6570 level-1 simple-variable subset:
  // {var} captures one or more characters excluding '/', variables
  // use names from [A-Za-z0-9_], must be separated by literal text, and
  // captures remain percent-encoded.
  TMCPTemplateReader = function(const AUri: string; AVars: TJSONObject;
    const ACtx: TMCPRequestContext): TJSONArray;
  TMCPTemplateMethod = function(const AUri: string; AVars: TJSONObject;
    const ACtx: TMCPRequestContext): TJSONArray of object;

  TMCPTemplateRegistration = record
    Definition: TJSONObject; // owned: uriTemplate/name/mimeType/...
    UriTemplate: string;
    Reader: TMCPTemplateReader;
    Method: TMCPTemplateMethod;
  end;

  // Prompt handlers return the GetPromptResult "messages" array
  // (owned; use MCPMessages / MCPUserMessage / MCPAssistantMessage).
  // Prompt errors are protocol errors per spec (-32602 for unknown
  // prompts and missing required arguments, -32603 for handler
  // failures) — unlike tools, there is no in-band isError channel.
  TMCPPromptHandler = function(AArguments: TJSONObject;
    const ACtx: TMCPRequestContext): TJSONArray;
  TMCPPromptMethod = function(AArguments: TJSONObject;
    const ACtx: TMCPRequestContext): TJSONArray of object;

  TMCPPromptRegistration = record
    Definition: TJSONObject; // owned: name/description/arguments
    Description: string;     // echoed as GetPromptResult.description
    Handler: TMCPPromptHandler;
    Method: TMCPPromptMethod;
  end;

  // Fluent declaration of a prompt's flat argument list (name /
  // description / required — prompts do not use JSON Schema). Same
  // value semantics as TMCPSchema: registration calls Build through
  // constref so invalidation reaches the caller's record.
  TMCPPromptArguments = record
  private
    FList: TJSONArray;
  public
    function Add(const AName: string; const ADescription: string = '';
      ARequired: Boolean = True): TMCPPromptArguments;
    // Returns an owned array; registration takes ownership.
    function Build: TJSONArray;
  end;

  // Returned by every RegisterTool overload for optional fluent
  // decoration of the just-registered tool — display title and the
  // spec's behavior-hint annotations:
  //
  //   Server.RegisterTool('add', ..., AddHandler)
  //     .Title('Adder').ReadOnlyHint.IdempotentHint;
  //
  // Ignoring the result is fine (extended syntax): a plain statement
  // call registers the tool with no decoration.
  TMCPToolOptions = record
  private
    FDefinition: TJSONObject; // borrowed: owned by the registry
    function Annotations: TJSONObject;
    function SetAnnotation(const AName: string;
      AValue: Boolean): TMCPToolOptions;
  public
    function Title(const ATitle: string): TMCPToolOptions;
    function ReadOnlyHint(AValue: Boolean = True): TMCPToolOptions;
    function DestructiveHint(AValue: Boolean = True): TMCPToolOptions;
    function IdempotentHint(AValue: Boolean = True): TMCPToolOptions;
    function OpenWorldHint(AValue: Boolean = True): TMCPToolOptions;
  end;

  // Where the server writes server-to-client notification lines
  // (notifications/progress, notifications/message). Plain procedure +
  // user data so procedural transports can register without objects.
  TMCPLineSink = procedure(const ALine: string; AUserData: Pointer);

  TMCPServer = class
  private
    FName: string;
    FVersion: string;
    FInstructions: string;
    FCacheTtlMs: Integer;
    FCacheScope: string;
    FRedactErrorDetails: Boolean;
    FDualEra: Boolean;
    FSink: TMCPLineSink;
    FSinkData: Pointer;
    // Legacy initialize MUST be first, and normal operations start only
    // after notifications/initialized (ping remains valid throughout):
    // https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle
    // (verified 2026-07-21).
    FLegacyState: TMCPLegacyState;
    FLegacyProtocolVersion: string;
    FLegacyClientName: string;
    FLegacyClientVersion: string;
    FLegacyClientCapabilities: TJSONObject; // owned clone from initialize
    FTools: array of TMCPToolRegistration;
    FResources: array of TMCPResourceRegistration;
    FTemplates: array of TMCPTemplateRegistration;
    FPrompts: array of TMCPPromptRegistration;

    procedure SetCacheTtlMs(AValue: Integer);
    procedure SetCacheScope(const AValue: string);
    function ExceptionClientMessage(const ASite, AVerbosePrefix,
      ARedactedMessage: string; E: Exception): string;
    function ParseSchema(const ASchemaJson, AToolName: string): TJSONObject;
    function BuildToolDefinition(const AName, ADescription,
      AInputSchemaJson: string): TJSONObject;
    // ADefinition is borrowed; validation frees nothing.
    procedure ValidateToolDefinition(ADefinition: TJSONObject;
      out AToolName: string);
    function AddTool(ADefinition: TJSONObject; AHandler: TMCPToolHandler;
      AMethod: TMCPToolMethod): TMCPToolOptions;
    function AddTypedTool(ADefinition: TJSONObject;
      AArgsClass: TMCPArgsClass; AHandler: TMCPArgsHandler;
      AMethod: TMCPArgsMethod): TMCPToolOptions;
    procedure AddResource(const AUri, AName, AMimeType, ADescription: string;
      AReader: TMCPResourceReader; AMethod: TMCPResourceMethod;
      const AStaticText: string; AHasStaticText: Boolean);
    function FindTool(const AName: string): Integer;
    function FindResource(const AUri: string): Integer;
    function FindPrompt(const AName: string): Integer;
    procedure AddPrompt(const AName, ADescription: string;
      AArguments: TJSONArray; AHandler: TMCPPromptHandler;
      AMethod: TMCPPromptMethod);
    procedure AddTemplate(const AUriTemplate, AName, AMimeType,
      ADescription: string; AReader: TMCPTemplateReader;
      AMethod: TMCPTemplateMethod);
    function ServerCapabilities: TJSONObject;
    function HandleTemplatesList(const AMessage: TJSONRPCMessage;
      ALegacy: Boolean): string;

    function DispatchRequest(const AMessage: TJSONRPCMessage): string;
    function DispatchLegacyRequest(const AMessage: TJSONRPCMessage): string;
    function HandleInitialize(const AMessage: TJSONRPCMessage): string;
    function HandleDiscover(const AMessage: TJSONRPCMessage): string;
    function HandleToolsList(const AMessage: TJSONRPCMessage;
      ALegacy: Boolean): string;
    function HandleToolsCall(const AMessage: TJSONRPCMessage;
      const ACtx: TMCPRequestContext; ALegacy: Boolean): string;
    function HandleResourcesList(const AMessage: TJSONRPCMessage;
      ALegacy: Boolean): string;
    function HandleResourcesRead(const AMessage: TJSONRPCMessage;
      const ACtx: TMCPRequestContext; ALegacy: Boolean): string;
    function HandlePromptsList(const AMessage: TJSONRPCMessage;
      ALegacy: Boolean): string;
    function HandlePromptsGet(const AMessage: TJSONRPCMessage;
      const ACtx: TMCPRequestContext; ALegacy: Boolean): string;
    function ResultResponse(const AMessage: TJSONRPCMessage;
      AResult: TJSONObject; ALegacy: Boolean): string;
    function LegacyContext(AParams: TJSONObject): TMCPRequestContext;
    procedure AddCacheFields(AResult: TJSONObject; ATtlMs: Integer);
    procedure EmitNotification(const AMethod: string; AParams: TJSONObject);
  public
    constructor Create(const AName, AVersion: string);
    destructor Destroy; override;

    // Natural-language guidance surfaced through server/discover.
    property Instructions: string read FInstructions write FInstructions;
    property Name: string read FName;
    property Version: string read FVersion;

    // CacheableResult fields (SEP-2549), required on discover/list/read
    // results. Registries are fixed after startup, so registry metadata
    // is honestly cacheable: default ttl 300000 (5 min, the spec's
    // tools/list example) with "private" scope. Reads served by a
    // dynamic reader always advertise ttl 0 (revalidate) — the library
    // cannot know how fresh a callback's data stays.
    property CacheTtlMs: Integer read FCacheTtlMs write SetCacheTtlMs;
    property CacheScope: string read FCacheScope write SetCacheScope;

    // False by default: escaped handler/dispatch exceptions retain the
    // v1 in-band detail used by trusted local clients. True replaces
    // exception details with a correlation reference and logs the full
    // exception to stderr under that reference (best-effort: on UNIX
    // the first emission upgrades a default SIGPIPE disposition to
    // ignore so a closed stderr cannot kill the process; a host's own
    // SIGPIPE handling is left untouched).
    property RedactErrorDetails: Boolean read FRedactErrorDetails
      write FRedactErrorDetails;

    // Dual-era mode (default True): answer the legacy initialize
    // handshake (2025-11-25 and earlier) alongside stateless
    // 2026-07-28 requests — today's clients (Claude Code, Claude
    // Desktop) still open with initialize. False = strict modern-only:
    // initialize is rejected with a diagnostic naming the supported
    // versions.
    property DualEra: Boolean read FDualEra write FDualEra;

    // The response a transport sends for an inbound line it refused to
    // buffer (length cap). Kept here so the error shape remains a
    // protocol decision — transports move lines only.
    function OversizedLineResponse(AMaxLineLength: Integer): string;

    // Transport registration for server-to-client notification lines.
    // Without a sink, MCPReportProgress/MCPLogMessage are no-ops.
    // HandleMessage otherwise stays line-in/line-out; redacted escaped
    // exceptions additionally write their correlated detail to stderr.
    procedure SetLineSink(ASink: TMCPLineSink; AUserData: Pointer);

    // AInputSchemaJson is parsed at registration and raises EMCPServer
    // on invalid JSON — a bad schema is a programming error, not a
    // runtime condition. The definition-object overloads take
    // ownership of ADefinition for tools that need title/outputSchema/
    // annotations.
    function RegisterTool(const AName, ADescription, AInputSchemaJson: string;
      AHandler: TMCPToolHandler): TMCPToolOptions; overload;
    function RegisterTool(const AName, ADescription, AInputSchemaJson: string;
      AMethod: TMCPToolMethod): TMCPToolOptions; overload;
    function RegisterTool(ADefinition: TJSONObject;
      AHandler: TMCPToolHandler): TMCPToolOptions; overload;
    function RegisterTool(ADefinition: TJSONObject;
      AMethod: TMCPToolMethod): TMCPToolOptions; overload;

    // Fluent-schema overloads (MCP.Schema): the idiomatic registration
    // path for flat object schemas — no JSON strings. The overloads
    // call Build and take ownership of the finished schemas.
    function RegisterTool(const AName, ADescription: string;
      constref AInputSchema: TMCPSchema; AHandler: TMCPToolHandler): TMCPToolOptions; overload;
    function RegisterTool(const AName, ADescription: string;
      constref AInputSchema: TMCPSchema; AMethod: TMCPToolMethod): TMCPToolOptions; overload;
    function RegisterTool(const AName, ADescription: string;
      constref AInputSchema, AOutputSchema: TMCPSchema;
      AHandler: TMCPToolHandler): TMCPToolOptions; overload;
    function RegisterTool(const AName, ADescription: string;
      constref AInputSchema, AOutputSchema: TMCPSchema;
      AMethod: TMCPToolMethod): TMCPToolOptions; overload;

    // Typed-argument overloads: the argument class IS the schema
    // (SchemaFrom) and the handler receives a populated, validated
    // instance. The output schema can be fluent or itself a class
    // (paired with MCPStructuredResult(text, instance) in the
    // handler).
    function RegisterTool(const AName, ADescription: string;
      AArgsClass: TMCPArgsClass; AHandler: TMCPArgsHandler): TMCPToolOptions; overload;
    function RegisterTool(const AName, ADescription: string;
      AArgsClass: TMCPArgsClass; AMethod: TMCPArgsMethod): TMCPToolOptions; overload;
    function RegisterTool(const AName, ADescription: string;
      AArgsClass: TMCPArgsClass; constref AOutputSchema: TMCPSchema;
      AHandler: TMCPArgsHandler): TMCPToolOptions; overload;
    function RegisterTool(const AName, ADescription: string;
      AArgsClass: TMCPArgsClass; constref AOutputSchema: TMCPSchema;
      AMethod: TMCPArgsMethod): TMCPToolOptions; overload;
    function RegisterTool(const AName, ADescription: string;
      AArgsClass, AOutputClass: TMCPArgsClass;
      AHandler: TMCPArgsHandler): TMCPToolOptions; overload;
    function RegisterTool(const AName, ADescription: string;
      AArgsClass, AOutputClass: TMCPArgsClass;
      AMethod: TMCPArgsMethod): TMCPToolOptions; overload;

    procedure RegisterTextResource(const AUri, AName, AMimeType, AText: string;
      const ADescription: string = '');
    procedure RegisterResource(const AUri, AName, AMimeType: string;
      AReader: TMCPResourceReader; const ADescription: string = ''); overload;
    procedure RegisterResource(const AUri, AName, AMimeType: string;
      AMethod: TMCPResourceMethod; const ADescription: string = ''); overload;

    // Resource templates (resources/templates/list + matching in
    // resources/read; exact resources win over templates).
    procedure RegisterResourceTemplate(const AUriTemplate, AName,
      AMimeType: string; AReader: TMCPTemplateReader;
      const ADescription: string = ''); overload;
    procedure RegisterResourceTemplate(const AUriTemplate, AName,
      AMimeType: string; AMethod: TMCPTemplateMethod;
      const ADescription: string = ''); overload;

    // Prompts (prompts/list + prompts/get). Argument-less overloads
    // and overloads with a fluent argument list; registration takes
    // ownership of the built arguments.
    procedure RegisterPrompt(const AName, ADescription: string;
      AHandler: TMCPPromptHandler); overload;
    procedure RegisterPrompt(const AName, ADescription: string;
      AMethod: TMCPPromptMethod); overload;
    procedure RegisterPrompt(const AName, ADescription: string;
      constref AArguments: TMCPPromptArguments;
      AHandler: TMCPPromptHandler); overload;
    procedure RegisterPrompt(const AName, ADescription: string;
      constref AArguments: TMCPPromptArguments;
      AMethod: TMCPPromptMethod); overload;

    // The core entry point: one inbound line in, at most one response
    // line out. Returns True when AResponse must be written (requests
    // and malformed input), False when there is nothing to send
    // (notifications). Never raises.
    function HandleMessage(const ALine: string; out AResponse: string): Boolean;

    function ToolCount: Integer;
    function ResourceCount: Integer;
    function PromptCount: Integer;
  end;

  EMCPServer = class(Exception);

// Content builders for handler implementations.
function MCPTextResult(const AText: string): TMCPToolResult;
function MCPErrorResult(const AText: string): TMCPToolResult;
function MCPStructuredResult(const AText: string;
  AStructured: TJSONData): TMCPToolResult; overload;
// Typed structured output: serializes the instance's published
// properties (MCPSerialize) and frees it.
function MCPStructuredResult(const AText: string;
  AObj: TMCPArgs): TMCPToolResult; overload;
function MCPTextContents(const AUri, AMimeType, AText: string): TJSONArray;
function MCPBlobContents(const AUri, AMimeType, ABase64: string): TJSONArray;

// RFC 6570 level-1 simple-variable template match: {var} captures one
// or more characters excluding '/', delimited by the complete
// following literal with bounded backtracking. Variable names use
// [A-Za-z0-9_]. Captures are raw URI substrings; percent-decoding is
// deliberately not performed. On success AVars carries the captured
// variables (caller frees). Exposed for tests.
// Resource-template semantics verified 2026-07-20:
// https://modelcontextprotocol.io/specification/draft/server/resources
function MatchUriTemplate(const ATemplate, AUri: string;
  out AVars: TJSONObject): Boolean;

// Prompt builders: a fresh argument list to chain onto, and message
// constructors for prompt handlers.
function PromptArguments: TMCPPromptArguments;
function MCPPromptMessage(const ARole, AText: string): TJSONObject;
function MCPUserMessage(const AText: string): TJSONObject;
function MCPAssistantMessage(const AText: string): TJSONObject;
function MCPMessages(const AMessages: array of TJSONObject): TJSONArray;

// In-request notifications, callable from any handler. Both are
// silent no-ops when the precondition is missing, so handlers can
// call them unconditionally:
//   - progress requires the request to carry _meta.progressToken;
//   - log messages require the per-request logLevel opt-in (the spec
//     forbids notifications/message without it) and drop entries less
//     severe than the requested level (RFC 5424 ordering).
procedure MCPReportProgress(const ACtx: TMCPRequestContext;
  AProgress: Double; ATotal: Double = -1; const AMessage: string = '');
procedure MCPLogMessage(const ACtx: TMCPRequestContext;
  const ALevel, AData: string; const ALogger: string = '');

implementation

var
  ErrorSequence: QWord = 0;

function NextErrorReference: string;
begin
  Inc(ErrorSequence);
  Result := 'mcp-err-' + UIntToStr(ErrorSequence);
end;

{$IFDEF UNIX}
var
  SigPipePolicyApplied: Boolean = False;

// Redacted diagnostics write to stderr, and a closed pipe would kill
// the process with SIGPIPE before the RTL can raise EInOutError. On
// first use, upgrade only a DEFAULT disposition to ignore — one-way
// and idempotent, so there is no restore hazard and no race. A host
// that installed its own SIGPIPE handling keeps it; if its handler
// lets the write fail, the failure still lands in the caller's
// except block.
procedure EnsureSigPipeIgnored;
var
  Current, Ignored: SigActionRec;
begin
  if SigPipePolicyApplied then
    Exit;
  SigPipePolicyApplied := True;
  FillChar(Current, SizeOf(Current), 0);
  if FpSigAction(SIGPIPE, nil, @Current) <> 0 then
    Exit;
  // Delphi mode calls a proc-var mentioned in an expression, so the
  // stored handler pointer is read through its address instead.
  if PPointer(@Current.sa_handler)^ <> Pointer(SIG_DFL) then
    Exit;
  FillChar(Ignored, SizeOf(Ignored), 0);
  Ignored.sa_handler := SigActionHandler(SIG_IGN);
  FpSigAction(SIGPIPE, @Ignored, nil);
end;
{$ENDIF}

{ ───────── prompt builders ───────── }

function PromptArguments: TMCPPromptArguments;
begin
  Result.FList := TJSONArray.Create;
end;

function TMCPPromptArguments.Add(const AName: string;
  const ADescription: string; ARequired: Boolean): TMCPPromptArguments;
var
  Arg: TJSONObject;
begin
  if FList = nil then
    raise EMCPServer.Create('Prompt arguments were already built');
  Arg := TJSONObject.Create;
  Arg.Add('name', AName);
  if ADescription <> '' then
    Arg.Add('description', ADescription);
  if ARequired then
    Arg.Add('required', True);
  FList.Add(Arg);
  Result := Self;
end;

function TMCPPromptArguments.Build: TJSONArray;
begin
  if FList = nil then
    raise EMCPServer.Create('Prompt arguments were already built');
  Result := FList;
  FList := nil;
end;

function MCPPromptMessage(const ARole, AText: string): TJSONObject;
var
  Content: TJSONObject;
begin
  Content := TJSONObject.Create;
  Content.Add('type', 'text');
  Content.Add('text', AText);
  Result := TJSONObject.Create;
  Result.Add('role', ARole);
  Result.Add('content', Content);
end;

function MCPUserMessage(const AText: string): TJSONObject;
begin
  Result := MCPPromptMessage('user', AText);
end;

function MCPAssistantMessage(const AText: string): TJSONObject;
begin
  Result := MCPPromptMessage('assistant', AText);
end;

function MCPMessages(const AMessages: array of TJSONObject): TJSONArray;
var
  I: Integer;
begin
  Result := TJSONArray.Create;
  for I := 0 to High(AMessages) do
    Result.Add(AMessages[I]);
end;

{ ───────── URI templates ───────── }

function IsUriTemplateVariableCharacter(ACharacter: Char): Boolean; inline;
begin
  Result := ACharacter in ['A'..'Z', 'a'..'z', '0'..'9', '_'];
end;

function TryValidateUriTemplate(const ATemplate: string;
  out AError: string): Boolean;
var
  CloseBrace, Index, VariableIndex: Integer;
  PreviousWasVariable: Boolean;
begin
  Result := False;
  AError := '';
  if ATemplate = '' then
  begin
    AError := 'Resource template registration requires a non-empty uriTemplate';
    Exit;
  end;
  Index := 1;
  PreviousWasVariable := False;
  while Index <= Length(ATemplate) do
  begin
    if ATemplate[Index] = '}' then
    begin
      AError := Format('Invalid resource template "%s": stray "}" at ' +
        'character %d', [ATemplate, Index]);
      Exit;
    end;
    if ATemplate[Index] <> '{' then
    begin
      PreviousWasVariable := False;
      Inc(Index);
      Continue;
    end;
    if PreviousWasVariable then
    begin
      AError := Format('Invalid resource template "%s": adjacent variables ' +
        'require separating literal text', [ATemplate]);
      Exit;
    end;
    CloseBrace := Index + 1;
    while (CloseBrace <= Length(ATemplate)) and
      (ATemplate[CloseBrace] <> '}') do
      Inc(CloseBrace);
    if CloseBrace > Length(ATemplate) then
    begin
      AError := Format('Invalid resource template "%s": unclosed variable ' +
        'at character %d', [ATemplate, Index]);
      Exit;
    end;
    if CloseBrace = Index + 1 then
    begin
      AError := Format('Invalid resource template "%s": variable name must ' +
        'not be empty', [ATemplate]);
      Exit;
    end;
    for VariableIndex := Index + 1 to CloseBrace - 1 do
      if not IsUriTemplateVariableCharacter(ATemplate[VariableIndex]) then
      begin
        AError := Format('Invalid resource template "%s": variable name ' +
          'must contain only A-Z, a-z, 0-9, and _', [ATemplate]);
        Exit;
      end;
    PreviousWasVariable := True;
    Index := CloseBrace + 1;
  end;
  Result := True;
end;

function MatchUriTemplate(const ATemplate, AUri: string;
  out AVars: TJSONObject): Boolean;
type
  TVariableCapture = record
    Name: string;
    Value: string;
  end;
  TVariableCaptures = array of TVariableCapture;
  TFailedStateRow = array of Boolean;
  TFailedStateRows = array of TFailedStateRow;
var
  Captures: TVariableCaptures;
  FailedStates: TFailedStateRows;
  I: Integer;
  ValidationError: string;

  function IsFailedState(ATemplateIndex, AUriIndex: Integer): Boolean;
  begin
    Result := (Length(FailedStates[ATemplateIndex]) <> 0) and
      FailedStates[ATemplateIndex][AUriIndex];
  end;

  procedure RememberFailedState(ATemplateIndex, AUriIndex: Integer);
  begin
    if Length(FailedStates[ATemplateIndex]) = 0 then
      SetLength(FailedStates[ATemplateIndex], Length(AUri) + 2);
    FailedStates[ATemplateIndex][AUriIndex] := True;
  end;

  procedure RememberFailedVariableStates(ATemplateIndex, AFirstUriIndex,
    ALastUriIndex: Integer);
  var
    UriIndex: Integer;
  begin
    // With repeated-variable equality deliberately out of scope, a failed
    // variable match also proves every later start in this path segment
    // fails: each has a strict subset of the same possible endpoints.
    for UriIndex := AFirstUriIndex to ALastUriIndex do
      RememberFailedState(ATemplateIndex, UriIndex);
  end;

  function MatchFrom(ATemplateIndex, AUriIndex: Integer): Boolean;
  var
    CaptureIndex, CloseBrace, MaxValueEnd, ValueEnd: Integer;
    StartTemplateIndex, StartUriIndex: Integer;
  begin
    StartTemplateIndex := ATemplateIndex;
    StartUriIndex := AUriIndex;
    if IsFailedState(StartTemplateIndex, StartUriIndex) then
      Exit(False);
    while ATemplateIndex <= Length(ATemplate) do
    begin
      if IsFailedState(ATemplateIndex, AUriIndex) then
      begin
        RememberFailedState(StartTemplateIndex, StartUriIndex);
        Exit(False);
      end;
      if ATemplate[ATemplateIndex] = '{' then
      begin
        CloseBrace := ATemplateIndex + 1;
        while ATemplate[CloseBrace] <> '}' do
          Inc(CloseBrace);
        MaxValueEnd := AUriIndex;
        while (MaxValueEnd <= Length(AUri)) and
          (AUri[MaxValueEnd] <> '/') do
          Inc(MaxValueEnd);
        for ValueEnd := AUriIndex + 1 to MaxValueEnd do
        begin
          CaptureIndex := Length(Captures);
          SetLength(Captures, CaptureIndex + 1);
          Captures[CaptureIndex].Name := Copy(ATemplate,
            ATemplateIndex + 1, CloseBrace - ATemplateIndex - 1);
          Captures[CaptureIndex].Value := Copy(AUri, AUriIndex,
            ValueEnd - AUriIndex);
          if MatchFrom(CloseBrace + 1, ValueEnd) then
            Exit(True);
          SetLength(Captures, CaptureIndex);
        end;
        RememberFailedVariableStates(ATemplateIndex, AUriIndex, MaxValueEnd);
        RememberFailedState(StartTemplateIndex, StartUriIndex);
        Exit(False);
      end;
      if (AUriIndex > Length(AUri)) or
        (ATemplate[ATemplateIndex] <> AUri[AUriIndex]) then
      begin
        RememberFailedState(StartTemplateIndex, StartUriIndex);
        Exit(False);
      end;
      Inc(ATemplateIndex);
      Inc(AUriIndex);
    end;
    Result := AUriIndex > Length(AUri);
    if not Result then
      RememberFailedState(StartTemplateIndex, StartUriIndex);
  end;

begin
  AVars := nil;
  if not TryValidateUriTemplate(ATemplate, ValidationError) then
    Exit(False);
  SetLength(Captures, 0);
  SetLength(FailedStates, Length(ATemplate) + 2);
  Result := MatchFrom(1, 1);
  if not Result then
    Exit;
  AVars := TJSONObject.Create;
  for I := 0 to High(Captures) do
    AVars.Add(Captures[I].Name, Captures[I].Value);
end;

{ ───────── in-request notifications ───────── }

// RFC 5424 severity rank; higher is more severe. Request thresholds
// have already been validated by ExtractRequestContext; -1 guards
// against an invalid level emitted by server code.
function LogSeverity(const ALevel: string): Integer;
var
  I: Integer;
begin
  for I := Low(MCP_LOG_LEVELS) to High(MCP_LOG_LEVELS) do
    if MCP_LOG_LEVELS[I] = ALevel then
      Exit(I);
  Result := -1;
end;

procedure MCPReportProgress(const ACtx: TMCPRequestContext;
  AProgress: Double; ATotal: Double; const AMessage: string);
var
  Params: TJSONObject;
begin
  if not (ACtx.HasProgressToken and Assigned(ACtx.Notifier)) then
    Exit;
  Params := TJSONObject.Create;
  if ACtx.ProgressTokenIsString then
    Params.Add('progressToken', ACtx.ProgressToken)
  else
    Params.Add('progressToken', GetJSON(ACtx.ProgressToken));
  Params.Add('progress', AProgress);
  if ATotal >= 0 then
    Params.Add('total', ATotal);
  if AMessage <> '' then
    Params.Add('message', AMessage);
  ACtx.Notifier('notifications/progress', Params);
end;

procedure MCPLogMessage(const ACtx: TMCPRequestContext;
  const ALevel, AData: string; const ALogger: string);
var
  Params: TJSONObject;
begin
  if (ACtx.LogLevel = '') or not Assigned(ACtx.Notifier) then
    Exit;
  if LogSeverity(ALevel) < LogSeverity(ACtx.LogLevel) then
    Exit;
  Params := TJSONObject.Create;
  Params.Add('level', ALevel);
  if ALogger <> '' then
    Params.Add('logger', ALogger);
  Params.Add('data', AData);
  ACtx.Notifier('notifications/message', Params);
end;

{ ───────── content builders ───────── }

function TextContentBlock(const AText: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('type', 'text');
  Result.Add('text', AText);
end;

function MCPTextResult(const AText: string): TMCPToolResult;
begin
  Result := Default(TMCPToolResult);
  Result.Content := TJSONArray.Create;
  Result.Content.Add(TextContentBlock(AText));
end;

function MCPErrorResult(const AText: string): TMCPToolResult;
begin
  Result := MCPTextResult(AText);
  Result.IsError := True;
end;

function MCPStructuredResult(const AText: string;
  AStructured: TJSONData): TMCPToolResult;
begin
  Result := MCPTextResult(AText);
  Result.StructuredContent := AStructured;
end;

function MCPStructuredResult(const AText: string;
  AObj: TMCPArgs): TMCPToolResult;
begin
  try
    Result := MCPStructuredResult(AText, MCPSerialize(AObj));
  finally
    AObj.Free;
  end;
end;

function MCPTextContents(const AUri, AMimeType, AText: string): TJSONArray;
var
  Item: TJSONObject;
begin
  Item := TJSONObject.Create;
  Item.Add('uri', AUri);
  Item.Add('mimeType', AMimeType);
  Item.Add('text', AText);
  Result := TJSONArray.Create;
  Result.Add(Item);
end;

function MCPBlobContents(const AUri, AMimeType, ABase64: string): TJSONArray;
var
  Item: TJSONObject;
begin
  Item := TJSONObject.Create;
  Item.Add('uri', AUri);
  Item.Add('mimeType', AMimeType);
  Item.Add('blob', ABase64);
  Result := TJSONArray.Create;
  Result.Add(Item);
end;

{ ───────── TMCPServer: lifecycle ───────── }

constructor TMCPServer.Create(const AName, AVersion: string);
begin
  inherited Create;
  if AName = '' then
    raise EMCPServer.Create('Server name must not be empty');
  if AVersion = '' then
    raise EMCPServer.Create('Server version must not be empty');
  FName := AName;
  FVersion := AVersion;
  FCacheTtlMs := 300000;
  FCacheScope := CACHE_SCOPE_PRIVATE;
  FRedactErrorDetails := False;
  FDualEra := True;
  FLegacyState := lsNew;
end;

procedure TMCPServer.SetCacheTtlMs(AValue: Integer);
begin
  if AValue < 0 then
    raise EMCPServer.Create('CacheTtlMs must not be negative');
  FCacheTtlMs := AValue;
end;

procedure TMCPServer.SetCacheScope(const AValue: string);
begin
  if (AValue <> CACHE_SCOPE_PRIVATE) and
     (AValue <> CACHE_SCOPE_PUBLIC) then
    raise EMCPServer.CreateFmt(
      'CacheScope must be "%s" or "%s"',
      [CACHE_SCOPE_PRIVATE, CACHE_SCOPE_PUBLIC]);
  FCacheScope := AValue;
end;

function TMCPServer.ExceptionClientMessage(const ASite, AVerbosePrefix,
  ARedactedMessage: string; E: Exception): string;
var
  DiagnosticMessage: string;
  ErrorReference: string;
begin
  if not FRedactErrorDetails then
    Exit(AVerbosePrefix + E.Message);
  ErrorReference := NextErrorReference;
  DiagnosticMessage := StringReplace(E.Message, #13#10, ' ', [rfReplaceAll]);
  DiagnosticMessage := StringReplace(DiagnosticMessage, #13, ' ',
    [rfReplaceAll]);
  DiagnosticMessage := StringReplace(DiagnosticMessage, #10, ' ',
    [rfReplaceAll]);
  {$IFDEF UNIX}
  EnsureSigPipeIgnored;
  {$ENDIF}
  try
    Write(ErrOutput, ErrorReference, ' ', ASite, ': ', E.ClassName, ': ',
      DiagnosticMessage, #10);
    Flush(ErrOutput);
  except
    on EInOutError do
    begin
    end;
  end;
  Result := ARedactedMessage + ' (ref ' + ErrorReference + ')';
end;

destructor TMCPServer.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FTools) do
    FTools[I].Definition.Free;
  for I := 0 to High(FResources) do
    FResources[I].Definition.Free;
  for I := 0 to High(FTemplates) do
    FTemplates[I].Definition.Free;
  for I := 0 to High(FPrompts) do
    FPrompts[I].Definition.Free;
  FLegacyClientCapabilities.Free;
  inherited Destroy;
end;

// The capability objects stay empty: no listChanged / subscribe —
// registries are fixed after startup, so there is nothing to notify.
// Shared by server/discover (modern) and initialize (legacy).
function TMCPServer.ServerCapabilities: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('tools', TJSONObject.Create);
  Result.Add('resources', TJSONObject.Create);
  Result.Add('prompts', TJSONObject.Create);
end;

{ ───────── TMCPServer: registration ───────── }

function TMCPServer.ParseSchema(const ASchemaJson, AToolName: string): TJSONObject;
var
  Parser: TJSONParser;
  Data: TJSONData;
  SchemaType: TJSONData;
begin
  Parser := TJSONParser.Create(ASchemaJson, [joUTF8, joStrict]);
  try
    try
      Data := Parser.Parse;
    except
      on E: Exception do
        raise EMCPServer.CreateFmt(
          'Invalid input schema for tool "%s": %s', [AToolName, E.Message]);
    end;
  finally
    Parser.Free;
  end;
  if (Data = nil) or (Data.JSONType <> jtObject) then
  begin
    Data.Free;
    raise EMCPServer.CreateFmt(
      'Invalid input schema for tool "%s": must be a JSON object', [AToolName]);
  end;
  SchemaType := TJSONObject(Data).Find('type');
  if (SchemaType = nil) or (SchemaType.JSONType <> jtString) or
    (SchemaType.AsString <> 'object') then
  begin
    Data.Free;
    raise EMCPServer.CreateFmt(
      'Invalid input schema for tool "%s": root type must be "object"',
      [AToolName]);
  end;
  Result := TJSONObject(Data);
end;

function TMCPServer.BuildToolDefinition(const AName, ADescription,
  AInputSchemaJson: string): TJSONObject;
var
  InputSchema: TJSONObject; // owned until the definition takes it
begin
  // Parse before assembling the definition so a rejected schema
  // leaves nothing owned.
  InputSchema := ParseSchema(AInputSchemaJson, AName);
  Result := nil;
  try
    Result := TJSONObject.Create;
    Result.Add('name', AName);
    Result.Add('description', ADescription);
    Result.Add('inputSchema', InputSchema);
    InputSchema := nil; // ownership transferred to the definition
  except
    Result.Free;
    InputSchema.Free;
    raise;
  end;
end;

procedure TMCPServer.ValidateToolDefinition(ADefinition: TJSONObject;
  out AToolName: string);
var
  InputSchema, OutputSchema, SchemaType: TJSONData;
begin
  if ADefinition = nil then
    raise EMCPServer.Create('Tool definition must not be nil');
  AToolName := ADefinition.Get('name', '');
  if AToolName = '' then
    raise EMCPServer.Create('Tool definition must carry a non-empty name');
  // Tool.inputSchema is a required JSON Schema object:
  // https://modelcontextprotocol.io/specification/draft/server/tools
  // https://modelcontextprotocol.io/specification/draft/schema
  // (verified 2026-07-21).
  InputSchema := ADefinition.Find('inputSchema');
  if (InputSchema = nil) or (InputSchema.JSONType <> jtObject) then
    raise EMCPServer.CreateFmt(
      'Tool "%s" definition must carry an object-valued inputSchema',
      [AToolName]);
  SchemaType := TJSONObject(InputSchema).Find('type');
  if (SchemaType = nil) or (SchemaType.JSONType <> jtString) or
    (SchemaType.AsString <> 'object') then
    raise EMCPServer.CreateFmt(
      'Tool "%s" inputSchema must have root type "object"', [AToolName]);
  OutputSchema := ADefinition.Find('outputSchema');
  if OutputSchema <> nil then
  begin
    if OutputSchema.JSONType <> jtObject then
      raise EMCPServer.CreateFmt(
        'Tool "%s" definition must carry an object-valued outputSchema',
        [AToolName]);
    SchemaType := TJSONObject(OutputSchema).Find('type');
    if (SchemaType = nil) or (SchemaType.JSONType <> jtString) or
      (SchemaType.AsString <> 'object') then
      raise EMCPServer.CreateFmt(
        'Tool "%s" outputSchema must have root type "object"', [AToolName]);
  end;
  if FindTool(AToolName) >= 0 then
    raise EMCPServer.CreateFmt(
      'Tool "%s" is already registered', [AToolName]);
end;

function TMCPServer.AddTool(ADefinition: TJSONObject;
  AHandler: TMCPToolHandler; AMethod: TMCPToolMethod): TMCPToolOptions;
var
  ToolName: string;
begin
  try
    ValidateToolDefinition(ADefinition, ToolName);
    if Assigned(AHandler) = Assigned(AMethod) then
      raise EMCPServer.CreateFmt(
        'Tool "%s" must have exactly one callable', [ToolName]);
    SetLength(FTools, Length(FTools) + 1);
    FTools[High(FTools)].Definition := ADefinition;
    FTools[High(FTools)].Handler := AHandler;
    FTools[High(FTools)].Method := AMethod;
  except
    ADefinition.Free;
    raise;
  end;
  Result.FDefinition := ADefinition;
end;

{ ───────── fluent tool decoration ───────── }

function TMCPToolOptions.Annotations: TJSONObject;
var
  Data: TJSONData;
begin
  Data := FDefinition.Find('annotations');
  if (Data <> nil) and (Data.JSONType = jtObject) then
    Exit(TJSONObject(Data));
  Result := TJSONObject.Create;
  FDefinition.Add('annotations', Result);
end;

function TMCPToolOptions.SetAnnotation(const AName: string;
  AValue: Boolean): TMCPToolOptions;
var
  Obj: TJSONObject;
  Index: Integer;
begin
  Obj := Annotations;
  Index := Obj.IndexOfName(AName);
  if Index >= 0 then
    Obj.Delete(Index);
  Obj.Add(AName, AValue);
  Result := Self;
end;

function TMCPToolOptions.Title(const ATitle: string): TMCPToolOptions;
var
  Index: Integer;
begin
  Index := FDefinition.IndexOfName('title');
  if Index >= 0 then
    FDefinition.Delete(Index);
  FDefinition.Add('title', ATitle);
  Result := Self;
end;

function TMCPToolOptions.ReadOnlyHint(AValue: Boolean): TMCPToolOptions;
begin
  Result := SetAnnotation('readOnlyHint', AValue);
end;

function TMCPToolOptions.DestructiveHint(AValue: Boolean): TMCPToolOptions;
begin
  Result := SetAnnotation('destructiveHint', AValue);
end;

function TMCPToolOptions.IdempotentHint(AValue: Boolean): TMCPToolOptions;
begin
  Result := SetAnnotation('idempotentHint', AValue);
end;

function TMCPToolOptions.OpenWorldHint(AValue: Boolean): TMCPToolOptions;
begin
  Result := SetAnnotation('openWorldHint', AValue);
end;

function TMCPServer.AddTypedTool(ADefinition: TJSONObject;
  AArgsClass: TMCPArgsClass; AHandler: TMCPArgsHandler;
  AMethod: TMCPArgsMethod): TMCPToolOptions;
var
  ToolName: string;
begin
  try
    ValidateToolDefinition(ADefinition, ToolName);
    if AArgsClass = nil then
      raise EMCPServer.CreateFmt(
        'Typed tool "%s" requires a non-nil argument class', [ToolName]);
    if Assigned(AHandler) = Assigned(AMethod) then
      raise EMCPServer.CreateFmt(
        'Typed tool "%s" must have exactly one callable', [ToolName]);
    SetLength(FTools, Length(FTools) + 1);
    FTools[High(FTools)].Definition := ADefinition;
    FTools[High(FTools)].ArgsClass := AArgsClass;
    FTools[High(FTools)].ArgsHandler := AHandler;
    FTools[High(FTools)].ArgsMethod := AMethod;
  except
    ADefinition.Free;
    raise;
  end;
  Result.FDefinition := ADefinition;
end;

function TMCPServer.RegisterTool(const AName, ADescription,
  AInputSchemaJson: string; AHandler: TMCPToolHandler): TMCPToolOptions;
begin
  Result := AddTool(BuildToolDefinition(AName, ADescription, AInputSchemaJson),
    AHandler, nil);
end;

function TMCPServer.RegisterTool(const AName, ADescription,
  AInputSchemaJson: string; AMethod: TMCPToolMethod): TMCPToolOptions;
begin
  Result := AddTool(BuildToolDefinition(AName, ADescription, AInputSchemaJson),
    nil, AMethod);
end;

function TMCPServer.RegisterTool(ADefinition: TJSONObject;
  AHandler: TMCPToolHandler): TMCPToolOptions;
begin
  Result := AddTool(ADefinition, AHandler, nil);
end;

function TMCPServer.RegisterTool(ADefinition: TJSONObject;
  AMethod: TMCPToolMethod): TMCPToolOptions;
begin
  Result := AddTool(ADefinition, nil, AMethod);
end;

// Shared assembly for the fluent-schema overloads. AOutputSchema may
// be nil (the two-schema overloads pass the built output schema).
function SchemaDefinition(const AName, ADescription: string;
  AInputSchema, AOutputSchema: TJSONObject): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('name', AName);
  Result.Add('description', ADescription);
  Result.Add('inputSchema', AInputSchema);
  if AOutputSchema <> nil then
    Result.Add('outputSchema', AOutputSchema);
end;

// Returns an owned schema tree; the caller transfers or frees it.
function SchemaFromArgumentClass(const AToolName, ARole: string;
  AArgsClass: TMCPArgsClass): TJSONObject;
begin
  if AArgsClass = nil then
    raise EMCPServer.CreateFmt(
      'Typed tool "%s" requires a non-nil %s argument class',
      [AToolName, ARole]);
  Result := SchemaFrom(AArgsClass).Build;
end;

function TMCPServer.RegisterTool(const AName, ADescription: string;
  constref AInputSchema: TMCPSchema; AHandler: TMCPToolHandler): TMCPToolOptions;
begin
  Result := AddTool(SchemaDefinition(AName, ADescription, AInputSchema.Build, nil),
    AHandler, nil);
end;

function TMCPServer.RegisterTool(const AName, ADescription: string;
  constref AInputSchema: TMCPSchema; AMethod: TMCPToolMethod): TMCPToolOptions;
begin
  Result := AddTool(SchemaDefinition(AName, ADescription, AInputSchema.Build, nil),
    nil, AMethod);
end;

function TMCPServer.RegisterTool(const AName, ADescription: string;
  constref AInputSchema, AOutputSchema: TMCPSchema; AHandler: TMCPToolHandler): TMCPToolOptions;
var
  InputSchema, OutputSchema: TJSONObject;
begin
  InputSchema := nil;
  OutputSchema := nil;
  try
    InputSchema := AInputSchema.Build;
    OutputSchema := AOutputSchema.Build;
  except
    InputSchema.Free;
    OutputSchema.Free;
    raise;
  end;
  Result := AddTool(SchemaDefinition(AName, ADescription, InputSchema,
    OutputSchema), AHandler, nil);
end;

function TMCPServer.RegisterTool(const AName, ADescription: string;
  constref AInputSchema, AOutputSchema: TMCPSchema; AMethod: TMCPToolMethod): TMCPToolOptions;
var
  InputSchema, OutputSchema: TJSONObject;
begin
  InputSchema := nil;
  OutputSchema := nil;
  try
    InputSchema := AInputSchema.Build;
    OutputSchema := AOutputSchema.Build;
  except
    InputSchema.Free;
    OutputSchema.Free;
    raise;
  end;
  Result := AddTool(SchemaDefinition(AName, ADescription, InputSchema,
    OutputSchema), nil, AMethod);
end;

function TMCPServer.RegisterTool(const AName, ADescription: string;
  AArgsClass: TMCPArgsClass; AHandler: TMCPArgsHandler): TMCPToolOptions;
begin
  Result := AddTypedTool(SchemaDefinition(AName, ADescription,
    SchemaFromArgumentClass(AName, 'input', AArgsClass), nil),
    AArgsClass, AHandler, nil);
end;

function TMCPServer.RegisterTool(const AName, ADescription: string;
  AArgsClass: TMCPArgsClass; AMethod: TMCPArgsMethod): TMCPToolOptions;
begin
  Result := AddTypedTool(SchemaDefinition(AName, ADescription,
    SchemaFromArgumentClass(AName, 'input', AArgsClass), nil),
    AArgsClass, nil, AMethod);
end;

function TMCPServer.RegisterTool(const AName, ADescription: string;
  AArgsClass: TMCPArgsClass; constref AOutputSchema: TMCPSchema;
  AHandler: TMCPArgsHandler): TMCPToolOptions;
var
  InputSchema, OutputSchema: TJSONObject;
begin
  InputSchema := nil;
  OutputSchema := nil;
  try
    InputSchema := SchemaFromArgumentClass(AName, 'input', AArgsClass);
    OutputSchema := AOutputSchema.Build;
  except
    InputSchema.Free;
    OutputSchema.Free;
    raise;
  end;
  Result := AddTypedTool(SchemaDefinition(AName, ADescription, InputSchema,
    OutputSchema),
    AArgsClass, AHandler, nil);
end;

function TMCPServer.RegisterTool(const AName, ADescription: string;
  AArgsClass: TMCPArgsClass; constref AOutputSchema: TMCPSchema;
  AMethod: TMCPArgsMethod): TMCPToolOptions;
var
  InputSchema, OutputSchema: TJSONObject;
begin
  InputSchema := nil;
  OutputSchema := nil;
  try
    InputSchema := SchemaFromArgumentClass(AName, 'input', AArgsClass);
    OutputSchema := AOutputSchema.Build;
  except
    InputSchema.Free;
    OutputSchema.Free;
    raise;
  end;
  Result := AddTypedTool(SchemaDefinition(AName, ADescription, InputSchema,
    OutputSchema),
    AArgsClass, nil, AMethod);
end;

function TMCPServer.RegisterTool(const AName, ADescription: string;
  AArgsClass, AOutputClass: TMCPArgsClass; AHandler: TMCPArgsHandler): TMCPToolOptions;
var
  InputSchema, OutputSchema: TJSONObject;
begin
  InputSchema := nil;
  OutputSchema := nil;
  try
    InputSchema := SchemaFromArgumentClass(AName, 'input', AArgsClass);
    OutputSchema := SchemaFromArgumentClass(AName, 'output', AOutputClass);
  except
    InputSchema.Free;
    OutputSchema.Free;
    raise;
  end;
  Result := AddTypedTool(SchemaDefinition(AName, ADescription, InputSchema,
    OutputSchema),
    AArgsClass, AHandler, nil);
end;

function TMCPServer.RegisterTool(const AName, ADescription: string;
  AArgsClass, AOutputClass: TMCPArgsClass; AMethod: TMCPArgsMethod): TMCPToolOptions;
var
  InputSchema, OutputSchema: TJSONObject;
begin
  InputSchema := nil;
  OutputSchema := nil;
  try
    InputSchema := SchemaFromArgumentClass(AName, 'input', AArgsClass);
    OutputSchema := SchemaFromArgumentClass(AName, 'output', AOutputClass);
  except
    InputSchema.Free;
    OutputSchema.Free;
    raise;
  end;
  Result := AddTypedTool(SchemaDefinition(AName, ADescription, InputSchema,
    OutputSchema),
    AArgsClass, nil, AMethod);
end;

// Populate one published property from its JSON argument. False (with
// AError set) on a type mismatch.
function BindProperty(AInstance: TMCPArgs; AProp: PPropInfo;
  AValue: TJSONData; out AError: string): Boolean;

  function ReadSignedInteger(out AResult: Int64): Boolean;
  var
    UnsignedValue: QWord;
  begin
    Result := (AValue.JSONType = jtNumber) and
      (TJSONNumber(AValue).NumberType in [ntInteger, ntInt64, ntQWord]);
    if not Result then
      Exit;
    if TJSONNumber(AValue).NumberType = ntQWord then
    begin
      UnsignedValue := AValue.AsQWord;
      if UnsignedValue > QWord(High(Int64)) then
        Exit(False);
      AResult := Int64(UnsignedValue);
    end
    else
      AResult := AValue.AsInt64;
  end;

  function ReadUnsignedInteger(out AResult: QWord): Boolean;
  var
    SignedValue: Int64;
  begin
    Result := (AValue.JSONType = jtNumber) and
      (TJSONNumber(AValue).NumberType in [ntInteger, ntInt64, ntQWord]);
    if not Result then
      Exit;
    if TJSONNumber(AValue).NumberType = ntQWord then
      AResult := AValue.AsQWord
    else
    begin
      SignedValue := AValue.AsInt64;
      if SignedValue < 0 then
        Exit(False);
      AResult := QWord(SignedValue);
    end;
  end;

  function Mismatch(const AExpected: string): Boolean;
  begin
    AError := Format('Argument "%s" must be %s',
      [AProp^.Name, AExpected]);
    Result := False;
  end;

  procedure SetQWordProperty(const AValue: QWord);
  var
    SignedBits: Int64;
  begin
    // FPC 3.2.2 has tkQWord RTTI but exposes only signed Int64 property
    // accessors. Pass the unsigned value's bits through unchanged.
    Move(AValue, SignedBits, SizeOf(SignedBits));
    SetInt64Prop(AInstance, AProp, SignedBits);
  end;

var
  TypeData: PTypeData;
  SignedValue: Int64;
  UnsignedValue, Minimum, Maximum: QWord;
begin
  Result := True;
  case AProp^.PropType^.Kind of
    tkSString, tkLString, tkAString, tkWString, tkUString:
      if AValue.JSONType = jtString then
        SetStrProp(AInstance, AProp, AValue.AsString)
      else
        Exit(Mismatch('a string'));
    tkFloat:
      if AValue.JSONType = jtNumber then
        SetFloatProp(AInstance, AProp, AValue.AsFloat)
      else
        Exit(Mismatch('a number'));
    tkInteger:
      begin
        TypeData := GetTypeData(AProp^.PropType);
        if TypeData^.OrdType in [otUByte, otUWord, otULong] then
        begin
          if not ReadUnsignedInteger(UnsignedValue) then
            Exit(Mismatch('an integer'));
          Minimum := QWord(LongWord(TypeData^.MinValue));
          Maximum := QWord(LongWord(TypeData^.MaxValue));
          if (UnsignedValue < Minimum) or (UnsignedValue > Maximum) then
            Exit(Mismatch('an integer'));
          SetOrdProp(AInstance, AProp, Int64(UnsignedValue));
        end
        else
        begin
          if not ReadSignedInteger(SignedValue) or
            (SignedValue < TypeData^.MinValue) or
            (SignedValue > TypeData^.MaxValue) then
            Exit(Mismatch('an integer'));
          SetOrdProp(AInstance, AProp, SignedValue);
        end;
      end;
    tkInt64:
      if ReadSignedInteger(SignedValue) then
        SetInt64Prop(AInstance, AProp, SignedValue)
      else
        Exit(Mismatch('an integer'));
    tkQWord:
      if ReadUnsignedInteger(UnsignedValue) then
        SetQWordProperty(UnsignedValue)
      else
        Exit(Mismatch('an integer'));
    tkBool:
      if AValue.JSONType = jtBoolean then
        SetOrdProp(AInstance, AProp, Ord(AValue.AsBoolean))
      else
        Exit(Mismatch('a boolean'));
    tkEnumeration:
      if (AValue.JSONType = jtString) and
        (GetEnumValue(AProp^.PropType, AValue.AsString) >= 0) then
        SetEnumProp(AInstance, AProp, AValue.AsString)
      else
        Exit(Mismatch('a string from the declared enum values'));
  else
    // Unmappable kinds cannot get here: SchemaFrom rejected them at
    // registration.
    Exit(Mismatch('a supported type'));
  end;
end;

// Instantiate AClass and fill its published properties from
// AArguments. Every property is required; missing or mistyped
// arguments produce False with AError set (the caller turns that into
// an in-band isError result, which is what a model can act on).
function BindArguments(AClass: TMCPArgsClass; AArguments: TJSONObject;
  out AInstance: TMCPArgs; out AError: string): Boolean;
var
  Info: PTypeInfo;
  Props: PPropList;
  Count, I: Integer;
  Value: TJSONData;
begin
  Result := False;
  AError := '';
  AInstance := AClass.Create;
  Info := PTypeInfo(AClass.ClassInfo);
  Count := GetTypeData(Info)^.PropCount;
  if Count = 0 then
    Exit(True);
  GetMem(Props, Count * SizeOf(Pointer));
  try
    GetPropInfos(Info, Props);
    for I := 0 to Count - 1 do
    begin
      Value := AArguments.Find(Props^[I]^.Name);
      if Value = nil then
      begin
        // The `default` directive is streaming metadata, not field
        // initialization — seed it explicitly. `stored False`
        // properties simply stay zero-initialized.
        if MCPPropHasDefault(Props^[I]) then
          SetOrdProp(AInstance, Props^[I], Props^[I]^.Default)
        else if IsStoredProp(AInstance, Props^[I]) then
        begin
          AError := Format('Missing required argument "%s"',
            [Props^[I]^.Name]);
          Exit(False);
        end;
        Continue;
      end;
      if not BindProperty(AInstance, Props^[I], Value, AError) then
        Exit(False);
    end;
    Result := True;
  finally
    FreeMem(Props);
    if not Result then
      FreeAndNil(AInstance);
  end;
end;

procedure TMCPServer.AddResource(const AUri, AName, AMimeType,
  ADescription: string; AReader: TMCPResourceReader;
  AMethod: TMCPResourceMethod; const AStaticText: string;
  AHasStaticText: Boolean);
var
  Definition: TJSONObject;
begin
  if AUri = '' then
    raise EMCPServer.Create('Resource registration requires a non-empty uri');
  if AName = '' then
    raise EMCPServer.CreateFmt(
      'Resource "%s" requires a non-empty display name', [AUri]);
  if AHasStaticText then
  begin
    if Assigned(AReader) or Assigned(AMethod) then
      raise EMCPServer.CreateFmt(
        'Static resource "%s" must not have a callable', [AUri]);
  end
  else if Assigned(AReader) = Assigned(AMethod) then
    raise EMCPServer.CreateFmt(
      'Dynamic resource "%s" must have exactly one callable', [AUri]);
  if FindResource(AUri) >= 0 then
    raise EMCPServer.CreateFmt('Resource "%s" is already registered', [AUri]);
  Definition := TJSONObject.Create;
  Definition.Add('uri', AUri);
  Definition.Add('name', AName);
  if AMimeType <> '' then
    Definition.Add('mimeType', AMimeType);
  if ADescription <> '' then
    Definition.Add('description', ADescription);
  SetLength(FResources, Length(FResources) + 1);
  FResources[High(FResources)].Definition := Definition;
  FResources[High(FResources)].Uri := AUri;
  FResources[High(FResources)].StaticText := AStaticText;
  FResources[High(FResources)].HasStaticText := AHasStaticText;
  FResources[High(FResources)].Reader := AReader;
  FResources[High(FResources)].Method := AMethod;
end;

procedure TMCPServer.RegisterTextResource(const AUri, AName, AMimeType,
  AText: string; const ADescription: string);
begin
  AddResource(AUri, AName, AMimeType, ADescription, nil, nil, AText, True);
end;

procedure TMCPServer.RegisterResource(const AUri, AName, AMimeType: string;
  AReader: TMCPResourceReader; const ADescription: string);
begin
  AddResource(AUri, AName, AMimeType, ADescription, AReader, nil, '', False);
end;

procedure TMCPServer.RegisterResource(const AUri, AName, AMimeType: string;
  AMethod: TMCPResourceMethod; const ADescription: string);
begin
  AddResource(AUri, AName, AMimeType, ADescription, nil, AMethod, '', False);
end;

function TMCPServer.FindTool(const AName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FTools) do
    if FTools[I].Definition.Get('name', '') = AName then
      Exit(I);
  Result := -1;
end;

function TMCPServer.FindResource(const AUri: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FResources) do
    if FResources[I].Uri = AUri then
      Exit(I);
  Result := -1;
end;

procedure TMCPServer.AddTemplate(const AUriTemplate, AName, AMimeType,
  ADescription: string; AReader: TMCPTemplateReader;
  AMethod: TMCPTemplateMethod);
var
  I: Integer;
  Definition: TJSONObject;
  ValidationError: string;
begin
  if AName = '' then
    raise EMCPServer.CreateFmt(
      'Resource template "%s" requires a non-empty display name',
      [AUriTemplate]);
  if Assigned(AReader) = Assigned(AMethod) then
    raise EMCPServer.CreateFmt(
      'Resource template "%s" must have exactly one callable',
      [AUriTemplate]);
  if not TryValidateUriTemplate(AUriTemplate, ValidationError) then
    raise EMCPServer.Create(ValidationError);
  for I := 0 to High(FTemplates) do
    if FTemplates[I].UriTemplate = AUriTemplate then
      raise EMCPServer.CreateFmt(
        'Resource template "%s" is already registered', [AUriTemplate]);
  Definition := TJSONObject.Create;
  Definition.Add('uriTemplate', AUriTemplate);
  Definition.Add('name', AName);
  if AMimeType <> '' then
    Definition.Add('mimeType', AMimeType);
  if ADescription <> '' then
    Definition.Add('description', ADescription);
  SetLength(FTemplates, Length(FTemplates) + 1);
  FTemplates[High(FTemplates)].Definition := Definition;
  FTemplates[High(FTemplates)].UriTemplate := AUriTemplate;
  FTemplates[High(FTemplates)].Reader := AReader;
  FTemplates[High(FTemplates)].Method := AMethod;
end;

procedure TMCPServer.RegisterResourceTemplate(const AUriTemplate, AName,
  AMimeType: string; AReader: TMCPTemplateReader;
  const ADescription: string);
begin
  AddTemplate(AUriTemplate, AName, AMimeType, ADescription, AReader, nil);
end;

procedure TMCPServer.RegisterResourceTemplate(const AUriTemplate, AName,
  AMimeType: string; AMethod: TMCPTemplateMethod;
  const ADescription: string);
begin
  AddTemplate(AUriTemplate, AName, AMimeType, ADescription, nil, AMethod);
end;

function TMCPServer.FindPrompt(const AName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FPrompts) do
    if FPrompts[I].Definition.Get('name', '') = AName then
      Exit(I);
  Result := -1;
end;

procedure TMCPServer.AddPrompt(const AName, ADescription: string;
  AArguments: TJSONArray; AHandler: TMCPPromptHandler;
  AMethod: TMCPPromptMethod);
var
  Definition: TJSONObject;
begin
  if AName = '' then
  begin
    AArguments.Free;
    raise EMCPServer.Create('Prompt registration requires a non-empty name');
  end;
  if Assigned(AHandler) = Assigned(AMethod) then
  begin
    AArguments.Free;
    raise EMCPServer.CreateFmt(
      'Prompt "%s" must have exactly one callable', [AName]);
  end;
  if FindPrompt(AName) >= 0 then
  begin
    AArguments.Free;
    raise EMCPServer.CreateFmt('Prompt "%s" is already registered', [AName]);
  end;
  Definition := TJSONObject.Create;
  Definition.Add('name', AName);
  if ADescription <> '' then
    Definition.Add('description', ADescription);
  if AArguments <> nil then
    Definition.Add('arguments', AArguments);
  SetLength(FPrompts, Length(FPrompts) + 1);
  FPrompts[High(FPrompts)].Definition := Definition;
  FPrompts[High(FPrompts)].Description := ADescription;
  FPrompts[High(FPrompts)].Handler := AHandler;
  FPrompts[High(FPrompts)].Method := AMethod;
end;

procedure TMCPServer.RegisterPrompt(const AName, ADescription: string;
  AHandler: TMCPPromptHandler);
begin
  AddPrompt(AName, ADescription, nil, AHandler, nil);
end;

procedure TMCPServer.RegisterPrompt(const AName, ADescription: string;
  AMethod: TMCPPromptMethod);
begin
  AddPrompt(AName, ADescription, nil, nil, AMethod);
end;

procedure TMCPServer.RegisterPrompt(const AName, ADescription: string;
  constref AArguments: TMCPPromptArguments; AHandler: TMCPPromptHandler);
begin
  AddPrompt(AName, ADescription, AArguments.Build, AHandler, nil);
end;

procedure TMCPServer.RegisterPrompt(const AName, ADescription: string;
  constref AArguments: TMCPPromptArguments; AMethod: TMCPPromptMethod);
begin
  AddPrompt(AName, ADescription, AArguments.Build, nil, AMethod);
end;

function TMCPServer.ToolCount: Integer;
begin
  Result := Length(FTools);
end;

function TMCPServer.ResourceCount: Integer;
begin
  Result := Length(FResources);
end;

function TMCPServer.PromptCount: Integer;
begin
  Result := Length(FPrompts);
end;

{ ───────── TMCPServer: dispatch ───────── }

function TMCPServer.ResultResponse(const AMessage: TJSONRPCMessage;
  AResult: TJSONObject; ALegacy: Boolean): string;
begin
  // The modern stamps (resultType, serverInfo _meta) belong to the
  // 2026-07-28 dialect only; legacy responses stay byte-faithful to
  // their negotiated revision.
  if not ALegacy then
    StampResult(AResult, FName, FVersion);
  Result := BuildResultResponse(AMessage.Id, AResult);
end;

function TMCPServer.HandleMessage(const ALine: string;
  out AResponse: string): Boolean;
var
  Msg: TJSONRPCMessage;
begin
  AResponse := '';
  Result := False;
  Msg := ParseJSONRPCMessage(ALine);
  try
    case Msg.Kind of
      jrkInvalid:
        begin
          AResponse := BuildErrorResponse(Msg.Id, Msg.ErrorCode,
            Msg.ErrorMessage);
          Result := True;
        end;
      jrkNotification:
        begin
          if (Msg.Method = 'notifications/initialized') and
             (FLegacyState = lsAwaitingInitialized) then
            FLegacyState := lsReady;
          // Other notifications (including notifications/cancelled) are
          // deliberately ignored: requests are processed one at a time,
          // so a cancellation can only arrive after its target finished.
          Result := False;
        end;
      jrkRequest:
        begin
          try
            AResponse := DispatchRequest(Msg);
          except
            on E: Exception do
              AResponse := BuildErrorResponse(Msg.Id,
                JSONRPC_INTERNAL_ERROR,
                ExceptionClientMessage('dispatch/' + Msg.Method,
                  'Internal error: ', 'Internal error', E));
          end;
          Result := True;
        end;
    end;
  finally
    FreeJSONRPCMessage(Msg);
  end;
end;

// The dual-era server "selects its behavior from how the client
// opens" (spec compatibility matrix): the presence of the required
// modern _meta key marks a modern request; an initialize request
// selects legacy semantics. A legacy _meta like progressToken does
// NOT mark a request modern — only the protocolVersion key does.
function IsModernRequest(AParams: TJSONObject): Boolean;
var
  MetaData: TJSONData;
begin
  if AParams = nil then
    Exit(False);
  MetaData := AParams.Find('_meta');
  Result := (MetaData <> nil) and (MetaData.JSONType = jtObject) and
    (TJSONObject(MetaData).Find(META_KEY_PROTOCOL_VERSION) <> nil);
end;

function TMCPServer.DispatchRequest(const AMessage: TJSONRPCMessage): string;
var
  Ctx: TMCPRequestContext;
  MetaErr: TMCPMetaError;
begin
  if AMessage.Method = 'initialize' then
  begin
    if FDualEra then
      Exit(HandleInitialize(AMessage));
    // Modern-only servers SHOULD name their supported versions in the
    // reply — it is the only diagnostic a legacy client can surface.
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_METHOD_NOT_FOUND,
      'The initialize handshake is not supported; this server implements ' +
      'stateless MCP. Supported protocol versions: ' + MCP_PROTOCOL_VERSION,
      BuildUnsupportedVersionData([MCP_PROTOCOL_VERSION], 'initialize')));
  end;

  if FDualEra and not IsModernRequest(AMessage.Params) then
    Exit(DispatchLegacyRequest(AMessage));

  if not ExtractRequestContext(AMessage.Params, [MCP_PROTOCOL_VERSION],
    Ctx, MetaErr) then
    Exit(BuildErrorResponse(AMessage.Id, MetaErr.Code, MetaErr.Message,
      MetaErr.Data));
  Ctx.Notifier := EmitNotification;

  if AMessage.Method = 'server/discover' then
    Exit(HandleDiscover(AMessage));
  if AMessage.Method = 'tools/list' then
    Exit(HandleToolsList(AMessage, False));
  if AMessage.Method = 'tools/call' then
    Exit(HandleToolsCall(AMessage, Ctx, False));
  if AMessage.Method = 'resources/list' then
    Exit(HandleResourcesList(AMessage, False));
  if AMessage.Method = 'resources/read' then
    Exit(HandleResourcesRead(AMessage, Ctx, False));
  if AMessage.Method = 'resources/templates/list' then
    Exit(HandleTemplatesList(AMessage, False));
  if AMessage.Method = 'prompts/list' then
    Exit(HandlePromptsList(AMessage, False));
  if AMessage.Method = 'prompts/get' then
    Exit(HandlePromptsGet(AMessage, Ctx, False));

  Result := BuildErrorResponse(AMessage.Id, JSONRPC_METHOD_NOT_FOUND,
    'Method not found: ' + AMessage.Method);
end;

function TMCPServer.DispatchLegacyRequest(
  const AMessage: TJSONRPCMessage): string;
begin
  // ping is a legacy utility a client may send at any time, including
  // before initialize (the modern revision removed it — a modern
  // client never sends it).
  if AMessage.Method = 'ping' then
    Exit(BuildResultResponse(AMessage.Id, TJSONObject.Create));

  if FLegacyState = lsNew then
    // Legacy lifecycle: non-ping requests are invalid before the
    // handshake completes. The hint about _meta helps a misbehaving
    // modern client that dropped its required envelope.
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_REQUEST,
      'Received request before initialization: send initialize first ' +
      '(legacy clients), or carry the required per-request _meta ' +
      '(protocol 2026-07-28)'));

  if FLegacyState = lsAwaitingInitialized then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_REQUEST,
      'Received request before initialization is complete: send ' +
      'notifications/initialized first'));

  if AMessage.Method = 'tools/list' then
    Exit(HandleToolsList(AMessage, True));
  if AMessage.Method = 'tools/call' then
    Exit(HandleToolsCall(AMessage, LegacyContext(AMessage.Params), True));
  if AMessage.Method = 'resources/list' then
    Exit(HandleResourcesList(AMessage, True));
  if AMessage.Method = 'resources/read' then
    Exit(HandleResourcesRead(AMessage, LegacyContext(AMessage.Params), True));
  if AMessage.Method = 'resources/templates/list' then
    Exit(HandleTemplatesList(AMessage, True));
  if AMessage.Method = 'prompts/list' then
    Exit(HandlePromptsList(AMessage, True));
  if AMessage.Method = 'prompts/get' then
    Exit(HandlePromptsGet(AMessage, LegacyContext(AMessage.Params), True));

  Result := BuildErrorResponse(AMessage.Id, JSONRPC_METHOD_NOT_FOUND,
    'Method not found: ' + AMessage.Method);
end;

function TMCPServer.HandleInitialize(const AMessage: TJSONRPCMessage): string;
var
  VersionData, InfoData, CapsData, NameData, ClientVersionData: TJSONData;
  Requested, NegotiatedVersion, ClientName, ClientVersion: string;
  InitResult, Capabilities, ServerInfo, ClientCapabilities,
    ResponsePayload: TJSONObject;
begin
  if FLegacyState <> lsNew then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_REQUEST,
      'Server is already initialized: initialize may only be sent once'));

  if AMessage.Params = nil then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS,
      'Invalid params: initialize requires protocolVersion'));
  VersionData := AMessage.Params.Find('protocolVersion');
  if (VersionData = nil) or (VersionData.JSONType <> jtString) then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS,
      'Invalid params: protocolVersion must be a string'));
  Requested := VersionData.AsString;

  // InitializeRequest params require object-valued capabilities and
  // clientInfo with string name and version members:
  // https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle
  // (verified 2026-07-20).
  CapsData := AMessage.Params.Find('capabilities');
  if CapsData = nil then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS,
      'Invalid params: initialize requires capabilities'));
  if CapsData.JSONType <> jtObject then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS,
      'Invalid params: capabilities must be an object'));

  InfoData := AMessage.Params.Find('clientInfo');
  if InfoData = nil then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS,
      'Invalid params: initialize requires clientInfo'));
  if InfoData.JSONType <> jtObject then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS,
      'Invalid params: clientInfo must be an object'));
  NameData := TJSONObject(InfoData).Find('name');
  if (NameData = nil) or (NameData.JSONType <> jtString) then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS,
      'Invalid params: clientInfo.name must be a string'));
  ClientVersionData := TJSONObject(InfoData).Find('version');
  if (ClientVersionData = nil) or
    (ClientVersionData.JSONType <> jtString) then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS,
      'Invalid params: clientInfo.version must be a string'));

  // Legacy negotiation: echo a supported revision, otherwise answer
  // with the latest legacy revision we speak (the client decides
  // whether to proceed or disconnect).
  if IsLegacyProtocolVersion(Requested) then
    NegotiatedVersion := Requested
  else
    NegotiatedVersion := LATEST_LEGACY_PROTOCOL_VERSION;
  ClientName := NameData.AsString;
  ClientVersion := ClientVersionData.AsString;

  InitResult := nil;
  Capabilities := nil;
  ServerInfo := nil;
  ClientCapabilities := nil;
  try
    ClientCapabilities := TJSONObject(CapsData.Clone);
    Capabilities := ServerCapabilities;
    ServerInfo := TJSONObject.Create;
    ServerInfo.Add('name', FName);
    ServerInfo.Add('version', FVersion);

    InitResult := TJSONObject.Create;
    InitResult.Add('protocolVersion', NegotiatedVersion);
    InitResult.Add('capabilities', Capabilities);
    Capabilities := nil;
    InitResult.Add('serverInfo', ServerInfo);
    ServerInfo := nil;
    if FInstructions <> '' then
      InitResult.Add('instructions', FInstructions);

    // Legacy wire dialect: no resultType / serverInfo _meta stamping.
    ResponsePayload := InitResult;
    InitResult := nil;
    Result := BuildResultResponse(AMessage.Id, ResponsePayload);
  except
    InitResult.Free;
    Capabilities.Free;
    ServerInfo.Free;
    ClientCapabilities.Free;
    raise;
  end;

  FLegacyProtocolVersion := NegotiatedVersion;
  FLegacyClientName := ClientName;
  FLegacyClientVersion := ClientVersion;
  FLegacyClientCapabilities := ClientCapabilities;
  FLegacyState := lsAwaitingInitialized;
end;

function TMCPServer.LegacyContext(AParams: TJSONObject): TMCPRequestContext;
var
  MetaData: TJSONData;
begin
  Result := Default(TMCPRequestContext);
  Result.ProtocolVersion := FLegacyProtocolVersion;
  Result.ClientName := FLegacyClientName;
  Result.ClientVersion := FLegacyClientVersion;
  Result.ClientCapabilities := FLegacyClientCapabilities;
  Result.Notifier := EmitNotification;
  // progressToken is per-request in every era.
  if AParams <> nil then
  begin
    MetaData := AParams.Find('_meta');
    if (MetaData <> nil) and (MetaData.JSONType = jtObject) then
      ExtractProgressToken(TJSONObject(MetaData), Result);
  end;
end;

procedure TMCPServer.SetLineSink(ASink: TMCPLineSink; AUserData: Pointer);
begin
  FSink := ASink;
  FSinkData := AUserData;
end;

procedure TMCPServer.EmitNotification(const AMethod: string;
  AParams: TJSONObject);
var
  Line: string;
begin
  Line := BuildNotification(AMethod, AParams);
  if Assigned(FSink) then
    FSink(Line, FSinkData);
end;

function TMCPServer.OversizedLineResponse(AMaxLineLength: Integer): string;
begin
  // Same family as an unparseable line: -32700 with a null id (the id,
  // if any, was inside the line we refused to buffer).
  Result := BuildErrorResponse(nil, JSONRPC_PARSE_ERROR, Format(
    'Parse error: line exceeds the maximum length of %d bytes',
    [AMaxLineLength]));
end;

procedure TMCPServer.AddCacheFields(AResult: TJSONObject; ATtlMs: Integer);
begin
  // CacheableResult (SEP-2549): ttlMs + cacheScope are REQUIRED on
  // discover/list/read results — the official RC SDKs reject results
  // without them (verified against @modelcontextprotocol/client
  // 2.0.0-beta.4, whose wire schema marks them non-optional).
  AResult.Add('ttlMs', ATtlMs);
  AResult.Add('cacheScope', FCacheScope);
end;

function TMCPServer.HandleDiscover(const AMessage: TJSONRPCMessage): string;
var
  DiscoverResult, Capabilities, ServerInfo: TJSONObject;
  Versions: TJSONArray;
begin
  Versions := TJSONArray.Create;
  Versions.Add(MCP_PROTOCOL_VERSION);

  Capabilities := ServerCapabilities;

  // serverInfo is a required TOP-LEVEL DiscoverResult field in the RC
  // wire schema — the _meta stamp alone is not enough; the official
  // client beta classifies a server without it as legacy (verified
  // against @modelcontextprotocol/client 2.0.0-beta.4).
  ServerInfo := TJSONObject.Create;
  ServerInfo.Add('name', FName);
  ServerInfo.Add('version', FVersion);

  DiscoverResult := TJSONObject.Create;
  DiscoverResult.Add('supportedVersions', Versions);
  DiscoverResult.Add('capabilities', Capabilities);
  DiscoverResult.Add('serverInfo', ServerInfo);
  if FInstructions <> '' then
    DiscoverResult.Add('instructions', FInstructions);
  AddCacheFields(DiscoverResult, FCacheTtlMs);

  Result := ResultResponse(AMessage, DiscoverResult, False);
end;

function TMCPServer.HandleToolsList(const AMessage: TJSONRPCMessage;
  ALegacy: Boolean): string;
var
  ListResult: TJSONObject;
  Tools: TJSONArray;
  I: Integer;
begin
  // Whole list, registration order: deterministic ordering is what the
  // spec asks for, and without pagination there is no cursor to honor.
  Tools := TJSONArray.Create;
  for I := 0 to High(FTools) do
    Tools.Add(FTools[I].Definition.Clone);
  ListResult := TJSONObject.Create;
  ListResult.Add('tools', Tools);
  if not ALegacy then
    AddCacheFields(ListResult, FCacheTtlMs);
  Result := ResultResponse(AMessage, ListResult, ALegacy);
end;

function TMCPServer.HandleToolsCall(const AMessage: TJSONRPCMessage;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): string;
var
  NameData, ArgsData: TJSONData;
  ToolName, BindError: string;
  Index: Integer;
  Arguments, OwnedEmpty, CallResult: TJSONObject;
  ToolResult: TMCPToolResult;
  ArgsInstance: TMCPArgs;
begin
  if AMessage.Params = nil then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS,
      'Invalid params: params are required'));
  NameData := AMessage.Params.Find('name');
  if (NameData = nil) or (NameData.JSONType <> jtString) then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS,
      'Invalid params: name must be a string'));
  ToolName := NameData.AsString;

  Index := FindTool(ToolName);
  if Index < 0 then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS,
      'Unknown tool: ' + ToolName));

  ArgsData := AMessage.Params.Find('arguments');
  if (ArgsData <> nil) and (ArgsData.JSONType <> jtObject) then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS,
      'Invalid params: arguments must be an object'));

  // Handlers always see a non-nil arguments object.
  OwnedEmpty := nil;
  if ArgsData <> nil then
    Arguments := TJSONObject(ArgsData)
  else
  begin
    OwnedEmpty := TJSONObject.Create;
    Arguments := OwnedEmpty;
  end;

  try
    try
      if FTools[Index].ArgsClass <> nil then
      begin
        // Typed path: bind + validate before the handler runs.
        // Binding failures are argument errors the model can correct,
        // so they travel in-band like any execution error.
        if BindArguments(FTools[Index].ArgsClass, Arguments,
          ArgsInstance, BindError) then
        try
          if Assigned(FTools[Index].ArgsMethod) then
            ToolResult := FTools[Index].ArgsMethod(ArgsInstance, ACtx)
          else
            ToolResult := FTools[Index].ArgsHandler(ArgsInstance, ACtx);
        finally
          ArgsInstance.Free;
        end
        else
          ToolResult := MCPErrorResult(BindError);
      end
      else if Assigned(FTools[Index].Method) then
        ToolResult := FTools[Index].Method(Arguments, ACtx)
      else
        ToolResult := FTools[Index].Handler(Arguments, ACtx);
    except
      // Execution errors travel in-band (isError: true) so the model
      // can read them and self-correct; only dispatch-level faults are
      // JSON-RPC errors.
      on E: Exception do
        ToolResult := MCPErrorResult(ExceptionClientMessage(
          'tools/call handler', 'Tool execution failed: ',
          'Tool execution failed', E));
    end;
  finally
    OwnedEmpty.Free;
  end;

  if ToolResult.Content = nil then
    ToolResult.Content := TJSONArray.Create;

  CallResult := TJSONObject.Create;
  CallResult.Add('content', ToolResult.Content);
  CallResult.Add('isError', ToolResult.IsError);
  if ToolResult.StructuredContent <> nil then
    CallResult.Add('structuredContent', ToolResult.StructuredContent);

  Result := ResultResponse(AMessage, CallResult, ALegacy);
end;

function TMCPServer.HandleResourcesList(const AMessage: TJSONRPCMessage;
  ALegacy: Boolean): string;
var
  ListResult: TJSONObject;
  Resources: TJSONArray;
  I: Integer;
begin
  Resources := TJSONArray.Create;
  for I := 0 to High(FResources) do
    Resources.Add(FResources[I].Definition.Clone);
  ListResult := TJSONObject.Create;
  ListResult.Add('resources', Resources);
  if not ALegacy then
    AddCacheFields(ListResult, FCacheTtlMs);
  Result := ResultResponse(AMessage, ListResult, ALegacy);
end;

function TMCPServer.HandleResourcesRead(const AMessage: TJSONRPCMessage;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): string;
var
  UriData: TJSONData;
  Uri, MimeType: string;
  Index, ReadTtlMs: Integer;
  Contents: TJSONArray;
  ReadResult, NotFoundData, Vars: TJSONObject;
begin
  if AMessage.Params = nil then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS,
      'Invalid params: params are required'));
  UriData := AMessage.Params.Find('uri');
  if (UriData = nil) or (UriData.JSONType <> jtString) then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS,
      'Invalid params: uri must be a string'));
  Uri := UriData.AsString;

  // Exact resources win; templates are the fallback, first match in
  // registration order.
  Contents := nil;
  ReadTtlMs := 0;
  Index := FindResource(Uri);
  if Index >= 0 then
  begin
    // Dynamic readers advertise ttl 0 (always revalidate) — the
    // library cannot know how fresh a callback's data stays; static
    // text is fixed for the process lifetime and uses the registry
    // ttl.
    if Assigned(FResources[Index].Method) then
      Contents := FResources[Index].Method(Uri, ACtx)
    else if Assigned(FResources[Index].Reader) then
      Contents := FResources[Index].Reader(Uri, ACtx)
    else if FResources[Index].HasStaticText then
    begin
      MimeType := FResources[Index].Definition.Get('mimeType', 'text/plain');
      Contents := MCPTextContents(Uri, MimeType,
        FResources[Index].StaticText);
      ReadTtlMs := FCacheTtlMs;
    end;
  end
  else
  begin
    for Index := 0 to High(FTemplates) do
      if MatchUriTemplate(FTemplates[Index].UriTemplate, Uri, Vars) then
      begin
        try
          if Assigned(FTemplates[Index].Method) then
            Contents := FTemplates[Index].Method(Uri, Vars, ACtx)
          else
            Contents := FTemplates[Index].Reader(Uri, Vars, ACtx);
        finally
          Vars.Free;
        end;
        Break;
      end;
    if Contents = nil then
    begin
      // Modern era: MUST be -32602 (the modern revision forbids
      // -32002). Legacy era: -32002 is what its clients expect.
      NotFoundData := TJSONObject.Create;
      NotFoundData.Add('uri', Uri);
      if ALegacy then
        Exit(BuildErrorResponse(AMessage.Id,
          MCP_ERROR_LEGACY_RESOURCE_NOT_FOUND, 'Resource not found',
          NotFoundData));
      Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS,
        'Resource not found', NotFoundData));
    end;
  end;
  if Contents = nil then
    raise EMCPServer.CreateFmt(
      'Resource reader for "%s" returned no contents', [Uri]);

  ReadResult := TJSONObject.Create;
  ReadResult.Add('contents', Contents);
  if not ALegacy then
    AddCacheFields(ReadResult, ReadTtlMs);
  Result := ResultResponse(AMessage, ReadResult, ALegacy);
end;

function TMCPServer.HandleTemplatesList(const AMessage: TJSONRPCMessage;
  ALegacy: Boolean): string;
var
  ListResult: TJSONObject;
  Templates: TJSONArray;
  I: Integer;
begin
  Templates := TJSONArray.Create;
  for I := 0 to High(FTemplates) do
    Templates.Add(FTemplates[I].Definition.Clone);
  ListResult := TJSONObject.Create;
  ListResult.Add('resourceTemplates', Templates);
  if not ALegacy then
    AddCacheFields(ListResult, FCacheTtlMs);
  Result := ResultResponse(AMessage, ListResult, ALegacy);
end;

function TMCPServer.HandlePromptsList(const AMessage: TJSONRPCMessage;
  ALegacy: Boolean): string;
var
  ListResult: TJSONObject;
  Prompts: TJSONArray;
  I: Integer;
begin
  Prompts := TJSONArray.Create;
  for I := 0 to High(FPrompts) do
    Prompts.Add(FPrompts[I].Definition.Clone);
  ListResult := TJSONObject.Create;
  ListResult.Add('prompts', Prompts);
  if not ALegacy then
    AddCacheFields(ListResult, FCacheTtlMs);
  Result := ResultResponse(AMessage, ListResult, ALegacy);
end;

function TMCPServer.HandlePromptsGet(const AMessage: TJSONRPCMessage;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): string;
var
  NameData, ArgsData, DeclaredData: TJSONData;
  PromptName: string;
  Index, I: Integer;
  Arguments, OwnedEmpty, GetResult, Declared: TJSONObject;
  DeclaredArgs: TJSONArray;
  Messages: TJSONArray;
begin
  if AMessage.Params = nil then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS,
      'Invalid params: params are required'));
  NameData := AMessage.Params.Find('name');
  if (NameData = nil) or (NameData.JSONType <> jtString) then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS,
      'Invalid params: name must be a string'));
  PromptName := NameData.AsString;

  Index := FindPrompt(PromptName);
  if Index < 0 then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS,
      'Unknown prompt: ' + PromptName));

  ArgsData := AMessage.Params.Find('arguments');
  if (ArgsData <> nil) and (ArgsData.JSONType <> jtObject) then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS,
      'Invalid params: arguments must be an object'));

  OwnedEmpty := nil;
  if ArgsData <> nil then
    Arguments := TJSONObject(ArgsData)
  else
  begin
    OwnedEmpty := TJSONObject.Create;
    Arguments := OwnedEmpty;
  end;

  try
    // Missing required arguments are protocol errors for prompts
    // (spec: -32602), unlike the tools' in-band isError channel.
    DeclaredData := FPrompts[Index].Definition.Find('arguments');
    if (DeclaredData <> nil) and (DeclaredData.JSONType = jtArray) then
    begin
      DeclaredArgs := TJSONArray(DeclaredData);
      for I := 0 to DeclaredArgs.Count - 1 do
      begin
        Declared := TJSONObject(DeclaredArgs[I]);
        if Declared.Get('required', False) and
          (Arguments.Find(Declared.Get('name', '')) = nil) then
          Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS,
            'Missing required argument "' + Declared.Get('name', '') + '"'));
      end;
    end;

    try
      if Assigned(FPrompts[Index].Method) then
        Messages := FPrompts[Index].Method(Arguments, ACtx)
      else
        Messages := FPrompts[Index].Handler(Arguments, ACtx);
    except
      on E: Exception do
        Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INTERNAL_ERROR,
          ExceptionClientMessage('prompts/get handler',
            'Prompt handler failed: ', 'Prompt handler failed', E)));
    end;
    if Messages = nil then
      Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INTERNAL_ERROR,
        'Prompt handler for "' + PromptName + '" returned no messages'));
  finally
    OwnedEmpty.Free;
  end;

  GetResult := TJSONObject.Create;
  if FPrompts[Index].Description <> '' then
    GetResult.Add('description', FPrompts[Index].Description);
  GetResult.Add('messages', Messages);
  Result := ResultResponse(AMessage, GetResult, ALegacy);
end;

end.
