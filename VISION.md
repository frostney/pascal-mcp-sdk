# Vision

## Mission

pascal-mcp-sdk is the first FreePascal-native library for the Model Context
Protocol: a dependency-light, cross-platform MCP **server** toolkit that
lets any Pascal program expose tools and resources to AI agents without
adopting a second language runtime. The library targets the current
**stateless** protocol revision (2026-07-28) — every existing Object
Pascal MCP project is Delphi-locked, framework-heavy, and built on the
superseded session-based revisions; pascal-mcp-sdk exists to close that gap
cleanly rather than port it.

## Product direction

One transport-agnostic core owns protocol semantics and performs no
I/O; transports are thin bindings around it — **stdio** (pure RTL —
v1, complete) and **Streamable HTTP** (fcl-web confined to the
transport unit). The architectural reasoning is recorded in
[ADR-0001 (sans-I/O core)](docs/adr/0001-sans-io-core.md) and
[ADR-0003 (zero third-party runtime dependencies)](docs/adr/0003-zero-third-party-runtime-dependencies.md).

Cross-platform coverage (Linux, macOS, Windows) and embeddability (a
library that compiles into the host binary via lwpt, with zero
third-party runtime dependencies — RTL + fpjson only) are givens of
being a serious library, not goals.

pascal-mcp-sdk is a member of the lwpt ecosystem: built, tested, formatted,
and released through lwpt; consumable by any lwpt project as a
dependency, or by plain `fpc @lwpt.cfg` with no lwpt installed at all.
lantaarn is its first named consumer, mirroring duetto → lantaarn.

## Not-goals

- **No MCP client.** v1 is a server library; a client (for Pascal
  programs that drive other MCP servers) is a separate decision.
- **Legacy is compatibility, not a second implementation.** The
  server is dual-era by default so today's clients work, but legacy
  support stays a thin dialect layer over the one modern core and
  sunsets when the ecosystem's clients finish migrating — see
  [ADR-0002](docs/adr/0002-dual-era-legacy-as-thin-dialect.md).
- **No general JSON-Schema validation engine.** The subset the
  library emits is server-enforced; `.ApplicationValidated` hands
  deeper validation back to the handler — see
  [ADR-0004](docs/adr/0004-schema-validation-boundary.md).
- **No framework ambitions.** pascal-mcp-sdk registers tools and moves
  messages; logging policy, auth, and application state belong to the
  host program.
