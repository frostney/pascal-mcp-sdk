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
uses MCP.Apps, MCP.Schema, MCP.Server;

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
  `text/html;profile=mcp-app`. The URI must use `ui://`. For static
  HTML, its `_meta.ui` goes on the resource's declaration and on what
  `resources/read` returns. A second overload takes a reader instead;
  there the `_meta.ui` you register goes on the declaration only, so
  the reader passes the `_meta.ui` its read result should carry to
  `MCPAppContents`.
- `MCPAppUiMeta` builds `_meta.ui`: the content security policy's
  domain lists (empty lists keep the client's restrictive default:
  no external connections, scripts and styles only from the page),
  browser permissions (`apCamera`, `apMicrophone`, `apGeolocation`,
  `apClipboardWrite`; the client may refuse them), a dedicated origin
  (its format depends on the client), and whether the client should
  draw a border (`1`) or not (`0`).
- `.AppResource(Uri, Visibility)` links a tool. `Visibility` holds
  `'model'` and/or `'app'`; `[]` means both, the default. Visibility is
  advice to the host: a host that supports Apps leaves a tool marked
  only `'app'` out of what the model sees and lets the page call it.
  The server still answers `tools/list` and `tools/call` for it like any
  other tool, so it is no access control.
  The link also writes the older flat `ui/resourceUri` key, as the
  official TypeScript helper does, for clients that still read it.

Using either declares the extension in the server's capabilities,
unless you declared it with your own settings already; nothing is
declared otherwise. A tool linked with `.AppResource` to a `ui://` URI
that is not registered, or registered with another media type than
`text/html;profile=mcp-app`, fails when the server starts. Linking the
same tool again replaces its earlier link. Startup checks the link as
`tools/list` sends it, so a later `.Meta('ui', ...)` or
`.Meta('ui/resourceUri', ...)` on that tool must name the same
registered resource in both keys.

## Keep the text result

The specification requires a linked tool to return meaningful content
for clients without the extension. Return the same `MCPTextResult` or
`MCPStructuredResult` you would without a UI, whichever client calls:
the page gets that result too, and a host that renders the page may
still pass the content to the model. You can still tailor the wording
when the client renders apps, which means it declared the extension
with the app media type among its `mimeTypes`; keep the result
meaningful in both branches:

```pascal
if MCPClientRendersApps(ACtx) then
  ...   // the UI shows the details; the text still says what happened
```

`ACtx.HasExtension(Id)` only says the client declared an extension, and
`ACtx.ExtensionSettings(Id)` returns its settings object.

## Other extensions

`TMCPServer.DeclareExtension(Id, Settings)` declares any extension in
`capabilities.extensions`; the identifier needs a prefix
(`com.example/feature`). Extensions are opt-in: a client that does not
declare one gets core behaviour.

## The page

The HTML runs in the client's sandbox and talks to the client with
`postMessage`; the server only serves it. The page opens with
`ui/initialize` and, once the client answers, sends
`ui/notifications/initialized`; only then does the client send it the
tool's input and result (`ui/notifications/tool-result`), and the other
messages in the specification.
`mcpdemo`'s `echo` tool links a small card (`ui://pascal-mcp-sdk/echo-card`)
that shows the echoed text.
