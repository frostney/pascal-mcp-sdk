# Tooling

## Executive Summary

lwpt is the single toolchain entry point: `install` resolves the one
dev-time dependency and regenerates `lwpt.cfg`/`lwpt.lock`, `build`
compiles the two apps, `test` runs the co-located suites, `format` is
the canonical formatter (wired into lefthook pre-commit). git-cliff
generates CHANGELOG.md from Conventional Commits; markdownlint gates
the docs in CI. Everything also works with plain `fpc @lwpt.cfg`
because the dependency tree is committed.

## lwpt

```sh
lwpt install           # resolve deps → lwpt.cfg + lwpt.lock + .lwpt/modules
lwpt install --frozen  # CI: verify lockfile + committed modules, no network
lwpt build             # every [build] target in lwpt.toml → build/
lwpt test              # discovers source/units/*.Test.pas
lwpt format            # rewrite in place (pre-commit does this)
lwpt format --check    # CI gate: fail on drift
```

- `lwpt.toml` is the **manifest you edit**: package metadata, the
  `units = ["source/units"]` path, the `[format]` exclude, the
  dev-time `testing` dependency, and the two `[build]` targets.
- `lwpt.cfg` and `lwpt.lock` are **generated — never hand-edit**.
  `lwpt.cfg` doubles as the no-lwpt entry point
  (`fpc @lwpt.cfg ...`).
- `.lwpt/modules/` + `.lwpt/archives/` are **committed** (zero-install);
  `.lwpt/tmp/`, `.lwpt/sessions/`, `.lwpt/install.lock` are ignored.

## Dependency policy

Runtime: **RTL + fpjson. Nothing else.** This is a hard constraint
(AGENTS.md); it is what makes the library trivially vendorable and the
no-lwpt path a one-liner. Dev-time: lwpt's `testing` package only.
duetto's `cli` package joins only if an app grows real flag parsing —
`mcpdemo`/`mcpsmoke` deliberately have none.

## Hooks — lefthook

`lefthook install` once per clone. Pre-commit runs `lwpt format` on
staged Pascal/TOML files and re-stages what it rewrites
(`stage_fixed: true`). Heavy gates (build, test, mcpsmoke) live in CI,
not in the hook. Override the binary with `PASCALMCP_LWPT=...` when
lwpt is not on PATH.

## Changelog — git-cliff

`cliff.toml` maps Conventional Commit types straight to sections
(feat → New Features, fix → Bug Fixes, perf/docs grouped, the rest
Internal). Regenerate with `git-cliff -o CHANGELOG.md`; preview the
next release's entries with `git-cliff --unreleased --strip header`.
CHANGELOG.md is generated — do not hand-edit entries.

## Markdown — markdownlint-cli2

`.markdownlint-cli2.jsonc` mirrors the sibling repos: ATX headings,
2-space list indent, fenced code blocks with language tags; long lines
and bare URLs allowed. CI runs it via
`DavidAnson/markdownlint-cli2-action`; locally:

```sh
npx markdownlint-cli2 "**/*.md"
```

## CI

Two workflows, mirroring duetto's split (see
[.github/workflows/](../.github/workflows/)):

- **pr.yml** — every PR: Linux + macOS + Windows legs, each doing
  checksum-verified lwpt release install, `lwpt install --frozen`
  (online install on Windows — lwpt#78), `format --check` (one leg),
  `build`, `test`, and the `mcpsmoke` E2E battery; plus a blocking
  markdownlint job.
- **ci.yml** — push to main: the same battery as the post-merge
  confirmation signal.

## Cross-implementation check — tools/interop-ts

The official MCP TypeScript client beta run against `build/mcpdemo`
over stdio, in both pinned-`2026-07-28` and `auto`-probe modes (see
[tools/interop-ts/README.md](../tools/interop-ts/README.md)). Manual
for now (the SDK is beta); run it whenever the protocol surface
changes.
