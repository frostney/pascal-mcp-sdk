# Contributing to pascal-mcp-sdk

This guide is for people changing the library itself. If you just want
to **use** pascal-mcp-sdk in your program, see the
[README](README.md) and [docs/guides/quick-start.md](docs/guides/quick-start.md) —
consumers never need the contributor toolchain.

**Start here:
[docs/internals/contributing.md](docs/internals/contributing.md)** —
the one path every change takes (setup, failing-test-first, where
code belongs, the local gate, PR ceremony), also rendered on the
[project site](https://frostney.github.io/pascal-mcp-sdk/docs/internals/contributing/).

The other contributor pages:

- [docs/internals/architecture.md](docs/internals/architecture.md) —
  layering, the sans-I/O core, spec grounding. Read this before
  touching protocol behaviour.
- [docs/internals/tooling.md](docs/internals/tooling.md) — lwpt, CI,
  hooks, changelog, website.
- [docs/internals/code-style.md](docs/internals/code-style.md) —
  naming, fpjson ownership discipline, FPC pitfalls.
- [docs/internals/releasing.md](docs/internals/releasing.md) —
  cutting releases.
- [docs/adr/](docs/adr/) — the decision records behind the ground
  rules.
- [DEFINITION_OF_READY.md](DEFINITION_OF_READY.md) /
  [DEFINITION_OF_DONE.md](DEFINITION_OF_DONE.md) — what makes work
  startable and finished here.

The 30-second version:

```sh
git clone https://github.com/frostney/pascal-mcp-sdk
cd pascal-mcp-sdk
lwpt install           # resolve deps (lwpt release binary on PATH)
lwpt build             # build/mcpdemo + build/mcpsmoke
lwpt test              # co-located unit suites
lwpt run smoke         # E2E battery
lwpt format --check    # formatter gate
```

Ground rules (the load-bearing ones — reasoning in `docs/adr/`):
FreePascal only (FPC 3.2.2, flags centralised in
`source/units/MCP.inc`); zero third-party runtime dependencies
(RTL + fpjson); `MCP.Server` owns the protocol surface, transports
move lines only; spec facts are verified against
[modelcontextprotocol.io](https://modelcontextprotocol.io), never
recalled.
