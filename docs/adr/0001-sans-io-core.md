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

## Amendment (2026-11-27, #89)

One read happens in the core: with no `requestState` keys set, the
first `CreateSession` reads 32 bytes of operating-system entropy for
the instance's sealing key. It happens once, at the freeze boundary,
never while a request is handled, and a server configured with
`SetRequestStateKeys` performs none. Making the key lazily on the
first seal was rejected: the frozen server is shared across the HTTP
binding's threads, so lazy creation would need a lock in the
dispatch path.

## Amendment (2026-11-27, #93)

One hook outlives a call: a transport installs a cancellation poll on
its session (`TMCPSession.SetCancellationPoll`) with borrowed user
data, and the session keeps it across that connection's requests. The
core calls it only while one of the session's requests runs, on the
handler's thread, when the handler asks `IsCancelled` or a
notification is due. Passing the poll with each `HandleMessage` call
was rejected: the poll belongs to the connection (stdio's input
reader, HTTP's socket) rather than to one request, and every
transport would have to pass the same pair on every call to keep the
core from holding it. The session holds no other transport state.

## Amendment (2026-11-27, #126)

A second hook lives on the session: the transport's stream host
(`TMCPSession.StreamHost`), which the core hands to each 2026-07-28
handler as `ACtx.StreamHost`. A handler for a request that outlives
its call, such as the Events extension's `events/stream`, parks a
`TMCPStream` there and returns a placeholder result, which the
transport drops. The stream writes its own frames, built by the
extension, and the transport only decides when to step it and how a
frame travels: an SSE event in the HTTP request's thread, or a line
between other lines in the stdio loop. A core that drove streams
itself would need a clock and a thread, and changing `HandleMessage`
to return a stream was rejected: `MCP.Server` sits at its complexity
ceiling, and the two assignments that pass the host and the request id
keep the core's dispatch unchanged.
