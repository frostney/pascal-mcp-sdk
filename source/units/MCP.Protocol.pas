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
//       modelcontextprotocol.io/specification/2026-07-28/basic/index#meta
//   - version negotiation, UnsupportedProtocolVersionError (-32022):
//       modelcontextprotocol.io/specification/2026-07-28/basic/versioning
//   - exact lowercase RFC 5424-derived logging levels:
//       modelcontextprotocol.io/specification/2026-07-28/server/utilities/logging
//   - cooperative request cancellation:
//       https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/cancellation
//     (verified 2026-07-21)

{$I MCP.inc}

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
  // 2025-03-26 is deliberately omitted because its Base Protocol requires
  // receivers to accept JSON-RPC batches, which this library does not.
  // Verified 2026-07-20:
  // modelcontextprotocol.io/specification/2025-03-26/basic
  LATEST_LEGACY_PROTOCOL_VERSION = '2025-11-25';
  LEGACY_PROTOCOL_VERSIONS: array[0..2] of string = (
    '2025-11-25', '2025-06-18', '2024-11-05');

  // Legacy-era resource-not-found code (2025-11-25 and earlier). The
  // modern revision replaced it with -32602 and forbids emitting it;
  // a dual-era server still owes it to legacy clients.
  MCP_ERROR_LEGACY_RESOURCE_NOT_FOUND = -32002;

  META_KEY_PROTOCOL_VERSION    = 'io.modelcontextprotocol/protocolVersion';
  META_KEY_CLIENT_INFO         = 'io.modelcontextprotocol/clientInfo';
  META_KEY_CLIENT_CAPABILITIES = 'io.modelcontextprotocol/clientCapabilities';
  META_KEY_LOG_LEVEL           = 'io.modelcontextprotocol/logLevel';
  META_KEY_SERVER_INFO         = 'io.modelcontextprotocol/serverInfo';

  // Exact lowercase logging levels from the official specification,
  // verified 2026-07-20. Their order is increasing severity.
  MCP_LOG_LEVELS: array[0..7] of string = (
    'debug', 'info', 'notice', 'warning',
    'error', 'critical', 'alert', 'emergency');

  RESULT_TYPE_COMPLETE = 'complete';
  // MRTR interim results (SEP-2322): the request needs additional
  // input; the client retries the original request with
  // inputResponses/requestState. Verified 2026-08-08:
  // https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr
  RESULT_TYPE_INPUT_REQUIRED = 'input_required';

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
  // Signature of the server's notification emitter, surfaced to
  // handlers through the request context. AParams ownership transfers
  // to the emitter. Nil when the active transport cannot deliver
  // server-to-client notifications.
  TMCPNotifier = procedure(const AMethod: string;
    AParams: TJSONObject) of object;

  // Cooperative cancellation probe supplied by the dispatch layer.
  // A handler polls TMCPRequestContext.IsCancelled and abandons work
  // when it becomes true; there is no interruption or exception
  // injection. Nil means the request cannot currently be cancelled.
  TMCPCancellationProbe = function: Boolean of object;

  // Call-scoped handler context. The record and its object-bound
  // Notifier/CancellationProbe callbacks are valid only for the duration
  // of the synchronous handler invocation and must not be retained.
  TMCPRequestContext = record
    ProtocolVersion: string;
    ClientName: string;          // '' when clientInfo absent
    ClientVersion: string;
    ClientCapabilities: TJSONObject;
    LogLevel: string;            // '' when absent
    // progressToken from params._meta (both eras): opaque string or
    // number, preserved verbatim for echoing into
    // notifications/progress.
    HasProgressToken: Boolean;
    ProgressToken: string;
    ProgressTokenIsString: Boolean;
    // MRTR retry payload (modern era only; spec pattern verified
    // 2026-08-08, see RESULT_TYPE_INPUT_REQUIRED): inputResponses is
    // borrowed from the request tree (nil when this is not a retry);
    // RequestState is the client's echo as received ('' when absent);
    // MCP.Server verifies that sealed token and replaces it with the
    // handler's own state before any handler runs (#89), because the
    // spec makes requestState attacker-controlled input.
    InputResponses: TJSONObject;
    RequestState: string;
    // The request's whole params._meta object, borrowed for the handler
    // call (nil when absent, as a classic-era request may leave it), for
    // keys the library does not interpret, such as W3C trace context
    // (#96). Read-only: the server still reads parts of it after the
    // handler returns, so clone what you keep or change, and never free
    // it.
    Meta: TJSONObject;
    // Set by the dispatching server, not by ExtractRequestContext.
    Notifier: TMCPNotifier;
    // Set by the dispatching server. It also consults the transport's
    // cancellation poll (#93), so a notifications/cancelled waiting on
    // stdin or a closed HTTP connection turns it true while the handler
    // runs.
    CancellationProbe: TMCPCancellationProbe;
    // Set by the dispatching server for a 2026-07-28 request (#126): the
    // request's JSON-RPC id, borrowed for the call, and the session's
    // stream host (a TMCPStreamHost, MCP.Streams), where a handler parks
    // a stream the transport drives after it returns; nil when the
    // transport cannot stream.
    RequestId: TJSONData;
    StreamHost: TObject;
    // True when clientCapabilities declare AName. For a 2026-07-28
    // request, a capability that schema defines counts only in its
    // shape (an object; sampling's and elicitation's typed members
    // objects too), so null or false declares nothing; any other name
    // is the client's own and counts when its key is present, whatever
    // its value. A classic-handshake client, whose capabilities follow
    // its own revision's schema, counts by presence alone.
    function HasCapability(const AName: string): Boolean;
    // True when the client declared capability AName (HasCapability)
    // with member AMember, such as elicitation's "url" or sampling's
    // "tools" (#108). An empty elicitation object declares "form", as
    // the specification reads it for backwards compatibility.
    function HasSubCapability(const AName, AMember: string): Boolean;
    // The client declared extension AId in clientCapabilities.extensions
    // (#98; versioning#extension-negotiation, verified 2026-11-26).
    function HasExtension(const AId: string): Boolean;
    // The client's settings object for extension AId, borrowed for the
    // handler call; nil when not declared or not an object.
    function ExtensionSettings(const AId: string): TJSONObject;
    function IsCancelled: Boolean;
  end;

  TMCPMetaError = record
    Code: Integer;
    Message: string;
    Data: TJSONData; // ownership transfers to the caller (nil if none)
  end;

