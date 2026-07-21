program mcpsmoke;

// End-to-end smoke test: launches the mcpdemo binary as a real
// subprocess (the way an MCP client launches a stdio server), drives
// the full v1 surface over its actual stdin/stdout, and checks every
// response — including the error paths a modern client relies on
// (-32022 for an unsupported version, the initialize rejection, -32602
// for an unknown tool) and the EOF shutdown contract. This is the
// process-level complement to the in-process *.Test.pas suites; CI
// runs it as the "example-server smoke test" leg.
//
// Usage: mcpsmoke [path-to-mcpdemo]   (default: ./build/mcpdemo)

{$I Shared.inc}

uses
  SysUtils,
  Classes,
  Process,

  fpjson,
  jsonparser,
  jsonscanner;

const
  META_MODERN =
    '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientInfo":{"name":"mcpsmoke","version":"0.1.0"},' +
    '"io.modelcontextprotocol/clientCapabilities":{}}';
  UTF8_PAYLOAD = 'h' + #$C3#$A9 + 'llo ' + #$E4#$B8#$96 + #$E7#$95#$8C;
  UTF8_WORLD = #$E4#$B8#$96 + #$E7#$95#$8C;

var
  Failures: Integer = 0;

procedure Check(ACondition: Boolean; const AWhat: string);
begin
  if ACondition then
    WriteLn('ok    ', AWhat)
  else
  begin
    WriteLn('FAIL  ', AWhat);
    Inc(Failures);
  end;
end;

function DemoBinary: string;
begin
  if ParamCount >= 1 then
    Result := ParamStr(1)
  else
  begin
    Result := 'build' + DirectorySeparator + 'mcpdemo';
    {$IFDEF WINDOWS}
    Result := Result + '.exe';
    {$ENDIF}
  end;
end;

// Blocking line read from the child's stdout. Byte-at-a-time is plenty
// for a smoke test; a missing newline within the deadline is a failure.
function ReadLine(AProcess: TProcess; out ALine: string): Boolean;
var
  B: Byte;
  Deadline: QWord;
begin
  ALine := '';
  Deadline := GetTickCount64 + 10000;
  while GetTickCount64 < Deadline do
  begin
    if AProcess.Output.NumBytesAvailable > 0 then
    begin
      if AProcess.Output.Read(B, 1) <> 1 then
        Exit(False);
      if B = 10 then
        Exit(True);
      if B <> 13 then
        ALine := ALine + Chr(B);
    end
    else if not AProcess.Running then
      Exit(False)
    else
      Sleep(5);
  end;
  Result := False;
end;

procedure SendLine(AProcess: TProcess; const ALine: string);
var
  Payload: string;
begin
  Payload := ALine + #10;
  AProcess.Input.Write(Payload[1], Length(Payload));
end;

// Read and parse the next line without sending anything — for
// sequences where one request produces several lines (notifications
// followed by the response).
function NextJson(AProcess: TProcess): TJSONObject;
var
  Line: string;
  Data: TJSONData;
begin
  Result := nil;
  if not ReadLine(AProcess, Line) then
    Exit;
  try
    Data := GetJSON(Line);
  except
    Exit;
  end;
  if (Data <> nil) and (Data.JSONType = jtObject) then
    Result := TJSONObject(Data)
  else
    Data.Free;
end;

// Send one request, capture one response line, and parse it. nil on
// transport failure (counted by the caller via Check).
function RoundTripWithLine(AProcess: TProcess; const ARequest: string;
  out ALine: string): TJSONObject;
var
  Data: TJSONData;
begin
  Result := nil;
  SendLine(AProcess, ARequest);
  if not ReadLine(AProcess, ALine) then
    Exit;
  try
    Data := GetJSON(ALine);
  except
    Exit;
  end;
  if (Data <> nil) and (Data.JSONType = jtObject) then
    Result := TJSONObject(Data)
  else
    Data.Free;
end;

function RoundTrip(AProcess: TProcess; const ARequest: string): TJSONObject;
var
  Line: string;
begin
  Result := RoundTripWithLine(AProcess, ARequest, Line);
end;

function FindPath(AObj: TJSONObject; const APath: string): TJSONData;
begin
  if AObj = nil then
    Result := nil
  else
    Result := AObj.FindPath(APath);
end;

function PathString(AObj: TJSONObject; const APath: string): string;
var
  Data: TJSONData;
