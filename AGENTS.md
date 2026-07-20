# Agent Instructions

## Hard Constraints

- **FreePascal only.** FPC 3.2.2, Delphi mode, flags centralised in
  `source/units/Shared.inc`. Do not introduce another compiled language or
  repeat compiler directives per unit.
- **Zero third-party runtime dependencies.** The library is RTL + fpjson
  only. lwpt's `testing` package is dev-time; anything beyond that needs
  explicit maintainer approval with a recorded justification.
- **lwpt is the only toolchain entry point** — install, build, test, format
  all go through it. Do not add another build system (no Make/CMake for
  builds) and do not invoke `fpc` directly except as `fpc @lwpt.cfg`.
- **`lwpt.cfg` and `lwpt.lock` are generated** by `lwpt install`; never
  hand-edit them. `lwpt.toml` is the manifest you edit.
- **The `units` array in `lwpt.toml` lists only `source/units`** —
  lwpt 0.2.0 discovers dep units through nested manifests. Keep
  `[format] exclude = [".lwpt/**"]` so the formatter never rewrites
  fetched modules.
- **Layout is fixed:** library units in `source/units/` (namespaced
  `MCP.*.pas`, tests co-located as `MCP.*.Test.pas`), program entry points
  in `source/apps/`.
- **`build/` is generated** — never commit it.
- **`MCP.Server` owns the protocol surface.** Dispatch rules, error codes,
  and result shapes must not leak into transports; transports move lines
  only. `MCP.Protocol` owns the per-request `_meta` model; `MCP.JsonRpc`
  owns the JSON-RPC 2.0 profile.
- **Spec facts are verified, never recalled.** Any change to protocol
  behaviour cites the official spec page (modelcontextprotocol.io) it
  implements, with the verification date — see the unit headers and
  [docs/architecture.md](docs/architecture.md) for the pattern.

## Runtime / Commands

lwpt is the **released binary on PATH** (checksum-verified tarball from
lwpt's GitHub releases — see `docs/quick-start.md`); no sibling checkout,
no bootstrap. Dependencies resolve from the same release tag.

```bash
lwpt install           # resolve deps, regenerate lwpt.cfg + lwpt.lock
lwpt install --frozen  # CI mode: verify lockfile + committed modules, no network
lwpt format --check    # formatter gate (no flag = rewrite in place)
lwpt build             # mcpdemo + mcpsmoke
lwpt test              # four co-located unit suites
./build/mcpsmoke       # E2E battery: spawns mcpdemo, drives the protocol
```

## Code Organization

| Path | Role |
| --- | --- |
| `source/units/` | Library: `MCP.JsonRpc` (JSON-RPC 2.0 profile), `MCP.Protocol` (per-request `_meta` model), `MCP.Server` (sans-I/O dispatch core, tool/resource registries), `MCP.Transport.Stdio` (newline-delimited stdio binding) |
| `source/apps/` | Programs: `mcpdemo` (example stdio server), `mcpsmoke` (subprocess E2E battery) |
| `docs/` | Architecture, quick-start, tooling, code style, deployment |

Layering is strictly bottom-up: `MCP.JsonRpc` → `MCP.Protocol` →
`MCP.Server` → `MCP.Transport.Stdio`. The server core performs no I/O
(`HandleMessage`: line in, line out) — the planned `MCP.Transport.Http`
(Streamable HTTP) wraps the same core without changes, mirroring
duetto's sans-I/O discipline. See
[docs/architecture.md](docs/architecture.md).

## Testing

- `lwpt test` discovers `source/units/*.Test.pas`; tests are co-located
  with the unit they cover and must keep providing regression value.
- `mcpsmoke` is the in-repo E2E battery: it launches `mcpdemo` the way a
  real MCP client does (subprocess, pipes) and drives the full v1
  surface including error paths and the EOF shutdown contract.
- Nothing in the test stack touches the network; everything runs against
  local pipes and temp files.

## Safety / Boundaries

- Never commit generated state: `build/`, `.lwpt/tmp/`,
  `.lwpt/sessions/`, `.lwpt/install.lock`. The committed trees under
  `.lwpt/modules/` and `.lwpt/archives/` are deliberate (zero-install)
  — do not gitignore them.
- Do not push or open PRs without explicit maintainer go-ahead.
- Edit `AGENTS.md` only — `CLAUDE.md` is a symlink to it.
