# Definition of Ready

Use this gate before implementing an issue, idea, refactor, or
documentation change in pascal-mcp. A requirement may be marked not
applicable only with a recorded reason.

## Ready to investigate

- The desired outcome, current behaviour, affected surface, and
  non-goals are stated clearly enough to verify later.
- The work has been checked against [VISION.md](VISION.md). Any
  conflict with the stateless-spec direction or the not-goals fence is
  explicit and accepted before implementation.
- The root [AGENTS.md](AGENTS.md) hard constraints have been read.
- Applicable project skills under `.agents/skills/` have been
  identified before planning.
- The relevant docs have been identified before forming a plan:
  [Architecture](docs/architecture.md), [Code style](docs/code-style.md),
  [Tooling](docs/tooling.md).

## Ready to plan

- The relevant code path has been traced in source; documentation or
  memory alone is not treated as proof.
- **Protocol claims are grounded**: any statement about MCP behaviour
  has been verified against the official spec pages
  (modelcontextprotocol.io) for the targeted revision, and the citation
  is ready to land next to the change.

## Ready to implement

- The planned change fits the bottom-up layering (`MCP.JsonRpc` →
  `MCP.Protocol` → `MCP.Server` → transports); any protocol rule lands
  in the layer that owns it, never in a transport.
- New dependencies are not part of the plan; if one seems necessary,
  maintainer approval is obtained first.
- The verification story is known in advance: which co-located suite
  covers it, and whether `mcpsmoke` needs a new check.
