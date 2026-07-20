unit MCP.Protocol;

// MCP protocol layer for the stateless spec (revision 2026-07-28): the
// per-request metadata model that replaced the initialize handshake.
// Every request carries its protocol version and client capabilities in
// params._meta["io.modelcontextprotocol/*"]; the server validates them
// on every request and stamps resultType + serverInfo on every result.
// Nothing here touches a transport — MCP.Server dispatches decoded
// messages through these helpers, and any transport (stdio today, HTTP
// later) reuses them unchanged.
//
// Spec grounding (verified 2026-07-20 against the official draft pages
// for the 2026-07-28 revision):
//   - required _meta fields, -32602 on absence:
//       modelcontextprotocol.io/specification/draft/basic/index#meta
//   - version negotiation, UnsupportedProtocolVersionError (-32022):
//       modelcontextprotocol.io/specification/draft/basic/versioning

{$I Shared.inc}

interface

uses
  SysUtils,

  fpjson,
  MCP.JSONRPC;

const
  // The modern (stateless, per-request-metadata) revision this library
  // implements natively.
  MCP_PROTOCOL_VERSION = '2026-07-28';

  // Legacy (initialize-handshake) revisions a dual-era server answers.
  // The surface pascal-mcp-sdk serves (tools/list+call, resources) is
  // wire-stable across these: later revisions only added fields
  // (structuredContent, title) that older clients ignore.
  LATEST_LEGACY_PROTOCOL_VERSION = '2025-11-25';
  LEGACY_PROTOCOL_VERSIONS: array[0..3] of string = (
    '2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05');

  // Legacy-era resource-not-found code (2025-11-25 and earlier). The
  // modern revision replaced it with -32602 and forbids emitting it;
  // a dual-era server still owes it to legacy clients.
  MCP_ERROR_LEGACY_RESOURCE_NOT_FOUND = -32002;

  META_KEY_PROTOCOL_VERSION    = 'io.modelcontextprotocol/protocolVersion';
  META_KEY_CLIENT_INFO         = 'io.modelcontextprotocol/clientInfo';
  META_KEY_CLIENT_CAPABILITIES = 'io.modelcontextprotocol/clientCapabilities';
  META_KEY_LOG_LEVEL           = 'io.modelcontextprotocol/logLevel';
  META_KEY_SERVER_INFO         = 'io.modelcontextprotocol/serverInfo';

  RESULT_TYPE_COMPLETE = 'complete';

  // CacheableResult scopes (SEP-2549): whether shared intermediaries
  // may cache a response. "private" is the safe default for local
  // stdio servers.
  CACHE_SCOPE_PRIVATE = 'private';
  CACHE_SCOPE_PUBLIC  = 'public';

type
  // Everything a handler may want to know about the requesting client,
  // extracted from the request's _meta. ClientCapabilities is a
  // borrowed reference into the request tree — valid for the duration
  // of the handler call, never to be freed or retained.
  TMCPRequestContext = record
    ProtocolVersion: string;
    ClientName: string;          // '' when clientInfo absent
    ClientVersion: string;
    ClientCapabilities: TJSONObject;
    LogLevel: string;            // '' when absent
    function HasCapability(const AName: string): Boolean;
  end;

  TMCPMetaError = record
    Code: Integer;
    Message: string;
    Data: TJSONData; // ownership transfers to the caller (nil if none)
  end;

// Validate the required per-request _meta fields and extract the
// context. Returns False with AError filled when the request must be
// rejected: -32602 for missing/malformed fields, -32022 (with a
// data.supported list) for a version outside ASupportedVersions.
function ExtractRequestContext(AParams: TJSONObject;
  const ASupportedVersions: array of string;
  out ACtx: TMCPRequestContext; out AError: TMCPMetaError): Boolean;

// Stamp the fields the spec expects on every result: resultType
// ("complete" unless the builder already set one) and the serverInfo
// identity in _meta (servers SHOULD self-identify on every response).
procedure StampResult(AResult: TJSONObject;
  const AServerName, AServerVersion: string);

// data payload for UnsupportedProtocolVersionError: {supported, requested}.
function BuildUnsupportedVersionData(
  const ASupportedVersions: array of string;
  const ARequested: string): TJSONObject;

// True when AVersion is one of the legacy revisions this library can
// answer through the initialize handshake.
function IsLegacyProtocolVersion(const AVersion: string): Boolean;

implementation

function IsLegacyProtocolVersion(const AVersion: string): Boolean;
var
  Version: string;
begin
  for Version in LEGACY_PROTOCOL_VERSIONS do
    if Version = AVersion then
      Exit(True);
  Result := False;
