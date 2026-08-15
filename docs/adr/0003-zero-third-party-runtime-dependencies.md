# Zero third-party runtime dependencies

The runtime dependency set is FPC's RTL + fpjson, nothing else.
Packages that ship inside FPC 3.2.2 are not third-party: fcl-web is
admitted on the same footing as fcl-json, confined to
`MCP.Transport.HTTP`. This is what makes the library trivially
vendorable, embeddable into any host binary via lwpt, and buildable
with plain `fpc @lwpt.cfg` — the alternative (adopting a JSON or HTTP
library) would hand every consumer our supply chain.

## Consequences

- lwpt's `testing` package is dev-time only; anything beyond needs
  explicit maintainer approval with a recorded justification.
- The Node toolchains in the repo (`tools/interop-ts`, `website/`)
  are contributor/CI tooling and never touch the shipped library.
- Features that would require a heavier dependency (full JSON-Schema
  validation, TLS, auth) are out of scope by construction — see
  [ADR-0004](0004-schema-validation-boundary.md) and the operator
  contract in the shipping guide.
