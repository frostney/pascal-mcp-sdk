unit MCP.Transport.HTTP;

// Streamable HTTP transport binding (spec revision 2026-07-28): every
// JSON-RPC message is its own HTTP POST to a single MCP endpoint, and
// the server answers each request with either one JSON object or an
// SSE stream scoped to that request. This unit is the second thin
// shell around the sans-I/O core — every protocol decision lives in
// MCP.Server.HandleMessage; here we validate the transport profile,
// move bytes, and map JSON-RPC outcomes onto HTTP status codes.
// Substrate: fcl-web's fphttpserver, which ships inside FPC 3.2.2
// (the same interpretation of the dependency rule that admits fpjson);
// fcl-web stays confined to this unit.
//
// Binding rules implemented (all verified 2026-08-08 against
// https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http):
//   - single endpoint path accepting POST; GET and DELETE answer
//     405 Method Not Allowed (legacy Streamable HTTP traffic);
//     Mcp-Session-Id and Last-Event-ID headers are ignored — this
//     revision has no protocol sessions and no stream resumability;
//   - the Origin header, when present, must pass the allowlist or the
//     request is rejected with 403 (DNS-rebinding defense); the
//     default allowlist accepts localhost origins only, and the
//     default bind address is 127.0.0.1;
//   - a notification-shaped body is answered 202 Accepted with no
//     body (malformed notifications are dropped by the core and
//     still 202 — fire-and-forget);
//   - request bodies carrying a _meta protocol-version claim are
//     validated against the mirrored metadata headers before
//     dispatch: MCP-Protocol-Version (required, must match _meta) and
//     Mcp-Method (required, must equal method) on every enveloped
//     request; Mcp-Name (params.name / params.uri, with the
//     =?base64?...?= sentinel decoded first) on tools/call,
//     resources/read and prompts/get. Failures answer 400 with a
//     -32020 HeaderMismatch JSON-RPC error. A request without the
//     envelope claim skips header validation: it is malformed anyway,
//     and the core's -32602 (HTTP 400, #79) names what is missing,
//     where a -32020 would point at the headers instead. The official
//     client sends the full envelope and headers even on its first
//     server/discover probe (re-checked 2026-11-26 against
//     @modelcontextprotocol/client 2.0.0, buildProbeRequest).
//     Mcp-Param-* headers (#90): on tools/call, for every parameter
//     the tool designates with x-mcp-header (MCP.Server
//     ToolHeaderParameters), a non-null body value needs exactly one
//     Mcp-Param-<name> whose value, after strict =?base64?...?=
//     decoding, matches it by declared type (strings as they are,
//     integers numerically, booleans lowercase), and an absent or null
//     one needs none. A missing, repeated, mismatched, badly encoded or
//     unencoded non-ASCII header, or one sent for an absent or null
//     value, answers 400 with -32020. Headers for parameters the tool
//     does not designate are ignored.
//     Verified 2026-11-26 against .../basic/transports/streamable-http
//     #server-behavior-for-custom-headers;
//   - HTTP status mapping: -32601 → 404 (unknown RPC method, and the
//     legacy-initialize rejection whose diagnostic names the
//     supported versions); -32700/-32600/-32020/-32021/-32022 → 400;
//     -32602 → 400 when the request lacks a required per-request
//     field (MCP.Protocol.MissingRequiredMeta: _meta, its
//     protocolVersion or its clientCapabilities), which the spec makes
//     a malformed request (#79, basic/index#_meta, verified
//     2026-11-26); every other JSON-RPC response — results and in-band
//     protocol errors alike, other -32602s included — is 200;
//   - a request that opted into request-scoped notifications
//     (_meta.progressToken or the logLevel key) is answered as an SSE
//     stream *once a notification actually flows* (handlers of
//     tools/call, resources/read, prompts/get and completion/complete
//     can emit them): the stream
//     headers (200, text/event-stream, Cache-Control: no-cache,
//     X-Accel-Buffering: no) are deferred until the first event, the
//     notifications follow as data: events, and the final response
//     event terminates the stream. An opted-in request that emits no
//     notification — every error decided before a handler runs among
//     them — is answered as a single application/json object under
//     the status mapping above. Once a stream has opened, its status
//     is 200, so an error the core decides after the handler emitted
//     (e.g. -32021 for an input request the client did not declare)
//     is the stream's final event, not a mapped status (#84). All
//     other requests get a single application/json object. (The spec
//     lets the server choose per request; this is the policy.)
//   - closing the connection is the cancellation signal: the
//     session's cancellation poll (#93) reports a closed socket (an
//     orderly close, a reset or another terminal error), checked at
//     most every 50 ms, whenever the handler asks IsCancelled, so a
//     handler that never writes stops too. Receive EOF cannot tell a
//     client that closed only its sending side from one that closed
//     both, so that client has cancelled too: its request ends and it
//     gets no JSON-RPC message: an empty 202, or, when its SSE stream
//     had already opened, the end of that stream without a final
//     event. And when
//     a stream write fails, the failure aborts the running handler,
//     the core converts it into a response the transport can no
//     longer deliver, and nothing further is sent for that request
//     — subscriptions/listen streams do not arise because the core
//     advertises no subscription capability.
//
// Era posture: this binding is modern-only. The constructor turns off
// DualEra, so 2026-07-28 requests are served statelessly and a legacy
// initialize is rejected with the version diagnostic the spec
// recommends; legacy clients keep using stdio.
//
// Concurrency: connections are served on one thread each. The frozen
// server core is read-only at that point and every POST gets its own
// TMCPSession, so per-request protocol state is isolated; the
// process-global diagnostics the core keeps (the error-reference
// counter, stderr logging) are internally synchronized. Handler
// thread-safety remains the consumer's contract. On Unix the hosting
// program must list cthreads first in its uses clause (the standard
// FPC thread-driver contract) — see mcpdemo.

{$I MCP.inc}

interface

uses
  Classes,
  SysUtils,

  fphttpserver,
  fpjson,
  httpdefs,
  MCP.Extensions,
  MCP.JSONRPC,
  MCP.Protocol,
  MCP.Schema,
  MCP.Server;

