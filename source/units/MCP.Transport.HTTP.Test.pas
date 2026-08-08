{ MCP.Transport.HTTP.Test — the Streamable HTTP shell, driven with a
  real fphttpclient against a live listener on an ephemeral localhost
  port: JSON responses with the profile's status mapping (200 / 400 /
  403 / 404 / 405 / 413), 202-with-no-body for notifications, the
  mirrored-header validation (-32020 for missing or mismatched
  MCP-Protocol-Version / Mcp-Method / Mcp-Name, sentinel decoding),
  the SSE response mode for notification-opted requests (and the
  single-JSON answer when such a request emits nothing), legacy
  GET/DELETE refusal, Origin allowlisting including the host-spoofing
  shapes, the ignored legacy session/resumability headers, and the
  Stop/Run ordering contract. }

program MCP.Transport.HTTP.Test;

{$I Shared.inc}

uses
  // The threaded listener needs the Unix thread driver, and it must
  // be the first unit a program pulls in.
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,

  fpjson,
  jsonparser,
  fphttpclient,
  sockets,
  MCP.Protocol,
  MCP.Schema,
  MCP.Server,
  MCP.Transport.HTTP,
  TestingPascalLibrary;

const
  META_MODERN =
    '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{}}';
  META_MODERN_STREAMING =
    '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{},' +
    '"progressToken":"tok-1",' +
    '"io.modelcontextprotocol/logLevel":"debug"}';
  ALL_STATUSES: array[0..7] of Integer =
    (200, 202, 400, 403, 404, 405, 413, 500);

type
  TServerThread = class(TThread)
  private
    FTransport: TMCPHTTPServer;
  public
    constructor CreateFor(ATransport: TMCPHTTPServer);
    procedure Execute; override;
  end;

  THeaderPair = record
    Name, Value: string;
  end;

  THTTPBinding = class(TTestSuite)
  private
    FServer: TMCPServer;
    FTransport: TMCPHTTPServer;
    FThread: TServerThread;
    FBaseUrl: string;
    // One HTTP exchange; returns the status code, body and selected
    // response headers.
    function Exchange(const AMethod, APath, ABody: string;
      const AHeaders: array of THeaderPair; out AResponseBody: string;
      out AContentType: string): Integer;
    // POST to the endpoint with the standard modern headers for
    // AMcpMethod/AMcpName; '' skips a header entirely.
    function Post(const ABody, AMcpMethod, AMcpName: string;
      out AResponseBody: string): Integer;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;
    procedure TestSingleJSONResponse;
    procedure TestBareDiscoverProbe;
    procedure TestNotificationAccepted;
    procedure TestMalformedNotificationAccepted;
    procedure TestInvalidRequestBody;
    procedure TestMissingMcpMethod;
    procedure TestMismatchedMcpMethod;
    procedure TestMissingProtocolVersionHeader;
    procedure TestMismatchedProtocolVersionHeader;
    procedure TestUnsupportedVersion;
    procedure TestMissingMcpName;
    procedure TestSentinelEncodedMcpName;
    procedure TestUnknownMethod404;
    procedure TestInitializeRejected404;
    procedure TestLegacyGetRefused;
    procedure TestLegacyDeleteRefused;
    procedure TestWrongPath;
    procedure TestForeignOriginRejected;
    procedure TestLocalhostOriginAccepted;
    procedure TestIPv6LoopbackOriginAccepted;
    procedure TestIPv6PrefixedOriginRejected;
    procedure TestIPv6SuffixedOriginRejected;
    procedure TestUserinfoOriginRejected;
    procedure TestNonWebSchemeOriginRejected;
    procedure TestSessionHeaderIgnored;
    procedure TestOversizedBody;
    procedure TestSSEStream;
    procedure TestStreamingProtocolErrorIsJSON;
    procedure TestStreamingWithoutNotificationsIsJSON;
    procedure TestStopBeforeRunReturns;
    procedure TestStopDuringStartupReturns;
  end;

function PingHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPTextResult('pong');
end;

