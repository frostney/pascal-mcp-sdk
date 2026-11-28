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

{$I MCP.inc}

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
  ssockets,
  MCP.Events,
  MCP.Extensions,
  MCP.JSONRPC,
  MCP.Protocol,
  MCP.Schema,
  MCP.Server,
  MCP.Streams,
  MCP.Subscriptions,
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

  // A method and header lookup for a route named by "target".
  TRouteFixture = class
  public
    function Answer(AParams: TJSONObject; const ACtx: TMCPRequestContext;
      ALegacy: Boolean): TJSONObject;
    function Headers(const AName: string): TMCPHeaderParameters;
  end;

  THTTPBinding = class(TTestSuite)
  private
    FRouteFixture: TRouteFixture;
    FServer: TMCPServer;
    FTransport: TMCPHTTPServer;
    FThread: TServerThread;
    FBaseUrl: string;
    // One HTTP exchange; returns the status code, body and selected
    // response headers.
    function Exchange(const AMethod, APath, ABody: string;
      const AHeaders: array of THeaderPair; out AResponseBody: string;
      out AContentType: string): Integer;
    // A tools/call of 'routed' (#90) with AArguments and extra headers.
    function PostRouted(const AArguments: string;
      const AHeaders: array of THeaderPair; out ABody: string): Integer;
    // POST to the endpoint with the standard modern headers for
    // AMcpMethod/AMcpName; '' skips a header entirely.
    function Post(const ABody, AMcpMethod, AMcpName: string;
      out AResponseBody: string): Integer;
    // A well-formed tools/call POST that differs only in Origin, then
    // the status the loopback allowlist must answer with.
    procedure ExpectOriginStatus(const AOrigin: string;
      AExpectedStatus: Integer);
    // Raw POST declaring ADeclaredLength but sending no body, read to
    // EOF. The over-cap refusal keys on the declared Content-Length
    // alone, and a body the server never reads would sit unread at
    // close and turn the close into an RST that races the client's
    // read of the buffered 413 (the kernel discards pending data when
    // the reset lands first). With nothing unsent the close is a
    // clean FIN, so the response is always readable — and reaching
    // EOF is itself the connection-close assertion.
    // A tools/call of 'routed' with AArguments and AExtraHeaderLines
    // (raw "Name: value" lines, CRLF-joined), sent over a raw socket so
    // a field can repeat; returns the status.
    function PostRoutedRaw(const AArguments, AExtraHeaderLines: string;
      out ABody: string): Integer;
    // An events/poll with params AParamsJson (each member followed by a
    // comma), Mcp-Name AName ('' sends none) and AHeaders.
    function PostPollRaw(const AHeaderLines: string;
      out ABody: string): Integer;
    function PostPoll(const AName, AParamsJson: string;
      const AHeaders: array of THeaderPair; out ABody: string): Integer;
    function PostWithUnsentBody(ADeclaredLength: Integer;
      out AResponseBody: string): Integer;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;
    procedure TestSingleJSONResponse;
    procedure TestHandlerRaisedMissingCapability400;
    procedure TestRefusalAfterProgressEndsTheStream;
    procedure TestBareDiscoverProbe;
    procedure TestMissingProtocolVersion400;
    procedure TestMissingClientCapabilities400;
    procedure TestInBandInvalidParamsStays200;
    procedure TestEventRouting;
    procedure TestEventStream;
    procedure TestListenStream;
    procedure TestEventStreamClientClose;
    procedure TestQuietStreamClientClose;
    procedure TestStopDuringACheck;
    procedure TestStopDuringTheOpeningCheck;
    procedure TestProgressThenPark;
    procedure TestStreamingOptInMissingCapabilities400;
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
    procedure TestParamHeadersMatch;
    procedure TestParamHeaderMissing;
    procedure TestParamHeaderMismatch;
    procedure TestParamHeaderBadBase64;
    procedure TestParamHeaderUnencodedNonASCII;
    procedure TestParamHeaderWithoutValue;
    procedure TestParamHeaderEmptyAndRepeated;
    procedure TestParamHeaderIntegers;
    procedure TestMcpNameStrictBase64;
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
    procedure TestDeclaredCapabilityRefusedBeforeStreaming;
    procedure TestUndeclaredCapabilityStillEndsTheStream;
    function AbandonWaiter(AReset: Boolean; const AExtra: string;
      out ASawOpen, AResetSet: Boolean): string;
    procedure TestBytesBeforeCloseStillCancel;
    procedure TestDisconnectCancelsSilentHandler;
    procedure TestResetCancelsSilentHandler;
    procedure TestSSEStream;
    procedure TestCompletionStreams;
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

// A completion callback that reports progress: completion/complete
// runs a handler too, so an opted-in HTTP request streams (#81).
function NoisyCompletion(const AArgument, AValue: string;
  AContext: TJSONObject; const ACtx: TMCPRequestContext): TMCPCompletion;
begin
  MCPReportProgress(ACtx, 1, 1, 'looked up');
  Result := MCPCompleteFrom(AValue, ['alpha', 'beta']);
end;

