unit MCP.Server;

// Transport-agnostic MCP server core, DUAL-ERA per the 2026-07-28
// spec's compatibility model: requests carrying modern per-request
// _meta are served statelessly (revision 2026-07-28); an `initialize`
// request selects legacy semantics (2025-11-25 and earlier), scoped to
// one TMCPSession; both eras share the same frozen registries, which is
// what lets current-day legacy clients (Claude Code, Claude Desktop)
// and RC-era clients use the same binary without sharing negotiated
// identity. Set DualEra := False for a strict modern-only server that
// rejects initialize with a diagnostic naming its supported versions,
// as the spec recommends.
//
// Three lifetimes stay separate: TMCPServer owns registries frozen when
// the first session is created; TMCPSession owns one connection's
// legacy lifecycle and cloned client capabilities; each HandleMessage
// call owns its notification sink. The whole protocol surface remains
// testable without a transport, mirroring duetto's sans-I/O discipline.
// Redacted escaped exceptions add only the stderr diagnostic described
// below. MCP.Transport.Stdio (and a future MCP.Transport.HTTP) are thin
// byte-moving shells around this.
//
// v1 protocol surface:
//   modern era (per-request _meta):
//     server/discover                  (mandatory in 2026-07-28)
//     tools/list, tools/call
//     resources/list, resources/read
//     prompts/list, prompts/get
//     completion/complete              (#81; capabilities follow the
//                                      registrations)
//   legacy era (dual-era mode, after initialize + initialized):
//     initialize, ping
//     tools/list, tools/call
//     resources/list, resources/read
//     prompts/list, prompts/get, completion/complete
//     — responses omit the modern-only stamps (resultType, serverInfo
//       _meta, ttlMs/cacheScope) and resource-not-found is the legacy
//       -32002, so each era sees its own wire dialect
//   notifications/initialized          completes the legacy handshake
//   notifications/cancelled            cooperatively cancels the active
//                                      request when its id matches
//   other notifications/*              accepted and ignored. Legacy
//                                      lifecycle, negotiated identity,
//                                      and active-request cancellation
//                                      belong to TMCPSession.
// Not implemented (deliberate): subscriptions/listen and the
// listChanged capability flags (registries are fixed after startup, so
// there is nothing to notify), pagination cursors (lists are returned
// whole), and a general JSON-Schema validation engine — the schema
// subset the builders emit is server-enforced per call (#23);
// beyond it, handlers validate their own inputs and report problems
// as isError tool results, which is what models can act on.
//
// MRTR (Multi Round-Trip Requests, SEP-2322; spec pattern verified
// 2026-08-08 at .../2026-07-28/basic/patterns/mrtr): a tools/call or
// prompts/get handler needing more input returns
// MCPInputRequired(...) / MCPPromptInputRequired(...) — an
// input_required result carrying inputRequests (elicitation form/url,
// sampling/createMessage, roots/list entry builders below) and the
// handler's opaque requestState, sealed by the server (#89, see
// MCP.RequestState). The client retries the ORIGINAL request with
// inputResponses + the echoed token; the library verifies it and
// re-enters the same handler with both exposed on TMCPRequestContext.
// Each round is one ordinary HandleMessage call — no threads, no
// suspension. Modern era only: legacy calls get an in-band error
// (tools) or -32603 (prompts), and mapping onto legacy
// server-initiated requests is out of scope. Kinds are gated on the
// per-request client capabilities: an entry the client did not
// declare support for is answered with -32021
// (MissingRequiredClientCapability) instead of the result, per the
// spec's "MUST NOT send an inputRequests the client has not declared
// support for". resources/read MAY also return input_required per the
// final spec; this library deliberately surfaces MRTR on tools/call
// and prompts/get only.
//
// Handlers are synchronous and may be plain functions or methods (both
// overloads are provided). A handler that raises becomes an isError
// tool result carrying the exception message — execution errors belong
// in-band where the model can read them; protocol errors stay JSON-RPC
// errors. A handler that raises EMCPProtocolError answers with that
// JSON-RPC error instead, from any handler kind (#88). RedactErrorDetails preserves that verbose behavior by default;
// when enabled, escaped exceptions carry only a stable generic message
// and correlation reference on the wire, while the full detail is logged
// to stderr under the same reference. Deliberate MCPErrorResult values
// remain verbatim. The stderr/stdout split follows the transport spec
// (verified 2026-07-21):
// https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio
// Cancellation behavior (stop work, free resources, and send no response;
// unknown, completed, and malformed targets are ignored) is verified
// 2026-07-21 against:
// https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/cancellation

{$I MCP.inc}

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
  MCP.Completion,
  MCP.JSONRPC,
  MCP.Protocol,
  MCP.Schema,
  MCP.UriTemplate;

