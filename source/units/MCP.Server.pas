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
// HandleMessage — the whole protocol surface is testable without any
// I/O, mirroring duetto's sans-I/O discipline. MCP.Transport.Stdio
// (and a future MCP.Transport.Http) are thin byte-moving shells
// around this.
//
// v1 protocol surface:
//   modern era (per-request _meta):
//     server/discover                  (mandatory in 2026-07-28)
//     tools/list, tools/call
//     resources/list, resources/read
//   legacy era (dual-era mode, after initialize):
//     initialize, ping
//     tools/list, tools/call
//     resources/list, resources/read
//     — responses omit the modern-only stamps (resultType, serverInfo
//       _meta, ttlMs/cacheScope) and resource-not-found is the legacy
//       -32002, so each era sees its own wire dialect
//   notifications/*                    accepted and ignored; requests
//                                      are handled strictly one at a
//                                      time, so by the time a
//                                      notifications/cancelled arrives
//                                      the request it names has already
//                                      completed. Era selection state
//                                      (legacy initialized + negotiated
//                                      version) is the one deliberate
//                                      piece of per-process state the
//                                      compatibility model prescribes.
// Not in v1 (deliberate): subscriptions/listen and the listChanged
// capability flags (registries are fixed after startup, so there is
// nothing to notify), pagination cursors (lists are returned whole),
// MRTR input_required results, and JSON-Schema validation of tool
// arguments (handlers validate their own inputs and report problems as
// isError tool results, which is what models can act on).
//
// Handlers are synchronous and may be plain functions or methods (both
// overloads are provided). A handler that raises becomes an isError
// tool result carrying the exception message — execution errors belong
// in-band where the model can read them; protocol errors stay JSON-RPC
// errors.

{$I Shared.inc}

interface

uses
  SysUtils,

  fpjson,
  jsonparser,
  jsonscanner,
  MCP.JsonRpc,
  MCP.Protocol;

