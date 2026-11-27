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
    procedure TestSettingsInBothEras;
    procedure TestClassicClientDeclarations;
    procedure TestExplicitSettingsKept;
    procedure TestOtherMetaUiNotChecked;
    procedure TestFailedStartCanBeRetried;
    procedure TestNilChildrenAndEmptyName;
    procedure TestClientRendersApps;
    procedure TestEachOptInDeclares;
    procedure TestLinkedResourceMediaType;
    procedure TestRelinkReplacesRequirement;
    procedure TestLaterMetaChecked;
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

function RendersHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPTextResult(BoolToStr(MCPClientRendersApps(ACtx), 'renders',
    'does not render') + '|' + BoolToStr(ACtx.HasExtension(MCP_APPS_EXTENSION),
    'declared', 'undeclared'));
end;

// What a handler sees of the client's Apps declaration: the first of
// its mimeTypes, or 'no ui'.
function SettingsHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Types: TJSONArray;
begin
  if not ACtx.HasExtension(MCP_APPS_EXTENSION) then
    Exit(MCPTextResult('no ui'));
  Types := ACtx.ExtensionSettings(MCP_APPS_EXTENSION).Get('mimeTypes',
    TJSONArray(nil));
  if (Types = nil) or (Types.Count = 0) then
    Result := MCPTextResult('ui without mimeTypes')
  else
    Result := MCPTextResult('ui ' + Types.Items[0].AsString);
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
var
  Line: string;
begin
  FServer.RegisterTool('plain', 'Plain', '{"type":"object"}', PlainHandler);
  Line := Send('{"jsonrpc":"2.0","id":1,"method":"server/discover",' +
    '"params":{' + META_PLAIN_CLIENT + '}}');
  // A successful answer, with capabilities and no extensions member.
  Expect<Boolean>(Pos('"capabilities" : { "tools" : {', Line) > 0).ToBe(True);
  Expect<Boolean>(Pos('extensions', Line) = 0).ToBe(True);
end;

const
  APPS_DECLARED = '"extensions" : { "io.modelcontextprotocol/ui" : {} }';

// Each Apps entry point declares the extension on its own: a fresh
// server per path, so no other helper declares it first (#98 review).
function DeclaresApps(AServer: TMCPServer): Boolean;
var
  Session: TMCPSession;
  Line: string;
begin
  Session := AServer.CreateSession;
  try
    AServer.HandleMessage(Session, '{"jsonrpc":"2.0","id":1,' +
      '"method":"server/discover","params":{' + META_PLAIN_CLIENT + '}}', Line);
    Result := Pos(APPS_DECLARED, Line) > 0;
  finally
    Session.Free;
    AServer.Free;
  end;
end;

procedure TAppsSuite.TestEachOptInDeclares;
var
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('static', '1');
  RegisterAppResource(Server, 'ui://s', 's', HTML);
  Expect<Boolean>(DeclaresApps(Server)).ToBe(True);
  Server := TMCPServer.Create('reader', '1');
  RegisterAppResource(Server, 'ui://r', 'r', DynamicReader);
  Expect<Boolean>(DeclaresApps(Server)).ToBe(True);
  // The link alone, to a resource the core API registered with the app
  // media type.
  Server := TMCPServer.Create('link', '1');
  Server.RegisterTextResource('ui://l', 'l', MCP_APP_MIME_TYPE, HTML);
  Server.RegisterTool('t', 't', '{"type":"object"}', PlainHandler)
    .AppResource('ui://l', []);
  Expect<Boolean>(DeclaresApps(Server)).ToBe(True);
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
  FServer.RegisterTextResource('ui://weather/dashboard', 'Dashboard',
    MCP_APP_MIME_TYPE, HTML);
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
  Expect<string>(Message).ToBe('Tool "orphan" needs resource ' +
    '"ui://nowhere", which is not registered');
end;