// Emits both opt-in notification kinds so the SSE test sees a stream
// with events before the final response.
function NoisyEchoHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  MCPReportProgress(ACtx, 0.5, 1.0, 'halfway');
  MCPLogMessage(ACtx, 'info', 'echo invoked');
  Result := MCPTextResult(AArguments.Get('message', ''));
end;

// Emits nothing while it runs: a streaming-opted call to this tool
// must still come back as a single JSON object.
function QuietHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPTextResult('quiet');
end;

// Ask the kernel for a free localhost port: bind port 0, read the
// assignment back, release it for the listener to claim.
function FindFreePort: Word;
var
  Sock: LongInt;
  Addr: TInetSockAddr;
  AddrLen: TSockLen;
begin
  Sock := fpSocket(AF_INET, SOCK_STREAM, 0);
  if Sock < 0 then
    raise Exception.Create('FindFreePort: socket() failed');
  try
    FillChar(Addr, SizeOf(Addr), 0);
    Addr.sin_family := AF_INET;
    Addr.sin_port := 0;
    Addr.sin_addr.s_addr := htonl($7F000001);
    if fpBind(Sock, @Addr, SizeOf(Addr)) <> 0 then
      raise Exception.Create('FindFreePort: bind() failed');
    AddrLen := SizeOf(Addr);
    if fpGetSockName(Sock, @Addr, @AddrLen) <> 0 then
      raise Exception.Create('FindFreePort: getsockname() failed');
    Result := ntohs(Addr.sin_port);
  finally
    CloseSocket(Sock);
  end;
end;

constructor TServerThread.CreateFor(ATransport: TMCPHTTPServer);
begin
  FTransport := ATransport;
  inherited Create(False);
end;

procedure TServerThread.Execute;
begin
  FTransport.Run;
end;

procedure THTTPBinding.BeforeEach;
var
  Attempt: Integer;
  Probe, ProbeType: string;
begin
  FServer := TMCPServer.Create('http-test', '1.0');
  FServer.RegisterTool('ping', 'Ping', '{"type":"object"}', PingHandler);
  FServer.RegisterTool('echo', 'Echo',
    ObjectSchema.AddString('message', 'Text to echo'), NoisyEchoHandler);
  FServer.RegisterTool('quiet', 'Quiet', '{"type":"object"}', QuietHandler);
  FTransport := TMCPHTTPServer.Create(FServer);
  FTransport.Port := FindFreePort;
  FBaseUrl := 'http://127.0.0.1:' + IntToStr(FTransport.Port);
  FThread := TServerThread.CreateFor(FTransport);
  // Wait for the listener: GET / answers 404 once the socket accepts.
  for Attempt := 1 to 100 do
  begin
    try
      Exchange('GET', '/nonexistent', '', [], Probe, ProbeType);
      Exit;
    except
      Sleep(50);
    end;
  end;
  raise Exception.Create('HTTP listener did not come up');
end;

procedure THTTPBinding.AfterEach;
begin
  FTransport.Stop;
  FThread.WaitFor;
  FreeAndNil(FThread);
  FreeAndNil(FTransport);
  FreeAndNil(FServer);
end;

function THTTPBinding.Exchange(const AMethod, APath, ABody: string;
  const AHeaders: array of THeaderPair; out AResponseBody: string;
  out AContentType: string): Integer;
var
  Client: TFPHTTPClient;
  Response: TStringStream;
  I: Integer;
begin
  Client := TFPHTTPClient.Create(nil);
  try
    for I := Low(AHeaders) to High(AHeaders) do
      Client.AddHeader(AHeaders[I].Name, AHeaders[I].Value);
    if ABody <> '' then
    begin
      Client.AddHeader('Content-Type', 'application/json');
      Client.RequestBody := TStringStream.Create(ABody);
    end;
    Response := TStringStream.Create('');
    try
      Client.HTTPMethod(AMethod, FBaseUrl + APath, Response, ALL_STATUSES);
      Result := Client.ResponseStatusCode;
      AResponseBody := Response.DataString;
      AContentType := Client.GetHeader(Client.ResponseHeaders,
        'Content-Type');
    finally
      Response.Free;
      Client.RequestBody.Free;
      Client.RequestBody := nil;
    end;
  finally
    Client.Free;
  end;
end;

