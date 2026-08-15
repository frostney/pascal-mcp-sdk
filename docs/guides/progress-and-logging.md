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
the client sets a minimum level via the
`io.modelcontextprotocol/logLevel` key in `_meta` (the progress
token, by contrast, is the unprefixed `progressToken` key), and
messages below it are filtered out; without the key, no log
notifications are sent at all.

## Delivery

Request-scoped notifications are written **before** the response, on
the same channel: under stdio they are lines preceding the response
line; over Streamable HTTP a request that opted in is answered as an
SSE stream — notification events first, the final response last.

## A worked example — what the client sees

A handler that syncs three files, reporting each step and flagging a
data problem on the way:

```pascal
function SyncHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
const
  Files: array[0..2] of string = ('users.csv', 'orders.csv', 'events.csv');
var
  I: Integer;
begin
  MCPLogMessage(ACtx, 'info', 'sync started');
  for I := 0 to High(Files) do
  begin
    if ACtx.IsCancelled then
      Exit(MCPErrorResult('cancelled'));
    // ... the actual transfer of Files[I] ...
    if Files[I] = 'orders.csv' then
      MCPLogMessage(ACtx, 'warning', '3 rows skipped: bad encoding');
    MCPReportProgress(ACtx, I + 1, Length(Files), 'synced ' + Files[I]);
  end;
  Result := MCPTextResult('3 files synced');
end;
```

Called with `"progressToken": "sync-1"` and
`"io.modelcontextprotocol/logLevel": "info"` in `_meta`, the server
emits this exact stream — five notifications in handler order, then
the response (captured from `HandleMessage`; each is one line on the
wire):

```json
{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"sync started"}}
{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"sync-1","progress":1.0E+000,"total":3.0E+000,"message":"synced users.csv"}}
{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"warning","data":"3 rows skipped: bad encoding"}}
{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"sync-1","progress":2.0E+000,"total":3.0E+000,"message":"synced orders.csv"}}
{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"sync-1","progress":3.0E+000,"total":3.0E+000,"message":"synced events.csv"}}
{"jsonrpc":"2.0","id":5,"result":{"content":[{"type":"text","text":"3 files synced"}],"isError":false, ...}}
```

(Progress values are floats, and fpjson serializes them in exponent
form — shortened here from the full `1.0000000000000000E+000`; valid
JSON either way, and every client parses it as the number.)

The same call *without* the opt-in keys produces exactly one line —
the response. The handler didn't change; the no-op helpers absorbed
every call.

Here is that stream arriving in a real terminal — notifications
first, response last:

[Watch: a notification stream in a terminal](../casts/progress.cast)

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
