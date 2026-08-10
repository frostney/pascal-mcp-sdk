# Server API

The registration and serving surface: `TMCPServer` from `MCP.Server`,
plus the two transports. The task-oriented walkthroughs live in the
[guides](../guides/quick-start.md); this page is the complete surface.

## TMCPServer

```pascal
constructor Create(const AName, AVersion: string);
```

Name and version identify the server in `serverInfo`. Neither may be
empty. Configure and register on the fresh instance, then hand it to a
transport; configuration and registries freeze when the first session
is created, and later mutation raises `EMCPServer`.

### Configuration properties

| Property | Type | Default | Meaning |
| --- | --- | --- | --- |
| `Instructions` | `string` | `''` | Usage guidance surfaced via `server/discover` / classic `initialize` |
| `CacheTtlMs` | `Integer` | `300000` | SEP-2549 `ttlMs` caching hint on discover/list/read results; must be ≥ 0 |
| `CacheScope` | `string` | `'private'` | SEP-2549 `cacheScope`; `'private'` or `'public'` |
| `RedactErrorDetails` | `Boolean` | `False` | `True` replaces exception detail with a correlation reference, logging the full error to stderr |
| `DualEra` | `Boolean` | `True` | Answer the classic `initialize` handshake alongside stateless 2026-07-28 requests |
| `Name`, `Version` | `string` | — | Read-only, from `Create` |

Semantics and guidance: [Configuration](../guides/configuration.md).

### Registering tools

Fourteen overloads along two axes — the seven schema-declaration
shapes below, each in plain-function and `of object` method handler
form:

```pascal
// Raw JSON schema string
function RegisterTool(const AName, ADescription, AInputSchemaJson: string;
  AHandler: TMCPToolHandler): TMCPToolOptions;

// Pre-assembled definition object (name/description/inputSchema)
function RegisterTool(ADefinition: TJSONObject;
  AHandler: TMCPToolHandler): TMCPToolOptions;

// Fluent schema builder; optional output schema
function RegisterTool(const AName, ADescription: string;
  constref AInputSchema: TMCPSchema;
  AHandler: TMCPToolHandler): TMCPToolOptions;
function RegisterTool(const AName, ADescription: string;
  constref AInputSchema, AOutputSchema: TMCPSchema;
  AHandler: TMCPToolHandler): TMCPToolOptions;

// Typed argument class; optional output schema or output class
function RegisterTool(const AName, ADescription: string;
  AArgsClass: TMCPArgsClass;
  AHandler: TMCPArgsHandler): TMCPToolOptions;
function RegisterTool(const AName, ADescription: string;
  AArgsClass: TMCPArgsClass; constref AOutputSchema: TMCPSchema;
  AHandler: TMCPArgsHandler): TMCPToolOptions;
function RegisterTool(const AName, ADescription: string;
  AArgsClass, AOutputClass: TMCPArgsClass;
  AHandler: TMCPArgsHandler): TMCPToolOptions;
```

Handler signatures:

```pascal
TMCPToolHandler = function(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
TMCPArgsHandler = function(AArgs: TMCPArgs;
  const ACtx: TMCPRequestContext): TMCPToolResult;
// ...Method variants: identical, of object
```

Every overload returns `TMCPToolOptions` for fluent annotation:

```pascal
function Title(const ATitle: string): TMCPToolOptions;
function ReadOnlyHint(AValue: Boolean = True): TMCPToolOptions;
function DestructiveHint(AValue: Boolean = True): TMCPToolOptions;
function IdempotentHint(AValue: Boolean = True): TMCPToolOptions;
function OpenWorldHint(AValue: Boolean = True): TMCPToolOptions;
function ApplicationValidated: TMCPToolOptions;
```

