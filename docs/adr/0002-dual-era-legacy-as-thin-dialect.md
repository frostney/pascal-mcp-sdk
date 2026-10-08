# Legacy protocol support is a thin dialect, not a second implementation

The library targets the stateless 2026-07-28 revision, but ships
dual-era by default so today's clients (Claude Code, Claude Desktop)
work: the legacy `initialize` handshake (2024-11-05, 2025-06-18,
2025-11-25) is answered as a **dialect layer** over the one modern
core — same registries, same handlers, same dispatch, with era-specific
stamps and error codes at the edges only. The rejected alternative was
a faithful second implementation of the session-based revisions, which
is exactly the Delphi-locked, framework-heavy shape this project
exists to avoid.

## Consequences

- Legacy-only features the modern revision removed (server-initiated
  requests, subscriptions, `setLevel`) are **not implemented**.
- `2025-03-26` is excluded: its Base Protocol requires accepting
  JSON-RPC batches, which the library does not implement (verified
  2026-07-20).
- Handlers are era-blind; era-awareness lives in stamps and error
  codes at the edges, so the dialect can sunset by deletion when the
  ecosystem's clients finish migrating.
