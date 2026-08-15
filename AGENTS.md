# Agent Instructions

## Hard Constraints

- **FreePascal only.** FPC 3.2.2, Delphi mode, flags centralised in
  `source/units/MCP.inc`. Do not introduce another compiled language or
  repeat compiler directives per unit.
- **Zero third-party runtime dependencies.** The library is RTL + fpjson
  only. Packages that ship inside FPC 3.2.2 are not third-party: fcl-web
  is admitted on the same footing as fcl-json (fpjson), and stays
  confined to `MCP.Transport.HTTP`. lwpt's `testing` package is dev-time;
  anything beyond that needs explicit maintainer approval with a recorded
  justification.
- **lwpt is the only toolchain entry point** — install, build, test, format
  all go through it. Do not add another build system (no Make/CMake for
  builds) and do not invoke `fpc` directly except as `fpc @lwpt.cfg`.
- **`lwpt.cfg` and `lwpt.lock` are generated** by `lwpt install`; never
  hand-edit them. `lwpt.toml` is the manifest you edit.
- **The `units` array in `lwpt.toml` lists only `source/units`** —
  lwpt (0.2.0+) discovers dep units through nested manifests. Keep
  `[format] exclude = [".lwpt/**"]` so the formatter never rewrites
  fetched modules.
- **Layout is fixed:** library units in `source/units/` (namespaced
  `MCP.*.pas`, tests co-located as `MCP.*.Test.pas`), program entry points
  in `source/apps/`, self-contained run-script wrappers in `scripts/`
  (InstantFPC-executed, so no `MCP.inc` and no `MCP.*` units there).
- **`build/` is generated** — never commit it.
- **`MCP.Server` owns the protocol surface.** Dispatch rules, error codes,
  and result shapes must not leak into transports; transports move lines
  only. `MCP.Protocol` owns the per-request `_meta` model; `MCP.JSONRPC`
  owns the JSON-RPC 2.0 profile.
- **Spec facts are verified, never recalled.** Any change to protocol
  behaviour cites the official spec page (modelcontextprotocol.io) it
  implements, with the verification date — see the unit headers and
  [docs/internals/architecture.md](docs/internals/architecture.md) for the pattern.

## Runtime / Commands

lwpt is the **released binary on PATH** (checksum-verified tarball from
lwpt's GitHub releases — see `docs/guides/quick-start.md`); no sibling
checkout, no bootstrap. Dependencies resolve from the same release tag.
The command surface itself is documented in the machine-written
`lwpt agents` block at the end of this file — repo-specific context the
generator can't know: `lwpt install --frozen` is the CI mode (verify
lockfile + committed modules, no network), `lwpt build` produces
`mcpdemo` + `mcpsmoke`, `lwpt test` runs the co-located unit suites, and
`lwpt run smoke` drives the built E2E battery (mcpsmoke spawns mcpdemo
the way a real client does).

## Code Organization

| Path | Role |
| --- | --- |
| `source/units/` | Library: `MCP.JSONRPC` (JSON-RPC 2.0 profile), `MCP.Protocol` (per-request `_meta` model), `MCP.Schema` (fluent schema builder + RTTI-derived argument classes), `MCP.Server` (sans-I/O dispatch core; tool/resource/prompt registries), `MCP.Transport.Stdio` (newline-delimited stdio binding), `MCP.Transport.HTTP` (Streamable HTTP binding: single POST endpoint, SSE response streams) |
| `source/apps/` | Programs: `mcpdemo` (example stdio server), `mcpsmoke` (subprocess E2E battery) |
| `scripts/` | Self-contained `lwpt run` wrappers (currently `smoke.pas` → runs the built `mcpsmoke`) |
| `tools/` | Cross-implementation checks: `interop-ts/` (official MCP TypeScript clients vs `mcpdemo` over stdio, the legacy era, and Streamable HTTP) |
| `docs/` | Consumer-first tree rendered by the website: `guides/` (quick start, tools, images, schemas, prompts, resources, configuration, notifications, shipping, deployment, troubleshooting, cookbook), `reference/` (public API, gated by `.github/scripts/check-reference-docs.sh`), `internals/` (architecture, contributing, tooling, code style, releasing — contributor pages), `adr/` (decision records, repo-only — excluded from the website), `casts/` (committed terminal recordings served by the site) |
| `website/` | GitHub Pages site: Fumadocs static export rendering `docs/` directly — contributor/CI tooling, not part of the library |

Layering is strictly bottom-up: `MCP.JSONRPC` → `MCP.Protocol` →
`MCP.Server` → `MCP.Transport.Stdio` / `MCP.Transport.HTTP`. The server
core performs no I/O (`HandleMessage`: line in, line out) — both
transports wrap the same core without changes, mirroring duetto's
sans-I/O discipline. See
[docs/internals/architecture.md](docs/internals/architecture.md).

