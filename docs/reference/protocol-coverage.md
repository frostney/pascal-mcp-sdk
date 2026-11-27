# Protocol Coverage

What the library implements of MCP spec revision `2026-07-28`,
surface by surface. This table is the authoritative coverage record;
the README links here.

| Surface | Status |
| --- | --- |
| `server/discover` | ✅ mandatory entry point, capabilities + instructions |
| `tools/list` | ✅ registered tool definitions in registration order (deterministic), whole or in pages (see Pagination) |
| `tools/call` | ✅ text / image / audio / resource-link / embedded-resource / structured content, in-band execution errors, server-side subset validation of arguments, structured output of any JSON type checked against a subset `outputSchema` |
| `resources/list`, `resources/read` | ✅ static + dynamic, text + blob builders |
| `resources/templates/list` + template matching | ✅ RFC 6570 level-1 (`{var}`), exact resources win, vars passed to readers |
| `prompts/list`, `prompts/get` | ✅ fluent argument declaration, message builders for every content type, spec error codes |
| `completion/complete` | ✅ prompt arguments and resource-template variables, from a static list (prefix match) or a handler with context arguments; `completions` capability declared when registered |
| MRTR `input_required` (SEP-2322) | ✅ on `tools/call` + `prompts/get`: elicitation (form + url), sampling, roots entry builders; capability-gated; stateless re-entry; `requestState` sealed by the server (HMAC-SHA-256, expiry, bound to the method, target, arguments and server) and verified before the handler runs |
| Cancellation | ✅ `notifications/cancelled` and, on Streamable HTTP, a closed or reset connection reach a running handler through `ACtx.IsCancelled`; nothing more is sent for a cancelled request. Covered by the stdio and HTTP transport suites and the `mcpsmoke` countdown check |
| Pagination | ✅ opt-in: `PageSize` pages all four list methods with opaque `nextCursor` tokens, and a cursor the server did not hand out for that list answers `-32602`; whole lists by default. Covered by the server suite and `mcpsmoke` (`mcpdemo --page-size 2` over stdio); the TypeScript batteries run `mcpdemo` unpaged |
| `notifications/progress`, `notifications/message` | ✅ `MCPReportProgress` / `MCPLogMessage` from any handler; strictly opt-in per request (`progressToken` / `logLevel`), severity-filtered, emitted before the response |
| `_meta` validation, version negotiation | ✅ `-32602` / `-32021` / `-32022` per spec |
| `ttlMs` / `cacheScope` caching hints (SEP-2549) | ✅ on discover/list/read, tunable via `CacheTtlMs`/`CacheScope` |
| stdio transport | ✅ newline-delimited, EOF shutdown contract |
| Streamable HTTP transport | ✅ `MCP.Transport.HTTP`: single POST endpoint, SSE response streams, mirrored-header validation (`Mcp-Name`, and `Mcp-Param-*` for `x-mcp-header` parameters), Origin allowlist |
| Classic handshake era (`initialize`: 2024-11-05, 2025-06-18, 2025-11-25) | ✅ dual-era default: era-faithful dialect (unstamped results, `-32002`, `ping`); `DualEra := False` for strict modern-only |
| `subscriptions/listen`, list-changed | ⏳ not implemented (registries are static after startup) |

Resource-template matching is intentionally limited to simple `{var}`
expressions. Variables must be non-empty and separated by literal
text; matching uses the complete following literal and may backtrack.
Captured values are passed to readers exactly as encoded in the URI —
percent-decoding is not performed.

## Verification

Spec facts verified against the official
[MCP specification](https://modelcontextprotocol.io/specification/2026-07-28)
(2026-07-20, re-verified 2026-08-08 against the published final
2026-07-28 text; the per-surface page links — stdio, tools,
resources, versioning, `server/discover` — are collected in the
architecture page's
[Spec grounding](../internals/architecture.md#spec-grounding)), and
the implemented surface **interop-tested against both
official MCP TypeScript clients**: the stable v2 client
(`@modelcontextprotocol/client` 2.0.0, pinned + auto-probe modes, over
stdio and Streamable HTTP, including MRTR auto-fulfilment) and the v1
SDK (`@modelcontextprotocol/sdk`, the handshake era Claude Code
speaks). Those batteries drive `mcpdemo`. The content types `mcpdemo`
does not return (audio, resource links, embedded resources, mixed
results and non-text prompt messages), and paging, which `mcpdemo`
leaves off by default, are covered by the unit suites,
the `mcpsmoke` content battery and the official conformance suite
against the conformance fixture. See
[tools/interop-ts/](../../tools/interop-ts/) and the
[architecture page](../internals/architecture.md#spec-grounding) for
the grounding notes.

Wire captures from 2026-08-10 show current clients still opening
with the classic handshake — Claude Code 2.1.226 with `2025-11-25`,
Codex 0.145.0 with `2025-06-18`; the transcripts are in
[Your first conversation](../guides/first-conversation.md).
