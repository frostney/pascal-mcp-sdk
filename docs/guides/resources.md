# Resources

## Executive Summary

A resource is data your server exposes for the client to *read* — a
file, a config, a report — addressed by URI, listed via
`resources/list`, fetched via `resources/read`. Register static text
with one call, dynamic content with a reader callback, and whole URI
families with RFC 6570 templates. Readers return contents built with
`MCPTextContents` / `MCPBlobContents`.

## Static text resources

The one-liner for content that never changes while the process runs:

```pascal
Server.RegisterTextResource('mcp://my-server/motd', 'motd',
  'text/plain', 'Be excellent to each other.',
  'Message of the day');
```

URI, name, MIME type, the text itself, and an optional description
clients show in listings. URIs are yours to design; the `mcp://<server>/`
convention keeps them collision-free.

## Dynamic resources

Content produced at read time uses a reader callback:

```pascal
function ConfigReader(const AUri: string;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  Result := MCPTextContents(AUri, 'application/json', LoadConfigJson);
end;

Server.RegisterResource('mcp://my-server/config', 'config',
  'application/json', ConfigReader, 'Live server configuration');
```

The reader returns a `TJSONArray` of contents entries:

- `MCPTextContents(Uri, MimeType, Text)` — text contents.
- `MCPBlobContents(Uri, MimeType, Base64)` — binary contents,
  base64-encoded.

Both return a single-entry array; concatenate entries for multi-part
reads. A reader exception becomes a JSON-RPC error on
`resources/read`. Because the library cannot know how fresh a
callback's data stays, reads served by a dynamic reader always
advertise `ttlMs: 0` (revalidate) in their caching hints — static
text advertises the server-wide TTL (see
[Configuration](configuration.md#cachettlms-and-cachescope)).

Method-pointer overloads (`of object`) exist for both `RegisterResource`
and `RegisterResourceTemplate`, mirroring tools and prompts.

## Resource templates

A template registers a whole URI family; variables matched from the
requested URI are passed to the reader:

```pascal
function ShoutReader(const AUri: string; AVars: TJSONObject;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  Result := MCPTextContents(AUri, 'text/plain',
    UpperCase(AVars.Get('text', '')));
end;

Server.RegisterResourceTemplate('mcp://my-server/shout/{text}',
  'shout', 'text/plain', ShoutReader, 'Uppercase echo of {text}');
```

Templates are listed via `resources/templates/list`; a
`resources/read` whose URI matches no exact resource is matched
against the templates.

Matching is intentionally limited to RFC 6570 **level 1** (`{var}`
expressions):

- Variables must be non-empty and separated by literal text; matching
  uses the complete following literal and may backtrack.
- **Exact resources win** over template matches.
- Captured values are passed to readers exactly as encoded in the URI
  — percent-decoding is not performed. Decode in the reader if your
  variables can carry encoded characters.

## Errors

Reading an unregistered URI answers the spec's era-appropriate error:
`-32602` for stateless-era clients, `-32002` in the classic-handshake
dialect. Reader
exceptions become JSON-RPC internal errors, with messages subject to
[error redaction](configuration.md#redacterrordetails).

> Resource behaviour (`resources/list`, `resources/read`,
> `resources/templates/list`, error codes, caching hints) implements
> spec revision 2026-07-28 — see
> [Spec grounding](../internals/architecture.md#spec-grounding).
