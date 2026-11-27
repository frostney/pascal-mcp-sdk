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
| `PageSize` | `Integer` | `0` | Entries per page of `tools/list`, `resources/list`, `resources/templates/list` and `prompts/list`, of `skills/list` and `resources/directory/read` from `MCP.Skills`, and of `events/list` from `MCP.Events`, with a `nextCursor` while more remain; `0` lists everything at once |
| `RequestStateTtlMs` | `Integer` | `600000` | Lifetime of a sealed `requestState` token; must be > 0 |
| `SetRequestStateKeys(Keys)` | method | random per server instance | HMAC keys for `requestState` sealing, each ≥ 32 bytes; the first seals, all verify |
| `Name`, `Version` | `string` | — | Read-only, from `Create` |
| `Title`, `Description`, `WebsiteUrl` | `string` | `''` | Optional `serverInfo` fields on `server/discover` and `initialize`; `AddIcon(Src, MimeType, Sizes, Theme)` adds an icon |

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
function RequiresClientCapability(const AName: string): TMCPToolOptions;
```

`ApplicationValidated` publishes a raw schema unchanged and hands
argument validation to the handler — see
[Schemas](../guides/schemas.md#the-enforced-subset).

`RequiresClientCapability` declares a client capability the tool needs
(`'elicitation'`, `'sampling'`, `'roots'`, …); call it once per
capability, as a repeated name raises `EMCPServer`. A request whose
`clientCapabilities` lack any of them is answered `-32021` before the
handler runs, with every missing one in `data.requiredCapabilities`. A
capability the schema defines counts as declared only in its shape, so
`"sampling": null` or `false` is missing; a capability of the client's
own counts when present. The check is unconditional and top-level: it
runs on every modern-era call, retries included, and does not look at
members such as `elicitation.url`. The input gate checks those for each
request the handler returns
([Client requests](client-requests.md)). On
Streamable HTTP that matters: an error decided after the handler has
streamed progress can only end the stream, while one decided first is
answered `400`, as the specification requires. Not checked for
classic-handshake clients, which get no input requests anyway.

### Registering resources

```pascal
function RegisterTextResource(const AUri, AName, AMimeType, AText: string;
  const ADescription: string = ''): TMCPDefinitionOptions;

function RegisterResource(const AUri, AName, AMimeType: string;
  AReader: TMCPResourceReader; const ADescription: string = ''): TMCPDefinitionOptions;
function RegisterResource(const AUri, AName, AMimeType: string;
  AMethod: TMCPResourceMethod; const ADescription: string = ''): TMCPDefinitionOptions;

function RegisterResourceTemplate(const AUriTemplate, AName,
  AMimeType: string; AReader: TMCPTemplateReader;
  const ADescription: string = ''): TMCPDefinitionOptions;
function RegisterResourceTemplate(const AUriTemplate, AName,
  AMimeType: string; AMethod: TMCPTemplateMethod;
  const ADescription: string = ''): TMCPDefinitionOptions;
```

Since #96 these registrations, like `RegisterPrompt`, are functions
returning `TMCPDefinitionOptions`. A call written as a statement
compiles as before. Code that assigned one of them to a variable of a
`procedure ... of object` type needs a matching `function ... of
object` type, or a small wrapper procedure that makes the call.

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

Resource, template and prompt registrations return
`TMCPDefinitionOptions` for fluent decoration, like tools return
`TMCPToolOptions`:

```pascal
function Title(const ATitle: string): TMCPDefinitionOptions;
function Icon(const ASrc: string; const AMimeType: string = '';
  const ASizes: string = ''; const ATheme: string = ''): TMCPDefinitionOptions;
function Meta(const AKey: string; AValue: TJSONData): TMCPDefinitionOptions;
// resources only:
function Annotations(const AAudience: array of string;
  APriority: Double = -1; const ALastModified: string = ''): TMCPDefinitionOptions;