type
  // Result of one tool invocation. Content is a JSON array of content
  // blocks (owned; use the Mcp*Result builders), StructuredContent is
  // the optional machine-readable payload (owned; nil when absent).
  TMcpToolResult = record
    Content: TJSONArray;
    StructuredContent: TJSONData;
    IsError: Boolean;
  end;

  TMcpToolHandler = function(AArguments: TJSONObject;
    const ACtx: TMcpRequestContext): TMcpToolResult;
  TMcpToolMethod = function(AArguments: TJSONObject;
    const ACtx: TMcpRequestContext): TMcpToolResult of object;

  // Resource readers return the "contents" array of a resources/read
  // result (owned; use McpTextContents / McpBlobContents).
  TMcpResourceReader = function(const AUri: string;
    const ACtx: TMcpRequestContext): TJSONArray;
  TMcpResourceMethod = function(const AUri: string;
    const ACtx: TMcpRequestContext): TJSONArray of object;

  TMcpToolRegistration = record
    Definition: TJSONObject; // owned: name/description/inputSchema/...
    Handler: TMcpToolHandler;
    Method: TMcpToolMethod;
  end;

  TMcpResourceRegistration = record
    Definition: TJSONObject; // owned: uri/name/mimeType/...
    Uri: string;
    StaticText: string;      // used when no reader is registered
    HasStaticText: Boolean;
    Reader: TMcpResourceReader;
    Method: TMcpResourceMethod;
  end;

  TMcpServer = class
  private
    FName: string;
    FVersion: string;
    FInstructions: string;
    FCacheTtlMs: Integer;
    FCacheScope: string;
    FDualEra: Boolean;
    // Legacy-era session state (dual-era mode only): the compatibility
    // model scopes initialize-negotiated semantics to the process, so
    // this is the one deliberate piece of cross-request state.
    FLegacyInitialized: Boolean;
    FLegacyProtocolVersion: string;
    FLegacyClientName: string;
    FLegacyClientVersion: string;
    FLegacyClientCapabilities: TJSONObject; // owned clone from initialize
    FTools: array of TMcpToolRegistration;
    FResources: array of TMcpResourceRegistration;

    function ParseSchema(const ASchemaJson, AToolName: string): TJSONObject;
    function BuildToolDefinition(const AName, ADescription,
      AInputSchemaJson: string): TJSONObject;
    procedure AddTool(ADefinition: TJSONObject; AHandler: TMcpToolHandler;
      AMethod: TMcpToolMethod);
    procedure AddResource(const AUri, AName, AMimeType, ADescription: string;
      AReader: TMcpResourceReader; AMethod: TMcpResourceMethod;
      const AStaticText: string; AHasStaticText: Boolean);
    function FindTool(const AName: string): Integer;
    function FindResource(const AUri: string): Integer;

    function DispatchRequest(const AMessage: TJsonRpcMessage): string;
    function DispatchLegacyRequest(const AMessage: TJsonRpcMessage): string;
    function HandleInitialize(const AMessage: TJsonRpcMessage): string;
    function HandleDiscover(const AMessage: TJsonRpcMessage): string;
    function HandleToolsList(const AMessage: TJsonRpcMessage;
      ALegacy: Boolean): string;
    function HandleToolsCall(const AMessage: TJsonRpcMessage;
      const ACtx: TMcpRequestContext; ALegacy: Boolean): string;
    function HandleResourcesList(const AMessage: TJsonRpcMessage;
      ALegacy: Boolean): string;
    function HandleResourcesRead(const AMessage: TJsonRpcMessage;
      const ACtx: TMcpRequestContext; ALegacy: Boolean): string;
    function ResultResponse(const AMessage: TJsonRpcMessage;
      AResult: TJSONObject; ALegacy: Boolean): string;
    function LegacyContext: TMcpRequestContext;
    procedure AddCacheFields(AResult: TJSONObject; ATtlMs: Integer);
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
    property CacheTtlMs: Integer read FCacheTtlMs write FCacheTtlMs;
    property CacheScope: string read FCacheScope write FCacheScope;

    // Dual-era mode (default True): answer the legacy initialize
    // handshake (2025-11-25 and earlier) alongside stateless
    // 2026-07-28 requests — today's clients (Claude Code, Claude
    // Desktop) still open with initialize. False = strict modern-only:
    // initialize is rejected with a diagnostic naming the supported
    // versions.
    property DualEra: Boolean read FDualEra write FDualEra;

    // AInputSchemaJson is parsed at registration and raises EMcpServer
    // on invalid JSON — a bad schema is a programming error, not a
    // runtime condition. The definition-object overloads take
    // ownership of ADefinition for tools that need title/outputSchema/
    // annotations.
    procedure RegisterTool(const AName, ADescription, AInputSchemaJson: string;
      AHandler: TMcpToolHandler); overload;
    procedure RegisterTool(const AName, ADescription, AInputSchemaJson: string;
      AMethod: TMcpToolMethod); overload;
    procedure RegisterTool(ADefinition: TJSONObject;
      AHandler: TMcpToolHandler); overload;
    procedure RegisterTool(ADefinition: TJSONObject;
      AMethod: TMcpToolMethod); overload;

    procedure RegisterTextResource(const AUri, AName, AMimeType, AText: string;
      const ADescription: string = '');
    procedure RegisterResource(const AUri, AName, AMimeType: string;
      AReader: TMcpResourceReader; const ADescription: string = ''); overload;
    procedure RegisterResource(const AUri, AName, AMimeType: string;
      AMethod: TMcpResourceMethod; const ADescription: string = ''); overload;

    // The core entry point: one inbound line in, at most one response
    // line out. Returns True when AResponse must be written (requests
    // and malformed input), False when there is nothing to send
    // (notifications). Never raises.
    function HandleMessage(const ALine: string; out AResponse: string): Boolean;

    function ToolCount: Integer;
    function ResourceCount: Integer;
  end;

  EMcpServer = class(Exception);

// Content builders for handler implementations.
function McpTextResult(const AText: string): TMcpToolResult;
function McpErrorResult(const AText: string): TMcpToolResult;
function McpStructuredResult(const AText: string;
  AStructured: TJSONData): TMcpToolResult;
function McpTextContents(const AUri, AMimeType, AText: string): TJSONArray;
function McpBlobContents(const AUri, AMimeType, ABase64: string): TJSONArray;

