# interop-ts — official-SDK cross-check

Runs the **official MCP TypeScript client** (`@modelcontextprotocol/client`,
the 2026-07-28 RC beta) against `build/mcpdemo` over real stdio — the
reference-implementation net for pascal-mcp, mirroring duetto's
`tools/crosscheck.py` (which checks against the Python `websockets`
reference).

The battery runs twice: once **pinned** to `2026-07-28` (modern era,
no fallback — any nonconformance fails loudly) and once in **`auto`**
mode (the `server/discover` probe path a dual-era client uses in the
wild). The client also validates `structuredContent` against each
tool's `outputSchema` on its side.

```sh
lwpt build                # produces build/mcpdemo
cd tools/interop-ts
npm install
npm run interop
```

Requires Node ≥ 20. Not wired into CI while the SDK is in beta (its
API may still shift); run it manually when touching the protocol
surface, and revisit wiring it into ci.yml once the SDK is stable.

Findings this harness already produced (2026-07-20, beta.4): the RC
wire schema requires a **top-level `serverInfo`** on `DiscoverResult`
and **`ttlMs` + `cacheScope`** on discover/list/read results — both
stricter than the prose spec pages suggested; see
docs/architecture.md.