end;

function TMCPRequestContext.HasCapability(const AName: string): Boolean;
begin
  Result := (ClientCapabilities <> nil) and
    (ClientCapabilities.Find(AName) <> nil);
end;

function MetaError(out AError: TMCPMetaError; ACode: Integer;
  const AText: string; AData: TJSONData = nil): Boolean;
begin
  AError.Code := ACode;
  AError.Message := AText;
  AError.Data := AData;
  Result := False;
end;

function BuildUnsupportedVersionData(
  const ASupportedVersions: array of string;
  const ARequested: string): TJSONObject;
var
  Supported: TJSONArray;
  Version: string;
begin
  Supported := TJSONArray.Create;
  for Version in ASupportedVersions do
    Supported.Add(Version);
  Result := TJSONObject.Create;
  Result.Add('supported', Supported);
  Result.Add('requested', ARequested);
end;

function ExtractRequestContext(AParams: TJSONObject;
  const ASupportedVersions: array of string;
  out ACtx: TMCPRequestContext; out AError: TMCPMetaError): Boolean;
var
  MetaData, VersionData, CapsData, InfoData, LevelData: TJSONData;
  Meta, Info: TJSONObject;
  Version: string;
  Known: Boolean;
begin
  ACtx := Default(TMCPRequestContext);
  AError := Default(TMCPMetaError);

  if AParams = nil then
    Exit(MetaError(AError, JSONRPC_INVALID_PARAMS,
      'Invalid params: missing _meta (required on every request)'));

  MetaData := AParams.Find('_meta');
  if (MetaData = nil) or (MetaData.JSONType <> jtObject) then
    Exit(MetaError(AError, JSONRPC_INVALID_PARAMS,
      'Invalid params: missing _meta (required on every request)'));
  Meta := TJSONObject(MetaData);

  VersionData := Meta.Find(META_KEY_PROTOCOL_VERSION);
  if (VersionData = nil) or (VersionData.JSONType <> jtString) then
    Exit(MetaError(AError, JSONRPC_INVALID_PARAMS,
      'Invalid params: missing _meta["' + META_KEY_PROTOCOL_VERSION + '"]'));
  ACtx.ProtocolVersion := VersionData.AsString;

  CapsData := Meta.Find(META_KEY_CLIENT_CAPABILITIES);
  if (CapsData = nil) or (CapsData.JSONType <> jtObject) then
    Exit(MetaError(AError, JSONRPC_INVALID_PARAMS,
      'Invalid params: missing _meta["' + META_KEY_CLIENT_CAPABILITIES + '"]'));
  ACtx.ClientCapabilities := TJSONObject(CapsData);

  Known := False;
  for Version in ASupportedVersions do
    if Version = ACtx.ProtocolVersion then
    begin
      Known := True;
      Break;
    end;
  if not Known then
    Exit(MetaError(AError, MCP_ERROR_UNSUPPORTED_PROTOCOL_VERSION,
      'Unsupported protocol version',
      BuildUnsupportedVersionData(ASupportedVersions, ACtx.ProtocolVersion)));

  InfoData := Meta.Find(META_KEY_CLIENT_INFO);
  if (InfoData <> nil) and (InfoData.JSONType = jtObject) then
  begin
    Info := TJSONObject(InfoData);
    ACtx.ClientName := Info.Get('name', '');
    ACtx.ClientVersion := Info.Get('version', '');
  end;

  LevelData := Meta.Find(META_KEY_LOG_LEVEL);
  if (LevelData <> nil) and (LevelData.JSONType = jtString) then
    ACtx.LogLevel := LevelData.AsString;

  Result := True;
end;

procedure StampResult(AResult: TJSONObject;
  const AServerName, AServerVersion: string);
var
  MetaData: TJSONData;
  Meta, ServerInfo: TJSONObject;
begin
  if AResult.Find('resultType') = nil then
    AResult.Add('resultType', RESULT_TYPE_COMPLETE);

  MetaData := AResult.Find('_meta');
  if (MetaData <> nil) and (MetaData.JSONType = jtObject) then
    Meta := TJSONObject(MetaData)
  else
  begin
    Meta := TJSONObject.Create;
    AResult.Add('_meta', Meta);
  end;

  if Meta.Find(META_KEY_SERVER_INFO) = nil then
  begin
    ServerInfo := TJSONObject.Create;
    ServerInfo.Add('name', AServerName);
    ServerInfo.Add('version', AServerVersion);
    Meta.Add(META_KEY_SERVER_INFO, ServerInfo);
  end;
end;

end.
