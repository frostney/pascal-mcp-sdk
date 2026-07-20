# Vision

## Mission

pascal-mcp is the first FreePascal-native library for the Model Context
Protocol: a dependency-light, cross-platform MCP **server** toolkit that
lets any Pascal program expose tools and resources to AI agents without
adopting a second language runtime. The library targets the current
**stateless** protocol revision (2026-07-28) — every existing Object
Pascal MCP project is Delphi-locked, framework-heavy, and built on the
superseded session-based revisions; pascal-mcp exists to close that gap
cleanly rather than port it.

## Product direction

One transport-agnostic core (`MCP.Server` over `MCP.Protocol` and
`MCP.JsonRpc`) owns every protocol rule and performs no I/O. Transports
are thin bindings around it: **stdio** (newline-delimited JSON-RPC, pure
RTL — v1, complete) and, as an explicit follow-up, **Streamable HTTP**
(`MCP.Transport.Http`). The same tested core sits behind every binding
unchanged — the sans-I/O discipline proven in duetto.

Cross-platform coverage (Linux, macOS, Windows) and embeddability (a
library that compiles into the host binary via lwpt, with zero
third-party runtime dependencies — RTL + fpjson only) are givens of
being a serious library, not goals.

pascal-mcp is a member of the lwpt ecosystem: built, tested, formatted,
and released through lwpt; consumable by any lwpt project as a
dependency, or by plain `fpc @lwpt.cfg` with no lwpt installed at all.
lantaarn is its first named consumer, mirroring duetto → lantaarn.

## Not-goals

- **No MCP client.** v1 is a server library; a client (for Pascal
  programs that drive other MCP servers) is a separate decision.
- **Legacy is compatibility, not a second implementation.** The server
  is dual-era by default — the initialize handshake (2025-11-25 and
  earlier) is answered so today's clients (Claude Code, Claude
  Desktop) work — but legacy support stays a thin dialect layer over
  the one modern core: the same registries, handlers, and dispatch,
  with era-specific stamps and error codes at the edges. Legacy-only
  features that the modern revision removed (server-initiated
  requests, subscriptions, setLevel) are not implemented, and the
  legacy dialect sunsets when the ecosystem's clients finish
  migrating.
- **No JSON-Schema validation engine.** Tool handlers validate their own
  arguments and report problems as in-band `isError` results; shipping a
  schema validator is out of scope for a dependency-light library.
- **No framework ambitions.** pascal-mcp registers tools and moves
  messages; logging policy, auth, and application state belong to the
  host program.