implementation

{ ───────── content builders ───────── }

function TextContentBlock(const AText: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('type', 'text');
  Result.Add('text', AText);
end;

function McpTextResult(const AText: string): TMcpToolResult;
begin
  Result := Default(TMcpToolResult);
  Result.Content := TJSONArray.Create;
  Result.Content.Add(TextContentBlock(AText));
end;

function McpErrorResult(const AText: string): TMcpToolResult;
begin
  Result := McpTextResult(AText);
  Result.IsError := True;
end;

function McpStructuredResult(const AText: string;
  AStructured: TJSONData): TMcpToolResult;
begin
  Result := McpTextResult(AText);
  Result.StructuredContent := AStructured;
end;

function McpTextContents(const AUri, AMimeType, AText: string): TJSONArray;
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

function McpBlobContents(const AUri, AMimeType, ABase64: string): TJSONArray;
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

{ ───────── TMcpServer: lifecycle ───────── }

constructor TMcpServer.Create(const AName, AVersion: string);
begin
  inherited Create;
  FName := AName;
  FVersion := AVersion;
  FCacheTtlMs := 300000;
  FCacheScope := CACHE_SCOPE_PRIVATE;
  FDualEra := True;
end;

destructor TMcpServer.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FTools) do
    FTools[I].Definition.Free;
  for I := 0 to High(FResources) do
    FResources[I].Definition.Free;
  FLegacyClientCapabilities.Free;
  inherited Destroy;
end;

{ ───────── TMcpServer: registration ───────── }

function TMcpServer.ParseSchema(const ASchemaJson, AToolName: string): TJSONObject;
var
  Parser: TJSONParser;
  Data: TJSONData;
begin
  Parser := TJSONParser.Create(ASchemaJson, [joUTF8, joStrict]);
  try
    try
      Data := Parser.Parse;
    except
      on E: Exception do
        raise EMcpServer.CreateFmt(
          'Invalid input schema for tool "%s": %s', [AToolName, E.Message]);
    end;
  finally
    Parser.Free;
  end;
  if (Data = nil) or (Data.JSONType <> jtObject) then
  begin
    Data.Free;
    raise EMcpServer.CreateFmt(
      'Invalid input schema for tool "%s": must be a JSON object', [AToolName]);
  end;
  Result := TJSONObject(Data);
end;

