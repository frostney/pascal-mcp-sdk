{ MCP.Transport.Stdio.Test — the framing shell, driven through temp
  Text files (the seam RunMCPStdioLoop exposes): one response line per
  request line, LF-only terminators even for multi-line-ish payloads,
  CRLF input tolerated, blank lines skipped, notifications producing no
  output line, and the loop returning cleanly at EOF; and push streams
  (#126) multiplexed beside other requests, cancelled by
  notifications/cancelled, stepped while the loop waits for input, and
  refused over a Text with its own driver. }

program MCP.Transport.Stdio.Test;

{$I MCP.inc}

uses
  // The pipe script thread needs the Unix thread driver first.
  {$IFDEF UNIX}
  cthreads,
  BaseUnix,
  {$ENDIF}
  {$IFDEF WINDOWS}
  Windows,
  {$ENDIF}
  Classes,
  SysUtils,
  streamio,

  fpjson,
  jsonparser,
  MCP.Events,
  MCP.Protocol,
  MCP.Schema,
  MCP.Streams,
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
    procedure TestCancelWrittenAfterHandlerStarts;
    procedure TestCancelForQueuedRequestWaits;
    procedure TestMalformedThenValidCancellation;
    procedure TestServerOverCustomInput;
    procedure TestEscapedCancellationMethod;
    procedure TestTextBufferTakenOver;
    procedure TestStreamBackedInput;
    procedure TestCancelForOtherRequestIgnored;
    procedure TestStreamsBesideRequests;
    procedure TestStreamStepsWhileInputIdle;
    procedure TestStreamRefusedOverTextDriver;
    procedure TestStreamCancelledBetweenSteps;
    procedure TestStreamCancelledDuringFirstCheck;
    procedure TestParkedStreamOfCancelledRequestDropped;
    procedure TestLastLineWithoutNewline;
  end;

var
  // Each beat check call by its stream's id, and |ping for each ping
  // (#126).
  CallLog: string;

function PingHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  CallLog := CallLog + '|ping';
  Result := MCPTextResult('pong');
end;

var
  // How the polling handler ended: 'cancelled' or 'finished'.
  WaiterOutcome: string;
  // Every outcome in order, comma-separated.
  WaiterOutcomes: string;
  // The write end of the pipe TestCancelWrittenAfterHandlerStarts feeds.
  PipeWriter: THandle;
  // The beat upstream (#126): occurrences 1 .. BeatHead; the check asks
  // again after BeatPollMs; on call BeatCloseAt it adds one occurrence
  // and closes PipeWriter, ending the input.
  BeatHead, BeatPollMs, BeatCalls, BeatCloseAt: Integer;
  // 1 while PipeWriter is open, for ClosePipeOnce.
  PipeOpen: LongInt;

// Closes PipeWriter once, whoever gets there first: the check, or the
// script thread that bounds a test.
procedure ClosePipeOnce;
begin
  if InterLockedExchange(PipeOpen, 0) = 1 then
    FileClose(PipeWriter);
end;

type
  // Writes AData (if any) to PipeWriter after ADelayMs, then closes it
  // when AClose: input that arrives while the loop waits.
  TPipeScript = class(TThread)
  private
    FDelayMs: Integer;
    FData: string;
    FClose: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(ADelayMs: Integer; const AData: string;
      AClose: Boolean);
  end;

constructor TPipeScript.Create(ADelayMs: Integer; const AData: string;
  AClose: Boolean);
begin
  FDelayMs := ADelayMs;
  FData := AData;
  FClose := AClose;
  inherited Create(False);
end;

procedure TPipeScript.Execute;
var
  Waited: Integer;
begin
  // A closer whose pipe is already closed has nothing left to do.
  Waited := 0;
  while (Waited < FDelayMs) and not (FClose and (PipeOpen = 0)) do
  begin
    Sleep(10);
    Inc(Waited, 10);
  end;
  if (FData <> '') and (PipeOpen = 1) then
    FileWrite(PipeWriter, FData[1], Length(FData));
  if FClose then
    ClosePipeOnce;
end;

function BeatCheck(const AQuery: TMCPEventQuery;
  const ACtx: TMCPRequestContext): TMCPEventPoll;
var
  From, Last, I: Integer;
begin
  Inc(BeatCalls);
  CallLog := CallLog + ACtx.RequestId.AsString;
  if BeatCalls = BeatCloseAt then
  begin
    Inc(BeatHead);
    ClosePipeOnce;
  end;
  // A check that polls IsCancelled, as a cooperative one does (#126
  // review).
  if AQuery.Arguments.Get('poll', False) then
    ACtx.IsCancelled;
  Result := MCPEventPoll(IntToStr(BeatHead), TJSONArray.Create);
  Result.NextPollMs := BeatPollMs;
  // A stream that always has more is stepped on every loop turn.
  Result.HasMore := AQuery.Arguments.Get('more', False);
  if AQuery.FromNow then
    Exit;
  From := StrToInt(AQuery.Cursor) + 1;
  Last := BeatHead;
  if (AQuery.MaxEvents >= 0) and (From + AQuery.MaxEvents - 1 < Last) then
  begin
    Last := From + AQuery.MaxEvents - 1;
    Result.HasMore := True;
  end;
  for I := From to Last do
    Result.Events.Add(MCPEventOccurrence('e' + IntToStr(I),
      '2026-11-27T10:00:00Z', TJSONObject.Create(['n', I, 'text',
      UTF8_PAYLOAD])));
  if Last >= From then
    Result.Cursor := IntToStr(Last);
end;

type
  // A stream that would write one line on its first step.
  TDummyStream = class(TMCPStream)
  public
    function Step(ASink: TMCPLineSink; ASinkData: Pointer): Int64; override;
    procedure Close(ASink: TMCPLineSink; ASinkData: Pointer); override;
  end;

  // test/park: parks a dummy stream, then sees a cancellation waiting.
  TParkMethod = class
    function Park(AParams: TJSONObject; const ACtx: TMCPRequestContext;
      ALegacy: Boolean): TJSONObject;
  end;

function TDummyStream.Step(ASink: TMCPLineSink; ASinkData: Pointer): Int64;
begin
  ASink('{"dummy":true}', ASinkData);
  Finish;
  Result := High(Int64);
end;

procedure TDummyStream.Close(ASink: TMCPLineSink; ASinkData: Pointer);
begin
  Finish;
end;

function TParkMethod.Park(AParams: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
begin
  TMCPStreamHost(ACtx.StreamHost).Park(TDummyStream.Create(ACtx.RequestId));
  ACtx.IsCancelled;
  Result := TJSONObject.Create;
end;

var
  ParkMethod: TParkMethod;

function StreamLine(const AId, AParams: string): string;
begin
  Result := '{"jsonrpc":"2.0","id":' + AId + ',"method":"events/stream",' +
    '"params":{"name":"beat",' + AParams + META_MODERN + '}}';
end;

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
      WaiterOutcomes := WaiterOutcomes + 'cancelled,';
      Exit(MCPTextResult('cancelled'));
    end;
    Sleep(1);
  end;
  WaiterOutcomes := WaiterOutcomes + 'finished,';
  Result := MCPTextResult('finished');
end;

// Asks IsCancelled exactly once, as a handler at its last checkpoint.
function PollOnceHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  if ACtx.IsCancelled then
    WaiterOutcome := 'cancelled'
  else
    WaiterOutcome := 'finished';
  Result := MCPTextResult(WaiterOutcome);
end;

// Writes its own cancellation into the input pipe once it runs, then
// closes the pipe and polls: only a poll that reads the handle can see
// it, as the loop read the request before the cancellation existed.
function SelfCancelHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
const
  CANCEL = '{"jsonrpc":"2.0","method":"notifications/cancelled",' +
    '"params":{"requestId":"p1"}}'#10;
var
  I: Integer;
begin
  FileWrite(PipeWriter, CANCEL[1], Length(CANCEL));
  FileClose(PipeWriter);
  WaiterOutcome := 'finished';
  for I := 1 to 2000 do
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
  FServer.RegisterTool('self_cancel', 'Cancels itself through the pipe',
    '{"type":"object"}', SelfCancelHandler);
  FServer.RegisterTool('poll_once', 'Polls once', '{"type":"object"}',
    PollOnceHandler);
  RegisterEvent(FServer, 'beat', 'Beats', ObjectSchema, ObjectSchema
    .AddInteger('n'), BeatCheck);
  FServer.RegisterMethod('test/park', ParkMethod.Park);
  BeatHead := 2;
  BeatPollMs := 60000;
  BeatCalls := 0;
  BeatCloseAt := 0;
  CallLog := '';
  WaiterOutcome := '';
  WaiterOutcomes := '';
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

// A pipe whose write end the handler keeps; the read end replaces the
// handle of an ordinary Text opened on an empty file, so the loop sees a
// plain file Text over a real pipe.
procedure OpenPipe(out AReader, AWriter: THandle);
{$IFDEF UNIX}
var
  Ends: TFilDes;
begin
  if fpPipe(Ends) <> 0 then
    raise Exception.Create('pipe failed');
  AReader := Ends[0];
  AWriter := Ends[1];
end;
{$ELSE}
begin
  if not CreatePipe(AReader, AWriter, nil, 0) then
    raise Exception.Create('CreatePipe failed');
end;
{$ENDIF}

// Cancellation reaches a running handler on stdio (spec verified
// 2026-11-27: the receiver SHOULD stop processing a cancelled request
// and not respond,
// https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/cancellation;
// on stdio servers SHOULD stop as soon as practical,
// https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio).
// Here the cancellation is written only after the handler started, so
// the poll must read it from the pipe.
procedure TStdioLoop.TestCancelWrittenAfterHandlerStarts;
const
  REQUEST = '{"jsonrpc":"2.0","id":"p1","method":"tools/call",' +
    '"params":{"name":"self_cancel",' + META_MODERN + '}}'#10;
var
  InFile, OutFile: Text;
  PipeReader: THandle;
  Output: string;
  Bytes: TStringStream;
begin
  Bytes := TStringStream.Create('');
  try
    Bytes.SaveToFile(FDir + 'in.txt');
  finally
    Bytes.Free;
  end;
  OpenPipe(PipeReader, PipeWriter);
  FileWrite(PipeWriter, REQUEST[1], Length(REQUEST));
  Assign(InFile, FDir + 'in.txt');
  Reset(InFile);
  FileClose(TextRec(InFile).Handle);
  TextRec(InFile).Handle := PipeReader;
  Assign(OutFile, FDir + 'out.txt');
  Rewrite(OutFile);
  try
    RunMCPStdioLoop(InFile, OutFile, FServer);
  finally
    Close(InFile);
    Close(OutFile);
  end;
  Expect<string>(WaiterOutcome).ToBe('cancelled');
  Bytes := TStringStream.Create('');
  try
    Bytes.LoadFromFile(FDir + 'out.txt');
    Output := Bytes.DataString;
  finally
    Bytes.Free;
  end;
  // Nothing is sent for the cancelled request.
  Expect<string>(Output).ToBe('');
end;

// A cancellation for a request still queued behind the running one is
// left for that request, not spent on the running one (#93 review).
procedure TStdioLoop.TestCancelForQueuedRequestWaits;
begin
  RunLoop(WaiterCall('1') + #10 + WaiterCall('2') + #10 +
    '{"jsonrpc":"2.0","method":"notifications/cancelled","params":' +
    '{"requestId":2}}' + #10);
  Expect<string>(WaiterOutcomes).ToBe('finished,cancelled,');
end;

// The method is matched decoded, as the core matches it: an escaped
// slash is still notifications/cancelled (#93 review).
procedure TStdioLoop.TestEscapedCancellationMethod;
begin
  RunLoop(WaiterCall('3') + #10 +
    '{"jsonrpc":"2.0","method":"notifications\/cancelled","params":' +
    '{"requestId":3}}' + #10);
  Expect<string>(WaiterOutcomes).ToBe('cancelled,');
end;

// A malformed cancellation naming the running request is skipped, and
// the valid one behind it is found by the same poll (#93 review).
procedure TStdioLoop.TestMalformedThenValidCancellation;
begin
  RunLoop('{"jsonrpc":"2.0","id":4,"method":"tools/call","params":' +
    '{"name":"poll_once",' + META_MODERN + '}}' + #10 +
    '{"jsonrpc":"2.0","method":"notifications/cancelled","params":' +
    '{"requestId":4,"reason":5}}' + #10 +
    '{"jsonrpc":"2.0","method":"notifications/cancelled","params":' +
    '{"requestId":4,"reason":"user"}}' + #10);
  Expect<string>(WaiterOutcome).ToBe('cancelled');
end;

// RunMCPStdioServer over a global Input that has its own driver: the
// plain-file check does not take Input's driver for the plain one, so
// the stream is read through Text (#93 review).
procedure TStdioLoop.TestServerOverCustomInput;
var
  SavedInput, SavedOutput: TextRec;
  Source, Sink: TStringStream;
begin
  Source := TStringStream.Create(DiscoverLine(8) + #10);
  Sink := TStringStream.Create('');
  SavedInput := TextRec(Input);
  SavedOutput := TextRec(Output);
  try
    AssignStream(Input, Source);
    Reset(Input);
    AssignStream(Output, Sink);
    Rewrite(Output);
    try
      RunMCPStdioServer(FServer);
    finally
      Close(Input);
      Close(Output);
      TextRec(Input) := SavedInput;
      TextRec(Output) := SavedOutput;
    end;
    Expect<Boolean>(Pos('"id" : 8', Sink.DataString) > 0).ToBe(True);
  finally
    Source.Free;
    Sink.Free;
  end;
end;

// Bytes the caller's Text had already buffered are served, not skipped
// (#93 review).
procedure TStdioLoop.TestTextBufferTakenOver;
var
  InFile, OutFile: Text;
  Bytes: TStringStream;
  Header, Output: string;
  LargeBuffer: array[0..4095] of Char;
begin
  // A header longer than 256 bytes, read through a larger buffer, so
  // the takeover starts beyond the declared TextBuf bounds.
  Bytes := TStringStream.Create(StringOfChar('h', 300) + #10 +
    DiscoverLine(5) + #10);
  try
    Bytes.SaveToFile(FDir + 'in.txt');
  finally
    Bytes.Free;
  end;
  Assign(InFile, FDir + 'in.txt');
  SetTextBuf(InFile, LargeBuffer, SizeOf(LargeBuffer));
  Reset(InFile);
  ReadLn(InFile, Header);
  Assign(OutFile, FDir + 'out.txt');
  Rewrite(OutFile);
  try
    RunMCPStdioLoop(InFile, OutFile, FServer);
  finally
    Close(InFile);
    Close(OutFile);
  end;
  Bytes := TStringStream.Create('');
  try
    Bytes.LoadFromFile(FDir + 'out.txt');
    Output := Bytes.DataString;
  finally
    Bytes.Free;
  end;
  Expect<string>(Header).ToBe(StringOfChar('h', 300));
  Expect<Boolean>(Pos('"id" : 5', Output) > 0).ToBe(True);
end;

// A Text with its own I/O driver (here a stream) is read through Text,
// as before #93 (review).
procedure TStdioLoop.TestStreamBackedInput;
var
  InFile, OutFile: Text;
  Source: TStringStream;
  Bytes: TStringStream;
  Output: string;
begin
  Source := TStringStream.Create(DiscoverLine(6) + #10 + '{"jsonrpc":"2.0",' +
    '"id":7,"method":"tools/call","params":{"name":"echo","arguments":' +
    '{"message":"' + UTF8_PAYLOAD + '"},' + META_MODERN + '}}' + #10);
  try
    AssignStream(InFile, Source);
    Reset(InFile);
    Assign(OutFile, FDir + 'out.txt');
    Rewrite(OutFile);
    try
      RunMCPStdioLoop(InFile, OutFile, FServer);
    finally
      Close(InFile);
      Close(OutFile);
    end;
  finally
    Source.Free;
  end;
  Bytes := TStringStream.Create('');
  try
    Bytes.LoadFromFile(FDir + 'out.txt');
    Output := Bytes.DataString;
  finally
    Bytes.Free;
  end;
  Expect<Boolean>(Pos('"id" : 6', Output) > 0).ToBe(True);
  Expect<Boolean>(Pos('"text" : "' + UTF8_PAYLOAD + '"', Output) > 0)
    .ToBe(True);
end;

// Two push streams and a request on one stdin (events.mdx, Lifecycle:
// concurrent streams share stdout, told apart by the subscription id):
// each stream's frames follow its request, the request is answered
// between them, a stream request gets no response line, and a
// cancelled stream sends nothing more.
procedure TStdioLoop.TestStreamsBesideRequests;
var
  Output: string;
  Lines: TStringList;
begin
  Output := RunLoop(StreamLine('"a"', '"cursor":"0",') + #10 +
    StreamLine('"c"', '"arguments":{"more":true},') + #10 +
    StreamLine('"b"', '') + #10 +
    '{"jsonrpc":"2.0","method":"notifications/cancelled","params":' +
    '{"requestId":"c"}}' + #10 +
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":' +
    '"ping",' + META_MODERN + '}}' + #10);
  // Stream c, which always has more, was cancelled by the line already
  // waiting: its probe took it before c wrote anything, and c was never
  // checked again.
  // a: the handler's check and one more for its backlog; c: the
  // handler's only; b: the handler's.
  Expect<string>(CallLog).ToBe('aacb|ping');
  Expect<Integer>(Pos('/subscriptionId" : "c"', Output)).ToBe(0);
  // Non-ASCII occurrence data goes out byte-exact (#126 review).
  Expect<Boolean>(Pos('"text" : "' + UTF8_PAYLOAD + '"', Output) > 0)
    .ToBe(True);
  Lines := TStringList.Create;
  try
    Lines.Text := Output;
    Expect<Integer>(Lines.Count).ToBe(5);
    Expect<Boolean>(Pos('notifications/events/active', Lines[0]) > 0)
      .ToBe(True);
    Expect<Boolean>(Pos('/subscriptionId" : "a"', Lines[0]) > 0).ToBe(True);
    Expect<Boolean>(Pos('"eventId" : "e1"', Lines[1]) > 0).ToBe(True);
    Expect<Boolean>(Pos('"eventId" : "e2"', Lines[2]) > 0).ToBe(True);
    Expect<Boolean>(Pos('"cursor" : "2", "truncated" : false', Lines[3]) > 0)
      .ToBe(True);
    Expect<Boolean>(Pos('/subscriptionId" : "b"', Lines[3]) > 0).ToBe(True);
    Expect<Boolean>(Pos('"id" : 3', Lines[4]) > 0).ToBe(True);
    Expect<Integer>(Pos('"id" : "a"', Output) + Pos('"id" : "b"', Output))
      .ToBe(0);
  finally
    Lines.Free;
  end;
end;

// The loop waits for input no longer than the stream's next check: with
// stdin open and idle, the check runs again after nextPollMs, and its
// occurrence goes out before the input ends.
procedure TStdioLoop.TestStreamStepsWhileInputIdle;
var
  InFile, OutFile: Text;
  PipeReader: THandle;
  Request, Output: string;
  Bytes: TStringStream;
  Started: QWord;
  Script: TPipeScript;
begin
  BeatHead := 0;
  BeatPollMs := 100;
  BeatCloseAt := 2;
  Request := StreamLine('9', '"cursor":"0",') + #10;
  Script := nil;
  Bytes := TStringStream.Create('');
  try
    Bytes.SaveToFile(FDir + 'in.txt');
  finally
    Bytes.Free;
  end;
  OpenPipe(PipeReader, PipeWriter);
  PipeOpen := 1;
  FileWrite(PipeWriter, Request[1], Length(Request));
  Assign(InFile, FDir + 'in.txt');
  Reset(InFile);
  FileClose(TextRec(InFile).Handle);
  TextRec(InFile).Handle := PipeReader;
  Assign(OutFile, FDir + 'out.txt');
  Rewrite(OutFile);
  Started := GetTickCount64;
  try
    // A bound: if the idle loop never steps the stream, the input still
    // ends, and the missing occurrence fails the test (#126 review).
    Script := TPipeScript.Create(3000, '', True);
    RunMCPStdioLoop(InFile, OutFile, FServer);
  finally
    Close(InFile);
    Close(OutFile);
    if Script <> nil then
    begin
      Script.WaitFor;
      Script.Free;
    end;
  end;
  Bytes := TStringStream.Create('');
  try
    Bytes.LoadFromFile(FDir + 'out.txt');
    Output := Bytes.DataString;
  finally
    Bytes.Free;
  end;
  Expect<Integer>(BeatCalls).ToBe(2);
  Expect<Boolean>(GetTickCount64 - Started >= 90).ToBe(True);
  Expect<Integer>(Pos('{ "jsonrpc" : "2.0", "method" : ' +
    '"notifications/events/active"', Output)).ToBe(1);
  Expect<Boolean>(Pos('"eventId" : "e1"', Output) > 0).ToBe(True);
end;

// A cancellation that arrives while its stream is not due is read by
// the loop itself, and the stream is dropped there: it is not checked
// again when it would have been due.
procedure TStdioLoop.TestStreamCancelledBetweenSteps;
var
  InFile, OutFile: Text;
  PipeReader: THandle;
  Request: string;
  Bytes: TStringStream;
  Cancel, Closer: TPipeScript;
begin
  BeatPollMs := 400;
  Request := StreamLine('5', '"cursor":"2",') + #10;
  Bytes := TStringStream.Create('');
  try
    Bytes.SaveToFile(FDir + 'in.txt');
  finally
    Bytes.Free;
  end;
  OpenPipe(PipeReader, PipeWriter);
  PipeOpen := 1;
  FileWrite(PipeWriter, Request[1], Length(Request));
  Assign(InFile, FDir + 'in.txt');
  Reset(InFile);
  FileClose(TextRec(InFile).Handle);
  TextRec(InFile).Handle := PipeReader;
  Assign(OutFile, FDir + 'out.txt');
  Rewrite(OutFile);
  Cancel := TPipeScript.Create(100, '{"jsonrpc":"2.0","method":' +
    '"notifications/cancelled","params":{"requestId":5}}' + #10, False);
  Closer := TPipeScript.Create(900, '', True);
  try
    RunMCPStdioLoop(InFile, OutFile, FServer);
  finally
    Close(InFile);
    Close(OutFile);
    Cancel.WaitFor;
    Cancel.Free;
    Closer.WaitFor;
    Closer.Free;
  end;
  // The handler's check only: none at 400 ms.
  Expect<string>(CallLog).ToBe('5');
end;

// A cancellation that a cooperative first check sees: no stream opens
// and nothing is written for the request (#126 review).
procedure TStdioLoop.TestStreamCancelledDuringFirstCheck;
begin
  Expect<string>(RunLoop(StreamLine('6', '"cursor":"0","arguments":' +
    '{"poll":true},') + #10 + '{"jsonrpc":"2.0","method":' +
    '"notifications/cancelled","params":{"requestId":6}}' + #10)).ToBe('');
  Expect<string>(CallLog).ToBe('6');
end;

// A stream parked by a request the core then answers nothing for (the
// request was cancelled after the stream was parked) is dropped, not
// driven (#126 review).
procedure TStdioLoop.TestParkedStreamOfCancelledRequestDropped;
begin
  Expect<string>(RunLoop('{"jsonrpc":"2.0","id":7,"method":"test/park",' +
    '"params":{' + META_MODERN + '}}' + #10 + '{"jsonrpc":"2.0","method":' +
    '"notifications/cancelled","params":{"requestId":7}}' + #10)).ToBe('');
end;

// A Text with its own I/O driver cannot be waited on, so the loop
// offers no stream host and events/stream answers -32026.
procedure TStdioLoop.TestStreamRefusedOverTextDriver;
var
  InFile, OutFile: Text;
  Source, Bytes: TStringStream;
  Output: string;
begin
  Source := TStringStream.Create(StreamLine('4', '') + #10);
  try
    AssignStream(InFile, Source);
    Reset(InFile);
    Assign(OutFile, FDir + 'out.txt');
    Rewrite(OutFile);
    try
      RunMCPStdioLoop(InFile, OutFile, FServer);
    finally
      Close(InFile);
      Close(OutFile);
    end;
  finally
    Source.Free;
  end;
  Bytes := TStringStream.Create('');
  try
    Bytes.LoadFromFile(FDir + 'out.txt');
    Output := Bytes.DataString;
  finally
    Bytes.Free;
  end;
  Expect<Boolean>(Pos('"id" : 4, "error" : { "code" : -32026', Output) > 0)
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
  Test('a cancellation written after the handler started reaches it',
    TestCancelWrittenAfterHandlerStarts);
  Test('a cancellation for a queued request waits for that request',
    TestCancelForQueuedRequestWaits);
  Test('a malformed cancellation does not hide a valid one behind it',
    TestMalformedThenValidCancellation);
  Test('RunMCPStdioServer reads a custom-driver Input through Text',
    TestServerOverCustomInput);
  Test('an escaped notifications\/cancelled method still cancels',
    TestEscapedCancellationMethod);
  Test('bytes the caller''s Text already buffered are served',
    TestTextBufferTakenOver);
  Test('a stream-backed Text is read through Text, as before',
    TestStreamBackedInput);
  Test('a cancellation for another id leaves the handler running',
    TestCancelForOtherRequestIgnored);
  Test('a last line without LF is served', TestLastLineWithoutNewline);
  Test('push streams share stdout with requests; a cancelled one stops',
    TestStreamsBesideRequests);
  Test('a stream is stepped while stdin is open and idle',
    TestStreamStepsWhileInputIdle);
  Test('a Text with its own driver cannot stream: -32026',
    TestStreamRefusedOverTextDriver);
  Test('a cancellation read between steps drops the stream',
    TestStreamCancelledBetweenSteps);
  Test('a cancellation the first check sees opens no stream',
    TestStreamCancelledDuringFirstCheck);
  Test('a stream parked by a cancelled request is dropped',
    TestParkedStreamOfCancelledRequestDropped);
end;

begin
  ParkMethod := TParkMethod.Create;
  TestRunnerProgram.AddSuite(TStdioLoop.Create('Transport.Stdio: loop'));
  TestRunnerProgram.Run;
  ParkMethod.Free;
end.