// Pull params._meta.progressToken (string or number) into ACtx.
// Exposed separately because the legacy dispatch path builds its
// context from handshake state, not from ExtractRequestContext.
procedure ExtractProgressToken(AMeta: TJSONObject;
  var ACtx: TMCPRequestContext);

// The first required per-request field AParams lacks ('_meta', or the
// _meta key of protocolVersion or clientCapabilities, each with its
// required JSON type), or '' when all are present. A request missing
// one is malformed: -32602, and on HTTP 400 Bad Request (#79), verified
// 2026-11-26 against
// https://modelcontextprotocol.io/specification/2026-07-28/basic/index#_meta
// Transports use it to tell that rejection from other -32602 errors,
// which stay in-band. AParams is borrowed and may be nil (no params).
function MissingRequiredMeta(AParams: TJSONObject): string;

// Validate the required per-request _meta fields and extract the
// context. Returns False with AError filled when the request must be
// rejected: -32602 for missing/malformed fields, -32022 (with a
// data.supported list) for a version outside ASupportedVersions.
function ExtractRequestContext(AParams: TJSONObject;
  const ASupportedVersions: array of string;
  out ACtx: TMCPRequestContext; out AError: TMCPMetaError): Boolean;

// The {name, version} server identity object. Returns a fresh owned
// object; the caller transfers it into a result tree or frees it.
// Lives here because this unit owns response identity: the _meta stamp
// below and the top-level serverInfo of initialize and discover results
// share these name and version fields (the top-level one may carry the
// server's other Implementation fields too, #96).
function BuildServerInfo(const AName, AVersion: string): TJSONObject;

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