function Size(ABytes: Int64): TMCPDefinitionOptions;
function CacheTtlMs(AValue: Integer): TMCPDefinitionOptions;
```

```pascal
Server.RegisterResource('mcp://app/report', 'report', 'text/csv', ReportReader)
  .Title('Monthly report')
  .Annotations(['user'], 0.8, '2026-11-01T00:00:00Z')
  .CacheTtlMs(60000);
```

An icon's `ASrc` must be a well-formed `https:` URI (a valid host,
IPv6 in brackets, and a numeric port if any) or `data:` URI (base64
data when it says `;base64`), `ASizes` is space-separated
(`'48x48 96x96'`) and `ATheme` is `light` or `dark`. An annotation's
`ALastModified` is a date-time with a time zone
(`2026-11-01T00:00:00Z` or a `+HH:MM` offset), as clients check it;
anything else raises `EMCPServer`. `Meta` takes ownership of its value
and puts it under the definition's `_meta`. `CacheTtlMs` sets the
`ttlMs` of reads served by the resource's reader (by default `0`,
revalidate every time); static text uses the server's `CacheTtlMs`,
and `CacheTtlMs` on it raises.
`TMCPToolOptions` has the same `Icon` and `Meta`. Fields from the
[schema](https://modelcontextprotocol.io/specification/2026-07-28/schema)
(verified 2026-11-26).

### Registering prompts

Eight overloads: with or without declared arguments, message-array or
result handlers, each in function and method shape:

```pascal
function RegisterPrompt(const AName, ADescription: string;
  AHandler: TMCPPromptHandler): TMCPDefinitionOptions;
function RegisterPrompt(const AName, ADescription: string;
  constref AArguments: TMCPPromptArguments;
  AHandler: TMCPPromptHandler): TMCPDefinitionOptions;
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
`resources` when there is a resource, template or resource resolver
(such as the one `MCP.Skills` adds), `prompts` when there is a prompt,
`completions` when there is a completion.

### x-mcp-header parameters

```pascal
function ToolHeaderParameters(const AName: string): TMCPHeaderParameters;
```

