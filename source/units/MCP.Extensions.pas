{ MCP.Extensions — the hooks an extension unit serves through (#115):
  request methods it adds, resources under a URI prefix that it reads
  without listing them, objects whose lifetime the server owns, and a
  hook that may take a tools/call over before its handler runs (#82).
  MCP.Server keeps one TMCPExtensionHooks and consults it after its own
  methods and resources; MCP.Skills is the first user. No I/O. }

unit MCP.Extensions;

{$I MCP.inc}

interface

uses
  SysUtils,

  fpjson,
  MCP.Protocol,
  MCP.Schema;

type
  // The core requests: those MCP.Server answers itself, and
  // subscriptions/listen, which it answers through the listen handler
  // when a unit sets one (MCP.Subscriptions, #138) and with -32601
  // otherwise. Dispatch selects on this type, so a core method is always
  // a reserved one too.
  TMCPCoreMethod = (cmInitialize, cmPing, cmServerDiscover, cmToolsList,
    cmToolsCall, cmResourcesList, cmResourcesRead, cmResourcesTemplatesList,
    cmPromptsList, cmPromptsGet, cmCompletionComplete, cmSubscriptionsListen);

  // A request an extension serves: the result object (new, the
  // caller's; the server stamps and sends it) for AParams (borrowed;
  // nil when the request has none). ALegacy is true for a client on the
  // classic handshake. Raise EMCPProtocolError (MCP.Server) to answer a
  // JSON-RPC error.
  TMCPMethodHandler = function(AParams: TJSONObject;
    const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject of object;

  // resources/read for a URI under a resolver's prefix: the contents
  // (new, the caller's), or nil when AUri is none of its resources.
  TMCPResourceResolver = function(const AUri: string;
    const ACtx: TMCPRequestContext): TJSONArray of object;

  // The x-mcp-header parameters of the entity named AName (an event
  // type, say), for the Streamable HTTP Mcp-Param-* check; none when it
  // is unknown.
  TMCPHeaderLookup = function(const AName: string): TMCPHeaderParameters
    of object;

  // A tools/call for tool AToolName, seen before its handler runs (#82):
  // nil lets the call run as usual; otherwise the result to send in its
  // place (new, the caller's; the server stamps and sends it), such as
  // the Tasks extension's CreateTaskResult. AArguments (the call's
  // arguments, {} when it has none) and everything ACtx borrows are
  // valid for the call only, so clone what you keep. ALegacy is true for
  // a client on the classic handshake. Raise EMCPProtocolError to
  // answer a JSON-RPC error.
  TMCPToolCallHook = function(const AToolName: string;
    AArguments: TJSONObject; const ACtx: TMCPRequestContext;
    ALegacy: Boolean): TJSONObject of object;
  // Stops the work a tool-call hook started and waits for it, before the
  // server frees anything (#82 review).
  TMCPDrain = procedure of object;

  TMCPExtensionHooks = class
  private
    FMethods: array of record
      Name: string;
      Handler: TMCPMethodHandler;
      Cacheable: Boolean;
    end;
    FResolvers: array of record
      Prefix: string;
      Resolver: TMCPResourceResolver;
    end;
    FAdopted: array of TObject;
    FModernOnly: array of string;
    FPinned: TJSONObject; // owned: settings that replace a declaration
    FRoutes: array of record
      Method, NameParam: string;
      Headers: TMCPHeaderLookup;
    end;
    FToolCallHook: TMCPToolCallHook;
    FToolCallDrain: TMCPDrain;
  public
    destructor Destroy; override;
    // '' once added; otherwise why not (an empty name, a nil handler, a
    // core method or one already added), and nothing is added.
    function AddMethod(const AName: string; AHandler: TMCPMethodHandler;
      ACacheable: Boolean): string;
    // Why AddMethod would refuse one of AMethods (repeats among them
    // included), or AddResolver APrefix ('' to check none); '' when all
    // would be added. subscriptions/listen among AMethods asks whether
    // SetListenHandler would refuse instead. Nothing changes, so a caller
    // can check before it adds any.
    function Preflight(const AMethods: array of string;
      const APrefix: string): string;
    function FindMethod(const AName: string; out AHandler: TMCPMethodHandler;
      out ACacheable: Boolean): Boolean;
    // '' once added; otherwise why not (an empty prefix, a nil resolver
    // or a prefix that overlaps one already added).
    function AddResolver(const APrefix: string;
      AResolver: TMCPResourceResolver): string;
    // The contents from the resolver whose prefix AUri starts with, or
    // nil.
    function Resolve(const AUri: string;
      const ACtx: TMCPRequestContext): TJSONArray;
    function HasResolvers: Boolean;
    // '' once AMethod (added with AddMethod) routes: on Streamable HTTP
    // its Mcp-Name header mirrors params.ANameParam and, with AHeaders,
    // its Mcp-Param-* headers mirror params.arguments as AHeaders gives
    // them; otherwise why not.
    function AddRoute(const AMethod, ANameParam: string;
      AHeaders: TMCPHeaderLookup): string;
    function FindRoute(const AMethod: string; out ANameParam: string;
      out AHeaders: TMCPHeaderLookup): Boolean;
    // '' once AHook sees every tools/call, with ADrain (nil for none) to
    // stop what it started; otherwise why not (a nil hook, or a hook set
    // already: one extension takes tool calls over).
    function SetToolCallHook(AHook: TMCPToolCallHook;
      ADrain: TMCPDrain): string;
    // Runs the tool-call hook's drain, once: the server calls it before
    // it frees anything, adopted objects included. Safe on nil.
    procedure Drain;
    // What the tool-call hook answers for a call (see TMCPToolCallHook);
    // nil without a hook.
    function TakeToolCall(const AToolName: string; AArguments: TJSONObject;
      const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
    // '' once AHandler answers subscriptions/listen; otherwise why not (a
    // nil handler, or one set already: one unit serves the method).
    function SetListenHandler(AHandler: TMCPMethodHandler): string;
    // Extension AId is left out of the classic capabilities.
    procedure RestrictToModern(const AId: string);
    // Extension AId is answered with ASettings (owned), replacing what
    // was declared.
    procedure PinSettings(const AId: string; ASettings: TJSONObject);
    // The extensions to declare (new, the caller's; nil for none): a
    // clone of ADeclared (borrowed) with pinned settings in place,
    // without the modern-only ones when ALegacy.
    function ExtensionsFor(ADeclared: TJSONObject;
      ALegacy: Boolean): TJSONObject;
    // Whether some resolver's prefix starts AUri.
    function Covers(const AUri: string): Boolean;
    // Whether AObject is adopted already.
    function Owns(AObject: TObject): Boolean;
    // AObject (owned from here) is freed with the hooks, after every
    // handler is gone; adopting it again changes nothing. Adopted finds
    // the first one of class AClass.
    procedure Adopt(AObject: TObject);
    function Adopted(AClass: TClass): TObject;
  end;

// The core method named AName, if it is one.
function FindCoreMethod(const AName: string;
  out AMethod: TMCPCoreMethod): Boolean;
// Whether AName is a core method, so no extension may add it.
function IsBuiltInMethod(const AName: string): Boolean;

// The literal text of AUriTemplate before its first variable: every URI
// the template matches starts with it.
function TemplateLiteralPrefix(const AUriTemplate: string): string;

// Adds ttlMs (ATtlMs) and cacheScope (AScope) to AResult (borrowed),
// each only when it is missing, so a handler's own values stay.
procedure AddMissingCacheFields(AResult: TJSONObject; ATtlMs: Integer;
  const AScope: string);

implementation

const
  LISTEN_METHOD = 'subscriptions/listen';
  CORE_METHOD_NAMES: array[TMCPCoreMethod] of string = ('initialize',
    'ping', 'server/discover', 'tools/list', 'tools/call', 'resources/list',
    'resources/read', 'resources/templates/list', 'prompts/list',
    'prompts/get', 'completion/complete', LISTEN_METHOD);

function FindCoreMethod(const AName: string;
  out AMethod: TMCPCoreMethod): Boolean;
var
  Method: TMCPCoreMethod;
begin
  for Method := Low(TMCPCoreMethod) to High(TMCPCoreMethod) do
    if CORE_METHOD_NAMES[Method] = AName then
    begin
      AMethod := Method;
      Exit(True);
    end;
  AMethod := Low(TMCPCoreMethod);
  Result := False;
end;

function IsBuiltInMethod(const AName: string): Boolean;
var
  Method: TMCPCoreMethod;
begin
  Result := FindCoreMethod(AName, Method);
end;

destructor TMCPExtensionHooks.Destroy;
var
  I: Integer;
begin
  FPinned.Free;
  for I := High(FAdopted) downto 0 do
    FAdopted[I].Free;
  inherited Destroy;
end;

// Why AName cannot be added, ignoring the handler: '' when it can.
function MethodNameProblem(AHooks: TMCPExtensionHooks;
  const AName: string): string;
var
  Handler: TMCPMethodHandler;
  Cacheable: Boolean;
begin
  Result := '';
  if AName = '' then
    Result := 'An extension method needs a name and a handler'
  else if IsBuiltInMethod(AName) then
    Result := Format('"%s" is a core method', [AName])
  else if AHooks.FindMethod(AName, Handler, Cacheable) then
    Result := Format('Method "%s" is already registered', [AName]);
end;

function TMCPExtensionHooks.AddMethod(const AName: string;
  AHandler: TMCPMethodHandler; ACacheable: Boolean): string;
var
  Slot: Integer;
begin
  if not Assigned(AHandler) then
    Exit('An extension method needs a name and a handler');
  Result := MethodNameProblem(Self, AName);
  if Result <> '' then
    Exit;
  Slot := Length(FMethods);
  SetLength(FMethods, Slot + 1);
  FMethods[Slot].Name := AName;
  FMethods[Slot].Handler := AHandler;
  FMethods[Slot].Cacheable := ACacheable;
end;

function TMCPExtensionHooks.FindMethod(const AName: string;
  out AHandler: TMCPMethodHandler; out ACacheable: Boolean): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FMethods) do
    if FMethods[I].Name = AName then
    begin
      AHandler := FMethods[I].Handler;
      ACacheable := FMethods[I].Cacheable;
      Exit(True);
    end;
  AHandler := nil;
  ACacheable := False;
  Result := False;
end;

function StartsWith(const AText, APrefix: string): Boolean;
begin
  Result := Copy(AText, 1, Length(APrefix)) = APrefix;
end;

function ListenProblem(AHooks: TMCPExtensionHooks): string;
var
  Handler: TMCPMethodHandler;
  Cacheable: Boolean;
begin
  Result := '';
  if AHooks.FindMethod(LISTEN_METHOD, Handler, Cacheable) then
    Result := 'A subscriptions/listen handler is already set';
end;

function TMCPExtensionHooks.Preflight(const AMethods: array of string;
  const APrefix: string): string;
var
  I, J: Integer;
begin
  for I := 0 to High(AMethods) do
  begin
    // subscriptions/listen asks whether SetListenHandler would refuse
    // (#138): no extension adds it, but one unit may serve it.
    if AMethods[I] = LISTEN_METHOD then
      Result := ListenProblem(Self)
    else
      Result := MethodNameProblem(Self, AMethods[I]);
    if Result <> '' then
      Exit;
    for J := 0 to I - 1 do
      if AMethods[J] = AMethods[I] then
        Exit(Format('Method "%s" is given twice', [AMethods[I]]));
  end;
  Result := '';
  if APrefix = '' then
    Exit;
  for I := 0 to High(FResolvers) do
    if StartsWith(APrefix, FResolvers[I].Prefix) or
      StartsWith(FResolvers[I].Prefix, APrefix) then
      Exit(Format('URI prefix "%s" overlaps "%s"', [APrefix,
        FResolvers[I].Prefix]));
end;

function TMCPExtensionHooks.AddResolver(const APrefix: string;
  AResolver: TMCPResourceResolver): string;
var
  Slot: Integer;
begin
  if (APrefix = '') or not Assigned(AResolver) then
    Exit('A resource resolver needs a URI prefix and a resolver');
  // One resolver per URI, so the order they were added never matters.
  Result := Preflight([], APrefix);
  if Result <> '' then
    Exit;
  Slot := Length(FResolvers);
  SetLength(FResolvers, Slot + 1);
  FResolvers[Slot].Prefix := APrefix;
  FResolvers[Slot].Resolver := AResolver;
end;

function TMCPExtensionHooks.Resolve(const AUri: string;
  const ACtx: TMCPRequestContext): TJSONArray;
var
  I: Integer;
begin
  for I := 0 to High(FResolvers) do
    if StartsWith(AUri, FResolvers[I].Prefix) then
      Exit(FResolvers[I].Resolver(AUri, ACtx));
  Result := nil;
end;

function TMCPExtensionHooks.HasResolvers: Boolean;
begin
  Result := Length(FResolvers) > 0;
end;

function TemplateLiteralPrefix(const AUriTemplate: string): string;
var
  Brace: Integer;
begin
  Brace := Pos('{', AUriTemplate);
  if Brace = 0 then
    Exit(AUriTemplate);
  Result := Copy(AUriTemplate, 1, Brace - 1);
end;

procedure AddMissingCacheFields(AResult: TJSONObject; ATtlMs: Integer;
  const AScope: string);
begin
  if AResult.Find('ttlMs') = nil then
    AResult.Add('ttlMs', ATtlMs);
  if AResult.Find('cacheScope') = nil then
    AResult.Add('cacheScope', AScope);
end;

function TMCPExtensionHooks.AddRoute(const AMethod, ANameParam: string;
  AHeaders: TMCPHeaderLookup): string;
var
  Handler: TMCPMethodHandler;
  Cacheable: Boolean;
  NameParam: string;
  Headers: TMCPHeaderLookup;
  Slot: Integer;
begin
  if not FindMethod(AMethod, Handler, Cacheable) or (ANameParam = '') then
    Exit(Format('Route "%s" needs a registered method and a name ' +
      'parameter', [AMethod]));
  if FindRoute(AMethod, NameParam, Headers) then
    Exit(Format('Method "%s" is routed already', [AMethod]));
  Result := '';
  Slot := Length(FRoutes);
  SetLength(FRoutes, Slot + 1);
  FRoutes[Slot].Method := AMethod;
  FRoutes[Slot].NameParam := ANameParam;
  FRoutes[Slot].Headers := AHeaders;
end;

function TMCPExtensionHooks.FindRoute(const AMethod: string;
  out ANameParam: string; out AHeaders: TMCPHeaderLookup): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FRoutes) do
    if FRoutes[I].Method = AMethod then
    begin
      ANameParam := FRoutes[I].NameParam;
      AHeaders := FRoutes[I].Headers;
      Exit(True);
    end;
  ANameParam := '';
  AHeaders := nil;
  Result := False;
end;

function TMCPExtensionHooks.SetToolCallHook(AHook: TMCPToolCallHook;
  ADrain: TMCPDrain): string;
begin
  if not Assigned(AHook) then
    Exit('A tool-call hook must not be nil');
  if Assigned(FToolCallHook) then
    Exit('A tool-call hook is already set');
  FToolCallHook := AHook;
  FToolCallDrain := ADrain;
  Result := '';
end;

procedure TMCPExtensionHooks.Drain;
var
  Pending: TMCPDrain;
begin
  // A server whose constructor raised has no hooks yet: nothing to drain.
  if Self = nil then
    Exit;
  Pending := FToolCallDrain;
  FToolCallDrain := nil;
  if Assigned(Pending) then
    Pending();
end;

function TMCPExtensionHooks.SetListenHandler(
  AHandler: TMCPMethodHandler): string;
var
  Slot: Integer;
begin
  if not Assigned(AHandler) then
    Exit('A subscriptions/listen handler must not be nil');
  Result := ListenProblem(Self);
  if Result <> '' then
    Exit;
  // Held among the methods, though AddMethod refuses a core one, so
  // dispatch finds it the way it finds an extension's.
  Slot := Length(FMethods);
  SetLength(FMethods, Slot + 1);
  FMethods[Slot].Name := LISTEN_METHOD;
  FMethods[Slot].Handler := AHandler;
  FMethods[Slot].Cacheable := False;
  Result := '';
end;

function TMCPExtensionHooks.TakeToolCall(const AToolName: string;
  AArguments: TJSONObject; const ACtx: TMCPRequestContext;
  ALegacy: Boolean): TJSONObject;
begin
  Result := nil;
  if Assigned(FToolCallHook) then
    Result := FToolCallHook(AToolName, AArguments, ACtx, ALegacy);
end;

procedure TMCPExtensionHooks.RestrictToModern(const AId: string);
begin
  SetLength(FModernOnly, Length(FModernOnly) + 1);
  FModernOnly[High(FModernOnly)] := AId;
end;

procedure TMCPExtensionHooks.PinSettings(const AId: string;
  ASettings: TJSONObject);
begin
  if FPinned = nil then
    FPinned := TJSONObject.Create;
  FPinned.Delete(AId);
  FPinned.Add(AId, ASettings);
end;

function TMCPExtensionHooks.ExtensionsFor(ADeclared: TJSONObject;
  ALegacy: Boolean): TJSONObject;
var
  I: Integer;
begin
  Result := nil;
  if ADeclared.Count = 0 then
    Exit;
  Result := TJSONObject(ADeclared.Clone);
  if FPinned <> nil then
    for I := 0 to FPinned.Count - 1 do
      if Result.IndexOfName(FPinned.Names[I]) >= 0 then
      begin
        Result.Delete(FPinned.Names[I]);
        Result.Add(FPinned.Names[I], FPinned.Items[I].Clone);
      end;
  if ALegacy then
    for I := 0 to High(FModernOnly) do
      Result.Delete(FModernOnly[I]);
  if Result.Count = 0 then
    FreeAndNil(Result);
end;

function TMCPExtensionHooks.Owns(AObject: TObject): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FAdopted) do
    if FAdopted[I] = AObject then
      Exit(True);
  Result := False;
end;

function TMCPExtensionHooks.Covers(const AUri: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FResolvers) do
    if StartsWith(AUri, FResolvers[I].Prefix) then
      Exit(True);
  Result := False;
end;

procedure TMCPExtensionHooks.Adopt(AObject: TObject);
begin
  if (AObject = nil) or Owns(AObject) then
    Exit;
  SetLength(FAdopted, Length(FAdopted) + 1);
  FAdopted[High(FAdopted)] := AObject;
end;

function TMCPExtensionHooks.Adopted(AClass: TClass): TObject;
var
  I: Integer;
begin
  for I := 0 to High(FAdopted) do
    if FAdopted[I] is AClass then
      Exit(FAdopted[I]);
  Result := nil;
end;

end.