const
  // Default inbound body cap in bytes (same budget as the stdio line
  // cap).
  MCP_HTTP_DEFAULT_MAX_BODY = 4 * 1024 * 1024;
  MCP_HTTP_DEFAULT_ENDPOINT = '/mcp';

type
  EMCPHTTPTransport = class(Exception);

  // Serves one TMCPServer over Streamable HTTP. Configure, then call
  // Run (blocking — serve until Stop is called from another thread):
  //
  //   Transport := TMCPHTTPServer.Create(Server);
  //   Transport.Port := 3000;
  //   Transport.Run;
  //
  // The listener is threaded, so on Unix the hosting program must
  // list cthreads first in its uses clause (the standard FPC
  // thread-driver contract) — see mcpdemo.
  TMCPHTTPServer = class(TObject)
  private
    FServer: TMCPServer; // borrowed: must outlive the transport
    FHTTP: TFPHTTPServer; // owned
    FEndpointPath: string;
    FMaxBodyBytes: Integer;
    FAllowedOrigins: TStringList; // owned: exact-match additions
    FStopPending: Boolean;
    procedure HandleAcceptIdle(ASender: TObject);
    function GetPort: Word;
    procedure SetPort(AValue: Word);
    function GetAddress: string;
    procedure SetAddress(const AValue: string);
    function OriginAllowed(const AOrigin: string): Boolean;
    function ParamHeaderFailure(ARequest: TFPHTTPConnectionRequest;
      const AMessage: TJSONRPCMessage; AHeaders: TMCPHeaderLookup;
      const ATarget: string; out AFailure: string): Boolean;
    function HeaderFailure(ARequest: TFPHTTPConnectionRequest;
      const AMessage: TJSONRPCMessage; out AFailure: string): Boolean;
    procedure HandleHTTPRequest(ASender: TObject;
      var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse);
    procedure AnswerJSON(AResponse: TFPHTTPConnectionResponse;
      ACode: Integer; const ABody: string);
    // AMalformedRequest: the request lacked a required per-request
    // field, so a -32602 answer maps to 400 (#79).
    procedure AnswerRequest(ARequest: TFPHTTPConnectionRequest;
      AResponse: TFPHTTPConnectionResponse; const ABody: string;
      AStream, AMalformedRequest: Boolean);
  public
    constructor Create(AServer: TMCPServer);
    destructor Destroy; override;

    // Serve until Stop. Freezes the server configuration up front so
    // connection threads only ever read frozen state. Returns
    // immediately when Stop already ran — a stopped transport stays
    // stopped.
    procedure Run;
    // Unblocks Run, and may be called in any order relative to it: a
    // Stop that lands before the listener is up is remembered and
    // takes effect within one accept-idle interval (250 ms).
    procedure Stop;

    // 0 lets the OS choose (useful only when something else reports
    // the bound port; tests pick a free port themselves).
    property Port: Word read GetPort write SetPort;
    // Bind address. Default 127.0.0.1 — the localhost binding the
    // spec prescribes for local servers; widen deliberately.
    property Address: string read GetAddress write SetAddress;
    property EndpointPath: string read FEndpointPath write FEndpointPath;
    property MaxBodyBytes: Integer read FMaxBodyBytes write FMaxBodyBytes;
    // Extra allowed Origin values (exact match, e.g.
    // 'https://app.example'). Localhost origins and origin-less
    // requests are always accepted.
    property AllowedOrigins: TStringList read FAllowedOrigins;
  end;

implementation

uses
  base64,
  Math,
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  {$IFDEF WINDOWS}
  winsock2,
  {$ELSE}
  sockets,
  {$ENDIF}
  ssockets;

{ ───────── helpers ───────── }

// True for http(s) origins whose host is a loopback name. The check
// is deliberately structural (scheme '://' host [':' port]) — origins
// are opaque tokens, not URLs to resolve.
function IsLocalhostOrigin(const AOrigin: string): Boolean;
var
  Rest, Host, Scheme: string;
  SchemeEnd, PortSep: Integer;
begin
  Result := False;
  SchemeEnd := Pos('://', AOrigin);
  if SchemeEnd = 0 then
    Exit;
  // Only web origins are loopback-trusted: a foreign scheme
  // ('weird://localhost') must not ride the host allowlist.
  Scheme := Copy(AOrigin, 1, SchemeEnd - 1);
  if not (SameText(Scheme, 'http') or SameText(Scheme, 'https')) then
    Exit;
  Rest := Copy(AOrigin, SchemeEnd + 3, MaxInt);
  // A serialized origin is scheme://host[:port] and nothing more.
  // Userinfo and a path would let a foreign host hide behind a
  // loopback-looking prefix ('http://localhost:99@evil.example'), so
  // both are refused before the host is read out.
  if (Pos('@', Rest) > 0) or (Pos('/', Rest) > 0) then
    Exit;
  if Copy(Rest, 1, 5) = '[::1]' then
    // The bracketed literal must be the whole host: a prefix match
    // would also accept 'http://[::1].attacker.example'.
    Exit((Length(Rest) = 5) or (Rest[6] = ':'));
  PortSep := Pos(':', Rest);
  if PortSep = 0 then
    Host := Rest
  else
    Host := Copy(Rest, 1, PortSep - 1);
  Result := SameText(Host, 'localhost') or (Host = '127.0.0.1');
end;

// Base64 as the sentinel encoding needs it: the standard alphabet,
// whole 4-character groups and padding only at the end. fcl-base's
// decoder skips what it does not understand, so it is checked first:
// the SEP-2243 test table rejects bad padding and foreign characters.
function StrictBase64(const APayload: string; out ADecoded: string): Boolean;
var
  I, Padding: Integer;
begin
  // The empty payload is the empty string's encoding (#90 review).
  Result := APayload = '';
  ADecoded := '';
  if Result or (Length(APayload) mod 4 <> 0) then
    Exit;
  Padding := 0;
  for I := 1 to Length(APayload) do
    case APayload[I] of
      'A'..'Z', 'a'..'z', '0'..'9', '+', '/':
        if Padding > 0 then
          Exit;
      '=':
        Inc(Padding);
    else
      Exit;
    end;
  if Padding > 2 then
    Exit;
  ADecoded := DecodeStringBase64(APayload);
  Result := True;
