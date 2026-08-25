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
  handshake) *and* the classic `initialize` handshake current clients
  still speak: **Claude Code, Claude Desktop, and Codex connect out
  of the box**.
- **MRTR (`input_required`)** — handlers can ask the client for more
  input mid-call (elicitation, sampling, roots) using the 2026-07-28
  multi-round-trip pattern, without any server-side session state.
- **Server-enforced argument validation** — every tool call is
  checked against its registered schema before your handler runs.

📚 **Full documentation:** guides, API reference, and internals at
<https://frostney.github.io/pascal-mcp-sdk/> — rendered from
[docs/](docs/).

## Not these projects

This is a FreePascal MCP server library. It is not
[tina4stack/claude-pascal-mcp](https://github.com/tina4stack/claude-pascal-mcp)
(a Python MCP that compiles Pascal) and not
[@pascal-app/mcp](https://www.npmjs.com/package/@pascal-app/mcp)
(the 3D editor MCP).

## Install

**As an [lwpt](https://github.com/frostney/lwpt) dependency:**

```sh
lwpt add frostney/pascal-mcp-sdk@^2.0
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
walkthrough lives in [docs/guides/quick-start.md](docs/guides/quick-start.md).

## Protocol coverage

Implemented: tools, resources (including RFC 6570 templates),
prompts, MRTR, progress/log notifications, caching hints, both
transports, and the classic `initialize` era. Deliberately out:
`subscriptions/listen` and list-changed notifications — registries
are static after startup. The authoritative surface-by-surface table,
including verification and interop evidence, lives in
[docs/reference/protocol-coverage.md](docs/reference/protocol-coverage.md).

## Contributing

Building, testing, and formatting the library itself go through the
lwpt toolchain — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).
