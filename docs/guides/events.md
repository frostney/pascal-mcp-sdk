# Events

## Executive Summary

Events is the official extension for telling a client that something
happened, such as a new email or an incident
(`io.modelcontextprotocol/events`, at the Beta stage, defined by
[SEP-3415](https://github.com/modelcontextprotocol/ext-events/blob/c77b84395eff0ae32f53b0516c2214fe276ed050/specification/beta/events/events.mdx)).
A server lists the event types it offers, and a client subscribes to
one with a name, arguments and a cursor. `MCP.Events` serves poll
delivery: the client calls `events/poll` with its cursor, and the
server answers with what happened since and a new cursor. The server
holds no state per client, which fits this library's stateless design.

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
  ["poll"]`, and its input and payload schemas, paged with `PageSize`.
- `events/poll`: one subscription per request. An unknown name answers
  `-32023` with `data.kind` `"event"`, and bad parameters or arguments
  answer `-32602`.

The extension is defined for the 2026-07-28 revision, so the classic
`initialize` does not declare it, and a client on the classic handshake
that calls these methods anyway gets `-32601`. On Streamable HTTP, `events/poll`
carries the `Mcp-Name` header for the event name and an `Mcp-Param-*`
header for each argument marked `x-mcp-header`. Both are checked as for
`tools/call`. `Mcp-Name` must arrive once, and a name that is not plain
ASCII must be base64-encoded.

## Not served

- **Push delivery** (`events/stream`) needs a response stream that
  stays open, and comes later.
- **Webhooks** need subscriptions the server keeps, outbound HTTPS
  calls and an authenticated caller.
- **`notifications/events/list_changed`** needs `subscriptions/listen`.

The event types are fixed when the server starts, so a declaration
without `listChanged` is accurate.

## Related pages

- [Server API reference](../reference/server.md#extensions), for
  `RegisterEvent`, the query and poll records, and the error codes.
- [Tools](tools.md#routing-headers-x-mcp-header), for the `x-mcp-header`
  annotation event arguments share.
- [Skills](skills.md), the other extension built on the same hooks.
