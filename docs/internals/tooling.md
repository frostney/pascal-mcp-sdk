# Tooling

> **Audience: contributors.** This describes the library's internals and toolchain; consumers only need the [guides](../guides/quick-start.md) and [reference](../reference/server.md) sections.

## Executive Summary

lwpt is the single toolchain entry point: `install` resolves the one
dev-time dependency and regenerates `lwpt.cfg`/`lwpt.lock`, `build`
compiles the apps the manifest's `[build]` table lists, `test` runs the co-located suites, `format` is
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
lwpt test source/units/MCP.Server.Test.pas  # one test file (paths and globs select)
lwpt test --inventory  # each test program's suite and case counts
lwpt run smoke         # the built mcpsmoke E2E battery (scripts/smoke.pas)
lwpt format            # rewrite in place (pre-commit does this)
lwpt format --check    # CI gate: fail on drift
lwpt agents            # refresh the AGENTS.md command-reference block
lwpt agents --check    # CI gate: fail when that block is stale
lwpt health            # CI gate: complexity vs the [health] ceilings
lwpt duplication       # CI gate: clones vs the [duplication] ceiling
```

- `lwpt.toml` is the **manifest you edit**: package metadata, the
  `units = ["source/units"]` path, the `[format]` exclude, the
  dev-time `testing` dependency, the `[build]` targets, and the
  `[smoke]` run-script (`lwpt run smoke` → `scripts/smoke.pas`, a
  self-contained wrapper because run-scripts execute via InstantFPC
  without project include paths).
- `lwpt.cfg` and `lwpt.lock` are **generated — never hand-edit**.
  `lwpt.cfg` doubles as the no-lwpt entry point
  (`fpc @lwpt.cfg ...`).
- `.lwpt/modules/` + `.lwpt/archives/` are **committed** (zero-install);
  `.lwpt/tmp/`, `.lwpt/sessions/`, `.lwpt/install.lock` are ignored.

## Dependency policy

Runtime: **FPC-shipped packages only — RTL, fpjson, fcl-base
(`base64`), and fcl-web confined to `MCP.Transport.HTTP`. Nothing
else** ([ADR-0003](https://github.com/frostney/pascal-mcp-sdk/blob/main/docs/adr/0003-zero-third-party-runtime-dependencies.md)).
This is a hard constraint (AGENTS.md); it is what makes the library
trivially vendorable and the no-lwpt path a one-liner. Dev-time: lwpt's `testing` package only.
Any other dev-time package, such as duetto's `cli` should an app ever
need real flag parsing (`mcpdemo`/`mcpsmoke` deliberately have none),
is a future decision: it needs maintainer approval and an ADR first.

## Hooks — lefthook

`lefthook install` once per clone. Pre-commit runs `lwpt format` on
staged Pascal/TOML files and re-stages what it rewrites
(`stage_fixed: true`). Heavy gates (build, test, mcpsmoke) live in CI,
not in the hook. Override the binary with `PASCAL_MCP_SDK_LWPT=...` when
lwpt is not on PATH.

Commit-msg runs `.github/scripts/check-pr-title.py --commit-msg` on
the message git is about to record. Its subject must be a Conventional
Commit of a `cliff.toml` type, the same rule as the required
`conventional-title` check. The hook sees the message before git
cleans it up, so it cleans it up as git will, with `git stripspace`
and git's own `commit.cleanup` and comment string: comment lines go
under `strip`, and under the default cleanup only when an editor
opened (`git commit -m` keeps a `#` line); an edited message ends at
the scissors line under `commit.cleanup=scissors` or `commit.verbose`.
The subject is the first line that is not blank. Options on the command
line, such as `--cleanup` or `-v`, are not visible to the hook.

