# Changelog

All notable changes to pascal-mcp-sdk are documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); entries are generated from Conventional Commits by git-cliff.
## [3.0.0] - 2026-11-28

### Breaking Changes

- set server, resource, prompt and tool metadata and handler _meta (#112)
- validate x-mcp-header annotations and Mcp-Param headers (#105)
- keep strings and the wire UTF-8 under any locale (#104)
- seal requestState with HMAC-SHA-256 before handlers see it (#103)
- accept any outputSchema root and check structured output (#101)

### Bug Fixes

- run stream timers on a monotonic clock on macOS (#135)
- step new stdio streams at once and make their cancel test order-based (#133)
- gate input requests on elicitation modes and sampling.tools (#116)
- answer a request missing required _meta with 400 (#99)
- settle stack #54's review: exact wire numbers, one lwpt pin, site and docs corrections (#85)
- render tables and heading anchors, and give llms files absolute URLs (#78)

### Documentation

- list the FPC 3.2.4-rc2 leg as a required check (#137)
- refresh wire captures, mark deprecations, fix drift (#129)
- list conformance as a required check (#123)
- name the library on existing citation surfaces (#61)
- gold-standard docs overhaul — diagrams, real casts, restored website pipeline (#53)
- import AGENTS.md through a regular CLAUDE.md (#73)
- consumer-first website overhaul, lwpt agents adoption, and verified client-era captures (#48)
- promote audit retro lessons into DoD and code style (#47)
- promote 2.0.0 retrospective lessons into the project contracts (#41)

### Internal

- build and test with FPC 3.2.4-rc2 on every PR (#131)
- check commit subjects locally with a commit-msg hook (#125)
- migrate the four skills removed upstream and refresh the rest (#86)
- upgrade lwpt to 0.10.0 (#71)
- run the official MCP conformance suite as a non-blocking PR job (#69)
- adopt lwpt 0.6.0 analysis gates and test selectors (#59)
- weekly lwpt release bump with full regeneration (#58)
- weekly automated refresh of lock-managed agent skills (#57)
- upgrade lwpt to 0.6.0 (#56)
- rename Shared.inc to MCP.inc and trim implied directives (#52)
- restore install --frozen on the Windows legs (#50)
- give matrix jobs stable display names (#51)
- upgrade lwpt to 0.5.1 and drop test ExitCode boilerplate (#49)
- apply 2026-08-09 codebase-audit remediation (#45)
- refresh project skills and add codebase-audit (#43)
- require Conventional Commit PR titles (#40)

### New Features

- serve subscriptions/listen with task status notifications (#141)
- serve the Tasks extension (#140)
- serve the Events extension's push delivery (#127)
- serve the Events extension's poll delivery (#121)
- load Skills from a directory on disk (#120)
- serve the Skills extension (#119)
- negotiate extensions and serve MCP Apps UIs (#114)
- add an in-process test client and a testing guide (#113)
- paginate list methods with opaque cursors (#111)
- deliver cancellation to running handlers on stdio and HTTP (#110)
- let tools declare the client capabilities they need (#109)
- declare enums, defaults, arrays and nested objects (#107)
- answer completion/complete and make conformance blocking (#106)
- let handlers answer with a JSON-RPC error of their choosing (#100)
- build every content type and run conformance against a fixture (#92)
- compact JSON numbers on the wire (#55)
- MCPImageResult — image content blocks from bytes or base64 (#44)

## [2.0.0] - 2026-08-09

### Breaking Changes

- validate raw tool arguments against the registered schema subset (#38)

### Bug Fixes

- drop invalid notification-shaped messages instead of replying -32600 (#38)
- make Build-reuse detection survive record copies (#38)

### Documentation

- add FPC pitfalls section to code-style guide (#37)
- split README and docs by audience — consumers vs contributors (#38)

### Internal

- install run-retro skill from known-good-route (#36)
- post-final-spec pass — re-verify 2026-07-28 final, stable SDK interop, require interop in CI (#38)

### New Features

- Streamable HTTP binding — MCP.Transport.HTTP with SSE response streams (#38)
- MRTR input_required — result-driven re-entry for tools and prompts (#38)
- GitHub Pages site — Fumadocs landing page + rendered docs (#38)

## [1.2.0] - 2026-07-21

### Internal

- run the tools/interop-ts batteries as a non-blocking PR job (#32)

### New Features

- v1.2.0 concurrent core — state split into three lifetimes, cooperative cancellation (#34)

## [1.1.0] - 2026-07-21

### New Features

- v1.1.0 hardened contracts — registration guards, disclosure flag, lifecycle state machine (#30)

## [1.0.1] - 2026-07-20

### Bug Fixes

- v1.0.1 wire correctness — UTF-8, version matrix, params guards, logLevel, RTTI ranges, URI templates, demo contract, interop pins (#25)

### Documentation

- fold 2026-07-20 retro into DoD, DoR, and VISION (#27)

## [1.0.0] - 2026-07-20

### Documentation

- neutral README tone, correct suite counts, install create-release skill (#8)

### New Features

- v1 stdio MCP server library (stateless 2026-07-28, dual-era) (#1)