type
  TMCPLegacyState = (lsNew, lsAwaitingInitialized, lsReady);

  // Result of one tool invocation. Content is a JSON array of content
  // blocks (owned; use the MCP*Result builders), StructuredContent is
  // the optional machine-readable payload (owned; nil when absent).
  // InputRequired marks an MRTR interim result (use MCPInputRequired):
  // InputRequests is the owned inputRequests map (may be nil for a
  // state-only round) and RequestState the handler's opaque state
  // ('' = absent).
  TMCPToolResult = record
    Content: TJSONArray;
    StructuredContent: TJSONData;
    IsError: Boolean;
    InputRequired: Boolean;
    InputRequests: TJSONObject;
    RequestState: string;
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
    // Escape hatch (#23): the application owns argument validation
    // Client capabilities the tool declared it needs (#84), checked
    // before the handler runs.
    RequiredCapabilities: array of string;
    // for this tool; its schema may use keywords outside the
    // enforceable subset and the server skips call-time checks.
    AppValidated: Boolean;
    // Set at freeze: the inputSchema is within the enforceable
    // subset, so arguments are validated against it per call.
    SubsetValidate: Boolean;
    // Set at freeze: an outputSchema within the subset, so every
    // structuredContent is checked against it before it is sent (#91).
    OutputValidate: Boolean;
    // Set at freeze: the inputSchema's x-mcp-header annotations, which
    // registration already validated (#90), so a call does not walk
    // the schema again.
    HeaderParams: TMCPHeaderParameters;
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

  // MRTR-capable prompt result: either Messages (owned; the ordinary
  // GetPromptResult payload, use MCPPromptMessagesResult) or an
  // input_required round (use MCPPromptInputRequired — same fields as
  // the tool variant). Prompt handlers that never need MRTR keep the
  // plain TJSONArray signature above.
  TMCPPromptResult = record
    Messages: TJSONArray;
    InputRequired: Boolean;
    InputRequests: TJSONObject;
    RequestState: string;
  end;

  TMCPPromptResultHandler = function(AArguments: TJSONObject;
    const ACtx: TMCPRequestContext): TMCPPromptResult;
  TMCPPromptResultMethod = function(AArguments: TJSONObject;
    const ACtx: TMCPRequestContext): TMCPPromptResult of object;

  TMCPPromptRegistration = record
    Definition: TJSONObject; // owned: name/description/arguments
    Description: string;     // echoed as GetPromptResult.description
    Handler: TMCPPromptHandler;
    Method: TMCPPromptMethod;
    ResultHandler: TMCPPromptResultHandler;
    ResultMethod: TMCPPromptResultMethod;
  end;

  // completion/complete (#81): the types live in MCP.Completion and are
  // re-exported here, so a server needs only MCP.Server.
  TMCPCompletion = MCP.Completion.TMCPCompletion;
  TMCPCompletionHandler = MCP.Completion.TMCPCompletionHandler;
  TMCPCompletionMethod = MCP.Completion.TMCPCompletionMethod;

  TMCPCompletionRegistration = record
    RefType: string;     // 'ref/prompt' or 'ref/resource'
    RefName: string;     // prompt name or URI template
    Argument: string;
    Values: array of string; // static candidates when no callable
    Handler: TMCPCompletionHandler;
    Method: TMCPCompletionMethod;
  end;

  TMCPServer = class;

  // Heap-allocated builder state shared by every record copy of
  // TMCPPromptArguments — same copy-safety design as TMCPSchemaCore
  // (issue #29): the consumed flag lives on the ref-counted core, so
  // Build-reuse raises through any record copy and a never-built list
  // is freed with the last copy.
  TMCPPromptArgumentsCore = class(TInterfacedObject)
  private
    FList: TJSONArray; // owned here until Build transfers it
  public
    destructor Destroy; override;
  end;

  // Fluent declaration of a prompt's flat argument list (name /
  // description / required — prompts do not use JSON Schema). Same
  // value semantics as TMCPSchema: record copies share one underlying
  // builder and Build consumes it for every copy.
  TMCPPromptArguments = record
  private
    FLifetime: IInterface; // ref-counts FCore across record copies
    FCore: TMCPPromptArgumentsCore; // typed view of the same object
    function ActiveCore: TMCPPromptArgumentsCore;
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
    FServer: TMCPServer;       // borrowed: guards post-freeze mutation
    function Annotations: TJSONObject;
    function SetAnnotation(const AName: string;
      AValue: Boolean): TMCPToolOptions;
  public
    function Title(const ATitle: string): TMCPToolOptions;
    function ReadOnlyHint(AValue: Boolean = True): TMCPToolOptions;
    function DestructiveHint(AValue: Boolean = True): TMCPToolOptions;
    function IdempotentHint(AValue: Boolean = True): TMCPToolOptions;
    function OpenWorldHint(AValue: Boolean = True): TMCPToolOptions;
    // Escape hatch (#23): declare that this tool's handler owns its
    // argument validation. Required for raw-handler schemas that use
    // keywords outside the server-enforced subset (type/properties/
    // required/enum/default); such tools skip call-time validation.
    function ApplicationValidated: TMCPToolOptions;
    // Declares a client capability the tool needs ('sampling',
    // 'elicitation', 'roots', ...). A request whose clientCapabilities
    // lack it is answered -32021 before the handler runs, so nothing has
    // been streamed yet and Streamable HTTP can answer 400 as the spec
    // requires (#84). Call once per capability.
    function RequiresClientCapability(const AName: string): TMCPToolOptions;
  end;

  // Where the server writes server-to-client notification lines
  // (notifications/progress, notifications/message). Plain procedure +
  // user data so procedural transports can register without objects.
  TMCPLineSink = procedure(const ALine: string; AUserData: Pointer);

  // One transport connection's legacy lifecycle. ClientCapabilities is
  // an owned clone of initialize.params.capabilities; request contexts
  // borrow it only for the synchronous handler call.
  TMCPSession = class
  private
    // Legacy initialize MUST be first, and normal operations start only
    // after notifications/initialized (ping remains valid throughout):
    // https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle
    // (verified 2026-07-21).
    FLegacyState: TMCPLegacyState;
    FLegacyIdentity: TObject;
    FOwner: TMCPServer; // borrowed: the server must outlive its sessions
    FCurrentRequestToken: TObject; // borrowed: dispatch owns the token
    // ARequestId is borrowed; the returned token is owned by dispatch.
    function BeginRequest(ARequestId: TJSONData): TObject;
    procedure EndRequest(AToken: TObject);
    function TryCancelRequest(ARequestId: TJSONData): Boolean;
    procedure CompleteLegacyInitialize;
    // Takes ownership of AClientCapabilities.
    procedure CommitLegacyInitialize(const AProtocolVersion,
      AClientName, AClientVersion: string;
      AClientCapabilities: TJSONObject);
    // AParams is borrowed for the synchronous handler call.
    function LegacyContext(AParams: TJSONObject): TMCPRequestContext;
    // Sessions are constructed only by their owning server — the
    // non-public constructor is deliberate, so the compiler hint
    // about it is suppressed for this one declaration.
    {$PUSH}{$WARN 3018 OFF}
    constructor Create(AOwner: TMCPServer);
    {$POP}
  public
    destructor Destroy; override;
    // Signal cooperative cancellation for ARequestId (borrowed). Only
    // the currently active matching string/number id is accepted;
    // unknown, finished, malformed, and repeated signals are no-ops.
    procedure CancelRequest(ARequestId: TJSONData);
  end;

  TMCPServer = class
  private
    type
      // Registry name lookup (FindTool / FindPrompt): index or < 0.
      TRegistryLookup = function(const AName: string): Integer of object;
  private
    FName: string;
    FVersion: string;
    FInstructions: string;
    FCacheTtlMs: Integer;
    FCacheScope: string;
    FRedactErrorDetails: Boolean;
    FDualEra: Boolean;
    FFrozen: Boolean;
    // requestState sealing (#89): the configured key ring (empty means
    // a random key for this instance), the token lifetime, and the sealer
    // built from them at freeze (a TMCPRequestStateSealer, owned).
    FRequestStateKeys: array of RawByteString;
    FRequestStateTtlMs: Integer;
    FSealer: TObject;
    FTools: array of TMCPToolRegistration;
    FResources: array of TMCPResourceRegistration;
    FTemplates: array of TMCPTemplateRegistration;
    FPrompts: array of TMCPPromptRegistration;
    FCompletions: array of TMCPCompletionRegistration;

    procedure EnsureMutable;
    procedure FreezeConfiguration;
    procedure SetInstructions(const AValue: string);
    procedure SetCacheTtlMs(AValue: Integer);
    procedure SetCacheScope(const AValue: string);
    procedure SetRedactErrorDetails(AValue: Boolean);
    procedure SetDualEra(AValue: Boolean);
    procedure SetRequestStateTtlMs(AValue: Integer);
    // Replaces ACtx.RequestState with the handler's own state when the
    // client's token verifies for this request; False when it does not.
    function OpenRequestState(const AMessage: TJSONRPCMessage;
      var ACtx: TMCPRequestContext): Boolean;
    function ExceptionClientMessage(const ASite, AVerbosePrefix,
      ARedactedMessage: string; E: Exception): string;
    // E is an EMCPProtocolError, declared after this class.
    function ProtocolErrorResponse(AMessage: TJSONRPCMessage;
      E: Exception): string;
    function ParseSchema(const ASchemaJson, AToolName: string): TJSONObject;
    function BuildToolDefinition(const AName, ADescription,
      AInputSchemaJson: string): TJSONObject;
    // ADefinition is borrowed; validation frees nothing.
    procedure MarkToolApplicationValidated(ADefinition: TJSONObject);
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
      AMethod: TMCPPromptMethod;
      AResultHandler: TMCPPromptResultHandler = nil;
      AResultMethod: TMCPPromptResultMethod = nil);
    procedure AddTemplate(const AUriTemplate, AName, AMimeType,
      ADescription: string; AReader: TMCPTemplateReader;
      AMethod: TMCPTemplateMethod);
    function ServerCapabilities: TJSONObject;
    // ACallable: the handler or method overload, so a nil one is a
    // mistake, not an empty list.
    procedure AddCompletion(const ARefType, ARefName, AArgument: string;
      const AValues: array of string; ACallable: Boolean;
      AHandler: TMCPCompletionHandler; AMethod: TMCPCompletionMethod);
    function FindTemplate(const AUriTemplate: string): Integer;
    // The completion registered for that argument of that target, or -1.
    function FindCompletion(const ARefType, ARefName,
      AArgument: string): Integer;
    function HandleComplete(const AMessage: TJSONRPCMessage;
      const ACtx: TMCPRequestContext; ALegacy: Boolean): string;
    function HandleTemplatesList(const AMessage: TJSONRPCMessage;
      ALegacy: Boolean): string;

    function DispatchRequest(ASession: TMCPSession;
      ASink: TMCPLineSink; ASinkData: Pointer;
      const AMessage: TJSONRPCMessage): string;
    function DispatchLegacyRequest(ASession: TMCPSession;
      ASink: TMCPLineSink; ASinkData: Pointer;
      const AMessage: TJSONRPCMessage): string;
    function HandleInitialize(ASession: TMCPSession;
      const AMessage: TJSONRPCMessage): string;
    function HandleDiscover(const AMessage: TJSONRPCMessage): string;
    function HandleToolsList(const AMessage: TJSONRPCMessage;
      ALegacy: Boolean): string;
    // Shared prologue for tools/call and prompts/get, which validate
    // and resolve their target identically. ALookup is FindTool or
    // FindPrompt; ANoun ('tool'/'prompt') names the registry in the
    // unknown-name message. Returns '' once the target resolved,
    // otherwise the error response the caller must Exit with.
    // AArguments is never nil on success: it is a copy of the supplied
    // arguments (or an empty object), the same object as AOwnedEmpty,
    // which the caller must free. AMessage keeps the client's original
    // arguments for requestState sealing (#89).
    function ResolveCallTarget(const AMessage: TJSONRPCMessage;
      ALookup: TRegistryLookup; const ANoun: string;
      out AName: string; out AIndex: Integer;
      out AArguments, AOwnedEmpty: TJSONObject): string;
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
    function InputRequiredResponse(const AMessage: TJSONRPCMessage;
      const ACtx: TMCPRequestContext;
      const ASubjectKind, ASubjectName: string;
      AInputRequests: TJSONObject; const ARequestState: string): string;
    function ResultResponse(const AMessage: TJSONRPCMessage;
      AResult: TJSONObject; ALegacy: Boolean): string;
    procedure AddCacheFields(AResult: TJSONObject; ATtlMs: Integer);
  public
    constructor Create(const AName, AVersion: string);
    destructor Destroy; override;

    // Natural-language guidance surfaced through server/discover.
    property Instructions: string read FInstructions write SetInstructions;
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
    // exception details with a correlation reference (deliberate errors,
    // MCPErrorResult and EMCPProtocolError, are sent as written) and logs the full
    // exception to stderr under that reference (best-effort: on UNIX
    // the first emission upgrades a default SIGPIPE disposition to
    // ignore so a closed stderr cannot kill the process; a host's own
    // SIGPIPE handling is left untouched).
    property RedactErrorDetails: Boolean read FRedactErrorDetails
      write SetRedactErrorDetails;

    // Dual-era mode (default True): answer the legacy initialize
    // handshake (2025-11-25 and earlier) alongside stateless
    // 2026-07-28 requests — today's clients (Claude Code, Claude
    // Desktop) still open with initialize. False = strict modern-only:
    // initialize is rejected with a diagnostic naming the supported
    // versions.
    property DualEra: Boolean read FDualEra write SetDualEra;

    // requestState integrity (#89). Every requestState a handler returns
    // goes to the client sealed (HMAC-SHA-256 over the state, an expiry,
    // the method, the tool or prompt name, a digest of the arguments
    // and this server's name), and every one a client sends back is
    // verified before the handler runs: a token that fails is answered
    // -32602 and the handler never sees it. Handlers keep reading and
    // writing their own plain state (ACtx.RequestState).
    //
    // Keys: the first seals, every key verifies. Rotate in three steps
    // across all instances: [Old, New], then [New, Old], then [New] once
    // the longest old-key TTL has passed since the last instance
    // switched, plus a clock allowance (docs/guides/configuration.md,
    // "requestState sealing", has the full procedure). Each key must be at least 32 bytes. Without keys
    // the server seals with a random key read from the OS at freeze,
    // which only this instance can verify: set a shared key when
    // several instances serve one endpoint or one replaces another.
    // A token verifies until it expires, so it can be replayed within
    // its TTL. The client can read the state, so it must not carry
    // secrets.
    procedure SetRequestStateKeys(const AKeys: array of RawByteString);
    // Token lifetime in milliseconds (default 600000, ten minutes).
    property RequestStateTtlMs: Integer read FRequestStateTtlMs
      write SetRequestStateTtlMs;

    // The response a transport sends for an inbound line it refused to
    // buffer (length cap). Kept here so the error shape remains a
    // protocol decision — transports move lines only.
    function OversizedLineResponse(AMaxLineLength: Integer): string;

    // Freezes request-visible configuration and returns one independent
    // legacy session bound to this server. Transports create one per
    // connection, free it after serving, and keep the server alive longer.
    function CreateSession: TMCPSession;

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
    // MRTR-capable prompt overloads: the handler returns a
    // TMCPPromptResult and may answer with an input_required round
    // (see the MRTR notes in the unit header).
    procedure RegisterPrompt(const AName, ADescription: string;
      AHandler: TMCPPromptResultHandler); overload;
    procedure RegisterPrompt(const AName, ADescription: string;
      AMethod: TMCPPromptResultMethod); overload;
    procedure RegisterPrompt(const AName, ADescription: string;
      constref AArguments: TMCPPromptArguments;
      AHandler: TMCPPromptResultHandler); overload;
    procedure RegisterPrompt(const AName, ADescription: string;
      constref AArguments: TMCPPromptArguments;
      AMethod: TMCPPromptResultMethod); overload;

    // Argument completion (completion/complete, #81) for a registered
    // prompt's declared argument or a registered resource template's
    // variable. Register after the prompt or template. A static list
    // completes by case-insensitive prefix (MCPCompleteFrom); a callable
    // decides itself. Registering any completion declares the
    // completions capability; an argument with none registered answers
    // an empty list.
    procedure RegisterPromptCompletion(const APrompt, AArgument: string;
      const AValues: array of string); overload;
    procedure RegisterPromptCompletion(const APrompt, AArgument: string;
      AHandler: TMCPCompletionHandler); overload;
    procedure RegisterPromptCompletion(const APrompt, AArgument: string;
      AMethod: TMCPCompletionMethod); overload;
    procedure RegisterTemplateCompletion(const AUriTemplate, AVariable: string;
      const AValues: array of string); overload;
    procedure RegisterTemplateCompletion(const AUriTemplate, AVariable: string;
      AHandler: TMCPCompletionHandler); overload;
    procedure RegisterTemplateCompletion(const AUriTemplate, AVariable: string;
      AMethod: TMCPCompletionMethod); overload;

    // The core entry point: one inbound line in, at most one response
    // line out. The sink overload binds server-to-client notifications
    // to this call only. Returns True when AResponse must be written
    // (requests and malformed input), False when there is nothing to
    // send (notifications). Wire input never raises; a nil session or one
    // created by another server raises EMCPServer as API misuse.
    function HandleMessage(ASession: TMCPSession; const ALine: string;
      out AResponse: string): Boolean; overload;
    function HandleMessage(ASession: TMCPSession; const ALine: string;
      ASink: TMCPLineSink; ASinkData: Pointer;
      out AResponse: string): Boolean; overload;

    // The x-mcp-header parameters of tool AName (#90): the parameters a
    // Streamable HTTP client mirrors into Mcp-Param-* headers, which
    // the HTTP binding validates. Empty for an unknown tool or one
    // without annotations.
    function ToolHeaderParameters(const AName: string): TMCPHeaderParameters;

    function ToolCount: Integer;
    function ResourceCount: Integer;
    function PromptCount: Integer;
  end;

  EMCPServer = class(Exception);

  // A JSON-RPC error a handler answers with instead of a result (#88).
  // Raised from a tools/call, prompts/get or resources/read handler
  // (typed and template handlers included), it becomes the error
  // response with exactly this code, message and data, in both eras;
  // it is deliberate, so RedactErrorDetails leaves it alone: its message
  // and data reach the client verbatim, so keep secrets out. Every
  // other exception keeps its mapping (tools: in-band isError;
  // prompts and resources: -32603).
  //
  // Allowed codes: the JSON-RPC ones (-32700, -32600 to -32603), the
  // MCP-defined -32021 (MissingRequiredClientCapability; build it with
  // MCPMissingCapabilityError), and application codes outside the
  // reserved -32768..-32000 range. Any other code is reserved for a
  // meaning the spec defines elsewhere or for legacy use, so the
  // constructor raises EMCPServer for it (and frees AData). Error-code
  // policy verified 2026-11-26 against
  // https://modelcontextprotocol.io/specification/2026-07-28/basic/index#error-codes
  EMCPProtocolError = class(Exception)
  private
    FCode: Integer;
    FData: TJSONData;
    // Hands the data to the dispatch wrapper, which puts it on the
    // wire and then owns it (nil if none).
    function TakeData: TJSONData;
  public
    // Takes ownership of AData (nil for none). Code -32021 needs data
    // with a non-empty requiredCapabilities object.
    constructor Create(ACode: Integer; const AMessage: string;
      AData: TJSONData = nil);
    destructor Destroy; override;
    property Code: Integer read FCode;
    // Borrowed: owned by the exception; do not free or change it (a
    // -32021 whose data no longer validates is sent as -32603).
    property Data: TJSONData read FData;
  end;

// The -32021 MissingRequiredClientCapability error for a request
// that needs ACapability (for example 'sampling') which the client did
// not declare, with the spec's data.requiredCapabilities. Raise it
// from a handler: raise MCPMissingCapabilityError('sampling').
// Verified 2026-11-26 against
// https://modelcontextprotocol.io/specification/2026-07-28/basic/index#_meta
function MCPMissingCapabilityError(const ACapability: string): EMCPProtocolError;

// Content builders for handler implementations.
function MCPTextResult(const AText: string): TMCPToolResult;
function MCPErrorResult(const AText: string): TMCPToolResult;
function MCPStructuredResult(const AText: string;
  AStructured: TJSONData): TMCPToolResult; overload;
// Structured output of any JSON value (object, array, string, number,
// boolean or null; SEP-2106), with its serialized JSON as the text
// block, which the spec says such a result SHOULD also carry
// (tools#structured-content, verified 2026-11-26). Takes ownership.
function MCPStructuredResult(AStructured: TJSONData): TMCPToolResult; overload;
// Typed structured output: serializes the instance's published
// properties (MCPSerialize) and frees it.
function MCPStructuredResult(const AText: string;
  AObj: TMCPArgs): TMCPToolResult; overload;
// Image tool result: one image content block
// ({"type":"image","data":<base64>,"mimeType":<media type>}) in the
// same content envelope MCPTextResult builds. Content-block shape
// verified 2026-08-09 against:
// https://modelcontextprotocol.io/specification/2026-07-28/server/tools
// The string overload takes data that is ALREADY base64 (the same
// contract as MCPBlobContents); the TBytes overload encodes the raw
// bytes itself. AMimeType is the image's IANA media type
// ('image/png', 'image/jpeg', ...) and goes on the wire verbatim —
// the spec names no enumeration, so the handler owns that choice.
function MCPImageResult(const ABase64,
  AMimeType: string): TMCPToolResult; overload;
function MCPImageResult(const AData: TBytes;
  const AMimeType: string): TMCPToolResult; overload;
// Audio tool result: one audio content block, same contracts as
// MCPImageResult (base64 string or raw bytes, media type verbatim).
function MCPAudioResult(const ABase64,
  AMimeType: string): TMCPToolResult; overload;
function MCPAudioResult(const AData: TBytes;
  const AMimeType: string): TMCPToolResult; overload;
// Any mix of content blocks, in order (build them with MCP.Content:
// MCPTextContent, MCPImageContent, MCPAudioContent, MCPResourceLink,
// MCPEmbeddedText, MCPEmbeddedBlob). Takes ownership of every block,
// also when it raises: a nil or repeated block frees the blocks and
// raises EMCPServer (in a tool handler, an isError result).
function MCPContentResult(const ABlocks: array of TJSONObject): TMCPToolResult;
function MCPTextContents(const AUri, AMimeType, AText: string): TJSONArray;
function MCPBlobContents(const AUri, AMimeType, ABase64: string): TJSONArray;

