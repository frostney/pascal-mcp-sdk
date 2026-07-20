unit MCP.JSONRPC;

// JSON-RPC 2.0 message layer, restricted to the profile MCP mandates
// (spec revision 2026-07-28, "Base Protocol"): every accepted message
// is a single JSON object. The batch-requiring 2025-03-26 legacy
// revision is deliberately not advertised by this library. Request ids
// are strings or numbers and MUST NOT be null, and params, when present,
// is an object. Wire framing (one message per line) belongs to the
// transport (MCP.Transport.Stdio); this unit only turns one line into a
// decoded message and result/error payloads back into compact single-line
// JSON. Batch requirement verified 2026-07-20:
// modelcontextprotocol.io/specification/2025-03-26/basic
//
// MCP transports carry UTF-8 JSON. This bottom serialization unit links
// the platform RTL widestring manager so fpjson conversions preserve
// UTF-8 bytes for every consumer, including sans-I/O embeddings.
// UTF-8 transport requirement verified 2026-07-20:
// https://modelcontextprotocol.io/specification/draft/basic/transports/stdio
//
// Ownership: TJSONRPCMessage.Raw owns the whole parse tree; Id and
// Params are borrowed views into it. Free with FreeJSONRPCMessage.
// The Build* functions clone the id (so the message can be freed
// independently) and take ownership of the payload they are given.

{$I Shared.inc}

interface

uses
  {$IFDEF UNIX}
  cwstring,
  {$ENDIF}
  {$IFDEF WINDOWS}
  fpwidestring,
  {$ENDIF}
  SysUtils,

  fpjson,
  jsonparser,
  jsonscanner;

const
  JSONRPC_VERSION = '2.0';

  // JSON-RPC 2.0 standard error codes.
  JSONRPC_PARSE_ERROR      = -32700;
  JSONRPC_INVALID_REQUEST  = -32600;
  JSONRPC_METHOD_NOT_FOUND = -32601;
  JSONRPC_INVALID_PARAMS   = -32602;
  JSONRPC_INTERNAL_ERROR   = -32603;

  // MCP-reserved sub-range (-32020..-32099), defined by the spec.
  MCP_ERROR_HEADER_MISMATCH             = -32020;
  MCP_ERROR_MISSING_CLIENT_CAPABILITY   = -32021;
  MCP_ERROR_UNSUPPORTED_PROTOCOL_VERSION = -32022;

type
  TJSONRPCKind = (jrkInvalid, jrkRequest, jrkNotification);

  TJSONRPCMessage = record
    Kind: TJSONRPCKind;
    Method: string;
    Id: TJSONData;       // borrowed from Raw; nil for notifications and
                         // for invalid messages whose id was unreadable
    Params: TJSONObject; // borrowed from Raw; nil when absent
    Raw: TJSONData;      // owns the tree; nil when the line did not parse
    ErrorCode: Integer;  // set when Kind = jrkInvalid
    ErrorMessage: string;
  end;

// Decode one line into a message. Never raises: malformed input comes
// back as Kind = jrkInvalid with the JSON-RPC error to reply with (a
// readable id is preserved so the reply can carry it).
function ParseJSONRPCMessage(const ALine: string): TJSONRPCMessage;

procedure FreeJSONRPCMessage(var AMessage: TJSONRPCMessage);

// Build a response line. AId is cloned (nil becomes JSON null, which
// JSON-RPC prescribes when the request id was unreadable); AResult /
// AData ownership transfers to the response.
function BuildResultResponse(AId: TJSONData; AResult: TJSONObject): string;
// Server-to-client notification line (no id). AParams owned; nil for
// parameter-less notifications.
function BuildNotification(const AMethod: string;
  AParams: TJSONObject): string;
function BuildErrorResponse(AId: TJSONData; ACode: Integer;
  const AMessage: string; AData: TJSONData = nil): string;

// Compact single-line serialization (fpjson escapes embedded newlines,
// which is what keeps the stdio framing invariant).
function SerializeCompact(AData: TJSONData): string;

implementation

function ParseJson(const ALine: string): TJSONData;
var
  Parser: TJSONParser;
begin
  Parser := TJSONParser.Create(ALine, [joUTF8, joStrict]);
  try
    Result := Parser.Parse;
  finally
    Parser.Free;
  end;
end;

function Invalid(var AMessage: TJSONRPCMessage; ACode: Integer;
  const AText: string): TJSONRPCMessage;
begin
  AMessage.Kind := jrkInvalid;
  AMessage.ErrorCode := ACode;
  AMessage.ErrorMessage := AText;
  Result := AMessage;