begin
  Data := FindPath(AObj, APath);
  if (Data <> nil) and (Data.JSONType = jtString) then
    Result := Data.AsString
  else
    Result := '';
end;

function PathInt(AObj: TJSONObject; const APath: string): Integer;
var
  Data: TJSONData;
begin
  Data := FindPath(AObj, APath);
  if (Data <> nil) and (Data.JSONType = jtNumber) then
    Result := Data.AsInteger
  else
    Result := 0;
end;

var
  Demo: TProcess;
  Response: TJSONObject;
  ResponseLine: string;
  ServerInfo: TJSONData;
  WaitedMs: Integer;

begin
  Demo := TProcess.Create(nil);
  try
    Demo.Executable := DemoBinary;
    Demo.Options := [poUsePipes];
    try
      Demo.Execute;
    except
      on E: Exception do
      begin
        WriteLn('FAIL  cannot launch ', DemoBinary, ': ', E.Message);
        Halt(1);
      end;
    end;

    // server/discover — the mandatory entry point.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{' +
      META_MODERN + '}}');
    Check(PathString(Response, 'result.resultType') = 'complete',
      'discover: resultType complete');
    Check(PathString(Response, 'result.supportedVersions[0]') = '2026-07-28',
      'discover: supportedVersions lists 2026-07-28');
    Check(FindPath(Response, 'result.capabilities.tools') <> nil,
      'discover: tools capability');
    // The serverInfo _meta key contains dots, so FindPath (which
    // splits on dots) cannot address it — navigate by hand.
    ServerInfo := FindPath(Response, 'result._meta');
    if (ServerInfo <> nil) and (ServerInfo.JSONType = jtObject) then
      ServerInfo := TJSONObject(ServerInfo).Find(
        'io.modelcontextprotocol/serverInfo')
    else
      ServerInfo := nil;
    Check((ServerInfo <> nil) and (ServerInfo.JSONType = jtObject) and
      (TJSONObject(ServerInfo).Get('name', '') = 'pascal-mcp-sdk-demo'),
      'discover: serverInfo stamped');
    Check(PathString(Response, 'result.serverInfo.name') = 'pascal-mcp-sdk-demo',
      'discover: top-level serverInfo (required by RC wire schema)');
    Check(FindPath(Response, 'result.ttlMs') <> nil,
      'discover: ttlMs present (SEP-2549)');
    Response.Free;

    // tools/list.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{' +
      META_MODERN + '}}');
    Check(PathString(Response, 'result.tools[0].name') = 'echo',
      'tools/list: echo first (registration order)');
    Check(PathString(Response, 'result.tools[1].name') = 'add',
      'tools/list: add second');
    Check(FindPath(Response, 'result.tools[1].outputSchema') <> nil,
      'tools/list: add carries outputSchema');
    Check(PathString(Response, 'result.cacheScope') = 'private',
      'tools/list: cacheScope present (SEP-2549)');
    Response.Free;

    // tools/call echo.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{' +
      '"name":"echo","arguments":{"message":"round trip"},' +
      META_MODERN + '}}');
    Check(PathString(Response, 'result.content[0].text') = 'round trip',
      'tools/call echo: text mirrored');
    Response.Free;

    Response := RoundTripWithLine(Demo,
      '{"jsonrpc":"2.0","id":19,"method":"tools/call","params":{' +
      '"name":"echo","arguments":{"message":"' + UTF8_PAYLOAD + '"},' +
      META_MODERN + '}}', ResponseLine);
    Check(Pos('"text" : "' + UTF8_PAYLOAD + '"', ResponseLine) > 0,
      'tools/call echo: non-ASCII bytes mirrored as UTF-8');
    Response.Free;

    Response := RoundTripWithLine(Demo,
      '{"jsonrpc":"2.0","id":23,"method":"tools/call","params":{' +
      '"name":"echo","arguments":{"message":"a\u4e16\u754cb"},' +
      META_MODERN + '}}', ResponseLine);
    Check(Pos('"text" : "a' + UTF8_WORLD + 'b"', ResponseLine) > 0,
      'tools/call echo: adjacent escapes mirrored as exact UTF-8 bytes');
    Response.Free;

    // Raw handlers validate arguments against their advertised schema.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{' +
      '"name":"echo","arguments":{},' + META_MODERN + '}}');
    Check((FindPath(Response, 'result.isError') <> nil) and
      FindPath(Response, 'result.isError').AsBoolean,
      'tools/call echo (bad args): isError true');
    Response.Free;

    // tools/call add — structured content.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{' +
      '"name":"add","arguments":{"a":19,"b":23},' + META_MODERN + '}}');
    Check(PathInt(Response, 'result.structuredContent.sum') = 42,
      'tools/call add: structuredContent.sum = 42');
    Response.Free;

    // tools/call add with missing argument — execution error in-band.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{' +
      '"name":"add","arguments":{"a":19},' + META_MODERN + '}}');
    Check((FindPath(Response, 'result.isError') <> nil) and
      FindPath(Response, 'result.isError').AsBoolean,
      'tools/call add (bad args): isError true');
    Response.Free;

    // tools/call unknown — protocol error.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{' +
      '"name":"nope",' + META_MODERN + '}}');
    Check(PathInt(Response, 'error.code') = -32602,
      'tools/call unknown: -32602');
    Response.Free;

    // resources/list + read.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":7,"method":"resources/list","params":{' +
      META_MODERN + '}}');
    Check(PathString(Response, 'result.resources[0].uri') =
      'mcp://pascal-mcp-sdk/greeting',
      'resources/list: greeting present');
    Response.Free;

    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":8,"method":"resources/read","params":{' +
      '"uri":"mcp://pascal-mcp-sdk/greeting",' + META_MODERN + '}}');
    Check(Pos('Hello from pascal-mcp-sdk',
      PathString(Response, 'result.contents[0].text')) > 0,
      'resources/read: greeting text');
    Response.Free;

    // Unsupported protocol version — -32022 with the supported list.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":9,"method":"tools/list","params":{' +
      '"_meta":{"io.modelcontextprotocol/protocolVersion":"1900-01-01",' +
      '"io.modelcontextprotocol/clientCapabilities":{}}}}');
    Check(PathInt(Response, 'error.code') = -32022,
      'unsupported version: -32022');
    Check(PathString(Response, 'error.data.supported[0]') = '2026-07-28',
      'unsupported version: supported list in data');
    Response.Free;

    // resources/templates/list + a templated read.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":21,"method":"resources/templates/list",' +
      '"params":{' + META_MODERN + '}}');
    Check(PathString(Response, 'result.resourceTemplates[0].uriTemplate') =
      'mcp://pascal-mcp-sdk/shout/{text}',
      'templates/list: shout template present');
    Response.Free;

    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":22,"method":"resources/read","params":{' +
      '"uri":"mcp://pascal-mcp-sdk/shout/hey",' + META_MODERN + '}}');
    Check(PathString(Response, 'result.contents[0].text') = 'HEY',
      'resources/read: template variable extracted (shout/hey → HEY)');
    Response.Free;

    // prompts/list + prompts/get.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":8,"method":"prompts/list","params":{' +
      META_MODERN + '}}');
    Check(PathString(Response, 'result.prompts[0].name') = 'greet',
      'prompts/list: greet present');
    Check(FindPath(Response, 'result.ttlMs') <> nil,
      'prompts/list: ttlMs present (SEP-2549)');
    Response.Free;

    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":9,"method":"prompts/get","params":{' +
      '"name":"greet","arguments":{"name":"Ada"},' + META_MODERN + '}}');
    Check(Pos('Ada', PathString(Response,
      'result.messages[0].content.text')) > 0,
      'prompts/get: argument woven into message');
    Response.Free;

    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":10,"method":"prompts/get","params":{' +
      '"name":"greet",' + META_MODERN + '}}');
    Check(PathInt(Response, 'error.code') = -32602,
      'prompts/get: missing required argument → -32602');
    Response.Free;

    // In-request notifications: with progressToken + logLevel opted
    // in, echo emits progress(0.5) + log(info) + progress(1.0) before
    // its response — four lines total, in order.
    SendLine(Demo,
      '{"jsonrpc":"2.0","id":16,"method":"tools/call","params":{' +
      '"name":"echo","arguments":{"message":"noisy hi"},' +
      '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
      '"io.modelcontextprotocol/clientCapabilities":{},' +
      '"io.modelcontextprotocol/logLevel":"info",' +
      '"progressToken":5}}}');
    Response := NextJson(Demo);
    Check(PathString(Response, 'method') = 'notifications/progress',
      'notify: first line is progress');
    Check(PathInt(Response, 'params.progressToken') = 5,
      'notify: token echoed');
    Response.Free;
    Response := NextJson(Demo);
    Check(PathString(Response, 'method') = 'notifications/message',
      'notify: log message with opt-in');
    Check(PathString(Response, 'params.level') = 'info',
      'notify: log level carried');
    Response.Free;
    Response := NextJson(Demo);
    Check(PathString(Response, 'method') = 'notifications/progress',
      'notify: completion progress');
    Response.Free;
    Response := NextJson(Demo);
    Check(PathString(Response, 'result.content[0].text') = 'noisy hi',
      'notify: response arrives after notifications');
    Response.Free;

    // ── Legacy era (dual-era default): the path today's clients
    //    (Claude Code / Claude Desktop) actually take. ──

    // Bare legacy request before the handshake → -32600.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":10,"method":"tools/list","params":{}}');
    Check(PathInt(Response, 'error.code') = -32600,
      'legacy: request before initialize → -32600');
    Response.Free;

    // ping is valid at any time in the legacy era.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":11,"method":"ping"}');
    Check((Response <> nil) and (Response.Find('result') <> nil),
      'legacy: ping answered');
    Response.Free;

    // initialize — negotiate a legacy revision.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":12,"method":"initialize","params":{' +
      '"protocolVersion":"2025-06-18","capabilities":{},' +
      '"clientInfo":{"name":"legacy-smoke","version":"0"}}}');
    Check(PathString(Response, 'result.protocolVersion') = '2025-06-18',
      'legacy: initialize echoes 2025-06-18');
    Check(PathString(Response, 'result.serverInfo.name') = 'pascal-mcp-sdk-demo',
      'legacy: initialize serverInfo');
    Check(FindPath(Response, 'result.resultType') = nil,
      'legacy: initialize result unstamped');
    Response.Free;

    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":120,"method":"tools/list","params":{}}');
    Check((PathInt(Response, 'error.code') = -32600) and
      (PathString(Response, 'error.message') =
      'Received request before initialization is complete: send ' +
      'notifications/initialized first'),
      'legacy: request before initialized notification → -32600');
    Response.Free;

    SendLine(Demo,
      '{"jsonrpc":"2.0","method":"notifications/initialized"}');

    // Legacy tools/call — no _meta anywhere.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{' +
      '"name":"echo","arguments":{"message":"legacy round trip"}}}');
    Check(PathString(Response, 'result.content[0].text') =
      'legacy round trip',
      'legacy: tools/call echo works');
    Check(FindPath(Response, 'result.resultType') = nil,
      'legacy: tools/call result unstamped');
    Response.Free;

    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":121,"method":"initialize","params":{' +
      '"protocolVersion":"2025-11-25","capabilities":{},' +
      '"clientInfo":{"name":"legacy-again","version":"1"}}}');
    Check((PathInt(Response, 'error.code') = -32600) and
      (PathString(Response, 'error.message') =
      'Server is already initialized: initialize may only be sent once'),
      'legacy: second initialize → -32600 already initialized');
    Response.Free;

    // Legacy resource-not-found uses the era-correct -32002.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":14,"method":"resources/read","params":{' +
      '"uri":"mcp://nope"}}');
    Check(PathInt(Response, 'error.code') = -32002,
      'legacy: resource not found → -32002');
    Response.Free;

    // Both eras concurrently: a modern request after the legacy
    // handshake is still served statelessly with modern stamps.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":15,"method":"tools/list","params":{' +
      META_MODERN + '}}');
    Check(PathString(Response, 'result.resultType') = 'complete',
      'dual-era: modern request after legacy handshake stays modern');
    Response.Free;

    // EOF on stdin → prompt exit (the graceful-shutdown contract).
    Demo.CloseInput;
    WaitedMs := 0;
    while Demo.Running and (WaitedMs < 5000) do
    begin
      Sleep(50);
      Inc(WaitedMs, 50);
    end;
    Check(not Demo.Running, 'shutdown: exits on stdin EOF');
    if Demo.Running then
      Demo.Terminate(1)
    else
      Check(Demo.ExitStatus = 0, 'shutdown: exit status 0');
  finally
    Demo.Free;
  end;

  WriteLn;
  if Failures = 0 then
    WriteLn('mcpsmoke: all checks passed')
  else
    WriteLn('mcpsmoke: ', Failures, ' check(s) FAILED');
  if Failures > 0 then
    Halt(1);
end.
