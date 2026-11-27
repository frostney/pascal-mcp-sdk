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
| `RedactErrorDetails` | `Boolean` | `False` | `True` replaces escaped exception detail with a correlation reference, logging the full error to stderr; deliberate errors (`MCPErrorResult`, `EMCPProtocolError`) are sent as written |
| `DualEra` | `Boolean` | `True` | Answer the classic `initialize` handshake alongside stateless 2026-07-28 requests |
| `RequestStateTtlMs` | `Integer` | `600000` | Lifetime of a sealed `requestState` token; must be > 0 |
| `SetRequestStateKeys(Keys)` | method | random per server instance | HMAC keys for `requestState` sealing, each ≥ 32 bytes; the first seals, all verify |
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

### Argument completion

`completion/complete` suggests values while a user fills in a prompt
argument or a resource-template variable
([Completion](https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/completion),
verified 2026-11-26). Register a completion after the prompt or
template it belongs to:

```pascal
procedure RegisterPromptCompletion(const APrompt, AArgument: string;
  const AValues: array of string);              // static list
procedure RegisterPromptCompletion(const APrompt, AArgument: string;
  AHandler: TMCPCompletionHandler);             // + Method variant
procedure RegisterTemplateCompletion(const AUriTemplate, AVariable: string;
  const AValues: array of string);              // + Handler, Method

TMCPCompletionHandler = function(const AArgument, AValue: string;
  AContext: TJSONObject; const ACtx: TMCPRequestContext): TMCPCompletion;

TMCPCompletion = record
  Values: array of string;  // ranked; at most 100 are sent
  Total: Integer;           // all matches, -1 when unknown
  HasMore: Boolean;
end;

function MCPCompleteFrom(const AValue: string;
  const ACandidates: array of string): TMCPCompletion;
```

A static list completes by prefix, in the order given (`MCPCompleteFrom`,
which a handler can call too). Case is ignored by Unicode simple case
folding for Basic Latin, Latin-1, Latin Extended-A, Greek and Coptic,
and Cyrillic with its supplement (so `ſ` matches `s` and `ς` matches
`σ`), independent of the locale; other scripts compare exactly. A
handler gets the value typed so far and, in `AContext`, the arguments
the client has already resolved (`nil` when none); a supplied `context`
that is not an object, or whose `arguments` are not strings, is
answered `-32602` before any handler runs. More than 100 values are cut
to 100; `hasMore` is true then, when the handler sets `HasMore`, or when
its known `Total` exceeds the values sent. An unknown prompt or
template, an argument it does not declare, or a nil handler is refused
with `EMCPServer` at registration, and the first two are answered
`-32602` on the wire; an argument with no completion registered
answers an empty list, and a server with no completions registered
answers `completion/complete` with `-32601`, since it declares no
`completions` capability. Registering any completion declares the
`completions` capability. Over Streamable HTTP a request that opts
into notifications streams them, as for the other handler-backed
methods.

### Capabilities

`server/discover` and the classic `initialize` declare a capability
for each kind of thing registered: `tools` when there is a tool,
`resources` when there is a resource or template, `prompts` when there
is a prompt, `completions` when there is a completion.

### x-mcp-header parameters

```pascal
function ToolHeaderParameters(const AName: string): TMCPHeaderParameters;
```

