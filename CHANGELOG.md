# Changelog

All notable changes to pascal-mcp-sdk are documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); entries are generated from Conventional Commits by git-cliff.
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


