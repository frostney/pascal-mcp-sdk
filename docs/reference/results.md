# Results and Content

Handlers build their answers with these helpers. The result and
message builders are in `MCP.Server`; the content blocks they can
carry are in `MCP.Content`.

## Tool results

A tool handler returns `TMCPToolResult`; build it with one of:

```pascal
function MCPTextResult(const AText: string): TMCPToolResult;
function MCPErrorResult(const AText: string): TMCPToolResult;
function MCPStructuredResult(const AText: string;
  AStructured: TJSONData): TMCPToolResult;
function MCPStructuredResult(AStructured: TJSONData): TMCPToolResult;
function MCPStructuredResult(const AText: string;
  AObj: TMCPArgs): TMCPToolResult;
function MCPImageResult(const ABase64,
  AMimeType: string): TMCPToolResult;
function MCPImageResult(const AData: TBytes;
  const AMimeType: string): TMCPToolResult;
function MCPAudioResult(const ABase64,
  AMimeType: string): TMCPToolResult;
function MCPAudioResult(const AData: TBytes;
  const AMimeType: string): TMCPToolResult;
function MCPContentResult(const ABlocks: array of TJSONObject): TMCPToolResult;
```

- `MCPTextResult` — one text content block.
- `MCPErrorResult` — the same shape with `isError: true`: the in-band
  error channel a model reads and corrects against. Use it for
  everything the *caller* did wrong; reserve exceptions for what went
  wrong *in the server* (they become `isError` results too, with
  messages subject to
  [redaction](../guides/configuration.md#redacterrordetails)).
- `MCPStructuredResult` — text plus `structuredContent`, which can be
  any JSON value (object, array, string, number, boolean or null). The
  `TJSONData` overloads take ownership of the data you pass; the
  one-argument form puts the value's serialized JSON in the text block,
  which the specification says a structured result should also carry.
  The `TMCPArgs` overload serializes an instance of a typed output
  class **and frees it** (see
  [Schemas](../guides/schemas.md#typed-argument-classes)). When the
  tool declares an output schema inside the
  [enforced subset](../guides/schemas.md#the-enforced-subset), the
  server checks the value before sending it and turns a mismatch into
  an `isError` result. To a client on a classic-handshake revision
  (2025-11-25 and earlier), which allows only object structured
  content, a non-object value is sent as a text block of its JSON,
  after your own text unless a block already carries exactly that.
- `MCPImageResult` — one image content block (`type`, `data`,
  `mimeType`). The string overload takes data that is **already**
  base64 (the same contract as `MCPBlobContents`); the `TBytes`
  overload base64-encodes the raw bytes itself. `AMimeType` is the
  image's IANA media type (`image/png`, `image/jpeg`, …) and goes on
  the wire verbatim — the spec names no enumeration, so the handler
  owns that choice.
- `MCPAudioResult` — one audio content block, with the same two
  overloads and contracts as `MCPImageResult` (`audio/wav`,
  `audio/mpeg`, …).
- `MCPContentResult` — any list of content blocks from
  [`MCP.Content`](#content-blocks), in order; it takes ownership of
  every block, also when it raises `EMCPServer` for a `nil` or repeated
  block. Use it for mixed results, resource links and embedded
  resources:

  ```pascal
  Result := MCPContentResult([
    MCPTextContent('Found the entry point:'),
    MCPResourceLink('file:///src/main.pas', 'main.pas', 'text/x-pascal'),
    MCPEmbeddedText('file:///src/main.pas', 'text/x-pascal', Source)]);
  ```

The MRTR variant `MCPInputRequired` is documented with the other
client-request builders in [Client requests](client-requests.md).

### Numbers on the wire

Float properties of a typed output class and the `progress`/`total`
of progress notifications go on the wire as the shortest decimal that
parses back to the same `Double`, written the way JavaScript's
`JSON.stringify` writes it: `0.25`, `1000000000000000`, `1e+21`,
`5e-324`. Integers of magnitude below 2^53 are JSON integers, and
negative zero is `0`. NaN and infinities have no JSON form: serializing one raises
`EMCPSchema` (in a tool handler, that becomes an `isError` result like
any other exception). `MCP.Schema` exposes the same conversion for
hand-built JSON:

```pascal
function MCPWireNumber(AValue: Double): TJSONData;
```

The caller owns the returned node until it adds it to a JSON object or
array.

## Content blocks

`MCP.Content` builds the five content block types the 2026-07-28
revision defines for tool results and prompt messages. Each returns a
fresh `TJSONObject`; `MCPContentResult` and `MCPContentMessage` take
ownership of the blocks you pass them.

```pascal
function MCPTextContent(const AText: string): TJSONObject;
function MCPImageContent(const ABase64, AMimeType: string): TJSONObject;
function MCPImageContent(const AData: TBytes;
  const AMimeType: string): TJSONObject;
function MCPAudioContent(const ABase64, AMimeType: string): TJSONObject;
function MCPAudioContent(const AData: TBytes;
  const AMimeType: string): TJSONObject;
function MCPResourceLink(const AUri, AName: string;
  const AMimeType: string = ''; const ADescription: string = ''): TJSONObject;
function MCPEmbeddedText(const AUri, AMimeType, AText: string): TJSONObject;
function MCPEmbeddedBlob(const AUri, AMimeType, ABase64: string): TJSONObject;
function MCPEmbeddedBlob(const AUri, AMimeType: string;
  const AData: TBytes): TJSONObject;
function MCPBase64(const AData: TBytes): string;
```

| Builder | Wire shape |
| --- | --- |
| `MCPTextContent` | `{"type":"text","text":…}` |
| `MCPImageContent`, `MCPAudioContent` | `{"type":"image"` or `"audio","data":<base64>,"mimeType":…}` |
| `MCPResourceLink` | `{"type":"resource_link","uri":…,"name":…}`, plus `description` and `mimeType` when given |
| `MCPEmbeddedText`, `MCPEmbeddedBlob` | `{"type":"resource","resource":{"uri":…,"mimeType":…,"text"` or `"blob":…}}`; `mimeType` is left out when empty |

The string overloads take data that is already base64; the `TBytes`
overloads encode raw bytes themselves (`MCPBase64` exposes that
encoding). In a prompt message an embedded resource **must** carry its
MIME type, so pass one there; elsewhere `mimeType` is optional. A resource link need not name a resource your server lists
in `resources/list`. To add
[annotations](https://modelcontextprotocol.io/specification/2026-07-28/server/resources#annotations),
add an `annotations` member to the returned object before handing it
over.

## Resource contents

Resource readers return a `TJSONArray` of contents entries:

```pascal
function MCPTextContents(const AUri, AMimeType,
  AText: string): TJSONArray;
function MCPBlobContents(const AUri, AMimeType,
  ABase64: string): TJSONArray;
```

Each returns a single-entry array — text or base64-encoded binary —
echoing the URI the client asked for. See
[Resources](../guides/resources.md).

## Prompt messages

A prompt handler returns a `TJSONArray` of messages:

```pascal
function MCPPromptMessage(const ARole, AText: string): TJSONObject;
function MCPUserMessage(const AText: string): TJSONObject;
function MCPAssistantMessage(const AText: string): TJSONObject;
function MCPContentMessage(const ARole: string;
  AContent: TJSONObject): TJSONObject;
function MCPMessages(const AMessages: array of TJSONObject): TJSONArray;
```

`MCPContentMessage` carries any [content block](#content-blocks), such
as an image or an embedded resource, and takes ownership of it; the
text helpers are shorthand for it with `MCPTextContent`. `ARole` is
`user` or `assistant`, the two roles the specification defines.

### Content types and older clients

Audio blocks arrived in protocol revision 2025-03-26 and resource
links in 2025-06-18; the 2024-11-05 revision has text, image and
embedded resources only. A dual-era server can serve a client that
negotiated an older revision over stdio, and a client that validates
results against its own revision's schema may reject the newer block
types. When that matters, check `ACtx.ProtocolVersion` and fall back,
for example to a text block that names the resource.

The MRTR-capable prompt shape returns `TMCPPromptResult` instead;
wrap a message array with:

```pascal
function MCPPromptMessagesResult(AMessages: TJSONArray): TMCPPromptResult;
```

or answer an input round with `MCPPromptInputRequired` — see
[Client requests](client-requests.md). Guide:
[Prompts](../guides/prompts.md).

## In-request notifications

Emitted through the request context, written to the client before the
response; both are no-ops unless the request opted in:

```pascal
procedure MCPReportProgress(const ACtx: TMCPRequestContext;
  AProgress: Double; ATotal: Double = -1; const AMessage: string = '');
procedure MCPLogMessage(const ACtx: TMCPRequestContext;
  const ALevel, AData: string; const ALogger: string = '');
```

Levels are RFC 5424 (`debug` … `emergency`); gating and delivery are
described in
[Progress and logging](../guides/progress-and-logging.md).