// -32021 MissingRequiredClientCapability data payload:
// {requiredCapabilities: {<ACapability>: {}}}. Fresh, owned by the
// caller.
function BuildMissingCapabilityData(const ACapability: string): TJSONObject;
  overload;
// The same with every capability in ACapabilities, so a client learns
// all it lacks from one refusal (#84). ACapabilities must be non-empty
// and free of repeats, else EArgumentException before anything is
// allocated: -32021 data names each capability once, at least one.
function BuildMissingCapabilityData(
  const ACapabilities: array of string): TJSONObject; overload;
// The same naming one member of ACapability (both non-empty, else
// EArgumentException): {"requiredCapabilities":{"elicitation":
// {"url":{}}}} for a missing elicitation.url (#108).
function BuildMissingCapabilityData(const ACapability,
  AMember: string): TJSONObject; overload;

// True when AData is valid -32021 data: an object whose
// requiredCapabilities is a ClientCapabilities object naming at least
// one capability, each shaped as the schema types it. AData is
// borrowed and may be nil.
function IsMissingCapabilityData(AData: TJSONData): Boolean;

// The requestId of a well-formed notifications/cancelled (borrowed from
// AMessage), or nil: params present, and a reason absent or a string.
// A malformed reason invalidates the whole notification. Spec verified
// 2026-07-21:
// https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/cancellation
function CancellationRequestId(const AMessage: TJSONRPCMessage): TJSONData;

// Whether AId is an extension identifier: a _meta key with its
// mandatory prefix (dot-separated labels of letters, digits and
// hyphens, each starting with a letter and ending with a letter or
// digit), a slash, and a name, possibly empty, of letters, digits, '-',
// '_' and '.' that starts and ends with a letter or digit. Verified 2026-11-26 against
// https://modelcontextprotocol.io/specification/2026-07-28/basic/index#_meta.
function IsExtensionId(const AId: string): Boolean;

// Capability gating (moved from MCP.Server for its size, #98): the
// capability an input request needs, the ones a request lacks, and the
// automatic -32021 for them.

// AInputRequests is borrowed. Entries are checked in order and the
// first problem wins. '' when every entry names a kind the client
// declared, with the member of that capability it needs (an
// elicitation mode, sampling.tools for a request with tools or
// toolChoice); otherwise the first missing capability, and in
// AMissingMember the member it lacks, or '' when the capability alone
// is missing and enough. AUnknownKind carries the method of an entry
// that is not an MRTR kind at all, and stays non-empty for a malformed
// entry too — one that is not an object, carries no string "method",
// or asks for an elicitation mode other than form or url — so callers
// can keep testing it with a single `<> ''` guard and never emit such
// a map on the wire.
function MissingInputCapability(AInputRequests: TJSONObject;
  const ACtx: TMCPRequestContext; out AUnknownKind,
  AMissingMember: string): string;

// The automatic -32021 for a subject lacking ANames (not empty), both
// for declared needs (#84) and for a run-time input request.
function MissingCapabilityResponse(const AMessage: TJSONRPCMessage;
  const ASubjectKind, ASubjectName: string;
  const ANames: array of string): string;
// The same for one member of ACapability (#108): the message names
// "elicitation.url", the data {"elicitation":{"url":{}}}.
function MissingMemberResponse(const AMessage: TJSONRPCMessage;
  const ASubjectKind, ASubjectName, ACapability, AMember: string): string;

// The declared capabilities ACtx lacks, in declaration order (#84).
function MissingDeclaredCapabilities(const ARequired: array of string;
  const ACtx: TMCPRequestContext): TStringArray;

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

function IsCapabilityEntry(const AName: string; AValue: TJSONData): Boolean;
  forward;

// The index of AName's member in AObject, or -1. A linear scan:
// TJSONObject.IndexOfName misses a member stored as nil, which fpjson
// writes as null and which is still a present key.
function MemberPosition(AObject: TJSONObject; const AName: string): Integer;
begin
  for Result := 0 to AObject.Count - 1 do
    if AObject.Names[Result] = AName then
      Exit;
  Result := -1;