## Testing

- `lwpt test` discovers `source/units/*.Test.pas`; tests are co-located
  with the unit they cover and must keep providing regression value.
- `mcpsmoke` is the in-repo E2E battery: it launches `mcpdemo` the way a
  real MCP client does (subprocess, pipes) and drives the full v1
  surface including error paths and the EOF shutdown contract.
- Nothing in the test stack touches the **external** network; everything
  runs against local pipes, loopback (127.0.0.1) sockets, and temp
  files. The loopback sockets are a recorded maintainer exception for
  the transport binding suites: `MCP.Transport.HTTP.Test.pas`
  deliberately drives a live listener on an ephemeral 127.0.0.1 port,
  and stays co-located per the fixed layout above (this repo has no
  separate integration-test layer).

## Safety / Boundaries

- Never commit generated state: `build/`, `.lwpt/tmp/`,
  `.lwpt/sessions/`, `.lwpt/install.lock`. The committed trees under
  `.lwpt/modules/` and `.lwpt/archives/` are deliberate (zero-install)
  — do not gitignore them.
- Do not push or open PRs without explicit maintainer go-ahead.
- Edit `AGENTS.md` only — `CLAUDE.md` is a symlink to it.

<!-- lwpt:agents:begin -->

## `lwpt` command reference

Generated by `lwpt agents` from the toolkit's command registry and this project's manifest. Everything between the `lwpt:agents` markers is machine-written: edit outside the markers only, regenerate with `lwpt agents`, verify with `lwpt agents --check`. Run `lwpt <command> --help` for the same reference in a terminal.

### Subcommands

- `lwpt install [--frozen] [--silent]` — Resolve and fetch dependencies
  - `--frozen` — CI mode: refuse to update the lockfile, refuse network, verify hashes
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt add <source[@version]> [--name <name>] [--silent]` — Add a dependency to the manifest and install it
  - `--name=<value>` — Dependency name in the manifest (default: the source's last path segment)
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt remove <name> [<name>...] [--silent]` — Remove dependencies from the manifest and prune their modules
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt build [entry...] [--mode dev|release] [--clean] [--jobs N] [--verbose] [--silent]` — Compile manifest build entries
  - `--mode=<value>` — Build mode: dev (default) or release
  - `--clean` — Force a full rebuild in fresh private staging
  - `--jobs=<N>` — Maximum concurrent build entries (default: machine budget)
  - `--verbose` — Replay successful build-entry logs
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt format [--check] [--silent]` — Format uses-clauses and identifiers
  - `--check` — Report files needing formatting without rewriting; exit 1 if any
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt duplication [--json] [--silent]` — Report manifest-scoped Pascal token clones
  - `--json` — Emit the deterministic machine-readable analysis envelope
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt test [selector...] [--tier default|e2e] [--jobs N] [--bail N] [--verbose] [--inventory] [--silent]` — Discover and run *.Test.pas files
  - `--tier=<value>` — Test tier to include: default (unit + integration) or e2e (adds network-touching tier)
  - `--jobs=<N>` — Maximum concurrent test programs (default: shared machine budget)
  - `--bail=<N>` — Stop after N compile or runtime failures; 0 runs the full queue
  - `--verbose` — Replay successful test logs
  - `--inventory` — Emit registered suites and cases as deterministic JSON without running tests
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt repair [--silent]` — Reclaim install, build-session, and worker-lease residue
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt init [--yes] [--force] [--adopt] [--silent]` — Scaffold a new LWPT project or adopt an existing manifest
  - `--yes` — Skip prompts and use defaults derived from the directory name
  - `--force` — Overwrite an existing lwpt.toml without asking
  - `--adopt` — Fill in missing scaffold around an existing manifest without modifying it
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt run <task-name> | <subcommand> [subcommand-args...] [--silent]` — Invoke a user-declared run task (or a built-in subcommand by name)
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt health [--json] [--hotspots] [--silent]` — Report Pascal complexity and optional Git hotspots
  - `--json` — Write the deterministic machine-readable report
  - `--hotspots` — Enrich complexity with the latest 100 commits of local Git churn
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt agents [--check] [--silent]` — Write or verify the agent-facing command reference in AGENTS.md
  - `--check` — Verify the AGENTS.md block matches the current command surface; exit 1 when stale
  - `--silent` — Suppress ordinary output and emit only the final command result

### Run tasks

- `lwpt run smoke` — command: `instantfpc`; args: [0]=`scripts/smoke.pas`

### Manifest schema

Generated from the same immutable structural registry used by manifest validation. Domain-specific syntax and cross-field rules remain in the parser; see the project documentation for those details.

- `[package]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Package identity and Pascal unit roots.
  - `name`: string; optional; default: `unnamed`; invalid values are ignored as absent. Package name; the legacy root name fallback still warns.
  - `version`: string; optional; default: `0.0.0`; invalid values are ignored as absent. Package version.
  - `units`: array of strings; optional; default: `empty`; invalid values and items are skipped. Pascal unit-root paths.
