{ MCP.Apps.Test — MCP Apps (#98) and the extension negotiation under it:
  the UI resource declaration and read contents with _meta.ui, the
  tool link (_meta.ui and the legacy flat key), the startup check for a
  missing linked resource, the declared capability, and reading the
  client's extension settings. Wire lines asserted byte-exact, with
  non-ASCII HTML. Shapes verified 2026-11-26 against ext-apps
  specification/2026-01-26/apps.mdx and
  https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning#extension-negotiation }

program MCP.Apps.Test;

{$I MCP.inc}

uses
  SysUtils,

  fpjson,
  MCP.Apps,
  MCP.Protocol,
  MCP.Server,
  TestingPascalLibrary;

const
  HTML = '<!DOCTYPE html><html><body>Gr' + #$C3#$BC + #$C3#$9F + 'e</body></html>';
  META_UI_CLIENT =
    '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{"extensions":{' +
    '"io.modelcontextprotocol/ui":{"mimeTypes":["text/html;profile=mcp-app"]}}}}';
  META_PLAIN_CLIENT =
    '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{}}';

type
  TAppsSuite = class(TTestSuite)
  private
    FServer: TMCPServer;
    FSession: TMCPSession;
    function Send(const ALine: string): string;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;
    procedure TestNoExtensionUnlessUsed;
    procedure TestResourceDeclaration;
    procedure TestReadContentsCarryUiMeta;
    procedure TestToolLink;
    procedure TestMissingLinkedResourceFailsStartup;
    procedure TestClientExtensionSettings;
    procedure TestGuards;
  end;

function WeatherHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  // Meaningful content for every client, and a hint whether this one
  // renders the UI.
  Result := MCPTextResult('Sunny, ' + BoolToStr(
    ACtx.HasExtension(MCP_APPS_EXTENSION), 'with UI', 'text only') + ', ' +
    ACtx.ExtensionSettings(MCP_APPS_EXTENSION).Get('mimeTypes', TJSONArray(nil))
      .Items[0].AsString);
end;

function PlainHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPTextResult(BoolToStr(ACtx.HasExtension(MCP_APPS_EXTENSION),
    'ui', 'no ui'));
end;

function DynamicReader(const AUri: string;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  Result := MCPAppContents(AUri, HTML, MCPAppUiMeta([], [], [], [], [], '', 0));
end;

procedure TAppsSuite.BeforeEach;
begin
  FServer := TMCPServer.Create('apps', '1.0');
  FSession := nil;
end;

procedure TAppsSuite.AfterEach;
begin
  FreeAndNil(FSession);
  FreeAndNil(FServer);
end;

function TAppsSuite.Send(const ALine: string): string;
begin
  if FSession = nil then
    FSession := FServer.CreateSession;
  FServer.HandleMessage(FSession, ALine, Result);
end;

procedure TAppsSuite.TestNoExtensionUnlessUsed;
begin
  FServer.RegisterTool('plain', 'Plain', '{"type":"object"}', PlainHandler);
  Expect<Boolean>(Pos('extensions', Send('{"jsonrpc":"2.0","id":1,' +
    '"method":"server/discover","params":{' + META_PLAIN_CLIENT + '}}')) = 0)
    .ToBe(True);
end;

procedure TAppsSuite.TestResourceDeclaration;
var
  Line: string;
begin
  RegisterAppResource(FServer, 'ui://weather/dashboard', 'Dashboard', HTML,
    MCPAppUiMeta(['https://api.example.com'], ['https://cdn.example.com'], [],
    [], [apClipboardWrite], '', 1), 'Weather view');
  Line := Send('{"jsonrpc":"2.0","id":1,"method":"resources/list","params":{' +
    META_PLAIN_CLIENT + '}}');
  Expect<Boolean>(Pos('{ "uri" : "ui://weather/dashboard", "name" : ' +
    '"Dashboard", "mimeType" : "text/html;profile=mcp-app", "description" : ' +
    '"Weather view", "_meta" : { "ui" : { "csp" : { "connectDomains" : ' +
    '["https://api.example.com"], "resourceDomains" : ' +
    '["https://cdn.example.com"] }, "permissions" : { "clipboardWrite" : {} }, ' +
    '"prefersBorder" : true } } }', Line) > 0).ToBe(True);
  // Registering an app resource declares the extension.
  Expect<Boolean>(Pos('"extensions" : { "io.modelcontextprotocol/ui" : {} }',
    Send('{"jsonrpc":"2.0","id":2,"method":"server/discover","params":{' +
    META_PLAIN_CLIENT + '}}')) > 0).ToBe(True);
end;

procedure TAppsSuite.TestReadContentsCarryUiMeta;
var
  Line: string;
begin
  RegisterAppResource(FServer, 'ui://weather/static', 'Static', HTML,
    MCPAppUiMeta([], [], ['https://player.example.com'], []));
  RegisterAppResource(FServer, 'ui://weather/dynamic', 'Dynamic', DynamicReader);
  Line := Send('{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{' +
    '"uri":"ui://weather/static",' + META_PLAIN_CLIENT + '}}');
  Expect<Boolean>(Pos('"contents" : [{ "uri" : "ui://weather/static", ' +
    '"mimeType" : "text/html;profile=mcp-app", "text" : "' + HTML + '", ' +
    '"_meta" : { "ui" : { "csp" : { "frameDomains" : ' +
    '["https://player.example.com"] } } } }]', Line) > 0).ToBe(True);
  Line := Send('{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{' +
    '"uri":"ui://weather/dynamic",' + META_PLAIN_CLIENT + '}}');
  Expect<Boolean>(Pos('"_meta" : { "ui" : { "prefersBorder" : false } }', Line) > 0)
    .ToBe(True);
end;

procedure TAppsSuite.TestToolLink;
var
  Line: string;
begin
  RegisterAppResource(FServer, 'ui://weather/dashboard', 'Dashboard', HTML);
  FServer.RegisterTool('get_weather', 'Weather', '{"type":"object"}',
    WeatherHandler).AppResource('ui://weather/dashboard', ['model', 'app']);
  Line := Send('{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{' +
    META_PLAIN_CLIENT + '}}');
  Expect<Boolean>(Pos('"_meta" : { "ui" : { "resourceUri" : ' +
    '"ui://weather/dashboard", "visibility" : ["model", "app"] }, ' +
    '"ui/resourceUri" : "ui://weather/dashboard" }', Line) > 0).ToBe(True);
  Line := Send('{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{' +
    '"name":"get_weather",' + META_UI_CLIENT + '}}');
  Expect<Boolean>(Pos('"text" : "Sunny, with UI, text/html;profile=mcp-app"',
    Line) > 0).ToBe(True);
end;

procedure TAppsSuite.TestMissingLinkedResourceFailsStartup;
var
  Message: string;
begin
  FServer.RegisterTool('orphan', 'Orphan', '{"type":"object"}', PlainHandler)
    .AppResource('ui://nowhere', []);
  Message := '';
  try
    FServer.CreateSession.Free;
  except
    on E: EMCPServer do
      Message := E.Message;
  end;
  Expect<string>(Message).ToBe('Tool "orphan" links UI resource ' +
    '"ui://nowhere", which is not registered');
end;

procedure TAppsSuite.TestClientExtensionSettings;
begin
  FServer.RegisterTool('plain', 'Plain', '{"type":"object"}', PlainHandler);
  Expect<Boolean>(Pos('"text" : "ui"', Send('{"jsonrpc":"2.0","id":1,' +
    '"method":"tools/call","params":{"name":"plain",' + META_UI_CLIENT + '}}')) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('"text" : "no ui"', Send('{"jsonrpc":"2.0","id":2,' +
    '"method":"tools/call","params":{"name":"plain",' + META_PLAIN_CLIENT +
    '}}')) > 0).ToBe(True);
  // A malformed declaration (not an object) counts as absent.
  Expect<Boolean>(Pos('"text" : "no ui"', Send('{"jsonrpc":"2.0","id":3,' +
    '"method":"tools/call","params":{"name":"plain","_meta":{' +
    '"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{"extensions":{' +
    '"io.modelcontextprotocol/ui":true}}}}}')) > 0).ToBe(True);
end;

function RaisesServerError(AProc: TProcedure): Boolean;
begin
  Result := False;
  try
    AProc();
  except
    on E: EMCPServer do
      Result := True;
  end;
end;

var
  GuardServer: TMCPServer;

procedure NonUiUri;
begin
  RegisterAppResource(GuardServer, 'https://example.com/x', 'x', HTML);
end;

procedure BadVisibility;
begin
  RegisterAppResource(GuardServer, 'ui://x', 'x', HTML);
  GuardServer.RegisterTool('t', 't', '{"type":"object"}', PlainHandler)
    .AppResource('ui://x', ['everyone']);
end;

procedure BadExtensionId;
begin
  GuardServer.DeclareExtension('no-prefix');
end;

procedure TAppsSuite.TestGuards;
begin
  GuardServer := FServer;
  Expect<Boolean>(RaisesServerError(NonUiUri)).ToBe(True);
  Expect<Boolean>(RaisesServerError(BadVisibility)).ToBe(True);
  Expect<Boolean>(RaisesServerError(BadExtensionId)).ToBe(True);
  GuardServer := nil;
end;

procedure TAppsSuite.SetupTests;
begin
  Test('no extensions declared unless something opts in',
    TestNoExtensionUnlessUsed);
  Test('UI resource declaration with _meta.ui; extension declared',
    TestResourceDeclaration);
  Test('read contents carry _meta.ui for static and reader resources',
    TestReadContentsCarryUiMeta);
  Test('tool link writes _meta.ui and the legacy key; handler sees the client',
    TestToolLink);
  Test('a link to an unregistered UI resource fails at startup',
    TestMissingLinkedResourceFailsStartup);
  Test('HasExtension for present, absent and malformed declarations',
    TestClientExtensionSettings);
  Test('non-ui:// URIs, bad visibility and bad extension ids refused',
    TestGuards);
end;

begin
  TestRunnerProgram.AddSuite(TAppsSuite.Create('Apps: MCP Apps extension'));
  TestRunnerProgram.Run;
end.
