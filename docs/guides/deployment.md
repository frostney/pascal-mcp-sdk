# Deploying the HTTP Binding

## Executive Summary

A stdio server never deploys anywhere — the MCP client launches the
binary on the user's machine and owns its lifetime
([Shipping your server](shipping.md) covers that story). Deployment
enters the picture with the Streamable HTTP binding
(`TMCPHTTPServer`): a long-lived native process serving POST + SSE on
one endpoint. Because the binary is self-contained and the modern
protocol revision is stateless, the deployment story is short —
package the release binary in a small Docker image and run it on any
host that runs containers: always-on hosts (Fly.io, Railway, a VPS)
or Vercel's container runtime, each with the trade-offs below. TLS
and authentication are deliberately not in the library; a reverse
proxy or the platform's edge terminates TLS in front of you.

## The server program

The HTTP binding is a few lines around the same registrations a stdio
server uses. For containers, two details matter: bind `0.0.0.0` (the
platform routes into the container), and read the port from the
environment (`PORT` is the convention Vercel and most container hosts
use):

```pascal
program myserver;

{$I MCP.inc}

uses
  cthreads, // must be first on Unix: the listener is threaded
  Classes, SysUtils, fpjson,
  MCP.Protocol, MCP.Schema, MCP.Server, MCP.Transport.HTTP;

var
  Server: TMCPServer;
  Transport: TMCPHTTPServer;
begin
  Server := TMCPServer.Create('my-server', '1.0.0');
  try
    // ...RegisterTool / RegisterResource / RegisterPrompt...

    Transport := TMCPHTTPServer.Create(Server);
    try
      Transport.Address := '0.0.0.0';
      Transport.Port := StrToIntDef(GetEnvironmentVariable('PORT'), 8080);
      Transport.AllowedOrigins.Add('https://app.example.com');
      Transport.Run; // blocks until Stop is called from another thread
    finally
      Transport.Free;
    end;
  finally
    Server.Free;
  end;
end.
```

The binding serves the stateless `2026-07-28` revision only: every
POST is self-contained, an SSE stream lives exactly as long as one
request, and no session survives between calls — which is what makes
the container's lifecycle (restarts, scale-to-zero, multiple
instances) a non-event. State that must survive belongs behind
explicit handles in tool arguments, exactly as under stdio (see the
[runtime contract](shipping.md#runtime-contract)).

## The Docker image

FPC binaries need only libc at runtime, so a two-stage build produces
a small image. Debian bookworm ships FPC 3.2.2 — the exact pinned
compiler — and the committed dependency tree means the build stage
needs no lwpt, just `fpc @lwpt.cfg`:

```text
# Dockerfile
FROM debian:bookworm-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends fpc \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
RUN fpc @lwpt.cfg -O4 -dPRODUCTION -Xs -CX -XX -FEbuild source/apps/myserver.pas

FROM debian:bookworm-slim
COPY --from=build /src/build/myserver /usr/local/bin/myserver
EXPOSE 8080
USER nobody
CMD ["myserver"]
```

Build and smoke it locally:

```sh
docker build -t my-mcp-server .
docker run --rm -p 8080:8080 -e PORT=8080 my-mcp-server
```

Then exercise the endpoint the way a client will — POST a
`server/discover` to `http://localhost:8080/mcp` (the
[shipping guide](shipping.md#deploying-the-http-binding) shows the
binding's rules: single endpoint, mirrored headers, Origin
allowlist).

## Vercel

Since June 2026, Vercel runs arbitrary Docker images as functions:
name the file `Dockerfile.vercel` and deploy — Vercel builds the
image, and routes traffic to the container, which must listen on the
port in `$PORT`
([Container Images](https://vercel.com/docs/functions/container-images)).
The stateless binding fits the model, but know what the model is:

- **Scale-to-zero, not always-on.** Instances stop after idle
  minutes; the container gets SIGTERM and a grace period. The first
  request after idle pays a cold start.
- **A duration ceiling applies to every request** — including the
  streamed SSE response of a long tool call (300 s by default, more
  on paid plans). Long-running tools need an always-on host instead.
- **State never survives** between invocations — which the stateless
  binding already assumes.

## Always-on hosts

For long-lived processes without request-duration ceilings, run the
same image on a container host:

- **[Fly.io](https://fly.io)** — `fly launch` reads the Dockerfile
  and provisions a VM; usage-based pricing; no duration limits,
  long-lived SSE is fine.
- **[Railway](https://railway.com)** — connect the repo or push the
  image; usage-based with a monthly minimum; no duration limits.
- **A VPS + systemd** — copy the binary (no container required),
  write a unit file with `Restart=on-failure`, and let the distro's
  reverse proxy face the internet.

## TLS, auth, and the proxy in front

The library ships **no TLS and no authentication** — beyond loopback,
that is the operator's job by design
([shipping guide](shipping.md#deploying-the-http-binding)). In
practice:

- On Vercel/Fly/Railway, the platform edge terminates TLS; the
  container speaks plain HTTP on `$PORT`.
- On a VPS, put nginx/Caddy in front: terminate TLS, forward to
  `127.0.0.1:<port>`, and **disable response buffering for the
  endpoint** (SSE needs the proxy to stream, e.g.
  `proxy_buffering off;` in nginx).
- The Origin allowlist stays on regardless of proxy: add your web
  client's origin as an exact-match string via `AllowedOrigins`, and
  leave everything else rejected — it is the spec's DNS-rebinding
  defense, not a CORS convenience.
- Graceful shutdown: platforms stop containers with SIGTERM. `Stop`
  is safe to call from a signal handler or another thread; wire it up
  so in-flight requests finish inside the grace period.

## Registering the deployed server

Clients that speak Streamable HTTP take the endpoint URL directly —
for Claude Code:

```sh
claude mcp add --transport http my-server https://my-server.example.com/mcp
```

Legacy-handshake clients keep using stdio ([the binding is
modern-era only](shipping.md#deploying-the-http-binding)); nothing
stops one binary from serving stdio locally and HTTP remotely — the
registrations are the same.