end;

function ParseJSONRPCMessage(const ALine: string): TJSONRPCMessage;
var
  Obj: TJSONObject;
  Version, IdData, MethodData, ParamsData: TJSONData;
begin
  Result := Default(TJSONRPCMessage);

  try
    Result.Raw := ParseJson(ALine);
  except
    on E: Exception do
      Exit(Invalid(Result, JSONRPC_PARSE_ERROR, 'Parse error: ' + E.Message));
  end;

  if (Result.Raw = nil) or (Result.Raw.JSONType <> jtObject) then
    Exit(Invalid(Result, JSONRPC_INVALID_REQUEST,
      'Invalid request: expected a JSON object (MCP does not support batching)'));
  Obj := TJSONObject(Result.Raw);

  // A readable id is captured before any validation so error replies
  // can echo it (JSON-RPC 2.0 §5).
  IdData := Obj.Find('id');
  if (IdData <> nil) and (IdData.JSONType in [jtString, jtNumber]) then
    Result.Id := IdData;

  Version := Obj.Find('jsonrpc');
  if (Version = nil) or (Version.JSONType <> jtString) or
     (Version.AsString <> JSONRPC_VERSION) then
    Exit(Invalid(Result, JSONRPC_INVALID_REQUEST,
      'Invalid request: jsonrpc must be "2.0"'));

  MethodData := Obj.Find('method');
  if (MethodData = nil) or (MethodData.JSONType <> jtString) then
    Exit(Invalid(Result, JSONRPC_INVALID_REQUEST,
      'Invalid request: method must be a string'));
  Result.Method := MethodData.AsString;

  if (IdData <> nil) and (Result.Id = nil) then
    Exit(Invalid(Result, JSONRPC_INVALID_REQUEST,
      'Invalid request: id must be a string or number (null is not allowed)'));

  ParamsData := Obj.Find('params');
  if ParamsData <> nil then
  begin
    if ParamsData.JSONType <> jtObject then
      Exit(Invalid(Result, JSONRPC_INVALID_REQUEST,
        'Invalid request: params must be an object'));
    Result.Params := TJSONObject(ParamsData);
  end;

  if IdData = nil then
    Result.Kind := jrkNotification
  else
    Result.Kind := jrkRequest;
end;

procedure FreeJSONRPCMessage(var AMessage: TJSONRPCMessage);
begin
  FreeAndNil(AMessage.Raw);
  AMessage.Id := nil;
  AMessage.Params := nil;
  AMessage.Kind := jrkInvalid;
end;

function CloneId(AId: TJSONData): TJSONData;
begin
  if AId = nil then
    Result := TJSONNull.Create
  else
    Result := AId.Clone;
end;

function BuildResultResponse(AId: TJSONData; AResult: TJSONObject): string;
var
  Response: TJSONObject;
begin
  Response := TJSONObject.Create;
  try
    Response.Add('jsonrpc', JSONRPC_VERSION);
    Response.Add('id', CloneId(AId));
    Response.Add('result', AResult);
    Result := SerializeCompact(Response);
  finally
    Response.Free;
  end;
end;

function BuildNotification(const AMethod: string;
  AParams: TJSONObject): string;
var
  Notification: TJSONObject;
begin
  Notification := TJSONObject.Create;
  try
    Notification.Add('jsonrpc', JSONRPC_VERSION);
    Notification.Add('method', AMethod);
    if AParams <> nil then
      Notification.Add('params', AParams);
    Result := SerializeCompact(Notification);
  finally
    Notification.Free;
  end;
end;

function BuildErrorResponse(AId: TJSONData; ACode: Integer;
  const AMessage: string; AData: TJSONData): string;
var
  Response, ErrorObj: TJSONObject;
begin
  Response := TJSONObject.Create;
  try
    Response.Add('jsonrpc', JSONRPC_VERSION);
    Response.Add('id', CloneId(AId));
    ErrorObj := TJSONObject.Create;
    ErrorObj.Add('code', ACode);
    ErrorObj.Add('message', AMessage);
    if AData <> nil then
      ErrorObj.Add('data', AData);
    Response.Add('error', ErrorObj);
    Result := SerializeCompact(Response);
  finally
    Response.Free;
  end;
end;

function SerializeCompact(AData: TJSONData): string;
begin
  Result := AData.AsJSON;
end;

{$IFDEF WINDOWS}
initialization
  SetMultiByteConversionCodePage(CP_UTF8);
{$ENDIF}

end.
