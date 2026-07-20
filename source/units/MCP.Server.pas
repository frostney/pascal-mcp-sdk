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
// (and a future MCP.Transport.HTTP) are thin byte-moving shells
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
// errors.

{$I Shared.inc}

interface

uses
  SysUtils,
  typinfo,

  fpjson,
  jsonparser,
  jsonscanner,
  MCP.JSONRPC,
  MCP.Protocol,
  MCP.Schema;

type
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
    StaticText: string;      // used when no reader is registered
    HasStaticText: Boolean;
    Reader: TMCPResourceReader;
    Method: TMCPResourceMethod;
  end;

  TMCPServer = class
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
    FTools: array of TMCPToolRegistration;
    FResources: array of TMCPResourceRegistration;

    function ParseSchema(const ASchemaJson, AToolName: string): TJSONObject;
    function BuildToolDefinition(const AName, ADescription,
      AInputSchemaJson: string): TJSONObject;
    procedure AddTool(ADefinition: TJSONObject; AHandler: TMCPToolHandler;
      AMethod: TMCPToolMethod);
    procedure AddTypedTool(ADefinition: TJSONObject;
      AArgsClass: TMCPArgsClass; AHandler: TMCPArgsHandler;
      AMethod: TMCPArgsMethod);
    procedure AddResource(const AUri, AName, AMimeType, ADescription: string;
      AReader: TMCPResourceReader; AMethod: TMCPResourceMethod;
      const AStaticText: string; AHasStaticText: Boolean);
    function FindTool(const AName: string): Integer;
    function FindResource(const AUri: string): Integer;

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
    function ResultResponse(const AMessage: TJSONRPCMessage;
      AResult: TJSONObject; ALegacy: Boolean): string;
    function LegacyContext: TMCPRequestContext;
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

    // The response a transport sends for an inbound line it refused to
    // buffer (length cap). Kept here so the error shape remains a
    // protocol decision — transports move lines only.
    function OversizedLineResponse(AMaxLineLength: Integer): string;

    // AInputSchemaJson is parsed at registration and raises EMCPServer
    // on invalid JSON — a bad schema is a programming error, not a
    // runtime condition. The definition-object overloads take
    // ownership of ADefinition for tools that need title/outputSchema/
    // annotations.
    procedure RegisterTool(const AName, ADescription, AInputSchemaJson: string;
      AHandler: TMCPToolHandler); overload;
    procedure RegisterTool(const AName, ADescription, AInputSchemaJson: string;
      AMethod: TMCPToolMethod); overload;
    procedure RegisterTool(ADefinition: TJSONObject;
      AHandler: TMCPToolHandler); overload;
    procedure RegisterTool(ADefinition: TJSONObject;
      AMethod: TMCPToolMethod); overload;

    // Fluent-schema overloads (MCP.Schema): the idiomatic registration
    // path for flat object schemas — no JSON strings. The overloads
    // call Build and take ownership of the finished schemas.
    procedure RegisterTool(const AName, ADescription: string;
      const AInputSchema: TMCPSchema; AHandler: TMCPToolHandler); overload;
    procedure RegisterTool(const AName, ADescription: string;
      const AInputSchema: TMCPSchema; AMethod: TMCPToolMethod); overload;
    procedure RegisterTool(const AName, ADescription: string;
      const AInputSchema, AOutputSchema: TMCPSchema;
      AHandler: TMCPToolHandler); overload;
    procedure RegisterTool(const AName, ADescription: string;
      const AInputSchema, AOutputSchema: TMCPSchema;
      AMethod: TMCPToolMethod); overload;

    // Typed-argument overloads: the argument class IS the schema
    // (SchemaFrom) and the handler receives a populated, validated
    // instance. Optional output schema as in the fluent overloads.
    procedure RegisterTool(const AName, ADescription: string;
      AArgsClass: TMCPArgsClass; AHandler: TMCPArgsHandler); overload;
    procedure RegisterTool(const AName, ADescription: string;
      AArgsClass: TMCPArgsClass; AMethod: TMCPArgsMethod); overload;
    procedure RegisterTool(const AName, ADescription: string;
      AArgsClass: TMCPArgsClass; const AOutputSchema: TMCPSchema;
      AHandler: TMCPArgsHandler); overload;
    procedure RegisterTool(const AName, ADescription: string;
      AArgsClass: TMCPArgsClass; const AOutputSchema: TMCPSchema;
      AMethod: TMCPArgsMethod); overload;

    procedure RegisterTextResource(const AUri, AName, AMimeType, AText: string;
      const ADescription: string = '');
    procedure RegisterResource(const AUri, AName, AMimeType: string;
      AReader: TMCPResourceReader; const ADescription: string = ''); overload;
    procedure RegisterResource(const AUri, AName, AMimeType: string;
      AMethod: TMCPResourceMethod; const ADescription: string = ''); overload;

    // The core entry point: one inbound line in, at most one response
    // line out. Returns True when AResponse must be written (requests
    // and malformed input), False when there is nothing to send
    // (notifications). Never raises.
    function HandleMessage(const ALine: string; out AResponse: string): Boolean;

    function ToolCount: Integer;
    function ResourceCount: Integer;
  end;

  EMCPServer = class(Exception);