function TMcpServer.BuildToolDefinition(const AName, ADescription,
  AInputSchemaJson: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('name', AName);
  Result.Add('description', ADescription);
  Result.Add('inputSchema', ParseSchema(AInputSchemaJson, AName));
end;

procedure TMcpServer.AddTool(ADefinition: TJSONObject;
  AHandler: TMcpToolHandler; AMethod: TMcpToolMethod);
var
  ToolName: string;
begin
  ToolName := ADefinition.Get('name', '');
  if ToolName = '' then
  begin
    ADefinition.Free;
    raise EMcpServer.Create('Tool definition must carry a non-empty name');
  end;
  if FindTool(ToolName) >= 0 then
  begin
    ADefinition.Free;
    raise EMcpServer.CreateFmt('Tool "%s" is already registered', [ToolName]);
  end;
  SetLength(FTools, Length(FTools) + 1);
  FTools[High(FTools)].Definition := ADefinition;
  FTools[High(FTools)].Handler := AHandler;
  FTools[High(FTools)].Method := AMethod;
end;

procedure TMcpServer.RegisterTool(const AName, ADescription,
  AInputSchemaJson: string; AHandler: TMcpToolHandler);
begin
  AddTool(BuildToolDefinition(AName, ADescription, AInputSchemaJson),
    AHandler, nil);
end;

procedure TMcpServer.RegisterTool(const AName, ADescription,
  AInputSchemaJson: string; AMethod: TMcpToolMethod);
begin
  AddTool(BuildToolDefinition(AName, ADescription, AInputSchemaJson),
    nil, AMethod);
end;

procedure TMcpServer.RegisterTool(ADefinition: TJSONObject;
  AHandler: TMcpToolHandler);
begin
  AddTool(ADefinition, AHandler, nil);
end;

procedure TMcpServer.RegisterTool(ADefinition: TJSONObject;
  AMethod: TMcpToolMethod);
begin
  AddTool(ADefinition, nil, AMethod);
end;

procedure TMcpServer.AddResource(const AUri, AName, AMimeType,
  ADescription: string; AReader: TMcpResourceReader;
  AMethod: TMcpResourceMethod; const AStaticText: string;
  AHasStaticText: Boolean);
var
  Definition: TJSONObject;
begin
  if AUri = '' then
    raise EMcpServer.Create('Resource registration requires a non-empty uri');
  if FindResource(AUri) >= 0 then
    raise EMcpServer.CreateFmt('Resource "%s" is already registered', [AUri]);
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

procedure TMcpServer.RegisterTextResource(const AUri, AName, AMimeType,
  AText: string; const ADescription: string);
begin
  AddResource(AUri, AName, AMimeType, ADescription, nil, nil, AText, True);
end;

procedure TMcpServer.RegisterResource(const AUri, AName, AMimeType: string;
  AReader: TMcpResourceReader; const ADescription: string);
begin
  AddResource(AUri, AName, AMimeType, ADescription, AReader, nil, '', False);
end;

procedure TMcpServer.RegisterResource(const AUri, AName, AMimeType: string;
  AMethod: TMcpResourceMethod; const ADescription: string);
begin
  AddResource(AUri, AName, AMimeType, ADescription, nil, AMethod, '', False);
end;

function TMcpServer.FindTool(const AName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FTools) do
    if FTools[I].Definition.Get('name', '') = AName then
      Exit(I);
  Result := -1;
end;

function TMcpServer.FindResource(const AUri: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FResources) do
    if FResources[I].Uri = AUri then
      Exit(I);
  Result := -1;
end;

function TMcpServer.ToolCount: Integer;
begin
  Result := Length(FTools);
end;

function TMcpServer.ResourceCount: Integer;
begin
  Result := Length(FResources);
end;

{ ───────── TMcpServer: dispatch ───────── }

function TMcpServer.ResultResponse(const AMessage: TJsonRpcMessage;
  AResult: TJSONObject; ALegacy: Boolean): string;
begin
  // The modern stamps (resultType, serverInfo _meta) belong to the
  // 2026-07-28 dialect only; legacy responses stay byte-faithful to
  // their negotiated revision.
  if not ALegacy then
    StampResult(AResult, FName, FVersion);
  Result := BuildResultResponse(AMessage.Id, AResult);
end;

function TMcpServer.HandleMessage(const ALine: string;
  out AResponse: string): Boolean;
var
  Msg: TJsonRpcMessage;
begin
  AResponse := '';
  Result := False;
  Msg := ParseJsonRpcMessage(ALine);
  try
    case Msg.Kind of
      jrkInvalid:
        begin
          AResponse := BuildErrorResponse(Msg.Id, Msg.ErrorCode,
            Msg.ErrorMessage);
          Result := True;
        end;
      jrkNotification:
        // All notifications (including notifications/cancelled) are
        // deliberately ignored: requests are processed one at a time,
        // so a cancellation can only arrive after its target finished.
        Result := False;
      jrkRequest:
        begin
          try
            AResponse := DispatchRequest(Msg);
          except
            on E: Exception do
              AResponse := BuildErrorResponse(Msg.Id,
                JSONRPC_INTERNAL_ERROR, 'Internal error: ' + E.Message);
          end;
          Result := True;
        end;
    end;
  finally
    FreeJsonRpcMessage(Msg);
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

function TMcpServer.DispatchRequest(const AMessage: TJsonRpcMessage): string;
var
  Ctx: TMcpRequestContext;
  MetaErr: TMcpMetaError;
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

  Result := BuildErrorResponse(AMessage.Id, JSONRPC_METHOD_NOT_FOUND,
    'Method not found: ' + AMessage.Method);
end;

function TMcpServer.DispatchLegacyRequest(
  const AMessage: TJsonRpcMessage): string;
begin
  // ping is a legacy utility a client may send at any time, including
  // before initialize (the modern revision removed it — a modern
  // client never sends it).
  if AMessage.Method = 'ping' then
    Exit(BuildResultResponse(AMessage.Id, TJSONObject.Create));

  if not FLegacyInitialized then
    // Legacy lifecycle: non-ping requests are invalid before the
    // handshake completes. The hint about _meta helps a misbehaving
    // modern client that dropped its required envelope.
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_REQUEST,
      'Received request before initialization: send initialize first ' +
      '(legacy clients), or carry the required per-request _meta ' +
      '(protocol 2026-07-28)'));

  if AMessage.Method = 'tools/list' then
    Exit(HandleToolsList(AMessage, True));
  if AMessage.Method = 'tools/call' then
    Exit(HandleToolsCall(AMessage, LegacyContext, True));
  if AMessage.Method = 'resources/list' then
    Exit(HandleResourcesList(AMessage, True));
  if AMessage.Method = 'resources/read' then
    Exit(HandleResourcesRead(AMessage, LegacyContext, True));

  Result := BuildErrorResponse(AMessage.Id, JSONRPC_METHOD_NOT_FOUND,
    'Method not found: ' + AMessage.Method);
