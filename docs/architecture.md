# Architecture

## Executive Summary

pascal-mcp-sdk is four units layered strictly bottom-up: `MCP.JSONRPC`
(the JSON-RPC 2.0 profile MCP mandates), `MCP.Protocol` (the stateless
per-request `_meta` model of spec revision 2026-07-28), `MCP.Server`
(the sans-I/O dispatch core holding the tool/resource registries), and
`MCP.Transport.Stdio` (the newline-delimited stdio binding). The core
performs no I/O — `HandleMessage` maps one inbound line to at most one
response line — so the planned Streamable HTTP binding wraps the same
tested core without touching it. The runtime dependency set is FPC's
RTL + fpjson, nothing else.

## Layering

```text
MCP.Transport.Stdio      thin shell: lines in/out, LF framing, EOF = shutdown
        │
MCP.Server               dispatch + registries; HandleMessage(line) → line
        │
MCP.Protocol             _meta validation, version negotiation, result stamping
        │
MCP.JSONRPC              JSON-RPC 2.0 parse/build, MCP profile + error codes
        │
RTL + fpjson             the only runtime dependencies
```

Rules live in the layer that owns them and nowhere else:

- **`MCP.JSONRPC`** — message classification (request / notification /
  invalid), MCP's tightened id rules (string or number, never null),
  batch rejection, params-must-be-object, id preservation into error
  replies, compact single-line serialization. Knows nothing about MCP
  methods.
- **`MCP.Protocol`** — the reserved `_meta` keys, the two required
  per-request fields (`protocolVersion`, `clientCapabilities`),
  `-32602` for their absence, `-32022` (+ `supported` list) for version
  mismatch, and the response-side stamping (`resultType: "complete"`,
  `serverInfo`). Knows nothing about tools or resources.
- **`MCP.Server`** — method dispatch (`server/discover`, `tools/*`,
  `resources/*`), the registries, in-band vs. protocol error policy
  (handler exceptions → `isError: true` results; dispatch faults →
  JSON-RPC errors), the legacy-`initialize` rejection that names
  supported versions. Knows nothing about bytes or streams.
- **`MCP.Transport.Stdio`** — LF-terminated writes on every platform,
  CR tolerance on reads, blank-line skipping, stderr-only logging, EOF
  as the graceful-shutdown signal. Contains not a single protocol
  decision.

## The sans-I/O core

`TMCPServer.HandleMessage(const ALine; out AResponse): Boolean` is the
entire protocol surface. It is what the unit tests drive (no pipes, no
processes), what `RunMCPStdioLoop` calls in a loop, and what
`MCP.Transport.Http` will call per POST body when it lands. This
mirrors duetto's `WS.Protocol` discipline: one tested core, transports
as delivery.

Because the 2026-07-28 revision is **stateless** — servers must not
infer anything from prior requests on the same connection — the serial
read-handle-write loop is not a simplification but the spec's own
model: every request re-validates its `_meta`, and process/connection
identity carries no session meaning. This is also why ignoring
`notifications/cancelled` is correct: requests are handled one at a
time, so a cancellation can only arrive after its target completed.

## Registration and handler model

Registries are populated at startup and fixed afterwards (that is why
no `listChanged`/`subscribe` capability is advertised and
`subscriptions/listen` is out of v1). Handlers are synchronous and come
in two shapes per registry — plain function pointers and `of object`
method pointers — so both programs and class-based hosts (lantaarn)
register naturally. Tool schemas are built with the fluent
`MCP.Schema` API (`ObjectSchema.AddString(...)...` — a JSON Schema
2020-12 subset covering the flat object schemas most tools need, with
input and output schema overloads); richer schemas use the JSON-string
or definition-object overloads, parsed for well-formedness at
registration (`EMCPServer` on error). Argument validation beyond that
is the handler's job, reported as in-band `isError` results that a
model can read and correct against.

## Spec grounding

Verified 2026-07-20 against the official spec (modelcontextprotocol.io):

- The **current ratified** revision is `2025-11-25`
  ([versioning](https://modelcontextprotocol.io/specification/versioning)).
- **`2026-07-28` is the locked release candidate** (locked 2026-05-21;
  final ships July 28, 2026 —
  [release post](https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/)).
  It removes the `initialize` handshake, protocol-level sessions, the
  `Mcp-Session-Id` header, and the GET SSE stream; server→client
  requests are replaced by Multi Round-Trip Requests.
- This library implements `2026-07-28` from its **draft spec pages**,
  which carry the RC content:
  [transports overview](https://modelcontextprotocol.io/specification/draft/basic/transports),
  [stdio binding](https://modelcontextprotocol.io/specification/draft/basic/transports/stdio),
  [`_meta` + error codes](https://modelcontextprotocol.io/specification/draft/basic/index),
  [versioning](https://modelcontextprotocol.io/specification/draft/basic/versioning),
  [server/discover](https://modelcontextprotocol.io/specification/draft/server/discover),
  [tools](https://modelcontextprotocol.io/specification/draft/server/tools),
  [resources](https://modelcontextprotocol.io/specification/draft/server/resources).
- When the final `2026-07-28` text publishes, re-verify the implemented
  surface against it; any drift from the RC is a `fix(protocol)`.
- **The prose pages are not the whole truth — the schema anchor is.**
  Interop against the official TypeScript client beta
  (`@modelcontextprotocol/client` 2.0.0-beta.4, via
  `tools/interop-ts/`) surfaced two requirements the prose pages
  underplay: `DiscoverResult` requires a **top-level `serverInfo`**
  field (the `_meta` stamp alone reads as a legacy server to the
  probe), and `ttlMs` + `cacheScope` (SEP-2549 CacheableResult) are
  **required** on discover/list/read results. Both are implemented and
  pinned by unit tests, `mcpsmoke`, and the interop battery. Protocol
  claims should be checked against the
  [schema](https://github.com/modelcontextprotocol/specification/blob/main/schema/draft/schema.ts)
  and a real RC implementation, not prose alone.

pascal-mcp-sdk is a **dual-era server** (spec's compatibility matrix, on
by default): era selection follows how the client opens. A request
carrying the modern per-request `_meta` protocol-version key is served
statelessly per 2026-07-28; an `initialize` request selects legacy
semantics (2024-11-05…2025-11-25), scoped to the server instance (=
the stdio process) — the one deliberate piece of cross-request state
the compatibility model prescribes. Both eras run concurrently on the
same instance; handlers are era-blind (`TMCPRequestContext` is filled
from `_meta` or from the stored handshake). The legacy dialect is
era-faithful at the edges: no `resultType`/`serverInfo` stamps, no
SEP-2549 cache fields, resource-not-found `-32002`, and `ping`
answered. `DualEra := False` restores strict modern-only behavior
(initialize rejected with a diagnostic naming supported versions, as
the spec recommends). Proven end-to-end by `tools/interop-ts`: the v2
RC beta client negotiates modern (auto-probe included), the v1 SDK
client (Claude Code's library) completes the classic handshake, and
Claude Code itself connects via `claude mcp add`.

## The HTTP follow-up

`MCP.Transport.Http` (Streamable HTTP: JSON-RPC per POST, SSE response
streams, `Mcp-Method`/`Mcp-Name` header mirroring) is deliberately not
in v1. Default server primitive when it lands: FPC's `fphttpserver`
(fcl-web, ships with FPC, cross-platform); fallback is a minimal
hand-rolled HTTP/1.1 server if avoiding fcl-web matters. lwpt
httpclient's `TransportSecurity` (server-side TLS) and `StringBuffer`
are reusable building blocks. The decision on the exact primitive is
made at that milestone, not now.
