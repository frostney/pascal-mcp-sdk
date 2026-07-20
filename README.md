# pascal-mcp-sdk

**The first FreePascal-native MCP (Model Context Protocol) server
library.** Dependency-light, cross-platform (Linux, macOS, Windows),
targeting the current **stateless** protocol revision (`2026-07-28`).
Expose tools and resources from any Pascal program to AI agents —
no second language runtime, no framework.

- **Zero third-party runtime dependencies** — FPC RTL + fpjson only.
- **stdio transport, complete** — newline-delimited JSON-RPC 2.0 over
  stdin/stdout, the standard local-subprocess transport. Streamable
  HTTP is a planned follow-up behind the same transport-agnostic core.
- **Stateless spec, dual-era by default** — native 2026-07-28
  (per-request `_meta`, mandatory `server/discover`, no session
  handshake) *and* the legacy `initialize` handshake for today's
  clients: **Claude Code and Claude Desktop connect out of the box**
  (verified). Existing Object Pascal MCP projects are Delphi-only and
  target only the superseded session-based revisions.
- **lwpt ecosystem** — built/tested/formatted via
  [lwpt](https://github.com/frostney/lwpt); sibling of
  [duetto](https://github.com/frostney/duetto). Works without lwpt too
  (see below).

## Quick start

```pascal
program myserver;

{$mode delphi} {$H+}

uses
  fpjson,
  MCP.Protocol, MCP.Server, MCP.Transport.Stdio;

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
    Server.RegisterTool('greet', 'Greet someone by name',
      '{"type":"object","properties":{"name":{"type":"string"}},' +
      '"required":["name"]}',
      Greet);
    RunMCPStdioServer(Server);  // serves until the client closes stdin
  finally
    Server.Free;
  end;
end.
```

Handlers are synchronous plain functions or methods (`of object` —
both registration overloads exist). Tool input schemas are JSON Schema
passed as strings and validated for well-formedness at registration.
Results are built with `MCPTextResult` / `MCPErrorResult` /
`MCPStructuredResult`; handler exceptions become in-band
`isError: true` tool results automatically. Resources register either
as static text (`RegisterTextResource`) or with a reader callback
(`RegisterResource`).

The complete worked example is
[source/apps/mcpdemo.pas](source/apps/mcpdemo.pas); the protocol-level
walkthrough lives in [docs/quick-start.md](docs/quick-start.md).

## Building with lwpt

```sh
lwpt install       # resolve dev-time deps, generate lwpt.cfg
lwpt build         # build/mcpdemo + build/mcpsmoke
lwpt test          # co-located unit suites
./build/mcpsmoke   # end-to-end battery against the real subprocess
```

## Using pascal-mcp-sdk without lwpt

lwpt projects are **zero-install**: the dependency modules under
`.lwpt/modules/` and the generated FPC response file `lwpt.cfg` are
committed. A plain FPC 3.2.2 install is enough to build straight from a
fresh clone — no lwpt binary required:

```sh
fpc @lwpt.cfg -FEbuild source/apps/mcpdemo.pas
./build/mcpdemo
```

`lwpt.cfg` is just `-Fu`/`-Fi` unit paths; the manual equivalent, if
you prefer explicit flags:

```sh
fpc -Fusource/units -Fisource/units \
    -Fu.lwpt/modules/testing/packages/testing/source \
    -FEbuild source/apps/mcpdemo.pas
```

(The `testing` module path is only needed by the `MCP.*.Test.pas`
programs; the library and `mcpdemo` compile with `-Fusource/units`
alone.)

To **vendor** pascal-mcp-sdk into a non-lwpt project, copy
`source/units/MCP.*.pas` (minus the `.Test.pas` files) plus
`source/units/Shared.inc` into your unit path — the library is those
five files, RTL + fpjson only.

## Protocol coverage (v1)

| Surface | Status |
| --- | --- |
| `server/discover` | ✅ mandatory entry point, capabilities + instructions |
| `tools/list`, `tools/call` | ✅ text / structured content, in-band execution errors |
| `resources/list`, `resources/read` | ✅ static + dynamic, text + blob builders |
| `_meta` validation, version negotiation | ✅ `-32602` / `-32021` / `-32022` per spec |
| `ttlMs` / `cacheScope` caching hints (SEP-2549) | ✅ on discover/list/read, tunable via `CacheTtlMs`/`CacheScope` |
| Legacy era (`initialize`, 2024-11-05…2025-11-25) | ✅ dual-era default: era-faithful dialect (unstamped results, `-32002`, `ping`); `DualEra := False` for strict modern-only |
| `subscriptions/listen`, list-changed | ⏳ follow-up (registries are static in v1) |
| Streamable HTTP transport | ⏳ follow-up (`MCP.Transport.Http` seam reserved) |

Spec facts verified against the official
[MCP specification](https://modelcontextprotocol.io/specification/draft/basic/transports/stdio)
on 2026-07-20, and the full surface **interop-tested against both
official MCP TypeScript clients**: the v2 RC beta
(`@modelcontextprotocol/client` 2.0.0-beta.4, pinned + auto-probe
modes) and the v1 SDK (`@modelcontextprotocol/sdk`, the legacy era
Claude Code speaks) — plus a live `claude mcp add` health check. See
[tools/interop-ts/](tools/interop-ts/) and
[docs/architecture.md](docs/architecture.md) for the grounding notes.

## License

MIT — see [LICENSE](LICENSE).