end;

// A plain (unencoded) header value: visible ASCII, space and tab only
// (RFC 9110 field values, as the transport spec requires of them).
function IsPlainHeaderValue(const AValue: string): Boolean;
var
  I: Integer;
begin
  Result := True;
  for I := 1 to Length(AValue) do
    if not (AValue[I] in [#9, #32..#126]) then
      Exit(False);
end;

// The argument at APath under AArguments, or nil (absent or null).
// Both are borrowed: the result is a node inside AArguments.
function ArgumentAt(AArguments: TJSONData;
  const APath: array of string): TJSONData;
var
  I: Integer;
begin
  Result := AArguments;
  for I := 0 to High(APath) do
  begin
    if (Result = nil) or (Result.JSONType <> jtObject) then
      Exit(nil);
    Result := TJSONObject(Result).Find(APath[I]);
  end;
  if (Result <> nil) and (Result.JSONType = jtNull) then
    Result := nil;
end;

const
  // 2^53 - 1: the JavaScript safe-integer bound the spec puts on
  // integer header values.
  MAX_SAFE_HEADER_INTEGER = 9007199254740991;

// AText as a decimal integer within the safe range: an optional minus
// sign and digits, and an all-zero fraction ("42.0"), since the spec
// compares integers numerically.
function SafeHeaderInteger(const AText: string; out AValue: Int64): Boolean;
var
  I, Start, Stop, Dot: Integer;
begin
  Result := False;
  AValue := 0;
  Start := 1;
  if (AText <> '') and (AText[1] = '-') then
    Start := 2;
  Stop := Length(AText);
  Dot := Pos('.', AText);
  if Dot > 0 then
  begin
    if Dot = Length(AText) then
      Exit;
    for I := Dot + 1 to Length(AText) do
      if AText[I] <> '0' then
        Exit;
    Stop := Dot - 1;
  end;
  if (Start > Stop) or (Stop - Start + 1 > 16) then
    Exit;
  for I := Start to Stop do
  begin
    if not (AText[I] in ['0'..'9']) then
      Exit;
    AValue := AValue * 10 + (Ord(AText[I]) - Ord('0'));
  end;
  if Start = 2 then
    AValue := -AValue;
  Result := Abs(AValue) <= MAX_SAFE_HEADER_INTEGER;
end;

// The body argument AValue as the safe integer it holds: an integer
// node, or a float with no fractional part (42.0), within the range.
function SafeBodyInteger(AValue: TJSONData; out AInteger: Int64): Boolean;
var
  F: Double;
begin
  Result := False;
  AInteger := 0;
  if AValue.JSONType <> jtNumber then
    Exit;
  if TJSONNumber(AValue).NumberType in [ntInteger, ntInt64] then
  begin
    AInteger := AValue.AsInt64;
    Exit(Abs(AInteger) <= MAX_SAFE_HEADER_INTEGER);
  end;
  if TJSONNumber(AValue).NumberType <> ntFloat then
    Exit; // a QWord is past the safe range
  F := AValue.AsFloat;
  // Range first, so Trunc never sees a value it could overflow on.
  if IsNan(F) or (Abs(F) > MAX_SAFE_HEADER_INTEGER) or (Frac(F) <> 0) then
    Exit;
  AInteger := Trunc(F);
  Result := True;
end;

// Whether the decoded header text matches the body argument for a
// parameter declared as AType (Value Encoding: strings as they are,
// integers in decimal compared numerically, booleans lowercase). A
// value of another type, or a composite, has no header form and never
// matches (#90 review).
function HeaderMatches(const AText, AType: string; AValue: TJSONData): Boolean;
var
  HeaderInt, BodyInt: Int64;
begin
  if AType = 'integer' then
    Result := SafeHeaderInteger(AText, HeaderInt) and
      SafeBodyInteger(AValue, BodyInt) and (HeaderInt = BodyInt)
  else if AType = 'boolean' then
    Result := (AValue.JSONType = jtBoolean) and
      (AText = BoolToStr(AValue.AsBoolean, 'true', 'false'))
  else
    Result := (AValue.JSONType = jtString) and (AText = AValue.AsString);
end;

// True when AValue is =?base64?<APayload>?= (markers case-sensitive);
// only splits, never decodes.
function SentinelPayload(const AValue: string; out APayload: string): Boolean;
const
  SENTINEL_PREFIX = '=?base64?';
  SENTINEL_SUFFIX = '?=';
begin
  Result := (Length(AValue) >= Length(SENTINEL_PREFIX) +
    Length(SENTINEL_SUFFIX)) and
    (Copy(AValue, 1, Length(SENTINEL_PREFIX)) = SENTINEL_PREFIX) and
    (Copy(AValue, Length(AValue) - Length(SENTINEL_SUFFIX) + 1,
    Length(SENTINEL_SUFFIX)) = SENTINEL_SUFFIX);
  if Result then
    APayload := Copy(AValue, Length(SENTINEL_PREFIX) + 1,
      Length(AValue) - Length(SENTINEL_PREFIX) - Length(SENTINEL_SUFFIX))
  else
    APayload := '';
end;

// Undo the =?base64?...?= sentinel encoding the transport spec defines
// for header values that are not header-safe ASCII. False when the
// payload is not strict base64. Mcp-Name and Mcp-Param values decode
// alike since #90, so an unpadded Mcp-Name payload, which fcl-base
// accepted before, is refused (Value Encoding names standard base64).
function DecodeHeaderValue(const AValue: string; out ADecoded: string): Boolean;
var
  Payload: string;
begin
  Result := True;
  ADecoded := AValue;
  if SentinelPayload(AValue, Payload) then
    Result := StrictBase64(Payload, ADecoded);
end;

// params._meta as an object, or nil.
function MetaObject(AParams: TJSONObject): TJSONObject;
var
  MetaData: TJSONData;
begin
  Result := nil;
  if AParams = nil then
    Exit;
  MetaData := AParams.Find('_meta');
  if (MetaData <> nil) and (MetaData.JSONType = jtObject) then
    Result := TJSONObject(MetaData);
end;

// The body value Mcp-Name mirrors for AMethod, '' when the method
// carries none (or the body is missing it).
function BodyNameFor(const AMethod: string; AParams: TJSONObject): string;
begin
  Result := '';
  if AParams = nil then
    Exit;
  if (AMethod = 'tools/call') or (AMethod = 'prompts/get') then
    Result := AParams.Get('name', '')
  else if AMethod = 'resources/read' then
    Result := AParams.Get('uri', '');
end;

function NeedsName(const AMethod: string): Boolean;
begin
  Result := (AMethod = 'tools/call') or (AMethod = 'prompts/get') or
    (AMethod = 'resources/read');
end;

// Whether this request opted into request-scoped notifications — the
// streaming policy documented in the unit header. Which methods emit
// them is the core's business: a stream opens only once one flows, so
// an opted-in request whose method notifies nothing gets JSON (#81).
function WantsStream(const AMessage: TJSONRPCMessage): Boolean;
var
  Meta: TJSONObject;
begin
  Result := False;
  Meta := MetaObject(AMessage.Params);
  if Meta = nil then
    Exit;
  Result := (Meta.Find('progressToken') <> nil) or
    (Meta.Find(META_KEY_LOG_LEVEL) <> nil);
end;

// The HTTP status the transport profile prescribes for a JSON-RPC
// response line (unit header lists the mapping). AMalformedRequest:
// the request lacked a required per-request field, so its -32602 is
// the malformed-request rejection rather than an in-band error.
function HTTPStatusForResponse(const ALine: string;
  AMalformedRequest: Boolean): Integer;
var
  Root: TJSONData;
  ErrorData: TJSONData;
  Code: Integer;
begin
  Result := 200;
  try
    Root := GetJSON(ALine);
  except
    Exit;
  end;
  try
    if Root.JSONType <> jtObject then
      Exit;
    ErrorData := TJSONObject(Root).Find('error');
    if (ErrorData = nil) or (ErrorData.JSONType <> jtObject) then
      Exit;
    Code := TJSONObject(ErrorData).Get('code', 0);
    case Code of
      JSONRPC_METHOD_NOT_FOUND:
        Result := 404;
      JSONRPC_PARSE_ERROR, JSONRPC_INVALID_REQUEST,
      MCP_ERROR_HEADER_MISMATCH, MCP_ERROR_MISSING_CLIENT_CAPABILITY,
      MCP_ERROR_UNSUPPORTED_PROTOCOL_VERSION:
        Result := 400;
      JSONRPC_INVALID_PARAMS:
        if AMalformedRequest then
          Result := 400;
    end;
  finally
    Root.Free;
  end;
end;

type
  PSSEStream = ^TSSEStream;
  TSSEStream = record
    Response: TFPHTTPConnectionResponse; // borrowed
    Socket: TStream; // borrowed: the connection socket
    HeadersSent: Boolean; // the stream is committed once this is set
  end;

// Notification sink for streaming responses: one SSE data event per
// line, written immediately. The stream headers ride on the first
// event — until one arrives the request is still answerable as a
// single JSON object under the normal status mapping. A failed write
// raises through the running handler — that abort is the
// disconnect-as-cancellation contract.
procedure SSESink(const ALine: string; AUserData: Pointer);
var
  Frame: string;
  Stream: PSSEStream;
begin
  Stream := PSSEStream(AUserData);
  if not Stream^.HeadersSent then
  begin
    // Committed before the write: a header write that fails has still
    // spent the response, so the caller must not fall back to JSON.
    Stream^.HeadersSent := True;
    Stream^.Response.Code := 200;
    Stream^.Response.ContentType := 'text/event-stream';
    Stream^.Response.CacheControl := 'no-cache';
    Stream^.Response.SetCustomHeader('X-Accel-Buffering', 'no');
    Stream^.Response.SendHeaders;
  end;
  Frame := 'data: ' + ALine + #10#10;
  Stream^.Socket.WriteBuffer(Frame[1], Length(Frame));
end;

{ ───────── TMCPHTTPServer ───────── }

type
  // fphttpserver 3.2.2 buffers the whole declared Content-Length into
  // a string before OnRequest ever fires, so a cap checked in the
  // handler bounds nothing. This connection refuses the read itself:
  // an over-cap Content-Length means the body is never drained, the
  // request reaches the handler with empty content, and the refusal
  // travels on the connection for the handler to answer 413.
  TMCPHTTPConnection = class(TFPHTTPConnection)
  private
    FMaxBodyBytes: Integer;
    FBodyRefused: Boolean;
  protected
    procedure ReadRequestContent(ARequest: TFPHTTPConnectionRequest);
      override;
  public
    property MaxBodyBytes: Integer read FMaxBodyBytes write FMaxBodyBytes;
    property BodyRefused: Boolean read FBodyRefused;
  end;

  // A request that remembers every custom header field it received:
  // fcl-web keeps only the last value of a repeated field, so a check of
  // a mirrored header could not otherwise see a conflicting earlier one
  // (#90 review).
  TMCPHTTPRequest = class(TFPHTTPConnectionRequest)
  private
    // One entry per Mcp-Param-* field name, ASCII-lowercased: its last
    // value and how many times it arrived. Other fields are not kept.
    FParamNames: array of string;
    FParamValues: array of string;
    FParamCounts: array of Integer;
    function ParamIndex(const AKey: string): Integer;
  public
    procedure SetCustomHeader(const AName, AValue: string); override;
    // How many times the Mcp-Param-* field AName (any ASCII case)
    // arrived, and its last value. fcl-web's own lookup compares names
    // by the locale's rules, so the binding reads these instead.
    function ParamFieldCount(const AName: string): Integer;
    function ParamFieldValue(const AName: string): string;
  end;

  // TFPHttpServer publishes Port/Threaded/OnRequest but keeps the
  // bind address protected; surface it for the localhost default.
  TMCPHTTPListener = class(TFPHTTPServer)
  private
    FOwner: TMCPHTTPServer; // borrowed: owns this listener
  protected
    function CreateConnection(AData: TSocketStream): TFPHTTPConnection;
      override;
    function CreateRequest: TFPHTTPConnectionRequest; override;
  public
    property Address;
  end;

{$IFDEF DARWIN}
const
  // Not declared by the 3.2.2 sockets unit on Darwin.
  MCP_SO_NOSIGPIPE = $1022;
{$ENDIF}

const
  PARAM_FIELD_PREFIX = 'mcp-param-';

function TMCPHTTPRequest.ParamIndex(const AKey: string): Integer;
begin
  for Result := 0 to High(FParamNames) do
    if FParamNames[Result] = AKey then
      Exit;
  Result := -1;
end;

procedure TMCPHTTPRequest.SetCustomHeader(const AName, AValue: string);
var
  Key: string;
  Index: Integer;
begin
  // LowerCase folds ASCII only, whatever the locale.
  Key := LowerCase(AName);
  if Copy(Key, 1, Length(PARAM_FIELD_PREFIX)) = PARAM_FIELD_PREFIX then
  begin
    Index := ParamIndex(Key);
    if Index < 0 then
    begin
      Index := Length(FParamNames);
      SetLength(FParamNames, Index + 1);
      SetLength(FParamValues, Index + 1);
      SetLength(FParamCounts, Index + 1);
      FParamNames[Index] := Key;
      FParamCounts[Index] := 0;
    end;
    FParamValues[Index] := AValue;
    Inc(FParamCounts[Index]);
  end;
  inherited SetCustomHeader(AName, AValue);
end;

function TMCPHTTPRequest.ParamFieldCount(const AName: string): Integer;
var
  Index: Integer;
begin
  Index := ParamIndex(LowerCase(AName));
  if Index < 0 then
    Result := 0
  else
    Result := FParamCounts[Index];
end;

function TMCPHTTPRequest.ParamFieldValue(const AName: string): string;
var
  Index: Integer;
begin
  Index := ParamIndex(LowerCase(AName));
  if Index < 0 then
    Result := ''
  else
    Result := FParamValues[Index];
end;

function TMCPHTTPListener.CreateRequest: TFPHTTPConnectionRequest;
begin
  Result := TMCPHTTPRequest.Create;
end;

procedure TMCPHTTPConnection.ReadRequestContent(
  ARequest: TFPHTTPConnectionRequest);
begin
  if (FMaxBodyBytes > 0) and (ARequest.ContentLength > FMaxBodyBytes) then
  begin
    // Declared length alone decides: nothing is allocated and nothing
    // is read. The unread body stays in the socket, which is why the
    // 413 answer closes the connection.
    FBodyRefused := True;
    Exit;
  end;
  inherited ReadRequestContent(ARequest);
end;

function TMCPHTTPListener.CreateConnection(
  AData: TSocketStream): TFPHTTPConnection;
{$IFDEF DARWIN}
var
  OptionValue: Integer;
{$ENDIF}
begin
  // A client that abandons its SSE stream must surface as a write
  // error the transport can treat as cancellation — not as a
  // process-killing SIGPIPE. fphttpserver already sets MSG_NOSIGNAL
  // on Linux/FreeBSD; Darwin needs the per-socket option.
  {$IFDEF DARWIN}
  OptionValue := 1;
  fpsetsockopt(AData.Handle, SOL_SOCKET, MCP_SO_NOSIGPIPE,
    @OptionValue, SizeOf(OptionValue));
  {$ENDIF}
  Result := TMCPHTTPConnection.Create(Self, AData);
  // MaxBodyBytes is settable up to the moment a connection arrives;
  // snapshot it here so the connection thread reads a stable value.
  TMCPHTTPConnection(Result).MaxBodyBytes := FOwner.FMaxBodyBytes;
end;

constructor TMCPHTTPServer.Create(AServer: TMCPServer);
begin
  inherited Create;
  if AServer = nil then
    raise EMCPHTTPTransport.Create('Server must not be nil');
  FServer := AServer;
  // Modern-only posture; raises via the core's freeze guard when the
  // server is already frozen into dual-era mode.
  if FServer.DualEra then
    FServer.DualEra := False;
  FEndpointPath := MCP_HTTP_DEFAULT_ENDPOINT;
  FMaxBodyBytes := MCP_HTTP_DEFAULT_MAX_BODY;
  FAllowedOrigins := TStringList.Create;
  FHTTP := TMCPHTTPListener.Create(nil);
  TMCPHTTPListener(FHTTP).FOwner := Self;
  TMCPHTTPListener(FHTTP).Address := '127.0.0.1';
  FHTTP.Threaded := True;
  // The accept loop wakes at this interval to notice Stop; without
  // it, deactivation waits for the next inbound connection.
  FHTTP.AcceptIdleTimeout := 250;
  FHTTP.OnAcceptIdle := HandleAcceptIdle;
  FHTTP.OnRequest := HandleHTTPRequest;
end;

destructor TMCPHTTPServer.Destroy;
begin
  FHTTP.Free;
  FAllowedOrigins.Free;
  inherited Destroy;
end;

function TMCPHTTPServer.GetPort: Word;
begin
  Result := FHTTP.Port;
end;

procedure TMCPHTTPServer.SetPort(AValue: Word);
begin
  FHTTP.Port := AValue;
end;

function TMCPHTTPServer.GetAddress: string;
begin
  Result := TMCPHTTPListener(FHTTP).Address;
end;

procedure TMCPHTTPServer.SetAddress(const AValue: string);
begin
  TMCPHTTPListener(FHTTP).Address := AValue;
end;

// The accept loop's idle tick, the one place that runs on the Run
// thread while the listener is up. fphttpserver's deactivation is
// edge-triggered — SetActive(False) no-ops while the listener socket
// does not exist yet, and StartAccepting then sets its own accepting
// flag — so a Stop that raced ahead of activation would otherwise be
// lost and Run would block forever. Here it is picked up instead.
procedure TMCPHTTPServer.HandleAcceptIdle(ASender: TObject);
begin
  if FStopPending and FHTTP.Active then
    FHTTP.Active := False;
end;

procedure TMCPHTTPServer.Run;
var
  Session: TMCPSession;
begin
  // A stopped transport stays stopped: Run after Stop returns at once
  // rather than opening a listener nothing will ever close.
  if FStopPending then
    Exit;
  // Freeze deterministically before the listener starts so connection
  // threads never observe a configuration transition.
  Session := FServer.CreateSession;
  Session.Free;
  FHTTP.Active := True; // blocks until Stop
end;

procedure TMCPHTTPServer.Stop;
begin
  // Record first, deactivate second: the flag is what makes an early
  // Stop survive until the accept loop can act on it.
  FStopPending := True;
  FHTTP.Active := False; // best effort; a no-op before activation
end;

function TMCPHTTPServer.OriginAllowed(const AOrigin: string): Boolean;
begin
  Result := IsLocalhostOrigin(AOrigin) or
    (FAllowedOrigins.IndexOf(AOrigin) >= 0);
end;

function TMCPHTTPServer.HeaderFailure(ARequest: TFPHTTPConnectionRequest;
  const AMessage: TJSONRPCMessage; out AFailure: string): Boolean;
var
  HeaderVersion, BodyVersion, HeaderMethod: string;
  HeaderName, DecodedName, BodyName, NameParam: string;
  Routed: Boolean;
  Headers: TMCPHeaderLookup;
  Meta: TJSONObject;
begin
  Result := True;

  // The mirrored headers derive from the body's _meta envelope; a
  // request without the envelope claim is malformed and left to the
  // core, whose -32602 names the missing field (400 on HTTP, #79).
  BodyVersion := '';
  Meta := MetaObject(AMessage.Params);
  if Meta <> nil then
    BodyVersion := Meta.Get(META_KEY_PROTOCOL_VERSION, '');
  if BodyVersion = '' then
    Exit(False);

  // MCP-Protocol-Version: required on every enveloped POST; must
  // match the body's _meta value.
  HeaderVersion := ARequest.GetFieldByName('MCP-Protocol-Version');
  if HeaderVersion = '' then
  begin
    AFailure := 'Header mismatch: required MCP-Protocol-Version ' +
      'header is missing';
    Exit;
  end;
  if HeaderVersion <> BodyVersion then
  begin
    AFailure := 'Header mismatch: MCP-Protocol-Version header value ''' +
      HeaderVersion + ''' does not match body value ''' + BodyVersion +
      '''';
    Exit;
  end;

  // Mcp-Method: required on all requests; values are case-sensitive.
  HeaderMethod := ARequest.GetFieldByName('Mcp-Method');
  if HeaderMethod = '' then
  begin
    AFailure := 'Header mismatch: required Mcp-Method header is missing';
    Exit;
  end;
  if HeaderMethod <> AMessage.Method then
  begin
    AFailure := 'Header mismatch: Mcp-Method header value ''' +
      HeaderMethod + ''' does not match body method ''' +
      AMessage.Method + '''';
    Exit;
  end;

  // Mcp-Name: required for tools/call, prompts/get (params.name) and
  // resources/read (params.uri); sentinel-encoded values are decoded
  // before comparison. When the body itself omits the mirrored value
  // the request is malformed anyway — the core's diagnostic wins.
  // An extension's routed method (#118) mirrors its own name parameter.
  Routed := FServer.MethodRoute(AMessage.Method, NameParam, Headers);
  if NeedsName(AMessage.Method) or Routed then
  begin
    if Routed then
    begin
      BodyName := '';
      if AMessage.Params <> nil then
        BodyName := AMessage.Params.Get(NameParam, '');
    end
    else
      BodyName := BodyNameFor(AMessage.Method, AMessage.Params);
    HeaderName := ARequest.GetFieldByName('Mcp-Name');
    if HeaderName = '' then
    begin
      if BodyName <> '' then
      begin
        AFailure := 'Header mismatch: required Mcp-Name header is missing';
        Exit;
      end;
    end
    else
    begin
      if not DecodeHeaderValue(HeaderName, DecodedName) then
      begin
        AFailure := 'Header mismatch: Mcp-Name header value is not ' +
          'decodable base64';
        Exit;
      end;
      // A name that is not plain ASCII must come base64-encoded
      // (events.mdx, Streamable HTTP: Routing Headers; the transport's
      // Value Encoding), so raw bytes are refused (#118 review).
      if (DecodedName = HeaderName) and not IsPlainHeaderValue(HeaderName) then
      begin
        AFailure := 'Header mismatch: Mcp-Name header value is not plain ' +
          'ASCII; send it base64-encoded';
        Exit;
      end;
      if DecodedName <> BodyName then
      begin
        AFailure := 'Header mismatch: Mcp-Name header value ''' +
          DecodedName + ''' does not match body value ''' + BodyName +
          '''';
        Exit;
      end;
    end;
  end;

  if ((AMessage.Method = 'tools/call') or (Routed and Assigned(Headers))) and
    ParamHeaderFailure(ARequest, AMessage, Headers, BodyName, AFailure) then
    Exit;

  Result := False;
end;

// Mcp-Param-* validation for tools/call (#90): every parameter the
// tool designates with x-mcp-header must arrive as a header that,
// decoded, equals the body value; a header for an absent or null value
// does not match either. Verified 2026-11-26 against
// https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http#server-behavior-for-custom-headers
// How many times the Mcp-Param field AName arrived on ARequest, and
// its value: from a TMCPHTTPRequest (the listener makes every request
// one), else from fcl-web's own storage, which keeps one value and
// compares names by the locale.
function ParamField(ARequest: TFPHTTPConnectionRequest; const AName: string;
  out AValue: string): Integer;
begin
  if ARequest is TMCPHTTPRequest then
  begin
    AValue := TMCPHTTPRequest(ARequest).ParamFieldValue(AName);
    Exit(TMCPHTTPRequest(ARequest).ParamFieldCount(AName));
  end;
  AValue := ARequest.GetFieldByName(AName);
  if ARequest.CustomHeaders.IndexOfName(AName) >= 0 then
    Result := 1
  else
    Result := 0;
end;

function TMCPHTTPServer.ParamHeaderFailure(
  ARequest: TFPHTTPConnectionRequest; const AMessage: TJSONRPCMessage;
  AHeaders: TMCPHeaderLookup; const ATarget: string;
  out AFailure: string): Boolean;
var
  Parameters: TMCPHeaderParameters;
  Arguments, Value: TJSONData;
  HeaderName, Raw, Payload, Decoded: string;
  I, Occurrences: Integer;
begin
  Result := True;
  // A routed method's own parameters for the target its route names
  // (#118 review), or the tool's.
  if Assigned(AHeaders) then
    Parameters := AHeaders(ATarget)
  else
    Parameters := FServer.ToolHeaderParameters(AMessage.Params.Get('name', ''));
  Arguments := AMessage.Params.Find('arguments');
  for I := 0 to High(Parameters) do
  begin
    HeaderName := 'Mcp-Param-' + Parameters[I].Header;
    Value := ArgumentAt(Arguments, Parameters[I].Path);
    // Presence, not value: an empty field is present (the empty string's
    // header), and a repeated one is refused, since an intermediary may
    // have routed on another occurrence (#90 review).
    Occurrences := ParamField(ARequest, HeaderName, Raw);
    if Occurrences > 1 then
    begin
      AFailure := 'Header mismatch: ' + HeaderName + ' header sent more ' +
        'than once';
      Exit;
    end;
    if Occurrences = 0 then
    begin
      if Value = nil then
        Continue;
      AFailure := 'Header mismatch: required ' + HeaderName +
        ' header is missing';
      Exit;
    end;
    if Value = nil then
    begin
      AFailure := 'Header mismatch: ' + HeaderName + ' header sent for ' +
        'an argument the body does not carry';
      Exit;
    end;
    // fcl-web has already trimmed the value's edges; what is left is
    // checked as the client sent it.
    if SentinelPayload(Raw, Payload) then
    begin
      if not StrictBase64(Payload, Decoded) then
      begin
        AFailure := 'Header mismatch: ' + HeaderName + ' header value ' +
          'is not valid base64';
        Exit;
      end;
    end
    else if IsPlainHeaderValue(Raw) then
      Decoded := Raw
    else
    begin
      AFailure := 'Header mismatch: ' + HeaderName + ' header value ' +
        'has characters a header cannot carry unencoded';
      Exit;
    end;
    if not HeaderMatches(Decoded, Parameters[I].ParamType, Value) then
    begin
      AFailure := 'Header mismatch: ' + HeaderName + ' header value does ' +
        'not match the body argument';
      Exit;
    end;
  end;
  Result := False;
end;

procedure TMCPHTTPServer.AnswerJSON(AResponse: TFPHTTPConnectionResponse;
  ACode: Integer; const ABody: string);
begin
  AResponse.Code := ACode;
  AResponse.ContentType := 'application/json';
  AResponse.Content := ABody;
end;

type
  // The poll state of one POST (#93): its socket and when it was last
  // checked.
  THTTPDisconnectPoll = record
    Socket: THandle;
    LastCheck: QWord;
    Closed: Boolean;
  end;
  PHTTPDisconnectPoll = ^THTTPDisconnectPoll;

const
  // How often a polling handler costs a system call.
  DISCONNECT_POLL_INTERVAL_MS = 50;

const
  // Bytes one disconnect check discards at most; a client sending more
  // than this after its request is seen closed on a later check.
  DISCONNECT_DRAIN_LIMIT = 16 * 1024;

// The client closed the connection: the socket reports a hang-up or an
// error, or reading it finds the end of the stream (an orderly close)
// or a terminal error such as a reset. The request body was read in
// full before dispatch, and the binding serves one request per
// connection, so bytes still arriving are not a request: they are read
// and discarded, up to DISCONNECT_DRAIN_LIMIT per check, so an orderly
// close behind them is still seen (#93 review); a peek would keep
// finding the first of them. Errors that only say to try again leave
// the request running. Receive EOF cannot tell a client that closed
// only its sending side from one that closed both, so either counts as
// having cancelled: the request ends and nothing more about it is sent.
function SocketClosedByPeer(ASocket: THandle): Boolean;
var
  {$IFDEF WINDOWS}
  ReadSet: winsock2.TFDSet;
  Timeout: winsock2.TTimeVal;
  Failure: Integer;
  {$ELSE}
  Fd: pollfd;
  Failure: cint;
  {$ENDIF}
  Buffer: array[0..4095] of Byte;
  Got, Drained: Integer;
begin
  Result := False;
  Drained := 0;
  while Drained < DISCONNECT_DRAIN_LIMIT do
  begin
    {$IFDEF WINDOWS}
    // A Windows fd_set lists sockets, so any socket value fits it.
    winsock2.FD_ZERO(ReadSet);
    winsock2.FD_SET(ASocket, ReadSet);
    Timeout.tv_sec := 0;
    Timeout.tv_usec := 0;
    if winsock2.select(0, @ReadSet, nil, nil, @Timeout) <= 0 then
      Exit;
    Got := winsock2.recv(ASocket, Buffer, SizeOf(Buffer), 0);
    if Got < 0 then
    begin
      Failure := winsock2.WSAGetLastError;
      Exit((Failure <> WSAEWOULDBLOCK) and (Failure <> WSAEINTR) and
        (Failure <> WSAEINPROGRESS));
    end;
    {$ELSE}
    // poll, not select: a descriptor above 1023 fits no TFDSet.
    Fd.fd := ASocket;
    Fd.events := POLLIN;
    Fd.revents := 0;
    if fpPoll(@Fd, 1, 0) <= 0 then
      Exit;
    if Fd.revents and (POLLERR or POLLHUP or POLLNVAL) <> 0 then
      Exit(True);
    Got := fpRecv(ASocket, @Buffer, SizeOf(Buffer), 0);
    if Got < 0 then
    begin
      Failure := fpgeterrno;
      Exit((Failure <> ESysEAGAIN) and (Failure <> ESysEINTR));
    end;
    {$ENDIF}
    if Got = 0 then
      Exit(True);
    Inc(Drained, Got);
  end;
end;

// The session's cancellation poll on HTTP (#93): closing the
// connection is how a client cancels, so a handler that never writes
// still learns about it. Checked at most every 50 ms.
function HTTPDisconnectPoll(ASession: TMCPSession;
  AUserData: Pointer): Boolean;
begin
  with PHTTPDisconnectPoll(AUserData)^ do
  begin
    if not Closed and (GetTickCount64 - LastCheck >= DISCONNECT_POLL_INTERVAL_MS) then
    begin
      LastCheck := GetTickCount64;
      Closed := SocketClosedByPeer(Socket);
    end;
    Result := Closed;
  end;
end;

// Dispatch one request body through the core and answer it — a
// single JSON object, or an SSE stream when AStream is set and the
// handler actually emits a notification.
procedure TMCPHTTPServer.AnswerRequest(ARequest: TFPHTTPConnectionRequest;
  AResponse: TFPHTTPConnectionResponse; const ABody: string;
  AStream, AMalformedRequest: Boolean);
var
  Session: TMCPSession;
  Stream: TSSEStream;
  ResponseLine: string;
  Produced: Boolean;
  Poll: THTTPDisconnectPoll;
begin
  Session := FServer.CreateSession;
  try
    Poll.Socket := ARequest.Connection.Socket.Handle;
    Poll.LastCheck := 0;
    Poll.Closed := False;
    Session.SetCancellationPoll(HTTPDisconnectPoll, @Poll);
    if AStream then
    begin
      // Nothing is committed up front: the sink opens the stream on
      // its first event, so a request that fails at protocol level —
      // which no notification ever precedes — still gets the status
      // the mapping prescribes instead of a 200 SSE stream.
      Stream.Response := AResponse;
      Stream.Socket := ARequest.Connection.Socket;
      Stream.HeadersSent := False;
      Produced := False;
      try
        Produced := FServer.HandleMessage(Session, ABody, @SSESink,
          @Stream, ResponseLine);
        if Stream.HeadersSent and Produced then
          SSESink(ResponseLine, @Stream);
      except
        // A dead client stream: the spec forbids sending anything
        // further for the cancelled request, so the failed write is
        // the end of it.
        on EStreamError do;
      end;
      // Once the stream is open, the response went out as its last
      // event. Otherwise no notification flowed, so the opt-in changed
      // nothing about how this request is answered.
      if Stream.HeadersSent then
        Exit;
    end
    else
      Produced := FServer.HandleMessage(Session, ABody, nil, nil,
        ResponseLine);
    // One place answers every non-streamed request (#79 review).
    if Produced then
      AnswerJSON(AResponse, HTTPStatusForResponse(ResponseLine,
        AMalformedRequest), ResponseLine)
    else
      // Notification-shaped bodies (including malformed ones the core
      // drops as fire-and-forget) are accepted with no body.
      AResponse.Code := 202;
  finally
    Session.Free;
  end;
end;

procedure TMCPHTTPServer.HandleHTTPRequest(ASender: TObject;
  var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  Msg: TJSONRPCMessage;
  Origin, Failure, Body: string;
begin
  // fphttpserver 3.2.2 serves one request per connection; announce
  // the close so clients do not attempt reuse.
  AResponse.SetCustomHeader('Connection', 'close');

  if ARequest.PathInfo <> FEndpointPath then
  begin
    AResponse.Code := 404;
    Exit;
  end;

  // Only POST exists on the MCP endpoint in this revision; legacy
  // GET (SSE stream) and DELETE (session teardown) get 405.
  if ARequest.Method <> 'POST' then
  begin
    AResponse.Code := 405;
    AResponse.Allow := 'POST';
    Exit;
  end;

  // DNS-rebinding defense: an Origin outside the allowlist is
  // rejected before the body is looked at. The id-less JSON-RPC
  // error body is the shape the spec permits here.
  Origin := ARequest.GetFieldByName('Origin');
  if (Origin <> '') and not OriginAllowed(Origin) then
  begin
    AnswerJSON(AResponse, 403, BuildErrorResponse(nil,
      JSONRPC_INVALID_REQUEST, 'Origin not allowed'));
    Exit;
  end;

  // Over-cap bodies are already refused at the socket by
  // TMCPHTTPConnection, which is the only place the cap can bound
  // memory; the Length check behind it is the second line of defense
  // for a body that arrives without a usable Content-Length.
  // Connection: close (set above) matters here: the refused body was
  // never drained out of the socket.
  Body := ARequest.Content;
  if ((ARequest.Connection is TMCPHTTPConnection) and
      TMCPHTTPConnection(ARequest.Connection).BodyRefused) or
     (Length(Body) > FMaxBodyBytes) then
  begin
    // The refusal text stays a protocol decision.
    AnswerJSON(AResponse, 413,
      FServer.OversizedLineResponse(FMaxBodyBytes));
    Exit;
  end;

  Msg := ParseJSONRPCMessage(Body);
  try
    if Msg.Kind = jrkRequest then
    begin
      if HeaderFailure(ARequest, Msg, Failure) then
      begin
        AnswerJSON(AResponse, 400, BuildErrorResponse(Msg.Id,
          MCP_ERROR_HEADER_MISMATCH, Failure));
        Exit;
      end;
      AnswerRequest(ARequest, AResponse, Body, WantsStream(Msg),
        MissingRequiredMeta(Msg.Params) <> '');
    end
    else
      // Notifications (well-formed or dropped-malformed) and invalid
      // request-shaped bodies alike go through the core; the header
      // profile defines no requirements for notification POSTs.
      AnswerRequest(ARequest, AResponse, Body, False, False);
  finally
    FreeJSONRPCMessage(Msg);
  end;
end;

end.