Subjects starting with `fixup!`, `squash!` or `amend!` and a space, or
with the word `Merge`, pass, since an autosquash rebase or the squash
merge folds them away; CI still checks a PR whose only commit carries
one. A refused commit is not made: the checker prints the file holding
its message. Run the same commit again with `-m` or `-F` replaced by
`-e -F` and that file, keeping its other options and paths, to reopen
it; a commit made with `-C <commit>` keeps that commit's author when
run again with `-c <commit>`. A plain `git revert` or `git cherry-pick` commits with
`-n`, so no hook runs; one that stopped on a conflict runs the hook
when continued, and refuses a `Revert "…"` subject, which wants a
`revert:` one. The hook needs `python3` on PATH, and a repository path
without a `'`. The checker's tests run with
`python3 -m unittest discover -s .github/scripts -p 'test_*.py'`; those
for `core.commentString` skip on git older than 2.45. It does not replace
the CI check: the PR title is written on GitHub, and a hook runs only
where `lefthook install` was run.

## Changelog — git-cliff

`cliff.toml` maps Conventional Commit types straight to sections
(feat → New Features, fix → Bug Fixes, perf/docs grouped, the rest
Internal). Regenerate with `git-cliff -o CHANGELOG.md`; preview the
next release's entries with `git-cliff --unreleased --strip header`.
CHANGELOG.md is generated — do not hand-edit entries.

## Markdown — markdownlint-cli2

`.markdownlint-cli2.jsonc` mirrors the sibling repos: ATX headings,
2-space list indent, fenced code blocks with language tags; long lines
allowed, bare URLs not (MD034 — write explicit links). CI runs it via
`DavidAnson/markdownlint-cli2-action`; locally:

```sh
npx markdownlint-cli2 "**/*.md"
```

## CI