The parameters tool `AName` mirrors into `Mcp-Param-*` headers (header
name, property path, type), as `MCP.Schema.MCPHeaderParameters`
reads them from its `inputSchema`. The Streamable HTTP binding uses it
to validate the headers; a custom transport can too. See
[Routing headers](../guides/tools.md#routing-headers-x-mcp-header).

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

### Schema builder and argument classes

`MCP.Schema` builds the schemas tools register and binds arguments to
typed classes (see [Schemas](../guides/schemas.md)):

```pascal
ObjectSchema: TMCPSchema;                         // {"type":"object"}
  .AddString / AddNumber / AddInteger / AddBoolean(AName, ADescription = '',
    ARequired = True)
  .AddEnum(AName, AValues, ADescription = '', ARequired = True)
  .AddArray(AName, AItemType, ADescription = '', ARequired = True)
  .AddArray(AName, AItems: TMCPSchema, ADescription = '', ARequired = True)
  .AddObject(AName, ASchema: TMCPSchema, ADescription = '', ARequired = True)
  .WithDefault(AValue)       // string, Int64, Double or Boolean
  .Build: TJSONObject        // owned by the caller; the builder is spent

function SchemaFrom(AClass: TMCPArgsClass): TMCPSchema;
function MCPBindArguments(AClass: TMCPArgsClass; AArguments: TJSONObject;
  out AInstance: TMCPArgs; out AError: string): Boolean;
function MCPSerialize(AObj: TMCPArgs): TJSONObject;
```

| Function | Contract |
| --- | --- |
| `AddArray`, `AddObject` | The nested `TMCPSchema` is built and consumed by the call |
| `WithDefault` | Applies to the primitive property added last and makes it optional; raises `EMCPSchema` when the default does not fit it or it already has one |
| `SchemaFrom` | Published properties to a schema: scalars, enums, field-backed dynamic arrays of `string`, `Integer`, `Int64`, `Double` or `Boolean`, and field-backed `TMCPArgs` descendants as nested objects (at most 16 levels, as binding and `MCPSerialize` also enforce); raises `EMCPSchema` for anything else |
| `MCPBindArguments` | Creates an `AClass` instance from `AArguments` (borrowed), nested objects and arrays included; `False` with an in-band message naming the path on a missing or mistyped argument; the caller owns `AInstance` on success |
| `MCPSerialize` | The reverse, as a new object the caller owns; a nil nested object is left out; raises `EMCPSchema` for an unmapped property, a class property that is not a field-backed `TMCPArgs`, or a value with no JSON form (NaN) |

### Schema checks

`MCP.Schema` exposes the checks the server runs on arguments and
structured output (see [the enforced subset](../guides/schemas.md#the-enforced-subset)):

```pascal
function MCPSchemaSubsetViolation(ASchema: TJSONObject;
  AObjectRoot: Boolean): string;
function MCPValidateAgainstSchema(ASchema: TJSONObject; AValue: TJSONData;
  const AKind: string; ASeedDefaults: Boolean; out AError: string): Boolean;
```

| Function | Contract |
| --- | --- |
| `MCPSchemaSubsetViolation` | `''` when `ASchema` is inside the subset, otherwise the first violation with its path. `AObjectRoot` also requires an `object` root, as input schemas need. `ASchema` is borrowed |
| `MCPValidateAgainstSchema` | `True` when `AValue` conforms; otherwise `False` with the first violation in `AError`, naming the value with `AKind` (`'argument'` gives `Missing required argument "a.b"`). `ASchema` must be inside the subset. Both are borrowed; with `ASeedDefaults`, absent optional properties that declare a default are added to `AValue` |

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
newline framing. It writes UTF-8 to `AOutput` whatever that file's code
page, and puts the code page back exactly when it returns.

`MCPLogToStderr` writes one line to stderr and flushes it, under the
lock every library diagnostic shares, so lines from different threads
never mix. The line is UTF-8 unless stderr is a Windows console, which
keeps the code page the RTL chose for it; `ErrOutput`'s code page is
restored afterwards, so your own writes are unaffected. I/O errors
propagate (the server's internal diagnostics ignore them).

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

### Answering with a JSON-RPC error

A handler that must refuse a request with a protocol error, rather than
a result, raises `EMCPProtocolError`:

```pascal
EMCPProtocolError = class(Exception)
  constructor Create(ACode: Integer; const AMessage: string;
    AData: TJSONData = nil);   // takes ownership of AData
  property Code: Integer;
  property Data: TJSONData;
end;

function MCPMissingCapabilityError(const ACapability: string): EMCPProtocolError;
```

Raised from a `tools/call`, `prompts/get` or `resources/read` handler
(typed and template handlers included), it becomes the error response
with exactly that code, message and data, in both eras. It is
deliberate, so [`RedactErrorDetails`](../guides/configuration.md#redacterrordetails)
leaves it alone: its message and data reach the client verbatim, so
keep secrets out of them. Every other exception keeps its mapping: an
`isError` result from a tool, `-32603` from a prompt or a resource
reader. `Data` is owned by the exception; do not free or change it.

| Code | Use it for |
| --- | --- |
| `-32602` | Invalid params of a prompt or resource request that the handler rejects itself, or a `requestState` the handler cannot accept. A tool's argument errors stay in-band (`MCPErrorResult`), so the model can correct them |
| `-32021` | A client capability the request needs and did not declare; it must carry `data.requiredCapabilities`, so build it with `MCPMissingCapabilityError('sampling')`. The constructor refuses `-32021` unless `requiredCapabilities` names at least one capability shaped as in `ClientCapabilities` (each one an object, and so are `sampling.tools`, `elicitation.form` and each `extensions` entry); data changed after that is sent as `-32603` |
| `-32700`, `-32600`, `-32601`, `-32603` | The other JSON-RPC codes, with their JSON-RPC meanings |
| outside `-32768..-32000` | Your application's own codes |

Any other code is reserved, by the
[specification](https://modelcontextprotocol.io/specification/2026-07-28/basic/index#error-codes)
or for legacy use, and the constructor raises `EMCPServer` for it.

A URI that matches a resource template but names nothing that exists
is not an error to raise either: return `nil` from the template reader,
and the server answers with the code the client's protocol revision
expects (`-32602`, or `-32002` for classic-handshake clients) and the
URI as data. (An exact resource's reader must return contents.)

On the Streamable HTTP binding the status follows the code, so a
handler-raised `-32021` answers 400, as long as nothing has been
streamed yet. A request that opted into progress becomes a `200` event
stream with its first notification; an error raised after that can
only be the stream's last event. Check capabilities before reporting
progress.

```pascal
if not ACtx.HasCapability('sampling') then
  raise MCPMissingCapabilityError('sampling');
```
