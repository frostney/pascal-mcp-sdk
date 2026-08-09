# pascal-mcp-sdk

**A FreePascal-native MCP (Model Context Protocol) server library.**
Dependency-light, cross-platform (Linux, macOS, Windows), targeting
the current **stateless** protocol revision (`2026-07-28`).
Expose tools, resources, and prompts from any Pascal program to AI
agents — no second language runtime, no framework.

- **Zero third-party runtime dependencies** — FPC RTL + fpjson only
  (the HTTP transport uses fcl-web, which ships inside FPC).
- **Two transports, one core** — newline-delimited JSON-RPC over
  stdio (the standard local-subprocess transport) and **Streamable
  HTTP** (single POST endpoint, SSE response streams), both thin
  shells around the same sans-I/O server core.
- **Stateless spec, dual-era by default** — native 2026-07-28
  (per-request `_meta`, mandatory `server/discover`, no session
  handshake) *and* the legacy `initialize` handshake for today's
  clients: **Claude Code and Claude Desktop connect out of the box**
  (verified).
- **MRTR (`input_required`)** — handlers can ask the client for more
  input mid-call (elicitation, sampling, roots) using the 2026-07-28
  multi-round-trip pattern, without any server-side session state.
- **Server-enforced argument validation** — every tool call is
  checked against its registered schema before your handler runs.

## Install

**As an [lwpt](https://github.com/frostney/lwpt) dependency** (the
command below was run and verified against a fresh scratch project):

```sh
lwpt add frostney/pascal-mcp-sdk@^1.0
```

Your programs then `uses MCP.Server` (and friends) directly — lwpt
discovers the library units through the nested manifest, and the
library's own test files stay out of your project's `lwpt test`
discovery.

**By vendoring** — the library is seven files. Copy
`source/units/MCP.JSONRPC.pas`, `MCP.Protocol.pas`, `MCP.Schema.pas`,
`MCP.Server.pas`, `MCP.Transport.Stdio.pas`, `MCP.Transport.HTTP.pas`,
and `Shared.inc` into your unit path. RTL + fpjson only (fcl-web for
the HTTP transport unit).

**Zero-install from a clone** — the repo commits its dependency
modules and the generated FPC response file, so a plain FPC 3.2.2 is
enough to build the demo server with no lwpt binary at all:

```sh
fpc @lwpt.cfg -FEbuild source/apps/mcpdemo.pas
./build/mcpdemo
```

## Quick start

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
    Server.RegisterTool('greet', 'Greet someone by name',
      ObjectSchema.AddString('name', 'Who to greet'),
      Greet);
    RunMCPStdioServer(Server);  // serves until the client closes stdin
  finally
    Server.Free;
  end;
end.
```

Handlers are synchronous plain functions or methods (`of object` —
both registration overloads exist). Tool schemas are built with the
fluent `MCP.Schema` API (`ObjectSchema.AddString(...).AddNumber(...)`;
properties are required unless opted out, and an output schema can be
passed alongside the input schema).

Or skip the schema entirely and let an **argument class** expand into
it — the handler then receives a populated, validated instance instead
of raw JSON (missing/mistyped arguments are rejected as in-band
`isError` results before the handler runs):

```pascal
type
  TAddArgs = class(TMCPArgs)
  private
    FA, FB: Double;
  published
    property a: Double read FA write FA;
    property b: Double read FB write FB;
  end;