function HeaderPair(const AName, AValue: string): THeaderPair;
begin
  Result.Name := AName;
  Result.Value := AValue;
end;

function THTTPBinding.Post(const ABody, AMcpMethod, AMcpName: string;
  out AResponseBody: string): Integer;
var
  Headers: array of THeaderPair;
  ContentType: string;
begin
  Headers := [HeaderPair('MCP-Protocol-Version', MCP_PROTOCOL_VERSION)];
  if AMcpMethod <> '' then
    Headers := Concat(Headers, [HeaderPair('Mcp-Method', AMcpMethod)]);
  if AMcpName <> '' then
    Headers := Concat(Headers, [HeaderPair('Mcp-Name', AMcpName)]);
  Result := Exchange('POST', '/mcp', ABody, Headers, AResponseBody,
    ContentType);
end;

function ErrorCodeOf(const ABody: string): Integer;
var
  Parsed: TJSONData;
begin
  Parsed := GetJSON(ABody);
  try
    Result := TJSONData(Parsed.FindPath('error.code')).AsInteger;
  finally
    Parsed.Free;
  end;
end;

function CallLine(AId: Integer; const AToolName: string;
  const AMeta: string = META_MODERN): string;
begin
  Result := '{"jsonrpc":"2.0","id":' + IntToStr(AId) +
    ',"method":"tools/call","params":{"name":"' + AToolName + '",' +
    '"arguments":{"message":"hi"},' + AMeta + '}}';
end;

{ ───────── tests ───────── }

procedure THTTPBinding.TestSingleJSONResponse;
var
  Body, ContentType: string;
  Status: Integer;
begin
  Status := Exchange('POST', '/mcp', CallLine(1, 'ping'),
    [HeaderPair('MCP-Protocol-Version', MCP_PROTOCOL_VERSION),
     HeaderPair('Mcp-Method', 'tools/call'),
     HeaderPair('Mcp-Name', 'ping')], Body, ContentType);
  Expect<Integer>(Status).ToBe(200);
  Expect<string>(ContentType).ToBe('application/json');
  Expect<Boolean>(Pos('pong', Body) > 0).ToBe(True);
  Expect<Boolean>(Pos('"resultType" : "complete"', Body) > 0).ToBe(True);
end;

procedure THTTPBinding.TestBareDiscoverProbe;
var
  Body, ContentType: string;
  Status: Integer;
begin
  // A body carrying no _meta envelope and no mirrored headers is not
  // rejected by the transport with a misleading -32020 header
  // mismatch: header validation keys on the envelope claim, so the
  // request reaches the core (SDK-anchor fact, see the unit header).
  // server/discover still carries _meta like every request (spec
  // verified 2026-08-08:
  // https://modelcontextprotocol.io/specification/2026-07-28/server/discover),
  // so the core answers the accurate -32602 for the missing _meta
  // rather than the transport masking it as a header error.
  Status := Exchange('POST', '/mcp',
    '{"jsonrpc":"2.0","id":0,"method":"server/discover","params":{}}',
    [], Body, ContentType);
  Expect<Integer>(Status).ToBe(200);
  Expect<Integer>(ErrorCodeOf(Body)).ToBe(-32602);
end;

procedure THTTPBinding.TestNotificationAccepted;
var
  Body: string;
  Status: Integer;
begin
  Status := Post('{"jsonrpc":"2.0","method":"notifications/cancelled",' +
    '"params":{"requestId":1}}', '', '', Body);
  Expect<Integer>(Status).ToBe(202);
  Expect<string>(Body).ToBe('');
end;

procedure THTTPBinding.TestMalformedNotificationAccepted;
var
  Body: string;
  Status: Integer;
begin
  // Fire-and-forget: a malformed notification is dropped, not
  // answered with an error.
  Status := Post('{"jsonrpc":"2.0","method":"notifications/cancelled",' +
    '"params":[1,2]}', '', '', Body);
  Expect<Integer>(Status).ToBe(202);
  Expect<string>(Body).ToBe('');
end;

procedure THTTPBinding.TestInvalidRequestBody;
var
  Body: string;
  Status: Integer;
