# Quick Start

## Executive Summary

Install FPC 3.2.2 (and optionally the lwpt release binary), clone,
`lwpt build` — or `fpc @lwpt.cfg -FEbuild source/apps/mcpdemo.pas` with
no lwpt at all. Register tools with a name, description, JSON-Schema
string, and a handler function; call `RunMcpStdioServer`. Wire the
binary into any MCP client as a stdio server.

## Prerequisites

- **FPC 3.2.2** — `apt install fpc` / `brew install fpc` / the
  win32+win64 combo installer from freepascal.org.
- **lwpt** (optional but canonical) — download the release tarball for
  your platform from
  [lwpt's releases](https://github.com/frostney/lwpt/releases), verify
  the checksum, put `lwpt` on PATH.
- **lefthook** (contributors) — `lefthook install` once per clone wires
  the formatting pre-commit hook.

## Build and verify

```sh
git clone https://github.com/frostney/pascal-mcp
cd pascal-mcp
lwpt install       # resolves the dev-time testing dep, writes lwpt.cfg
lwpt build         # build/mcpdemo, build/mcpsmoke
lwpt test          # 4 co-located suites
./build/mcpsmoke   # 19-check E2E battery against the real subprocess
```

Without lwpt (the committed `.lwpt/modules` + `lwpt.cfg` make the repo
zero-install):

```sh
fpc @lwpt.cfg -FEbuild source/apps/mcpdemo.pas
```

## Talk to the demo server by hand

Every request must carry the per-request `_meta` (this is the stateless
2026-07-28 revision — there is no initialize handshake):

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

## Write your own server

```pascal
program myserver;

{$mode delphi} {$H+}

uses
  fpjson,
  MCP.Protocol, MCP.Server, MCP.Transport.Stdio;

function Greet(AArguments: TJSONObject;
  const ACtx: TMcpRequestContext): TMcpToolResult;
begin
  Result := McpTextResult('Hello, ' + AArguments.Get('name', 'world') + '!');
end;

var
  Server: TMcpServer;
begin
  Server := TMcpServer.Create('my-server', '1.0.0');
  try
    Server.Instructions := 'Greets people.';   // surfaced via server/discover
    Server.RegisterTool('greet', 'Greet someone by name',
      '{"type":"object","properties":{"name":{"type":"string"}},' +
      '"required":["name"]}',
      Greet);
    Server.RegisterTextResource('mcp://my-server/motd', 'motd',
      'text/plain', 'Be excellent to each other.');
    RunMcpStdioServer(Server);
  finally
    Server.Free;
  end;
end.
```

Compile it inside this repo's unit paths (`fpc @lwpt.cfg ...`), or in
your own project with `-Fu<path-to>/source/units`.

Key behaviours you get for free:

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

## Register the server with an MCP client

Any client that launches stdio servers works — legacy or RC-era, thanks
to the dual-era default. With Claude Code it is one command
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

Logging goes to **stderr only** (`McpLogToStderr`) — stdout belongs to
the protocol.