`ApplicationValidated` publishes a raw schema unchanged and hands
argument validation to the handler — see
[Schemas](../guides/schemas.md#the-enforced-subset).

### Registering resources

```pascal
procedure RegisterTextResource(const AUri, AName, AMimeType, AText: string;
  const ADescription: string = '');

procedure RegisterResource(const AUri, AName, AMimeType: string;
  AReader: TMCPResourceReader; const ADescription: string = '');
procedure RegisterResource(const AUri, AName, AMimeType: string;
  AMethod: TMCPResourceMethod; const ADescription: string = '');

procedure RegisterResourceTemplate(const AUriTemplate, AName,
  AMimeType: string; AReader: TMCPTemplateReader;
  const ADescription: string = '');
procedure RegisterResourceTemplate(const AUriTemplate, AName,
  AMimeType: string; AMethod: TMCPTemplateMethod;
  const ADescription: string = '');
```

Reader signatures:

```pascal
TMCPResourceReader = function(const AUri: string;
  const ACtx: TMCPRequestContext): TJSONArray;
TMCPTemplateReader = function(const AUri: string; AVars: TJSONObject;
  const ACtx: TMCPRequestContext): TJSONArray;
```

Readers return contents built with `MCPTextContents` /
`MCPBlobContents` — see [Results and content](results.md). Template
matching is RFC 6570 level 1; the standalone matcher is public:

```pascal
function MatchUriTemplate(const ATemplate, AUri: string;
  out AVars: TJSONObject): Boolean;
```

### Registering prompts

Eight overloads: with or without declared arguments, message-array or
result handlers, each in function and method shape:

```pascal
procedure RegisterPrompt(const AName, ADescription: string;
  AHandler: TMCPPromptHandler);
procedure RegisterPrompt(const AName, ADescription: string;
  constref AArguments: TMCPPromptArguments;
  AHandler: TMCPPromptHandler);
// same two with TMCPPromptResultHandler — the MRTR-capable shape
// whose handler returns TMCPPromptResult
// ...and all four as of-object Method variants
```

Handler signatures:

```pascal
TMCPPromptHandler = function(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TJSONArray;
TMCPPromptResultHandler = function(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPPromptResult;
```

Arguments are declared fluently, starting from the `PromptArguments`
factory function:

```pascal
function PromptArguments: TMCPPromptArguments;
function Add(const AName: string; const ADescription: string = '';
  ARequired: Boolean = True): TMCPPromptArguments;
```

### The request context

Every handler receives `TMCPRequestContext` (from `MCP.Protocol`):

| Member | Meaning |
| --- | --- |
| `ProtocolVersion` | Negotiated revision for this request |
| `ClientName`, `ClientVersion` | From `clientInfo`; `''` when absent |
| `ClientCapabilities` | The per-request capability object |
| `HasCapability(Name)` | Capability probe (used for MRTR gating) |
| `LogLevel` | Client's requested log floor; `''` = no log opt-in |
| `HasProgressToken`, `ProgressToken` | Progress opt-in state |
| `InputResponses`, `RequestState` | MRTR retry payload — see [Client requests](client-requests.md) |
| `IsCancelled` | Cooperative cancellation probe |

### Introspection and the sans-I/O seam

```pascal
function ToolCount: Integer;
function ResourceCount: Integer;
function PromptCount: Integer;

function CreateSession: TMCPSession;
function HandleMessage(ASession: TMCPSession; const ALine: string;
  out AResponse: string): Boolean;
function HandleMessage(ASession: TMCPSession; const ALine: string;
  ASink: TMCPLineSink; ASinkData: Pointer;
  out AResponse: string): Boolean;
function OversizedLineResponse(AMaxLineLength: Integer): string;
```

`CreateSession` / `HandleMessage` are the line-in/line-out core the
transports wrap — only custom transport authors call these directly
(see [Architecture](../internals/architecture.md#the-sans-io-core)).

## Stdio transport

From `MCP.Transport.Stdio`:

```pascal
procedure RunMCPStdioServer(AServer: TMCPServer;
  AMaxLineLength: Integer = MCP_STDIO_DEFAULT_MAX_LINE);  // 4 MiB
procedure RunMCPStdioLoop(var AInput, AOutput: Text; AServer: TMCPServer;
  AMaxLineLength: Integer = MCP_STDIO_DEFAULT_MAX_LINE);
procedure MCPLogToStderr(const AMessage: string);
```

`RunMCPStdioServer` serves stdin/stdout until EOF — the spec's
graceful shutdown. `RunMCPStdioLoop` is the same loop over arbitrary
`Text` files, for tests and custom stream transports reusing the
newline framing.

## Streamable HTTP transport

From `MCP.Transport.HTTP`:

```pascal
constructor Create(AServer: TMCPServer);
procedure Run;    // blocks until Stop
procedure Stop;   // callable from another thread

property Port: Word;
property Address: string;              // default 127.0.0.1
property EndpointPath: string;         // default '/mcp'
property MaxBodyBytes: Integer;        // default 4 MiB
property AllowedOrigins: TStringList;  // exact-match additions
```

Deployment posture — loopback default, Origin allowlist, no TLS/auth,
modern era only — is covered in
[Shipping your server](../guides/shipping.md#deploying-the-http-binding).
On Unix, `cthreads` must be first in the program's uses clause.

## Errors

`EMCPServer` is raised for API misuse: registration after freeze,
malformed schemas, empty names, nil/foreign sessions. Wire-level
problems never raise — they become JSON-RPC error responses.
