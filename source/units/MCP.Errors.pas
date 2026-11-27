{ MCP.Errors — the exceptions the library raises and handlers raise:
  EMCPServer for a misuse of the API, EMCPProtocolError for a JSON-RPC
  error a handler answers with (#88), and the error codes a handler may
  use. MCP.Server declares both under the same names, so code that uses
  only MCP.Server keeps raising and catching them; they live here so
  units below the server, and extensions, can use them too (#118). }

unit MCP.Errors;

{$I MCP.inc}

interface

uses
  SysUtils,

  fpjson,
  MCP.JSONRPC;

const
  // General-purpose codes SEP-3415 (the Events extension) allocates
  // after -32022, each with typed data (verified 2026-11-27 against
  // ext-events specification/beta/events/events.mdx at c77b843, Error
  // Handling): an unknown entity (data.kind), a principal not permitted,
  // a limit reached (data.limit), an option not supported here
  // (data.feature), and a webhook endpoint that failed.
  MCP_ERROR_NOT_FOUND = -32023;
  MCP_ERROR_FORBIDDEN = -32024;
  MCP_ERROR_RESOURCE_EXHAUSTED = -32025;
  MCP_ERROR_UNSUPPORTED = -32026;
  MCP_ERROR_CALLBACK_ENDPOINT = -32027;

type
  EMCPServer = class(Exception);

  // A JSON-RPC error a handler answers with instead of a result (#88).
  // Raised from a tools/call, prompts/get or resources/read handler
  // (typed and template handlers included), or from an extension's
  // method, it becomes the error response with exactly this code,
  // message and data, in both eras; it is deliberate, so
  // RedactErrorDetails leaves it alone: its message and data reach the
  // client verbatim, so keep secrets out. Every other exception keeps its
  // mapping (tools: in-band isError; prompts and resources: -32603).
  //
  // Allowed codes: the JSON-RPC ones (-32700, -32600 to -32603), the
  // MCP-defined -32021 (MissingRequiredClientCapability; build it with
  // MCPMissingCapabilityError) and -32023 to -32027 (the codes above),
  // and application codes outside the reserved -32768..-32000 range.
  // Any other code is reserved for a meaning the spec defines elsewhere
  // or for legacy use, so the constructor raises EMCPServer for it (and
  // frees AData). Error-code policy verified 2026-11-26 against
  // https://modelcontextprotocol.io/specification/2026-07-28/basic/index#error-codes
  EMCPProtocolError = class(Exception)
  private
    FCode: Integer;
    FData: TJSONData;
    // Hands the data to ProtocolErrorReply, which puts it on the wire
    // (nil if none).
    function TakeData: TJSONData;
  public
    // Takes ownership of AData (nil for none). Code -32021 needs data
    // with a non-empty requiredCapabilities object.
    constructor Create(ACode: Integer; const AMessage: string;
      AData: TJSONData = nil);
    destructor Destroy; override;
    property Code: Integer read FCode;
    // Borrowed: owned by the exception; do not free or change it (a
    // -32021 whose data no longer validates is sent as -32603).
    property Data: TJSONData read FData;
  end;

// The -32021 MissingRequiredClientCapability error for a request that
// needs ACapability (for example 'sampling') which the client did not
// declare, with the spec's data.requiredCapabilities. Verified
// 2026-11-26 against
// https://modelcontextprotocol.io/specification/2026-07-28/basic/index#_meta
function MCPMissingCapabilityError(const ACapability: string): EMCPProtocolError;

// The response line for AError (the exception a handler raised while
// answering AMessage): its code, message and data, the data taken from
// it. A -32021 whose data a handler changed after construction is
// checked again and, if it no longer validates, answered -32603, with
// ALogLine saying so for the server's log ('' otherwise).
function ProtocolErrorReply(const AMessage: TJSONRPCMessage;
  AError: EMCPProtocolError; out ALogLine: string): string;

implementation

uses
  MCP.Protocol;

function IsAllowedHandlerErrorCode(ACode: Integer): Boolean;
begin
  case ACode of
    JSONRPC_PARSE_ERROR, JSONRPC_INVALID_REQUEST, JSONRPC_METHOD_NOT_FOUND,
    JSONRPC_INVALID_PARAMS, JSONRPC_INTERNAL_ERROR,
    MCP_ERROR_MISSING_CLIENT_CAPABILITY,
    MCP_ERROR_CALLBACK_ENDPOINT..MCP_ERROR_NOT_FOUND:
      Result := True;
  else
    Result := (ACode < -32768) or (ACode > -32000);
  end;
end;

constructor EMCPProtocolError.Create(ACode: Integer; const AMessage: string;
  AData: TJSONData);
begin
  // Own AData first, so every rejection below frees it: an exception in
  // a constructor runs the destructor.
  inherited Create(AMessage);
  FCode := ACode;
  FData := AData;
  if not IsAllowedHandlerErrorCode(ACode) then
    raise EMCPServer.CreateFmt('EMCPProtocolError code %d is reserved: ' +
      'use a JSON-RPC code (-32700, -32600 to -32603), -32021, -32023 to ' +
      '-32027, or an application code outside -32768..-32000', [ACode]);
  if (ACode = MCP_ERROR_MISSING_CLIENT_CAPABILITY) and
    not IsMissingCapabilityData(AData) then
    raise EMCPServer.Create('EMCPProtocolError -32021 needs data whose ' +
      'requiredCapabilities names at least one capability, each shaped ' +
      'as in ClientCapabilities; use MCPMissingCapabilityError');
end;

destructor EMCPProtocolError.Destroy;
begin
  FData.Free;
  inherited Destroy;
end;

function EMCPProtocolError.TakeData: TJSONData;
begin
  Result := FData;
  FData := nil;
end;

function MCPMissingCapabilityError(const ACapability: string): EMCPProtocolError;
begin
  Result := EMCPProtocolError.Create(MCP_ERROR_MISSING_CLIENT_CAPABILITY,
    'Missing required client capability: ' + ACapability,
    BuildMissingCapabilityData(ACapability));
end;

function ProtocolErrorReply(const AMessage: TJSONRPCMessage;
  AError: EMCPProtocolError; out ALogLine: string): string;
begin
  ALogLine := '';
  if (AError.Code = MCP_ERROR_MISSING_CLIENT_CAPABILITY) and
    not IsMissingCapabilityData(AError.Data) then
  begin
    ALogLine := 'dispatch/' + AMessage.Method + ': -32021 data no longer ' +
      'names valid requiredCapabilities; sent as -32603';
    Exit(BuildErrorResponse(AMessage.Id, JSONRPC_INTERNAL_ERROR,
      'Internal error'));
  end;
  Result := BuildErrorResponse(AMessage.Id, AError.Code, AError.Message,
    AError.TakeData);
end;

end.