// ── MRTR (input_required) builders and accessors ──
//
// A handler that needs more input assembles an inputRequests map —
// keys are handler-assigned identifiers, values come from the entry
// builders below — and returns MCPInputRequired(Requests, State).
// On the client's retry the same handler runs again with
// ACtx.InputResponses / ACtx.RequestState populated.
//
// AInputRequests ownership transfers ('' RequestState = absent); at
// least one of the two must be present (spec MUST) — EMCPServer
// otherwise, surfaced in-band by the dispatch wrapper.
function MCPInputRequired(AInputRequests: TJSONObject;
  const ARequestState: string = ''): TMCPToolResult;
function MCPPromptMessagesResult(AMessages: TJSONArray): TMCPPromptResult;
function MCPPromptInputRequired(AInputRequests: TJSONObject;
  const ARequestState: string = ''): TMCPPromptResult;

// inputRequests entry builders — one per embedded request kind.
// Deprecation provenance: the final 2026-07-28 changelog deprecates
// Roots and Sampling wholesale (SEP-2577, "new implementations should
// not add support") under the 12-month lifecycle policy (SEP-2596);
// they are carried here deliberately (maintainer decision 2026-07-20:
// an incomplete MRTR design is worse) and each kind is one builder +
// one accessor, so a later sunset is cheap.
function MCPElicitFormRequest(const AMessage: string;
  ARequestedSchema: TJSONObject): TJSONObject; overload;
function MCPElicitFormRequest(const AMessage: string;
  constref ASchema: TMCPSchema): TJSONObject; overload;
function MCPElicitURLRequest(const AMessage, AUrl: string): TJSONObject;
// ASamplingParams is the caller-built CreateMessageRequest params
// object (messages/systemPrompt/maxTokens/...); ownership transfers.
function MCPSamplingRequest(ASamplingParams: TJSONObject): TJSONObject;
// Convenience single-turn text sampling request.
function MCPSamplingTextRequest(const APrompt: string;
  AMaxTokens: Integer): TJSONObject;
function MCPRootsRequest: TJSONObject;

// Retry-side accessors: the response entry for AKey (borrowed from
// the request tree; nil when absent), and the accepted-form shortcut
// for elicitation responses (content object when action = "accept",
// nil otherwise).
function MCPInputResponse(const ACtx: TMCPRequestContext;
  const AKey: string): TJSONObject;
function MCPElicitationContent(const ACtx: TMCPRequestContext;
  const AKey: string): TJSONObject;

// RFC 6570 level-1 simple-variable template match: {var} captures one
// or more characters excluding '/', delimited by the complete
// following literal with bounded backtracking. Variable names use
// [A-Za-z0-9_]. Captures are raw URI substrings; percent-decoding is
// deliberately not performed. On success AVars carries the captured
// variables (caller frees). Exposed for tests.
// Resource-template semantics verified 2026-07-20:
// https://modelcontextprotocol.io/specification/2026-07-28/server/resources
function MatchUriTemplate(const ATemplate, AUri: string;
  out AVars: TJSONObject): Boolean;

// Prompt builders: a fresh argument list to chain onto, and message
// constructors for prompt handlers.
function PromptArguments: TMCPPromptArguments;
function MCPPromptMessage(const ARole, AText: string): TJSONObject;
function MCPUserMessage(const AText: string): TJSONObject;
function MCPAssistantMessage(const AText: string): TJSONObject;
// A prompt message carrying any content block (image, audio, resource
// link, embedded resource; see MCP.Content). Takes ownership of
// AContent; nil raises EMCPServer. ARole is 'user' or 'assistant'. In
// a prompt message an embedded resource MUST carry its mimeType
// (prompts spec, verified 2026-11-26), so pass one to MCPEmbeddedText
// and MCPEmbeddedBlob there.
function MCPContentMessage(const ARole: string;
  AContent: TJSONObject): TJSONObject;
function MCPMessages(const AMessages: array of TJSONObject): TJSONArray;

// The candidates that start with AValue, compared case-insensitively,
// in their given order: the completion a static list gives (#81).
function MCPCompleteFrom(const AValue: string;
  const ACandidates: array of string): TMCPCompletion;

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

// MCP.Content owns the content-block shapes (and the base64 encoding of
// raw-bytes payloads); the tool-result and prompt-message builders here
// wrap its blocks.
uses
  Math,

  MCP.Content,
  MCP.Crypto,
  MCP.RequestState;

var
  // Process-global diagnostic state intentionally remains outside
  // session/request state. It is shared across threads — a Streamable
  // HTTP transport dispatches from one thread per connection into the
  // same core — so the contract is: the correlation counter's
  // read-modify-write is guarded by ErrorSequenceLock (a plain
  // critical section, portable across 32- and 64-bit targets, rather
  // than a 64-bit atomic intrinsic that FPC 3.2.2 only declares for
  // cpu64). Stderr writes are serialized by MCPWriteStderrLine's own
  // lock (MCP.JSONRPC), kept separate so error-ref allocation never
  // waits on logging latency. Both are process-wide, matching the
  // lifetime of the stderr handle itself.
  ErrorSequence: Int64 = 0;
  ErrorSequenceLock: TRTLCriticalSection;

type
  TMCPRequestCancellationToken = class
  private
    FRequestId: TJSONData;
    FCancelled: Boolean;
    function Matches(ARequestId: TJSONData): Boolean;
  public
    // ARequestId is borrowed; the token owns its clone.
    constructor Create(ARequestId: TJSONData);
    destructor Destroy; override;
    function Cancel(ARequestId: TJSONData): Boolean;
    function IsCancelled: Boolean;
  end;

  TMCPLegacyIdentity = class
  public
    ProtocolVersion: string;
    ClientName: string;
    ClientVersion: string;
    ClientCapabilities: TJSONObject;
    // AClientCapabilities is borrowed until construction succeeds.
    constructor Create(const AProtocolVersion, AClientName,
      AClientVersion: string; AClientCapabilities: TJSONObject);
    destructor Destroy; override;
  end;

  // Lives for exactly one HandleMessage call. Handler contexts borrow
  // its bound notifier only while dispatch remains on the stack.
  TMCPRequestDispatch = class
  private
    FCancellationToken: TMCPRequestCancellationToken;
    FSink: TMCPLineSink;
    FSinkData: Pointer;
  public
    constructor Create(ACancellationToken: TMCPRequestCancellationToken;
      ASink: TMCPLineSink; ASinkData: Pointer);
    function IsCancelled: Boolean;
    // Takes ownership of AParams.
    procedure EmitNotification(const AMethod: string;
      AParams: TJSONObject);
  end;

constructor TMCPRequestCancellationToken.Create(ARequestId: TJSONData);
begin
  inherited Create;
  if ARequestId <> nil then
    FRequestId := ARequestId.Clone;
end;

destructor TMCPRequestCancellationToken.Destroy;
begin
  FRequestId.Free;
  inherited Destroy;
end;

function IsIntegralJSONNumber(AValue: TJSONData): Boolean;
begin
  Result := (AValue <> nil) and (AValue.JSONType = jtNumber) and
    not (AValue is TJSONFloatNumber);
end;

function TMCPRequestCancellationToken.Matches(
  ARequestId: TJSONData): Boolean;
begin
  Result := False;
  if (ARequestId = nil) or (FRequestId = nil) then
    Exit;
  if (ARequestId.JSONType = jtString) and
     (FRequestId.JSONType = jtString) then
    Exit(ARequestId.AsString = FRequestId.AsString);
  if (ARequestId.JSONType <> jtNumber) or
     (FRequestId.JSONType <> jtNumber) then
    Exit;
  if IsIntegralJSONNumber(ARequestId) and
     IsIntegralJSONNumber(FRequestId) then
    Result := ARequestId.AsInt64 = FRequestId.AsInt64
  else
    Result := ARequestId.AsFloat = FRequestId.AsFloat;
end;

function TMCPRequestCancellationToken.Cancel(
  ARequestId: TJSONData): Boolean;
begin
  Result := not FCancelled and Matches(ARequestId);
  if Result then
    FCancelled := True;
end;

function TMCPRequestCancellationToken.IsCancelled: Boolean;
begin
  Result := FCancelled;
end;

constructor TMCPLegacyIdentity.Create(const AProtocolVersion,
  AClientName, AClientVersion: string;
  AClientCapabilities: TJSONObject);
begin
  inherited Create;
  ProtocolVersion := AProtocolVersion;
  ClientName := AClientName;
  ClientVersion := AClientVersion;
  ClientCapabilities := AClientCapabilities;
end;

destructor TMCPLegacyIdentity.Destroy;
begin
  ClientCapabilities.Free;
  inherited Destroy;
end;

constructor TMCPRequestDispatch.Create(
  ACancellationToken: TMCPRequestCancellationToken;
  ASink: TMCPLineSink; ASinkData: Pointer);
begin
  inherited Create;
  FCancellationToken := ACancellationToken;
  FSink := ASink;
  FSinkData := ASinkData;
end;

function TMCPRequestDispatch.IsCancelled: Boolean;
begin
  Result := (FCancellationToken <> nil) and
    FCancellationToken.IsCancelled;
end;

procedure TMCPRequestDispatch.EmitNotification(const AMethod: string;
  AParams: TJSONObject);
var
  Line: string;
begin
  if IsCancelled then
  begin
    AParams.Free;
    Exit;
  end;
  Line := BuildNotification(AMethod, AParams);
  if Assigned(FSink) then
    FSink(Line, FSinkData);
end;

function NextErrorReference: string;
var
  Reference: Int64;
begin
  // Lock-guarded read-modify-write: concurrent connection threads must
  // never hand the same reference to two different clients. A critical
  // section (not a 64-bit atomic intrinsic) keeps this portable to the
  // i386-win32 CI target, where FPC 3.2.2 does not declare
  // InterlockedIncrement64.
  System.EnterCriticalSection(ErrorSequenceLock);
  try
    Inc(ErrorSequence);
    Reference := ErrorSequence;
  finally
    System.LeaveCriticalSection(ErrorSequenceLock);
  end;
  Result := 'mcp-err-' + IntToStr(Reference);
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
  // offset-zero stored handler is read through the record address.
  if PPointer(@Current)^ <> Pointer(SIG_DFL) then
    Exit;
  FillChar(Ignored, SizeOf(Ignored), 0);
  Ignored.sa_handler := SigActionHandler(SIG_IGN);
  FpSigAction(SIGPIPE, @Ignored, nil);
end;
{$ENDIF}

