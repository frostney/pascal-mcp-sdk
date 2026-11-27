# Events

## Executive Summary

Events is the official extension for telling a client that something
happened, such as a new email or an incident
(`io.modelcontextprotocol/events`, at the Beta stage, defined by
[SEP-3415](https://github.com/modelcontextprotocol/ext-events/blob/c77b84395eff0ae32f53b0516c2214fe276ed050/specification/beta/events/events.mdx)).
A server lists the event types it offers, and a client subscribes to
one with a name, arguments and a cursor. `MCP.Events` serves two
delivery modes from the same check:

- **Poll**: the client calls `events/poll` with its cursor, and the
  server answers with what happened since and a new cursor. The server
  holds no state per client, which fits this library's stateless
  design.
- **Push**: the client opens a long-lived `events/stream`, and the
  server sends each occurrence as it finds it, until the client
  cancels. Only the open stream holds state, and it ends with the
  stream.

## Register an event type

```pascal
uses fpjson, MCP.Events, MCP.Protocol, MCP.Schema, MCP.Server;

function NewMail(const AQuery: TMCPEventQuery;
  const ACtx: TMCPRequestContext): TMCPEventPoll;
var
  Folder: TMailFolder;
  Page: TMailPage;
  Mail: TMailItem;
begin
  Folder := Mailbox.Folder(AQuery.Arguments.Get('folder', 'INBOX'));
  // "Start from now": no events, just the current position.
  if AQuery.FromNow then
    Exit(MCPEventPoll(Folder.Position));
  // One page from the cursor, no further back than maxAgeMs, at most
  // maxEvents long.
  Page := Folder.ReadFrom(AQuery.Cursor, AQuery.MaxAgeMs, AQuery.MaxEvents);
  Result := MCPEventPoll(Page.NextPosition, TJSONArray.Create);
  Result.HasMore := Page.HasMore;      // more mail after this page
  Result.Truncated := Page.Skipped;    // the cursor was too old
  if Page.Skipped then                 // where reading resumed, before
    Result.GapCursor := Page.Start;    // this page's mail
  for Mail in Page.Items do
    Result.Events.Add(MCPEventOccurrence(Mail.Id, Mail.ReceivedAt,
      TJSONObject.Create(['from', Mail.From, 'subject', Mail.Subject])));
end;

RegisterEvent(Server, 'email.received', 'Fires when an email arrives',
  // folder is optional: without it, the inbox is watched.
  ObjectSchema.AddString('folder', 'Folder to watch', False),
  ObjectSchema.AddString('from').AddString('subject'),
  NewMail);
```

The check gets a `TMCPEventQuery` for each poll:

- `Arguments`: the subscription's arguments, checked against the
  input schema, which must lie in the subset the server enforces for
  tools.
- `Cursor`: the client's position, opaque to it. When it is null or
  absent, `FromNow` is true, and the check returns no events and a
  fresh cursor.
- `MaxAgeMs` and `MaxEvents`: the client's limits, `-1` when absent.
  `MaxEvents` is at least 1 when given.

It returns a `TMCPEventPoll`, built with `MCPEventPoll(Cursor, Events)`:

- `Events`: at most `MaxEvents` occurrences built with
  `MCPEventOccurrence(Id, Timestamp, Data)`. The timestamp is RFC 3339
  with a time zone. With an empty id, the server derives one from the
  name, timestamp and data, so the same event polled twice keeps its
  id.
- `Cursor`: the position after these events, not the upstream's head:
  with `HasMore`, the client reads on from here and skips nothing.
- `HasMore`: more events are waiting beyond `MaxEvents`. The client
  polls again at once.
- `Truncated`: events were skipped. The cursor may have fallen outside
  what the upstream keeps, `MaxAgeMs` may have moved the start past it,
  or the server may apply its own replay ceiling.
- `NoReplay`: the upstream has no history, so the cursor goes out as
  null.
- `NextPollMs`: when the client should poll next. Zero takes the
  registration's interval, 30 seconds by default.
- `GapCursor`: with `Truncated` and events, the position reading
  resumed from, before them. Polls ignore it; a push stream sends it
  after a gap (see Push delivery).

Occurrences that break these rules, such as data that does not match
the payload schema, are the server's mistake: the poll answers
`-32603` and nothing is sent. A check may raise `EMCPProtocolError`
with the extension's codes, such as `-32024` (Forbidden) for a
subscription the caller may not have.

## What the server serves

The first `RegisterEvent` call declares the extension with `{}`, which
stays `{}` whatever `DeclareExtension` sets, since `listChanged` needs
`subscriptions/listen`. It serves:

- `events/list`: each type with its description, `"delivery":
  ["poll", "push"]`, and its input and payload schemas, paged with
  `PageSize`.
- `events/poll`: one subscription per request. An unknown name answers
  `-32023` with `data.kind` `"event"`, and bad parameters or arguments
  answer `-32602`.
- `events/stream`: one push subscription per request, described below.

The extension is defined for the 2026-07-28 revision, so the classic
`initialize` does not declare it, and a client on the classic handshake
that calls these methods anyway gets `-32601`. On Streamable HTTP,
`events/poll` and `events/stream` carry the `Mcp-Name` header for the event name and an `Mcp-Param-*`
header for each argument marked `x-mcp-header`. Both are checked as for
`tools/call`. `Mcp-Name` must arrive once, and a name that is not plain
ASCII must be base64-encoded.

## Push delivery

The server polls the check on the stream's behalf, asking for one
occurrence at a time (`MaxEvents` 1), so each event carries the exact
cursor after it. `HasMore` reads on at once, and otherwise the next
call waits `NextPollMs`, or the registration's interval, or 30 seconds
when both are zero. The check
needs nothing new; a type without replay keeps its position for the
stream's lifetime and sends `cursor: null`.

The first check call runs inside the request, so an error it raises,
such as `-32024`, answers at once and opens no stream, as do an unknown
name and bad arguments. Then the stream sends, each message tagged with
`_meta["io.modelcontextprotocol/subscriptionId"]`, the request's id:

- `notifications/events/active` first, with the client's cursor (or a
  fresh one), `truncated` and the granted `heartbeatMs`, and again with
  `truncated: true` after a gap. When an occurrence follows the gap,
  the cursor is the check's `GapCursor`, the position before it, so a
  client that reconnects from it is sent the occurrence again. Without
  one it is the position after the occurrence, which is then part of
  the gap the flag signals.
- `notifications/events/event` for each occurrence, with its cursor.
- `notifications/events/heartbeat` whenever `heartbeatMs` passes
  without another message, with the position checked up to. The grant
  is 30 seconds, or the client's suggestion clamped to 1 second to 5
  minutes.
- `notifications/events/error` (`-32603`) when the check fails with
  any other exception, `EMCPServer` included. The stream retries at the
  next interval.
- `notifications/events/terminated` when the check raises
  `EMCPProtocolError`, such as `-32024` for revoked access (its data
  when that is an object), or returns occurrences that break the rules
  (`-32603`). The final frame, `{"resultType": "complete"}` with the
  subscription id in `_meta`, follows, and the stream ends.

The first check runs without a notifier, so its progress and log
notifications go nowhere. Later checks get a context whose
`IsCancelled` turns true when the client goes away, so a check that
waits can stop. `MaxAgeMs` bounds the whole first backlog; once the
stream has caught up, later checks get `-1`. The next check is timed
from when a check returns.

On Streamable HTTP the response is an SSE stream that opens at once,
and the client cancels by closing the connection, which the server
notices within 50 ms. Each stream holds its connection's thread, and no
cap on concurrent requests counts it. `Stop` closes open streams with
their final frame.

On stdio the loop stays single-threaded: it waits for input no longer
than the next stream is due, and steps the streams between lines, so
other requests, and other streams, carry on. A `notifications/cancelled`
for the stream's id ends it, and nothing more is sent for it. The end
of input ends every stream. A request that runs long delays the streams
until it returns. A loop over a Text with its own driver, or a Windows
console, cannot wait with a time limit, and `events/stream` then
answers `-32026` (Unsupported, `data.feature` `"deliveryMode"`), as it
does over the in-process test client.

## Not served

- **Webhooks** need subscriptions the server keeps, outbound HTTPS
  calls and an authenticated caller.
- **`notifications/events/list_changed`** needs `subscriptions/listen`.

The event types are fixed when the server starts, so a declaration
without `listChanged` is accurate.

## Related pages

- [Server API reference](../reference/server.md#extensions), for
  `RegisterEvent`, the query and poll records, the push constants and
  `MCP.Streams`, and the error codes.
- [Tools](tools.md#routing-headers-x-mcp-header), for the `x-mcp-header`
  annotation event arguments share.
- [Skills](skills.md), the other extension built on the same hooks.