begin
  Status := Post('{"jsonrpc":"2.0","id":5,"method":"tools/list",' +
    '"params":[1]}', 'tools/list', '', Body);
  Expect<Integer>(Status).ToBe(400);
  Expect<Integer>(ErrorCodeOf(Body)).ToBe(-32600);
end;

procedure THTTPBinding.TestMissingMcpMethod;
var
  Body: string;
  Status: Integer;
begin
  Status := Post(CallLine(1, 'ping'), '', 'ping', Body);
  Expect<Integer>(Status).ToBe(400);
  Expect<Integer>(ErrorCodeOf(Body)).ToBe(-32020);
end;

procedure THTTPBinding.TestMismatchedMcpMethod;
var
  Body: string;
  Status: Integer;
begin
  Status := Post(CallLine(1, 'ping'), 'tools/list', 'ping', Body);
  Expect<Integer>(Status).ToBe(400);
  Expect<Integer>(ErrorCodeOf(Body)).ToBe(-32020);
end;

procedure THTTPBinding.TestMissingProtocolVersionHeader;
var
  Body, ContentType: string;
  Status: Integer;
begin
  Status := Exchange('POST', '/mcp', CallLine(1, 'ping'),
    [HeaderPair('Mcp-Method', 'tools/call'),
     HeaderPair('Mcp-Name', 'ping')], Body, ContentType);
  Expect<Integer>(Status).ToBe(400);
  Expect<Integer>(ErrorCodeOf(Body)).ToBe(-32020);
end;

procedure THTTPBinding.TestMismatchedProtocolVersionHeader;
var
  Body, ContentType: string;
  Status: Integer;
begin
  Status := Exchange('POST', '/mcp', CallLine(1, 'ping'),
    [HeaderPair('MCP-Protocol-Version', '2025-11-25'),
     HeaderPair('Mcp-Method', 'tools/call'),
     HeaderPair('Mcp-Name', 'ping')], Body, ContentType);
  Expect<Integer>(Status).ToBe(400);
  Expect<Integer>(ErrorCodeOf(Body)).ToBe(-32020);
end;

procedure THTTPBinding.TestUnsupportedVersion;
var
  Line, Body, ContentType: string;
  Status: Integer;
begin
  // Header and body agree on a version this modern-only server does
  // not implement: the core's -32022 with the supported list, HTTP 400.
  Line := '{"jsonrpc":"2.0","id":9,"method":"tools/list","params":{' +
    '"_meta":{"io.modelcontextprotocol/protocolVersion":"2025-11-25",' +
    '"io.modelcontextprotocol/clientCapabilities":{}}}}';
  Status := Exchange('POST', '/mcp', Line,
    [HeaderPair('MCP-Protocol-Version', '2025-11-25'),
     HeaderPair('Mcp-Method', 'tools/list')], Body, ContentType);
  Expect<Integer>(Status).ToBe(400);
  Expect<Integer>(ErrorCodeOf(Body)).ToBe(-32022);
  Expect<Boolean>(Pos(MCP_PROTOCOL_VERSION, Body) > 0).ToBe(True);
end;

procedure THTTPBinding.TestMissingMcpName;
var
  Body: string;
  Status: Integer;
begin
  Status := Post(CallLine(1, 'ping'), 'tools/call', '', Body);
  Expect<Integer>(Status).ToBe(400);
  Expect<Integer>(ErrorCodeOf(Body)).ToBe(-32020);
end;

procedure THTTPBinding.TestSentinelEncodedMcpName;
var
  Body: string;
  Status: Integer;
begin
  // '=?base64?cGluZw==?=' decodes to 'ping' and must match the body.
  Status := Post(CallLine(1, 'ping'), 'tools/call',
    '=?base64?cGluZw==?=', Body);
  Expect<Integer>(Status).ToBe(200);
  Expect<Boolean>(Pos('pong', Body) > 0).ToBe(True);
end;

procedure THTTPBinding.TestUnknownMethod404;
var
  Body: string;
  Status: Integer;
begin
  Status := Post('{"jsonrpc":"2.0","id":2,"method":"no/such",' +
    '"params":{' + META_MODERN + '}}', 'no/such', '', Body);
  Expect<Integer>(Status).ToBe(404);
  Expect<Integer>(ErrorCodeOf(Body)).ToBe(-32601);
