# Results and Content

The helpers handlers build their answers with, all from `MCP.Server`.

## Tool results

A tool handler returns `TMCPToolResult`; build it with one of:

```pascal
function MCPTextResult(const AText: string): TMCPToolResult;
function MCPErrorResult(const AText: string): TMCPToolResult;
function MCPStructuredResult(const AText: string;
  AStructured: TJSONData): TMCPToolResult;
function MCPStructuredResult(const AText: string;
  AObj: TMCPArgs): TMCPToolResult;
```

- `MCPTextResult` — one text content block.
- `MCPErrorResult` — the same shape with `isError: true`: the in-band
  error channel a model reads and corrects against. Use it for
  everything the *caller* did wrong; reserve exceptions for what went
  wrong *in the server* (they become `isError` results too, with
  messages subject to
  [redaction](../guides/configuration.md#redacterrordetails)).
- `MCPStructuredResult` — text plus `structuredContent`. The
  `TJSONData` overload takes ownership of the data you pass; the
  `TMCPArgs` overload serializes an instance of a typed output class
  **and frees it** (see
  [Schemas](../guides/schemas.md#typed-argument-classes)).

The MRTR variant `MCPInputRequired` is documented with the other
client-request builders in [Client requests](client-requests.md).

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
function MCPMessages(const AMessages: array of TJSONObject): TJSONArray;
```

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
