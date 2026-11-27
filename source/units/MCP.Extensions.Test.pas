{ MCP.Extensions.Test — the hooks extensions serve through (#115):
  methods answered after the core's in both eras, with cache fields and
  errors as written; resolvers for unlisted resources; adopted objects;
  and the registration guards. }

program MCP.Extensions.Test;

{$I MCP.inc}

uses
  SysUtils,

  fpjson,
  jsonparser,
  MCP.Extensions,
  MCP.JSONRPC,
  MCP.Protocol,
  MCP.Server,
  TestingPascalLibrary;

const
  META =
    '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{}}';

type
  // Handlers and a resolver the suite registers; it also counts the
  // objects freed with the server.
  THookFixture = class
  public
    function Echo(AParams: TJSONObject; const ACtx: TMCPRequestContext;
      ALegacy: Boolean): TJSONObject;
    function Refuse(AParams: TJSONObject; const ACtx: TMCPRequestContext;
      ALegacy: Boolean): TJSONObject;
    function Fail(AParams: TJSONObject; const ACtx: TMCPRequestContext;
      ALegacy: Boolean): TJSONObject;
    function Nothing(AParams: TJSONObject; const ACtx: TMCPRequestContext;
      ALegacy: Boolean): TJSONObject;
    function OwnTtl(AParams: TJSONObject; const ACtx: TMCPRequestContext;
      ALegacy: Boolean): TJSONObject;
    function TtlOnly(AParams: TJSONObject; const ACtx: TMCPRequestContext;
      ALegacy: Boolean): TJSONObject;
    function ScopeOnly(AParams: TJSONObject; const ACtx: TMCPRequestContext;
      ALegacy: Boolean): TJSONObject;
    function Read(const AUri: string;
      const ACtx: TMCPRequestContext): TJSONArray;
  end;

  TFreeProbe = class
  public
    destructor Destroy; override;
  end;

  THooksSuite = class(TTestSuite)
  private
    FFixture: THookFixture;
    FServer: TMCPServer;
    FSession: TMCPSession;
    function Send(const ALine: string): string;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;
    procedure TestMethodInBothEras;
    procedure TestCacheFields;
    procedure TestErrors;
    procedure TestResolver;
    procedure TestAdopt;
    procedure TestGuards;
    procedure TestPreflight;
  end;

var
  FreedProbes: Integer;

destructor TFreeProbe.Destroy;
begin
  Inc(FreedProbes);
  inherited Destroy;
end;

function THookFixture.Echo(AParams: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
begin
  Result := TJSONObject.Create(['legacy', ALegacy, 'said',
    AParams.Get('say', '')]);
end;

function THookFixture.Refuse(AParams: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
begin
  raise EMCPProtocolError.Create(JSONRPC_INVALID_PARAMS, 'No such thing',
    TJSONObject.Create(['what', 'thing']));
end;

function THookFixture.Fail(AParams: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
begin
  raise Exception.Create('broken');
end;

function THookFixture.Nothing(AParams: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
begin
  Result := nil;
end;

function THookFixture.OwnTtl(AParams: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
begin
  Result := TJSONObject.Create(['ttlMs', 5, 'cacheScope', 'public']);
end;

function THookFixture.TtlOnly(AParams: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
begin
  Result := TJSONObject.Create(['ttlMs', 7]);
end;

function THookFixture.ScopeOnly(AParams: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
begin
  Result := TJSONObject.Create(['cacheScope', 'public']);
end;

function THookFixture.Read(const AUri: string;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  if AUri = 'memo://a/known' then
    Exit(MCPTextContents(AUri, 'text/plain', 'known'));
  Result := nil;
end;

procedure THooksSuite.BeforeEach;
begin
  FFixture := THookFixture.Create;
  FServer := TMCPServer.Create('hooks', '1.0');
  FSession := nil;
end;

procedure THooksSuite.AfterEach;
begin
  FreeAndNil(FSession);
  FreeAndNil(FServer);
  FreeAndNil(FFixture);
end;

function THooksSuite.Send(const ALine: string): string;
begin
  if FSession = nil then
    FSession := FServer.CreateSession;
  FServer.HandleMessage(FSession, ALine, Result);
end;

// After the core methods, in both eras, stamped for each.
procedure THooksSuite.TestMethodInBothEras;
begin
  FServer.RegisterMethod('example/echo', FFixture.Echo);
  Expect<string>(Send('{"jsonrpc":"2.0","id":1,"method":"example/echo",' +
    '"params":{"say":"hi",' + META + '}}')).ToBe('{ "jsonrpc" : "2.0", ' +
    '"id" : 1, "result" : { "legacy" : false, "said" : "hi", "resultType" : ' +
    '"complete", "_meta" : { "io.modelcontextprotocol/serverInfo" : ' +
    '{ "name" : "hooks", "version" : "1.0" } } } }');
  FreeAndNil(FSession);
  Send('{"jsonrpc":"2.0","id":1,"method":"initialize","params":' +
    '{"protocolVersion":"2025-11-25","capabilities":{},' +
    '"clientInfo":{"name":"c","version":"1"}}}');
  Send('{"jsonrpc":"2.0","method":"notifications/initialized"}');
  Expect<string>(Send('{"jsonrpc":"2.0","id":2,"method":"example/echo",' +
    '"params":{"say":"ho"}}')).ToBe('{ "jsonrpc" : "2.0", "id" : 2, ' +
    '"result" : { "legacy" : true, "said" : "ho" } }');
end;

// The registry's cache fields on a modern result that has none.
procedure THooksSuite.TestCacheFields;
var
  Line: string;
begin
  FServer.CacheTtlMs := 1234;
  FServer.RegisterMethod('example/cached', FFixture.Echo, True);
  FServer.RegisterMethod('example/own', FFixture.OwnTtl, True);
  Line := Send('{"jsonrpc":"2.0","id":1,"method":"example/cached",' +
    '"params":{' + META + '}}');
  Expect<Boolean>(Pos('"ttlMs" : 1234, "cacheScope" : "private"', Line) > 0)
    .ToBe(True);
  Line := Send('{"jsonrpc":"2.0","id":2,"method":"example/own",' +
    '"params":{' + META + '}}');
  Expect<Boolean>(Pos('"ttlMs" : 5, "cacheScope" : "public"', Line) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('1234', Line) = 0).ToBe(True);
  // Each missing field from the registry, the given one kept.
  FreeAndNil(FSession);
  FreeAndNil(FServer);
  FServer := TMCPServer.Create('hooks', '1.0');
  FServer.CacheTtlMs := 1234;
  FServer.RegisterMethod('example/ttl', FFixture.TtlOnly, True);
  FServer.RegisterMethod('example/scope', FFixture.ScopeOnly, True);
  Line := Send('{"jsonrpc":"2.0","id":3,"method":"example/ttl",' +
    '"params":{' + META + '}}');
  Expect<Boolean>(Pos('"ttlMs" : 7, "cacheScope" : "private"', Line) > 0)
    .ToBe(True);
  Line := Send('{"jsonrpc":"2.0","id":4,"method":"example/scope",' +
    '"params":{' + META + '}}');
  Expect<Boolean>(Pos('"cacheScope" : "public", "ttlMs" : 1234', Line) > 0)
    .ToBe(True);
end;

// A protocol error as written; anything else, and no result, -32603;
// an unknown method -32601.
procedure THooksSuite.TestErrors;
var
  Line: string;
begin
  FServer.RegisterMethod('example/refuse', FFixture.Refuse);
  FServer.RegisterMethod('example/fail', FFixture.Fail);
  FServer.RegisterMethod('example/nothing', FFixture.Nothing);
  Expect<string>(Send('{"jsonrpc":"2.0","id":1,"method":"example/refuse",' +
    '"params":{' + META + '}}')).ToBe('{ "jsonrpc" : "2.0", "id" : 1, ' +
    '"error" : { "code" : -32602, "message" : "No such thing", "data" : ' +
    '{ "what" : "thing" } } }');
  Line := Send('{"jsonrpc":"2.0","id":2,"method":"example/fail",' +
    '"params":{' + META + '}}');
  Expect<Boolean>(Pos('"code" : -32603', Line) > 0).ToBe(True);
  Line := Send('{"jsonrpc":"2.0","id":3,"method":"example/nothing",' +
    '"params":{' + META + '}}');
  Expect<Boolean>(Pos('"code" : -32603', Line) > 0).ToBe(True);
  Line := Send('{"jsonrpc":"2.0","id":4,"method":"example/absent",' +
    '"params":{' + META + '}}');
  Expect<Boolean>(Pos('"code" : -32601', Line) > 0).ToBe(True);
end;

// Unlisted resources under a prefix, at the registry ttl, with the
// resources capability; a URI the resolver does not know is not found.
procedure THooksSuite.TestResolver;
var
  Line: string;
begin
  FServer.RegisterResourceResolver('memo://a/', FFixture.Read);
  Line := Send('{"jsonrpc":"2.0","id":1,"method":"server/discover",' +
    '"params":{' + META + '}}');
  Expect<Boolean>(Pos('"capabilities" : { "resources" : {} }', Line) > 0)
    .ToBe(True);
  Line := Send('{"jsonrpc":"2.0","id":2,"method":"resources/read",' +
    '"params":{"uri":"memo://a/known",' + META + '}}');
  Expect<Boolean>(Pos('"contents" : [{ "uri" : "memo://a/known", ' +
    '"mimeType" : "text/plain", "text" : "known" }], "ttlMs" : 300000', Line) >
    0).ToBe(True);
  Line := Send('{"jsonrpc":"2.0","id":3,"method":"resources/read",' +
    '"params":{"uri":"memo://a/other",' + META + '}}');
  Expect<Boolean>(Pos('"code" : -32602', Line) > 0).ToBe(True);
  Line := Send('{"jsonrpc":"2.0","id":4,"method":"resources/list",' +
    '"params":{' + META + '}}');
  Expect<Boolean>(Pos('"resources" : []', Line) > 0).ToBe(True);
end;

// Adopted objects are found by class and freed with the server.
procedure THooksSuite.TestAdopt;
var
  Probe: TFreeProbe;
  Raised: Boolean;
begin
  FreedProbes := 0;
  Probe := TFreeProbe.Create;
  FServer.Adopt(Probe);
  // Adopting again changes nothing: one free.
  FServer.Adopt(Probe);
  Expect<Boolean>(FServer.Adopted(TFreeProbe) = Probe).ToBe(True);
  Expect<Boolean>(FServer.Adopted(THookFixture) = nil).ToBe(True);
  FreeAndNil(FServer);
  Expect<Integer>(FreedProbes).ToBe(1);
  // After the server started, adoption is refused and the object freed.
  FServer := TMCPServer.Create('hooks', '1.0');
  Send('{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{' +
    META + '}}');
  try
    FServer.Adopt(TFreeProbe.Create);
  except
    on E: EMCPServer do
      ;
  end;
  Expect<Integer>(FreedProbes).ToBe(2);
  Expect<Boolean>(FServer.Adopted(TFreeProbe) = nil).ToBe(True);
  // An object the server owns, offered again after the start: refused,
  // not freed, and freed once with the server (#115 review).
  FreeAndNil(FSession);
  FreeAndNil(FServer);
  FServer := TMCPServer.Create('hooks', '1.0');
  Probe := TFreeProbe.Create;
  FServer.Adopt(Probe);
  Send('{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{' +
    META + '}}');
  Raised := False;
  try
    FServer.Adopt(Probe);
  except
    on E: EMCPServer do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  Expect<Integer>(FreedProbes).ToBe(2);
  FreeAndNil(FSession);
  FreeAndNil(FServer);
  Expect<Integer>(FreedProbes).ToBe(3);
end;

var
  GuardServer: TMCPServer;
  GuardFixture: THookFixture;

procedure CoreMethod;
begin
  GuardServer.RegisterMethod('tools/list', GuardFixture.Echo);
end;

procedure UnansweredCoreMethod;
begin
  GuardServer.RegisterMethod('subscriptions/listen', GuardFixture.Echo);
end;

procedure SecondTime;
begin
  GuardServer.RegisterMethod('example/x', GuardFixture.Echo);
end;

procedure NoHandler;
begin
  GuardServer.RegisterMethod('example/y', nil);
end;

procedure OverlappingPrefix;
begin
  GuardServer.RegisterResourceResolver('memo://a/b/', GuardFixture.Read);
end;

procedure EmptyPrefix;
begin
  GuardServer.RegisterResourceResolver('', GuardFixture.Read);
end;

procedure LateMethod;
begin
  GuardServer.RegisterMethod('example/late', GuardFixture.Echo);
end;

function Raises(AProc: TProcedure): Boolean;
begin
  Result := False;
  try
    AProc();
  except
    on E: EMCPServer do
      Result := True;
  end;
end;

// HookProblem names what would be refused, and changes nothing.
procedure THooksSuite.TestPreflight;
begin
  FServer.RegisterResourceResolver('memo://a/', FFixture.Read);
  Expect<string>(FServer.HookProblem(['example/a', 'example/b'], 'memo://b/'))
    .ToBe('');
  Expect<string>(FServer.HookProblem(['example/a', 'example/a'], ''))
    .ToBe('Method "example/a" is given twice');
  Expect<string>(FServer.HookProblem(['prompts/get'], ''))
    .ToBe('"prompts/get" is a core method');
  Expect<string>(FServer.HookProblem([], 'memo://')).ToBe('URI prefix ' +
    '"memo://" overlaps "memo://a/"');
  FServer.RegisterMethod('example/a', FFixture.Echo);
  Expect<string>(FServer.HookProblem(['example/a'], ''))
    .ToBe('Method "example/a" is already registered');
  Send('{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{' +
    META + '}}');
  Expect<string>(FServer.HookProblem([], '')).ToBe('Server configuration is ' +
    'frozen after session creation');
end;

procedure THooksSuite.TestGuards;
begin
  GuardServer := FServer;
  GuardFixture := FFixture;
  try
    FServer.RegisterMethod('example/x', FFixture.Echo);
    FServer.RegisterResourceResolver('memo://a/', FFixture.Read);
    Expect<Boolean>(Raises(CoreMethod)).ToBe(True);
    Expect<Boolean>(Raises(UnansweredCoreMethod)).ToBe(True);
    Expect<Boolean>(Raises(SecondTime)).ToBe(True);
    Expect<Boolean>(Raises(NoHandler)).ToBe(True);
    Expect<Boolean>(Raises(OverlappingPrefix)).ToBe(True);
    Expect<Boolean>(Raises(EmptyPrefix)).ToBe(True);
    // Nothing after the server started.
    Send('{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{' +
      META + '}}');
    Expect<Boolean>(Raises(LateMethod)).ToBe(True);
  finally
    GuardServer := nil;
    GuardFixture := nil;
  end;
end;

procedure THooksSuite.SetupTests;
begin
  Test('an extension method answers in both eras, stamped for each',
    TestMethodInBothEras);
  Test('cache fields are added to a modern result that has none',
    TestCacheFields);
  Test('protocol errors as written, faults -32603, unknown -32601',
    TestErrors);
  Test('a resolver serves unlisted resources under its prefix',
    TestResolver);
  Test('adopted objects are found and freed with the server', TestAdopt);
  Test('core methods, repeats, nil handlers and overlaps are refused',
    TestGuards);
  Test('HookProblem names a refusal without changing anything',
    TestPreflight);
end;

begin
  TestRunnerProgram.AddSuite(THooksSuite.Create('Extensions: hooks'));
  TestRunnerProgram.Run;
end.
