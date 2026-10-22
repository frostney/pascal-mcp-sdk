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
//     envelope claim skips header validation — SDK-anchor fact
//     (verified 2026-08-08 against @modelcontextprotocol/client
//     2.0.0): the official client derives these headers from the
//     body envelope and sends its pre-negotiation server/discover
//     probe bare, so demanding the header there would break the
//     documented up-front version-selection flow; the core still
//     rejects every other _meta-less request with -32602.
//     Mcp-Param-* headers are forwarded-and-ignored: this server
//     designates no x-mcp-header parameters, so none are recognized;
//   - HTTP status mapping: -32601 → 404 (unknown RPC method, and the
//     legacy-initialize rejection whose diagnostic names the
//     supported versions); -32700/-32600/-32020/-32021/-32022 → 400;
//     every other JSON-RPC response — results and in-band protocol
//     errors alike — is 200;
//   - a request that opted into request-scoped notifications
//     (_meta.progressToken or the logLevel key) on a handler-backed
//     method (tools/call, resources/read, prompts/get) is answered as
//     an SSE stream *once a notification actually flows*: the stream
//     headers (200, text/event-stream, Cache-Control: no-cache,
//     X-Accel-Buffering: no) are deferred until the first event, the
//     notifications follow as data: events, and the final response
//     event terminates the stream. An opted-in request that emits no
//     notification — every protocol error does, since errors are
//     decided before a handler runs — is answered as a single
//     application/json object under the status mapping above, so the
//     status a client sees never depends on the streaming opt-in. All
//     other requests get a single application/json object. (The spec
//     lets the server choose per request; this is the policy.)
//   - closing the SSE response stream is the cancellation signal:
//     when a stream write fails, the failure aborts the running
//     handler, the core converts it into a response the transport can
//     no longer deliver, and nothing further is sent for that request
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
  MCP.JSONRPC,
  MCP.Protocol,
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
    function HeaderFailure(ARequest: TFPHTTPConnectionRequest;
      const AMessage: TJSONRPCMessage; out AFailure: string): Boolean;
    procedure HandleHTTPRequest(ASender: TObject;
      var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse);
    procedure AnswerJSON(AResponse: TFPHTTPConnectionResponse;
      ACode: Integer; const ABody: string);
    procedure AnswerRequest(ARequest: TFPHTTPConnectionRequest;
      AResponse: TFPHTTPConnectionResponse; const ABody: string;
      AStream: Boolean);
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
  {$IFDEF DARWIN}
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

// Undo the =?base64?...?= sentinel encoding the transport spec
// defines for header values that are not header-safe ASCII. Returns
// False when the payload is not decodable base64.
function DecodeHeaderValue(const AValue: string; out ADecoded: string): Boolean;
const
  SENTINEL_PREFIX = '=?base64?';
  SENTINEL_SUFFIX = '?=';
var
  Payload: string;
begin
  Result := True;
  ADecoded := AValue;
  if (Copy(AValue, 1, Length(SENTINEL_PREFIX)) <> SENTINEL_PREFIX) or
     (Copy(AValue, Length(AValue) - Length(SENTINEL_SUFFIX) + 1,
       Length(SENTINEL_SUFFIX)) <> SENTINEL_SUFFIX) then
    Exit;
  Payload := Copy(AValue, Length(SENTINEL_PREFIX) + 1,
    Length(AValue) - Length(SENTINEL_PREFIX) - Length(SENTINEL_SUFFIX));
  try
    ADecoded := DecodeStringBase64(Payload);
  except
    Result := False;
  end;
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

// Whether this request opted into request-scoped notifications and
// targets a handler-backed method — the streaming policy documented
// in the unit header.
function WantsStream(const AMessage: TJSONRPCMessage): Boolean;
var
  Meta: TJSONObject;
begin
  Result := False;
  if not NeedsName(AMessage.Method) then
    Exit;
  Meta := MetaObject(AMessage.Params);
  if Meta = nil then
    Exit;
  Result := (Meta.Find('progressToken') <> nil) or
    (Meta.Find(META_KEY_LOG_LEVEL) <> nil);
end;

// The HTTP status the transport profile prescribes for a JSON-RPC
// response line (unit header lists the mapping).
function HTTPStatusForResponse(const ALine: string): Integer;
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

  // TFPHttpServer publishes Port/Threaded/OnRequest but keeps the
  // bind address protected; surface it for the localhost default.
  TMCPHTTPListener = class(TFPHTTPServer)
  private
    FOwner: TMCPHTTPServer; // borrowed: owns this listener
  protected
    function CreateConnection(AData: TSocketStream): TFPHTTPConnection;
      override;
  public
    property Address;
  end;

{$IFDEF DARWIN}
const
  // Not declared by the 3.2.2 sockets unit on Darwin.
  MCP_SO_NOSIGPIPE = $1022;
{$ENDIF}

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
  HeaderName, DecodedName, BodyName: string;
  Meta: TJSONObject;
begin
  Result := True;

  // The mirrored headers derive from the body's _meta envelope; a
  // request without the envelope claim (the official client's
  // pre-negotiation server/discover probe) carries none and is left
  // to the core, which rejects every other _meta-less request with
  // its more useful -32602 diagnostic.
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
  if NeedsName(AMessage.Method) then
  begin
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
      if DecodedName <> BodyName then
      begin
        AFailure := 'Header mismatch: Mcp-Name header value ''' +
          DecodedName + ''' does not match body value ''' + BodyName +
          '''';
        Exit;
      end;
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

// Dispatch one request body through the core and answer it — a
// single JSON object, or an SSE stream when AStream is set and the
// handler actually emits a notification.
procedure TMCPHTTPServer.AnswerRequest(ARequest: TFPHTTPConnectionRequest;
  AResponse: TFPHTTPConnectionResponse; const ABody: string;
  AStream: Boolean);
var
  Session: TMCPSession;
  Stream: TSSEStream;
  ResponseLine: string;
  Produced: Boolean;
begin
  Session := FServer.CreateSession;
  try
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
      if not Stream.HeadersSent then
        // No notification flowed, so the opt-in changed nothing about
        // how this request is answered.
        if Produced then
          AnswerJSON(AResponse, HTTPStatusForResponse(ResponseLine),
            ResponseLine)
        else
          AResponse.Code := 202;
    end
    else
    begin
      if FServer.HandleMessage(Session, ABody, nil, nil, ResponseLine) then
        AnswerJSON(AResponse, HTTPStatusForResponse(ResponseLine),
          ResponseLine)
      else
        // Notification-shaped bodies (including malformed ones the
        // core drops as fire-and-forget) are accepted with no body.
        AResponse.Code := 202;
    end;
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
      AnswerRequest(ARequest, AResponse, Body, WantsStream(Msg));
    end
    else
      // Notifications (well-formed or dropped-malformed) and invalid
      // request-shaped bodies alike go through the core; the header
      // profile defines no requirements for notification POSTs.
      AnswerRequest(ARequest, AResponse, Body, False);
  finally
    FreeJSONRPCMessage(Msg);
  end;
end;

end.