function Add(AArgs: TMCPArgs;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  with AArgs as TAddArgs do
    Result := MCPTextResult(FloatToStr(a + b));
end;

// the class IS the schema: {a: number, b: number}, both required
Server.RegisterTool('add', 'Add two numbers', TAddArgs, Add);
```

Published properties map to JSON Schema types (string kinds →
`string`, floats → `number`, integer kinds → `integer`, `Boolean` →
`boolean`, enums → `string` with the enum names as allowed values).
Optionality uses the standard property directives: `default 3` makes
an ordinal property optional with that schema default (seeded into
the instance when the argument is omitted), and `stored False` makes
any property optional without one.
Classes rather than records because FPC 3.2.2 RTTI only exposes field
names for published class properties. For richer schemas ($ref,
nested objects, title/annotations, per-property descriptions) the
fluent builder, JSON-string, and definition-object registration
overloads remain available, validated at registration (schemas beyond
the server-enforced subset are marked `.ApplicationValidated`, handing
argument validation to your handler).

**Upgrading:** raw-schema registrations are now checked at startup
against the enforced JSON Schema subset. A tool whose `inputSchema`
uses a keyword outside that subset fails at registration, naming the
offending keyword, instead of being silently under-validated at call
time. Mark such registrations `.ApplicationValidated` to keep the
previous behaviour, with argument validation owned by your handler.

Results are built with `MCPTextResult` / `MCPErrorResult` /
`MCPStructuredResult` / `MCPImageResult`; handler exceptions become
in-band `isError: true` tool results automatically. `MCPImageResult`
takes either raw bytes (encoded to base64 for you) or data that is
already base64, plus the image's media type:

```pascal
Result := MCPImageResult(ScreenshotBytes, 'image/png');
```

Resources register either as static text (`RegisterTextResource`) or
with a reader callback (`RegisterResource`).

Serving the same registrations over **Streamable HTTP** instead of
stdio is a transport swap (modern-era only; binds 127.0.0.1):

```pascal
uses
  {$IFDEF UNIX} cthreads, {$ENDIF}   // first in the program uses clause
  ..., MCP.Transport.HTTP;

Transport := TMCPHTTPServer.Create(Server);
Transport.Port := 3000;   // POST http://127.0.0.1:3000/mcp
Transport.Run;            // blocks; Transport.Stop unblocks it
```

The complete worked example is
[source/apps/mcpdemo.pas](source/apps/mcpdemo.pas) — including the
MRTR `greet_user` tool that elicits input mid-call; the protocol-level
walkthrough lives in [docs/quick-start.md](docs/quick-start.md).

## Protocol coverage

| Surface | Status |
| --- | --- |
| `server/discover` | ✅ mandatory entry point, capabilities + instructions |
| `tools/list`, `tools/call` | ✅ text / image / structured content, in-band execution errors, server-side subset validation of arguments |
| `resources/list`, `resources/read` | ✅ static + dynamic, text + blob builders |
| `resources/templates/list` + template matching | ✅ RFC 6570 level-1 (`{var}`), exact resources win, vars passed to readers |
| `prompts/list`, `prompts/get` | ✅ fluent argument declaration, message builders, spec error codes |
| MRTR `input_required` (SEP-2322) | ✅ on `tools/call` + `prompts/get`: elicitation (form + url), sampling, roots entry builders; capability-gated; stateless re-entry |
| `notifications/progress`, `notifications/message` | ✅ `MCPReportProgress` / `MCPLogMessage` from any handler; strictly opt-in per request (`progressToken` / `logLevel`), severity-filtered, emitted before the response |
| `_meta` validation, version negotiation | ✅ `-32602` / `-32021` / `-32022` per spec |
| `ttlMs` / `cacheScope` caching hints (SEP-2549) | ✅ on discover/list/read, tunable via `CacheTtlMs`/`CacheScope` |
| stdio transport | ✅ newline-delimited, EOF shutdown contract |
| Streamable HTTP transport | ✅ `MCP.Transport.HTTP`: single POST endpoint, SSE response streams, mirrored-header validation, Origin allowlist |
| Legacy era (`initialize`: 2024-11-05, 2025-06-18, 2025-11-25) | ✅ dual-era default: era-faithful dialect (unstamped results, `-32002`, `ping`); `DualEra := False` for strict modern-only |
| `subscriptions/listen`, list-changed | ⏳ not implemented (registries are static after startup) |

Resource-template matching is intentionally limited to simple `{var}`
expressions. Variables must be non-empty and separated by literal text; matching
uses the complete following literal and may backtrack. Captured values are passed
to readers exactly as encoded in the URI—percent-decoding is not performed.

Spec facts verified against the official
[MCP specification](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio)
(2026-07-20, re-verified 2026-08-08 against the published final
2026-07-28 text), and the full surface **interop-tested against both
official MCP TypeScript clients**: the stable v2 client
(`@modelcontextprotocol/client` 2.0.0, pinned + auto-probe modes, over
stdio and Streamable HTTP, including MRTR auto-fulfilment) and the v1
SDK (`@modelcontextprotocol/sdk`, the legacy era Claude Code speaks) —
plus a live `claude mcp add` health check. See
[tools/interop-ts/](tools/interop-ts/) and
[docs/architecture.md](docs/architecture.md) for the grounding notes.

## Contributing

Building, testing, and formatting the library itself go through the
lwpt toolchain — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).
