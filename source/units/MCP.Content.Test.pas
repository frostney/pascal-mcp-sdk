{ MCP.Content.Test — the content-block builders, asserted on the exact
  serialized JSON the wire carries (SerializeCompact), so a field name,
  an optional member or an encoding regression shows up byte for byte
  rather than cancelling out through a decode (#10, #26). Shapes
  verified 2026-11-26 against
  https://modelcontextprotocol.io/specification/2026-07-28/server/tools#tool-result
  and .../server/prompts#promptmessage. URIs stay ASCII (RFC 3986;
  non-ASCII is percent-encoded); names and text carry the UTF-8. }

program MCP.Content.Test;

{$I MCP.inc}

uses
  SysUtils,

  fpjson,
  MCP.Content,
  MCP.JSONRPC,
  TestingPascalLibrary;

const
  // UTF-8 for 'é😀' — a two-byte sequence adjacent to an astral-plane
  // four-byte one.
  UTF8_TEXT = #$C3#$A9#$F0#$9F#$98#$80;
  // The same six bytes as a binary payload; base64 written out
  // literally rather than recomputed.
  ASTRAL_BYTES: array[0..5] of Byte = ($C3, $A9, $F0, $9F, $98, $80);
  ASTRAL_BASE64 = 'w6nwn5iA';

type
  TContentBlocks = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestText;
    procedure TestImageBase64;
    procedure TestImageBytes;
    procedure TestAudioBase64;
    procedure TestAudioBytes;
    procedure TestResourceLinkFull;
    procedure TestResourceLinkMinimal;
    procedure TestEmbeddedText;
    procedure TestEmbeddedTextWithoutMimeType;
    procedure TestEmbeddedBlob;
    procedure TestEmbeddedBlobBytes;
    procedure TestBase64Empty;
  end;

function BytesOf(const AValues: array of Byte): TBytes;
var
  I: Integer;
begin
  SetLength(Result, Length(AValues));
  for I := 0 to High(AValues) do
    Result[I] := AValues[I];
end;

// Serializes and frees ABlock.
function Wire(ABlock: TJSONObject): string;
begin
  try
    Result := SerializeCompact(ABlock);
  finally
    ABlock.Free;
  end;
end;

procedure TContentBlocks.TestText;
begin
  Expect<string>(Wire(MCPTextContent(UTF8_TEXT)))
    .ToBe('{ "type" : "text", "text" : "' + UTF8_TEXT + '" }');
end;

procedure TContentBlocks.TestImageBase64;
begin
  Expect<string>(Wire(MCPImageContent('iVBORw0KGgo=', 'image/png')))
    .ToBe('{ "type" : "image", "data" : "iVBORw0KGgo=", "mimeType" : "image/png" }');
end;

procedure TContentBlocks.TestImageBytes;
begin
  Expect<string>(Wire(MCPImageContent(BytesOf(ASTRAL_BYTES), 'image/png')))
    .ToBe('{ "type" : "image", "data" : "' + ASTRAL_BASE64 +
      '", "mimeType" : "image/png" }');
end;

procedure TContentBlocks.TestAudioBase64;
begin
  Expect<string>(Wire(MCPAudioContent('UklGRg==', 'audio/wav')))
    .ToBe('{ "type" : "audio", "data" : "UklGRg==", "mimeType" : "audio/wav" }');
end;

procedure TContentBlocks.TestAudioBytes;
begin
  Expect<string>(Wire(MCPAudioContent(BytesOf(ASTRAL_BYTES), 'audio/ogg')))
    .ToBe('{ "type" : "audio", "data" : "' + ASTRAL_BASE64 +
      '", "mimeType" : "audio/ogg" }');
end;

procedure TContentBlocks.TestResourceLinkFull;
begin
  Expect<string>(Wire(MCPResourceLink('file:///src/%C3%A9.rs',
    UTF8_TEXT + '.rs', 'text/x-rust', 'Entry ' + UTF8_TEXT)))
    .ToBe('{ "type" : "resource_link", "uri" : "file:///src/%C3%A9.rs", ' +
      '"name" : "' + UTF8_TEXT + '.rs", "description" : "Entry ' +
      UTF8_TEXT + '", "mimeType" : "text/x-rust" }');
end;

procedure TContentBlocks.TestResourceLinkMinimal;
begin
  // description and mimeType are optional and omitted when empty.
  Expect<string>(Wire(MCPResourceLink('test://a', 'a')))
    .ToBe('{ "type" : "resource_link", "uri" : "test://a", "name" : "a" }');
end;

procedure TContentBlocks.TestEmbeddedText;
begin
  Expect<string>(Wire(MCPEmbeddedText('test://e', 'text/plain', UTF8_TEXT)))
    .ToBe('{ "type" : "resource", "resource" : { "uri" : "test://e", ' +
      '"mimeType" : "text/plain", "text" : "' + UTF8_TEXT + '" } }');
end;

procedure TContentBlocks.TestEmbeddedTextWithoutMimeType;
begin
  Expect<string>(Wire(MCPEmbeddedText('test://e', '', 'x')))
    .ToBe('{ "type" : "resource", "resource" : { "uri" : "test://e", ' +
      '"text" : "x" } }');
end;

procedure TContentBlocks.TestEmbeddedBlob;
begin
  Expect<string>(Wire(MCPEmbeddedBlob('test://b', 'image/png', 'iVBORw0KGgo=')))
    .ToBe('{ "type" : "resource", "resource" : { "uri" : "test://b", ' +
      '"mimeType" : "image/png", "blob" : "iVBORw0KGgo=" } }');
end;

procedure TContentBlocks.TestEmbeddedBlobBytes;
begin
  Expect<string>(Wire(MCPEmbeddedBlob('test://b', 'application/octet-stream',
    BytesOf(ASTRAL_BYTES))))
    .ToBe('{ "type" : "resource", "resource" : { "uri" : "test://b", ' +
      '"mimeType" : "application/octet-stream", "blob" : "' +
      ASTRAL_BASE64 + '" } }');
end;

procedure TContentBlocks.TestBase64Empty;
var
  NoBytes: TBytes;
begin
  NoBytes := nil;
  Expect<string>(MCPBase64(NoBytes)).ToBe('');
  Expect<string>(MCPBase64(BytesOf(ASTRAL_BYTES))).ToBe(ASTRAL_BASE64);
end;

procedure TContentBlocks.SetupTests;
begin
  Test('text block, non-ASCII byte-exact', TestText);
  Test('image block from base64', TestImageBase64);
  Test('image block from raw bytes', TestImageBytes);
  Test('audio block from base64', TestAudioBase64);
  Test('audio block from raw bytes', TestAudioBytes);
  Test('resource link with every field', TestResourceLinkFull);
  Test('resource link omits empty optional fields', TestResourceLinkMinimal);
  Test('embedded text resource', TestEmbeddedText);
  Test('embedded text resource without mimeType',
    TestEmbeddedTextWithoutMimeType);
  Test('embedded blob resource from base64', TestEmbeddedBlob);
  Test('embedded blob resource from raw bytes', TestEmbeddedBlobBytes);
  Test('MCPBase64: empty and astral bytes', TestBase64Empty);
end;

begin
  TestRunnerProgram.AddSuite(TContentBlocks.Create('Content: blocks'));
  TestRunnerProgram.Run;
end.