- `[dependencies]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Named dependency declarations.
  - `<name>`: string or table; optional; other values retain legacy handling. Bare `<source>@<version>` shorthand or an inline table.
- `[dependencies].<name>` — string or inline table; all manifests; other values retain legacy handling; unknown keys are ignored. A source shorthand or expanded dependency declaration.
  - `source`: string; required; invalid values are errors. `owner/repo` (GitHub), `<host>:owner/repo` (built-in or custom host), an HTTPS tarball, a local path, or `workspace:<version>`.
  - `version`: string; optional; default: `none`; invalid values are ignored as absent. Version range, exact version, SHA, or tag.
  - `include`: array of strings; optional; default: `all files`; invalid values and items are skipped. Post-extraction include globs.
  - `exclude`: array of strings; optional; default: `none`; invalid values and items are skipped. Post-extraction exclude globs.
  - `repo`: retired; optional; invalid values are errors. Retired; any declaration is an error.
  - `ref`: retired; optional; invalid values are errors. Retired; any declaration is an error.
  - `tag`: retired; optional; invalid values are errors. Retired; any declaration is an error.
  - `asset`: retired; optional; invalid values are errors. Retired; any declaration is an error.
  - `path`: retired; optional; invalid values are errors. Retired; any declaration is an error.
  - `subdir`: retired; optional; invalid values are errors. Retired; use include globs.
- `[sources]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Named custom Git-host URL templates.
  - `<name>`: table; optional; invalid values are ignored as absent. One custom source declaration.
- `[sources].<name>` — inline table; all manifests; invalid values are ignored as absent; unknown keys are ignored. One custom Git-host source.
  - `archive`: string; required; invalid values are errors. HTTPS archive template containing {user}, {repository}, and {ref}.
  - `git`: string; required; invalid values are errors. HTTPS smart-HTTP template containing {user} and {repository}.
- `[workspaces]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Workspace discovery globs.
  - `include`: array of strings; optional; default: `empty`; invalid values and items are skipped. Workspace discovery globs.
  - `exclude`: array of strings; optional; default: `empty`; invalid values and items are skipped. Workspace exclusion globs.
- `[build]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Single-entry shorthand or named build entries.
  - `<name>`: string or table; optional; other values retain legacy handling. Named entry; build.source enables single-entry shorthand.
- `[build].<name>` — string or table; all manifests; other values retain legacy handling; unknown keys are ignored. One compiler-neutral build entry.
  - `source`: string; conditional; invalid values are ignored as absent. Compiler entry-point path.
  - `output`: string; optional; default: `build/<name>`; invalid values are ignored as absent. Published executable path.
  - `depends`: array of strings; optional; default: `empty`; invalid values are errors. Prerequisite build-entry names.
  - `flags`: array of strings; optional; default: `empty`; root manifest only; invalid values are errors. Ordered compiler-driver arguments.
  - `compiler`: string; optional; default: `[compiler].default`; root manifest only; invalid values are errors. Named compiler-profile override.
  - `target`: table; optional; default: `compiler native target`; root manifest only; invalid values are errors. Explicit target tuple.
  - `prebuild`: table; optional; default: `empty`; invalid values are ignored as absent. Per-entry prebuild command map.
  - `postbuild`: table; optional; default: `empty`; invalid values are ignored as absent. Per-entry postbuild command map.
- `[build].<name>.target` — table; root manifest only; invalid values are errors; unknown keys are errors. An explicit complete compiler target tuple.
  - `os`: string; required; invalid values are errors. Target operating system.
  - `architecture`: string; required; invalid values are errors. Target architecture.
  - `abi`: string; optional; default: `empty`; invalid values are errors. Optional target ABI.
  - `environment`: string; optional; default: `empty`; invalid values are errors. Optional target execution environment.
- `[compiler]` — table; root manifest only; invalid values are errors; unknown keys are ignored. Root-owned compiler profile selection.
  - `default`: string; optional; default: `host default`; invalid values are errors. Default profile name.
  - `profiles`: table; optional; default: `empty`; invalid values are errors. Named compiler-profile map.
- `[compiler.profiles].<name>` — table; root manifest only; invalid values are errors; unknown keys are ignored. One built-in or external compiler profile.
  - `driver`: string; required; invalid values are errors. Built-in or external driver identity.
  - `command`: string; optional; default: `driver default`; invalid values are errors. Direct compiler command.
  - `args`: array of strings; optional; default: `empty`; invalid values are errors. Ordered command arguments.
  - `version`: string; optional; default: `*`; invalid values are errors. Compiler version constraint.
  - `executable`: retired; optional; invalid values are errors. Retired; use command and args.
  - `script`: retired; optional; invalid values are errors. Retired; use command and args.