end;

function TMcpServer.HandleInitialize(const AMessage: TJsonRpcMessage): string;
var
  VersionData, InfoData, CapsData: TJSONData;
  Requested: string;
  InitResult, Capabilities, ServerInfo: TJSONObject;
begin
  if AMessage.Params = nil then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS,
      'Invalid params: initialize requires protocolVersion'));
  VersionData := AMessage.Params.Find('protocolVersion');
  if (VersionData = nil) or (VersionData.JSONType <> jtString) then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS,
      'Invalid params: protocolVersion must be a string'));
  Requested := VersionData.AsString;

  // Legacy negotiation: echo a supported revision, otherwise answer
  // with the latest legacy revision we speak (the client decides
  // whether to proceed or disconnect).
  if IsLegacyProtocolVersion(Requested) then
    FLegacyProtocolVersion := Requested
  else
    FLegacyProtocolVersion := LATEST_LEGACY_PROTOCOL_VERSION;

  // A re-initialize renegotiates: replace any earlier session state.
  FLegacyClientName := '';
  FLegacyClientVersion := '';
  FreeAndNil(FLegacyClientCapabilities);
  InfoData := AMessage.Params.Find('clientInfo');
  if (InfoData <> nil) and (InfoData.JSONType = jtObject) then
  begin
    FLegacyClientName := TJSONObject(InfoData).Get('name', '');
    FLegacyClientVersion := TJSONObject(InfoData).Get('version', '');
  end;
  CapsData := AMessage.Params.Find('capabilities');
  if (CapsData <> nil) and (CapsData.JSONType = jtObject) then
    FLegacyClientCapabilities := TJSONObject(CapsData.Clone);
  FLegacyInitialized := True;

  Capabilities := TJSONObject.Create;
  Capabilities.Add('tools', TJSONObject.Create);
  Capabilities.Add('resources', TJSONObject.Create);
  ServerInfo := TJSONObject.Create;
  ServerInfo.Add('name', FName);
  ServerInfo.Add('version', FVersion);

  InitResult := TJSONObject.Create;
  InitResult.Add('protocolVersion', FLegacyProtocolVersion);
  InitResult.Add('capabilities', Capabilities);
  InitResult.Add('serverInfo', ServerInfo);
  if FInstructions <> '' then
    InitResult.Add('instructions', FInstructions);

  // Legacy wire dialect: no resultType / serverInfo _meta stamping.
  Result := BuildResultResponse(AMessage.Id, InitResult);
end;

function TMcpServer.LegacyContext: TMcpRequestContext;
begin
  Result := Default(TMcpRequestContext);
  Result.ProtocolVersion := FLegacyProtocolVersion;
  Result.ClientName := FLegacyClientName;
  Result.ClientVersion := FLegacyClientVersion;
  Result.ClientCapabilities := FLegacyClientCapabilities;
end;

procedure TMcpServer.AddCacheFields(AResult: TJSONObject; ATtlMs: Integer);
begin
  // CacheableResult (SEP-2549): ttlMs + cacheScope are REQUIRED on
  // discover/list/read results — the official RC SDKs reject results
  // without them (verified against @modelcontextprotocol/client
  // 2.0.0-beta.4, whose wire schema marks them non-optional).
  AResult.Add('ttlMs', ATtlMs);
  AResult.Add('cacheScope', FCacheScope);
