# Interactive UIs (MCP Apps)

## Executive Summary

MCP Apps is the official extension for interactive user interfaces
(`io.modelcontextprotocol/ui`, stable revision
[2026-01-26](https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx)).
A tool links to an HTML resource with a `ui://` URI; a client that
supports the extension (Claude, ChatGPT, VS Code and Cursor among
them) renders that HTML in a sandboxed frame next to the tool's
result, and the page receives the tool's input and result from the
client. A client without the extension calls the same tool and shows
its ordinary content. `MCP.Apps` gives you the server side: the UI
resource, its security metadata, and the tool link.

## Register a UI and link a tool

```pascal
uses MCP.Apps, MCP.Server;

RegisterAppResource(Server, 'ui://weather/dashboard', 'Weather dashboard',
  DashboardHtml,
  MCPAppUiMeta(['https://api.weather.example'],   // connect (fetch, WebSocket)
               ['https://cdn.example.com'],       // scripts, styles, images
               [], [],                            // frames, base URIs
               [], '', 1));                       // permissions, domain, border

Server.RegisterTool('get_weather', 'Current weather for a city',
  ObjectSchema.AddString('city'), WeatherHandler)
  .AppResource('ui://weather/dashboard', []);
```

- `RegisterAppResource` registers a resource with the media type
  `text/html;profile=mcp-app`. The URI must use `ui://`. Its
  `_meta.ui` goes on the resource's declaration and on what
  `resources/read` returns. A second overload takes a reader that builds
  its contents with `MCPAppContents`.
- `MCPAppUiMeta` builds `_meta.ui`: the content security policy's
  domain lists (empty lists keep the client's restrictive default:
  no external connections, scripts and styles only from the page),
  browser permissions (`apCamera`, `apMicrophone`, `apGeolocation`,
  `apClipboardWrite`; the client may refuse them), a dedicated origin
  (its format depends on the client), and whether the client should
  draw a border (`1`) or not (`0`).
- `.AppResource(Uri, Visibility)` links a tool. `Visibility` holds
  `'model'` and/or `'app'`; `[]` means both, the default. A tool marked
  only `'app'` is hidden from the model and callable from the page.
  The link also writes the older flat `ui/resourceUri` key, as the
  official TypeScript helper does, for clients that still read it.

Using either declares the extension in the server's capabilities;
nothing is declared otherwise. A tool linked to a `ui://` URI that is
not registered fails when the server starts.

## Keep the text result

The specification requires a linked tool to return meaningful content
for clients without the extension. Return the same `MCPTextResult` or
`MCPStructuredResult` you would without a UI; the page gets that result
too. To tailor the content, ask the request:

```pascal
if ACtx.HasExtension(MCP_APPS_EXTENSION) then
  ...   // the client renders the UI
```

`ACtx.ExtensionSettings(Id)` returns the client's settings object for
an extension (for MCP Apps, the `mimeTypes` it renders).

## Other extensions

`TMCPServer.DeclareExtension(Id, Settings)` declares any extension in
`capabilities.extensions`; the identifier needs a prefix
(`com.example/feature`). Extensions are opt-in: a client that does not
declare one gets core behaviour.

## The page

The HTML runs in the client's sandbox and talks to the client with
`postMessage` (`ui/initialize`, `ui/notifications/tool-result` and the
other messages in the specification); the server only serves it.
`mcpdemo`'s `echo` tool links a small card (`ui://pascal-mcp-sdk/echo-card`)
that shows the echoed text.