function SanitizeLogText(const AText: string): string;
begin
  Result := StringReplace(AText, #13#10, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #13, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
end;

procedure TryLogToStderr(const AMessage: string);
begin
  {$IFDEF UNIX}
  EnsureSigPipeIgnored;
  {$ENDIF}
  // MCPWriteStderrLine writes and flushes under one lock (two
  // connection threads cannot splice their text into one line and make
  // the redacted reference unreadable) and as UTF-8 under any locale
  // (#102). Logging is best effort: a closed stderr is ignored.
  try
    MCPWriteStderrLine(AMessage);
  except
    on EInOutError do
    begin
    end;
  end;
end;

{ ───────── prompt builders ───────── }

destructor TMCPPromptArgumentsCore.Destroy;
begin
  // An argument list that was never built is freed with the last
  // record copy instead of leaking.
  FList.Free;
  inherited Destroy;
end;

function PromptArguments: TMCPPromptArguments;
var
  Core: TMCPPromptArgumentsCore;
begin
  Core := TMCPPromptArgumentsCore.Create;
  Result.FCore := Core;
  Result.FLifetime := Core;
  Core.FList := TJSONArray.Create;
end;

function TMCPPromptArguments.ActiveCore: TMCPPromptArgumentsCore;
begin
  // FCore = nil covers the default record (never created through
  // PromptArguments); a nil FList on a live core means some copy
  // already called Build.
  if (FCore = nil) or (FCore.FList = nil) then
    raise EMCPServer.Create('Prompt arguments were already built');
  Result := FCore;
end;

function TMCPPromptArguments.Add(const AName: string;
  const ADescription: string; ARequired: Boolean): TMCPPromptArguments;
var
  Core: TMCPPromptArgumentsCore;
  Arg: TJSONObject;
begin
  Core := ActiveCore;
  Arg := TJSONObject.Create;
  Arg.Add('name', AName);
  if ADescription <> '' then
    Arg.Add('description', ADescription);
  if ARequired then
    Arg.Add('required', True);
  Core.FList.Add(Arg);
  Result := Self;
end;

function TMCPPromptArguments.Build: TJSONArray;
var
  Core: TMCPPromptArgumentsCore;
begin
  Core := ActiveCore;
  Result := Core.FList;
  // Consumed state is recorded on the shared core so every record
  // copy sees it.
  Core.FList := nil;
end;

function MCPContentMessage(const ARole: string;
  AContent: TJSONObject): TJSONObject;
begin
  if AContent = nil then
    raise EMCPServer.Create('MCPContentMessage: content block is nil');
  Result := TJSONObject.Create;
  Result.Add('role', ARole);
  Result.Add('content', AContent);
end;

function MCPPromptMessage(const ARole, AText: string): TJSONObject;
begin
  Result := MCPContentMessage(ARole, MCPTextContent(AText));
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

function MatchUriTemplate(const ATemplate, AUri: string;
  out AVars: TJSONObject): Boolean;
begin
  Result := MCP.UriTemplate.MatchUriTemplate(ATemplate, AUri, AVars);
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
  NotificationParams, Params: TJSONObject;
  ProgressToken: TJSONData;
begin
  if ACtx.IsCancelled or
     not (ACtx.HasProgressToken and Assigned(ACtx.Notifier)) then
    Exit;
  Params := TJSONObject.Create;
  try
    if ACtx.ProgressTokenIsString then
      Params.Add('progressToken', ACtx.ProgressToken)
    else
    begin
      ProgressToken := GetJSON(ACtx.ProgressToken);
      try
        Params.Add('progressToken', ProgressToken);
        ProgressToken := nil;
      finally
        ProgressToken.Free;
      end;
    end;
    // Compact number nodes (MCP.Schema's MCPWireNumber): fpjson's
    // default float serialization is full-precision exponent form;
    // the official SDKs put plain decimals on the wire.
    // A NaN or infinite progress or total raises EMCPSchema there (no
    // JSON form); only a finite negative total means "no total", and
    // IsNan comes first so a NaN is never compared.
    Params.Add('progress', MCPWireNumber(AProgress));
    if IsNan(ATotal) or IsInfinite(ATotal) or (ATotal >= 0) then
      Params.Add('total', MCPWireNumber(ATotal));
    if AMessage <> '' then
      Params.Add('message', AMessage);
    NotificationParams := Params;
    Params := nil;
    ACtx.Notifier('notifications/progress', NotificationParams);
  finally
    Params.Free;
  end;
end;

procedure MCPLogMessage(const ACtx: TMCPRequestContext;
  const ALevel, AData: string; const ALogger: string);
var
  NotificationParams, Params: TJSONObject;
begin
  if ACtx.IsCancelled or (ACtx.LogLevel = '') or
     not Assigned(ACtx.Notifier) then
    Exit;
  if LogSeverity(ALevel) < LogSeverity(ACtx.LogLevel) then
    Exit;
  Params := TJSONObject.Create;
  try
    Params.Add('level', ALevel);
    if ALogger <> '' then
      Params.Add('logger', ALogger);
    Params.Add('data', AData);
    NotificationParams := Params;
    Params := nil;
    ACtx.Notifier('notifications/message', NotificationParams);
  finally
    Params.Free;
  end;
end;

{ ───────── MRTR builders and accessors (#4) ───────── }

// Shared precondition for both input_required builders: the spec
// mandates at least one of inputRequests / requestState. The builders
// take ownership of AInputRequests, so the rejecting path frees it
// before raising. ABuilderName names the caller in the message.
procedure EnsureInputRequiredPayload(AInputRequests: TJSONObject;
  const ARequestState, ABuilderName: string);
begin
  if ((AInputRequests = nil) or (AInputRequests.Count = 0)) and
     (ARequestState = '') then
  begin
    AInputRequests.Free;
    raise EMCPServer.Create(ABuilderName +
      ' requires inputRequests or a requestState ' +
      '(the spec mandates at least one)');
  end;
end;

function MCPInputRequired(AInputRequests: TJSONObject;
  const ARequestState: string): TMCPToolResult;
begin
  EnsureInputRequiredPayload(AInputRequests, ARequestState,
    'MCPInputRequired');
  Result := Default(TMCPToolResult);
  Result.InputRequired := True;
  Result.InputRequests := AInputRequests;
  Result.RequestState := ARequestState;
end;

function MCPPromptMessagesResult(AMessages: TJSONArray): TMCPPromptResult;
begin
  Result := Default(TMCPPromptResult);
  Result.Messages := AMessages;
end;

function MCPPromptInputRequired(AInputRequests: TJSONObject;
  const ARequestState: string): TMCPPromptResult;
begin
  EnsureInputRequiredPayload(AInputRequests, ARequestState,
    'MCPPromptInputRequired');
  Result := Default(TMCPPromptResult);
  Result.InputRequired := True;
  Result.InputRequests := AInputRequests;
  Result.RequestState := ARequestState;
end;

function EmbeddedRequest(const AMethod: string;
  AParams: TJSONObject): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('method', AMethod);
  if AParams <> nil then
    Result.Add('params', AParams);
end;

function MCPElicitFormRequest(const AMessage: string;
  ARequestedSchema: TJSONObject): TJSONObject;
var
  Params: TJSONObject;
begin
  Params := TJSONObject.Create;
  try
    Params.Add('mode', 'form');
    Params.Add('message', AMessage);
    Params.Add('requestedSchema', ARequestedSchema);
    ARequestedSchema := nil;
  except
    Params.Free;
    ARequestedSchema.Free;
    raise;
  end;
  Result := EmbeddedRequest('elicitation/create', Params);
end;

function MCPElicitFormRequest(const AMessage: string;
  constref ASchema: TMCPSchema): TJSONObject;
begin
  Result := MCPElicitFormRequest(AMessage, ASchema.Build);
end;

function MCPElicitURLRequest(const AMessage, AUrl: string): TJSONObject;
var
  Params: TJSONObject;
begin
  Params := TJSONObject.Create;
  Params.Add('mode', 'url');
  Params.Add('message', AMessage);
  Params.Add('url', AUrl);
  Result := EmbeddedRequest('elicitation/create', Params);
end;

function MCPSamplingRequest(ASamplingParams: TJSONObject): TJSONObject;
begin
  Result := EmbeddedRequest('sampling/createMessage', ASamplingParams);
end;

function MCPSamplingTextRequest(const APrompt: string;
  AMaxTokens: Integer): TJSONObject;
var
  Params, Message, Content: TJSONObject;
  Messages: TJSONArray;
begin
  Content := TJSONObject.Create;
  Content.Add('type', 'text');
  Content.Add('text', APrompt);
  Message := TJSONObject.Create;
  Message.Add('role', 'user');
  Message.Add('content', Content);
  Messages := TJSONArray.Create;
  Messages.Add(Message);
  Params := TJSONObject.Create;
  Params.Add('messages', Messages);
  Params.Add('maxTokens', AMaxTokens);
  Result := EmbeddedRequest('sampling/createMessage', Params);
end;

function MCPRootsRequest: TJSONObject;
begin
  Result := EmbeddedRequest('roots/list', nil);
end;

function MCPInputResponse(const ACtx: TMCPRequestContext;
  const AKey: string): TJSONObject;
var
  Data: TJSONData;
begin
  Result := nil;
  if ACtx.InputResponses = nil then
    Exit;
  Data := ACtx.InputResponses.Find(AKey);
  if (Data <> nil) and (Data.JSONType = jtObject) then
    Result := TJSONObject(Data);
end;

function MCPElicitationContent(const ACtx: TMCPRequestContext;
  const AKey: string): TJSONObject;
var
  Response: TJSONObject;
  ContentData: TJSONData;
begin
  Result := nil;
  Response := MCPInputResponse(ACtx, AKey);
  if (Response = nil) or (Response.Get('action', '') <> 'accept') then
    Exit;
  ContentData := Response.Find('content');
  if (ContentData <> nil) and (ContentData.JSONType = jtObject) then
    Result := TJSONObject(ContentData);
end;

// The client capability each embedded request kind requires. '' for
// an unrecognized kind (rejected separately — the library only emits
// the three MRTR kinds).
function CapabilityForInputRequest(const AMethod: string): string;
begin
  if AMethod = 'elicitation/create' then
    Result := 'elicitation'
  else if AMethod = 'sampling/createMessage' then
    Result := 'sampling'
  else if AMethod = 'roots/list' then
    Result := 'roots'
  else
    Result := '';
end;

// '' when every inputRequests entry names a kind the client declared;
// otherwise the first missing capability. AUnknownKind carries the
// method of an entry that is not an MRTR kind at all, and stays
// non-empty for a malformed entry too — one that is not an object, or
// carries no string "method" — so callers can keep testing it with a
// single `<> ''` guard and never emit such a map on the wire.
function MissingInputCapability(AInputRequests: TJSONObject;
  const ACtx: TMCPRequestContext; out AUnknownKind: string): string;
var
  I: Integer;
  Entry, MethodData: TJSONData;
  Method, Capability: string;
begin
  Result := '';
  AUnknownKind := '';
  if AInputRequests = nil then
    Exit;
  for I := 0 to AInputRequests.Count - 1 do
  begin
    Entry := AInputRequests.Items[I];
    Method := '';
    if Entry.JSONType = jtObject then
    begin
      MethodData := TJSONObject(Entry).Find('method');
      if (MethodData <> nil) and (MethodData.JSONType = jtString) then
        Method := MethodData.AsString;
    end;
    Capability := CapabilityForInputRequest(Method);
    if Capability = '' then
    begin
      // A malformed entry has no method to quote back; the placeholder
      // keeps the unknown-kind signal distinguishable from success.
      if Method = '' then
        AUnknownKind := '(missing method)'
      else
        AUnknownKind := Method;
      Exit;
    end;
    if not ACtx.HasCapability(Capability) then
      Exit(Capability);
  end;
end;

{ ───────── handler-raised protocol errors (#88) ───────── }

function IsAllowedHandlerErrorCode(ACode: Integer): Boolean;
begin
  case ACode of
    JSONRPC_PARSE_ERROR, JSONRPC_INVALID_REQUEST, JSONRPC_METHOD_NOT_FOUND,
    JSONRPC_INVALID_PARAMS, JSONRPC_INTERNAL_ERROR,
    MCP_ERROR_MISSING_CLIENT_CAPABILITY:
      Result := True;
  else
    Result := (ACode < -32768) or (ACode > -32000);
  end;
end;

constructor EMCPProtocolError.Create(ACode: Integer; const AMessage: string;
  AData: TJSONData);
begin
  // Own AData first, so every rejection below frees it: an exception in
  // a constructor runs the destructor.
  inherited Create(AMessage);
  FCode := ACode;
  FData := AData;
  if not IsAllowedHandlerErrorCode(ACode) then
    raise EMCPServer.CreateFmt('EMCPProtocolError code %d is reserved: ' +
      'use a JSON-RPC code (-32700, -32600 to -32603), -32021, or an ' +
      'application code outside -32768..-32000', [ACode]);
  if (ACode = MCP_ERROR_MISSING_CLIENT_CAPABILITY) and
    not IsMissingCapabilityData(AData) then
    raise EMCPServer.Create('EMCPProtocolError -32021 needs data whose ' +
      'requiredCapabilities names at least one capability, each shaped ' +
      'as in ClientCapabilities; use MCPMissingCapabilityError');
end;

destructor EMCPProtocolError.Destroy;
begin
  FData.Free;
  inherited Destroy;
end;

function EMCPProtocolError.TakeData: TJSONData;
begin
  Result := FData;
  FData := nil;
end;

function MCPMissingCapabilityError(const ACapability: string): EMCPProtocolError;
begin
  Result := EMCPProtocolError.Create(MCP_ERROR_MISSING_CLIENT_CAPABILITY,
    'Missing required client capability: ' + ACapability,
    BuildMissingCapabilityData(ACapability));
end;

function MCPTextResult(const AText: string): TMCPToolResult;
begin
  Result := Default(TMCPToolResult);
  Result.Content := TJSONArray.Create;
  Result.Content.Add(MCPTextContent(AText));
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

function MCPStructuredResult(AStructured: TJSONData): TMCPToolResult;
var
  Text: string;
begin
  if AStructured = nil then
    raise EMCPServer.Create('MCPStructuredResult: structured value is nil');
  // Owned from here: freed if serializing it raises.
  try
    Text := SerializeCompact(AStructured);
  except
    AStructured.Free;
    raise;
  end;
  Result := MCPStructuredResult(Text, AStructured);
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

function MCPImageResult(const ABase64, AMimeType: string): TMCPToolResult;
begin
  Result := Default(TMCPToolResult);
  Result.Content := TJSONArray.Create;
  Result.Content.Add(MCPImageContent(ABase64, AMimeType));
end;

function MCPImageResult(const AData: TBytes;
  const AMimeType: string): TMCPToolResult;
begin
  Result := MCPImageResult(MCPBase64(AData), AMimeType);
end;

function MCPAudioResult(const ABase64, AMimeType: string): TMCPToolResult;
begin
  Result := MCPContentResult([MCPAudioContent(ABase64, AMimeType)]);
end;

function MCPAudioResult(const AData: TBytes;
  const AMimeType: string): TMCPToolResult;
begin
  Result := MCPContentResult([MCPAudioContent(AData, AMimeType)]);
end;

// Frees every distinct non-nil block of ABlocks once.
procedure FreeDistinctBlocks(const ABlocks: array of TJSONObject);
var
  I, J: Integer;
  Seen: Boolean;
begin
  for I := 0 to High(ABlocks) do
  begin
    Seen := ABlocks[I] = nil;
    for J := 0 to I - 1 do
      if ABlocks[J] = ABlocks[I] then
        Seen := True;
    if not Seen then
      ABlocks[I].Free;
  end;
end;

function MCPContentResult(const ABlocks: array of TJSONObject): TMCPToolResult;
var
  I, J: Integer;
begin
  // Checked before anything is adopted, so a rejected call leaves no
  // half-built result: the blocks are freed (they were handed over)
  // and EMCPServer raised. A nil block would serialize as null, and a
  // repeated one is rejected by fpjson part-way through.
  for I := 0 to High(ABlocks) do
  begin
    if ABlocks[I] = nil then
    begin
      FreeDistinctBlocks(ABlocks);
      raise EMCPServer.CreateFmt('MCPContentResult: block %d is nil', [I]);
    end;
    for J := 0 to I - 1 do
      if ABlocks[J] = ABlocks[I] then
      begin
        FreeDistinctBlocks(ABlocks);
        raise EMCPServer.CreateFmt(
          'MCPContentResult: block %d repeats block %d', [I, J]);
      end;
  end;
  Result := Default(TMCPToolResult);
  Result.Content := TJSONArray.Create;
  for I := 0 to High(ABlocks) do
    Result.Content.Add(ABlocks[I]);
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

{ ───────── TMCPSession: legacy lifecycle ───────── }

constructor TMCPSession.Create(AOwner: TMCPServer);
begin
  inherited Create;
  FOwner := AOwner;
  FLegacyState := lsNew;
end;

destructor TMCPSession.Destroy;
begin
  FLegacyIdentity.Free;
  inherited Destroy;
end;

function TMCPSession.BeginRequest(ARequestId: TJSONData): TObject;
var
  Token: TMCPRequestCancellationToken;
begin
  // Clone/conversion work may raise, so do it before arming the session.
  Token := TMCPRequestCancellationToken.Create(ARequestId);
  FCurrentRequestToken := Token;
  Result := Token;
end;

procedure TMCPSession.EndRequest(AToken: TObject);
begin
  if FCurrentRequestToken = AToken then
    FCurrentRequestToken := nil;
end;

function TMCPSession.TryCancelRequest(ARequestId: TJSONData): Boolean;
begin
  Result := (FCurrentRequestToken <> nil) and
    TMCPRequestCancellationToken(FCurrentRequestToken).Cancel(ARequestId);
end;

procedure TMCPSession.CancelRequest(ARequestId: TJSONData);
begin
  TryCancelRequest(ARequestId);
end;

procedure TMCPSession.CompleteLegacyInitialize;
begin
  if FLegacyState = lsAwaitingInitialized then
    FLegacyState := lsReady;
end;

procedure TMCPSession.CommitLegacyInitialize(const AProtocolVersion,
  AClientName, AClientVersion: string;
  AClientCapabilities: TJSONObject);
var
  NewIdentity, OldIdentity: TMCPLegacyIdentity;
  OwnedCapabilities: TJSONObject;
begin
  OwnedCapabilities := AClientCapabilities;
  NewIdentity := nil;
  try
    NewIdentity := TMCPLegacyIdentity.Create(AProtocolVersion,
      AClientName, AClientVersion, OwnedCapabilities);
    OwnedCapabilities := nil;
    OldIdentity := TMCPLegacyIdentity(FLegacyIdentity);
    FLegacyIdentity := NewIdentity;
    NewIdentity := nil;
    FLegacyState := lsAwaitingInitialized;
    OldIdentity.Free;
  finally
    NewIdentity.Free;
    OwnedCapabilities.Free;
  end;
end;

function TMCPSession.LegacyContext(
  AParams: TJSONObject): TMCPRequestContext;
var
  Identity: TMCPLegacyIdentity;
  MetaData: TJSONData;
begin
  Result := Default(TMCPRequestContext);
  Identity := TMCPLegacyIdentity(FLegacyIdentity);
  Result.ProtocolVersion := Identity.ProtocolVersion;
  Result.ClientName := Identity.ClientName;
  Result.ClientVersion := Identity.ClientVersion;
  // Borrowed from the session for this synchronous handler call.
  Result.ClientCapabilities := Identity.ClientCapabilities;
  // progressToken is per-request in every era.
  if AParams <> nil then
  begin
    MetaData := AParams.Find('_meta');
    if (MetaData <> nil) and (MetaData.JSONType = jtObject) then
      ExtractProgressToken(TJSONObject(MetaData), Result);
  end;
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
  FFrozen := False;
  FRequestStateTtlMs := 600000;
end;

procedure TMCPServer.EnsureMutable;
begin
  if FFrozen then
    raise EMCPServer.Create(
      'Server configuration is frozen after session creation');
end;

{ ───────── subset schema validation (#23) ───────── }

// The sealer for AKeys, or for one random 32-byte key when none were
// configured. A missing random source fails closed: the server does not
// start rather than seal with a guessable key.
function CreateSealer(const AName: string; const AKeys: array of RawByteString;
  ATtlMs: Integer): TMCPRequestStateSealer;
begin
  try
    if Length(AKeys) > 0 then
      Result := TMCPRequestStateSealer.Create(AName, AKeys, ATtlMs)
    else
      Result := TMCPRequestStateSealer.Create(AName,
        [SecureRandomBytes(32)], ATtlMs);
  except
    on E: EMCPCrypto do
      raise EMCPServer.Create('Cannot set up requestState sealing: ' +
        E.Message);
  end;
end;

procedure TMCPServer.SetRequestStateKeys(const AKeys: array of RawByteString);
var
  I: Integer;
begin
  EnsureMutable;
  for I := 0 to High(AKeys) do
    if Length(AKeys[I]) < 32 then
      raise EMCPServer.CreateFmt('requestState key %d is %d bytes; ' +
        'each key must be at least 32 bytes', [I, Length(AKeys[I])]);
  SetLength(FRequestStateKeys, Length(AKeys));
  for I := 0 to High(AKeys) do
    FRequestStateKeys[I] := AKeys[I];
end;

procedure TMCPServer.SetRequestStateTtlMs(AValue: Integer);
begin
  EnsureMutable;
  if AValue <= 0 then
    raise EMCPServer.Create('RequestStateTtlMs must be positive');
  FRequestStateTtlMs := AValue;
end;

// The request's arguments object, or nil.
function RequestArguments(const AMessage: TJSONRPCMessage): TJSONObject;
var
  Data: TJSONData;
begin
  Result := nil;
  if AMessage.Params = nil then
    Exit;
  Data := AMessage.Params.Find('arguments');
  if (Data <> nil) and (Data.JSONType = jtObject) then
    Result := TJSONObject(Data);
end;

function TMCPServer.OpenRequestState(const AMessage: TJSONRPCMessage;
  var ACtx: TMCPRequestContext): Boolean;
var
  State, Reason: string;
begin
  Result := TMCPRequestStateSealer(FSealer).Unseal(AMessage.Method,
    AMessage.Params.Get('name', ''), RequestArguments(AMessage),
    ACtx.RequestState, State, Reason);
  if Result then
    ACtx.RequestState := State
  else
    // The reason stays off the wire: it would tell an attacker which
    // check to aim at next.
    TryLogToStderr('MCP requestState rejected on ' + AMessage.Method + ': ' +
      Reason);
end;

procedure TMCPServer.FreezeConfiguration;
var
  I: Integer;
  Violation: string;
  InputSchema, OutputSchema: TJSONData;
begin
  if FFrozen then
    Exit;
  // Subset conformance is decided here rather than at RegisterTool so
  // the fluent .ApplicationValidated mark — which runs after
  // RegisterTool returns — is visible (#23). A raw-handler tool whose
  // schema leaves the subset without the mark fails startup, matching
  // the fail-fast registration guards.
  for I := 0 to High(FTools) do
    if FTools[I].ArgsClass = nil then
    begin
      InputSchema := FTools[I].Definition.Find('inputSchema');
      Violation := MCPSchemaSubsetViolation(TJSONObject(InputSchema), True);
      if Violation = '' then
        FTools[I].SubsetValidate := not FTools[I].AppValidated
      else if not FTools[I].AppValidated then
        raise EMCPServer.CreateFmt(
          'Tool "%s" inputSchema %s — outside the server-validated ' +
          'subset (type/properties/required/items/enum/default). Mark ' +
          'the registration .ApplicationValidated to take over argument ' +
          'validation', [FTools[I].Definition.Get('name', ''), Violation]);
    end;
  FSealer := CreateSealer(FName, FRequestStateKeys, FRequestStateTtlMs);
  // Structured output is checked whenever the output schema is inside
  // the subset (#91); a richer one is the handler's to honour.
  for I := 0 to High(FTools) do
  begin
    OutputSchema := FTools[I].Definition.Find('outputSchema');
    FTools[I].OutputValidate := (OutputSchema <> nil) and
      (MCPSchemaSubsetViolation(TJSONObject(OutputSchema), False) = '');
    MCPHeaderParameters(TJSONObject(FTools[I].Definition.Find(
      'inputSchema')), FTools[I].HeaderParams);
  end;
  FFrozen := True;
end;

function TMCPServer.CreateSession: TMCPSession;
var
  Session: TMCPSession;
begin
  Session := TMCPSession.Create(Self);
  try
    FreezeConfiguration;
    Result := Session;
    Session := nil;
  finally
    Session.Free;
  end;
end;

procedure TMCPServer.SetInstructions(const AValue: string);
begin
  EnsureMutable;
  FInstructions := AValue;
end;

procedure TMCPServer.SetCacheTtlMs(AValue: Integer);
begin
  EnsureMutable;
  if AValue < 0 then
    raise EMCPServer.Create('CacheTtlMs must not be negative');
  FCacheTtlMs := AValue;
end;

procedure TMCPServer.SetCacheScope(const AValue: string);
begin
  EnsureMutable;
  if (AValue <> CACHE_SCOPE_PRIVATE) and
     (AValue <> CACHE_SCOPE_PUBLIC) then
    raise EMCPServer.CreateFmt(
      'CacheScope must be "%s" or "%s"',
      [CACHE_SCOPE_PRIVATE, CACHE_SCOPE_PUBLIC]);
  FCacheScope := AValue;
end;

procedure TMCPServer.SetRedactErrorDetails(AValue: Boolean);
begin
  EnsureMutable;
  FRedactErrorDetails := AValue;
end;

procedure TMCPServer.SetDualEra(AValue: Boolean);
begin
  EnsureMutable;
  FDualEra := AValue;
end;

function TMCPServer.ExceptionClientMessage(const ASite, AVerbosePrefix,
  ARedactedMessage: string; E: Exception): string;
var
  ErrorReference: string;
begin
  if not FRedactErrorDetails then
    Exit(AVerbosePrefix + E.Message);
  ErrorReference := NextErrorReference;
  TryLogToStderr(ErrorReference + ' ' + ASite + ': ' + E.ClassName + ': ' +
    SanitizeLogText(E.Message));
  Result := ARedactedMessage + ' (ref ' + ErrorReference + ')';
end;

// The response for a handler's EMCPProtocolError (#88). Its data is
// borrowed until here, so a -32021 whose data a handler changed after
// construction is checked again and, if it no longer validates, sent
// as -32603 rather than as a refusal clients would reject.
function TMCPServer.ProtocolErrorResponse(AMessage: TJSONRPCMessage;
  E: Exception): string;
var
  Err: EMCPProtocolError;
begin
  Err := E as EMCPProtocolError;
  if (Err.Code = MCP_ERROR_MISSING_CLIENT_CAPABILITY) and
    not IsMissingCapabilityData(Err.Data) then
  begin
    TryLogToStderr('dispatch/' + AMessage.Method + ': -32021 data no ' +
      'longer names valid requiredCapabilities; sent as -32603');
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INTERNAL_ERROR,
      'Internal error'));
  end;
  Result := BuildErrorResponse(AMessage.Id, Err.Code, Err.Message,
    Err.TakeData);
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
  FSealer.Free;
  inherited Destroy;
end;

// The capability objects stay empty: no listChanged / subscribe —
// registries are fixed after startup, so there is nothing to notify.
// Shared by server/discover (modern) and initialize (legacy).
// Each capability is declared when the server offers something under
// it ("Present if the server offers any tools to call", schema
// ServerCapabilities, verified 2026-11-26 against
// https://modelcontextprotocol.io/specification/2026-07-28/schema#servercapabilities),
// so a client does not list what is not there.
function TMCPServer.ServerCapabilities: TJSONObject;
begin
  Result := TJSONObject.Create;
  try
    if Length(FTools) > 0 then
      Result.Add('tools', TJSONObject.Create);
    if (Length(FResources) > 0) or (Length(FTemplates) > 0) then
      Result.Add('resources', TJSONObject.Create);
    if Length(FPrompts) > 0 then
      Result.Add('prompts', TJSONObject.Create);
    if Length(FCompletions) > 0 then
      Result.Add('completions', TJSONObject.Create);
  except
    Result.Free;
    raise;
  end;
end;

{ ───────── completion (#81) ───────── }

function MCPCompleteFrom(const AValue: string;
  const ACandidates: array of string): TMCPCompletion;
begin
  Result := MCP.Completion.MCPCompleteFrom(AValue, ACandidates);
end;

function TMCPServer.FindTemplate(const AUriTemplate: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FTemplates) do
    if FTemplates[I].UriTemplate = AUriTemplate then
      Exit(I);
  Result := -1;
end;

// '' when ARefType/ARefName name a registered prompt or template that
// has AArgument, otherwise what is wrong (MCP.Completion decides).
function CompletionTargetProblem(AServer: TMCPServer; const ARefType,
  ARefName, AArgument: string): string;
var
  Index: Integer;
  Definition: TJSONObject;
begin
  Definition := nil;
  if ARefType = 'ref/prompt' then
  begin
    Index := AServer.FindPrompt(ARefName);
    if Index >= 0 then
      Definition := AServer.FPrompts[Index].Definition;
  end;
  Result := CompletionTargetFault(ARefType, ARefName, AArgument, Definition,
    AServer.FindTemplate(ARefName) >= 0);
end;

function TMCPServer.FindCompletion(const ARefType, ARefName,
  AArgument: string): Integer;
begin
  for Result := 0 to High(FCompletions) do
    if (FCompletions[Result].RefType = ARefType) and
      (FCompletions[Result].RefName = ARefName) and
      (FCompletions[Result].Argument = AArgument) then
      Exit;
  Result := -1;
end;

procedure TMCPServer.AddCompletion(const ARefType, ARefName,
  AArgument: string; const AValues: array of string; ACallable: Boolean;
  AHandler: TMCPCompletionHandler; AMethod: TMCPCompletionMethod);
var
  Problem: string;
  I, Slot: Integer;
begin
  EnsureMutable;
  Problem := CompletionTargetProblem(Self, ARefType, ARefName, AArgument);
  if Problem <> '' then
    raise EMCPServer.Create('Cannot register a completion: ' + Problem);
  if ACallable and not Assigned(AHandler) and not Assigned(AMethod) then
    raise EMCPServer.CreateFmt('The completion for "%s" of "%s" needs a ' +
      'non-nil callable', [AArgument, ARefName]);
  if FindCompletion(ARefType, ARefName, AArgument) >= 0 then
    raise EMCPServer.CreateFmt('A completion for "%s" of "%s" is ' +
      'already registered', [AArgument, ARefName]);
  Slot := Length(FCompletions);
  SetLength(FCompletions, Slot + 1);
  FCompletions[Slot].RefType := ARefType;
  FCompletions[Slot].RefName := ARefName;
  FCompletions[Slot].Argument := AArgument;
  SetLength(FCompletions[Slot].Values, Length(AValues));
  for I := 0 to High(AValues) do
    FCompletions[Slot].Values[I] := AValues[I];
  FCompletions[Slot].Handler := AHandler;
  FCompletions[Slot].Method := AMethod;
end;

procedure TMCPServer.RegisterPromptCompletion(const APrompt, AArgument: string;
  const AValues: array of string);
begin
  AddCompletion('ref/prompt', APrompt, AArgument, AValues, False, nil, nil);
end;

procedure TMCPServer.RegisterPromptCompletion(const APrompt, AArgument: string;
  AHandler: TMCPCompletionHandler);
begin
  AddCompletion('ref/prompt', APrompt, AArgument, [], True, AHandler, nil);
end;

procedure TMCPServer.RegisterPromptCompletion(const APrompt, AArgument: string;
  AMethod: TMCPCompletionMethod);
begin
  AddCompletion('ref/prompt', APrompt, AArgument, [], True, nil, AMethod);
end;

procedure TMCPServer.RegisterTemplateCompletion(const AUriTemplate,
  AVariable: string; const AValues: array of string);
begin
  AddCompletion('ref/resource', AUriTemplate, AVariable, AValues, False, nil,
    nil);
end;

procedure TMCPServer.RegisterTemplateCompletion(const AUriTemplate,
  AVariable: string; AHandler: TMCPCompletionHandler);
begin
  AddCompletion('ref/resource', AUriTemplate, AVariable, [], True, AHandler,
    nil);
end;

procedure TMCPServer.RegisterTemplateCompletion(const AUriTemplate,
  AVariable: string; AMethod: TMCPCompletionMethod);
begin
  AddCompletion('ref/resource', AUriTemplate, AVariable, [], True, nil,
    AMethod);
end;

// completion/complete: verified 2026-11-26 against
// https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/completion
// (unknown prompt or missing argument: -32602).
function TMCPServer.HandleComplete(const AMessage: TJSONRPCMessage;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): string;
var
  Request: TMCPCompleteRequest;
  Problem: string;
  Completion: TMCPCompletion;
  I: Integer;
  CompleteResult: TJSONObject;
begin
  // Without a registration the server declares no completions
  // capability, so the method is not supported: -32601, as the
  // completion page's error handling recommends (verified 2026-11-27,
  // .../server/utilities/completion#error-handling).
  if Length(FCompletions) = 0 then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_METHOD_NOT_FOUND,
      'Method not found: completion/complete (no completions registered)'));
  Problem := ParseCompleteRequest(AMessage.Params, Request);
  if Problem = '' then
  begin
    Problem := CompletionTargetProblem(Self, Request.RefType,
      Request.RefName, Request.Argument);
    if Problem <> '' then
      Problem := 'Invalid params: ' + Problem;
  end;
  if Problem <> '' then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS, Problem));

  // An argument with no completion registered answers an empty list.
  I := FindCompletion(Request.RefType, Request.RefName, Request.Argument);
  if I < 0 then
    Completion := MCPCompleteFrom(Request.Value, [])
  else if Assigned(FCompletions[I].Method) then
    Completion := FCompletions[I].Method(Request.Argument, Request.Value,
      Request.Context, ACtx)
  else if Assigned(FCompletions[I].Handler) then
    Completion := FCompletions[I].Handler(Request.Argument, Request.Value,
      Request.Context, ACtx)
  else
    Completion := MCPCompleteFrom(Request.Value, FCompletions[I].Values);

  CompleteResult := TJSONObject.Create;
  CompleteResult.Add('completion', CompletionObject(Completion));
  Result := ResultResponse(AMessage, CompleteResult, ALegacy);
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
  EnsureMutable;
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

procedure TMCPServer.MarkToolApplicationValidated(ADefinition: TJSONObject);
var
  I: Integer;
begin
  for I := 0 to High(FTools) do
    if FTools[I].Definition = ADefinition then
    begin
      FTools[I].AppValidated := True;
      Exit;
    end;
  raise EMCPServer.Create(
    'ApplicationValidated: tool registration not found');
end;

procedure TMCPServer.ValidateToolDefinition(ADefinition: TJSONObject;
  out AToolName: string);
var
  InputSchema, OutputSchema, SchemaType: TJSONData;
  HeaderParams: TMCPHeaderParameters;
  Violation: string;
begin
  if ADefinition = nil then
    raise EMCPServer.Create('Tool definition must not be nil');
  AToolName := ADefinition.Get('name', '');
  if AToolName = '' then
    raise EMCPServer.Create('Tool definition must carry a non-empty name');
  // Tool.inputSchema is a required JSON Schema object:
  // https://modelcontextprotocol.io/specification/2026-07-28/server/tools
  // https://modelcontextprotocol.io/specification/2026-07-28/schema
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
    // Any root type since SEP-2106 (tools#structured-content, verified
    // 2026-11-26); the schema itself is still a JSON object.
    if OutputSchema.JSONType <> jtObject then
      raise EMCPServer.CreateFmt(
        'Tool "%s" definition must carry an object-valued outputSchema',
        [AToolName]);
  end;
  // x-mcp-header annotations a client would reject make it drop the
  // whole tool, so they fail here instead (#90).
  Violation := MCPHeaderParameters(TJSONObject(InputSchema), HeaderParams);
  if Violation <> '' then
    raise EMCPServer.CreateFmt('Tool "%s" inputSchema: %s',
      [AToolName, Violation]);
  if FindTool(AToolName) >= 0 then
    raise EMCPServer.CreateFmt(
      'Tool "%s" is already registered', [AToolName]);
end;

// Replaces every child stored as nil (which fpjson writes as null but
// cannot clone, FPC 3.2.2) with a JSON null, so a definition can be
// cloned for every tools/list.
procedure NilChildrenToNull(AData: TJSONData);
var
  I: Integer;
begin
  if (AData = nil) or not (AData.JSONType in [jtObject, jtArray]) then
    Exit;
  for I := 0 to AData.Count - 1 do
    if AData.Items[I] = nil then
      AData.Items[I] := TJSONNull.Create
    else
      NilChildrenToNull(AData.Items[I]);
end;

function TMCPServer.AddTool(ADefinition: TJSONObject;
  AHandler: TMCPToolHandler; AMethod: TMCPToolMethod): TMCPToolOptions;
var
  ToolName: string;
begin
  try
    EnsureMutable;
    NilChildrenToNull(ADefinition);
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
  Result.FServer := Self;
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
  FServer.EnsureMutable;
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
  FServer.EnsureMutable;
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

function TMCPToolOptions.ApplicationValidated: TMCPToolOptions;
begin
  FServer.EnsureMutable;
  FServer.MarkToolApplicationValidated(FDefinition);
  Result := Self;
end;

function TMCPToolOptions.RequiresClientCapability(
  const AName: string): TMCPToolOptions;
var
  Index, Slot: Integer;
begin
  FServer.EnsureMutable;
  if AName = '' then
    raise EMCPServer.Create('RequiresClientCapability needs a capability name');
  Index := FServer.FindTool(FDefinition.Get('name', ''));
  Slot := Length(FServer.FTools[Index].RequiredCapabilities);
  SetLength(FServer.FTools[Index].RequiredCapabilities, Slot + 1);
  FServer.FTools[Index].RequiredCapabilities[Slot] := AName;
  Result := Self;
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
    EnsureMutable;
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
  Result.FServer := Self;
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

// Two-schema assembly for the overloads that build an output schema
// too. AInputSchema is already built and owned by this function on
// entry — building an output schema can raise (TMCPSchema.Build is
// consuming, SchemaFromArgumentClass rejects nil/unmappable classes),
// and the input tree would otherwise leak. Callers pass the input
// build as an argument, so a raise there happens before the call and
// leaves nothing allocated.
function PairedSchemaDefinition(const AName, ADescription: string;
  AInputSchema: TJSONObject;
  constref AOutputSchema: TMCPSchema): TJSONObject;
var
  OutputSchema: TJSONObject;
begin
  try
    OutputSchema := AOutputSchema.Build;
  except
    AInputSchema.Free;
    raise;
  end;
  Result := SchemaDefinition(AName, ADescription, AInputSchema, OutputSchema);
end;

// As PairedSchemaDefinition, for the overloads whose output schema is
// derived from an argument class rather than a fluent schema.
function PairedClassDefinition(const AName, ADescription: string;
  AInputSchema: TJSONObject; AOutputClass: TMCPArgsClass): TJSONObject;
var
  OutputSchema: TJSONObject;
begin
  try
    OutputSchema := SchemaFromArgumentClass(AName, 'output', AOutputClass);
  except
    AInputSchema.Free;
    raise;
  end;
  Result := SchemaDefinition(AName, ADescription, AInputSchema, OutputSchema);
end;

function TMCPServer.RegisterTool(const AName, ADescription: string;
  constref AInputSchema: TMCPSchema; AHandler: TMCPToolHandler): TMCPToolOptions;
begin
  EnsureMutable;
  Result := AddTool(SchemaDefinition(AName, ADescription, AInputSchema.Build, nil),
    AHandler, nil);
end;

function TMCPServer.RegisterTool(const AName, ADescription: string;
  constref AInputSchema: TMCPSchema; AMethod: TMCPToolMethod): TMCPToolOptions;
begin
  EnsureMutable;
  Result := AddTool(SchemaDefinition(AName, ADescription, AInputSchema.Build, nil),
    nil, AMethod);
end;

function TMCPServer.RegisterTool(const AName, ADescription: string;
  constref AInputSchema, AOutputSchema: TMCPSchema; AHandler: TMCPToolHandler): TMCPToolOptions;
begin
  EnsureMutable;
  Result := AddTool(PairedSchemaDefinition(AName, ADescription,
    AInputSchema.Build, AOutputSchema), AHandler, nil);
end;

function TMCPServer.RegisterTool(const AName, ADescription: string;
  constref AInputSchema, AOutputSchema: TMCPSchema; AMethod: TMCPToolMethod): TMCPToolOptions;
begin
  EnsureMutable;
  Result := AddTool(PairedSchemaDefinition(AName, ADescription,
    AInputSchema.Build, AOutputSchema), nil, AMethod);
end;

function TMCPServer.RegisterTool(const AName, ADescription: string;
  AArgsClass: TMCPArgsClass; AHandler: TMCPArgsHandler): TMCPToolOptions;
begin
  EnsureMutable;
  Result := AddTypedTool(SchemaDefinition(AName, ADescription,
    SchemaFromArgumentClass(AName, 'input', AArgsClass), nil),
    AArgsClass, AHandler, nil);
end;

function TMCPServer.RegisterTool(const AName, ADescription: string;
  AArgsClass: TMCPArgsClass; AMethod: TMCPArgsMethod): TMCPToolOptions;
begin
  EnsureMutable;
  Result := AddTypedTool(SchemaDefinition(AName, ADescription,
    SchemaFromArgumentClass(AName, 'input', AArgsClass), nil),
    AArgsClass, nil, AMethod);
end;

function TMCPServer.RegisterTool(const AName, ADescription: string;
  AArgsClass: TMCPArgsClass; constref AOutputSchema: TMCPSchema;
  AHandler: TMCPArgsHandler): TMCPToolOptions;
begin
  EnsureMutable;
  Result := AddTypedTool(PairedSchemaDefinition(AName, ADescription,
    SchemaFromArgumentClass(AName, 'input', AArgsClass), AOutputSchema),
    AArgsClass, AHandler, nil);
end;

function TMCPServer.RegisterTool(const AName, ADescription: string;
  AArgsClass: TMCPArgsClass; constref AOutputSchema: TMCPSchema;
  AMethod: TMCPArgsMethod): TMCPToolOptions;
begin
  EnsureMutable;
  Result := AddTypedTool(PairedSchemaDefinition(AName, ADescription,
    SchemaFromArgumentClass(AName, 'input', AArgsClass), AOutputSchema),
    AArgsClass, nil, AMethod);
end;

function TMCPServer.RegisterTool(const AName, ADescription: string;
  AArgsClass, AOutputClass: TMCPArgsClass; AHandler: TMCPArgsHandler): TMCPToolOptions;
begin
  EnsureMutable;
  Result := AddTypedTool(PairedClassDefinition(AName, ADescription,
    SchemaFromArgumentClass(AName, 'input', AArgsClass), AOutputClass),
    AArgsClass, AHandler, nil);
end;

function TMCPServer.RegisterTool(const AName, ADescription: string;
  AArgsClass, AOutputClass: TMCPArgsClass; AMethod: TMCPArgsMethod): TMCPToolOptions;
begin
  EnsureMutable;
  Result := AddTypedTool(PairedClassDefinition(AName, ADescription,
    SchemaFromArgumentClass(AName, 'input', AArgsClass), AOutputClass),
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
  EnsureMutable;
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

function TMCPServer.ToolHeaderParameters(
  const AName: string): TMCPHeaderParameters;
var
  Index, I: Integer;
begin
  Result := nil;
  Index := FindTool(AName);
  if Index < 0 then
    Exit;
  if not FFrozen then
  begin
    MCPHeaderParameters(TJSONObject(FTools[Index].Definition.Find(
      'inputSchema')), Result);
    Exit;
  end;
  // An independent copy: dynamic arrays are shared, not copied, by
  // assignment, and the cached paths must stay as frozen.
  Result := Copy(FTools[Index].HeaderParams);
  for I := 0 to High(Result) do
    Result[I].Path := Copy(FTools[Index].HeaderParams[I].Path);
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
  Definition: TJSONObject;
  ValidationError: string;
begin
  EnsureMutable;
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
  if FindTemplate(AUriTemplate) >= 0 then
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
  AMethod: TMCPPromptMethod; AResultHandler: TMCPPromptResultHandler;
  AResultMethod: TMCPPromptResultMethod);
var
  Definition: TJSONObject;
  CallableCount: Integer;
begin
  try
    EnsureMutable;
  except
    AArguments.Free;
    raise;
  end;
  if AName = '' then
  begin
    AArguments.Free;
    raise EMCPServer.Create('Prompt registration requires a non-empty name');
  end;
  CallableCount := Ord(Assigned(AHandler)) + Ord(Assigned(AMethod)) +
    Ord(Assigned(AResultHandler)) + Ord(Assigned(AResultMethod));
  if CallableCount <> 1 then
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
  FPrompts[High(FPrompts)].ResultHandler := AResultHandler;
  FPrompts[High(FPrompts)].ResultMethod := AResultMethod;
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

procedure TMCPServer.RegisterPrompt(const AName, ADescription: string;
  AHandler: TMCPPromptResultHandler);
begin
  AddPrompt(AName, ADescription, nil, nil, nil, AHandler, nil);
end;

procedure TMCPServer.RegisterPrompt(const AName, ADescription: string;
  AMethod: TMCPPromptResultMethod);
begin
  AddPrompt(AName, ADescription, nil, nil, nil, nil, AMethod);
end;

procedure TMCPServer.RegisterPrompt(const AName, ADescription: string;
  constref AArguments: TMCPPromptArguments;
  AHandler: TMCPPromptResultHandler);
begin
  AddPrompt(AName, ADescription, AArguments.Build, nil, nil, AHandler, nil);
end;

procedure TMCPServer.RegisterPrompt(const AName, ADescription: string;
  constref AArguments: TMCPPromptArguments;
  AMethod: TMCPPromptResultMethod);
begin
  AddPrompt(AName, ADescription, AArguments.Build, nil, nil, nil, AMethod);
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

function TMCPServer.HandleMessage(ASession: TMCPSession;
  const ALine: string; out AResponse: string): Boolean;
begin
  Result := HandleMessage(ASession, ALine, nil, nil, AResponse);
end;

function TMCPServer.HandleMessage(ASession: TMCPSession;
  const ALine: string; ASink: TMCPLineSink; ASinkData: Pointer;
  out AResponse: string): Boolean;
var
  Msg: TJSONRPCMessage;
  ReasonData: TJSONData;
  RequestToken: TMCPRequestCancellationToken;
begin
  AResponse := '';
  Result := False;
  if ASession = nil then
    raise EMCPServer.Create('Session must not be nil');
  if ASession.FOwner <> Self then
    raise EMCPServer.Create('Session belongs to another server');
  FreezeConfiguration;
  Msg := ParseJSONRPCMessage(ALine);
  try
    case Msg.Kind of
      jrkInvalid:
        begin
          // Notification-shaped invalid messages (method present, id
          // absent) are dropped: JSON-RPC 2.0 §4.1 forbids replying to
          // notifications, and MCP treats malformed notifications as
          // fire-and-forget no-ops (see the classification note in
          // MCP.JSONRPC). Id-carrying invalid requests keep the reply.
          if not Msg.NotificationShaped then
          begin
            AResponse := BuildErrorResponse(Msg.Id, Msg.ErrorCode,
              Msg.ErrorMessage);
            Result := True;
          end;
        end;
      jrkNotification:
        begin
          if Msg.Method = 'notifications/initialized' then
            ASession.CompleteLegacyInitialize;
          if (Msg.Method = 'notifications/cancelled') and
             (Msg.Params <> nil) then
          begin
            // A malformed reason invalidates the whole notification;
            // accepted reasons are logged best-effort for debugging.
            // Spec verified 2026-07-21:
            // https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/cancellation
            ReasonData := Msg.Params.Find('reason');
            if ((ReasonData = nil) or
                (ReasonData.JSONType = jtString)) and
               ASession.TryCancelRequest(
                 Msg.Params.Find('requestId')) and
               (ReasonData <> nil) then
              TryLogToStderr('MCP cancellation reason: ' +
                SanitizeLogText(ReasonData.AsString));
          end;
          // All other notifications are deliberately ignored. Invalid
          // cancellation params are fire-and-forget no-ops, never errors.
          Result := False;
        end;
      jrkRequest:
        begin
          RequestToken := nil;
          // Initialize commits the legacy lifecycle and its response is
          // never cancellable, so it deliberately has no request token.
          if Msg.Method <> 'initialize' then
            RequestToken := TMCPRequestCancellationToken(
              ASession.BeginRequest(Msg.Id));
          try
            try
              AResponse := DispatchRequest(ASession, ASink, ASinkData, Msg);
            except
              // A handler's deliberate JSON-RPC error (#88).
              on E: EMCPProtocolError do
                AResponse := ProtocolErrorResponse(Msg, E);
              on E: Exception do
                AResponse := BuildErrorResponse(Msg.Id,
                  JSONRPC_INTERNAL_ERROR,
                  ExceptionClientMessage('dispatch/' + Msg.Method,
                    'Internal error: ', 'Internal error', E));
            end;
            // A server that accepted cancellation MUST NOT send the
            // response, even when the cooperative handler returned one.
            // Spec verified 2026-07-21:
            // https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/cancellation
            if (RequestToken <> nil) and RequestToken.IsCancelled then
              AResponse := ''
            else
              Result := True;
          finally
            ASession.EndRequest(RequestToken);
            RequestToken.Free;
          end;
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

function TMCPServer.DispatchRequest(ASession: TMCPSession;
  ASink: TMCPLineSink; ASinkData: Pointer;
  const AMessage: TJSONRPCMessage): string;
var
  Ctx: TMCPRequestContext;
  Dispatch: TMCPRequestDispatch;
  MetaErr: TMCPMetaError;
begin
  if AMessage.Method = 'initialize' then
  begin
    if FDualEra then
      Exit(HandleInitialize(ASession, AMessage));
    // Modern-only servers SHOULD name their supported versions in the
    // reply — it is the only diagnostic a legacy client can surface.
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_METHOD_NOT_FOUND,
      'The initialize handshake is not supported; this server implements ' +
      'stateless MCP. Supported protocol versions: ' + MCP_PROTOCOL_VERSION,
      BuildUnsupportedVersionData([MCP_PROTOCOL_VERSION], 'initialize')));
  end;

  if FDualEra and not IsModernRequest(AMessage.Params) then
    Exit(DispatchLegacyRequest(ASession, ASink, ASinkData, AMessage));

  Dispatch := TMCPRequestDispatch.Create(
    TMCPRequestCancellationToken(ASession.FCurrentRequestToken),
    ASink, ASinkData);
  try
    if not ExtractRequestContext(AMessage.Params, [MCP_PROTOCOL_VERSION],
      Ctx, MetaErr) then
      Exit(BuildErrorResponse(AMessage.Id, MetaErr.Code, MetaErr.Message,
        MetaErr.Data));
    if Assigned(ASink) then
      Ctx.Notifier := Dispatch.EmitNotification;
    Ctx.CancellationProbe := Dispatch.IsCancelled;

    // requestState is verified before any handler sees it (#89). Only
    // tools/call and prompts/get mint state here, so on any other
    // method a client-sent value cannot be ours and is dropped. A
    // supplied field counts even when empty: '' is no token we issued,
    // and must not reach the handler as a fresh call.
    if (AMessage.Params <> nil) and
      (AMessage.Params.Find('requestState') <> nil) then
      if (AMessage.Method = 'tools/call') or
        (AMessage.Method = 'prompts/get') then
      begin
        if not OpenRequestState(AMessage, Ctx) then
          Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS,
            'Invalid or expired requestState'));
      end
      else
        Ctx.RequestState := '';

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
    if AMessage.Method = 'completion/complete' then
      Exit(HandleComplete(AMessage, Ctx, False));

    Result := BuildErrorResponse(AMessage.Id, JSONRPC_METHOD_NOT_FOUND,
      'Method not found: ' + AMessage.Method);
  finally
    Dispatch.Free;
  end;