- `[version]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Generated version-include settings.
  - `output`: string; optional; default: `empty`; invalid values are ignored as absent. Generated include path.
  - `prefix`: string; optional; default: `BAKED`; invalid values are ignored as absent. Generated constant prefix.
- `[lwpt]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Toolkit-state path overrides.
  - `modules-dir`: string; optional; default: `toolkit default`; invalid values are ignored as absent. Installed-module directory override.
  - `archives-dir`: string; optional; default: `toolkit default`; invalid values are ignored as absent. Archive-cache directory override.
  - `tmp-dir`: string; optional; default: `toolkit default`; invalid values are ignored as absent. Private temporary directory override.
  - `sessions-dir`: string; optional; default: `toolkit default`; invalid values are ignored as absent. Private compiler-session directory override.
  - `cfg-file`: string; optional; default: `toolkit default`; invalid values are ignored as absent. Compiler response-file override.
- `[format]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Formatter scope additions and subtractions.
  - `include`: array of strings; optional; default: `empty`; invalid values and items are skipped. Formatter-scope additions.
  - `exclude`: array of strings; optional; default: `empty`; invalid values and items are skipped. Formatter-scope subtraction.
- `[analysis]` — table; all manifests; invalid values are errors; unknown keys are ignored. Shared Pascal analysis source scope.
  - `include`: array of strings; optional; default: `empty`; invalid values are errors. Analysis-scope additions.
  - `exclude`: array of strings; optional; default: `empty`; invalid values are errors. Analysis-scope subtraction.
- `[health]` — table; all manifests; invalid values are errors; unknown keys are errors. Optional complexity and hotspot limits.
  - `max-routine-cyclomatic`: integer; optional; default: `unset`; invalid values are errors. Non-negative routine cyclomatic limit.
  - `max-routine-cognitive`: integer; optional; default: `unset`; invalid values are errors. Non-negative routine cognitive limit.
  - `max-file-cyclomatic`: integer; optional; default: `unset`; invalid values are errors. Non-negative file cyclomatic limit.
  - `max-file-cognitive`: integer; optional; default: `unset`; invalid values are errors. Non-negative file cognitive limit.
  - `max-hotspot-score`: integer; optional; default: `unset`; invalid values are errors. Integer hotspot limit from 0 to 100.
- `[duplication]` — table; all manifests; invalid values are errors; unknown keys are ignored. Token-clone floor and optional percentage limit.
  - `minimum-tokens`: integer; optional; default: `100`; invalid values are errors. Clone floor; minimum accepted value is 25.
  - `maximum-percent`: integer; optional; default: `unset`; invalid values are errors. Integer duplication limit from 0 to 100.
- `[test]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Test compiler and scheduler policy.
  - `bail`: integer; optional; default: `0`; invalid values are errors. Non-negative failure count; zero runs the full queue.
  - `flags`: array of strings; optional; default: `empty`; root manifest only; invalid values are errors. Ordered test compiler arguments.
- `[preinstall] / [postinstall] / [prebuild] / [postbuild] / [pretest] / [posttest]` — table; root manifest only; invalid values are ignored as absent; unknown keys are ignored. Root lifecycle command maps.
  - `<name>`: string or table; optional; invalid values are errors. One lifecycle hook.
- `<hook entry>` — string or inline table; all manifests; invalid values are errors; unknown keys are errors. A direct command with optional staleness gating.
  - `command`: string; required; invalid values are errors. Direct child-process command.
  - `args`: array of strings; optional; default: `empty`; invalid values are errors. Ordered command arguments.
  - `inputs`: array of strings; conditional; default: `empty`; invalid values are errors. Non-empty staleness input globs.
  - `output`: string; conditional; default: `empty`; invalid values are errors. Staleness output, paired with inputs.
  - `script`: retired; optional; invalid values are errors. Retired; use command and args.
- `[<task-name>]` — table; root manifest only; invalid values are errors; unknown keys are errors. An otherwise-unknown top-level section carrying command.
  - `command`: string; required; invalid values are errors. Direct child-process command.
  - `args`: array of strings; optional; default: `empty`; invalid values are errors. Ordered command arguments.
  - `inputs`: array of strings; conditional; default: `empty`; invalid values are errors. Non-empty staleness input globs.
  - `output`: string; conditional; default: `empty`; invalid values are errors. Staleness output, paired with inputs.
  - `script`: retired; optional; invalid values are errors. Retired; use command and args.

<!-- lwpt:agents:end -->