function StartupError(AServer: TMCPServer): string;
begin
  Result := '';
  try
    AServer.CreateSession.Free;
  except
    on E: EMCPServer do
      Result := E.Message;
  end;
end;

// A link to a resource of another media type fails at startup (#98
// review).
procedure TAppsSuite.TestLinkedResourceMediaType;
begin
  FServer.RegisterTextResource('ui://plain', 'plain', 'text/plain', 'x');
  FServer.RegisterTool('typed', 'Typed', '{"type":"object"}', PlainHandler)
    .AppResource('ui://plain', []);
  Expect<string>(StartupError(FServer)).ToBe('Tool "typed" needs resource ' +
    '"ui://plain" with media type text/html;profile=mcp-app');
end;

// Linking a tool again replaces its earlier link, so startup checks
// only the final one (#98 review).
procedure TAppsSuite.TestRelinkReplacesRequirement;
var
  Options: TMCPToolOptions;
begin
  RegisterAppResource(FServer, 'ui://new', 'new', HTML);
  Options := FServer.RegisterTool('moved', 'Moved', '{"type":"object"}',
    PlainHandler);
  Options.AppResource('ui://old', []);
  Options.AppResource('ui://new', []);
  Expect<string>(StartupError(FServer)).ToBe('');
  // Both keys go out with the final link.
  Expect<Boolean>(Pos('"_meta" : { "ui" : { "resourceUri" : "ui://new" }, ' +
    '"ui/resourceUri" : "ui://new" }', Send('{"jsonrpc":"2.0","id":1,' +
    '"method":"tools/list","params":{' + META_PLAIN_CLIENT + '}}')) > 0)
    .ToBe(True);
end;

// Startup checks the link as it goes out: a later .Meta that changes
// either key is checked too (#98 review).
procedure TAppsSuite.TestLaterMetaChecked;
var
  Server: TMCPServer;
begin
  RegisterAppResource(FServer, 'ui://a', 'a', HTML);
  FServer.RegisterTool('split', 'Split', '{"type":"object"}', PlainHandler)
    .AppResource('ui://a', [])
    .Meta('ui', TJSONObject(GetJSON('{"resourceUri":"ui://b"}')));
  Expect<string>(StartupError(FServer)).ToBe('Tool "split" links "ui://b" ' +
    'at _meta.ui.resourceUri but "ui://a" at _meta.ui/resourceUri');
  Server := TMCPServer.Create('moved', '1');
  try
    RegisterAppResource(Server, 'ui://a', 'a', HTML);
    Server.RegisterTool('moved', 'Moved', '{"type":"object"}', PlainHandler)
      .AppResource('ui://a', [])
      .Meta('ui', TJSONObject(GetJSON('{"resourceUri":"ui://b"}')))
      .Meta('ui/resourceUri', TJSONString.Create('ui://b'));
    Expect<string>(StartupError(Server)).ToBe('Tool "moved" needs resource ' +
      '"ui://b", which is not registered');
  finally
    Server.Free;
  end;
  Server := TMCPServer.Create('dropped', '1');
  try
    RegisterAppResource(Server, 'ui://a', 'a', HTML);
    Server.RegisterTool('dropped', 'Dropped', '{"type":"object"}', PlainHandler)
      .AppResource('ui://a', [])
      .Meta('ui', TJSONObject(GetJSON('{"prefersBorder":true}')));
    Expect<string>(StartupError(Server)).ToBe('Tool "dropped" has no link ' +
      'at _meta.ui.resourceUri');
  finally
    Server.Free;
  end;
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

procedure EmptyPrefixLabel;
begin
  GuardServer.DeclareExtension('com..example/feature');
end;

procedure SlashInName;
begin
  GuardServer.DeclareExtension('com.example/feature/name');
end;

procedure NameStartsWithHyphen;
begin
  GuardServer.DeclareExtension('com.example/-feature');
end;

