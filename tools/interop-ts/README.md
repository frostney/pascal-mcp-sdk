# interop-ts — official-SDK cross-check

Runs the **official MCP TypeScript clients** against `build/mcpdemo`
over real stdio — the reference-implementation net for pascal-mcp-sdk,
mirroring duetto's `tools/crosscheck.py` (which checks against the
Python `websockets` reference). Three batteries over one shared module:

- **`battery.mjs`** — the modern (2026-07-28) battery itself, plus the
  version banner and check accounting every script shares. It lives
  here exactly once, so the stdio and Streamable HTTP runs assert an
  identical surface and cannot drift apart.
- **`interop.mjs`** — the stable v2 client
  (`@modelcontextprotocol/client` 2.0.0, the 2026-07-28 client), run
  twice: **pinned** to `2026-07-28` (modern era,
  no fallback — any nonconformance fails loudly) and in **`auto`**
  mode (the `server/discover` probe path; against a dual-era server it
  negotiates modern, proving capable clients get upgraded). The client
  also validates `structuredContent` against each tool's
  `outputSchema` on its side.
- **`http-interop.mjs`** — the same stable v2 client over **Streamable
  HTTP**: spawns `mcpdemo --http` on a free localhost port, waits for
  the port to actually accept connections, and runs the same battery
  via real POSTs, adding a progress check that only passes when the
  server streams request-scoped notifications on the SSE response
  before the final result.
- **`legacy-interop.mjs`** — the v1 SDK (`@modelcontextprotocol/sdk`),
  the client library today's clients (Claude Code, Claude Desktop) are
  built on. It stays a battery of its own because the era genuinely
  differs — full `initialize` handshake, tools, resources, and the
  era-correct `-32002` resource-not-found — but shares the same helpers.
  Claude Code itself was additionally verified directly
  (`claude mcp add` + health check: Connected).

```sh
lwpt build                # produces build/mcpdemo
cd tools/interop-ts
npm ci
npm run interop           # v2 stdio (pinned + auto), v1, then v2 over HTTP
```

The two SDK packages are exact-version pinned in `package.json`, and the
committed `package-lock.json` makes `npm ci` reproduce those resolutions. Each
battery prints the resolved version of the client it drives at startup, so its
output records the implementation version under test.

Requires Node ≥ 20. Runs in CI as the `interop` job in pr.yml
(a required PR gate since the post-final-spec pass upgraded the pins
to the stable SDKs). Still worth running locally when touching the
protocol surface.

Findings this harness already produced (2026-07-20, on the
beta client; confirmed unchanged on stable 2.0.0, 2026-08-08): the
wire schema requires a **top-level `serverInfo`** on `DiscoverResult`
and **`ttlMs` + `cacheScope`** on discover/list/read results — both
stricter than the prose spec pages suggested; see
docs/architecture.md.
