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
    // AObject (owned from here) is freed with the hooks, after every
    // handler is gone; Adopted finds the first one of class AClass.
    procedure Adopt(AObject: TObject);
    function Adopted(AClass: TClass): TObject;
  end;

// Whether MCP.Server answers AName itself, in either era, so no
// extension may add it.
function IsBuiltInMethod(const AName: string): Boolean;

implementation

const
  // The core requests: those MCP.Server dispatches before the hooks,
  // and subscriptions/listen, which it leaves unanswered.
  BUILT_IN_METHODS: array[0..11] of string = ('initialize', 'ping',
    'server/discover', 'tools/list', 'tools/call', 'resources/list',
    'resources/read', 'resources/templates/list', 'prompts/list',
    'prompts/get', 'completion/complete', 'subscriptions/listen');

function IsBuiltInMethod(const AName: string): Boolean;
var
  Name: string;
begin
  for Name in BUILT_IN_METHODS do
    if Name = AName then
      Exit(True);
  Result := False;
end;

destructor TMCPExtensionHooks.Destroy;
var
  I: Integer;
begin
  for I := High(FAdopted) downto 0 do
    FAdopted[I].Free;
  inherited Destroy;
end;

function TMCPExtensionHooks.AddMethod(const AName: string;
  AHandler: TMCPMethodHandler; ACacheable: Boolean): string;
var
  Handler: TMCPMethodHandler;
  Cacheable: Boolean;
  Slot: Integer;
begin
  if (AName = '') or not Assigned(AHandler) then
    Exit('An extension method needs a name and a handler');
  if IsBuiltInMethod(AName) then
    Exit(Format('"%s" is a core method', [AName]));
  if FindMethod(AName, Handler, Cacheable) then
    Exit(Format('Method "%s" is already registered', [AName]));
  Result := '';
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

function TMCPExtensionHooks.AddResolver(const APrefix: string;
  AResolver: TMCPResourceResolver): string;
var
  I, Slot: Integer;
begin
  if (APrefix = '') or not Assigned(AResolver) then
    Exit('A resource resolver needs a URI prefix and a resolver');
  // One resolver per URI, so the order they were added never matters.
  for I := 0 to High(FResolvers) do
    if StartsWith(APrefix, FResolvers[I].Prefix) or
      StartsWith(FResolvers[I].Prefix, APrefix) then
      Exit(Format('URI prefix "%s" overlaps "%s"', [APrefix,
        FResolvers[I].Prefix]));
  Result := '';
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

procedure TMCPExtensionHooks.Adopt(AObject: TObject);
begin
  if AObject = nil then
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
