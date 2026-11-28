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
| MRTR `input_required` (SEP-2322) | ✅ on `tools/call` + `prompts/get`: elicitation (form + url), sampling, roots entry builders (sampling and roots are deprecated in `2026-07-28`, SEP-2577); capability-gated, including the elicitation mode and `sampling.tools`; stateless re-entry; `requestState` sealed by the server (HMAC-SHA-256, expiry, bound to the method, target, arguments and server) and verified before the handler runs |
| Cancellation | ✅ `notifications/cancelled` and, on Streamable HTTP, a closed or reset connection reach a running handler through `ACtx.IsCancelled`; nothing more is sent for a cancelled request. Covered by the stdio and HTTP transport suites and the `mcpsmoke` countdown check |
| Pagination | ✅ opt-in: `PageSize` pages the four core list methods, and `skills/list` and `resources/directory/read` from `MCP.Skills` (covered by the Skills suite's paging tests), with opaque `nextCursor` tokens (caching fields on every modern page), and a cursor that is not one of that list's page cursors answers `-32602`; whole lists by default. Covered by the server suite and `mcpsmoke` (`mcpdemo --page-size 2` over stdio); the TypeScript batteries run `mcpdemo` unpaged |
| Extensions | ✅ `capabilities.extensions` declared on opt-in (`DeclareExtension`); client declarations readable per request |
| MCP Apps (`io.modelcontextprotocol/ui`) | ✅ `MCP.Apps`: `ui://` HTML resources with `_meta.ui` (CSP, permissions, domain, border), tool links with visibility, startup check of links |
| Skills (`io.modelcontextprotocol/skills`) | ✅ `MCP.Skills`: skills defined in code as `skill://` resources, `skills/list` (paged), `skills/get`, `resources/directory/read`, SHA-256 digests and sizes, nested skills, the Agent Skills name and field rules; skills loaded from a directory, their frontmatter read with a YAML subset YAML 1.1 and 1.2 parsers agree on |
| Events (`io.modelcontextprotocol/events`) | ✅ `MCP.Events`: event types with input and payload schemas, `events/list` (paged), poll delivery (`events/poll`) with cursors, `maxEvents`/`hasMore`, truncation and types without replay, derived event ids, the SEP-3415 error codes, `Mcp-Name`/`Mcp-Param-*` on Streamable HTTP; push delivery (`events/stream`) from the same check, one occurrence per call: active, event, heartbeat, error and terminated notifications and the final frame, an SSE stream on Streamable HTTP, streams multiplexed in the single-threaded stdio loop and cancelled with `notifications/cancelled`; 2026-07-28 only. Webhooks and `list_changed`: not served |
| `notifications/progress`, `notifications/message` | ✅ `MCPReportProgress` / `MCPLogMessage` from any handler; strictly opt-in per request (`progressToken` / `logLevel`), severity-filtered, emitted before the response. Logging is deprecated in `2026-07-28` (SEP-2577) |
| `_meta` validation, version negotiation | ✅ `-32602` / `-32021` / `-32022` per spec |
| `ttlMs` / `cacheScope` caching hints (SEP-2549) | ✅ on discover/list/read, tunable via `CacheTtlMs`/`CacheScope` |
| stdio transport | ✅ newline-delimited, EOF shutdown contract |
| Streamable HTTP transport | ✅ `MCP.Transport.HTTP`: single POST endpoint, SSE response streams, mirrored-header validation (`Mcp-Name`, and `Mcp-Param-*` for `x-mcp-header` parameters), Origin allowlist |
| Classic handshake era (`initialize`: 2024-11-05, 2025-06-18, 2025-11-25) | ✅ dual-era default on stdio: era-faithful dialect (unstamped results, `-32002`, `ping`); `DualEra := False` for strict modern-only. The Streamable HTTP binding is modern-only |
| Tasks (`io.modelcontextprotocol/tasks`) | ✅ `MCP.Tasks`: server-directed task creation per tool (`tsOptional`, `tsRequired`) or per call (a selector), only for requests that declare the extension (`-32021` for a required one otherwise); a flat `CreateTaskResult`, readable before it is sent; `tasks/get` with the result, the JSON-RPC error or the open input requests inlined; input rounds answered with `tasks/update`, partial answers kept, keys unique over the task's lifetime; `tasks/cancel`; `ttlMs`, `pollIntervalMs`, limits on running and kept tasks; each handler on a thread of its own; `Mcp-Name` routing on Streamable HTTP; `notifications/tasks` on `subscriptions/listen` for the listed `taskIds` (`-32021` without the extension), each task's whole state after each change; 2026-07-28 only |
| `subscriptions/listen` | ✅ `MCP.Subscriptions`, once an extension offers notifications (the Tasks extension's `taskIds`): the acknowledgment first with the agreed filter, `io.modelcontextprotocol/subscriptionId` on every frame, an SSE stream on Streamable HTTP, streams multiplexed in the stdio loop and cancelled with `notifications/cancelled`, and the completion result when the transport ends the stream; 2026-07-28 only. List changes and resource subscriptions are never agreed to, since the registries are static after startup. In the conformance baseline `tasks-status-notifications` is an expected skip ([#139](https://github.com/frostney/pascal-mcp-sdk/issues/139)): the suite skips it until its harness reads this stream |
| Authorization (OAuth 2.1 for HTTP transports) | ⏳ not in the library, deliberately: beyond loopback the operator must put authentication in front of the Streamable HTTP binding, for example in a reverse proxy; a platform's edge terminates TLS but authenticates nothing by itself (see [Deployment](../guides/deployment.md#tls-auth-and-the-proxy-in-front)) |

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
the core protocol surface **interop-tested against both
official MCP TypeScript clients**: the stable v2 client
(`@modelcontextprotocol/client` 2.0.0, pinned + auto-probe modes, over
stdio and Streamable HTTP, including MRTR auto-fulfilment) and the v1
SDK (`@modelcontextprotocol/sdk`, the classic handshake era). Those batteries drive `mcpdemo`. The content types `mcpdemo`
does not return (audio, resource links, embedded resources, mixed
results and non-text prompt messages) are covered by the unit suites,
the `mcpsmoke` content battery and the official conformance suite
against the conformance fixture. See
[tools/interop-ts/](../../tools/interop-ts/) and the
[architecture page](../internals/architecture.md#spec-grounding) for
the grounding notes.
Paging, which `mcpdemo` leaves off by default, is covered by the server
unit suite and the `mcpsmoke` pagination battery, which runs
`mcpdemo --page-size 2` over stdio.
The TypeScript batteries exercise the transports and the core protocol;
they assert neither extension negotiation, MCP Apps nor Skills.
Skills is covered by the `MCP.Skills` unit suite, with digests computed
outside Pascal, and by `mcpsmoke`, which reads `mcpdemo`'s skill back
over stdio and checks its digest and size, and does the same for a
skill `mcpdemo --skills-dir` loads from disk. The `MCP.Frontmatter`
suite's expectations are what PyYAML (YAML 1.1) and the `yaml` package
(YAML 1.2) read from the same text. Events is covered by the `MCP.Events` unit suite, poll and push
(each notification's exact line, gaps, cancellation in a running check,
the replay floor and the schedule on a test clock), the HTTP binding
suite for the routing headers, the SSE stream, a client close and
`Stop`, the stdio loop suite for streams beside requests, cancellation,
the end of input and an idle stdin, and `mcpsmoke`, which polls
`mcpdemo`'s minute clock over stdio and streams it over real pipes.
Tasks is covered by the `MCP.Tasks` unit suite (creation, completion,
tool and protocol errors, input rounds with partial answers and reused
keys, the capability gate, cancellation, the errors, the limits, a
non-ASCII result on the wire and teardown while tasks run), by the
official conformance suite's nine `tasks-*` scenarios that run against
the conformance fixture over Streamable HTTP, routing headers
included, and by `mcpsmoke`, which creates, polls, answers and cancels
tasks of the fixture over stdio and ends its input while one runs.
MCP Apps and extension negotiation are covered by the `MCP.Apps` unit
suite and the `mcpsmoke` checks of `mcpdemo`'s card over stdio: the
wire data and the served HTML. No host renders the card in these
checks.

Wire captures over stdio from 2026-11-27 show Claude Code 2.1.332
opening with `server/discover` and sending every request at
`2026-07-28`, and Codex 0.171.0 still opening with the classic
`initialize` at `2025-06-18`. Captures from 2026-08-10 show Claude Code
2.1.226 with `2025-11-25` and Codex 0.145.0 with `2025-06-18`.
[Your first conversation](../guides/first-conversation.md) shows the
November Claude Code session and Codex `initialize`.
