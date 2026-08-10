# Tooling

> **Audience: contributors.** This describes the library's internals and toolchain; consumers only need the [guides](../guides/quick-start.md) and [reference](../reference/server.md) sections.

## Executive Summary

lwpt is the single toolchain entry point: `install` resolves the one
dev-time dependency and regenerates `lwpt.cfg`/`lwpt.lock`, `build`
compiles the two apps, `test` runs the co-located suites, `format` is
the canonical formatter (wired into lefthook pre-commit), and
`agents` writes the machine-managed AGENTS.md command reference.
git-cliff generates CHANGELOG.md from Conventional Commits. CI gates
markdown (markdownlint), formatting and the AGENTS.md block
(`--check` modes), and reference-docs coverage. Everything also
works with plain `fpc @lwpt.cfg` because the dependency tree is
committed.

## lwpt

```sh
lwpt install           # resolve deps → lwpt.cfg + lwpt.lock + .lwpt/modules
lwpt install --frozen  # CI: verify lockfile + committed modules, no network
lwpt build             # every [build] target in lwpt.toml → build/
lwpt test              # discovers source/units/*.Test.pas
lwpt run smoke         # the built mcpsmoke E2E battery (scripts/smoke.pas)
lwpt format            # rewrite in place (pre-commit does this)
lwpt format --check    # CI gate: fail on drift
lwpt agents            # refresh the AGENTS.md command-reference block
lwpt agents --check    # CI gate: fail when that block is stale
```

- `lwpt.toml` is the **manifest you edit**: package metadata, the
  `units = ["source/units"]` path, the `[format]` exclude, the
  dev-time `testing` dependency, the two `[build]` targets, and the
  `[smoke]` run-script (`lwpt run smoke` → `scripts/smoke.pas`, a
  self-contained wrapper because run-scripts execute via InstantFPC
  without project include paths).
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
not in the hook. Override the binary with `PASCAL_MCP_SDK_LWPT=...` when
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

Four workflows (see [.github/workflows/](../../.github/workflows/)):

- **pr.yml** — every PR: Linux + macOS + Windows legs, each doing
  checksum-verified lwpt release install, `lwpt install --frozen`
  (online install on Windows — the frozen-install skip tracks
  lwpt#168), then `build`, `test`, and the `mcpsmoke` E2E battery.
  One leg additionally runs the platform-independent gates:
  `lwpt format --check`, `lwpt agents --check`, and
  `.github/scripts/check-reference-docs.sh` (every public
  `MCP*`/`Register*` symbol must appear in `docs/reference/`). Plus
  a blocking markdownlint job and the required `interop` job (below).
- **ci.yml** — push to main: the same battery as the post-merge
  confirmation signal.
- **pr-title.yml** — Conventional Commit PR-title gate (squash-merge
  titles become the changelog).
- **pages.yml** — website build/deploy; see the Website section.

## Cross-implementation check — tools/interop-ts

The official stable MCP TypeScript clients run against
`build/mcpdemo` — the v2 client over stdio (pinned-`2026-07-28` and
`auto`-probe modes) and over Streamable HTTP, plus the v1 SDK's
legacy handshake (see
[tools/interop-ts/README.md](../../tools/interop-ts/README.md)). Runs in
CI as the **required** `interop` job on every PR: a red interop job
is a real cross-implementation regression. Each battery prints the
resolved versions at startup. Still worth running locally whenever
the protocol surface changes.

## Website — website/

The project site (<https://frostney.github.io/pascal-mcp-sdk/>) is a
[Fumadocs](https://fumadocs.dev) (Next.js) static export under
`website/`, adopted wholesale from the frostney/lwpt#90 decision
record: landing page + docs site in one deployment, `basePath`
`/pascal-mcp-sdk`, built-in search, **no analytics**. The site
renders the repository's `docs/` tree **directly** — no curated
second copy; only landing-page content and glue live under
`website/`. Two remark plugins process the markdown:
`remark-repo-links` maps repo-relative links (links within `docs/`
become site routes, links leaving the rendered set resolve to their
GitHub URLs, images under `docs/images/` map to the synced
`public/docs-images/` copy, and a broken mapping **fails the
build**), and `remark-term-links` auto-links the first occurrence
per page of well-known tooling terms. A `prebuild`/`predev` script
syncs `docs/images/` into `public/`; the app also emits the SEO/AEO
surfaces (sitemap, robots, per-page OG images, `llms.txt` /
`llms-full.txt`, JSON-LD).
Deployment is `.github/workflows/pages.yml` (official
`configure-pages` / `upload-pages-artifact` / `deploy-pages`
actions): pushes to `main` touching `website/**` or `docs/**` deploy;
PRs touching those paths build without deploying. The Node toolchain
is contributor/CI tooling only (precedent: `tools/interop-ts`) and
never touches the shipped library or its RTL + fpjson dependency
policy. **Node pin: 24** (`actions/setup-node` in pages.yml; the interop
job in pr.yml pins its own Node 20).