end;

// A capability the 2026-07-28 ClientCapabilities schema defines counts
// as declared only in its shape: "sampling": null or false declares
// nothing (#84 review). The set is open, so another name counts when its
// key is present. Classic-handshake capabilities follow older schemas
// (2025-06-18 has "sampling": {"tools": true}), so there presence alone
// counts, as before #84.
function TMCPRequestContext.HasCapability(const AName: string): Boolean;
var
  Position: Integer;
begin
  if ClientCapabilities = nil then
    Exit(False);
  if IsLegacyProtocolVersion(ProtocolVersion) then
    Exit(ClientCapabilities.Find(AName) <> nil);
  Position := MemberPosition(ClientCapabilities, AName);
  Result := (Position >= 0) and
    IsCapabilityEntry(AName, ClientCapabilities.Items[Position]);
end;

function TMCPRequestContext.HasSubCapability(const AName,
  AMember: string): Boolean;
var
  Capability: TJSONData;
begin
  if not HasCapability(AName) then
    Exit(False);
  Capability := ClientCapabilities.Find(AName);
  // A classic client's capability counts by presence, so it may be no
  // object: then it declares no member.
  if (Capability = nil) or (Capability.JSONType <> jtObject) then
    Exit(False);
  // "an empty capabilities object is equivalent to declaring support
  // for form mode only" (client/elicitation#capabilities, 2026-07-28 and
  // 2025-11-25, verified 2026-11-27); 2025-06-18 has only the empty
  // object.
  if (AName = 'elicitation') and (AMember = 'form') and
    (Capability.Count = 0) then
    Exit(True);
  // HasCapability checked a 2026-07-28 request's typed members' shapes.
  Result := MemberPosition(TJSONObject(Capability), AMember) >= 0;
end;

function TMCPRequestContext.ExtensionSettings(const AId: string): TJSONObject;
var
  Extensions, Settings: TJSONData;
begin
  Result := nil;
  if ClientCapabilities = nil then
    Exit;
  Extensions := ClientCapabilities.Find('extensions');
  if (Extensions = nil) or (Extensions.JSONType <> jtObject) then
    Exit;
  Settings := TJSONObject(Extensions).Find(AId);
  if (Settings <> nil) and (Settings.JSONType = jtObject) then
    Result := TJSONObject(Settings);
end;

function TMCPRequestContext.HasExtension(const AId: string): Boolean;
begin
  Result := ExtensionSettings(AId) <> nil;
end;

function TMCPRequestContext.IsCancelled: Boolean;
begin
  Result := Assigned(CancellationProbe) and CancellationProbe;
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

function MissingRequiredMeta(AParams: TJSONObject): string;
var
  MetaData, FieldData: TJSONData;
  Meta: TJSONObject;
begin
  if AParams = nil then
    Exit('_meta');
  MetaData := AParams.Find('_meta');
  if (MetaData = nil) or (MetaData.JSONType <> jtObject) then
    Exit('_meta');
  Meta := TJSONObject(MetaData);
  FieldData := Meta.Find(META_KEY_PROTOCOL_VERSION);
  if (FieldData = nil) or (FieldData.JSONType <> jtString) then
    Exit('_meta["' + META_KEY_PROTOCOL_VERSION + '"]');
  FieldData := Meta.Find(META_KEY_CLIENT_CAPABILITIES);
  if (FieldData = nil) or (FieldData.JSONType <> jtObject) then
    Exit('_meta["' + META_KEY_CLIENT_CAPABILITIES + '"]');
  Result := '';
end;

function ExtractRequestContext(AParams: TJSONObject;
  const ASupportedVersions: array of string;
  out ACtx: TMCPRequestContext; out AError: TMCPMetaError): Boolean;
var
  InfoData, LevelData: TJSONData;
  ResponsesData, StateData: TJSONData;
  Meta, Info: TJSONObject;
  Version, Level, Missing: string;
  Known: Boolean;
