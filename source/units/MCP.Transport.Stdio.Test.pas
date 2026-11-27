{ MCP.Transport.Stdio.Test — the framing shell, driven through temp
  Text files (the seam RunMCPStdioLoop exposes): one response line per
  request line, LF-only terminators even for multi-line-ish payloads,
  CRLF input tolerated, blank lines skipped, notifications producing no
  output line, and the loop returning cleanly at EOF. }

program MCP.Transport.Stdio.Test;

{$I MCP.inc}

uses
  Classes,
  SysUtils,

  fpjson,
  jsonparser,
  MCP.Protocol,
  MCP.Server,
  MCP.Transport.Stdio,
  TestingPascalLibrary;

const
  META_MODERN =
    '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{}}';
  UTF8_PAYLOAD = 'h' + #$C3#$A9 + 'llo ' + #$E4#$B8#$96 + #$E7#$95#$8C;

type
  TStdioLoop = class(TTestSuite)
  private
    FServer: TMCPServer;
    FDir: string;
    // Feed AInput through the loop; returns the raw bytes written out.
    function RunLoop(const AInput: string;
      AMaxLineLength: Integer = MCP_STDIO_DEFAULT_MAX_LINE): string;
    function RunWithCodePage(const AInput: string;
      ACodePage: TSystemCodePage; out AAfter: TSystemCodePage): string;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;
    procedure TestOneLineInOneLineOut;
    procedure TestLfOnlyTerminators;
    procedure TestCrLfInputTolerated;
    procedure TestBlankLinesSkipped;
    procedure TestNotificationNoOutput;
    procedure TestCallerCodePageRestored;
    procedure TestStderrCodePageRestored;
    procedure TestMultipleRequests;
    procedure TestUtf8RoundTrip;
    procedure TestOversizedLineRejected;
    procedure TestOversizedLineRecovery;
    procedure TestCancelReachesRunningHandler;
    procedure TestCancelForOtherRequestIgnored;
    procedure TestLastLineWithoutNewline;
  end;

function PingHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPTextResult('pong');
end;

var
  // How the polling handler ended: 'cancelled' or 'finished'.
  WaiterOutcome: string;

// Polls IsCancelled the way a long handler does; the cancellation, if
// any, comes from the stdio loop's poll (#93).
function WaiterHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  I: Integer;
begin
  WaiterOutcome := 'finished';
  for I := 1 to 200 do
  begin
    if ACtx.IsCancelled then
    begin
      WaiterOutcome := 'cancelled';
      Exit(MCPTextResult('cancelled'));
    end;
    Sleep(1);
  end;
  Result := MCPTextResult('finished');
end;

function EchoHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPTextResult(AArguments.Get('message', ''));
end;

procedure TStdioLoop.BeforeEach;
begin
  FServer := TMCPServer.Create('stdio-test', '1.0');
  FServer.RegisterTool('ping', 'Ping', '{"type":"object"}', PingHandler);
  FServer.RegisterTool('echo', 'Echo', '{"type":"object"}', EchoHandler);
  FServer.RegisterTool('waiter', 'Waits', '{"type":"object"}', WaiterHandler);
  FDir := GetTempDir + 'pascal-mcp-sdk-stdio-test' + PathDelim;
  ForceDirectories(FDir);
end;

procedure TStdioLoop.AfterEach;
begin
  FreeAndNil(FServer);
  DeleteFile(FDir + 'in.txt');
  DeleteFile(FDir + 'out.txt');
  RemoveDir(FDir);
end;

function TStdioLoop.RunLoop(const AInput: string;
  AMaxLineLength: Integer): string;
var
  InFile, OutFile: Text;
  Bytes: TStringStream;
  FileStream: TFileStream;
begin
  // Write the scripted input, then drive the loop with real Text
  // files — the same code path RunMCPStdioServer wires to Input/Output.
  Bytes := TStringStream.Create(AInput);
  try
    Bytes.SaveToFile(FDir + 'in.txt');
  finally
    Bytes.Free;
  end;

  Assign(InFile, FDir + 'in.txt');
  Reset(InFile);
  Assign(OutFile, FDir + 'out.txt');
  Rewrite(OutFile);
  try
    RunMCPStdioLoop(InFile, OutFile, FServer, AMaxLineLength);
  finally
    Close(InFile);
    Close(OutFile);
  end;

  FileStream := TFileStream.Create(FDir + 'out.txt', fmOpenRead);
  try
    Bytes := TStringStream.Create('');
    try
      Bytes.CopyFrom(FileStream, 0);
      Result := Bytes.DataString;
    finally
      Bytes.Free;
    end;
  finally
    FileStream.Free;
  end;
end;

function DiscoverLine(AId: Integer): string;
begin
  Result := '{"jsonrpc":"2.0","id":' + IntToStr(AId) +
    ',"method":"server/discover","params":{' + META_MODERN + '}}';
end;

procedure TStdioLoop.TestOneLineInOneLineOut;
var
  Output: string;
  Parsed: TJSONData;
