# Handoff

Updated: 2026-07-20 (session: initial scaffold, branch `scaffold-v1-stdio`)

## Current task

Scaffold pascal-mcp — FreePascal-native MCP server library, lwpt
sibling of duetto — **complete and verified locally**. Five commits on
`scaffold-v1-stdio` off `main`, not pushed (no push/PR without
explicit maintainer go-ahead).

## State: everything green

```text
lwpt install --frozen   ✅ archive + tree hashes verified
lwpt format --check     ✅ 9 files, no drift
lwpt build              ✅ mcpdemo + mcpsmoke
lwpt test               ✅ 4 suites / 45 tests
./build/mcpsmoke        ✅ 19 E2E checks vs the real subprocess
markdownlint            ✅ 0 issues
no-lwpt path            ✅ fpc @lwpt.cfg -FEbuild source/apps/mcpdemo.pas
                           compiles and serves (live add→42 verified)
```

## What was built

- **Library** (`source/units/`, layered bottom-up, sans-I/O core):
  `MCP.JsonRpc` (JSON-RPC 2.0, MCP profile: no batching, no null ids)
  → `MCP.Protocol` (per-request `_meta`, -32602/-32021/-32022,
  result stamping) → `MCP.Server` (registries + `HandleMessage`
  dispatch: server/discover, tools/list+call, resources/list+read,
  initialize rejection naming supported versions) →
  `MCP.Transport.Stdio` (LF framing, CR tolerance, EOF = shutdown).
  Runtime deps: RTL + fpjson only. Tests co-located per unit.
- **Apps**: `mcpdemo` (echo + add + static resource),
  `mcpsmoke` (TProcess E2E battery — CI's smoke leg).
- **Governance**: AGENTS.md (+CLAUDE.md symlink), VISION.md, DoR, DoD,
  README (incl. "Using pascal-mcp without lwpt"), docs/ ×5 with
  Executive Summaries.
- **Tooling**: lefthook (PASCALMCP_LWPT override), cliff.toml +
  generated CHANGELOG.md, markdownlint, editorconfig, lwpt-convention
  .gitignore.
- **CI**: pr.yml (Linux/macOS/win64 + docs job + no-lwpt leg), ci.yml
  (wider per-arch matrix). Adapted from duetto; wsinterop/Autobahn
  legs dropped, `fcl-json` added to Windows FPC unit paths.
- **Skills**: 13 installed (`known-good-route` ×9, `mattpocock` ×4)
  → `.agents/skills/` + `.claude/skills` symlink + skills-lock.json.

## Decisions made (and why)

1. **Spec status nuance discovered during grounding** (2026-07-20):
   the current *ratified* MCP revision is **2025-11-25**; `2026-07-28`
   is the **locked release candidate** — final text ships July 28,
   2026, i.e. 8 days after this session. The library targets
   2026-07-28 per the ADR decision; sources cited in
   docs/architecture.md. **Follow-up: re-verify against the final text
   once published; RC drift = `fix(protocol)`.**
2. **Modern-only server** — legacy `initialize` gets the
   spec-recommended diagnostic naming supported versions; dual-era is
   a documented follow-up seam (`ExtractRequestContext` supported-list
   + a legacy branch in `DispatchRequest`), not implemented.
3. **API shape** (in lieu of a grill session; documented in
   docs/architecture.md + code-style.md): synchronous handlers, both
   plain-function and `of object` overloads; tool schemas as JSON
   strings validated at registration; execution errors in-band
   (`isError: true`, incl. handler exceptions), protocol errors as
   JSON-RPC errors; registries fixed after startup (hence no
   listChanged/subscriptions in v1).
4. **Dev-time deps: `testing` only** — duetto's `cli` package skipped;
   the apps take no flags. Add it only when an app grows real parsing.
5. **v1 scope fences**: no pagination cursors, no MRTR
   `input_required`, no JSON-Schema argument validation, no
   subscriptions — all recorded in VISION.md not-goals / MCP.Server
   header.

## Open questions

- **Push + PR**: awaiting maintainer go-ahead. Suggested PR title:
  `feat: v1 stdio MCP server library (stateless 2026-07-28 spec)`.
- **GitHub repo**: no remote configured yet (`frostney/pascal-mcp`
  presumably; create + `git push -u origin` when authorized).
- **lwpt CI asset names** assume the same release layout as duetto's
  workflows (they were copied verbatim on that point) — will be proven
  on first CI run.
- **release.yml/toolchain.yml** not mirrored (brief: only if a release
  flow is wanted now).

## Next steps

1. Get go-ahead → push branch, open PR, watch the three pr.yml legs.
2. After 2026-07-28: re-verify spec surface against the final text.
3. Follow-up milestones, in rough order: Streamable HTTP transport
   (`MCP.Transport.Http`, default `fphttpserver`; TransportSecurity /
   StringBuffer from lwpt httpclient as building blocks), dual-era
   support decision, subscriptions/listen + listChanged if registries
   ever become dynamic, lantaarn adoption as first consumer.