end;

function TMCPServer.DispatchLegacyRequest(ASession: TMCPSession;
  ASink: TMCPLineSink; ASinkData: Pointer;
  const AMessage: TJSONRPCMessage): string;
var
  Ctx: TMCPRequestContext;
  Dispatch: TMCPRequestDispatch;
begin
  // ping is a legacy utility a client may send at any time, including
  // before initialize (the modern revision removed it — a modern
  // client never sends it).
  if AMessage.Method = 'ping' then
    Exit(BuildResultResponse(AMessage.Id, TJSONObject.Create));

  if ASession.FLegacyState = lsNew then
    // Legacy lifecycle: non-ping requests are invalid before the
    // handshake completes. The hint about _meta helps a misbehaving
    // modern client that dropped its required envelope.
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_REQUEST,
      'Received request before initialization: send initialize first ' +
      '(legacy clients), or carry the required per-request _meta ' +
      '(protocol 2026-07-28)'));

  if ASession.FLegacyState = lsAwaitingInitialized then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_REQUEST,
      'Received request before initialization is complete: send ' +
      'notifications/initialized first'));

  Dispatch := TMCPRequestDispatch.Create(
    TMCPRequestCancellationToken(ASession.FCurrentRequestToken),
    ASink, ASinkData);
  try
    Ctx := ASession.LegacyContext(AMessage.Params);
    if Assigned(ASink) then
      Ctx.Notifier := Dispatch.EmitNotification;
    Ctx.CancellationProbe := Dispatch.IsCancelled;

    if AMessage.Method = 'tools/list' then
      Exit(HandleToolsList(AMessage, True));
    if AMessage.Method = 'tools/call' then
      Exit(HandleToolsCall(AMessage, Ctx, True));
    if AMessage.Method = 'resources/list' then
      Exit(HandleResourcesList(AMessage, True));
    if AMessage.Method = 'resources/read' then
      Exit(HandleResourcesRead(AMessage, Ctx, True));
    if AMessage.Method = 'resources/templates/list' then
      Exit(HandleTemplatesList(AMessage, True));
    if AMessage.Method = 'prompts/list' then
      Exit(HandlePromptsList(AMessage, True));
    if AMessage.Method = 'prompts/get' then
      Exit(HandlePromptsGet(AMessage, Ctx, True));
    if AMessage.Method = 'completion/complete' then
      Exit(HandleComplete(AMessage, Ctx, True));

    Result := BuildErrorResponse(AMessage.Id, JSONRPC_METHOD_NOT_FOUND,
      'Method not found: ' + AMessage.Method);
  finally
    Dispatch.Free;
  end;
