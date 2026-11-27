# Tools

## Executive Summary

A tool is a function your server exposes for an AI agent to call: a
name, a description the model reads, a JSON Schema for its arguments,
and a Pascal handler. Register tools on a `TMCPServer` before serving;
the library validates every call against the schema before your
handler runs, turns handler exceptions into in-band errors the model
can correct against (an `EMCPProtocolError` answers with its JSON-RPC
error instead), and stamps the protocol envelope — your handler
contains domain logic and nothing else.

## The registration model

Every tool registration names the tool, describes it, declares its
argument schema, and binds a handler:

```pascal
Server.RegisterTool('greet', 'Greet someone by name',
  ObjectSchema.AddString('name', 'Who to greet'),
  Greet);
```

The schema can be declared four ways — pick per tool, they coexist on
one server:

- **Fluent builder** — `ObjectSchema.AddString(...).AddNumber(...)`
  for the flat object schemas most tools need. See
  [Schemas](schemas.md).
- **Typed argument class** — a `TMCPArgs` descendant whose published
  properties *are* the schema; the handler receives a populated,
  validated instance instead of raw JSON. See
  [Schemas](schemas.md#typed-argument-classes).
- **Raw JSON string** — `'{"type":"object",...}'`, parsed and
  validated at registration.
- **Definition object** — a `TJSONObject` you assembled yourself
  (`name`/`description`/`inputSchema`), for tools whose definitions
  come from data.

Handlers come in two shapes per style — plain functions and
`of object` methods — so both programs and class-based hosts register
naturally. All registration must happen before the first session is
created: the registries freeze when serving starts, and a late
`RegisterTool` raises `EMCPServer`.

## Handlers

A raw-schema handler receives the arguments as `TJSONObject` plus a
request context:

```pascal
function Greet(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPTextResult('Hello, ' + AArguments.Get('name', 'world') + '!');
end;
```

A typed handler receives the populated argument instance:

```pascal
function Add(AArgs: TMCPArgs;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  with AArgs as TAddArgs do
    Result := MCPTextResult(FloatToStr(a + b));
end;
```

`ACtx` carries the per-request facts: the negotiated protocol version,
client name/version and capabilities, the progress token and log level
(see [Progress and logging](progress-and-logging.md)), the MRTR retry
payload (below), and `IsCancelled` for cooperative cancellation.
Handlers are synchronous — under stdio the loop is read-handle-write,
so keep them short.

Results are built with the helpers in
[Results and content](../reference/results.md):

- `MCPTextResult('...')` — plain text content.
- `MCPStructuredResult(Text, StructuredData)` — text plus
  `structuredContent` matching your output schema, which the server
  checks before sending when the schema is inside
  [the enforced subset](schemas.md#the-enforced-subset).
  `MCPStructuredResult(StructuredData)` uses the serialized JSON as the
  text. The value can be any JSON value: an array of records, a number.
- `MCPImageResult(Bytes, 'image/png')` — one image content block;
  takes raw bytes (base64-encoded for you) or already-base64 data.
- `MCPErrorResult('...')` — an explicit in-band error
  (`isError: true`).

An exception a handler raises also becomes an in-band `isError`
result: that is the channel a model reads and corrects against. When
the request itself must be refused with a JSON-RPC error instead, for
example a client capability it needs and did not declare, raise
`EMCPProtocolError` (see
[Answering with a JSON-RPC error](../reference/server.md#answering-with-a-json-rpc-error)).

## Validation before your handler runs

Every call is checked before the handler runs. A raw schema's
arguments are checked against the enforced subset — `type`,
`properties`, `required`, `items`, `enum`, `default`, nested to any
depth; a typed tool's are checked as they bind to its argument class.
Violations become in-band `isError` results
in the same shape for raw and typed tools, so the model sees what it
got wrong and retries. Absent optional arguments are seeded with their
schema `default`; unknown argument properties are ignored.

A raw schema that uses keywords *outside* the enforced subset fails at
startup, naming the offending keyword, unless the registration is
marked `.ApplicationValidated` — the documented escape hatch, for input
schemas only, that hands argument validation to your handler (see
[Schemas](schemas.md#the-enforced-subset)).

Deeper, semantic validation stays your handler's job — report
violations with `MCPErrorResult`, not exceptions, when you want the
model to read and correct them. Exceptions work too: an escaped
handler exception becomes an `isError: true` result automatically
(with the message redactable — see
[Configuration](configuration.md#redacterrordetails)); an
`EMCPProtocolError` is the exception to that, and is never redacted.

## Routing headers (x-mcp-header)

A parameter can be mirrored into an HTTP header so that load balancers
and gateways can route on it without reading the body. Mark it with
`x-mcp-header` in a raw schema:

```pascal
Server.RegisterTool('execute_sql', 'Run SQL in a region',
  '{"type":"object","properties":{' +
  '"region":{"type":"string","x-mcp-header":"Region"},' +
  '"query":{"type":"string"}},"required":["region","query"]}',
  SqlHandler);
```

`x-mcp-header` is part of the enforced subset, so the server still
validates the arguments.

Over Streamable HTTP the client then sends `Mcp-Param-Region:
us-west1` with the call, and the server checks that the header matches
the body. For each header the called tool designates: an argument with
a non-null value needs its header exactly once, and an absent or
`null` argument needs none. The call is refused with HTTP 400 and
`-32020` when a needed header is missing, sent more than once or
different from the body, or when a header comes for an absent or
`null` argument. `Mcp-Param-*` headers the tool does not designate are
ignored, as the spec asks. Header names match in any ASCII case. An empty header is the empty string's,
and integers compare as numbers within the JavaScript safe range, so a
body `42.0` matches a header `42`. The comparison goes by the declared
type: a body value of another type, or an array or object, never
matches. The HTTP server strips a header value's leading and trailing
whitespace and control bytes before the check sees it, so a plain value
with such edges (which a client must base64-encode) is not caught; the
decoded comparison still holds. At registration the server checks the annotations
the way a client would: a non-empty header token, unique (ignoring
case), only on a `string`, `integer` or `boolean` property, and only on
properties reached through `properties` from the root. A violation
raises `EMCPServer`, because a client would drop the whole tool from
its list
([x-mcp-header](https://modelcontextprotocol.io/specification/2026-07-28/server/tools#x-mcp-header),
verified 2026-11-26). Header values are visible to every intermediary,
so do not mark secrets or personal data.

> [!NOTE]
> Upgrading (breaking): `=?base64?...?=` values in `Mcp-Name`, sent for
> every tool, prompt and resource whether annotated or not, now decode
> strictly too. A custom client that left the base64 padding off gets
> 400; send standard base64 with its `=` padding, as the spec's Value
> Encoding asks. The official TypeScript client (2.0.0) already does
> (verified 2026-11-27: it encodes with `btoa`, which pads).

## Annotations

`RegisterTool` returns a `TMCPToolOptions` for fluent annotation
chaining:

```pascal
Server.RegisterTool('add', 'Add two numbers and return the sum',
  TAddArgs, TSumResult, AddHandler)
  .Title('Adder').ReadOnlyHint.IdempotentHint;
```

`Title` sets a display name; `ReadOnlyHint`, `DestructiveHint`,
`IdempotentHint`, and `OpenWorldHint` set the spec's behavior-hint
annotations clients may surface or act on. `ApplicationValidated`
marks a raw schema as handler-validated (above).

## A complete tool, end to end

Everything above in one worked example — typed arguments, structured
output, annotations, and what actually crosses the wire. The tool
counts words and UTF-8 bytes; its argument and result classes *are*
its schemas:

```pascal
type
  TCountArgs = class(TMCPArgs)
  private
    FText: string;
  published
    property text: string read FText write FText;
  end;

  TCountResult = class(TMCPArgs)
  private
    FWords: Integer;
    FBytes: Integer;
  published
    property words: Integer read FWords write FWords;
    property bytes: Integer read FBytes write FBytes;
  end;

function CountHandler(AArgs: TMCPArgs;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Words, Bytes: Integer;
  Counts: TCountResult;
begin
  // Compute first: if the domain logic raises, nothing is allocated yet.
  with AArgs as TCountArgs do
  begin
    Words := CountWords(text); // your domain logic
    // Strings arrive as UTF-8: Length counts bytes, not characters.
    Bytes := Length(text);
  end;
  Counts := TCountResult.Create;
  Counts.words := Words;
  Counts.bytes := Bytes;
  Result := MCPStructuredResult(
    Format('%d words, %d bytes', [Words, Bytes]),
    Counts); // serializes the published properties, then frees Counts
end;

Server.RegisterTool('count_text', 'Count words and UTF-8 bytes in text',
  TCountArgs, TCountResult, CountHandler)
  .Title('Text Counter').ReadOnlyHint.IdempotentHint;
```

`tools/list` then advertises the derived schemas and annotations —
this is the tool's entry from the library's actual `result.tools`
array (formatted for reading; the full response wraps it in the
JSON-RPC envelope on one line):

```json
{
  "name": "count_text",
  "description": "Count words and UTF-8 bytes in text",
  "inputSchema": {
    "type": "object",
    "properties": { "text": { "type": "string" } },
    "required": ["text"]
  },
  "outputSchema": {
    "type": "object",
    "properties": {
      "words": { "type": "integer" },
      "bytes": { "type": "integer" }
    },
    "required": ["words", "bytes"]
  },
  "title": "Text Counter",
  "annotations": { "readOnlyHint": true, "idempotentHint": true }
}
```

A `tools/call` request (`_meta` as every modern request carries it):

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/call",
  "params": {
    "name": "count_text",
    "arguments": { "text": "Grüße from Pascal MCP" },
    "_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities": {}
    }
  }
}
```

answers with both the text content and the structured form — 23
bytes for 21 characters, since `ü` and `ß` take two bytes each in
UTF-8:

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "content": [{ "type": "text", "text": "4 words, 23 bytes" }],
    "isError": false,
    "structuredContent": { "words": 4, "bytes": 23 },
    "resultType": "complete",
    "_meta": {
      "io.modelcontextprotocol/serverInfo": {
        "name": "example-server", "version": "1.0.0"
      }
    }
  }
}
```

And a mistyped argument (`"text": 42`) never reaches the handler —
the server answers in-band, in a shape the model can correct against:

```json
{
  "content": [{ "type": "text", "text": "Argument \"text\" must be a string" }],
  "isError": true
}
```

## Asking the client for more input (MRTR)

A handler that needs more input mid-call — a missing value, a user
confirmation, a model completion — returns `MCPInputRequired(...)`
instead of a final result. The client gathers the responses and
retries the same call; your handler re-enters with the responses
available on `ACtx`. Declare the capability each kind of request needs
on the registration, so a client without it is refused before the
handler runs rather than after it has streamed progress:

```pascal
Server.RegisterTool('greet_user', 'Greet a person', '{"type":"object"}',
  GreetUserHandler).RequiresClientCapability('elicitation');
```

```pascal
function GreetUserHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Content: TJSONObject;
begin
  Content := MCPElicitationContent(ACtx, 'who');
  if Content = nil then
    Exit(MCPInputRequired(TJSONObject.Create(['who',
      MCPElicitFormRequest('Who should be greeted?',
      ObjectSchema.AddString('name', 'Name of the person to greet'))]),
      'greet-round-1'));
  Result := MCPTextResult('Hello, ' + Content.Get('name', 'stranger') + '!');
end;
```

The server stays stateless across rounds: your `requestState` string
travels through the client, sealed by the server so that a tampered or
expired copy, or one presented for another tool, other arguments or
another server, is refused before your handler runs. A valid token can
be presented again until it expires, so a side effect that must happen
once needs its own guard (see
[requestState sealing](configuration.md#requeststate-sealing)). Request
kinds are capability-gated per request. The entry builders and
accessors are documented in
[Client requests](../reference/client-requests.md).

## Cancellation

`notifications/cancelled` flips a per-request token; long-running
handlers poll `ACtx.IsCancelled` and abandon work. The serial stdio
transport cannot deliver a cancellation while a handler is running
(one more reason to keep handlers short); transports with mid-request
delivery points can.

> These protocol behaviours implement spec revision 2026-07-28; the
> dated official-spec citations live in the architecture page's
> [Spec grounding](../internals/architecture.md#spec-grounding)
> section.