end;

procedure THTTPBinding.TestInitializeRejected404;
var
  Body: string;
  Status: Integer;
begin
  // Modern-only posture: a legacy handshake gets the -32601 whose
  // message names the supported versions — the recognizable modern
  // error the backward-compatibility flow keys on.
  Status := Post('{"jsonrpc":"2.0","id":1,"method":"initialize",' +
    '"params":{"protocolVersion":"2025-11-25","capabilities":{},' +
    '"clientInfo":{"name":"legacy","version":"1.0"}}}',
    'initialize', '', Body);
  Expect<Integer>(Status).ToBe(404);
  Expect<Integer>(ErrorCodeOf(Body)).ToBe(-32601);
  Expect<Boolean>(Pos(MCP_PROTOCOL_VERSION, Body) > 0).ToBe(True);
end;

procedure THTTPBinding.TestLegacyGetRefused;
var
  Body, ContentType: string;
  Status: Integer;
begin
  Status := Exchange('GET', '/mcp', '', [], Body, ContentType);
  Expect<Integer>(Status).ToBe(405);
end;

procedure THTTPBinding.TestLegacyDeleteRefused;
var
  Body, ContentType: string;
  Status: Integer;
begin
  Status := Exchange('DELETE', '/mcp', '', [], Body, ContentType);
  Expect<Integer>(Status).ToBe(405);
end;

procedure THTTPBinding.TestWrongPath;
var
  Body, ContentType: string;
  Status: Integer;
begin
  Status := Exchange('POST', '/other', CallLine(1, 'ping'),
    [HeaderPair('MCP-Protocol-Version', MCP_PROTOCOL_VERSION),
     HeaderPair('Mcp-Method', 'tools/call'),
     HeaderPair('Mcp-Name', 'ping')], Body, ContentType);
  Expect<Integer>(Status).ToBe(404);
end;

procedure THTTPBinding.TestForeignOriginRejected;
var
  Body, ContentType: string;
  Status: Integer;
begin
  Status := Exchange('POST', '/mcp', CallLine(1, 'ping'),
    [HeaderPair('Origin', 'https://evil.example'),
     HeaderPair('MCP-Protocol-Version', MCP_PROTOCOL_VERSION),
     HeaderPair('Mcp-Method', 'tools/call'),
     HeaderPair('Mcp-Name', 'ping')], Body, ContentType);
  Expect<Integer>(Status).ToBe(403);
end;

procedure THTTPBinding.TestLocalhostOriginAccepted;
var
  Body, ContentType: string;
  Status: Integer;
begin
  Status := Exchange('POST', '/mcp', CallLine(1, 'ping'),
    [HeaderPair('Origin', 'http://localhost:5173'),
     HeaderPair('MCP-Protocol-Version', MCP_PROTOCOL_VERSION),
     HeaderPair('Mcp-Method', 'tools/call'),
     HeaderPair('Mcp-Name', 'ping')], Body, ContentType);
  Expect<Integer>(Status).ToBe(200);
end;

procedure THTTPBinding.TestIPv6LoopbackOriginAccepted;
var
  Body, ContentType: string;
  Status: Integer;
begin
  Status := Exchange('POST', '/mcp', CallLine(1, 'ping'),
    [HeaderPair('Origin', 'http://[::1]:8080'),
     HeaderPair('MCP-Protocol-Version', MCP_PROTOCOL_VERSION),
     HeaderPair('Mcp-Method', 'tools/call'),
     HeaderPair('Mcp-Name', 'ping')], Body, ContentType);
  Expect<Integer>(Status).ToBe(200);
end;

procedure THTTPBinding.TestIPv6PrefixedOriginRejected;
var
  Body, ContentType: string;
  Status: Integer;
begin
  // The bracketed loopback literal is the whole host or nothing: a
  // foreign host that merely starts with it is not localhost.
  Status := Exchange('POST', '/mcp', CallLine(1, 'ping'),
    [HeaderPair('Origin', 'http://[::1].attacker.example'),
     HeaderPair('MCP-Protocol-Version', MCP_PROTOCOL_VERSION),
     HeaderPair('Mcp-Method', 'tools/call'),
     HeaderPair('Mcp-Name', 'ping')], Body, ContentType);
  Expect<Integer>(Status).ToBe(403);
