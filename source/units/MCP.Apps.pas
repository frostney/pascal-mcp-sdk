unit MCP.Apps;

// MCP Apps (#98): interactive UIs a client renders for a tool's result.
// Extension io.modelcontextprotocol/ui, stable specification 2026-01-26
// (SEP-1865), verified 2026-11-26 against
// https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx
// (ext-apps 87bcdc8):
//
//   - a UI resource has a ui:// URI and the media type
//     text/html;profile=mcp-app, and may carry _meta.ui (content
//     security policy domains, permissions, a dedicated domain, a border
//     preference) on its declaration and its read contents;
//   - a tool links to one through _meta.ui.resourceUri, with an optional
//     visibility of "model" and/or "app"; the linked resource must be
//     registered (checked at startup);
//   - the client renders the HTML in a sandboxed iframe and talks to it;
//     none of that is the server's.
//
// Extensions are opt-in: registering an app resource or linking a tool
// declares io.modelcontextprotocol/ui in the server's capabilities. A
// client without the extension still calls the tool and gets its
// content, so a linked tool must return meaningful content as well.
//
//   RegisterAppResource(Server, 'ui://weather/dashboard', 'Dashboard',
//     DashboardHtml, MCPAppUiMeta(['https://api.example.com'], [], [], []));
//   Server.RegisterTool('get_weather', 'Weather', Schema, WeatherHandler)
//     .AppResource('ui://weather/dashboard', []);

{$I MCP.inc}

interface

uses
  SysUtils,

  fpjson,
  MCP.Server;

const
  MCP_APPS_EXTENSION = 'io.modelcontextprotocol/ui';
  MCP_APP_MIME_TYPE = 'text/html;profile=mcp-app';

type
  TMCPAppPermission = (apCamera, apMicrophone, apGeolocation, apClipboardWrite);
  TMCPAppPermissions = set of TMCPAppPermission;

  TMCPAppToolOptions = record helper for TMCPToolOptions
    // Links the tool to UI resource AUri (ui://...). AVisibility holds
    // 'model' and/or 'app' ([] leaves it out: both, the default).
    // Writes _meta.ui and the flat "ui/resourceUri" key older hosts read,
    // as the official helper does, and declares the extension.
    function AppResource(const AUri: string;
      const AVisibility: array of string): TMCPToolOptions;
  end;

// The _meta.ui object of a UI resource (owned by the caller until handed
// over). Empty domain lists are left out (the host's restrictive
// default applies); APrefersBorder: -1 unset, 0 false, 1 true.
function MCPAppUiMeta(const AConnectDomains, AResourceDomains, AFrameDomains,
  ABaseUriDomains: array of string; APermissions: TMCPAppPermissions = [];
  const ADomain: string = ''; APrefersBorder: Integer = -1): TJSONObject;

// A static HTML UI resource. AUiMeta (owned; nil for none) goes on the
// declaration's _meta.ui and on the read contents' _meta.ui.
function RegisterAppResource(AServer: TMCPServer; const AUri, AName,
  AHtml: string; AUiMeta: TJSONObject = nil;
  const ADescription: string = ''): TMCPDefinitionOptions; overload;
// A UI resource served by a reader, which builds its contents with
// MCPAppContents. AUiMeta (owned; nil for none) goes on the declaration.
function RegisterAppResource(AServer: TMCPServer; const AUri, AName: string;
  AReader: TMCPResourceReader; AUiMeta: TJSONObject = nil;
  const ADescription: string = ''): TMCPDefinitionOptions; overload;

// resources/read contents for a UI resource: the app media type, the
// HTML as text, and AUiMeta (owned; nil for none) as _meta.ui.
function MCPAppContents(const AUri, AHtml: string;
  AUiMeta: TJSONObject = nil): TJSONArray;

implementation

procedure RequireUiUri(const AUri: string);
begin
  if Copy(AUri, 1, 5) <> 'ui://' then
    raise EMCPServer.CreateFmt('MCP Apps resource "%s" must use the ui:// ' +
      'scheme', [AUri]);
end;

function DomainList(const ADomains: array of string): TJSONArray;
var
  I: Integer;
begin
  Result := TJSONArray.Create;
  for I := 0 to High(ADomains) do
    Result.Add(ADomains[I]);
end;

function MCPAppUiMeta(const AConnectDomains, AResourceDomains, AFrameDomains,
  ABaseUriDomains: array of string; APermissions: TMCPAppPermissions;
  const ADomain: string; APrefersBorder: Integer): TJSONObject;
var
  Csp, Permissions: TJSONObject;