procedure TAppsSuite.TestGuards;
begin
  GuardServer := FServer;
  Expect<Boolean>(RaisesServerError(NonUiUri)).ToBe(True);
  Expect<Boolean>(RaisesServerError(BadVisibility)).ToBe(True);
  Expect<Boolean>(RaisesServerError(BadExtensionId)).ToBe(True);
  // A bad prefix label, and a name with a character the _meta rules
  // leave out, each on its own.
  Expect<Boolean>(RaisesServerError(EmptyPrefixLabel)).ToBe(True);
  Expect<Boolean>(RaisesServerError(SlashInName)).ToBe(True);
  Expect<Boolean>(RaisesServerError(NameStartsWithHyphen)).ToBe(True);
  GuardServer := nil;
end;

const
  INIT_CLASSIC = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":' +
    '{"protocolVersion":"2025-11-25","capabilities":';
  INIT_CLASSIC_END = ',"clientInfo":{"name":"c","version":"1"}}}';
  DISCOVER = '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{' +
    '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{}}}}';

// The server's settings for an extension go out as declared, on
// server/discover and on the classic initialize (#98 review).
procedure TAppsSuite.TestSettingsInBothEras;
const
  DECLARED = '"extensions" : { "com.example/feature" : { "level" : 2 } }';
begin
  FServer.DeclareExtension('com.example/feature',
    TJSONObject(GetJSON('{"level":2}')));
  Expect<Boolean>(Pos(DECLARED, Send(DISCOVER)) > 0).ToBe(True);
  FreeAndNil(FSession);
  Expect<Boolean>(Pos(DECLARED, Send(INIT_CLASSIC + '{}' + INIT_CLASSIC_END)) > 0)
    .ToBe(True);
end;

// A classic client's extensions come from its initialize capabilities:
// present, absent and malformed.
procedure TAppsSuite.TestClassicClientDeclarations;
const
  CALL = '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":' +
    '{"name":"plain","arguments":{}}}';
  INITIALIZED = '{"jsonrpc":"2.0","method":"notifications/initialized"}';

  function Classic(ASuite: TAppsSuite; const ACapabilities: string): string;
  begin
    FreeAndNil(ASuite.FSession);
    ASuite.Send(INIT_CLASSIC + ACapabilities + INIT_CLASSIC_END);
    ASuite.Send(INITIALIZED);
    Result := ASuite.Send(CALL);
  end;

begin
  FServer.RegisterTool('plain', 'Plain', '{"type":"object"}', SettingsHandler);
  // The settings reach the handler, not just the declaration.
  Expect<Boolean>(Pos('"text" : "ui text/html;profile=mcp-app"', Classic(Self,
    '{"extensions":{' +
    '"io.modelcontextprotocol/ui":{"mimeTypes":["text/html;profile=mcp-app"]}}}')) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('"text" : "no ui"', Classic(Self, '{}')) > 0).ToBe(True);
  Expect<Boolean>(Pos('"text" : "no ui"', Classic(Self,
    '{"extensions":["io.modelcontextprotocol/ui"]}')) > 0).ToBe(True);
end;

// Settings declared first are kept when an Apps helper opts in later
// (#98 review).
procedure TAppsSuite.TestExplicitSettingsKept;
begin
  FServer.DeclareExtension(MCP_APPS_EXTENSION,
    TJSONObject(GetJSON('{"note":"mine"}')));
  RegisterAppResource(FServer, 'ui://kept', 'kept', HTML);
  FServer.RegisterTool('t', 't', '{"type":"object"}', PlainHandler)
    .AppResource('ui://kept', []);
  Expect<Boolean>(Pos('"io.modelcontextprotocol/ui" : { "note" : "mine" }',
    Send(DISCOVER)) > 0).ToBe(True);
end;

