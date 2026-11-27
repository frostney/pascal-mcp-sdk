# Configuration

## Executive Summary

`TMCPServer` has six request-visible configuration properties —
`Instructions`, `CacheTtlMs`, `CacheScope`, `RedactErrorDetails`,
`DualEra` and `RequestStateTtlMs` — plus the `requestState` keys
(`SetRequestStateKeys`), all set between `Create` and serving. Configuration
freezes together with the registries when the first session is
created; a later write raises `EMCPServer`.

```pascal
Server := TMCPServer.Create('my-server', '1.0.0');
Server.Instructions := 'Greets people. Use "greet" with a name.';
Server.CacheTtlMs := 60000;
Server.RedactErrorDetails := True;
```

## Instructions

A free-text description of how to use your server, surfaced to
clients via `server/discover` (and the classic `initialize` result).
Clients typically place it in the model's context — write it for the
model: name the tools, say when to use them, keep it short.

## CacheTtlMs and CacheScope

The caching hints (`ttlMs` / `cacheScope`, SEP-2549) stamped on
`server/discover`, list, and read results, telling clients how long
the answer stays valid:

- `CacheTtlMs` — default `300000` (5 minutes, the spec's own
  `tools/list` example). Registries are frozen after startup, so
  registry metadata is honestly cacheable. Must not be negative.
- `CacheScope` — `'private'` (default) or `'public'`.

One exception is applied per-result: a `resources/read` served by a
**dynamic reader** always advertises `ttlMs: 0` (revalidate) — the
library cannot know how fresh a callback's data stays.

## RedactErrorDetails

`False` by default: an escaped handler or dispatch exception carries
its message to the client — the in-band detail trusted local clients
use to self-correct.

Set it to `True` for servers whose error messages could leak
internals: the client instead receives a generic message with a
correlation reference (`... (ref e-000001)`), and the full exception —
class, message, site — is logged to stderr under that reference for
you to match up. Deliberate errors are not redacted: an
`MCPErrorResult` text and an `EMCPProtocolError`'s message and data
reach the client as written, so keep secrets out of them. (Best-effort on Unix: the first stderr emission
upgrades a default SIGPIPE disposition to ignore, so a closed stderr
cannot kill the process; a host's own SIGPIPE handling is left
untouched.)

## DualEra

`True` by default: the server answers the classic `initialize`
handshake (protocol revisions `2024-11-05`, `2025-06-18`,
`2025-11-25`) alongside stateless `2026-07-28` requests. This is not
about supporting outdated software — the classic handshake is what
current clients speak, Claude Code and Codex included (see the wire
captures in [Your first conversation](first-conversation.md)). Era
selection follows how each client opens; handlers are era-blind, so
the spec's transition to the stateless revision costs you nothing
either way.

Set `DualEra := False` for a strict modern-only server: `initialize`
is rejected with a diagnostic naming the supported versions. The
Streamable HTTP binding forces this mode — HTTP clients speak
`2026-07-28`.

## requestState sealing

A handler that asks for more input (MRTR) can return a `requestState`
for the next round. The specification makes the client's echo of it
attacker-controlled input: a server must protect its integrity and
reject state that fails verification, and should bind it to an expiry
and to the request
([MRTR](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr),
verified 2026-11-26). The server does this for every handler. It sends
the state as a token signed with HMAC-SHA-256 that also carries an
expiry, the method, the tool or prompt name, a SHA-256 digest of the
arguments and the server's name, and it verifies the token before the
handler runs again. A token that fails any of these checks is answered
`-32602` ("Invalid or expired requestState"); the reason is logged to
stderr only.

```pascal
Server.SetRequestStateKeys([LoadKey('MCP_STATE_KEY')]);  // >= 32 bytes
Server.RequestStateTtlMs := 120000;                      // two minutes
```

- **No keys set:** each `TMCPServer` makes a random 32-byte key when
  its first session starts (reading the operating system's random
  source then; with keys set, nothing is read). The key lives as long
  as that instance: a token from an instance you replace, or from
  another process serving the same endpoint behind a load balancer,
  is refused. Give every instance the same key to keep continuations
  working across them.
- **Rotation:** the first key seals and every key verifies. Change keys
  in three steps, each on every instance before the next:
  1. `[Old, New]`: every instance can verify the new key, still
     sealing with the old one.
  2. `[New, Old]`: seal with the new key.
  3. `[New]`, once one TTL has passed since the last instance switched.
- **Replay:** a token is bound to its method, tool or prompt, arguments
  and server, and expires after `RequestStateTtlMs`. Within that window
  the same retry can be sent again and verifies each time. If a retry
  has a side effect that must happen once, make the handler
  idempotent, or record the use yourself (an id in the state, checked
  against your own store).
- **What it does not do:** the client can read the state, so keep
  secrets out of it. The token is not bound to a user, because the
  library has no authenticated identity to bind it to; if your state
  grants something per user, put the user in the state and check it in
  the handler.

## Freeze semantics

All six properties and the keys, like the registries, are mutable only until the
first session exists (`RunMCPStdioServer` and `TMCPHTTPServer` create
sessions internally). Configure fully, then serve:

```text
Create → Instructions/Cache*/Redact/DualEra/RequestState* → Register* → serve
```

A write after freeze raises
`EMCPServer: Server configuration is frozen after session creation`.

> The behaviours behind these switches (SEP-2549 cache fields, the
> dual-era compatibility matrix) implement spec revision 2026-07-28 —
> see [Spec grounding](../internals/architecture.md#spec-grounding).