begin
  Output := RunLoop(DiscoverLine(1) + #10);
  // Exactly one LF, at the very end — one response line.
  Expect<Integer>(Pos(#10, Output)).ToBe(Length(Output));
  Parsed := GetJSON(Copy(Output, 1, Length(Output) - 1));
  Expect<Integer>(Ord(Parsed.JSONType)).ToBe(Ord(jtObject));
  Parsed.Free;
end;

procedure TStdioLoop.TestLfOnlyTerminators;
var
  Output: string;
begin
  Output := RunLoop(DiscoverLine(1) + #10);
  Expect<Integer>(Pos(#13, Output)).ToBe(0);
end;

procedure TStdioLoop.TestCrLfInputTolerated;
var
  Output: string;
  Parsed: TJSONObject;
begin
  Output := RunLoop(DiscoverLine(7) + #13#10);
  Parsed := TJSONObject(GetJSON(Copy(Output, 1, Length(Output) - 1)));
  Expect<Integer>(Parsed.Get('id', 0)).ToBe(7);
  Expect<Boolean>(Parsed.Find('result') <> nil).ToBe(True);
  Parsed.Free;
end;

procedure TStdioLoop.TestBlankLinesSkipped;
var
  Output: string;
  I, Lines: Integer;
begin
  Output := RunLoop(#10#10 + DiscoverLine(1) + #10#10);
  Lines := 0;
  for I := 1 to Length(Output) do
    if Output[I] = #10 then
      Inc(Lines);
  Expect<Integer>(Lines).ToBe(1);
end;

procedure TStdioLoop.TestNotificationNoOutput;
var
  Output: string;
begin
  Output := RunLoop(
    '{"jsonrpc":"2.0","method":"notifications/cancelled",' +
    '"params":{"requestId":1}}'#10);
  Expect<string>(Output).ToBe('');
end;

procedure TStdioLoop.TestMultipleRequests;
var
  Output: string;
  I, Lines: Integer;
begin
  Output := RunLoop(DiscoverLine(1) + #10 + DiscoverLine(2) + #10 +
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{' +
    '"name":"ping",' + META_MODERN + '}}'#10);
  Lines := 0;
  for I := 1 to Length(Output) do
    if Output[I] = #10 then
      Inc(Lines);
  Expect<Integer>(Lines).ToBe(3);
  Expect<Boolean>(Pos('pong', Output) > 0).ToBe(True);
end;

procedure TStdioLoop.TestUtf8RoundTrip;
var
  Output: string;
begin
  Output := RunLoop(
    '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{' +
    '"name":"echo","arguments":{"message":"' + UTF8_PAYLOAD + '"},' +
    META_MODERN + '}}'#10);
  Expect<Boolean>(Pos('"text" : "' + UTF8_PAYLOAD + '"', Output) > 0)
    .ToBe(True);
end;

procedure TStdioLoop.TestOversizedLineRejected;
var
  Output: string;
  Parsed: TJSONObject;
begin
  // 200-byte cap, ~300-byte line: refused with -32700, null id.
  Output := RunLoop(StringOfChar('x', 300) + #10, 200);
  Parsed := TJSONObject(GetJSON(Copy(Output, 1, Length(Output) - 1)));
  Expect<Integer>(
    TJSONData(Parsed.FindPath('error.code')).AsInteger).ToBe(-32700);
  Expect<Boolean>(Parsed.Find('id').JSONType = jtNull).ToBe(True);
  Parsed.Free;
end;

procedure TStdioLoop.TestOversizedLineRecovery;
var
  Output: string;
  I, Lines: Integer;
begin
  // The stream stays line-synchronized: the request after an
  // oversized line is served normally.
  Output := RunLoop(StringOfChar('x', 300) + #10 + DiscoverLine(2) + #10,
    200);
  Lines := 0;
  for I := 1 to Length(Output) do
    if Output[I] = #10 then
      Inc(Lines);
  Expect<Integer>(Lines).ToBe(2);
  Expect<Boolean>(Pos('"supportedVersions"', Output) > 0).ToBe(True);
end;

// The output file is the caller's: the loop writes UTF-8 to it and puts
// its code page back on return (#102 review).
// Runs AInput through the loop with the output file's raw code page
// set to ACodePage; returns the bytes written and, in AAfter, the raw
// code page the file has once the loop returns.
function TStdioLoop.RunWithCodePage(const AInput: string;
  ACodePage: TSystemCodePage; out AAfter: TSystemCodePage): string;
var
  InFile, OutFile: Text;
  Bytes: TStringStream;
begin
  Bytes := TStringStream.Create(AInput);
  try
    Bytes.SaveToFile(FDir + 'in.txt');
  finally
    Bytes.Free;
  end;
  Assign(InFile, FDir + 'in.txt');
  Reset(InFile);
  Assign(OutFile, FDir + 'out.txt');
  Rewrite(OutFile);
  TextRec(OutFile).CodePage := ACodePage;
  try
    RunMCPStdioLoop(InFile, OutFile, FServer, MCP_STDIO_DEFAULT_MAX_LINE);
    AAfter := TextRec(OutFile).CodePage;
  finally
    Close(InFile);
    Close(OutFile);
  end;
  Bytes := TStringStream.Create('');
  try
    Bytes.LoadFromFile(FDir + 'out.txt');
    Result := Bytes.DataString;
  finally
    Bytes.Free;
  end;
end;

// The output file is the caller's: the loop writes UTF-8 to it whatever
// its code page, and puts the exact value back on return, 0 included
// (#102 review).
procedure TStdioLoop.TestCallerCodePageRestored;
const
  REQUEST = '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{' +
    '"name":"echo","arguments":{"message":"' + UTF8_PAYLOAD + '"},';
var
  After: TSystemCodePage;
  Output: string;
begin
  Output := RunWithCodePage(REQUEST + META_MODERN + '}}'#10, 1252, After);
  Expect<Integer>(After).ToBe(1252);
  Expect<Boolean>(Pos('"text" : "' + UTF8_PAYLOAD + '"', Output) > 0)
    .ToBe(True);
  RunWithCodePage('', 0, After);
  Expect<Integer>(After).ToBe(0);
end;

// MCPLogToStderr leaves ErrOutput's code page as the host had it.
procedure TStdioLoop.TestStderrCodePageRestored;
var
  Saved: TSystemCodePage;
begin
  Saved := TextRec(ErrOutput).CodePage;
  try
    TextRec(ErrOutput).CodePage := 1252;
    MCPLogToStderr('mcp-stderr-probe (expected in test output)');
    Expect<Integer>(TextRec(ErrOutput).CodePage).ToBe(1252);
    TextRec(ErrOutput).CodePage := 0;
    MCPLogToStderr('mcp-stderr-probe (expected in test output)');
    Expect<Integer>(TextRec(ErrOutput).CodePage).ToBe(0);
  finally
    TextRec(ErrOutput).CodePage := Saved;
  end;
end;

function WaiterCall(const AId: string): string;
begin
  Result := '{"jsonrpc":"2.0","id":' + AId + ',"method":"tools/call",' +
    '"params":{"name":"waiter",' + META_MODERN + '}}';
end;

procedure TStdioLoop.TestCancelReachesRunningHandler;
var
  Output: string;
begin
  // The cancellation arrives behind the request it names, ahead of
  // another request: the running handler sees it at its next poll, its
  // response is withheld, and the request after it is still served,
  // byte-exact.
  Output := RunLoop(WaiterCall('"w' + #$C3#$A9 + '"') + #10 +
    '{"jsonrpc":"2.0","method":"notifications/cancelled","params":' +
    '{"requestId":"w' + #$C3#$A9 + '","reason":"user"}}' + #10 +
    '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{' +
    '"name":"echo","arguments":{"message":"' + UTF8_PAYLOAD + '"},' +
    META_MODERN + '}}' + #10);
  Expect<string>(WaiterOutcome).ToBe('cancelled');
  Expect<Boolean>(Pos('"id" : "w', Output) = 0).ToBe(True);
  Expect<Boolean>(Pos('"id" : 9', Output) > 0).ToBe(True);
  Expect<Boolean>(Pos('"text" : "' + UTF8_PAYLOAD + '"', Output) > 0)
    .ToBe(True);
end;

procedure TStdioLoop.TestCancelForOtherRequestIgnored;
var
  Output: string;
begin
  Output := RunLoop(WaiterCall('1') + #10 +
    '{"jsonrpc":"2.0","method":"notifications/cancelled","params":' +
    '{"requestId":2}}' + #10);
  Expect<string>(WaiterOutcome).ToBe('finished');
  Expect<Boolean>(Pos('"text" : "finished"', Output) > 0).ToBe(True);
end;

procedure TStdioLoop.TestLastLineWithoutNewline;
var
  Output: string;
begin
  // A final line without its LF is still served, as before.
  Output := RunLoop(DiscoverLine(1));
  Expect<Boolean>(Pos('"id" : 1', Output) > 0).ToBe(True);
end;

procedure TStdioLoop.SetupTests;
begin
  Test('the caller''s output code page is restored exactly; output UTF-8',
    TestCallerCodePageRestored);
  Test('MCPLogToStderr restores the stderr code page exactly',
    TestStderrCodePageRestored);
  Test('one request line → one response line', TestOneLineInOneLineOut);
  Test('LF-only line terminators', TestLfOnlyTerminators);
  Test('CRLF input tolerated', TestCrLfInputTolerated);
  Test('blank lines skipped', TestBlankLinesSkipped);
  Test('notification writes nothing', TestNotificationNoOutput);
  Test('three requests → three responses', TestMultipleRequests);
  Test('non-ASCII payload → byte-exact UTF-8', TestUtf8RoundTrip);
  Test('oversized line → -32700, null id', TestOversizedLineRejected);
  Test('stream recovers after an oversized line',
    TestOversizedLineRecovery);
  Test('notifications/cancelled reaches a running handler; later lines served',
    TestCancelReachesRunningHandler);
  Test('a cancellation for another id leaves the handler running',
    TestCancelForOtherRequestIgnored);
  Test('a last line without LF is served', TestLastLineWithoutNewline);
end;

begin
  TestRunnerProgram.AddSuite(TStdioLoop.Create('Transport.Stdio: loop'));
  TestRunnerProgram.Run;
end.