end;

function TMCPServer.HandleInitialize(ASession: TMCPSession;
  const AMessage: TJSONRPCMessage): string;
var
  VersionData, InfoData, CapsData, NameData, ClientVersionData: TJSONData;
  Requested, NegotiatedVersion, ClientName, ClientVersion: string;
  InitResult, Capabilities, ServerInfo, ClientCapabilities,
    ResponsePayload: TJSONObject;
begin
  if ASession.FLegacyState <> lsNew then
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
    ServerInfo := BuildServerInfo(FName, FVersion);

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

  // Commit all negotiated state only after response serialization;
  // a failed response leaves the session in lsNew.
  ASession.CommitLegacyInitialize(NegotiatedVersion, ClientName,
    ClientVersion, ClientCapabilities);
  ClientCapabilities := nil; // ownership transferred to the session
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
  // discover/list/read results — the official SDKs reject results
  // without them. Discovered on the RC client (2.0.0-beta.4) and
  // unchanged in stable: verified 2026-08-08 against
  // @modelcontextprotocol/client 2.0.0, whose wire schema marks them
  // non-optional.
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

  // serverInfo is a required TOP-LEVEL DiscoverResult field in the
  // wire schema — the _meta stamp alone is not enough; the official
  // client classifies a server without it as legacy. Discovered on
  // the RC client (2.0.0-beta.4) and unchanged in stable: verified
  // 2026-08-08 against @modelcontextprotocol/client 2.0.0.
  ServerInfo := BuildServerInfo(FName, FVersion);

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
  ListResult, Definition: TJSONObject;
  OutputSchema: TJSONData;
  Tools: TJSONArray;
  I: Integer;
