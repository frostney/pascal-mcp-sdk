# Shipping Your Server

## Executive Summary

A server built with pascal-mcp-sdk deploys as a single native binary
per platform: build in release mode, ship the executable, register its
absolute path in the MCP client's server configuration. There is no
runtime and no config file. Under stdio — the default and primary
deployment story, and everything this page describes unless stated
otherwise — there is no network listener either: the client launches
the process and owns its lifetime via stdin. The exception is the
Streamable HTTP binding (`TMCPHTTPServer`), which does open a listener
and runs as a long-lived process; see
[Deploying the HTTP binding](#deploying-the-http-binding).

## Building for release

In an lwpt project:

```sh
lwpt build --mode release
```

Release mode compiles with `-O4 -dPRODUCTION -Xs -CX -XX`. Without
lwpt, pass the flags to FPC yourself:

```sh
fpc -dPRODUCTION -O3 -XX -CX -Fu<units-path> -Fi<units-path> -FEbuild myserver.pas
```

`-dPRODUCTION` flips the library's `Shared.inc` from checked
(range/overflow/assert on) to optimised (checks off, auto-inlining).
`-XX -CX` smart-links the binary down. Cross-compilation follows
standard FPC practice.

## Runtime contract

- **The client owns the process.** It launches the binary, writes
  requests to stdin, reads responses from stdout, and closes stdin to
  shut it down. A pascal-mcp-sdk server exits promptly on EOF — do not
  wrap it in a restart loop that fights the client's lifecycle
  (clients restart stateless servers themselves).
- **stdout is sacred.** Only MCP messages. Anything a server wants to
  say goes to stderr (`MCPLogToStderr`); clients may capture, forward,
  or ignore it.
- **State is explicit.** The protocol is stateless: the process may be
  killed and relaunched between any two requests. State that must
  survive belongs behind explicit handles in tool arguments/results
  (see the spec's "Stateful Tools" guidance), backed by files or a
  store the binary reaches on its own.
- **Credentials come from the environment.** The stdio transport does
  not use the HTTP authorization framework; pass secrets via the
  client's `env` block for the server entry, per spec guidance. The
  HTTP binding does not implement that framework either — the library
  ships no authentication, so anything beyond a loopback listener is
  the operator's job (see below).

## Client registration

```json
{
  "mcpServers": {
    "my-server": {
      "command": "/opt/my-server/bin/my-server",
      "env": { "MY_SERVER_TOKEN": "..." }
    }
  }
}
```

Use absolute paths; clients rarely share your shell's PATH. One binary
can back any number of client entries — each launch is an independent
process with independent (non-)state.

## Deploying the HTTP binding

A server that serves its registrations over Streamable HTTP
(`TMCPHTTPServer`) is the one deployment that opens a socket. The same
binary and the same release build apply; what changes is that the
operator, not the client, owns the process lifetime — `Run` blocks
until `Stop` is called from another thread.

- **Loopback by default.** The listener binds `127.0.0.1`; widen it
  deliberately via the `Address` property. The endpoint is a single
  POST path, `/mcp` by default (`EndpointPath`).
- **Origin allowlist.** The `Origin` header, when present, must pass
  the allowlist or the request is rejected — a DNS-rebinding defense.
  The default allowlist accepts localhost origins only; add further
  origins as exact-match strings via `AllowedOrigins`.
- **No TLS, no authentication.** The library ships neither. A listener
  widened beyond loopback needs a reverse proxy or a tunnel in front
  of it, and that is the operator's job.
- **Body size cap.** Inbound bodies are capped at 4 MiB by default
  (`MaxBodyBytes`), the same budget as the stdio line cap.
- **Modern era only.** This binding turns dual-era support off: it
  serves `2026-07-28` requests statelessly and rejects an
  `initialize` handshake with the version diagnostic. Clients that
  speak the classic handshake keep using stdio.

The runtime contract above still holds otherwise: state is explicit,
diagnostics go to stderr, and secrets come from the environment.

## Library versioning

The library follows semver (lwpt package versions and git tags), so
`lwpt add frostney/pascal-mcp-sdk@^2.0` keeps you on compatible
releases. Adopting a newer MCP protocol revision is a minor version at
most as long as `supportedVersions` still contains everything
previously advertised; dropping a revision is breaking. The release
process itself is described in
[Releasing](../internals/releasing.md).
