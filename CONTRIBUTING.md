# Contributing to pascal-mcp-sdk

This guide is for people changing the library itself. If you just want
to **use** pascal-mcp-sdk in your program, see the
[README](README.md) and [docs/quick-start.md](docs/quick-start.md) —
consumers never need the toolchain below.

## Toolchain

- **FPC 3.2.2** — `apt install fpc` / `brew install fpc` / the
  win32+win64 combo installer from freepascal.org. The version must be
  **exactly 3.2.2**: compiler flags are pinned in
  `source/units/Shared.inc` and CI pins 3.2.2. Where your package
  manager ships a different release, install 3.2.2 from the official
  [FPC downloads](https://www.freepascal.org/download.html) instead
  (`fpc -iV` prints the installed version).
- **lwpt** — the canonical build/test/format entry point. Download the
  release tarball for your platform from
  [lwpt's releases](https://github.com/frostney/lwpt/releases), verify
  the checksum, put `lwpt` on PATH. Everything goes through it — do
  not invoke `fpc` directly except as `fpc @lwpt.cfg`.
- **lefthook** — `lefthook install` once per clone wires the
  formatting pre-commit hook (`lwpt format`, re-staging what it
  rewrites).
- **Node ≥ 20** (only for the interop harness under
  `tools/interop-ts/`).

## Clone, build, test

```sh
git clone https://github.com/frostney/pascal-mcp-sdk
cd pascal-mcp-sdk
lwpt install           # resolve deps, regenerate lwpt.cfg + lwpt.lock
lwpt build             # build/mcpdemo + build/mcpsmoke
lwpt test              # co-located unit suites (source/units/*.Test.pas)
./build/mcpsmoke       # E2E battery: spawns mcpdemo, drives the protocol
lwpt format --check    # formatter gate (no flag = rewrite in place)
```

`lwpt install --frozen` is the CI mode: verify the lockfile and the
committed modules without touching the network. Exception: Windows CI
skips `--frozen` and runs `lwpt install` online, pending
[lwpt#78](https://github.com/frostney/lwpt/issues/78).

`lwpt.cfg` and `lwpt.lock` are **generated** by `lwpt install` — never
hand-edit them; `lwpt.toml` is the manifest you edit. The committed
trees under `.lwpt/modules/` and `.lwpt/archives/` are deliberate
(zero-install) — do not gitignore them. Never commit `build/`,
`.lwpt/tmp/`, `.lwpt/sessions/`, or `.lwpt/install.lock`.

## Test layers

1. **Unit suites** — co-located `source/units/MCP.*.Test.pas`,
   discovered by `lwpt test`. Tests live next to the unit they cover
   and must keep providing regression value.
2. **mcpsmoke** — the in-repo E2E battery: launches `mcpdemo` the way
   a real MCP client does (subprocess, pipes) and drives the full
   surface including error paths, MRTR rounds, and the EOF shutdown
   contract.
3. **Interop** (`tools/interop-ts/`) — the official MCP TypeScript
   clients against `mcpdemo` over stdio, the legacy handshake, and
   Streamable HTTP:

   ```sh
   lwpt build
   cd tools/interop-ts
   npm ci
   npm run interop
   ```

Test *execution* touches no network — everything runs against local
pipes, sockets on 127.0.0.1, and temp files. Dependency *installation*
is separate: `npm ci` for the interop harness may reach the npm registry.

## CI expectations

`pr.yml` is the pre-merge gate on every PR: native
`install --frozen` + format check + build + test + mcpsmoke on Linux,
macOS, and Windows, the zero-install `fpc @lwpt.cfg` path, a Markdown
lint, and the **required** `interop` job (the three official-SDK
batteries). `ci.yml` runs the wider per-arch matrix post-merge on
`main`.

## Ground rules

- **FreePascal only.** FPC 3.2.2, Delphi mode, flags centralised in
  `Shared.inc` — no per-unit compiler directives, no second compiled
  language.
- **Zero third-party runtime dependencies.** The library is RTL +
  fpjson only (fcl-web powers `MCP.Transport.HTTP` and ships inside
  FPC; it stays confined to that unit). lwpt's `testing` package is
  dev-time; anything beyond needs explicit maintainer approval.
- **`MCP.Server` owns the protocol surface.** Dispatch rules, error
  codes, and result shapes must not leak into transports; transports
  move lines only. Layering is strictly bottom-up: `MCP.JSONRPC` →
  `MCP.Protocol` → `MCP.Server` → transports.
- **Spec facts are verified, never recalled.** Any change to protocol
  behaviour cites the official spec page (modelcontextprotocol.io) it
  implements, with the verification date — see the unit headers and
  [docs/architecture.md](docs/architecture.md) for the pattern.

## Contributor docs

- [docs/architecture.md](docs/architecture.md) — layering, the
  sans-I/O core, spec grounding notes.
- [docs/tooling.md](docs/tooling.md) — toolchain decisions and pins.
- [docs/code-style.md](docs/code-style.md) — formatting and FPC
  pitfalls.
- [docs/deployment.md](docs/deployment.md) — release and packaging.
- [DEFINITION_OF_READY.md](DEFINITION_OF_READY.md) /
  [DEFINITION_OF_DONE.md](DEFINITION_OF_DONE.md) — what makes work
  startable and finished here.
