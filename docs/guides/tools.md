# Tools

## Executive Summary

A tool is a function your server exposes for an AI agent to call: a
name, a description the model reads, a JSON Schema for its arguments,
and a Pascal handler. Register tools on a `TMCPServer` before serving;
the library validates every call against the schema before your
handler runs, turns handler exceptions into in-band errors the model
can correct against, and stamps the protocol envelope — your handler
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
  `structuredContent` matching your output schema.
- `MCPImageResult(Bytes, 'image/png')` — one image content block;
  takes raw bytes (base64-encoded for you) or already-base64 data.
- `MCPErrorResult('...')` — an explicit in-band error
  (`isError: true`).

## Validation before your handler runs

Every call is checked against the registered schema's enforceable
subset — `type`, `properties`, `required`, `enum`, `default` —
before the handler runs. Violations become in-band `isError` results
in the same shape for raw and typed tools, so the model sees what it
got wrong and retries. Absent optional arguments are seeded with their
schema `default`; unknown argument properties are ignored.

A raw schema that uses keywords *outside* the enforced subset fails at
startup, naming the offending keyword, unless the registration is
marked `.ApplicationValidated` — the documented escape hatch that
hands argument validation to your handler (see
[Schemas](schemas.md#the-enforced-subset)).

Deeper, semantic validation stays your handler's job — report
violations with `MCPErrorResult`, not exceptions, when you want the
model to read and correct them. Exceptions work too: an escaped
handler exception becomes an `isError: true` result automatically
(with the message redactable — see
[Configuration](configuration.md#redacterrordetails)).

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
counts words and characters; its argument and result classes *are*
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
    FChars: Integer;
  published
    property words: Integer read FWords write FWords;
    property chars: Integer read FChars write FChars;
  end;

function CountHandler(AArgs: TMCPArgs;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Counts: TCountResult;
begin
  Counts := TCountResult.Create;
  with AArgs as TCountArgs do
  begin
    Counts.words := CountWords(text); // your domain logic
    Counts.chars := Length(text);
  end;
  Result := MCPStructuredResult(
    Format('%d words, %d characters', [Counts.words, Counts.chars]),
    Counts); // serializes the published properties, then frees Counts
end;

Server.RegisterTool('count_text', 'Count words and characters in text',
  TCountArgs, TCountResult, CountHandler)
  .Title('Text Counter').ReadOnlyHint.IdempotentHint;
```

`tools/list` then advertises the derived schemas and annotations —
this is the library's actual response (formatted for reading; the
wire is one line):

```json
{
  "name": "count_text",
  "description": "Count words and characters in text",
  "inputSchema": {
    "type": "object",
    "properties": { "text": { "type": "string" } },
    "required": ["text"]
  },
  "outputSchema": {
    "type": "object",
    "properties": {
      "words": { "type": "integer" },
      "chars": { "type": "integer" }
    },
    "required": ["words", "chars"]
  },
  "title": "Text Counter",
  "annotations": { "readOnlyHint": true, "idempotentHint": true }
}
```

A call answers with both the text content and the structured form:

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "content": [{ "type": "text", "text": "4 words, 19 characters" }],
    "isError": false,
    "structuredContent": { "words": 4, "chars": 19 },
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
available on `ACtx`:

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

The server stays stateless across rounds — your `requestState` string
is echoed back by the client (treat it as untrusted input). Request
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
