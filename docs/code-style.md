# Code Style

## Executive Summary

FPC 3.2.2, Delphi mode, one shared flags block (`Shared.inc`), `lwpt
format` as the only formatting authority. Namespaced units
(`MCP.*.pas`) with co-located tests, `A`-prefixed parameters,
`F`-prefixed fields, explicit ownership comments on every fpjson
boundary, and spec citations next to protocol behaviour.

## Compiler surface

Every unit and program starts with `{$I Shared.inc}` — Delphi mode,
`{$H+}`, `{$M+}`, advanced records, and the PRODUCTION flag block
(checks on in dev, off with `-dPRODUCTION`). No per-unit compiler
directives; if a flag is worth setting, it is worth centralising.

## Naming and layout

- Units are namespaced `MCP.<Area>.pas`; tests co-located as
  `MCP.<Area>.Test.pas` (programs, discovered by `lwpt test`).
- Types `T`-prefixed (`TMCPServer`, `TMCPToolResult`), fields
  `F`-prefixed, parameters `A`-prefixed, exceptions `E`-prefixed
  (`EMCPServer`).
- Public API helpers are plain unit-level functions with an `MCP`
  prefix (`MCPTextResult`, `MCPTextContents`) so call sites read
  without qualification.
- `lwpt format` owns whitespace, uses-clause ordering, and casing —
  run it rather than arguing with it (pre-commit does).

## fpjson ownership discipline

fpjson is manual-memory: `TJSONObject.Add(name, data)` **takes
ownership**, `Find` returns a **borrowed** reference, `Clone` allocates.
Every API boundary that passes `TJSONData` states its ownership rule in
a comment at the declaration (see `TJSONRPCMessage`,
`TMCPToolResult`, the `Register*` overloads). New code follows suit:
a reader should never have to guess who frees.

House rules distilled:

- Builders return owned trees; the caller (or the object they are added
  to) frees them.
- Handler inputs (`AArguments`, `Ctx.ClientCapabilities`) are borrowed:
  valid for the call, never freed, never retained.
- `try/finally` around every owned allocation whose scope can raise.

## Protocol code

- Behaviour mandated by the MCP spec carries a citation (spec page +
  verification date) in the unit header or at the rule — see
  `MCP.Protocol` and `MCP.Transport.Stdio`.
- Error-channel policy is fixed: **protocol errors** (malformed
  requests, unknown methods/tools/resources, bad metadata) are JSON-RPC
  errors with the spec's codes; **execution errors** (handler failures,
  bad argument values) are in-band `isError: true` results. New surface
  keeps that line.

## Tests

- Suites use lwpt's `TestingPascalLibrary` (`TTestSuite`, fluent
  `Expect<T>(...).ToBe(...)`).
- Test names state the rule being proven, spec-style
  (`'null id → -32600 (MCP forbids null ids)'`), so a failing run reads
  as a conformance report.
- Wire-level JSON fixtures are written inline as strings — what goes on
  the wire is what the test shows.