begin
  ACtx := Default(TMCPRequestContext);
  AError := Default(TMCPMetaError);

  Missing := MissingRequiredMeta(AParams);
  if Missing = '_meta' then
    Exit(MetaError(AError, JSONRPC_INVALID_PARAMS,
      'Invalid params: missing _meta (required on every request)'));
  if Missing <> '' then
    Exit(MetaError(AError, JSONRPC_INVALID_PARAMS,
      'Invalid params: missing ' + Missing));

  // MissingRequiredMeta checked presence and type of all three.
  Meta := TJSONObject(AParams.Find('_meta'));
  ACtx.ProtocolVersion := Meta.Find(META_KEY_PROTOCOL_VERSION).AsString;
  ACtx.ClientCapabilities :=
    TJSONObject(Meta.Find(META_KEY_CLIENT_CAPABILITIES));

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
  if LevelData <> nil then
  begin
    if LevelData.JSONType <> jtString then
      Exit(MetaError(AError, JSONRPC_INVALID_PARAMS,
        'Invalid params: _meta["' + META_KEY_LOG_LEVEL +
        '"] must be a string'));
    ACtx.LogLevel := LevelData.AsString;
    Known := False;
    for Level in MCP_LOG_LEVELS do
      if Level = ACtx.LogLevel then
      begin
        Known := True;
        Break;
      end;
    if not Known then
      Exit(MetaError(AError, JSONRPC_INVALID_PARAMS,
        'Invalid params: unknown _meta["' + META_KEY_LOG_LEVEL + '"] value'));
  end;

  ExtractProgressToken(Meta, ACtx);
  ACtx.Meta := Meta;

  // MRTR retry payload: top-level params fields on the supported
  // client requests (InputResponseRequestParams in the schema anchor).
  ResponsesData := AParams.Find('inputResponses');
  if ResponsesData <> nil then
  begin
    if ResponsesData.JSONType <> jtObject then
      Exit(MetaError(AError, JSONRPC_INVALID_PARAMS,
        'Invalid params: inputResponses must be an object'));
    ACtx.InputResponses := TJSONObject(ResponsesData);
  end;
  StateData := AParams.Find('requestState');
  if StateData <> nil then
  begin
    if StateData.JSONType <> jtString then
      Exit(MetaError(AError, JSONRPC_INVALID_PARAMS,
        'Invalid params: requestState must be a string'));
    ACtx.RequestState := StateData.AsString;
  end;

  Result := True;
end;

procedure ExtractProgressToken(AMeta: TJSONObject;
  var ACtx: TMCPRequestContext);
var
  TokenData: TJSONData;
begin
  if AMeta = nil then
    Exit;
  TokenData := AMeta.Find('progressToken');
  if TokenData = nil then
    Exit;
  case TokenData.JSONType of
    jtString:
      begin
        ACtx.HasProgressToken := True;
        ACtx.ProgressTokenIsString := True;
        ACtx.ProgressToken := TokenData.AsString;
      end;
    jtNumber:
      begin
        ACtx.HasProgressToken := True;
        ACtx.ProgressTokenIsString := False;
        ACtx.ProgressToken := TokenData.AsJSON;
      end;
  end;
end;