end;

procedure THTTPBinding.TestIPv6SuffixedOriginRejected;
var
  Body, ContentType: string;
  Status: Integer;
begin
  Status := Exchange('POST', '/mcp', CallLine(1, 'ping'),
    [HeaderPair('Origin', 'http://[::1]evil'),
     HeaderPair('MCP-Protocol-Version', MCP_PROTOCOL_VERSION),
     HeaderPair('Mcp-Method', 'tools/call'),
     HeaderPair('Mcp-Name', 'ping')], Body, ContentType);
  Expect<Integer>(Status).ToBe(403);
end;

procedure THTTPBinding.TestUserinfoOriginRejected;
var
  Body, ContentType: string;
  Status: Integer;
begin
  // Userinfo would make 'localhost' the credentials and the foreign
  // host the target; a serialized origin never carries it.
  Status := Exchange('POST', '/mcp', CallLine(1, 'ping'),
    [HeaderPair('Origin', 'http://localhost:99@evil.example'),
     HeaderPair('MCP-Protocol-Version', MCP_PROTOCOL_VERSION),
     HeaderPair('Mcp-Method', 'tools/call'),
     HeaderPair('Mcp-Name', 'ping')], Body, ContentType);
  Expect<Integer>(Status).ToBe(403);
end;

procedure THTTPBinding.TestNonWebSchemeOriginRejected;
var
  Body, ContentType: string;
  Status: Integer;
begin
  // The loopback allowlist is for web origins only: a non-http(s)
  // scheme in front of a loopback host must not slip through, or
  // 'weird://localhost' would inherit localhost's trust.
  Status := Exchange('POST', '/mcp', CallLine(1, 'ping'),
    [HeaderPair('Origin', 'weird://localhost'),
     HeaderPair('MCP-Protocol-Version', MCP_PROTOCOL_VERSION),
     HeaderPair('Mcp-Method', 'tools/call'),
     HeaderPair('Mcp-Name', 'ping')], Body, ContentType);
  Expect<Integer>(Status).ToBe(403);
end;

procedure THTTPBinding.TestSessionHeaderIgnored;
var
  Body, ContentType: string;
  Status: Integer;
begin
  // Legacy session and resumability headers are ignored, not echoed
  // and not errors.
  Status := Exchange('POST', '/mcp', CallLine(1, 'ping'),
    [HeaderPair('Mcp-Session-Id', 'legacy-session'),
     HeaderPair('Last-Event-ID', '42'),
     HeaderPair('MCP-Protocol-Version', MCP_PROTOCOL_VERSION),
     HeaderPair('Mcp-Method', 'tools/call'),
     HeaderPair('Mcp-Name', 'ping')], Body, ContentType);
  Expect<Integer>(Status).ToBe(200);
end;

procedure THTTPBinding.TestOversizedBody;
var
  Body: string;
  Status: Integer;
begin
  FTransport.MaxBodyBytes := 200;
  Status := Post('{"pad":"' + StringOfChar('x', 300) + '"}',
    'tools/call', 'ping', Body);
  Expect<Integer>(Status).ToBe(413);
  Expect<Integer>(ErrorCodeOf(Body)).ToBe(-32700);
end;

procedure THTTPBinding.TestSSEStream;
var
  Body, ContentType, LastEvent: string;
  Status, EventCount, Cut: Integer;
  Events: array of string;
