# Client Requests (MRTR)

The Multi Round-Trip Request surface: how a `tools/call` or
`prompts/get` handler asks the client for more input mid-call —
elicitation, sampling, roots — without the server keeping any
round-trip state between calls (your `requestState` travels via the
client; the transport's ordinary protocol session is unaffected).
The concept walkthrough is in
[Tools](../guides/tools.md#asking-the-client-for-more-input-mrtr);
this page is the API.

## Answering input_required

```pascal
function MCPInputRequired(AInputRequests: TJSONObject;
  const ARequestState: string = ''): TMCPToolResult;
function MCPPromptInputRequired(AInputRequests: TJSONObject;
  const ARequestState: string = ''): TMCPPromptResult;
```

`AInputRequests` maps your keys to request entries (built below);
the client fulfils them and retries the original call with the
responses. `ARequestState` is your round-trip state. The server seals
it before it leaves (HMAC-SHA-256 over the state, an expiry, the method,
the tool or prompt name, a digest of the arguments and the server's
name) and verifies the client's echo before your handler runs again:
a token that was altered, has expired, or comes back on another tool,
prompt or argument set is answered `-32602`, and the handler never
sees it. On re-entry `ACtx.RequestState` is your own string again.
The client can still read the state, so keep secrets out of it; key
and lifetime settings are in
[Configuration](../guides/configuration.md#requeststate-sealing).

## Request entry builders

One builder per request kind:

```pascal
// Elicitation: a form the client renders...
function MCPElicitFormRequest(const AMessage: string;
  ARequestedSchema: TJSONObject): TJSONObject;
function MCPElicitFormRequest(const AMessage: string;
  constref ASchema: TMCPSchema): TJSONObject;

// ...or a URL the client sends the user to
function MCPElicitURLRequest(const AMessage, AUrl: string): TJSONObject;

// Sampling: ask the client's model for a completion
function MCPSamplingRequest(ASamplingParams: TJSONObject): TJSONObject;
function MCPSamplingTextRequest(const APrompt: string;
  AMaxTokens: Integer): TJSONObject;

// Roots: ask for the client's filesystem roots
function MCPRootsRequest: TJSONObject;
```

The form-request schema uses the same builders as tool schemas
(`ObjectSchema...` or a raw `TJSONObject`). `MCPSamplingTextRequest`
is the one-prompt convenience over `MCPSamplingRequest`'s full
params object.

Each kind is gated on the per-request client capabilities: requesting
a kind the client did not declare answers `-32021` instead of
reaching the client.

## Reading the responses on re-entry

On the retry, the responses are exposed on the request context:

```pascal
function MCPInputResponse(const ACtx: TMCPRequestContext;
  const AKey: string): TJSONObject;
function MCPElicitationContent(const ACtx: TMCPRequestContext;
  const AKey: string): TJSONObject;
```

`MCPInputResponse` returns the raw response entry for your key (`nil`
when this is not a retry or the key is absent) — the pattern for
distinguishing round 1 from round 2. `MCPElicitationContent` goes one
step further for elicitation entries, returning the accepted form
content directly. The raw payload is also available as
`ACtx.InputResponses` / `ACtx.RequestState`.

## Era and capability notes

MRTR is modern-era (`2026-07-28`) only — a classic-handshake client calling
an MRTR-answering tool or prompt receives a JSON-RPC error naming the
limitation. Sampling and roots are deprecated in the final spec
(SEP-2577) but deliberately carried; prefer elicitation where either
would do. Spec grounding and interop evidence:
[Architecture](../internals/architecture.md#registration-and-handler-model).
