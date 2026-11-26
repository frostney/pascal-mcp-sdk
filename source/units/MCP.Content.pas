unit MCP.Content;

// Content blocks shared by tool results (tools/call "content") and
// prompt messages (prompts/get "messages[].content"). The 2026-07-28
// revision defines the same five block types for both, verified
// 2026-11-26 against:
//   https://modelcontextprotocol.io/specification/2026-07-28/server/tools#tool-result
//   https://modelcontextprotocol.io/specification/2026-07-28/server/prompts#promptmessage
//
//   text           {"type":"text","text":...}
//   image / audio  {"type":"image"|"audio","data":<base64>,"mimeType":...}
//   resource_link  {"type":"resource_link","uri":...,"name":...,
//                   "description"?:...,"mimeType"?:...}
//   resource       {"type":"resource","resource":{"uri":...,
//                   "mimeType"?:...,"text"|"blob":...}}
//
// Every builder returns a fresh owned TJSONObject; MCPContentResult and
// MCPContentMessage in MCP.Server take ownership of the blocks they are
// given. Optional fields are omitted when passed empty. Annotations are
// left to the caller (add an "annotations" member to the returned
// object). This unit has no protocol logic and no dependency on the
// server core, so it sits below MCP.Server in the layering.

{$I MCP.inc}

interface

uses
  SysUtils,

  fpjson;

function MCPTextContent(const AText: string): TJSONObject;

// The string overloads take data that is ALREADY base64 (the same
// contract as MCPBlobContents); the TBytes overloads encode the raw
// bytes themselves. AMimeType is the IANA media type and goes on the
// wire verbatim.
function MCPImageContent(const ABase64, AMimeType: string): TJSONObject; overload;
function MCPImageContent(const AData: TBytes;
  const AMimeType: string): TJSONObject; overload;
function MCPAudioContent(const ABase64, AMimeType: string): TJSONObject; overload;
function MCPAudioContent(const AData: TBytes;
  const AMimeType: string): TJSONObject; overload;

// A link to a resource the client can read or subscribe to. Links
// need not appear in resources/list (spec Info note).
function MCPResourceLink(const AUri, AName: string;
  const AMimeType: string = ''; const ADescription: string = ''): TJSONObject;

// Embedded resources: the resource's contents travel inside the block.
function MCPEmbeddedText(const AUri, AMimeType, AText: string): TJSONObject;
function MCPEmbeddedBlob(const AUri, AMimeType, ABase64: string): TJSONObject; overload;
function MCPEmbeddedBlob(const AUri, AMimeType: string;
  const AData: TBytes): TJSONObject; overload;

// Base64 of raw bytes, as the wire's "data" and "blob" fields carry it.
// Empty input encodes to '' (base64 of nothing), not to padding.
function MCPBase64(const AData: TBytes): string;

implementation

// fcl-base ships inside FPC 3.2.2 and is admitted by ADR-0003.
uses
  base64;

function MCPBase64(const AData: TBytes): string;
var
  Raw: string;
begin
  // fcl-base's encoder takes a string, so the bytes are moved in
  // byte-for-byte rather than assigned: an assignment would invite a
  // codepage conversion, and binary payloads are not text.
  if Length(AData) = 0 then
    Exit('');
  SetLength(Raw, Length(AData));
  Move(AData[0], Raw[1], Length(AData));
  Result := EncodeStringBase64(Raw);
end;

function Block(const AType: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('type', AType);
end;

function MCPTextContent(const AText: string): TJSONObject;
begin
  Result := Block('text');
  Result.Add('text', AText);
end;

function BinaryBlock(const AType, ABase64, AMimeType: string): TJSONObject;
begin
  Result := Block(AType);
  Result.Add('data', ABase64);
  Result.Add('mimeType', AMimeType);
end;

function MCPImageContent(const ABase64, AMimeType: string): TJSONObject;
begin
  Result := BinaryBlock('image', ABase64, AMimeType);
end;

function MCPImageContent(const AData: TBytes;
  const AMimeType: string): TJSONObject;
begin
  Result := BinaryBlock('image', MCPBase64(AData), AMimeType);
end;

function MCPAudioContent(const ABase64, AMimeType: string): TJSONObject;
begin
  Result := BinaryBlock('audio', ABase64, AMimeType);
end;

function MCPAudioContent(const AData: TBytes;
  const AMimeType: string): TJSONObject;
begin
  Result := BinaryBlock('audio', MCPBase64(AData), AMimeType);
end;

procedure AddOptional(AObject: TJSONObject; const AName, AValue: string);
begin
  if AValue <> '' then
    AObject.Add(AName, AValue);
end;

function MCPResourceLink(const AUri, AName, AMimeType,
  ADescription: string): TJSONObject;
begin
  Result := Block('resource_link');
  Result.Add('uri', AUri);
  Result.Add('name', AName);
  AddOptional(Result, 'description', ADescription);
  AddOptional(Result, 'mimeType', AMimeType);
end;

function EmbeddedBlock(const AUri, AMimeType, AField,
  AValue: string): TJSONObject;
var
  Resource: TJSONObject;
begin
  Resource := TJSONObject.Create;
  Resource.Add('uri', AUri);
  AddOptional(Resource, 'mimeType', AMimeType);
  Resource.Add(AField, AValue);
  Result := Block('resource');
  Result.Add('resource', Resource);
end;

function MCPEmbeddedText(const AUri, AMimeType, AText: string): TJSONObject;
begin
  Result := EmbeddedBlock(AUri, AMimeType, 'text', AText);
end;

function MCPEmbeddedBlob(const AUri, AMimeType, ABase64: string): TJSONObject;
begin
  Result := EmbeddedBlock(AUri, AMimeType, 'blob', ABase64);
end;

function MCPEmbeddedBlob(const AUri, AMimeType: string;
  const AData: TBytes): TJSONObject;
begin
  Result := EmbeddedBlock(AUri, AMimeType, 'blob', MCPBase64(AData));
end;

end.