Six workflows (see [.github/workflows/](../../.github/workflows/)).
The checks a PR needs to merge are listed in
[Contributing § Open the PR](contributing.md#open-the-pr).

- **pr.yml** — every PR: Linux + macOS + Windows legs, each doing
  checksum-verified lwpt release install, `lwpt install --frozen`,
  then `build`, `test`, and the `mcpsmoke` E2E battery. The Windows
  leg installs FPC 3.2.2 itself; the Linux and macOS legs take the FPC
  that apt and Homebrew offer, which the library supports as 3.2.2. A
  further Linux leg does the same on FPC 3.2.4-rc2, installed with
  [frostney/fpc-toolchain](https://github.com/frostney/fpc-toolchain)
  pinned by commit, and is not a required check. The Linux legs
  run `test` and `mcpsmoke` a second time under `LC_ALL=C` (the build
  is not repeated there), where the
  locale's code page is US-ASCII (#102); reproduce it with
  `LC_ALL=C lwpt test && LC_ALL=C ./build/mcpsmoke`.
  One leg additionally runs the platform-independent gates:
  `lwpt format --check`, `lwpt agents --check`, and
  `.github/scripts/check-reference-docs.sh` (every
  `MCP*`/`Register*` function or procedure in the interface of
  `MCP.Server` and `MCP.Content` must appear in `docs/reference/`). Plus
  the markdownlint job (the required `docs` check), and the required
  `interop` and `conformance` jobs (both below).
- **ci.yml** — push to main and manual dispatch: the wider native
  matrix (Linux x64 and arm64, macOS arm64 and x64, Win64 and Win32)
  as the post-merge confirmation signal; it does not run the
  conformance job.
- **pr-title.yml** — the required `conventional-title` check: the PR
  title, and on a single-commit PR the commit subject, must be a
  Conventional Commit (the squash commit's subject becomes the
  changelog entry; see
  [Contributing § Open the PR](contributing.md#open-the-pr)).
- **pages.yml** — website build/deploy; see the Website section.
- **lwpt-bump.yml** — weekly (Mondays) and on demand: opens a PR
  when the Homebrew tap's lwpt is newer than the pin, carrying the
  complete bump (the pin, the regenerated lockfile, zero-install trees
  and AGENTS.md command block). A failing run means the new release
  needs a migration by hand. CI on the PR it opens waits for a
  maintainer's **Approve workflows to run**.
- **update-project-skills.yml** — weekly (Mondays) and on demand: a
  thin caller of known-good-route's reusable workflow that refreshes
  the skills `skills-lock.json` lists and opens a draft PR when they
  changed. A skill deleted or renamed upstream stops the run until it
  is migrated by hand. As with the lwpt bump, CI on that PR waits for
  **Approve workflows to run**.

The lwpt pin is the exact version of the `testing` dependency in
`lwpt.toml`: the test framework comes from the same lwpt release tag
as the toolchain, and every workflow installs that release
(`.github/scripts/lwpt-version.sh` reads it).

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

## Official conformance suite — tools/conformance

`tools/conformance/run.mjs` starts the conformance fixture,
`build/mcpconformance --http`, on a free localhost port and runs the
official
[MCP conformance suite](https://github.com/modelcontextprotocol/conformance)
in server mode against it, pinned exactly to the npm pre-release
`@modelcontextprotocol/conformance@0.2.0-alpha.12`. The latest stable
release (0.1.16) predates the 2026-07-28 stateless lifecycle: it opens
every scenario with `initialize`, which the binding rejects, so 1 of
its 31 checks passes. The runner runs the suite's requirement set for
2026-07-28 (`--requirements 2026-07-28`): the scenarios that revision
requires, at its stateless wire, plus the extension and pending
scenarios the suite runs without scoring. Run it locally with
`lwpt build && lwpt run conformance` (Node 22 or later; npx fetches the
suite from the npm registry). Each run writes its per-scenario
`checks.json` files into a new directory of its own under
`build/conformance/` and prints it; the runner never deletes anything,
so concurrent runs cannot touch each other's evidence.

lwpt run tasks take no arguments, so a narrower run calls the runner
directly, for example
`node tools/conformance/run.mjs build/mcpconformance --scenario tools-list`.
`--scenario` (in either `--opt value` or `--opt=value` form) runs the
named scenarios at the baseline's revision, extension scenarios
included (with `--force`, as the requirement set runs them); `--suite`
runs a suite at that revision, which leaves extension scenarios out.
Nothing then counts as added or removed, and scenarios the baseline
does not list are printed as not judged. `--requirements` and
`--spec-version` may name only the baseline's revision, and
`--requirements` does not combine with a selection. The runner owns
`--url`, `--output-dir` and `--expected-failures`.

The run is judged against the committed baseline,
`tools/conformance/baseline.json`. It records the pinned suite version,
the requirement set, and the expected outcome of every scenario: `pass`
(a check succeeded and none failed), `fail` (a check failed) or `skip`
(every check was skipped or informational), each failure or skip with
its tracking issue. The suite can report one check id several times,
once per probe or subcase; as in the suite, the id fails when any
report does and passes only when none fails. A scenario may also list
`passingChecks`: check ids that must keep passing even though the
scenario as a whole is expected to fail. A malformed baseline (an
unknown expectation, a failure without an issue, a version that is not
exact) stops the run before the suite starts. Once results exist,
`run.mjs` exits 1 when the run differs from the baseline, and the
suite's own exit code is not used:

- **Regression**: a scenario fails, or is no longer tested, where the
  baseline expects otherwise; a scenario the baseline does not list
  fails; or a check in `passingChecks` no longer passes.
- **Stale baseline**: a scenario the baseline expects to fail or skip
  now passes, or a check not in `passingChecks` now passes. Update
  `baseline.json` in the same PR.
- **Added or removed**: the suite ran a scenario the baseline does not
  list, or skipped one it does.
- **Unreadable**: a scenario's `checks.json` is missing, malformed, an
  empty array, has an entry without an id or with a status other than
  `SUCCESS`, `FAILURE`, `WARNING`, `INFO` or `SKIPPED`, or appears
  twice. This fails the run instead of counting as an outcome.

The rules live in `tools/conformance/compare.mjs`, covered by
broken-input tests (`compare.test.mjs`); `run.test.mjs` drives
`run.mjs` end to end with a stand-in server and suite. The CI job runs
both before the suite: `node --test tools/conformance/compare.test.mjs
tools/conformance/run.test.mjs`.

The suite's own exit code counts only when it is neither 0 nor 1 (its
two ordinary results): anything else, a signal included, means the
suite was interrupted or could not run, and fails the run. Operational
errors also exit non-zero: 2 for usage (a missing server argument,
another revision, a runner-owned option, an existing results
directory) or an invalid baseline, 1 if the server does not start (it
is stopped first) or no results were produced. Interrupted itself, the
runner stops the suite and the server before it exits.

It prints a summary of every difference. Bumping the suite version
means updating the baseline in the same change.

`baseline.json` is the current state: every expected failure or skip
names the issue that tracks it, so the open issues it lists are the
library's known conformance gaps. The suite runs against the
conformance fixture, `source/apps/mcpconformance.pas`, which registers
the tools, prompts and resources the suite's reference fixture
registers, by the same names and through the public API only, so a
scenario fails only on a gap in the library.

CI runs it as the **required** `conformance` job on every PR and
uploads the results as the `conformance-results` artifact. The job
fails the PR workflow whenever the run differs from the baseline, in
either direction. Every scenario the suite scores passes, and so do
the nine Tasks extension scenarios it runs; `tasks-status-notifications`
is an expected skip (#138), since the suite skips it whatever the
server does.
Only the HTTP binding is covered: the stdio binding is not exercised
here.

## Website — website/

The project site (<https://frostney.github.io/pascal-mcp-sdk/>) is a
[Fumadocs](https://fumadocs.dev) (Next.js) static export under
`website/`, adopted wholesale from the frostney/lwpt#90 decision
record: landing page + docs site in one deployment, `basePath`
`/pascal-mcp-sdk`, built-in search, **no analytics**.

- **The site renders the repository's `docs/` tree directly** — no
  curated second copy; only landing-page content and glue live under
  `website/`. Repo-only records under `docs/` (the ADRs) are excluded
  in `website/lib/source.ts`.
- **Markdown pipeline** (`website/lib/source.ts`): the Markdown
  options are wrapped in fumadocs-mdx's `applyMdxPreset` — the docs
  macro applies no preset by itself, and without it tables, heading
  ids and the table of contents are lost — plus four site plugins:
  - `remark-casts` turns links to `.cast` files into the terminal
    player. It runs before `remark-repo-links`, which would otherwise
    route a `.cast` path as a page.
  - `remark-repo-links` maps repo-relative links — links within
    `docs/` become site routes, links leaving the rendered set
    resolve to their GitHub URLs, images under `docs/images/` map to
    the synced `public/docs-images/` copy, and a broken mapping
    **fails the build**.
  - `remark-term-links` auto-links the first occurrence per page of
    well-known tooling terms.
  - `rehype-mermaid-dual` renders ```` ```mermaid ```` fences to
    themed inline SVGs at build time (light + dark, toggled by the
    site theme; headless Chromium via playwright). No mermaid JS
    ships to the client, and the same fences render natively on
    GitHub.
- **Terminal recordings**: `.cast` files under `docs/casts/` play
  through a self-hosted asciinema-player wrapper (no CDN); the
  recordings are real captures of the built binaries — see
  `tools/casts/`.
- A `prebuild`/`predev` script syncs `docs/images/` into `public/`;
  the app also emits the SEO/AEO surfaces (sitemap, robots, per-page
  OG images, `llms.txt` / `llms-full.txt`, JSON-LD).
- **Post-build check**: `scripts/check-export.mjs` fails the build
  unless each page's output matches its `docs/` source: its tables
  render, every heading has an id and its table of contents lists the
  h2 and h3 headings, every in-site link, anchor and search result is
  served, its Mermaid fences rendered to SVG and its casts have their
  player and recording, and its page actions, JSON-LD, sitemap entry,
  `llms.txt` entry and Markdown copy name its own URL, with only
  absolute URLs in `llms.txt`, `llms-full.txt` and the copies. No ADR
  reaches the export.
- **Deployment** is `.github/workflows/pages.yml` (official
  `configure-pages` / `upload-pages-artifact` / `deploy-pages`
  actions): pushes to `main` touching `website/**` or `docs/**`
  deploy; PRs touching those paths build without deploying.
- The Node toolchain is contributor/CI tooling only (precedent:
  `tools/interop-ts`) and never touches the shipped library or its
  FPC-shipped runtime dependency policy. **Node pin: 24**
  (`actions/setup-node` — both pages.yml and the interop job in
  pr.yml).