begin
  // Whole list, registration order: deterministic ordering is what the
  // spec asks for, and without pagination there is no cursor to honor.
  Tools := TJSONArray.Create;
  try
  for I := 0 to High(FTools) do
  begin
    Definition := TJSONObject(FTools[I].Definition.Clone);
    // The classic dialect's outputSchema has an object root (2025-11-25
    // schema, Tool.outputSchema, verified 2026-11-27 against
    // https://modelcontextprotocol.io/specification/2025-11-25/schema#tool).
    // A tool with any other root stays listed, so classic clients can
    // still call it, but without the schema they could not accept (#91).
    OutputSchema := Definition.Find('outputSchema');
    if ALegacy and (OutputSchema <> nil) and
      (TJSONObject(OutputSchema).Get('type', '') <> 'object') then
      Definition.Delete('outputSchema');
    Tools.Add(Definition);
  end;
  except
    Tools.Free;
    raise;
  end;
  ListResult := TJSONObject.Create;
  ListResult.Add('tools', Tools);
  if not ALegacy then
    AddCacheFields(ListResult, FCacheTtlMs);
  Result := ResultResponse(AMessage, ListResult, ALegacy);
end;

// The input_required tail shared by tools/call and prompts/get (#4).
// Gate first, assemble second: an entry naming a kind the library
// never emits is a server bug (-32603), a kind the client did not
// declare is one the spec forbids sending (-32021). ASubjectKind /
// ASubjectName name the offender in diagnostics ('Tool' / 'Prompt'
// plus the registered name). AInputRequests is consumed on every
// path, error paths included. Modern era only — each caller keeps its
// own legacy-era branch, which never reaches here.
function TMCPServer.InputRequiredResponse(const AMessage: TJSONRPCMessage;
  const ACtx: TMCPRequestContext;
  const ASubjectKind, ASubjectName: string;
  AInputRequests: TJSONObject; const ARequestState: string): string;
