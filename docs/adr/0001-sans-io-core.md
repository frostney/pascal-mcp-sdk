# Sans-I/O core with transports as thin shells

One transport-agnostic core (`MCP.Server` over `MCP.Protocol` and
`MCP.JSONRPC`) owns all protocol semantics and performs no I/O —
`HandleMessage` maps one line in to at most one line out. Transports
(`MCP.Transport.Stdio`, `MCP.Transport.HTTP`) own only their wire
profile — framing, status and header mapping, connection lifecycle —
and never re-decide a protocol rule. This is the discipline proven in
duetto's `WS.Protocol`: the alternative (protocol logic living in each
transport) makes every new binding a re-implementation to re-test,
while the sans-I/O shape lets unit tests drive the full protocol
surface with no pipes or processes and lets both bindings wrap the
same tested core unchanged.

## Consequences

- A new transport is a framing exercise, not a protocol project.
- The core stays synchronous and line-oriented; anything needing
  mid-request I/O (like the per-call notification sink) enters as an
  explicit argument, never as retained transport state.
- If a change seems to need protocol knowledge inside a transport,
  the change is wrong, not the boundary.