end;

function TMcpServer.HandleDiscover(const AMessage: TJsonRpcMessage): string;
var
  DiscoverResult, Capabilities, ServerInfo: TJSONObject;
  Versions: TJSONArray;
begin
  Versions := TJSONArray.Create;
  Versions.Add(MCP_PROTOCOL_VERSION);

  // The capability objects stay empty: no listChanged / subscribe —
  // registries are fixed after startup, so there is nothing to notify.
  Capabilities := TJSONObject.Create;
  Capabilities.Add('tools', TJSONObject.Create);
  Capabilities.Add('resources', TJSONObject.Create);

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

function TMcpServer.HandleToolsList(const AMessage: TJsonRpcMessage;
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

function TMcpServer.HandleToolsCall(const AMessage: TJsonRpcMessage;
  const ACtx: TMcpRequestContext; ALegacy: Boolean): string;
var
  NameData, ArgsData: TJSONData;
  ToolName: string;
  Index: Integer;
  Arguments, OwnedEmpty, CallResult: TJSONObject;
  ToolResult: TMcpToolResult;
begin
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
      if Assigned(FTools[Index].Method) then
        ToolResult := FTools[Index].Method(Arguments, ACtx)
      else
        ToolResult := FTools[Index].Handler(Arguments, ACtx);
    except
      // Execution errors travel in-band (isError: true) so the model
      // can read them and self-correct; only dispatch-level faults are
      // JSON-RPC errors.
      on E: Exception do
        ToolResult := McpErrorResult('Tool execution failed: ' + E.Message);
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

function TMcpServer.HandleResourcesList(const AMessage: TJsonRpcMessage;
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

function TMcpServer.HandleResourcesRead(const AMessage: TJsonRpcMessage;
  const ACtx: TMcpRequestContext; ALegacy: Boolean): string;
var
  UriData: TJSONData;
  Uri, MimeType: string;
  Index, ReadTtlMs: Integer;
  Contents: TJSONArray;
  ReadResult, NotFoundData: TJSONObject;
begin
  UriData := AMessage.Params.Find('uri');
  if (UriData = nil) or (UriData.JSONType <> jtString) then
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS,
      'Invalid params: uri must be a string'));
  Uri := UriData.AsString;

  Index := FindResource(Uri);
  if Index < 0 then
  begin
    // Modern era: MUST be -32602 (the modern revision forbids -32002).
    // Legacy era: -32002 is what that revision's clients expect.
    NotFoundData := TJSONObject.Create;
    NotFoundData.Add('uri', Uri);
    if ALegacy then
      Exit(BuildErrorResponse(AMessage.Id,
        MCP_ERROR_LEGACY_RESOURCE_NOT_FOUND, 'Resource not found',
        NotFoundData));
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INVALID_PARAMS,
      'Resource not found', NotFoundData));
  end;

  // Dynamic readers advertise ttl 0 (always revalidate) — the library
  // cannot know how fresh a callback's data stays; static text is
  // fixed for the process lifetime and uses the registry ttl.
  ReadTtlMs := 0;
  if Assigned(FResources[Index].Method) then
    Contents := FResources[Index].Method(Uri, ACtx)
  else if Assigned(FResources[Index].Reader) then
    Contents := FResources[Index].Reader(Uri, ACtx)
  else
  begin
    MimeType := FResources[Index].Definition.Get('mimeType', 'text/plain');
    Contents := McpTextContents(Uri, MimeType, FResources[Index].StaticText);
    ReadTtlMs := FCacheTtlMs;
  end;
  if Contents = nil then
    raise EMcpServer.CreateFmt(
      'Resource reader for "%s" returned no contents', [Uri]);

  ReadResult := TJSONObject.Create;
  ReadResult.Add('contents', Contents);
  if not ALegacy then
    AddCacheFields(ReadResult, ReadTtlMs);
  Result := ResultResponse(AMessage, ReadResult, ALegacy);
end;

end.
