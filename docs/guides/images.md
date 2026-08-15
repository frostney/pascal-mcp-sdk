# Returning Images

## Executive Summary

A tool can answer with an image instead of (or alongside) text:
`MCPImageResult` builds the spec's image content block —
`{"type":"image","data":<base64>,"mimeType":<media type>}` — in the
same result envelope `MCPTextResult` uses. Hand it raw bytes and it
base64-encodes them for you, or hand it data that is already base64;
either way the client receives one image content block it can render
or pass to the model. Mind the transport budget: base64 inflates data
by a third, and both transports cap a message at 4 MiB by default.

## From raw bytes

The `TBytes` overload encodes for you — the natural fit whenever the
image exists as bytes in memory (read from disk, rendered by your
program, fetched from a store):

```pascal
function Screenshot(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Stream: TFileStream;
  Bytes: TBytes;
begin
  Stream := TFileStream.Create('/tmp/capture.png', fmOpenRead);
  try
    SetLength(Bytes, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Bytes[0], Stream.Size);
  finally
    Stream.Free;
  end;
  Result := MCPImageResult(Bytes, 'image/png');
end;
```

Register it like any other tool — a no-argument schema is just an
empty `ObjectSchema`:

```pascal
Server.RegisterTool('screenshot', 'Capture the current dashboard as PNG',
  ObjectSchema, Screenshot).ReadOnlyHint;
```

## From data that is already base64

The string overload takes data that is **already base64** — the same
contract as `MCPBlobContents`. Use it when the encoding happened
upstream: a data URI, a database blob column, an API response.

```pascal
Result := MCPImageResult(StoredBase64Png, 'image/png');
```

Nothing is validated or re-encoded: the string goes on the wire as
the `data` field verbatim. If you have raw bytes, use the `TBytes`
overload rather than encoding yourself.

## The media type

`AMimeType` is the image's IANA media type — `'image/png'`,
`'image/jpeg'`, `'image/webp'`, … — and goes on the wire verbatim.
The spec deliberately names no enumeration, so your handler owns the
choice; send the type that matches the bytes, because clients decide
how to decode from it.

## Size budget

The library does not cap what your handler returns — but the world
around it does. Both transports cap **inbound** messages at 4 MiB by
default (the stdio line cap and the HTTP `MaxBodyBytes` share that
budget), clients apply their own limits to what they will accept, and
every image the model reads spends its context. Base64 expands data
by roughly a third on top. Practical guidance:

- Keep returned images modest — resize or re-encode before returning
  (a smaller JPEG/WebP often serves the model just as well as a
  full-resolution PNG).
- For genuinely large images, return a [resource](resources.md) URI
  and serve the bytes via `resources/read` (`MCPBlobContents`),
  letting the client fetch on demand.

## Text and image together

A result's content array can carry both — build the image result and
prepend text, or vice versa. The common shape is an explanatory
sentence plus the rendering:

```pascal
Result := MCPImageResult(ChartBytes, 'image/png');
Result.Content.Insert(0, TJSONObject.Create([
  'type', 'text',
  'text', 'Revenue by month, Q1-Q2']));
```

(`Content` is the result's content array; entries added to it are
owned by the result — see the ownership rules in
[Results and content](../reference/results.md).)

> The image content-block shape implements spec revision 2026-07-28,
> verified 2026-08-09 against the
> [tools page](https://modelcontextprotocol.io/specification/2026-07-28/server/tools);
> the dated citation lives at the `MCPImageResult` declaration in
> `MCP.Server`.