function BuildServerInfo(const AName, AVersion: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('name', AName);
  Result.Add('version', AVersion);
end;

procedure StampResult(AResult: TJSONObject;
  const AServerName, AServerVersion: string);
var
  MetaData: TJSONData;
  Meta: TJSONObject;
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
    Meta.Add(META_KEY_SERVER_INFO,
      BuildServerInfo(AServerName, AServerVersion));
end;

// -32021 data payload: {requiredCapabilities: {<name>: {}}} (schema
// anchor MissingRequiredClientCapabilityError, verified 2026-08-08).
function BuildMissingCapabilityData(const ACapability: string): TJSONObject;
begin
  Result := BuildMissingCapabilityData([ACapability]);
end;

function BuildMissingCapabilityData(
  const ACapabilities: array of string): TJSONObject;
var
  Capabilities: TJSONObject;
  Name: string;
  I, J: Integer;
begin
  if Length(ACapabilities) = 0 then
    raise EArgumentException.Create(
      'BuildMissingCapabilityData needs at least one capability');
  for I := 1 to High(ACapabilities) do
    for J := 0 to I - 1 do
      if ACapabilities[I] = ACapabilities[J] then
        raise EArgumentException.CreateFmt(
          'BuildMissingCapabilityData names "%s" twice', [ACapabilities[I]]);
  Result := TJSONObject.Create;
  try
    Capabilities := TJSONObject.Create;
    Result.Add('requiredCapabilities', Capabilities);
    for Name in ACapabilities do
      Capabilities.Add(Name, TJSONObject.Create);
  except
    Result.Free;
    raise;
  end;
end;

function BuildMissingCapabilityData(const ACapability,
  AMember: string): TJSONObject;
var
  Capability: TJSONObject;
begin
  if (ACapability = '') or (AMember = '') then
    raise EArgumentException.Create(
      'BuildMissingCapabilityData needs a capability and a member');
  Result := BuildMissingCapabilityData([ACapability]);
  Capability := TJSONObject(TJSONObject(Result.Find('requiredCapabilities'))
    .Find(ACapability));
  try
    Capability.Add(AMember, TJSONObject.Create);
  except
    Result.Free;
    raise;
  end;
end;

function IsJSONObjectValue(AData: TJSONData): Boolean;
begin
  Result := (AData <> nil) and (AData.JSONType = jtObject);
end;

// True when every member of AObject that AFields names (all members
// when AFields is empty) is a JSON object.
function MembersAreObjects(AObject: TJSONObject;
  const AFields: array of string): Boolean;
var
  I, Position: Integer;
begin
  if Length(AFields) = 0 then
  begin
    for I := 0 to AObject.Count - 1 do
      if not IsJSONObjectValue(AObject.Items[I]) then
        Exit(False);
    Exit(True);
  end;
  // By key, so a typed member stored as nil (written as null) fails the
  // shape, as a parsed null does (#108 review).
  for I := 0 to High(AFields) do
  begin
    Position := MemberPosition(AObject, AFields[I]);
    if (Position >= 0) and not IsJSONObjectValue(AObject.Items[Position]) then
      Exit(False);
  end;
  Result := True;
end;

// One present entry of a ClientCapabilities object against its schema:
// a capability the schema defines is an object, and the members it
// types are objects too (sampling.context/tools, elicitation.form/url,
// each experimental and extensions entry). The set is open ("any client
// can define its own, additional capabilities", schema 2026-07-28,
// verified 2026-11-27), and the schema leaves such a value
// unconstrained, so another name is valid with any value, nil (a member
// stored as nil, written as null) included (#84 review). Callers
// establish that the key is present.
function IsCapabilityEntry(const AName: string; AValue: TJSONData): Boolean;
begin
  if (AName <> 'sampling') and (AName <> 'elicitation') and
    (AName <> 'roots') and (AName <> 'experimental') and
    (AName <> 'extensions') then
    Exit(True);
  Result := IsJSONObjectValue(AValue);
  if not Result then
    Exit;
  if AName = 'sampling' then
    Result := MembersAreObjects(TJSONObject(AValue), ['context', 'tools'])
  else if AName = 'elicitation' then
    Result := MembersAreObjects(TJSONObject(AValue), ['form', 'url'])
  else if (AName = 'experimental') or (AName = 'extensions') then
    Result := MembersAreObjects(TJSONObject(AValue), []);
end;

// -32021's data MUST carry requiredCapabilities, a ClientCapabilities
// object (schema MissingRequiredClientCapabilityError, verified
// 2026-11-27 against schema/2026-07-28/schema.json); this one also
// needs it to name at least one capability.
function IsMissingCapabilityData(AData: TJSONData): Boolean;
var
  Required: TJSONData;
  I: Integer;
begin
  if not IsJSONObjectValue(AData) then
    Exit(False);
  Required := TJSONObject(AData).Find('requiredCapabilities');
  if not IsJSONObjectValue(Required) or (Required.Count = 0) then
    Exit(False);
  for I := 0 to Required.Count - 1 do
    if not IsCapabilityEntry(TJSONObject(Required).Names[I],
      Required.Items[I]) then
      Exit(False);
  Result := True;
end;


function CancellationRequestId(const AMessage: TJSONRPCMessage): TJSONData;
var
  ReasonData: TJSONData;
begin
  Result := nil;
  if (AMessage.Kind <> jrkNotification) or
    (AMessage.Method <> 'notifications/cancelled') or
    (AMessage.Params = nil) then
    Exit;
  ReasonData := AMessage.Params.Find('reason');
  if (ReasonData = nil) or (ReasonData.JSONType = jtString) then
    Result := AMessage.Params.Find('requestId');
end;


function IsExtensionId(const AId: string): Boolean;
var
  Slash, I, J: Integer;
  Prefix, Name: string;
  Labels: TStringArray;
begin
  Result := False;
  Slash := Pos('/', AId);
  if Slash < 2 then
    Exit;
  Prefix := Copy(AId, 1, Slash - 1);
  Name := Copy(AId, Slash + 1, MaxInt);
  // The name may be empty ("com.example/"), as the _meta rules allow.
  if (Name <> '') and (not (Name[1] in ['A'..'Z', 'a'..'z', '0'..'9']) or
    not (Name[Length(Name)] in ['A'..'Z', 'a'..'z', '0'..'9'])) then
    Exit;
  for I := 1 to Length(Name) do
    if not (Name[I] in ['A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.']) then
      Exit;
  Labels := Prefix.Split(['.']);
  for I := 0 to High(Labels) do
  begin
    if (Labels[I] = '') or not (Labels[I][1] in ['A'..'Z', 'a'..'z']) or
      not (Labels[I][Length(Labels[I])] in ['A'..'Z', 'a'..'z', '0'..'9']) then
      Exit;
    for J := 1 to Length(Labels[I]) do
      if not (Labels[I][J] in ['A'..'Z', 'a'..'z', '0'..'9', '-']) then
        Exit;
  end;
  Result := True;
end;

// The client capability each embedded request kind requires. '' for
// an unrecognized kind (rejected separately — the library only emits
// the three MRTR kinds).
function CapabilityForInputRequest(const AMethod: string): string;
begin
  if AMethod = 'elicitation/create' then
    Result := 'elicitation'
  else if AMethod = 'sampling/createMessage' then
    Result := 'sampling'
  else if AMethod = 'roots/list' then
    Result := 'roots'
  else
    Result := '';
end;

// The member of its capability that input request AEntry (borrowed, an
// object) needs, in AMember ('' for none): for elicitation/create its
// mode, form when absent, and for sampling/createMessage "tools" when
// it carries tools or toolChoice. False for a mode other than "form"
// or "url". elicitation: "Servers MUST NOT send elicitation requests
// with modes that are not supported by the client", "form mode
// requests MAY omit mode"; sampling: "Servers MUST NOT send
// tool-enabled sampling requests to Clients that have not declared
// support for tool use via the sampling.tools capability"
// (client/elicitation#capabilities, #elicitation-requests and
// client/sampling#tools-in-sampling, 2026-07-28, verified 2026-11-27).
// Members are found by key, so one a caller stored as nil counts.
function InputRequestMember(const AMethod: string; AEntry: TJSONObject;
  out AMember: string): Boolean;
var
  Params, Mode: TJSONData;
  Position: Integer;
begin
  Result := True;
  AMember := '';
  Params := AEntry.Find('params');
  if not IsJSONObjectValue(Params) then
    Params := nil;
  if AMethod = 'elicitation/create' then
  begin
    AMember := 'form';
    if Params = nil then
      Exit;
    Position := MemberPosition(TJSONObject(Params), 'mode');
    if Position < 0 then
      Exit;
    Mode := TJSONObject(Params).Items[Position];
    if (Mode = nil) or (Mode.JSONType <> jtString) or
      ((Mode.AsString <> 'form') and (Mode.AsString <> 'url')) then
      Exit(False);
    AMember := Mode.AsString;
  end
  else if (AMethod = 'sampling/createMessage') and (Params <> nil) and
    ((MemberPosition(TJSONObject(Params), 'tools') >= 0) or
    (MemberPosition(TJSONObject(Params), 'toolChoice') >= 0)) then
    AMember := 'tools';
end;

// The contract is at the declaration.
function MissingInputCapability(AInputRequests: TJSONObject;
  const ACtx: TMCPRequestContext; out AUnknownKind,
  AMissingMember: string): string;
var
  I: Integer;
  Entry, MethodData: TJSONData;
  Method, Capability, Member: string;
begin
  Result := '';
  AUnknownKind := '';
  AMissingMember := '';
  if AInputRequests = nil then
    Exit;
  for I := 0 to AInputRequests.Count - 1 do
  begin
    Entry := AInputRequests.Items[I];
    Method := '';
    // An entry stored as nil is malformed too (#96 review).
    if (Entry <> nil) and (Entry.JSONType = jtObject) then
    begin
      MethodData := TJSONObject(Entry).Find('method');
      if (MethodData <> nil) and (MethodData.JSONType = jtString) then
        Method := MethodData.AsString;
    end;
    Capability := CapabilityForInputRequest(Method);
    if Capability = '' then
    begin
      // A malformed entry has no method to quote back; the placeholder
      // keeps the unknown-kind signal distinguishable from success.
      if Method = '' then
        AUnknownKind := '(missing method)'
      else
        AUnknownKind := Method;
      Exit;
    end;
    if not InputRequestMember(Method, TJSONObject(Entry), Member) then
    begin
      AUnknownKind := Method + ' with an unknown mode';
      Exit;
    end;
    if not ACtx.HasCapability(Capability) then
    begin
      // An empty elicitation object would do for form mode.
      if Member <> 'form' then
        AMissingMember := Member;
      Exit(Capability);
    end;
    if (Member <> '') and not ACtx.HasSubCapability(Capability, Member) then
    begin
      AMissingMember := Member;
      Exit(Capability);
    end;
  end;
end;

// 'capability "a"' or 'capabilities "a", "b"' for a -32021 message.
function CapabilityList(const ANames: array of string): string;
var
  I: Integer;
begin
  if Length(ANames) = 1 then
    Exit('capability "' + ANames[0] + '"');
  Result := 'capabilities';
  for I := 0 to High(ANames) do
  begin
    if I > 0 then
      Result := Result + ',';
    Result := Result + ' "' + ANames[I] + '"';
  end;
end;

// The automatic -32021 for a subject lacking ANames (not empty), both
// for declared needs (#84) and for a run-time input request.
function MissingCapabilityResponse(const AMessage: TJSONRPCMessage;
  const ASubjectKind, ASubjectName: string;
  const ANames: array of string): string;
begin
  Result := BuildErrorResponse(AMessage.Id, MCP_ERROR_MISSING_CLIENT_CAPABILITY,
    ASubjectKind + ' "' + ASubjectName + '" requires the client ' +
    CapabilityList(ANames), BuildMissingCapabilityData(ANames));
end;

function MissingMemberResponse(const AMessage: TJSONRPCMessage;
  const ASubjectKind, ASubjectName, ACapability, AMember: string): string;
begin
  Result := BuildErrorResponse(AMessage.Id, MCP_ERROR_MISSING_CLIENT_CAPABILITY,
    ASubjectKind + ' "' + ASubjectName + '" requires the client ' +
    'capability "' + ACapability + '.' + AMember + '"',
    BuildMissingCapabilityData(ACapability, AMember));
end;

// The declared capabilities ACtx lacks, in declaration order (#84).
function MissingDeclaredCapabilities(const ARequired: array of string;
  const ACtx: TMCPRequestContext): TStringArray;
var
  Name: string;
begin
  Result := nil;
  for Name in ARequired do
    if not ACtx.HasCapability(Name) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Name;
    end;
end;

end.
