# Troubleshooting

The failure modes everyone hits once, and what they mean.

## The client shows the server as disconnected or failing

Under stdio the usual causes, in order of likelihood:

- **Something wrote to stdout.** stdout belongs to the protocol; one
  stray `WriteLn` corrupts the stream and the client gives up. Route
  every diagnostic through `MCPLogToStderr` — including startup
  banners and third-party code output.
- **The configured path is wrong.** Clients rarely share your shell's
  PATH — register the binary's **absolute path**. `claude mcp list`
  shows connection state; most clients also capture the server's
  stderr in their logs, which is where your `MCPLogToStderr` output
  and any startup crash land.
- **The process exited at startup** — a registration error raises
  `EMCPServer` before serving begins (see below).

## `-32602: ... _meta ...` on every request

Modern (`2026-07-28`) requests are stateless: **every** request must
carry `_meta` with `io.modelcontextprotocol/protocolVersion` and
`io.modelcontextprotocol/clientCapabilities` in its `params`. When
driving a server by hand, copy the shape from the
[quick start](quick-start.md#talk-to-a-stdio-server-by-hand). Real
clients do this for you. Over HTTP the same rule holds — the mirrored
`Mcp-*` headers never substitute for `_meta` in the body.

## `-32022: unsupported protocol version`

The client asked for a protocol revision the server does not speak;
the error's data lists `supported` versions. A client speaking
`2025-03-26` hits this — that revision requires JSON-RPC batch
support the library deliberately omits (see
[Spec grounding](../internals/architecture.md#spec-grounding)); the
adjacent `2024-11-05`, `2025-06-18` (Codex today), and `2025-11-25`
(Claude Code today) all work via the dual-era default.

## `EMCPServer` at startup

Registration and configuration problems fail fast, before serving:

- *"...uses unsupported schema keyword..."* — a raw schema went
  beyond the [enforced subset](schemas.md#the-enforced-subset).
  Narrow the schema or mark the registration `.ApplicationValidated`.
- *"Server configuration is frozen after session creation"* — a
  `Register*` call or property write after serving started. Register
  and configure everything first, then serve.
- Malformed raw schema JSON, empty names, duplicate registrations —
  the message names the offender.

## HTTP: request rejected with 403

The Origin allowlist (DNS-rebinding defense). Localhost origins and
origin-less requests always pass; anything else needs an exact-match
entry in `AllowedOrigins`. A browser front-end on another origin —
or a reverse proxy that forwards the browser's `Origin` — needs its
origin added deliberately.

## HTTP: `Run` never returns / server won't exit

By design: `Run` blocks until `Stop` is called from another thread
(for example from a signal handler). Under stdio, shutdown is the
client's job — closing stdin ends `RunMCPStdioServer`.

## Unix + HTTP: runtime error about threads

The HTTP binding needs the threading RTL. `cthreads` must be the
**first** unit in your *program's* uses clause:

```pascal
uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  ...;
```

A library unit cannot do this for you — FPC requires the thread
driver first in the program.

## Oversized requests

Both transports cap inbound size at 4 MiB by default: the stdio line
cap (`AMaxLineLength` parameter of `RunMCPStdioServer`) answers a
compliant JSON-RPC error and drops the rest of the line; the HTTP
binding (`MaxBodyBytes` property) answers `413`. Raise the caps
deliberately if your tools legitimately take bigger payloads.

## Still stuck?

Drive the server by hand with the
[heredoc session](quick-start.md#talk-to-a-stdio-server-by-hand) —
two lines of shell reproduce most protocol-level problems without any
client in the way. If the behaviour contradicts the spec, that is a
bug: [open an issue](https://github.com/frostney/pascal-mcp-sdk/issues).
