# Documentation

pascal-mcp-sdk lets any FreePascal program expose **tools, resources,
and prompts** to AI agents over the
[Model Context Protocol](https://modelcontextprotocol.io) — no second
language runtime, no framework, no third-party dependencies beyond
FPC's own RTL and fpjson.

New to AI agents? Start with the
[introduction](guides/introduction.md) — MCP explained for Pascal
developers, no AI background assumed. Then the
[quick start](guides/quick-start.md) gets a working server registered
with an MCP client in a few minutes.

## Guides

Task-oriented pages for building and shipping your own MCP server:

- [Introduction](guides/introduction.md) — what AI agents are, what
  MCP standardizes, and where your Pascal code fits.
- [Quick start](guides/quick-start.md) — install, write a server,
  serve it over stdio or Streamable HTTP, register it with a client.
- [Your first conversation](guides/first-conversation.md) — an agent
  calling a Pascal tool, on screen and on the wire.
- [Tools](guides/tools.md) — the core registration model: handlers,
  typed argument classes, validation, annotations, MRTR.
- [Schemas](guides/schemas.md) — the fluent builder, RTTI-derived
  argument classes, output schemas, and the enforced subset.
- [Prompts](guides/prompts.md) — reusable message templates with
  declared arguments.
- [Resources](guides/resources.md) — static text, reader callbacks,
  blobs, and RFC 6570 URI templates.
- [Configuration](guides/configuration.md) — the server properties:
  instructions, caching hints, error redaction, dual-era mode.
- [Progress and logging](guides/progress-and-logging.md) — in-request
  notifications and stderr diagnostics.
- [Shipping your server](guides/shipping.md) — release builds, the
  runtime contract, client registration, HTTP deployment posture.
- [Troubleshooting](guides/troubleshooting.md) — the failure modes
  everyone hits once.
- [Cookbook](guides/cookbook.md) — complete worked examples, anchored
  in the demo server.

## Reference

The public API surface, page by page:

- [Server API](reference/server.md) — `TMCPServer`: every
  registration overload, options, and configuration property.
- [Results and content](reference/results.md) — the helpers handlers
  return results with.
- [Client requests](reference/client-requests.md) — MRTR builders and
  accessors: elicitation, sampling, roots.
- [Protocol coverage](reference/protocol-coverage.md) — the
  surface-by-surface record of what the library implements, with
  verification and interop evidence.

## Contributing

How the library itself is built:
[architecture](internals/architecture.md) (the six-unit layering and
spec grounding), [tooling](internals/tooling.md),
[code style](internals/code-style.md), and
[releasing](internals/releasing.md). The contribution workflow —
clone, build, test, format, CI — lives in
[CONTRIBUTING.md](../CONTRIBUTING.md).