begin
  Result := TJSONObject.Create;
  Csp := TJSONObject.Create;
  if Length(AConnectDomains) > 0 then
    Csp.Add('connectDomains', DomainList(AConnectDomains));
  if Length(AResourceDomains) > 0 then
    Csp.Add('resourceDomains', DomainList(AResourceDomains));
  if Length(AFrameDomains) > 0 then
    Csp.Add('frameDomains', DomainList(AFrameDomains));
  if Length(ABaseUriDomains) > 0 then
    Csp.Add('baseUriDomains', DomainList(ABaseUriDomains));
  if Csp.Count > 0 then
    Result.Add('csp', Csp)
  else
    Csp.Free;
  if APermissions <> [] then
  begin
    Permissions := TJSONObject.Create;
    if apCamera in APermissions then
      Permissions.Add('camera', TJSONObject.Create);
    if apMicrophone in APermissions then
      Permissions.Add('microphone', TJSONObject.Create);
    if apGeolocation in APermissions then
      Permissions.Add('geolocation', TJSONObject.Create);
    if apClipboardWrite in APermissions then
      Permissions.Add('clipboardWrite', TJSONObject.Create);
    Result.Add('permissions', Permissions);
  end;
  if ADomain <> '' then
    Result.Add('domain', ADomain);
  if APrefersBorder >= 0 then
    Result.Add('prefersBorder', APrefersBorder > 0);
end;

function MCPAppContents(const AUri, AHtml: string;
  AUiMeta: TJSONObject): TJSONArray;
var
  Item, Meta: TJSONObject;
begin
  Item := TJSONObject.Create;
  Item.Add('uri', AUri);
  Item.Add('mimeType', MCP_APP_MIME_TYPE);
  Item.Add('text', AHtml);
  if AUiMeta <> nil then
  begin
    Meta := TJSONObject.Create;
    Meta.Add('ui', AUiMeta);
    Item.Add('_meta', Meta);
  end;
  Result := TJSONArray.Create;
  Result.Add(Item);
end;

function RegisterAppResource(AServer: TMCPServer; const AUri, AName,
  AHtml: string; AUiMeta: TJSONObject;
  const ADescription: string): TMCPDefinitionOptions;
var
  ContentMeta: TJSONObject;
begin
  try
    RequireUiUri(AUri);
    Result := AServer.RegisterTextResource(AUri, AName, MCP_APP_MIME_TYPE,
      AHtml, ADescription);
  except
    AUiMeta.Free;
    raise;
  end;
  if AUiMeta <> nil then
  begin
    ContentMeta := TJSONObject.Create;
    ContentMeta.Add('ui', AUiMeta.Clone);
    AServer.SetResourceContentMeta(AUri, ContentMeta);
    Result.Meta('ui', AUiMeta);
  end;
  AServer.DeclareExtension(MCP_APPS_EXTENSION);
end;

function RegisterAppResource(AServer: TMCPServer; const AUri, AName: string;
  AReader: TMCPResourceReader; AUiMeta: TJSONObject;
  const ADescription: string): TMCPDefinitionOptions;
begin
  try
    RequireUiUri(AUri);
    Result := AServer.RegisterResource(AUri, AName, MCP_APP_MIME_TYPE,
      AReader, ADescription);
  except
    AUiMeta.Free;
    raise;
  end;
  if AUiMeta <> nil then
    Result.Meta('ui', AUiMeta);
  AServer.DeclareExtension(MCP_APPS_EXTENSION);
end;

function TMCPAppToolOptions.AppResource(const AUri: string;
  const AVisibility: array of string): TMCPToolOptions;
var
  Ui: TJSONObject;
  Visibility: TJSONArray;
  I: Integer;
begin
  RequireUiUri(AUri);
  Ui := TJSONObject.Create;
  Ui.Add('resourceUri', AUri);
  if Length(AVisibility) > 0 then
  begin
    Visibility := TJSONArray.Create;
    for I := 0 to High(AVisibility) do
    begin
      if (AVisibility[I] <> 'model') and (AVisibility[I] <> 'app') then
      begin
        Visibility.Free;
        Ui.Free;
        raise EMCPServer.CreateFmt('Visibility "%s" must be model or app',
          [AVisibility[I]]);
      end;
      Visibility.Add(AVisibility[I]);
    end;
    Ui.Add('visibility', Visibility);
  end;
  Result := Meta('ui', Ui).Meta('ui/resourceUri', TJSONString.Create(AUri));
  Server.DeclareExtension(MCP_APPS_EXTENSION);
end;

end.