The parameters tool `AName` mirrors into `Mcp-Param-*` headers (header
name, property path, type), as `MCP.Schema.MCPHeaderParameters`
reads them from its `inputSchema`. The Streamable HTTP binding uses it
to validate the headers; a custom transport can too. See
[Routing headers](../guides/tools.md#routing-headers-x-mcp-header).

### Extensions

```pascal
procedure DeclareExtension(const AId: string; ASettings: TJSONObject = nil);
procedure EnsureExtension(const AId: string); overload;
procedure EnsureExtension(const AId: string; ASettings: TJSONObject);
  overload;
procedure SetResourceContentMeta(const AUri: string; AMeta: TJSONObject);
procedure RegisterMethod(const AMethod: string; AHandler: TMCPMethodHandler;
  ACacheable: Boolean = False);
procedure RegisterResourceResolver(const AUriPrefix: string;
  AResolver: TMCPResourceResolver);
procedure RestrictExtensionToModern(const AId: string);
procedure PinExtensionSettings(const AId: string; ASettings: TJSONObject);
procedure RegisterRoute(const AMethod, ANameParam: string;
  AHeaders: TMCPHeaderLookup);
function MethodRoute(const AMethod: string; out ANameParam: string;
  out AHeaders: TMCPHeaderLookup): Boolean;
function HookProblem(const AMethods: array of string;
  const AUriPrefix: string): string;
procedure Adopt(AObject: TObject);
function Adopted(AClass: TClass): TObject;
// on TMCPToolOptions:
function RequireLinkedResource(const AMetaPaths: array of string;
  const AMimeType: string = ''; const AUriPrefix: string = ''): TMCPToolOptions;
```

`DeclareExtension` adds `AId` to `capabilities.extensions` on
`server/discover` and `initialize`, with `ASettings` (owned; `nil`
gives `{}`). Identifiers need a prefix (`io.modelcontextprotocol/ui`);
anything else raises `EMCPServer`. Extensions are opt-in
([extension negotiation](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning#extension-negotiation),
verified 2026-11-26), so nothing is declared until this is called.
Declaring again replaces the settings; `EnsureExtension` declares
`ASettings` (owned; `nil` gives `{}`) only when the extension is not
declared yet and frees them otherwise, which is how helpers opt in. A tool's `RequireLinkedResource` makes startup (the first
`CreateSession`) raise `EMCPServer`, naming the tool, unless each of
`AMetaPaths` (`.`-separated keys under the tool's `_meta`) holds the
same string, the URI of a registered resource declared with media type
`AMimeType` unless that is `''`, starting with `AUriPrefix` unless that
is `''`. Startup reads the tool's final
`_meta`, so a later `.Meta` that changes the link is checked too. A
second call replaces the first.
`SetResourceContentMeta` gives a static text resource's read contents a
`_meta` object (owned). Settings and content `_meta` with children
stored as nil keep JSON nulls there.

An extension unit adds the requests and resources it serves through
three hooks, whose handler types are in `MCP.Extensions`:

```pascal
TMCPMethodHandler = function(AParams: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject of object;
TMCPResourceResolver = function(const AUri: string;
  const ACtx: TMCPRequestContext): TJSONArray of object;
```

`RegisterMethod` answers requests for `AMethod` in both eras, after
the server's own methods. The handler gets the request's `params`
(borrowed; `nil` when absent) and returns a new result object, which
the server stamps for the request's era and sends. `ACacheable` adds
the registry's `ttlMs` and `cacheScope` to a 2026-07-28 result, each
one the handler left out. An `EMCPProtocolError` it raises is answered as written, and
any other exception as `-32603`. A core method, one already
registered, an empty name or a nil handler raises `EMCPServer`.
`RegisterResourceResolver` serves `resources/read` for URIs that start
with `AUriPrefix`, after the registered resources and before the
templates. A URI under the prefix that the resolver does not know is
not found: templates are not consulted for it. Its resources are not
listed, its reads carry the registry's `ttlMs`, and it makes the
server declare the `resources` capability. A resolver returns new contents, or `nil` for a URI that
is none of its resources. Prefixes may not overlap, and a registered
resource under a resolver's prefix fails startup, since it would hide
what the extension serves there; so does a resource template whose
text before its first variable lies under the prefix. `Adopt` hands the
server an object to free after its handlers are gone, such as the
state those handlers read, and `Adopted` finds the first adopted
object of a class; adopting the same object again changes nothing.
`RestrictExtensionToModern` leaves extension `AId` out of the classic
`initialize` capabilities, for an extension whose methods answer
2026-07-28 requests only. `PinExtensionSettings` declares `AId` with
`ASettings` (owned; nil for `{}`) whatever `DeclareExtension` sets
before or after, for settings an extension unit must keep true. `RegisterRoute` makes a registered method routable on Streamable HTTP:
its requests carry an `Mcp-Name` header mirroring `params.ANameParam`
and, when `AHeaders` (a `TMCPHeaderLookup`, from `MCP.Extensions`) is
given, the `Mcp-Param-*` headers it names for that value, checked as for
`tools/call`. An unregistered method, an empty name parameter or a
second route raises `EMCPServer`. `MethodRoute` is the transport's view.
`HookProblem` says why registering `AMethods` or `AUriPrefix` would
fail, or `''`, without changing anything, so an extension can check
everything before it registers its first hook. Registering or adopting
after the server started raises `EMCPServer`; a refused `Adopt` frees
the object then, unless the server owns it already, in which case it
is freed with the server as before.

From `MCP.Apps`, MCP Apps on top of these
([Interactive UIs](../guides/mcp-apps.md)):

```pascal
const MCP_APPS_EXTENSION = 'io.modelcontextprotocol/ui';
const MCP_APP_MIME_TYPE = 'text/html;profile=mcp-app';

function RegisterAppResource(AServer: TMCPServer; const AUri, AName,
  AHtml: string; AUiMeta: TJSONObject = nil;
  const ADescription: string = ''): TMCPDefinitionOptions;   // static
function RegisterAppResource(AServer: TMCPServer; const AUri, AName: string;
  AReader: TMCPResourceReader; AUiMeta: TJSONObject = nil;
  const ADescription: string = ''): TMCPDefinitionOptions;   // reader
function MCPAppUiMeta(const AConnectDomains, AResourceDomains, AFrameDomains,
  ABaseUriDomains: array of string; APermissions: TMCPAppPermissions = [];
  const ADomain: string = ''; APrefersBorder: Integer = -1): TJSONObject;
function MCPAppContents(const AUri, AHtml: string;
  AUiMeta: TJSONObject = nil): TJSONArray;
function MCPClientRendersApps(const ACtx: TMCPRequestContext): Boolean;
// on TMCPToolOptions:
function AppResource(const AUri: string;
  const AVisibility: array of string): TMCPToolOptions;
```

| Member | Meaning |
| --- | --- |
| `RegisterAppResource` | A `ui://` resource with the app media type; `AUiMeta` (owned, `nil` for none) goes on its declaration's `_meta.ui` and, for static HTML, on its read contents. A non-`ui://` URI raises `EMCPServer`. Declares the extension unless it is declared already |
| `MCPAppUiMeta` | A new `_meta.ui` object the caller owns until it hands it over: the CSP domain lists (empty ones left out), permissions, domain, and `APrefersBorder` (`-1` unset, `0` false, `1` true) |
| `MCPAppContents` | A reader's contents: the HTML as text with the app media type, and `AUiMeta` (owned) as `_meta.ui`; the array is the caller's to return |
| `MCPClientRendersApps` | Whether the request's client declared the extension with the app media type in its `mimeTypes` |
| `.AppResource` | Links the tool to `AUri`: `_meta.ui` with `resourceUri` and `visibility` (`'model'`, `'app'`; `[]` for both), and the older flat `ui/resourceUri` key. Through `RequireLinkedResource`, startup requires both keys to name the same `ui://` resource, registered with the app media type; the extension is declared unless it is already. Linking the tool again replaces the earlier link |

From `MCP.Skills`, the Skills extension on these hooks
([Skills](../guides/skills.md)):

```pascal
const MCP_SKILLS_EXTENSION = 'io.modelcontextprotocol/skills';
const MCP_SKILL_MAX_FILES = 512;
const MCP_SKILL_MAX_BYTES = 16777216;

type TMCPSkillFile = record
  Path: string;
  Content: RawByteString;
  MimeType: string;
end;

function MCPSkillFile(const APath: string; const AContent: RawByteString;
  const AMimeType: string = ''): TMCPSkillFile;
procedure RegisterSkill(AServer: TMCPServer; const ASkillPath: string;
  AFrontmatter: TJSONObject; const ABody: string;
  const AFiles: array of TMCPSkillFile);
procedure RegisterSkillDirectory(AServer: TMCPServer; const ARoot: string;
  const APrefix: string = '');
function MCPSkillMarkdown(AFrontmatter: TJSONObject;
  const ABody: string): string;
```

| Member | Meaning |
| --- | --- |
| `MCPSkillFile` | A supporting file: its path relative to the skill root, its raw bytes (`RawByteString`, so no code page conversion touches them), and a media type (`''` picks one from the extension, or `text/plain` for other UTF-8 text and `application/octet-stream` otherwise) |
| `RegisterSkill` | The skill at `skill://ASkillPath/SKILL.md`, written from `AFrontmatter` (owned, also on failure) and `ABody`, with `AFiles`. The frontmatter's `name` must equal the path's last segment, and the Agent Skills fields are checked. A bad name, path or field, files that clash (the same URI, one under another, or a file with the directory media type), a URI already served, or a skill over `MCP_SKILL_MAX_FILES` or `MCP_SKILL_MAX_BYTES` with its nested skills' files raises `EMCPServer`, as does a call after the server started, and the server is left as it was. The first call declares the extension with `directoryRead` unless it is declared already, and serves `skills/list`, `skills/get`, `resources/directory/read` and the files |
| `RegisterSkillDirectory` | Every skill under `ARoot`: each directory holding a `SKILL.md`, at `skill://APrefix/<its path below ARoot>`, its `SKILL.md` and files served as the bytes on disk. Its frontmatter is read with `MCP.Frontmatter`'s YAML subset, and the checks of `RegisterSkill` apply. Directories are listed by directory reads even when empty. Names starting with `.` are left out, and so are files outside any skill. A symbolic link (`ARoot` included), anything but a directory or regular file, a directory that cannot be read, a skill over the limits (checked from the listed sizes before reading, nested skills' files and any registered skill the tree lies below counted), a `SKILL.md` in `ARoot` itself, or frontmatter outside the subset (named with its file and line) raises `EMCPServer`, and then none of the tree's skills is registered. The tree is trusted and must not change while it is read |
| `MCPSkillMarkdown` | The `SKILL.md` text `RegisterSkill` writes: a YAML frontmatter block for `AFrontmatter` (borrowed), then `ABody`. Strings are double-quoted with escapes YAML 1.1 and 1.2 share; a fractional number, a key written longer than the 1024 characters YAML parsers read, or text that is not UTF-8 raises `EMCPServer` |

From `MCP.Events`, the Events extension's poll and push delivery
([Events](../guides/events.md)):

```pascal
const MCP_EVENTS_EXTENSION = 'io.modelcontextprotocol/events';
const MCP_EVENT_DEFAULT_POLL_MS = 30000;
const MCP_EVENT_DEFAULT_HEARTBEAT_MS = 30000;   // push: the grant
const MCP_EVENT_MIN_HEARTBEAT_MS = 1000;        // and its bounds
const MCP_EVENT_MAX_HEARTBEAT_MS = 300000;
const MCP_SUBSCRIPTION_ID_KEY = 'io.modelcontextprotocol/subscriptionId';

type TMCPEventQuery = record
  Arguments: TJSONObject;   // borrowed; {} when absent
  Cursor: string;
  FromNow: Boolean;         // null or absent cursor
  MaxAgeMs: Int64;          // -1 when absent
  MaxEvents: Integer;       // -1 when absent
end;

type TMCPEventPoll = record
  Events: TJSONArray;       // owned; nil for none
  Cursor: string;
  NoReplay: Boolean;        // cursor null
  HasMore, Truncated: Boolean;
  NextPollMs: Integer;      // 0: the registration's
  GapCursor: string;        // push: the position before a gap's events
end;

TMCPEventCheck = function(const AQuery: TMCPEventQuery;
  const ACtx: TMCPRequestContext): TMCPEventPoll;   // and an of-object form

function MCPEventPoll(const ACursor: string;
  AEvents: TJSONArray = nil): TMCPEventPoll;
function MCPEventOccurrence(const AEventId, ATimestamp: string;
  AData: TJSONObject; AMeta: TJSONObject = nil): TJSONObject;
procedure RegisterEvent(AServer: TMCPServer; const AName,
  ADescription: string; AInputSchema, APayloadSchema: TJSONObject;
  ACheck: TMCPEventCheck;
  ANextPollMs: Integer = MCP_EVENT_DEFAULT_POLL_MS);   // and TMCPSchema forms
```

| Member | Meaning |
| --- | --- |
| `RegisterEvent` | Event type `AName`, delivered by poll and push, before the server starts. `AInputSchema` (owned) describes the arguments: root type object, `x-mcp-header` annotations as for tools, checked against arguments when inside the server-enforced subset. `APayloadSchema` (owned) describes each occurrence's data, checked when inside the subset. An input schema outside the subset is refused. The first call declares the extension with `{}` on `server/discover` only (`RestrictExtensionToModern`, `PinExtensionSettings`) and serves `events/list`, `events/poll` and `events/stream` on 2026-07-28 (`-32601` for a classic client), routed on Streamable HTTP. A stream polls the check with `MaxEvents` 1, and answers `-32026` where the transport cannot stream. A duplicate or empty name, a bad schema, a nil check or a call after the server started raises `EMCPServer` |
| `TMCPEventQuery` | One poll: the arguments, the cursor or `FromNow` for a null or absent one, and the client's `maxAgeMs` (at least 0) and `maxEvents` (at least 1), read as the schema reads integers |
| `TMCPEventPoll` | A check's answer: at most `MaxEvents` occurrences, the cursor after them (null with `NoReplay`), `HasMore`, `Truncated` and `NextPollMs`. Events on a poll from now, more than `MaxEvents`, an occurrence without object data, an RFC 3339 timestamp or a payload matching its schema, and on a poll `HasMore` with `NoReplay`, answer `-32603`. With `Truncated` and events, `GapCursor` is the position delivery resumed from, before them, which a push stream's gap notification carries; with `''` that notification carries the fresh cursor, after the events, which then belong to the gap `Truncated` signals |
| `MCPEventOccurrence` | One occurrence: `AData` (owned) and `AMeta` (owned) as given. An empty `AEventId` is derived from the name, timestamp and data, so the same event keeps its id; the server adds the name |

### The request context

Every handler receives `TMCPRequestContext` (from `MCP.Protocol`):

| Member | Meaning |
| --- | --- |
| `ProtocolVersion` | Negotiated revision for this request |
| `ClientName`, `ClientVersion` | From `clientInfo`; `''` when absent |
| `ClientCapabilities` | The per-request capability object |
| `HasCapability(Name)` | Capability probe (used for MRTR gating and `RequiresClientCapability`). On a 2026-07-28 request, a capability that schema defines counts only in its shape, so `null` or `false` is not declared, while one of the client's own counts when its key is present. A classic-handshake client counts by presence alone, since its capabilities follow its own revision's schema |
| `LogLevel` | Client's requested log floor; `''` = no log opt-in |
| `HasProgressToken`, `ProgressToken` | Progress opt-in state |
| `InputResponses`, `RequestState` | MRTR retry payload — see [Client requests](client-requests.md) |
| `Meta` | The request's whole `params._meta`, borrowed for the call and read-only (nil when absent, as a classic-era request may leave it), for keys the library does not interpret, such as `traceparent`; clone what you keep or change, as the server reads parts of it after the handler returns |
| `HasSubCapability(Name, Member)` | Whether `HasCapability(Name)` holds and the capability has member `Member`, such as `('elicitation', 'url')` or `('sampling', 'tools')`. An empty `elicitation` object declares `form`, as the specification reads it |
| `HasExtension(Id)`, `ExtensionSettings(Id)` | Whether the client declared extension `Id` in `clientCapabilities.extensions`, and its settings object (borrowed; nil when absent) |
| `IsCancelled` | Cooperative cancellation probe |
| `RequestId`, `StreamHost` | On a 2026-07-28 request: its JSON-RPC id (borrowed for the call) and the session's stream host (a `TMCPStreamHost`; nil when the transport cannot stream), where a handler parks a long-lived stream (#126) |

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
transports wrap — custom transport authors call these directly
(see [Architecture](../internals/architecture.md#the-sans-io-core)), and
so does a test that hand-writes a line; for everything else in a test,
the [test client](test-client.md) builds the requests.

A transport that can learn of a cancellation while a handler runs
installs a poll on the session (#93):

```pascal
type
  TMCPCancellationPoll = function(ASession: TMCPSession;
    AUserData: Pointer): Boolean;

procedure TMCPSession.SetCancellationPoll(APoll: TMCPCancellationPoll;
  AUserData: Pointer);   // nil removes it
function TMCPSession.IsActiveRequestId(ARequestId: TJSONData): Boolean;
function TMCPSession.CancelsActiveRequest(const ALine: string): Boolean;
function MCPCancellationTarget(const ALine: string): TJSONData;
```

The session calls the poll on the handler's own thread whenever the
handler asks `IsCancelled` and before each in-request notification,
and only while the running request is not cancelled yet. Returning
`True` cancels that request. A poll may instead pass a
`notifications/cancelled` line to `HandleMessage` for the same session,
which cancels the request the ordinary way; that is the only re-entry
allowed. `MCPCancellationTarget` returns the `requestId` of a line that
is a `notifications/cancelled` dispatch would accept (well formed, with
a string `reason` or none), as a new object the caller owns, or `nil`.
`IsActiveRequestId` tells whether such an id names the running request,
matched as `notifications/cancelled` matches it, and
`CancelsActiveRequest` does both for one line. A transport that queues
lines classifies each once with `MCPCancellationTarget` and matches the
kept id on every poll.
`AUserData` is borrowed and must stay valid until the poll is removed
or the session is freed, and an exception from the poll reaches the
handler's `IsCancelled` call. The poll stays on the session across its
requests ([ADR-0001](../adr/0001-sans-io-core.md#amendment-2026-11-27-93)).
The stdio loop's poll reads what is waiting on a plain file input, and
the HTTP binding's reports a closed or reset connection.

### Long-lived requests

`MCP.Streams` holds a request that keeps writing after its handler
returns, such as `events/stream` (#126):

```pascal
type TMCPStream = class
  constructor Create(ARequestId: TJSONData);   // copied
  function Step(ASink: TMCPLineSink;
    ASinkData: Pointer): Int64; virtual; abstract;   // due, on its clock
  procedure Cancel; virtual;
  procedure Close(ASink: TMCPLineSink; ASinkData: Pointer); virtual; abstract;
  property Id: TJSONData;
  property Finished: Boolean;
end;

type TMCPStreamHost = class
  procedure Park(AStream: TMCPStream);   // owned
  function TakeParked: TMCPStream;       // the caller's, or nil
end;

function MCPTakeStream(AHost: TMCPStreamHost; AProduced: Boolean;
  const AResponse: string): TMCPStream;   // the stream to drive, or nil
property TMCPSession.StreamHost: TObject;   // borrowed; nil for none
function MCPNowMs: Int64;                   // monotonic milliseconds
property TMCPStream.Clock: TMCPClock;       // MCPStreamClock, else MCPNowMs
var MCPStreamClock: TMCPClock;              // nil: MCPNowMs; tests set it
function MCPStreamNow: Int64;               // MCPStreamClock's time
property TMCPStreamHost.ShutdownProbe: TMCPCancellationProbe;
function TMCPStreamHost.ShuttingDown: Boolean;
property TMCPStream.CancelProbe: TMCPCancellationProbe;   // the transport's
function TMCPStream.Cancelled: Boolean;
```

A transport that can drive streams sets `StreamHost` on its session.
The core hands it to each 2026-07-28 handler as `ACtx.StreamHost`. A
handler parks at most one stream and returns a placeholder result, which
the transport drops. After `HandleMessage`, the transport asks
`MCPTakeStream` for the stream to drive: only a request answered with a
result hands one over. When the core answered an error, such as a
handler that parked and then raised, or nothing, because the request was
cancelled, the stream is cancelled and freed, and the transport sends
the response as usual. The
transport then calls `Step` until `Finished`, again by the time `Step`
returns on the stream's clock. It sets `CancelProbe` to its live check
for a client that went away, which `Cancelled` asks, between the
stream's own steps and from the checks the stream runs. It calls
`Cancel` when the client goes away. Streamable HTTP calls `Close`, for
the final frame, when the transport stops, after a check that was
running returns; the stdio loop ends every stream at the end of input,
and a check that was running sees `IsCancelled`, while requests already
queued are still served. A transport sets `TMCPStreamHost.ShutdownProbe`
to its Stop or end of input, which a handler's own checks ask beside the
request's cancellation (`ShuttingDown`). A sink that raises ends the
stream.
Streamable HTTP steps a stream in the request's thread; the stdio loop
steps its streams between lines on its one thread.

`MCPLogDiagnostic` writes one line to stderr, best effort, the way the
core's own diagnostics do: a closed stderr is ignored, and on Unix
cannot end the process with SIGPIPE.

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
| `SchemaFrom` | Published properties to a schema: scalars, enums, dynamic arrays of `string`, `Integer`, `Int64`, `Double` or `Boolean` and `TMCPArgs` descendants as nested objects, each read and written through the same field (at most 16 levels, as binding and `MCPSerialize` also enforce); raises `EMCPSchema` for anything else |
| `MCPBindArguments` | Creates an `AClass` instance from `AArguments` (borrowed), nested objects and arrays included; `False` with an in-band message naming the path on a missing or mistyped argument; the caller owns `AInstance` on success |
| `MCPSerialize` | The reverse, as a new object the caller owns; a nil nested object is left out; raises `EMCPSchema` for an unmapped property, a class property that is not a `TMCPArgs` read and written through the same field, or a value with no JSON form (NaN) |

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
page, and puts the code page back exactly when it returns. On a plain
file input (stdin, a file, a pipe) it reads the handle directly, after
the bytes the `Text` had already buffered, so a `notifications/cancelled`
reaches a running handler; a `Text` with its own I/O driver, such as
one from `AssignStream`, is read through `Text` and learns of a
cancellation only after the handler returns. A failed read raises
`EInOutError` once the lines read before it are served.

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
(typed and template handlers included), or an extension's method or
event check, it becomes the error response
with exactly that code, message and data, in both eras. It is
deliberate, so [`RedactErrorDetails`](../guides/configuration.md#redacterrordetails)
leaves it alone: its message and data reach the client verbatim, so
keep secrets out of them. Every other exception keeps its mapping: an
`isError` result from a tool, `-32603` from a prompt or a resource
reader. `Data` is owned by the exception; do not free or change it.

| Code | Use it for |
| --- | --- |
| `-32602` | Invalid params of a prompt or resource request that the handler rejects itself, or a `requestState` the handler cannot accept. A tool's argument errors stay in-band (`MCPErrorResult`), so the model can correct them |
| `-32021` | A client capability the request needs and did not declare; it must carry `data.requiredCapabilities`, so build it with `MCPMissingCapabilityError('sampling')`, or for several, `EMCPProtocolError.Create(-32021, …, BuildMissingCapabilityData(['sampling', 'roots']))` from `MCP.Protocol`, or for one member, `EMCPProtocolError.Create(-32021, …, BuildMissingCapabilityData('elicitation', 'url'))`. Each builder returns a fresh object that the exception then owns; the list form raises `EArgumentException` for an empty list or a repeated name, the member form for an empty capability or member. The constructor refuses `-32021` unless `requiredCapabilities` names at least one capability shaped as in `ClientCapabilities`: each capability that schema defines is an object, and so are `sampling.tools`, `elicitation.form` and each `extensions` entry, while a capability of the client's own may have any value. Data changed after that is sent as `-32603` |
| `-32700`, `-32600`, `-32601`, `-32603` | The other JSON-RPC codes, with their JSON-RPC meanings |
| `-32023` to `-32027` | The general-purpose codes SEP-3415 allocates, each with typed data: NotFound (`data.kind`), Forbidden, ResourceExhausted (`data.limit`), Unsupported (`data.feature`) and CallbackEndpointError; `MCP.Errors` names them `MCP_ERROR_NOT_FOUND` and so on |
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