// A tool's own _meta.ui with any URI is not an Apps link: startup only
// checks links .AppResource made (#98 review).
procedure TAppsSuite.TestOtherMetaUiNotChecked;
begin
  FServer.RegisterTool('doc', 'Doc', '{"type":"object"}', PlainHandler)
    .Meta('ui', TJSONObject(GetJSON('{"resourceUri":"https://example.com/d"}')));
  Expect<Boolean>(Pos('"tools"', Send(DISCOVER)) > 0).ToBe(True);
end;

// A start that fails on a missing linked resource can be fixed and
// retried (#98 review).
procedure TAppsSuite.TestFailedStartCanBeRetried;
var
  Raised: Boolean;
begin
  FServer.RegisterTool('later', 'Later', '{"type":"object"}', PlainHandler)
    .AppResource('ui://later', []);
  Raised := False;
  try
    FServer.CreateSession.Free;
  except
    on E: EMCPServer do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  RegisterAppResource(FServer, 'ui://later', 'later', HTML);
  Expect<Boolean>(Pos('"io.modelcontextprotocol/ui"', Send(DISCOVER)) > 0)
    .ToBe(True);
end;

// Settings with a child stored as nil still clone for every answer, and
// an extension id may have an empty name after its prefix (#98 review).
procedure TAppsSuite.TestNilChildrenAndEmptyName;
var
  Settings: TJSONObject;
begin
  Settings := TJSONObject.Create;
  Settings.Add('empty', TJSONData(nil));
  FServer.DeclareExtension('com.example/', Settings);
  Expect<Boolean>(Pos('"com.example/" : { "empty" : null }', Send(DISCOVER)) > 0)
    .ToBe(True);
end;

// Rendering needs the app media type among the client's mimeTypes, not
// just a declaration (#98 review).
procedure TAppsSuite.TestClientRendersApps;
const
  CALL = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":' +
    '{"name":"renders",';
  CAPS = '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":';
begin
  FServer.RegisterTool('renders', 'Renders', '{"type":"object"}', RendersHandler);
  Expect<Boolean>(Pos('"text" : "renders|declared"', Send(CALL +
    META_UI_CLIENT + '}}')) > 0).ToBe(True);
  Expect<Boolean>(Pos('"text" : "does not render|declared"', Send(CALL + CAPS +
    '{"extensions":{"io.modelcontextprotocol/ui":{}}}}}}')) > 0).ToBe(True);
  Expect<Boolean>(Pos('"text" : "does not render|declared"', Send(CALL + CAPS +
    '{"extensions":{"io.modelcontextprotocol/ui":{"mimeTypes":["text/html"]}}}}}}'))
    > 0).ToBe(True);
  Expect<Boolean>(Pos('"text" : "does not render|undeclared"', Send(CALL +
    META_PLAIN_CLIENT + '}}')) > 0).ToBe(True);
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
  Test('extension settings go out on discover and classic initialize',
    TestSettingsInBothEras);
  Test('classic clients: present, absent and malformed extensions',
    TestClassicClientDeclarations);
  Test('explicit extension settings survive an Apps opt-in',
    TestExplicitSettingsKept);
  Test('a tool''s own _meta.ui is not checked as an Apps link',
    TestOtherMetaUiNotChecked);
  Test('a start that failed on a missing link can be retried',
    TestFailedStartCanBeRetried);
  Test('nil children in settings, and an empty extension name',
    TestNilChildrenAndEmptyName);
  Test('MCPClientRendersApps needs the app media type',
    TestClientRendersApps);
  Test('each Apps entry point declares the extension on its own',
    TestEachOptInDeclares);
  Test('a linked resource of another media type fails at startup',
    TestLinkedResourceMediaType);
  Test('linking a tool again replaces its earlier link',
    TestRelinkReplacesRequirement);
  Test('a later .Meta that changes the link is checked at startup',
    TestLaterMetaChecked);
  Test('non-ui:// URIs, bad visibility and bad extension ids refused',
    TestGuards);
end;

begin
  TestRunnerProgram.AddSuite(TAppsSuite.Create('Apps: MCP Apps extension'));
  TestRunnerProgram.Run;
end.
