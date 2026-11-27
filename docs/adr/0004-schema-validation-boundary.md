# Server-enforced schema subset, no general JSON-Schema engine

The schema subset the library itself emits (`type`, `description`,
`title`, `properties`, `required`, `enum`, `default` — the dialect of
the fluent builder and the RTTI argument classes) is enforced by the
server on every tool call; a general JSON-Schema 2020-12 validation
engine is deliberately out of scope. A raw schema using keywords
outside the subset fails at registration freeze unless marked
`.ApplicationValidated` — the escape hatch that hands argument
validation back to the handler, which reports problems as in-band
`isError` results a model can read and correct against.

The trade-off: a full validator would either be a large in-tree
engine (violating the dependency posture of
[ADR-0003](0003-zero-third-party-runtime-dependencies.md)) or a
third-party dependency, and either would still leave semantic
validation to handlers. Enforcing exactly what we emit keeps the
guarantee honest: everything the server advertises, it checks.

## Amendment (2026-11-27, #91)

The enforced subset is now recursive (`items` and nested `properties`
added, `null` as a type) and lives in `MCP.Schema`, and it also checks
structured output against a tool's `outputSchema`, whose root can be
any type since the 2026-07-28 revision (SEP-2106). An output schema
outside the subset is published and left to the handler, like an
`.ApplicationValidated` input schema. A schema whose `$schema` names a
dialect other than 2020-12 is outside the subset. The boundary itself
stands: still no general JSON Schema engine.