// Content builders for handler implementations.
function MCPTextResult(const AText: string): TMCPToolResult;
function MCPErrorResult(const AText: string): TMCPToolResult;
function MCPStructuredResult(const AText: string;
  AStructured: TJSONData): TMCPToolResult;
function MCPTextContents(const AUri, AMimeType, AText: string): TJSONArray;
function MCPBlobContents(const AUri, AMimeType, ABase64: string): TJSONArray;

implementation

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
  FName := AName;
  FVersion := AVersion;
  FCacheTtlMs := 300000;
  FCacheScope := CACHE_SCOPE_PRIVATE;
  FDualEra := True;
end;

destructor TMCPServer.Destroy;
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

{ ───────── TMCPServer: registration ───────── }

function TMCPServer.ParseSchema(const ASchemaJson, AToolName: string): TJSONObject;
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
  Result := TJSONObject(Data);
end;

function TMCPServer.BuildToolDefinition(const AName, ADescription,
  AInputSchemaJson: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('name', AName);
  Result.Add('description', ADescription);
  Result.Add('inputSchema', ParseSchema(AInputSchemaJson, AName));
end;

procedure TMCPServer.AddTool(ADefinition: TJSONObject;
  AHandler: TMCPToolHandler; AMethod: TMCPToolMethod);
var
  ToolName: string;
begin
  ToolName := ADefinition.Get('name', '');
  if ToolName = '' then
  begin
    ADefinition.Free;
    raise EMCPServer.Create('Tool definition must carry a non-empty name');
  end;
  if FindTool(ToolName) >= 0 then
  begin
    ADefinition.Free;
    raise EMCPServer.CreateFmt('Tool "%s" is already registered', [ToolName]);
  end;
  SetLength(FTools, Length(FTools) + 1);
  FTools[High(FTools)].Definition := ADefinition;
  FTools[High(FTools)].Handler := AHandler;
  FTools[High(FTools)].Method := AMethod;
end;

procedure TMCPServer.AddTypedTool(ADefinition: TJSONObject;
  AArgsClass: TMCPArgsClass; AHandler: TMCPArgsHandler;
  AMethod: TMCPArgsMethod);
begin
  AddTool(ADefinition, nil, nil);
  FTools[High(FTools)].ArgsClass := AArgsClass;
  FTools[High(FTools)].ArgsHandler := AHandler;
  FTools[High(FTools)].ArgsMethod := AMethod;
end;

procedure TMCPServer.RegisterTool(const AName, ADescription,
  AInputSchemaJson: string; AHandler: TMCPToolHandler);
begin
  AddTool(BuildToolDefinition(AName, ADescription, AInputSchemaJson),
    AHandler, nil);
end;

procedure TMCPServer.RegisterTool(const AName, ADescription,
  AInputSchemaJson: string; AMethod: TMCPToolMethod);
begin
  AddTool(BuildToolDefinition(AName, ADescription, AInputSchemaJson),
    nil, AMethod);
end;

procedure TMCPServer.RegisterTool(ADefinition: TJSONObject;
  AHandler: TMCPToolHandler);
begin
  AddTool(ADefinition, AHandler, nil);
end;

procedure TMCPServer.RegisterTool(ADefinition: TJSONObject;
  AMethod: TMCPToolMethod);
begin
  AddTool(ADefinition, nil, AMethod);
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

procedure TMCPServer.RegisterTool(const AName, ADescription: string;
  const AInputSchema: TMCPSchema; AHandler: TMCPToolHandler);
begin
  AddTool(SchemaDefinition(AName, ADescription, AInputSchema.Build, nil),
    AHandler, nil);
end;

procedure TMCPServer.RegisterTool(const AName, ADescription: string;
  const AInputSchema: TMCPSchema; AMethod: TMCPToolMethod);
begin
  AddTool(SchemaDefinition(AName, ADescription, AInputSchema.Build, nil),
    nil, AMethod);
end;

procedure TMCPServer.RegisterTool(const AName, ADescription: string;
  const AInputSchema, AOutputSchema: TMCPSchema; AHandler: TMCPToolHandler);
begin
  AddTool(SchemaDefinition(AName, ADescription, AInputSchema.Build,
    AOutputSchema.Build), AHandler, nil);
end;

procedure TMCPServer.RegisterTool(const AName, ADescription: string;
  const AInputSchema, AOutputSchema: TMCPSchema; AMethod: TMCPToolMethod);
begin
  AddTool(SchemaDefinition(AName, ADescription, AInputSchema.Build,
    AOutputSchema.Build), nil, AMethod);
end;

procedure TMCPServer.RegisterTool(const AName, ADescription: string;
  AArgsClass: TMCPArgsClass; AHandler: TMCPArgsHandler);
begin
  AddTypedTool(SchemaDefinition(AName, ADescription,
    SchemaFrom(AArgsClass).Build, nil), AArgsClass, AHandler, nil);
end;

procedure TMCPServer.RegisterTool(const AName, ADescription: string;
  AArgsClass: TMCPArgsClass; AMethod: TMCPArgsMethod);
begin
  AddTypedTool(SchemaDefinition(AName, ADescription,
    SchemaFrom(AArgsClass).Build, nil), AArgsClass, nil, AMethod);
end;

procedure TMCPServer.RegisterTool(const AName, ADescription: string;
  AArgsClass: TMCPArgsClass; const AOutputSchema: TMCPSchema;
  AHandler: TMCPArgsHandler);
begin
  AddTypedTool(SchemaDefinition(AName, ADescription,
    SchemaFrom(AArgsClass).Build, AOutputSchema.Build),
    AArgsClass, AHandler, nil);
end;

procedure TMCPServer.RegisterTool(const AName, ADescription: string;
  AArgsClass: TMCPArgsClass; const AOutputSchema: TMCPSchema;
  AMethod: TMCPArgsMethod);
begin
  AddTypedTool(SchemaDefinition(AName, ADescription,
    SchemaFrom(AArgsClass).Build, AOutputSchema.Build),
    AArgsClass, nil, AMethod);
end;

// Populate one published property from its JSON argument. False (with
// AError set) on a type mismatch.
function BindProperty(AInstance: TMCPArgs; AProp: PPropInfo;
  AValue: TJSONData; out AError: string): Boolean;

  function Mismatch(const AExpected: string): Boolean;
  begin
    AError := Format('Argument "%s" must be %s',
      [AProp^.Name, AExpected]);
    Result := False;
  end;

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
      if (AValue.JSONType = jtNumber) and
        (TJSONNumber(AValue).NumberType in [ntInteger, ntInt64]) then
        SetOrdProp(AInstance, AProp, AValue.AsInteger)
      else
        Exit(Mismatch('an integer'));
    tkInt64, tkQWord:
      if (AValue.JSONType = jtNumber) and
        (TJSONNumber(AValue).NumberType in [ntInteger, ntInt64]) then
        SetInt64Prop(AInstance, AProp, AValue.AsInt64)
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

function TMCPServer.ToolCount: Integer;
begin
  Result := Length(FTools);
end;

function TMCPServer.ResourceCount: Integer;
begin
  Result := Length(FResources);
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

function TMCPServer.DispatchLegacyRequest(
  const AMessage: TJSONRPCMessage): string;
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

function TMCPServer.HandleInitialize(const AMessage: TJSONRPCMessage): string;
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

function TMCPServer.LegacyContext: TMCPRequestContext;
begin
  Result := Default(TMCPRequestContext);
  Result.ProtocolVersion := FLegacyProtocolVersion;
  Result.ClientName := FLegacyClientName;
  Result.ClientVersion := FLegacyClientVersion;
  Result.ClientCapabilities := FLegacyClientCapabilities;
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
        ToolResult := MCPErrorResult('Tool execution failed: ' + E.Message);
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
    Contents := MCPTextContents(Uri, MimeType, FResources[Index].StaticText);
    ReadTtlMs := FCacheTtlMs;
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

end.