function HintPrompt(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  Result := MCPMessages([MCPUserMessage('hint')]);
end;

// Reports progress, then asks for sampling (#84).
function ProgressThenSamplingHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Requests: TJSONObject;
begin
  MCPReportProgress(ACtx, 0.5, 1.0, 'halfway');
  Requests := TJSONObject.Create;
  try
    Requests.Add('s', MCPSamplingTextRequest('Say hi', 10));
  except
    Requests.Free;
    raise;
  end;
  Result := MCPInputRequired(Requests);
end;

// Splits an SSE body into its events' data. False unless every event
// is one "data: " line ended by a blank line, with nothing left over.
function SplitSSEEvents(ABody: string; out AEvents: TStringArray): Boolean;
var
  Cut: Integer;
begin
  AEvents := nil;
  while ABody <> '' do
  begin
    Cut := Pos(#10#10, ABody);
    if (Cut = 0) or (Copy(ABody, 1, 6) <> 'data: ') or
      (Pos(#10, Copy(ABody, 1, Cut - 1)) > 0) then
      Exit(False);
    AEvents := Concat(AEvents, [Copy(ABody, 7, Cut - 7)]);
    Delete(ABody, 1, Cut + 1);
  end;
  Result := True;
end;

// An SSE body of well-formed events: progress first, and the -32021
// error alone as the last event.
function ProgressThenFinalRefusal(const ABody: string): Boolean;
var
  Events: TStringArray;
begin
  Result := SplitSSEEvents(ABody, Events) and (Length(Events) >= 2) and
    (Pos('notifications/progress', Events[0]) > 0) and
    (Pos('-32021', Events[0]) = 0) and
    (Pos('"code" : -32021', Events[High(Events)]) > 0) and
    (Pos('notifications/progress', Events[High(Events)]) = 0);
end;

// Emits nothing while it runs: a streaming-opted call to this tool
// must still come back as a single JSON object.
var
  // How the polling handler ended: 'cancelled' or 'finished'. Written
  // on the connection thread before WaiterDone is set, read after it.
  WaiterOutcome: string;
  // Set once the handler's first poll found the connection open, and
  // once it has ended.
  WaiterEntered, WaiterDone: PRTLEvent;
  // The first poll found the connection open.
  WaiterSawOpen: Boolean;

// Polls IsCancelled for up to three seconds without writing anything:
// only the binding's disconnect poll can cancel it (#93).
function WaiterHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  I: Integer;
begin
  WaiterOutcome := 'finished';
  for I := 1 to 300 do
  begin
    if ACtx.IsCancelled then
    begin
      WaiterOutcome := 'cancelled';
      Break;
    end;
    if I = 1 then
    begin
      WaiterSawOpen := True;
      RTLEventSetEvent(WaiterEntered);
    end;
    Sleep(10);
  end;
  Result := MCPTextResult(WaiterOutcome);
  RTLEventSetEvent(WaiterDone);
end;

function QuietHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPTextResult('quiet');
end;

// Reports progress, then raises -32021: the stream is open by then.
function ProgressThenRefuseHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  MCPReportProgress(ACtx, 0.5, 1.0, 'halfway');
  Result := Default(TMCPToolResult);
  raise MCPMissingCapabilityError('sampling');
end;

// Raises the -32021 a handler decides itself (#88).
function NeedsSamplingHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := Default(TMCPToolResult);
  raise MCPMissingCapabilityError('sampling');
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

// Poll AThread.Finished for up to ATimeoutMs, then join (WaitFor is
// non-blocking once Finished is true). False means the thread is
// still running at the deadline — the caller must then LEAK the
// thread and everything it can still touch: TThread.Free would block
// on the same hang, and freeing the transport/server under a live
// Run corrupts it.
function BoundedThreadJoin(AThread: TThread; ATimeoutMs: QWord): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + ATimeoutMs;
  while (GetTickCount64 < Deadline) and not AThread.Finished do
    Sleep(25);
  Result := AThread.Finished;
  if Result then
    AThread.WaitFor;
end;

function TRouteFixture.Answer(AParams: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
begin
  Result := TJSONObject.Create;
end;

// Region for the target "tick" alone, so the check must use the value
// the route names.
function TRouteFixture.Headers(const AName: string): TMCPHeaderParameters;
var
  Schema: TJSONObject;
begin
  Result := nil;
  if AName <> 'tick' then
    Exit;
  Schema := TJSONObject(GetJSON('{"type":"object","properties":' +
    '{"region":{"type":"string","x-mcp-header":"Region"}}}'));
  try
    MCPHeaderParameters(Schema, Result);
  finally
    Schema.Free;
  end;
end;

function TickCheck(const AQuery: TMCPEventQuery;
  const ACtx: TMCPRequestContext): TMCPEventPoll;
begin
  Result := MCPEventPoll('now');
end;

var
  // Check calls by the push fixtures (#126), read across threads.
  EndingCalls, EndlessCalls: Integer;

// Opens, then the second call revokes access: the server ends the
// stream with terminated and the final frame.
function EndingCheck(const AQuery: TMCPEventQuery;
  const ACtx: TMCPRequestContext): TMCPEventPoll;
begin
  Inc(EndingCalls);
  if EndingCalls >= 2 then
    raise EMCPProtocolError.Create(-32024, 'Forbidden');
  Result := MCPEventPoll('0', TJSONArray.Create);
  Result.NextPollMs := 50;
  // From a cursor, one non-ASCII occurrence, which the SSE frame must
  // carry byte-exact (#126 review).
  if not AQuery.FromNow then
  begin
    Result.Events.Add(MCPEventOccurrence('u', '2026-11-27T10:00:00Z',
      TJSONObject(MCPParseJSON('{"text":"Gr\u00fc\u00dfe"}'))));
    Result.Cursor := '1';
  end;
end;

var
  WaitingSawStop: Boolean;

// Asks again every 50 ms; its second call waits, up to 3 s, for
// IsCancelled, which Stop turns true (#126 review).
function WaitingCheck(const AQuery: TMCPEventQuery;
  const ACtx: TMCPRequestContext): TMCPEventPoll;
var
  I: Integer;
begin
  if not AQuery.FromNow then
    for I := 1 to 300 do
    begin
      if ACtx.IsCancelled then
      begin
        WaitingSawStop := True;
        Break;
      end;
      Sleep(10);
    end;
  Result := MCPEventPoll('0');
  Result.NextPollMs := 50;
end;

type
  // A stream that writes one frame and ends.
  TOneFrameStream = class(TMCPStream)
  public
    function Step(ASink: TMCPLineSink; ASinkData: Pointer): Int64; override;
    procedure Close(ASink: TMCPLineSink; ASinkData: Pointer); override;
  end;

  // A stream that writes one frame and is not due again for a minute;
  // QuietReleased is 1 once it is destroyed.
  TQuietStream = class(TMCPStream)
  public
    destructor Destroy; override;
    function Step(ASink: TMCPLineSink; ASinkData: Pointer): Int64; override;
    procedure Close(ASink: TMCPLineSink; ASinkData: Pointer); override;
  end;

  // test/parkprogress: reports progress, then parks a one-frame stream;
  // test/parkquiet parks a quiet stream.
  TParkProgress = class
    function Handle(AParams: TJSONObject; const ACtx: TMCPRequestContext;
      ALegacy: Boolean): TJSONObject;
    function Quiet(AParams: TJSONObject; const ACtx: TMCPRequestContext;
      ALegacy: Boolean): TJSONObject;
  end;

var
  QuietReleased: LongInt;

function TOneFrameStream.Step(ASink: TMCPLineSink; ASinkData: Pointer): Int64;
begin
  ASink('{"frame":"stream"}', ASinkData);
  Finish;
  Result := High(Int64);
end;

procedure TOneFrameStream.Close(ASink: TMCPLineSink; ASinkData: Pointer);
begin
  Finish;
end;

destructor TQuietStream.Destroy;
begin
  InterLockedExchange(QuietReleased, 1);
  inherited Destroy;
end;

function TQuietStream.Step(ASink: TMCPLineSink; ASinkData: Pointer): Int64;
begin
  ASink('{"frame":"quiet"}', ASinkData);
  Result := MCPNowMs + 60000;
end;

procedure TQuietStream.Close(ASink: TMCPLineSink; ASinkData: Pointer);
begin
  Finish;
end;

function TParkProgress.Quiet(AParams: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
begin
  TMCPStreamHost(ACtx.StreamHost).Park(TQuietStream.Create(ACtx.RequestId));
  Result := TJSONObject.Create;
end;

function TParkProgress.Handle(AParams: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
begin
  MCPReportProgress(ACtx, 1);
  TMCPStreamHost(ACtx.StreamHost).Park(TOneFrameStream.Create(
    ACtx.RequestId));
  Result := TJSONObject.Create;
end;

var
  ParkProgress: TParkProgress;

type
  // subscriptions/listen's "ticks" key: one notification per stream.
  TOneTickFeed = class(TMCPSubscriptionFeed)
  private
    FSent: Boolean;
  public
    procedure Collect(AOut: TJSONArray); override;
  end;

  TOneTickSource = class(TMCPSubscriptionSource)
  public
    function FilterKey: string; override;
    function Agree(AValue: TJSONData;
      const ACtx: TMCPRequestContext): TJSONData; override;
    function Open(AAgreed: TJSONData;
      const ACtx: TMCPRequestContext): TMCPSubscriptionFeed; override;
  end;

procedure TOneTickFeed.Collect(AOut: TJSONArray);
begin
  if FSent then
    Exit;
  FSent := True;
  AOut.Add(TJSONObject.Create(['method', 'notifications/ticks', 'params',
    TJSONObject.Create(['n', 1])]));
end;

function TOneTickSource.FilterKey: string;
begin
  Result := 'ticks';
end;

function TOneTickSource.Agree(AValue: TJSONData;
  const ACtx: TMCPRequestContext): TJSONData;
begin
  Result := TJSONBoolean.Create(True);
end;

function TOneTickSource.Open(AAgreed: TJSONData;
  const ACtx: TMCPRequestContext): TMCPSubscriptionFeed;
begin
  Result := TOneTickFeed.Create;
end;

type
  // Stops the transport after a delay, from its own thread.
  TStopLater = class(TThread)
  private
    FTransport: TMCPHTTPServer;
    FDelayMs: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(ATransport: TMCPHTTPServer; ADelayMs: Integer);
  end;

constructor TStopLater.Create(ATransport: TMCPHTTPServer; ADelayMs: Integer);
begin
  FTransport := ATransport;
  FDelayMs := ADelayMs;
  inherited Create(False);
end;

procedure TStopLater.Execute;
begin
  Sleep(FDelayMs);
  FTransport.Stop;
end;

// Never ends by itself: asks again every 50 ms.
function EndlessCheck(const AQuery: TMCPEventQuery;
  const ACtx: TMCPRequestContext): TMCPEventPoll;
begin
  Inc(EndlessCalls);
  Result := MCPEventPoll('0');
  Result.NextPollMs := 50;
end;

procedure THTTPBinding.BeforeEach;
var
  Attempt: Integer;
  Probe, ProbeType: string;
begin
  FServer := TMCPServer.Create('http-test', '1.0');
  // The server owns the route fixture, freed with it.
  FRouteFixture := TRouteFixture.Create;
  FServer.Adopt(FRouteFixture);
  FServer.RegisterTool('ping', 'Ping', '{"type":"object"}', PingHandler);
  FServer.RegisterTool('echo', 'Echo',
    ObjectSchema.AddString('message', 'Text to echo'), NoisyEchoHandler);
  FServer.RegisterTool('quiet', 'Quiet', '{"type":"object"}', QuietHandler);
  FServer.RegisterPrompt('hint', 'Hint', PromptArguments.Add('topic'),
    HintPrompt);
  FServer.RegisterPromptCompletion('hint', 'topic', NoisyCompletion);
  FServer.RegisterTool('needs_sampling', 'Needs sampling', '{"type":"object"}',
    NeedsSamplingHandler);
  FServer.RegisterTool('late_refusal', 'Refuses late', '{"type":"object"}',
    ProgressThenRefuseHandler);
  // The same handler, with and without its need declared (#84).
  FServer.RegisterTool('sampler', 'Samples', '{"type":"object"}',
    ProgressThenSamplingHandler).RequiresClientCapability('sampling');
  FServer.RegisterTool('sampler_undeclared', 'Samples', '{"type":"object"}',
    ProgressThenSamplingHandler);
  // Mirrors region (string), opts.limit (integer) and opts.dry
  // (boolean) into Mcp-Param-* headers (#90).
  FServer.RegisterTool('routed', 'Routed',
    '{"type":"object","properties":{' +
    '"region":{"type":"string","x-mcp-header":"Region"},' +
    '"opts":{"type":"object","properties":{' +
    '"limit":{"type":"integer","x-mcp-header":"Limit"},' +
    '"dry":{"type":"boolean","x-mcp-header":"Dry"}}}}}',
    QuietHandler).ApplicationValidated;
  FServer.RegisterTool('waiter', 'Waits', '{"type":"object"}', WaiterHandler);
  // A routed method whose name parameter is "target", with the event
  // types' header lookup (#118 review).
  FServer.RegisterMethod('example/route', FRouteFixture.Answer);
  // An event type whose region is mirrored into Mcp-Param-Region (#118).
  RegisterEvent(FServer, 'tick', 'Ticks',
    TJSONObject(GetJSON('{"type":"object","properties":{"region":' +
    '{"type":"string","x-mcp-header":"Region"}}}')), ObjectSchema.Build,
    TickCheck);
  RegisterEvent(FServer, 'ending', 'Ends', ObjectSchema, ObjectSchema,
    EndingCheck);
  RegisterEvent(FServer, 'endless', 'Never ends', ObjectSchema,
    ObjectSchema, EndlessCheck);
  RegisterEvent(FServer, 'waiting', 'Waits in its check', ObjectSchema,
    ObjectSchema, WaitingCheck);
  FServer.RegisterMethod('test/parkprogress', ParkProgress.Handle);
  FServer.RegisterMethod('test/parkquiet', ParkProgress.Quiet);
  QuietReleased := 0;
  WaitingSawStop := False;
  EndingCalls := 0;
  EndlessCalls := 0;
  FServer.RegisterRoute('example/route', 'target', FRouteFixture.Headers);
  AddSubscriptionSource(FServer, TOneTickSource.Create);
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
  // Bounded teardown: an unbounded WaitFor would hang the whole
  // suite if a regression ever kept Run from returning. On timeout
  // the trio is leaked deliberately (every test binds a fresh port,
  // so later tests still run) and the leak is reported loudly.
  if BoundedThreadJoin(FThread, 5000) then
  begin
    FreeAndNil(FThread);
    FreeAndNil(FTransport);
    FreeAndNil(FServer);
  end
  else
  begin
    WriteLn(ErrOutput, 'WARNING: HTTP transport thread did not stop ',
      'within 5s; leaking thread/transport/server for this test');
    FThread := nil;
    FTransport := nil;
    FServer := nil;
  end;
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

// Sends ARequest as raw bytes to the loopback port and reads to EOF;
// the status code, and the body in ABody. A 5 s socket timeout fails a
// test instead of hanging it.
function RawExchange(APort: Word; const ARequest: string;
  out ABody: string): Integer;
var
  Sock: TInetSocket;
  Response: string;
  Buf: array[0..4095] of Byte;
  Got, HeaderEnd: Integer;
begin
  Sock := TInetSocket.Create('127.0.0.1', APort);
  try
    Sock.IOTimeout := 5000;
    Sock.WriteBuffer(ARequest[1], Length(ARequest));
    Response := '';
    repeat
      Got := Sock.Read(Buf[0], SizeOf(Buf));
      if Got > 0 then
      begin
        SetLength(Response, Length(Response) + Got);
        Move(Buf[0], Response[Length(Response) - Got + 1], Got);
      end;
    until Got <= 0;
  finally
    Sock.Free;
  end;
  // 'HTTP/1.1 NNN ...' — the status code sits at a fixed offset.
  Result := StrToIntDef(Copy(Response, 10, 3), -1);
  HeaderEnd := Pos(#13#10#13#10, Response);
  if HeaderEnd > 0 then
    ABody := Copy(Response, HeaderEnd + 4, MaxInt)
  else
    ABody := '';
end;

// An events/stream POST for event AName, with Mcp-Name unless
// AWithName is false.
function StreamRequest(APort: Word; const AName: string;
  AWithName: Boolean = True; const ACursor: string = ''): string;
var
  Payload: string;
begin
  Payload := '{"jsonrpc":"2.0","id":5,"method":"events/stream","params":{' +
    '"name":"' + AName + '",';
  if ACursor <> '' then
    Payload := Payload + '"cursor":"' + ACursor + '",';
  Payload := Payload + META_MODERN + '}}';
  Result := 'POST /mcp HTTP/1.1'#13#10 +
    'Host: 127.0.0.1:' + IntToStr(APort) + #13#10 +
    'Content-Type: application/json'#13#10 +
    'Accept: application/json, text/event-stream'#13#10 +
    'MCP-Protocol-Version: ' + MCP_PROTOCOL_VERSION + #13#10 +
    'Mcp-Method: events/stream'#13#10;
  if AWithName then
    Result := Result + 'Mcp-Name: ' + AName + #13#10;
  Result := Result + 'Connection: close'#13#10 +
    'Content-Length: ' + IntToStr(Length(Payload)) + #13#10#13#10 + Payload;
end;

// Sends ARequest and reads until the first SSE frame is complete, then
// keeps the connection open for AHoldMs and closes it: what the
// response held by then.
function ReadFirstFrameThenClose(APort: Word; const ARequest: string;
  AHoldMs: Integer = 0): string;
var
  Sock: TInetSocket;
  Buf: array[0..4095] of Byte;
  Got, HeaderEnd: Integer;
begin
  Result := '';
  Sock := TInetSocket.Create('127.0.0.1', APort);
  try
    Sock.IOTimeout := 5000;
    Sock.WriteBuffer(ARequest[1], Length(ARequest));
    repeat
      Got := Sock.Read(Buf[0], SizeOf(Buf));
      if Got > 0 then
      begin
        SetLength(Result, Length(Result) + Got);
        Move(Buf[0], Result[Length(Result) - Got + 1], Got);
      end;
      HeaderEnd := Pos(#13#10#13#10, Result);
    until (Got <= 0) or ((HeaderEnd > 0) and
      (Pos(#10#10, Copy(Result, HeaderEnd + 4, MaxInt)) > 0));
    Sleep(AHoldMs);
  finally
    Sock.Free;
  end;
end;

function THTTPBinding.PostRoutedRaw(const AArguments,
  AExtraHeaderLines: string; out ABody: string): Integer;
var
  Payload, Request: string;
begin
  Payload := '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{' +
    '"name":"routed","arguments":' + AArguments + ',' + META_MODERN + '}}';
  Request := 'POST /mcp HTTP/1.1'#13#10 +
    'Host: 127.0.0.1:' + IntToStr(FTransport.Port) + #13#10 +
    'Content-Type: application/json'#13#10 +
    'Accept: application/json, text/event-stream'#13#10 +
    'MCP-Protocol-Version: ' + MCP_PROTOCOL_VERSION + #13#10 +
    'Mcp-Method: tools/call'#13#10 + 'Mcp-Name: routed'#13#10 +
    AExtraHeaderLines + #13#10 +
    'Connection: close'#13#10 +
    'Content-Length: ' + IntToStr(Length(Payload)) + #13#10#13#10 + Payload;
  Result := RawExchange(FTransport.Port, Request, ABody);
end;

function THTTPBinding.PostWithUnsentBody(ADeclaredLength: Integer;
  out AResponseBody: string): Integer;
begin
  // A hang here would be a close-contract regression; RawExchange's
  // socket timeout fails the test instead of wedging the suite.
  Result := RawExchange(FTransport.Port, 'POST /mcp HTTP/1.1'#13#10 +
    'Host: 127.0.0.1:' + IntToStr(FTransport.Port) + #13#10 +
    'Content-Type: application/json'#13#10 +
    'Content-Length: ' + IntToStr(ADeclaredLength) + #13#10#13#10,
    AResponseBody);
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

procedure THTTPBinding.TestHandlerRaisedMissingCapability400;
var
  Body: string;
  Status: Integer;
begin
  // The status follows the code wherever the core decided it, so a
  // handler-raised -32021 answers 400 like the library's own (spec
  // verified 2026-11-26:
  // https://modelcontextprotocol.io/specification/2026-07-28/basic/index#_meta).
  Status := Post(CallLine(1, 'needs_sampling'), 'tools/call',
    'needs_sampling', Body);
  Expect<Integer>(Status).ToBe(400);
  Expect<Integer>(ErrorCodeOf(Body)).ToBe(-32021);
end;

procedure THTTPBinding.TestRefusalAfterProgressEndsTheStream;
var
  Body, ContentType: string;
  Status: Integer;
begin
  // Once progress has opened the stream the status is 200 for good:
  // the error is its last event. This is the late fallback, not the
  // spec's 400: a handler (or, with #84, a declared capability) checks
  // before its first notification to get the 400.
  Status := Exchange('POST', '/mcp',
    CallLine(3, 'late_refusal', META_MODERN_STREAMING),
    [HeaderPair('MCP-Protocol-Version', MCP_PROTOCOL_VERSION),
     HeaderPair('Mcp-Method', 'tools/call'),
     HeaderPair('Mcp-Name', 'late_refusal')], Body, ContentType);
  Expect<Integer>(Status).ToBe(200);
  Expect<string>(ContentType).ToBe('text/event-stream');
  // Ordered frames: the progress event, then the error as the final,
  // terminated event.
  Expect<Boolean>(ProgressThenFinalRefusal(Body)).ToBe(True);
end;

procedure THTTPBinding.TestBareDiscoverProbe;
var
  Body, ContentType: string;
  Status: Integer;
begin
  // Malformed-input coverage: a body carrying no _meta envelope and no
  // mirrored headers is not rejected by the transport with a
  // misleading -32020 header mismatch: header validation keys on the
  // envelope claim, so the request reaches the core (see the unit
  // header). server/discover still carries _meta like every request (spec
  // verified 2026-08-08:
  // https://modelcontextprotocol.io/specification/2026-07-28/server/discover),
  // so the core answers the accurate -32602 for the missing _meta
  // rather than the transport masking it as a header error. A request
  // missing a required field is malformed, which HTTP answers 400
  // (#79; spec verified 2026-11-26:
  // https://modelcontextprotocol.io/specification/2026-07-28/basic/index#_meta).
  Status := Exchange('POST', '/mcp',
    '{"jsonrpc":"2.0","id":0,"method":"server/discover","params":{}}',
    [], Body, ContentType);
  Expect<Integer>(Status).ToBe(400);
  Expect<Integer>(ErrorCodeOf(Body)).ToBe(-32602);
end;

// Missing required _meta fields → -32602 and 400; other -32602s stay
// 200 (#79, spec verified 2026-11-26:
// https://modelcontextprotocol.io/specification/2026-07-28/basic/index#_meta).
procedure THTTPBinding.TestMissingProtocolVersion400;
var
  Body, ContentType: string;
  Status: Integer;
begin
  // No protocolVersion claim, so no header check applies; the core's
  // -32602 is the malformed-request rejection.
  Status := Exchange('POST', '/mcp',
    '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":' +
    '{"io.modelcontextprotocol/clientCapabilities":{}}}}',
    [HeaderPair('Mcp-Method', 'tools/list')], Body, ContentType);
  Expect<Integer>(Status).ToBe(400);
  Expect<Integer>(ErrorCodeOf(Body)).ToBe(-32602);
  Expect<Boolean>(Pos('protocolVersion', Body) > 0).ToBe(True);
end;

procedure THTTPBinding.TestMissingClientCapabilities400;
var
  Body: string;
  Status: Integer;
begin
  Status := Post('{"jsonrpc":"2.0","id":1,"method":"tools/list","params":' +
    '{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}',
    'tools/list', '', Body);
  Expect<Integer>(Status).ToBe(400);
  Expect<Integer>(ErrorCodeOf(Body)).ToBe(-32602);
  Expect<Boolean>(Pos('clientCapabilities', Body) > 0).ToBe(True);
end;

procedure THTTPBinding.TestStreamingOptInMissingCapabilities400;
var
  Body, ContentType: string;
  Status: Integer;
begin
  // A tools/call that opted into progress but lacks clientCapabilities
  // takes the streaming path, whose fallback must map the status too.
  Status := Exchange('POST', '/mcp',
    '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{' +
    '"name":"echo","arguments":{"message":"hi"},"_meta":{' +
    '"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"progressToken":7}}}',
    [HeaderPair('MCP-Protocol-Version', MCP_PROTOCOL_VERSION),
     HeaderPair('Mcp-Method', 'tools/call'), HeaderPair('Mcp-Name', 'echo')],
    Body, ContentType);
  Expect<Integer>(Status).ToBe(400);
  Expect<string>(ContentType).ToBe('application/json');
  Expect<Integer>(ErrorCodeOf(Body)).ToBe(-32602);
end;

procedure THTTPBinding.TestInBandInvalidParamsStays200;
var
  Body: string;
  Status: Integer;
begin
  // A complete envelope with an unknown tool: -32602 again, but an
  // ordinary invalid-params answer, so the status stays 200.
  Status := Post(CallLine(1, 'nope'), 'tools/call', 'nope', Body);
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

// A tools/call of 'routed' with AArguments and the extra headers. The
// Mcp-Param tests below follow "Custom Headers from Tool Parameters"
// and "Server Validation", verified 2026-11-26 against
// https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http#custom-headers-from-tool-parameters
function THTTPBinding.PostRouted(const AArguments: string;
  const AHeaders: array of THeaderPair; out ABody: string): Integer;
var
  Headers: array of THeaderPair;
  ContentType: string;
  I: Integer;
begin
  Headers := [HeaderPair('MCP-Protocol-Version', MCP_PROTOCOL_VERSION),
    HeaderPair('Mcp-Method', 'tools/call'), HeaderPair('Mcp-Name', 'routed')];
  for I := 0 to High(AHeaders) do
    Headers := Concat(Headers, [AHeaders[I]]);
  Result := Exchange('POST', '/mcp', '{"jsonrpc":"2.0","id":4,' +
    '"method":"tools/call","params":{"name":"routed","arguments":' +
    AArguments + ',' + META_MODERN + '}}', Headers, ABody, ContentType);
end;

procedure THTTPBinding.TestParamHeadersMatch;
var
  Body: string;
begin
  // Plain values, nested properties, all three types.
  Expect<Integer>(PostRouted('{"region":"us-west1","opts":{"limit":42,' +
    '"dry":true}}', [HeaderPair('Mcp-Param-Region', 'us-west1'),
    HeaderPair('Mcp-Param-Limit', '42'), HeaderPair('Mcp-Param-Dry', 'true')],
    Body)).ToBe(200);
  Expect<Boolean>(Pos('quiet', Body) > 0).ToBe(True);
  // Header names compare case-insensitively; a non-ASCII value travels
  // base64-encoded ('Hello, 世界', the spec's own example).
  Expect<Integer>(PostRouted('{"region":"Hello, ' + #$E4#$B8#$96#$E7#$95#$8C +
    '"}', [HeaderPair('mcp-param-region', '=?base64?SGVsbG8sIOS4lueVjA==?=')],
    Body)).ToBe(200);
end;

// events/poll carries Mcp-Name (params.name) and the Mcp-Param-*
// headers of its input schema, checked as for tools/call; events/list
// carries no name (events.mdx, Streamable HTTP: Routing Headers,
// verified 2026-11-27).
function THTTPBinding.PostPoll(const AName, AParamsJson: string;
  const AHeaders: array of THeaderPair; out ABody: string): Integer;
var
  Headers: array of THeaderPair;
  ContentType: string;
  I: Integer;
begin
  Headers := [HeaderPair('MCP-Protocol-Version', MCP_PROTOCOL_VERSION),
    HeaderPair('Mcp-Method', 'events/poll')];
  if AName <> '' then
    Headers := Concat(Headers, [HeaderPair('Mcp-Name', AName)]);
  for I := 0 to High(AHeaders) do
    Headers := Concat(Headers, [AHeaders[I]]);
  Result := Exchange('POST', '/mcp', '{"jsonrpc":"2.0","id":5,' +
    '"method":"events/poll","params":{' + AParamsJson + META_MODERN + '}}',
    Headers, ABody, ContentType);
end;

procedure THTTPBinding.TestEventRouting;
var
  Body, ContentType: string;
begin
  Expect<Integer>(PostPoll('tick', '"name":"tick","arguments":' +
    '{"region":"eu"},', [HeaderPair('Mcp-Param-Region', 'eu')], Body))
    .ToBe(200);
  Expect<Boolean>(Pos('"cursor" : "now"', Body) > 0).ToBe(True);
  Expect<Integer>(PostPoll('', '"name":"tick",', [], Body)).ToBe(400);
  Expect<Integer>(ErrorCodeOf(Body)).ToBe(-32020);
  Expect<Boolean>(Pos('required Mcp-Name header is missing', Body) > 0)
    .ToBe(True);
  Expect<Integer>(PostPoll('tock', '"name":"tick",', [], Body)).ToBe(400);
  Expect<Integer>(PostPoll('tick', '"name":"tick","arguments":' +
    '{"region":"eu"},', [], Body)).ToBe(400);
  Expect<Boolean>(Pos('Mcp-Param-Region header is missing', Body) > 0)
    .ToBe(True);
  Expect<Integer>(Post('{"jsonrpc":"2.0","id":6,"method":"events/list",' +
    '"params":{' + META_MODERN + '}}', 'events/list', '', Body)).ToBe(200);
  // A route whose name parameter is not "name" still checks the
  // headers of the value it names (#118 review).
  Expect<Integer>(Exchange('POST', '/mcp', '{"jsonrpc":"2.0","id":7,' +
    '"method":"example/route","params":{"target":"tick","arguments":' +
    '{"region":"eu"},' + META_MODERN + '}}', [HeaderPair('MCP-Protocol-Version',
    MCP_PROTOCOL_VERSION), HeaderPair('Mcp-Method', 'example/route'),
    HeaderPair('Mcp-Name', 'tick')], Body, ContentType)).ToBe(400);
  Expect<Boolean>(Pos('Mcp-Param-Region header is missing', Body) > 0)
    .ToBe(True);
  // A name that is not plain ASCII travels base64-encoded; raw bytes are
  // refused (#118 review). 'tick' as a sentinel matches.
  Expect<Integer>(PostPoll('=?base64?dGljaw==?=', '"name":"tick",', [], Body))
    .ToBe(200);
  Expect<Integer>(PostPoll('ti' + #$C3#$A9 + 'ck', '"name":"tick",', [], Body))
    .ToBe(400);
  Expect<Boolean>(Pos('not plain ASCII', Body) > 0).ToBe(True);
  // Core methods keep their behaviour: a raw name that matches the body
  // passes the header check (the tool is then unknown).
  Expect<Integer>(Exchange('POST', '/mcp', '{"jsonrpc":"2.0","id":8,' +
    '"method":"tools/call","params":{"name":"ti' + #$C3#$A9 + 'ck",' +
    '"arguments":{},' + META_MODERN + '}}', [HeaderPair('MCP-Protocol-Version',
    MCP_PROTOCOL_VERSION), HeaderPair('Mcp-Method', 'tools/call'),
    HeaderPair('Mcp-Name', 'ti' + #$C3#$A9 + 'ck')], Body, ContentType))
    .ToBe(200);
  // A routed method's Mcp-Name must arrive once (#118 review).
  Expect<Integer>(PostPollRaw('Mcp-Name: tock'#13#10'Mcp-Name: tick', Body))
    .ToBe(400);
  Expect<Integer>(ErrorCodeOf(Body)).ToBe(-32020);
  Expect<Boolean>(Pos('Mcp-Name header sent more than once', Body) > 0)
    .ToBe(True);
  Expect<Integer>(PostPollRaw('Mcp-Name: tick', Body)).ToBe(200);
end;

// events/poll for "tick" with the raw header lines AHeaderLines, so a
// field can repeat.
function THTTPBinding.PostPollRaw(const AHeaderLines: string;
  out ABody: string): Integer;
var
  Payload, Request: string;
begin
  Payload := '{"jsonrpc":"2.0","id":9,"method":"events/poll","params":{' +
    '"name":"tick",' + META_MODERN + '}}';
  Request := 'POST /mcp HTTP/1.1'#13#10 +
    'Host: 127.0.0.1:' + IntToStr(FTransport.Port) + #13#10 +
    'Content-Type: application/json'#13#10 +
    'Accept: application/json, text/event-stream'#13#10 +
    'MCP-Protocol-Version: ' + MCP_PROTOCOL_VERSION + #13#10 +
    'Mcp-Method: events/poll'#13#10 + AHeaderLines + #13#10 +
    'Connection: close'#13#10 +
    'Content-Length: ' + IntToStr(Length(Payload)) + #13#10#13#10 + Payload;
  Result := RawExchange(FTransport.Port, Request, ABody);
end;

// subscriptions/listen answers an SSE stream (#138): the
// acknowledgment first, the notification, and on Stop the completion
// result with the subscription id (Graceful Closure).
procedure THTTPBinding.TestListenStream;
var
  Payload, Body: string;
  Stopper: TStopLater;
begin
  Payload := '{"jsonrpc":"2.0","id":8,"method":"subscriptions/listen",' +
    '"params":{"notifications":{"ticks":true,"toolsListChanged":true},' +
    META_MODERN + '}}';
  Stopper := TStopLater.Create(FTransport, 400);
  try
    Expect<Integer>(RawExchange(FTransport.Port, 'POST /mcp HTTP/1.1'#13#10 +
      'Host: 127.0.0.1:' + IntToStr(FTransport.Port) + #13#10 +
      'Content-Type: application/json'#13#10 +
      'Accept: application/json, text/event-stream'#13#10 +
      'MCP-Protocol-Version: ' + MCP_PROTOCOL_VERSION + #13#10 +
      'Mcp-Method: subscriptions/listen'#13#10 +
      'Connection: close'#13#10 +
      'Content-Length: ' + IntToStr(Length(Payload)) + #13#10#13#10 + Payload,
      Body)).ToBe(200);
  finally
    Stopper.WaitFor;
    Stopper.Free;
  end;
  Expect<Integer>(Pos('data: { "jsonrpc" : "2.0", "method" : ' +
    '"notifications/subscriptions/acknowledged", "params" : { ' +
    '"notifications" : { "ticks" : true }, "_meta" : { ' +
    '"io.modelcontextprotocol/subscriptionId" : 8 } } }', Body)).ToBe(1);
  Expect<Boolean>(Pos('data: { "jsonrpc" : "2.0", "method" : ' +
    '"notifications/ticks", "params" : { "n" : 1, "_meta" : { ' +
    '"io.modelcontextprotocol/subscriptionId" : 8 } } }', Body) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('data: { "jsonrpc" : "2.0", "id" : 8, "result" : ' +
    '{ "resultType" : "complete", "_meta" : { ' +
    '"io.modelcontextprotocol/subscriptionId" : 8 } } }', Body) > 0)
    .ToBe(True);
end;

// events/stream answers with an SSE stream at once (events.mdx,
// Push-Based Delivery): active first, and when the server ends the
// subscription, terminated and the final frame, then the close.
procedure THTTPBinding.TestEventStream;
var
  Body: string;
begin
  Expect<Integer>(RawExchange(FTransport.Port, StreamRequest(
    FTransport.Port, 'ending'), Body)).ToBe(200);
  Expect<Integer>(Pos('data: { "jsonrpc" : "2.0", "method" : ' +
    '"notifications/events/active"', Body)).ToBe(1);
  Expect<Boolean>(Pos('data: { "jsonrpc" : "2.0", "method" : ' +
    '"notifications/events/terminated", "params" : { "error" : { "code" : ' +
    '-32024', Body) > 0).ToBe(True);
  Expect<Boolean>(Pos('data: { "jsonrpc" : "2.0", "id" : 5, "result" : ' +
    '{ "resultType" : "complete"', Body) > 0).ToBe(True);
  Expect<Integer>(EndingCalls).ToBe(2);
  // From a cursor, the non-ASCII occurrence, its UTF-8 bytes as sent.
  EndingCalls := 0;
  Expect<Integer>(RawExchange(FTransport.Port, StreamRequest(
    FTransport.Port, 'ending', True, '0'), Body)).ToBe(200);
  Expect<Boolean>(Pos('"text" : "Gr' + #$C3#$BC#$C3#$9F + 'e"', Body) > 0)
    .ToBe(True);
  // Mcp-Name is required on events/stream as on events/poll.
  Expect<Integer>(RawExchange(FTransport.Port, StreamRequest(
    FTransport.Port, 'ending', False), Body)).ToBe(400);
  Expect<Integer>(ErrorCodeOf(Body)).ToBe(-32020);
end;

// Stop reaches a check that waits: it returns, and the client, still
// reading, gets the final frame (#126 review).
procedure THTTPBinding.TestStopDuringACheck;
var
  Body: string;
  Stopper: TStopLater;
begin
  Stopper := TStopLater.Create(FTransport, 300);
  try
    // From now: the stream's own second check is the one that waits.
    Expect<Integer>(RawExchange(FTransport.Port, StreamRequest(
      FTransport.Port, 'waiting'), Body)).ToBe(200);
  finally
    Stopper.WaitFor;
    Stopper.Free;
  end;
  Expect<Boolean>(WaitingSawStop).ToBe(True);
  Expect<Boolean>(Pos('data: { "jsonrpc" : "2.0", "id" : 5, "result" : ' +
    '{ "resultType" : "complete"', Body) > 0).ToBe(True);
end;

// Stop reaches the opening check too, inside the request (#126
// review).
procedure THTTPBinding.TestStopDuringTheOpeningCheck;
var
  Body: string;
  Stopper: TStopLater;
begin
  Stopper := TStopLater.Create(FTransport, 300);
  try
    Expect<Integer>(RawExchange(FTransport.Port, StreamRequest(
      FTransport.Port, 'waiting', True, '0'), Body)).ToBe(200);
  finally
    Stopper.WaitFor;
    Stopper.Free;
  end;
  Expect<Boolean>(WaitingSawStop).ToBe(True);
end;

// A handler whose progress opened the SSE response, and that then parks
// a stream, gets the stream on that response, not its placeholder
// result (#126 review).
procedure THTTPBinding.TestProgressThenPark;
var
  Body, ContentType: string;
begin
  Expect<Integer>(Exchange('POST', '/mcp', '{"jsonrpc":"2.0","id":6,' +
    '"method":"test/parkprogress","params":{"_meta":{' +
    '"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{},"progressToken":"t"}}}',
    [HeaderPair('MCP-Protocol-Version', MCP_PROTOCOL_VERSION),
    HeaderPair('Mcp-Method', 'test/parkprogress')], Body, ContentType))
    .ToBe(200);
  Expect<Boolean>(Pos('notifications/progress', Body) > 0).ToBe(True);
  Expect<Boolean>(Pos('{"frame":"stream"}', Body) > 0).ToBe(True);
  Expect<Integer>(Pos('"result"', Body)).ToBe(0);
end;

// A client that closes the connection cancels its stream (events.mdx,
// Lifecycle): the server stops calling the check.
procedure THTTPBinding.TestEventStreamClientClose;
var
  Response: string;
  Calls: Integer;
begin
  Response := ReadFirstFrameThenClose(FTransport.Port, StreamRequest(
    FTransport.Port, 'endless'));
  Expect<Boolean>(Pos('Content-Type: text/event-stream', Response) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('notifications/events/active', Response) > 0)
    .ToBe(True);
  // The close is seen within 50 ms, a check runs every 50 ms.
  Sleep(400);
  Calls := EndlessCalls;
  Sleep(400);
  Expect<Integer>(EndlessCalls).ToBe(Calls);
end;

// A client that closes the connection ends a stream that is not due
// for a minute within the disconnect poll's interval: the wait between
// steps is capped by the poll, which runs on the streams' clock (#134
// review). The client holds the connection open for 200 ms after the
// first frame, so the poll's first probe, right after that frame, finds
// it open and the stream is waiting when the client closes.
procedure THTTPBinding.TestQuietStreamClientClose;
var
  Payload, Response: string;
  Waited: Integer;
begin
  Payload := '{"jsonrpc":"2.0","id":5,"method":"test/parkquiet",' +
    '"params":{' + META_MODERN + '}}';
  Response := ReadFirstFrameThenClose(FTransport.Port,
    'POST /mcp HTTP/1.1'#13#10 + 'Host: 127.0.0.1:' +
    IntToStr(FTransport.Port) + #13#10 +
    'Content-Type: application/json'#13#10 +
    'Accept: application/json, text/event-stream'#13#10 +
    'MCP-Protocol-Version: ' + MCP_PROTOCOL_VERSION + #13#10 +
    'Mcp-Method: test/parkquiet'#13#10 + 'Connection: close'#13#10 +
    'Content-Length: ' + IntToStr(Length(Payload)) + #13#10#13#10 + Payload,
    200);
  Expect<Boolean>(Pos('{"frame":"quiet"}', Response) > 0).ToBe(True);
  Waited := 0;
  while (QuietReleased = 0) and (Waited < 3000) do
  begin
    Sleep(10);
    Inc(Waited, 10);
  end;
  Expect<Integer>(QuietReleased).ToBe(1);
end;

procedure THTTPBinding.TestParamHeaderMissing;
var
  Body: string;
begin
  Expect<Integer>(PostRouted('{"region":"eu"}', [], Body)).ToBe(400);
  Expect<Integer>(ErrorCodeOf(Body)).ToBe(-32020);
  Expect<Boolean>(Pos('Mcp-Param-Region header is missing', Body) > 0)
    .ToBe(True);
end;

procedure THTTPBinding.TestParamHeaderMismatch;
var
  Body: string;
begin
  Expect<Integer>(PostRouted('{"region":"eu"}',
    [HeaderPair('Mcp-Param-Region', 'us')], Body)).ToBe(400);
  Expect<Integer>(ErrorCodeOf(Body)).ToBe(-32020);
  Expect<Integer>(PostRouted('{"opts":{"dry":false}}',
    [HeaderPair('Mcp-Param-Dry', 'False')], Body)).ToBe(400);
  // A base64 value that decodes to something else.
  Expect<Integer>(PostRouted('{"region":"eu"}',
    [HeaderPair('Mcp-Param-Region', '=?base64?dXM=?=')], Body)).ToBe(400);
end;

procedure THTTPBinding.TestParamHeaderBadBase64;
var
  Body: string;
begin
  // Missing padding and a character outside the alphabet: both
  // rejected (SEP-2243 test table), not decoded leniently.
  Expect<Integer>(PostRouted('{"region":"Hello"}',
    [HeaderPair('Mcp-Param-Region', '=?base64?SGVsbG8?=')], Body)).ToBe(400);
  Expect<Integer>(ErrorCodeOf(Body)).ToBe(-32020);
  // A foreign character in a payload of whole 4-character groups, which
  // a lenient decoder would skip to "Hello": only the alphabet check
  // refuses it.
  Expect<Integer>(PostRouted('{"region":"Hello"}',
    [HeaderPair('Mcp-Param-Region', '=?base64?SGVsbG8!?=')], Body)).ToBe(400);
  Expect<Integer>(ErrorCodeOf(Body)).ToBe(-32020);
  Expect<Boolean>(Pos('is not valid base64', Body) > 0).ToBe(True);
  // Without the full sentinel the value is literal.
  Expect<Integer>(PostRouted('{"region":"SGVsbG8="}',
    [HeaderPair('Mcp-Param-Region', 'SGVsbG8=')], Body)).ToBe(200);
end;

procedure THTTPBinding.TestParamHeaderUnencodedNonASCII;
var
  Body: string;
begin
  Expect<Integer>(PostRouted('{"region":"' + #$C3#$A9 + '"}',
    [HeaderPair('Mcp-Param-Region', #$C3#$A9)], Body)).ToBe(400);
  Expect<Integer>(ErrorCodeOf(Body)).ToBe(-32020);
end;

// Presence, not value (#90 review): an empty field is the empty
// string's header, the empty base64 payload decodes to it, an empty
// field for an absent argument is a mismatch, and a repeated field is
// refused. Verified 2026-11-27 against
// https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http#server-validation
procedure THTTPBinding.TestParamHeaderEmptyAndRepeated;
var
  Body: string;
begin
  Expect<Integer>(PostRouted('{"region":""}',
    [HeaderPair('Mcp-Param-Region', '')], Body)).ToBe(200);
  Expect<Integer>(PostRouted('{"region":""}',
    [HeaderPair('Mcp-Param-Region', '=?base64??=')], Body)).ToBe(200);
  Expect<Integer>(PostRouted('{}', [HeaderPair('Mcp-Param-Region', '')],
    Body)).ToBe(400);
  Expect<Integer>(PostRoutedRaw('{"region":"eu"}',
    'Mcp-Param-Region: us'#13#10'Mcp-Param-Region: eu', Body)).ToBe(400);
  Expect<Integer>(ErrorCodeOf(Body)).ToBe(-32020);
  Expect<Boolean>(Pos('sent more than once', Body) > 0).ToBe(True);
  Expect<Integer>(PostRoutedRaw('{"region":"eu"}', 'Mcp-Param-Region: eu',
    Body)).ToBe(200);
  // Names match in ASCII case for presence and value alike (an I/i pair
  // compares by the locale in fcl-web's own lookup, e.g. under tr_TR).
  Expect<Integer>(PostRoutedRaw('{"opts":{"limit":3}}',
    'MCP-PARAM-LIMIT: 3', Body)).ToBe(200);
  Expect<Integer>(PostRoutedRaw('{"opts":{"limit":3}}',
    'mcp-param-limit: 3'#13#10'MCP-PARAM-LIMIT: 3', Body)).ToBe(400);
end;

// Integers compare numerically within the JavaScript safe range;
// composites and values of another type have no header form.
procedure THTTPBinding.TestParamHeaderIntegers;
var
  Body: string;
begin
  Expect<Integer>(PostRouted('{"opts":{"limit":42.0}}',
    [HeaderPair('Mcp-Param-Limit', '42')], Body)).ToBe(200);
  Expect<Integer>(PostRouted('{"opts":{"limit":42}}',
    [HeaderPair('Mcp-Param-Limit', '42.0')], Body)).ToBe(200);
  Expect<Integer>(PostRouted('{"opts":{"limit":-7}}',
    [HeaderPair('Mcp-Param-Limit', '-7')], Body)).ToBe(200);
  Expect<Integer>(PostRouted('{"opts":{"limit":42}}',
    [HeaderPair('Mcp-Param-Limit', '+42')], Body)).ToBe(400);
  Expect<Integer>(PostRouted('{"opts":{"limit":9007199254740992}}',
    [HeaderPair('Mcp-Param-Limit', '9007199254740992')], Body)).ToBe(400);
  Expect<Integer>(PostRouted('{"opts":{"limit":"42"}}',
    [HeaderPair('Mcp-Param-Limit', '42')], Body)).ToBe(400);
  Expect<Integer>(PostRouted('{"region":["eu"]}',
    [HeaderPair('Mcp-Param-Region', '["eu"]')], Body)).ToBe(400);
end;

// Mcp-Name decodes strictly too since #90: an unpadded payload, which
// the lenient decoder used to take, is refused.
procedure THTTPBinding.TestMcpNameStrictBase64;
var
  Body, ContentType: string;
  Line: string;
begin
  Line := '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{' +
    '"name":"quiet",' + META_MODERN + '}}';
  Expect<Integer>(Exchange('POST', '/mcp', Line,
    [HeaderPair('MCP-Protocol-Version', MCP_PROTOCOL_VERSION),
    HeaderPair('Mcp-Method', 'tools/call'),
    HeaderPair('Mcp-Name', '=?base64?cXVpZXQ=?=')], Body, ContentType))
    .ToBe(200);
  Expect<Integer>(Exchange('POST', '/mcp', Line,
    [HeaderPair('MCP-Protocol-Version', MCP_PROTOCOL_VERSION),
    HeaderPair('Mcp-Method', 'tools/call'),
    HeaderPair('Mcp-Name', '=?base64?cXVpZXQ?=')], Body, ContentType))
    .ToBe(400);
end;

procedure THTTPBinding.TestParamHeaderWithoutValue;
var
  Body: string;
begin
  // Absent or null in the body: no header expected...
  Expect<Integer>(PostRouted('{"region":null}', [], Body)).ToBe(200);
  // ...and one that is sent anyway does not match.
  Expect<Integer>(PostRouted('{}', [HeaderPair('Mcp-Param-Region', 'eu')],
    Body)).ToBe(400);
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

procedure THTTPBinding.ExpectOriginStatus(const AOrigin: string;
  AExpectedStatus: Integer);
var
  Body, ContentType: string;
  Status: Integer;
begin
  Status := Exchange('POST', '/mcp', CallLine(1, 'ping'),
    [HeaderPair('Origin', AOrigin),
     HeaderPair('MCP-Protocol-Version', MCP_PROTOCOL_VERSION),
     HeaderPair('Mcp-Method', 'tools/call'),
     HeaderPair('Mcp-Name', 'ping')], Body, ContentType);
  Expect<Integer>(Status).ToBe(AExpectedStatus);
end;

procedure THTTPBinding.TestForeignOriginRejected;
begin
  ExpectOriginStatus('https://evil.example', 403);
end;

procedure THTTPBinding.TestLocalhostOriginAccepted;
begin
  ExpectOriginStatus('http://localhost:5173', 200);
end;

procedure THTTPBinding.TestIPv6LoopbackOriginAccepted;
begin
  ExpectOriginStatus('http://[::1]:8080', 200);
end;

procedure THTTPBinding.TestIPv6PrefixedOriginRejected;
begin
  // The bracketed loopback literal is the whole host or nothing: a
  // foreign host that merely starts with it is not localhost.
  ExpectOriginStatus('http://[::1].attacker.example', 403);
end;

procedure THTTPBinding.TestIPv6SuffixedOriginRejected;
begin
  ExpectOriginStatus('http://[::1]evil', 403);
end;

procedure THTTPBinding.TestUserinfoOriginRejected;
begin
  // Userinfo would make 'localhost' the credentials and the foreign
  // host the target; a serialized origin never carries it.
  ExpectOriginStatus('http://localhost:99@evil.example', 403);
end;

procedure THTTPBinding.TestNonWebSchemeOriginRejected;
begin
  // The loopback allowlist is for web origins only: a non-http(s)
  // scheme in front of a loopback host must not slip through, or
  // 'weird://localhost' would inherit localhost's trust.
  ExpectOriginStatus('weird://localhost', 403);
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
  // Headers-only on purpose: see PostWithUnsentBody. Sending the
  // over-cap body too made this assertion a kernel-timing race
  // (~0.5% loss of the buffered 413 to the server's RST, measured
  // 2026-08-09 at 2/400 vs 0/400 headers-only on Darwin).
  Status := PostWithUnsentBody(308, Body);
  Expect<Integer>(Status).ToBe(413);
  Expect<Integer>(ErrorCodeOf(Body)).ToBe(-32700);
end;

// completion/complete has no Mcp-Name, yet its callback can notify: an
// opted-in request streams like the handler-backed methods. Header and
// SSE rules verified 2026-11-26 against
// https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http
procedure THTTPBinding.TestCompletionStreams;
var
  Body, ContentType: string;
begin
  Expect<Integer>(Exchange('POST', '/mcp',
    '{"jsonrpc":"2.0","id":5,"method":"completion/complete","params":{' +
    '"ref":{"type":"ref/prompt","name":"hint"},"argument":{"name":"topic",' +
    '"value":"a"},' + META_MODERN_STREAMING + '}}',
    [HeaderPair('MCP-Protocol-Version', MCP_PROTOCOL_VERSION),
     HeaderPair('Mcp-Method', 'completion/complete')], Body, ContentType))
    .ToBe(200);
  Expect<string>(ContentType).ToBe('text/event-stream');
  Expect<Boolean>(Pos('notifications/progress', Body) > 0).ToBe(True);
  Expect<Boolean>(Pos('"values" : ["alpha"]', Body) > 0).ToBe(True);
end;

procedure THTTPBinding.TestSSEStream;
var
  Body, ContentType, LastEvent: string;
  Status, EventCount: Integer;
  Events: TStringArray;
begin
  Status := Exchange('POST', '/mcp',
    CallLine(3, 'echo', META_MODERN_STREAMING),
    [HeaderPair('MCP-Protocol-Version', MCP_PROTOCOL_VERSION),
     HeaderPair('Mcp-Method', 'tools/call'),
     HeaderPair('Mcp-Name', 'echo')], Body, ContentType);
  Expect<Integer>(Status).ToBe(200);
  Expect<string>(ContentType).ToBe('text/event-stream');

  // Split the stream into data: events.
  Expect<Boolean>(SplitSSEEvents(Body, Events)).ToBe(True);
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
  Thread: TServerThread;
  Finished: Boolean;
begin
  // Stop before Run: the transport stays stopped and Run returns
  // promptly. Run executes on a worker thread so a regression here
  // cannot block the suite inline — the bounded join keeps the
  // assertion reachable either way.
  Server := TMCPServer.Create('stop-test', '1.0');
  Transport := TMCPHTTPServer.Create(Server);
  Transport.Port := FindFreePort;
  Transport.Stop;
  Thread := TServerThread.CreateFor(Transport);
  Finished := BoundedThreadJoin(Thread, 2000);
  Expect<Boolean>(Finished).ToBe(True);
  if Finished then
  begin
    Thread.Free;
    Transport.Free;
    Server.Free;
  end
  else
    // Run is still blocking: freeing anything it touches (or the
    // thread itself — TThread.Free joins) would hang or corrupt the
    // suite. Leak the trio; the failed expectation reports the bug.
    WriteLn(ErrOutput, 'WARNING: Run did not return after early Stop; ',
      'leaking thread/transport/server');
end;

procedure THTTPBinding.TestStopDuringStartupReturns;
var
  Server: TMCPServer;
  Transport: TMCPHTTPServer;
  Thread: TServerThread;
  Finished: Boolean;
begin
  // Stop racing the listener's startup: whichever side wins, the
  // accept-idle tick picks the request up and Run returns.
  Server := TMCPServer.Create('stop-race-test', '1.0');
  try
    Transport := TMCPHTTPServer.Create(Server);
    Transport.Port := FindFreePort;
    Thread := TServerThread.CreateFor(Transport);
    Transport.Stop;
    // Bounded join instead of an unconditional WaitFor: if the
    // transport regressed and Run never returns, a blocking WaitFor
    // (or a TThread.Free, which joins) would hang the whole suite
    // instead of reporting the failed expectation.
    Finished := BoundedThreadJoin(Thread, 4000);
    Expect<Boolean>(Finished).ToBe(True);
    if Finished then
    begin
      Thread.Free;
      Transport.Free;
      // Server is freed by the outer finally.
    end
    else
    begin
      // Run is still live: it can touch the transport (and through it
      // the server) at any moment, so nothing it reaches may be freed.
      // Leak thread + transport, and detach the server from the outer
      // finally too.
      WriteLn(ErrOutput, 'WARNING: Run did not return after racing ',
        'Stop; leaking thread/transport/server');
      Server := nil;
    end;
  finally
    Server.Free;
  end;
end;

procedure THTTPBinding.TestDeclaredCapabilityRefusedBeforeStreaming;
var
  Body, ContentType: string;
  Status: Integer;
begin
  // Progress opted in, sampling not declared: the declared need is
  // checked before the handler runs, so the answer is a plain 400
  // (spec verified 2026-11-26:
  // https://modelcontextprotocol.io/specification/2026-07-28/basic/index#_meta).
  Status := Exchange('POST', '/mcp',
    CallLine(3, 'sampler', META_MODERN_STREAMING),
    [HeaderPair('MCP-Protocol-Version', MCP_PROTOCOL_VERSION),
     HeaderPair('Mcp-Method', 'tools/call'),
     HeaderPair('Mcp-Name', 'sampler')], Body, ContentType);
  Expect<Integer>(Status).ToBe(400);
  Expect<string>(ContentType).ToBe('application/json');
  Expect<Integer>(ErrorCodeOf(Body)).ToBe(-32021);
  Expect<Boolean>(Pos('"requiredCapabilities" : { "sampling" : {} }', Body) > 0)
    .ToBe(True);
end;

procedure THTTPBinding.TestUndeclaredCapabilityStillEndsTheStream;
var
  Body, ContentType: string;
  Status: Integer;
begin
  // Without the declaration the need shows only after progress went
  // out: the error can only be the stream's last event. This is the
  // case the declaration exists for.
  Status := Exchange('POST', '/mcp',
    CallLine(3, 'sampler_undeclared', META_MODERN_STREAMING),
    [HeaderPair('MCP-Protocol-Version', MCP_PROTOCOL_VERSION),
     HeaderPair('Mcp-Method', 'tools/call'),
     HeaderPair('Mcp-Name', 'sampler_undeclared')], Body, ContentType);
  Expect<Integer>(Status).ToBe(200);
  Expect<string>(ContentType).ToBe('text/event-stream');
  Expect<Boolean>(ProgressThenFinalRefusal(Body)).ToBe(True);
end;

// Sends a waiter call, waits until the handler's first poll found the
// connection open, then gives up on it: an orderly close, or with
// AReset a reset (SO_LINGER 0). Returns how the handler ended.
function THTTPBinding.AbandonWaiter(AReset: Boolean; const AExtra: string;
  out ASawOpen, AResetSet: Boolean): string;
type
  {$IFDEF WINDOWS}
  TResetLinger = record
    OnOff, Seconds: Word;
  end;
  {$ELSE}
  TResetLinger = record
    OnOff, Seconds: LongInt;
  end;
  {$ENDIF}
var
  Sock: TInetSocket;
  Body, Request: string;
  Linger: TResetLinger;
begin
  RTLEventResetEvent(WaiterEntered);
  RTLEventResetEvent(WaiterDone);
  WaiterOutcome := '';
  WaiterSawOpen := False;
  AResetSet := False;
  Body := CallLine(1, 'waiter');
  Request := 'POST /mcp HTTP/1.1'#13#10 +
    'Host: 127.0.0.1:' + IntToStr(FTransport.Port) + #13#10 +
    'Content-Type: application/json'#13#10 +
    'Accept: application/json, text/event-stream'#13#10 +
    'MCP-Protocol-Version: ' + MCP_PROTOCOL_VERSION + #13#10 +
    'Mcp-Method: tools/call'#13#10 + 'Mcp-Name: waiter'#13#10 +
    'Content-Length: ' + IntToStr(Length(Body)) + #13#10#13#10 + Body;
  Sock := TInetSocket.Create('127.0.0.1', FTransport.Port);
  try
    Sock.WriteBuffer(Request[1], Length(Request));
    RTLEventWaitFor(WaiterEntered, 5000);
    // Bytes after the request, sent once the handler is running, then
    // the close behind them.
    if AExtra <> '' then
      Sock.WriteBuffer(AExtra[1], Length(AExtra));
    if AReset then
    begin
      Linger.OnOff := 1;
      Linger.Seconds := 0;
      AResetSet := fpsetsockopt(Sock.Handle, SOL_SOCKET, SO_LINGER, @Linger,
        SizeOf(Linger)) = 0;
    end;
  finally
    // The client gives up: closing the connection is the cancellation.
    Sock.Free;
  end;
  RTLEventWaitFor(WaiterDone, 5000);
  // Read after the handler's last write, which WaiterDone orders.
  ASawOpen := WaiterSawOpen;
  Result := WaiterOutcome;
end;

// Closing the connection cancels the request (spec verified 2026-11-27:
// https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http#cancellation),
// and the handler learns it while it runs, though it never writes.
procedure THTTPBinding.TestDisconnectCancelsSilentHandler;
var
  SawOpen, ResetSet: Boolean;
begin
  // The handler first saw the connection open, then cancelled: the
  // close caused it.
  Expect<string>(AbandonWaiter(False, '', SawOpen, ResetSet))
    .ToBe('cancelled');
  Expect<Boolean>(SawOpen).ToBe(True);
end;

// Bytes the client sends after its request do not hide the close
// behind them (#93 review).
procedure THTTPBinding.TestBytesBeforeCloseStillCancel;
var
  SawOpen, ResetSet: Boolean;
begin
  Expect<string>(AbandonWaiter(False, 'extra bytes', SawOpen, ResetSet))
    .ToBe('cancelled');
  Expect<Boolean>(SawOpen).ToBe(True);
end;

// A reset is a closed connection too (#93 review).
procedure THTTPBinding.TestResetCancelsSilentHandler;
var
  SawOpen, ResetSet: Boolean;
begin
  Expect<string>(AbandonWaiter(True, '', SawOpen, ResetSet)).ToBe('cancelled');
  Expect<Boolean>(SawOpen).ToBe(True);
  Expect<Boolean>(ResetSet).ToBe(True);
end;

procedure THTTPBinding.SetupTests;
begin
  Test('completion/complete streams when its callback notifies',
    TestCompletionStreams);
  Test('request → single application/json response',
    TestSingleJSONResponse);
  Test('bare server/discover probe → 400, -32602 (not -32020)',
    TestBareDiscoverProbe);
  Test('missing _meta protocolVersion → 400, -32602',
    TestMissingProtocolVersion400);
  Test('missing _meta clientCapabilities → 400, -32602',
    TestMissingClientCapabilities400);
  Test('unknown tool → 200, -32602 in-band', TestInBandInvalidParamsStays200);
  Test('progress opt-in without clientCapabilities → 400 JSON, -32602',
    TestStreamingOptInMissingCapabilities400);
  Test('handler-raised -32021 → 400', TestHandlerRaisedMissingCapability400);
  Test('refusal after streamed progress → last SSE event under 200',
    TestRefusalAfterProgressEndsTheStream);
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
  Test('Mcp-Param headers: plain, nested, typed and base64 values match',
    TestParamHeadersMatch);
  Test('Mcp-Param header missing → 400, -32020', TestParamHeaderMissing);
  Test('events/poll carries Mcp-Name and Mcp-Param-*', TestEventRouting);
  Test('events/stream answers an SSE stream; the server can end it',
    TestEventStream);
  Test('subscriptions/listen answers an SSE stream; Stop ends it',
    TestListenStream);
  Test('a client that closes the connection ends its stream',
    TestEventStreamClientClose);
  Test('a client that closes the connection ends a quiet stream promptly',
    TestQuietStreamClientClose);
  Test('Stop reaches a waiting check, then the final frame',
    TestStopDuringACheck);
  Test('Stop reaches the opening check', TestStopDuringTheOpeningCheck);
  Test('progress, then a parked stream, on one SSE response',
    TestProgressThenPark);
  Test('Mcp-Param header mismatched → 400, -32020', TestParamHeaderMismatch);
  Test('Mcp-Param base64 with bad padding or characters → 400',
    TestParamHeaderBadBase64);
  Test('Mcp-Param unencoded non-ASCII → 400', TestParamHeaderUnencodedNonASCII);
  Test('Mcp-Param empty and repeated fields', TestParamHeaderEmptyAndRepeated);
  Test('Mcp-Param integers compare numerically in the safe range',
    TestParamHeaderIntegers);
  Test('Mcp-Name base64 decodes strictly', TestMcpNameStrictBase64);
  Test('Mcp-Param for an absent value: none expected, one sent → 400',
    TestParamHeaderWithoutValue);
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
  Test('declared capability missing → 400 before any notification',
    TestDeclaredCapabilityRefusedBeforeStreaming);
  Test('undeclared capability after progress → error ends the stream',
    TestUndeclaredCapabilityStillEndsTheStream);
  Test('client disconnect cancels a handler that never writes',
    TestDisconnectCancelsSilentHandler);
  Test('a reset connection cancels a handler that never writes',
    TestResetCancelsSilentHandler);
  Test('bytes sent before an orderly close do not hide it',
    TestBytesBeforeCloseStillCancel);
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
  ParkProgress := TParkProgress.Create;
  WaiterEntered := RTLEventCreate;
  WaiterDone := RTLEventCreate;
  TestRunnerProgram.AddSuite(THTTPBinding.Create('Transport.HTTP: binding'));
  TestRunnerProgram.Run;
  RTLEventDestroy(WaiterDone);
  RTLEventDestroy(WaiterEntered);
  ParkProgress.Free;
end.
