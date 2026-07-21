# interop-ts — official-SDK cross-check

Runs the **official MCP TypeScript clients** against `build/mcpdemo`
over real stdio — the reference-implementation net for pascal-mcp-sdk,
mirroring duetto's `tools/crosscheck.py` (which checks against the
Python `websockets` reference). Two batteries:

- **`interop.mjs`** — the v2 beta (`@modelcontextprotocol/client`,
  2026-07-28 RC), run twice: **pinned** to `2026-07-28` (modern era,
  no fallback — any nonconformance fails loudly) and in **`auto`**
  mode (the `server/discover` probe path; against a dual-era server it
  negotiates modern, proving capable clients get upgraded). The client
  also validates `structuredContent` against each tool's
  `outputSchema` on its side.
- **`legacy-interop.mjs`** — the v1 SDK (`@modelcontextprotocol/sdk`),
  the client library today's clients (Claude Code, Claude Desktop)
  are built on: full `initialize` handshake, tools, resources, and
  the era-correct `-32002` resource-not-found. Claude Code itself was
  additionally verified directly (`claude mcp add` + health check:
  Connected).

```sh
lwpt build                # produces build/mcpdemo
cd tools/interop-ts
npm ci
npm run interop           # v2-beta battery (pinned + auto) then v1 battery
```

The two SDK packages are exact-version pinned in `package.json`, and the
committed `package-lock.json` makes `npm ci` reproduce those resolutions. Each
battery prints both resolved package versions at startup so its output records
the implementation versions under test.

Requires Node ≥ 20. Runs in CI as the advisory `interop` job in
pr.yml (non-blocking as long as branch protection does not require
it; making it required is bundled with the post-final-spec pass).
Still worth running locally when touching the protocol surface.

Findings this harness already produced (2026-07-20, beta.4): the RC
wire schema requires a **top-level `serverInfo`** on `DiscoverResult`
and **`ttlMs` + `cacheScope`** on discover/list/read results — both
stricter than the prose spec pages suggested; see
docs/architecture.md.
