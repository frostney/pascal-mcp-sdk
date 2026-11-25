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
