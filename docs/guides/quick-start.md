# Quick Start

## Executive Summary

Add pascal-mcp-sdk to your project (`lwpt add` or vendor seven
files), register tools with a name, description, schema, and a
handler function, and call `RunMCPStdioServer` — or serve the same
registrations over Streamable HTTP with `TMCPHTTPServer`. Wire the
binary into any MCP client.

This page is for **consumers** of the library. Building and testing
the library itself is covered in
[CONTRIBUTING.md](../../CONTRIBUTING.md).

## Prerequisites

- **FPC 3.2.2** — `apt install fpc` / `brew install fpc` / the
  win32+win64 combo installer from freepascal.org.
- **lwpt** (optional — for the dependency path) — download the release
  tarball for your platform from
  [lwpt's releases](https://github.com/frostney/lwpt/releases), verify
  the checksum, put `lwpt` on PATH.

## Get the library

As an lwpt dependency, from your project root (this exact command was
verified against a scratch consumer project):

```sh
lwpt add frostney/pascal-mcp-sdk@^2.0
lwpt build
```

Your program's `uses MCP.Server` resolves through the nested manifest;
the library's `*.Test.pas` files do not leak into your `lwpt test`
discovery.

Without lwpt, vendor the seven files —
`source/units/MCP.JSONRPC.pas`, `MCP.Protocol.pas`, `MCP.Schema.pas`,
`MCP.Server.pas`, `MCP.Transport.Stdio.pas`, `MCP.Transport.HTTP.pas`,
`Shared.inc` — into your unit path and compile with
`-Fu<that-path> -Fi<that-path>`.

## Write your own server

```pascal
program myserver;

{$mode delphi} {$H+}

uses
  fpjson,
  MCP.Protocol, MCP.Schema, MCP.Server, MCP.Transport.Stdio;

function Greet(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPTextResult('Hello, ' + AArguments.Get('name', 'world') + '!');
end;

var
  Server: TMCPServer;
begin
  Server := TMCPServer.Create('my-server', '1.0.0');
  try
    Server.Instructions := 'Greets people.';   // surfaced via server/discover
    Server.RegisterTool('greet', 'Greet someone by name',
      ObjectSchema.AddString('name', 'Who to greet'),
      Greet);
    Server.RegisterTextResource('mcp://my-server/motd', 'motd',
      'text/plain', 'Be excellent to each other.');
    RunMCPStdioServer(Server);
  finally
    Server.Free;
  end;
end.
```

Prefer typed arguments? Declare a `TMCPArgs` descendant and register
the class — it expands into the schema, and your handler receives a
populated, validated instance (see the `add` tool in
[mcpdemo.pas](../../source/apps/mcpdemo.pas) and the README's typed
example).

Key behaviours you get for free:

- **Argument validation before your handler runs**: raw-handler tools
  are checked against their registered schema's subset (required,
  types, enums, defaults) and typed tools against their class —
  violations become in-band `isError` results a model can correct
  against.
- **Validation errors** (`-32602`), **version negotiation** (`-32022`
  with the supported list), and **method-not-found** (`-32601`) are
  produced by the library; handlers never see malformed metadata.
- **Handler exceptions** become `isError: true` tool results — the
  in-band error channel models can self-correct against.
- **`resultType` and `serverInfo`** are stamped on every result.
- **Legacy clients work out of the box**: the server is dual-era by
  default, so a client opening with the classic `initialize` handshake
  (Claude Code, Claude Desktop today) is served the legacy dialect
  while modern `_meta` requests stay stateless — same registries, same
  handlers. Set `Server.DualEra := False` for a strict modern-only
  server that rejects `initialize` naming its supported versions.
- **Mid-call input** (MRTR): return
  `MCPInputRequired(...)` from a tool or prompt handler to ask the
  client for more input (elicitation form/url, sampling, roots); the
  client retries the call and your handler re-enters with the
  responses on `ACtx` — see `greet_user` in
  [mcpdemo.pas](../../source/apps/mcpdemo.pas).

> These protocol behaviours — MRTR, Streamable HTTP/SSE, the per-request
> `_meta` model, and the EOF shutdown contract — implement spec revision
> 2026-07-28. The dated official-spec citations
> (modelcontextprotocol.io) live in architecture.md's
> [Spec grounding](../internals/architecture.md#spec-grounding) section.

## Serve over Streamable HTTP

The same server object serves HTTP with a transport swap (modern era
only — HTTP clients speak 2026-07-28; the binding validates the
mirrored `Mcp-*` headers, streams SSE for requests that opt into
progress/log notifications, and binds 127.0.0.1 by default):

```pascal
uses
  {$IFDEF UNIX} cthreads, {$ENDIF}   // first in the program uses clause
  ..., MCP.Transport.HTTP;

Transport := TMCPHTTPServer.Create(Server);
Transport.Port := 3000;   // POST http://127.0.0.1:3000/mcp
Transport.Run;            // blocks; Transport.Stop unblocks it
```

Try it: `./build/mcpdemo --http 3000`.

Every HTTP request still carries `_meta` in its body, and the mirrored
`Mcp-*` headers are derived from it. The transport does not reject a
request that omits the header with a header error, but the core still
requires `_meta` and answers `-32602` when it is missing — the header
tolerance is not a way to skip `_meta`.

## Talk to a stdio server by hand

Every modern request carries the per-request `_meta` (this is the
stateless 2026-07-28 revision — there is no initialize handshake):

```sh
./build/mcpdemo <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"add","arguments":{"a":19,"b":23},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
EOF
```

The first line answers with `supportedVersions`, capabilities, and the
server's instructions; the second with `content` +
`structuredContent: {"sum": 42}`. Closing stdin (the heredoc ending)
makes the server exit — that is the spec's graceful-shutdown contract.

## Register the server with an MCP client

Any client that launches stdio servers works — legacy or modern,
thanks to the dual-era default. With Claude Code it is one command
(verified against `mcpdemo`):

```sh
claude mcp add my-server /absolute/path/to/myserver
claude mcp list        # → my-server: … - ✔ Connected
```

The generic configuration shape:

```json
{
  "mcpServers": {
    "my-server": {
      "command": "/absolute/path/to/myserver"
    }
  }
}
```

Logging goes to **stderr only** (`MCPLogToStderr`) — stdout belongs to
the protocol.
