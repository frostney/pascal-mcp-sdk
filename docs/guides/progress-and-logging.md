# Progress and Logging

## Executive Summary

Two channels, two audiences. **In-request notifications** —
`MCPReportProgress` and `MCPLogMessage` — go to the *client* inside
the protocol, strictly when the client opted in, and are safe to call
unconditionally (they no-op otherwise). **Process diagnostics** —
`MCPLogToStderr` — go to stderr, never stdout, because under stdio the
protocol owns stdout.

## Progress

A long-running handler reports progress through the request context:

```pascal
function EchoHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  MCPReportProgress(ACtx, 0.5, 1.0, 'echoing');
  // ... the actual work ...
  Result := MCPTextResult('...');
  MCPReportProgress(ACtx, 1.0, 1.0);
end;
```

`AProgress` is how far along you are; `ATotal` (optional, `-1` = no
total) sets the scale; the optional message is human-readable.
Notifications are emitted **only** when the request carried a
`progressToken` in its `_meta` — without one, the call is a no-op, so
handlers report unconditionally and stay oblivious to client
preferences. The token round-trips verbatim into
`notifications/progress`.

## Log messages

`MCPLogMessage(ACtx, Level, Data, Logger)` emits
`notifications/message` entries scoped to the request:

```pascal
MCPLogMessage(ACtx, 'info', 'echo invoked');
```

Levels are RFC 5424: `debug`, `info`, `notice`, `warning`, `error`,
`critical`, `alert`, `emergency`. Emission is opt-in per request —
the client sets a minimum level via the `logLevel` key in `_meta`,
and messages below it are filtered out; without the key, no log
notifications are sent at all.

## Delivery

Request-scoped notifications are written **before** the response, on
the same channel: under stdio they are lines preceding the response
line; over Streamable HTTP a request that opted in is answered as an
SSE stream — notification events first, the final response last.

## Process diagnostics

Anything your server wants to say outside the protocol — startup
banners, operational warnings — goes to stderr:

```pascal
MCPLogToStderr('my-server: serving on stdio');
```

**Never `WriteLn` to stdout in a stdio server** — one stray line
corrupts the protocol stream (see
[Troubleshooting](troubleshooting.md)). Clients may capture, forward,
or ignore stderr.

> Notification behaviour (`notifications/progress`,
> `notifications/message`, opt-in gating, SSE delivery) implements
> spec revision 2026-07-28 — see
> [Spec grounding](../internals/architecture.md#spec-grounding).