var
  MissingCapability, UnknownKind: string;
  InterimResult: TJSONObject;
begin
  MissingCapability := MissingInputCapability(AInputRequests, ACtx,
    UnknownKind);
  if UnknownKind <> '' then
  begin
    AInputRequests.Free;
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INTERNAL_ERROR,
      ASubjectKind + ' "' + ASubjectName + '" produced an unsupported ' +
      'input request kind "' + UnknownKind + '"'));
  end;
  if MissingCapability <> '' then
  begin
    AInputRequests.Free;
    // Decided after the handler ran, so on HTTP a request that already
    // streamed progress cannot get its 400 any more (#84): tell the
    // author how to have it refused up front.
    if ASubjectKind = 'Tool' then
      TryLogToStderr('MCP: tool "' + SanitizeLogText(ASubjectName) +
        '" asked for input that needs the client capability "' +
        MissingCapability + '"; declare it with .RequiresClientCapability(''' +
        MissingCapability + ''') so such requests are refused before ' +
        'the handler runs');
    Exit(BuildErrorResponse(AMessage.Id,
      MCP_ERROR_MISSING_CLIENT_CAPABILITY,
      ASubjectKind + ' "' + ASubjectName + '" requires the client ' +
      'capability "' + MissingCapability + '"',
      BuildMissingCapabilityData(MissingCapability)));
  end;
  InterimResult := TJSONObject.Create;
  try
    InterimResult.Add('resultType', RESULT_TYPE_INPUT_REQUIRED);
    if AInputRequests <> nil then
      InterimResult.Add('inputRequests', AInputRequests);
    AInputRequests := nil; // owned by InterimResult from here
    // Sealed for the client (#89); the retry is verified in
    // DispatchRequest before the handler runs again.
    if ARequestState <> '' then
      InterimResult.Add('requestState',
        TMCPRequestStateSealer(FSealer).Seal(AMessage.Method, ASubjectName,
        RequestArguments(AMessage), ARequestState));
  except
    // Sealing can raise (an argument tree it cannot serialize): the
    // tree, the input requests included, is ours until the response
    // builder takes it.
    InterimResult.Free;
    AInputRequests.Free;
    raise;
  end;
  Result := ResultResponse(AMessage, InterimResult, False);
end;

function TMCPServer.ResolveCallTarget(const AMessage: TJSONRPCMessage;
  ALookup: TRegistryLookup; const ANoun: string;
  out AName: string; out AIndex: Integer;
  out AArguments, AOwnedEmpty: TJSONObject): string;
var
  NameData, ArgsData: TJSONData;
begin
  AName := '';
  AIndex := -1;
  AArguments := nil;
  AOwnedEmpty := nil;

  if AMessage.Params = nil then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS,
      'Invalid params: params are required'));
  NameData := AMessage.Params.Find('name');
  if (NameData = nil) or (NameData.JSONType <> jtString) then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS,
      'Invalid params: name must be a string'));
  AName := NameData.AsString;

  AIndex := ALookup(AName);
  if AIndex < 0 then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS,
      'Unknown ' + ANoun + ': ' + AName));

  ArgsData := AMessage.Params.Find('arguments');
  if (ArgsData <> nil) and (ArgsData.JSONType <> jtObject) then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS,
      'Invalid params: arguments must be an object'));

  // Handlers always see a non-nil arguments object, and always a copy
  // the caller owns: seeding defaults or a handler changing it must not
  // touch AMessage, whose original arguments a sealed requestState is
  // bound to (#89).
  if ArgsData <> nil then
    AOwnedEmpty := TJSONObject(ArgsData.Clone)
  else
    AOwnedEmpty := TJSONObject.Create;
  AArguments := AOwnedEmpty;
  Result := '';
end;

// A tool with a subset outputSchema must send conforming structured
// output: the spec makes that a server MUST (tools#output-schema,
// verified 2026-11-26). A handler that breaks it gets an isError result
// naming the first violation instead of sending the bad value. An
// isError result may omit structured output; one it carries is checked
// too, and dropped (keeping the handler's error text) if it fails.
// For a classic client: replaces non-object structured output with a
// text block of its JSON, unless the content already carries that text.
procedure MoveStructuredToText(var AResult: TMCPToolResult);
var
  Text: string;
  I: Integer;
  Block: TJSONData;
begin
  Text := SerializeCompact(AResult.StructuredContent);
  // Freed only once serialized: if that raises, the caller frees it.
  FreeAndNil(AResult.StructuredContent);
  for I := 0 to AResult.Content.Count - 1 do
  begin
    Block := AResult.Content.Items[I];
    if (Block.JSONType = jtObject) and
      (TJSONObject(Block).Get('type', '') = 'text') and
      (TJSONObject(Block).Get('text', '') = Text) then
      Exit;
  end;
  AResult.Content.Add(MCPTextContent(Text));
end;

procedure CheckStructuredOutput(const AToolName: string;
  AOutputSchema: TJSONObject; var AResult: TMCPToolResult);
var
  Violation: string;
begin
  if AResult.IsError then
  begin
    if (AResult.StructuredContent <> nil) and
      not MCPValidateAgainstSchema(AOutputSchema, AResult.StructuredContent,
      'structured output', False, Violation) then
      FreeAndNil(AResult.StructuredContent);
    Exit;
  end;
  if AResult.StructuredContent = nil then
    Violation := 'no structuredContent was returned'
  else if MCPValidateAgainstSchema(AOutputSchema, AResult.StructuredContent,
    'structured output', False, Violation) then
    Exit;
  AResult.Content.Free;
  AResult.StructuredContent.Free;
  AResult := MCPErrorResult('Tool "' + AToolName + '" produced output that ' +
    'does not match its outputSchema: ' + Violation);
end;

function TMCPServer.HandleToolsCall(const AMessage: TJSONRPCMessage;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): string;
var
  ToolName, BindError, TargetError: string;
  Index, I: Integer;
  Arguments, OwnedEmpty, CallResult: TJSONObject;
  ToolResult: TMCPToolResult;
  ArgsInstance: TMCPArgs;
begin
  TargetError := ResolveCallTarget(AMessage, FindTool, 'tool', ToolName,
    Index, Arguments, OwnedEmpty);
  if TargetError <> '' then
    Exit(TargetError);
  // Declared needs first (#84): refused before the handler can emit
  // anything, so the status stays the transport's to choose. Modern era
  // only, like the MRTR requests these capabilities serve.
  if not ALegacy then
    for I := 0 to High(FTools[Index].RequiredCapabilities) do
      if not ACtx.HasCapability(FTools[Index].RequiredCapabilities[I]) then
      begin
        OwnedEmpty.Free;
        Exit(BuildErrorResponse(AMessage.Id,
          MCP_ERROR_MISSING_CLIENT_CAPABILITY, 'Tool "' + ToolName +
          '" requires the client capability "' +
          FTools[Index].RequiredCapabilities[I] + '"',
          BuildMissingCapabilityData(FTools[Index].RequiredCapabilities[I])));
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
      else if FTools[Index].SubsetValidate and
        not MCPValidateAgainstSchema(
          TJSONObject(FTools[Index].Definition.Find('inputSchema')),
          Arguments, 'argument', True, BindError) then
        // Raw path (#23): the registered schema's enforceable subset
        // is checked before the handler runs; violations travel
        // in-band exactly like typed binding failures.
        ToolResult := MCPErrorResult(BindError)
      else if Assigned(FTools[Index].Method) then
        ToolResult := FTools[Index].Method(Arguments, ACtx)
      else
        ToolResult := FTools[Index].Handler(Arguments, ACtx);
    except
      // Execution errors travel in-band (isError: true) so the model
      // can read them and self-correct; only dispatch-level faults and
      // a handler's deliberate EMCPProtocolError (answered by the
      // dispatch wrapper, #88) are JSON-RPC errors.
      on E: EMCPProtocolError do
        raise;
      on E: Exception do
        ToolResult := MCPErrorResult(ExceptionClientMessage(
          'tools/call handler', 'Tool execution failed: ',
          'Tool execution failed', E));
    end;
  finally
    OwnedEmpty.Free;
  end;

  if ToolResult.InputRequired then
  begin
    // MRTR interim result (#4): modern era only, kinds gated on the
    // client's declared capabilities.
    ToolResult.Content.Free;
    ToolResult.StructuredContent.Free;
    if ALegacy then
    begin
      ToolResult.InputRequests.Free;
      ToolResult := MCPErrorResult('Tool "' + ToolName +
        '" requires additional input (input_required), which is not ' +
        'available to legacy-era clients');
    end
    else
      Exit(InputRequiredResponse(AMessage, ACtx, 'Tool', ToolName,
        ToolResult.InputRequests, ToolResult.RequestState));
  end;

  if ToolResult.Content = nil then
    ToolResult.Content := TJSONArray.Create;
  // The result trees stay ours until CallResult takes them: free them
  // if checking or converting raises (serializing a non-finite number).
  try
    if FTools[Index].OutputValidate then
      CheckStructuredOutput(ToolName,
        TJSONObject(FTools[Index].Definition.Find('outputSchema')), ToolResult);
    // The classic dialect's structuredContent is an object (2025-11-25
    // schema, CallToolResult, verified 2026-11-27 against
    // https://modelcontextprotocol.io/specification/2025-11-25/schema#calltoolresult);
    // any other value travels as a text block of its JSON (#91).
    if (ToolResult.StructuredContent <> nil) and ALegacy and
      (ToolResult.StructuredContent.JSONType <> jtObject) then
      MoveStructuredToText(ToolResult);
  except
    ToolResult.Content.Free;
    ToolResult.StructuredContent.Free;
    raise;
  end;

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
  DeclaredData: TJSONData;
  PromptName, TargetError: string;
  Index, I: Integer;
  Arguments, OwnedEmpty, GetResult, Declared: TJSONObject;
  DeclaredArgs: TJSONArray;
  Messages: TJSONArray;
  PromptResult: TMCPPromptResult;
begin
  TargetError := ResolveCallTarget(AMessage, FindPrompt, 'prompt',
    PromptName, Index, Arguments, OwnedEmpty);
  if TargetError <> '' then
    Exit(TargetError);

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
      if Assigned(FPrompts[Index].ResultHandler) or
         Assigned(FPrompts[Index].ResultMethod) then
      begin
        // MRTR-capable prompt: the handler may answer with an
        // input_required round instead of messages (#4).
        if Assigned(FPrompts[Index].ResultMethod) then
          PromptResult := FPrompts[Index].ResultMethod(Arguments, ACtx)
        else
          PromptResult := FPrompts[Index].ResultHandler(Arguments, ACtx);
        Messages := PromptResult.Messages;
      end
      else
      begin
        PromptResult := Default(TMCPPromptResult);
        if Assigned(FPrompts[Index].Method) then
          Messages := FPrompts[Index].Method(Arguments, ACtx)
        else
          Messages := FPrompts[Index].Handler(Arguments, ACtx);
      end;
    except
      // The dispatch wrapper answers a deliberate error (#88).
      on E: EMCPProtocolError do
        raise;
      on E: Exception do
        Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INTERNAL_ERROR,
          ExceptionClientMessage('prompts/get handler',
            'Prompt handler failed: ', 'Prompt handler failed', E)));
    end;

    if PromptResult.InputRequired then
    begin
      Messages.Free;
      if ALegacy then
      begin
        PromptResult.InputRequests.Free;
        Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INTERNAL_ERROR,
          'Prompt "' + PromptName + '" requires additional input ' +
          '(input_required), which is not available to legacy-era ' +
          'clients'));
      end;
      Exit(InputRequiredResponse(AMessage, ACtx, 'Prompt', PromptName,
        PromptResult.InputRequests, PromptResult.RequestState));
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

initialization
  // RTL-only mutual exclusion for the process-wide diagnostic state;
  // it outlives every session, so unit lifetime is the right scope.
  // ErrorSequenceLock guards the error-reference counter (portable in
  // place of a 64-bit atomic).
  InitCriticalSection(ErrorSequenceLock);

finalization
  DoneCriticalSection(ErrorSequenceLock);

end.