begin
  Status := Exchange('POST', '/mcp',
    CallLine(3, 'echo', META_MODERN_STREAMING),
    [HeaderPair('MCP-Protocol-Version', MCP_PROTOCOL_VERSION),
     HeaderPair('Mcp-Method', 'tools/call'),
     HeaderPair('Mcp-Name', 'echo')], Body, ContentType);
  Expect<Integer>(Status).ToBe(200);
  Expect<string>(ContentType).ToBe('text/event-stream');

  // Split the stream into data: events.
  Events := [];
  while Body <> '' do
  begin
    Cut := Pos(#10#10, Body);
    if Cut = 0 then
      Break;
    Expect<string>(Copy(Body, 1, 6)).ToBe('data: ');
    Events := Concat(Events, [Copy(Body, 7, Cut - 7)]);
    Delete(Body, 1, Cut + 1);
  end;
  EventCount := Length(Events);
  // progress(0.5) + log message + final response, in stream order.
  Expect<Integer>(EventCount).ToBe(3);
  // Guard the per-event indexing: a short stream must report the
  // failed count expectation above and let the suite continue, not
  // range-error on Events[...] and abort the whole program.
  if EventCount >= 3 then
  begin
    Expect<Boolean>(
      Pos('notifications/progress', Events[0]) > 0).ToBe(True);
    Expect<Boolean>(
      Pos('notifications/message', Events[1]) > 0).ToBe(True);
    LastEvent := Events[EventCount - 1];
    Expect<Boolean>(Pos('"result"', LastEvent) > 0).ToBe(True);
    Expect<Boolean>(Pos('"hi"', LastEvent) > 0).ToBe(True);
  end;
end;

procedure THTTPBinding.TestStreamingProtocolErrorIsJSON;
var
  Line, Body, ContentType: string;
  Status: Integer;
begin
  // The streaming opt-in must not change the status a client sees:
  // this request fails the version gate before any handler runs, so
  // no notification is emitted and the answer is the same 400 the
  // non-streaming form gets.
  Line := '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{' +
    '"name":"ping","arguments":{},' +
    '"_meta":{"io.modelcontextprotocol/protocolVersion":"2025-11-25",' +
    '"io.modelcontextprotocol/clientCapabilities":{},' +
    '"progressToken":"tok-1"}}}';
  Status := Exchange('POST', '/mcp', Line,
    [HeaderPair('MCP-Protocol-Version', '2025-11-25'),
     HeaderPair('Mcp-Method', 'tools/call'),
     HeaderPair('Mcp-Name', 'ping')], Body, ContentType);
  Expect<Integer>(Status).ToBe(400);
  Expect<string>(ContentType).ToBe('application/json');
  Expect<Integer>(ErrorCodeOf(Body)).ToBe(-32022);
end;

procedure THTTPBinding.TestStreamingWithoutNotificationsIsJSON;
var
  Body, ContentType: string;
  Status: Integer;
begin
  // Opted in, but the handler emits nothing: the stream is never
  // opened and the response stays a single JSON object.
  Status := Exchange('POST', '/mcp',
    CallLine(4, 'quiet', META_MODERN_STREAMING),
    [HeaderPair('MCP-Protocol-Version', MCP_PROTOCOL_VERSION),
     HeaderPair('Mcp-Method', 'tools/call'),
     HeaderPair('Mcp-Name', 'quiet')], Body, ContentType);
  Expect<Integer>(Status).ToBe(200);
  Expect<string>(ContentType).ToBe('application/json');
  Expect<Boolean>(Pos('data: ', Body) > 0).ToBe(False);
  Expect<Boolean>(Pos('quiet', Body) > 0).ToBe(True);
end;

procedure THTTPBinding.TestStopBeforeRunReturns;
var
  Server: TMCPServer;
  Transport: TMCPHTTPServer;
  Started: QWord;
begin
  // Stop before Run: the transport stays stopped and Run does not
  // block on a listener nothing would ever close.
  Server := TMCPServer.Create('stop-test', '1.0');
  try
    Transport := TMCPHTTPServer.Create(Server);
    try
      Transport.Port := FindFreePort;
      Transport.Stop;
      Started := GetTickCount64;
      Transport.Run;
      Expect<Boolean>(GetTickCount64 - Started < 2000).ToBe(True);
    finally
      Transport.Free;
    end;
  finally
    Server.Free;
  end;
end;

procedure THTTPBinding.TestStopDuringStartupReturns;
var
  Server: TMCPServer;
  Transport: TMCPHTTPServer;
  Thread: TServerThread;
  Deadline: QWord;
  Finished: Boolean;
begin
  // Stop racing the listener's startup: whichever side wins, the
  // accept-idle tick picks the request up and Run returns.
  Server := TMCPServer.Create('stop-race-test', '1.0');
  try
    Transport := TMCPHTTPServer.Create(Server);
    try
      Transport.Port := FindFreePort;
      Thread := TServerThread.CreateFor(Transport);
      try
        Transport.Stop;
        // Bounded poll instead of an unconditional WaitFor: if the
        // transport regressed and Run never returns, a blocking WaitFor
        // would hang the whole suite instead of reporting the failed
        // expectation. Wait at most a few seconds, then assert Run
        // finished; only join the thread when it actually did so
        // cleanup cannot block on the failure path.
        Deadline := GetTickCount64 + 4000;
        Finished := False;
        while GetTickCount64 < Deadline do
        begin
          if Thread.Finished then
          begin
            Finished := True;
            Break;
          end;
          Sleep(50);
        end;
        Expect<Boolean>(Finished).ToBe(True);
        if Finished then
          Thread.WaitFor;
      finally
        Thread.Free;
      end;
    finally
      Transport.Free;
    end;
  finally
    Server.Free;
  end;
end;

procedure THTTPBinding.SetupTests;
begin
  Test('request → single application/json response',
    TestSingleJSONResponse);
  Test('bare server/discover probe served without headers',
    TestBareDiscoverProbe);
  Test('notification → 202, no body', TestNotificationAccepted);
  Test('malformed notification dropped → 202',
    TestMalformedNotificationAccepted);
  Test('invalid request body → 400, -32600', TestInvalidRequestBody);
  Test('missing Mcp-Method → 400, -32020', TestMissingMcpMethod);
  Test('mismatched Mcp-Method → 400, -32020', TestMismatchedMcpMethod);
  Test('missing MCP-Protocol-Version → 400, -32020',
    TestMissingProtocolVersionHeader);
  Test('header/body version mismatch → 400, -32020',
    TestMismatchedProtocolVersionHeader);
  Test('unsupported version → 400, -32022 with supported list',
    TestUnsupportedVersion);
  Test('missing Mcp-Name on tools/call → 400, -32020',
    TestMissingMcpName);
  Test('sentinel-encoded Mcp-Name decoded and matched',
    TestSentinelEncodedMcpName);
  Test('unknown method → 404, -32601', TestUnknownMethod404);
  Test('legacy initialize → 404, versions named',
    TestInitializeRejected404);
  Test('GET → 405', TestLegacyGetRefused);
  Test('DELETE → 405', TestLegacyDeleteRefused);
  Test('wrong path → 404', TestWrongPath);
  Test('foreign Origin → 403', TestForeignOriginRejected);
  Test('localhost Origin accepted', TestLocalhostOriginAccepted);
  Test('[::1] loopback Origin accepted',
    TestIPv6LoopbackOriginAccepted);
  Test('Origin merely prefixed with [::1] → 403',
    TestIPv6PrefixedOriginRejected);
  Test('Origin with trailing junk after [::1] → 403',
    TestIPv6SuffixedOriginRejected);
  Test('Origin with userinfo → 403', TestUserinfoOriginRejected);
  Test('Origin with non-web scheme → 403',
    TestNonWebSchemeOriginRejected);
  Test('legacy session/resume headers ignored',
    TestSessionHeaderIgnored);
  Test('oversized body → 413', TestOversizedBody);
  Test('notification-opted request → SSE stream, response last',
    TestSSEStream);
  Test('notification-opted protocol error → 400 JSON, -32022',
    TestStreamingProtocolErrorIsJSON);
  Test('notification-opted call emitting nothing → 200 JSON',
    TestStreamingWithoutNotificationsIsJSON);
  Test('Stop before Run → Run returns at once',
    TestStopBeforeRunReturns);
  Test('Stop racing startup → Run still returns',
    TestStopDuringStartupReturns);
end;

begin
  TestRunnerProgram.AddSuite(THTTPBinding.Create('Transport.HTTP: binding'));
  TestRunnerProgram.Run;
  // Fail the process when any suite failed, so lwpt test and CI
  // actually gate on assertions (the runner does not set it).
  ExitCode := TestResultToExitCode;
end.
