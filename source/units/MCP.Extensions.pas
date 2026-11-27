{ MCP.Extensions — the hooks an extension unit serves through (#115):
  request methods it adds, resources under a URI prefix that it reads
  without listing them, and objects whose lifetime the server owns.
  MCP.Server keeps one TMCPExtensionHooks and consults it after its own
  methods and resources; MCP.Skills is the first user. No I/O. }

unit MCP.Extensions;

{$I MCP.inc}

interface

uses
  SysUtils,

  fpjson,
  MCP.Protocol;

type
  // The core requests: those MCP.Server answers itself, and
  // subscriptions/listen, which it leaves unanswered. Dispatch selects
  // on this type, so a core method is always a reserved one too.
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
  public
    destructor Destroy; override;
    // '' once added; otherwise why not (an empty name, a nil handler, a
    // core method or one already added), and nothing is added.
    function AddMethod(const AName: string; AHandler: TMCPMethodHandler;
      ACacheable: Boolean): string;
    // Why AddMethod would refuse one of AMethods (repeats among them
    // included), or AddResolver APrefix ('' to check none); '' when all
    // would be added. Nothing changes, so a caller can check before it
    // adds any.
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
    // Whether some resolver's prefix starts AUri.
    function Covers(const AUri: string): Boolean;
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

implementation

const
  CORE_METHOD_NAMES: array[TMCPCoreMethod] of string = ('initialize',
    'ping', 'server/discover', 'tools/list', 'tools/call', 'resources/list',
    'resources/read', 'resources/templates/list', 'prompts/list',
    'prompts/get', 'completion/complete', 'subscriptions/listen');

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

function TMCPExtensionHooks.Preflight(const AMethods: array of string;
  const APrefix: string): string;
var
  I, J: Integer;
begin
  for I := 0 to High(AMethods) do
  begin
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
var
  I: Integer;
begin
  if AObject = nil then
    Exit;
  for I := 0 to High(FAdopted) do
    if FAdopted[I] = AObject then
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
