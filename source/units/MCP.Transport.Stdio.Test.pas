{ MCP.Transport.Stdio.Test — the framing shell, driven through temp
  Text files (the seam RunMCPStdioLoop exposes): one response line per
  request line, LF-only terminators even for multi-line-ish payloads,
  CRLF input tolerated, blank lines skipped, notifications producing no
  output line, and the loop returning cleanly at EOF. }

program MCP.Transport.Stdio.Test;

{$I Shared.inc}

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

type
  TStdioLoop = class(TTestSuite)
  private
    FServer: TMCPServer;
    FDir: string;
    // Feed AInput through the loop; returns the raw bytes written out.
    function RunLoop(const AInput: string): string;
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
    procedure TestMultipleRequests;
  end;

function PingHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPTextResult('pong');
end;

procedure TStdioLoop.BeforeEach;
begin
  FServer := TMCPServer.Create('stdio-test', '1.0');
  FServer.RegisterTool('ping', 'Ping', '{"type":"object"}', PingHandler);
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

function TStdioLoop.RunLoop(const AInput: string): string;
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
    RunMCPStdioLoop(InFile, OutFile, FServer);
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

procedure TStdioLoop.SetupTests;
begin
  Test('one request line → one response line', TestOneLineInOneLineOut);
  Test('LF-only line terminators', TestLfOnlyTerminators);
  Test('CRLF input tolerated', TestCrLfInputTolerated);
  Test('blank lines skipped', TestBlankLinesSkipped);
  Test('notification writes nothing', TestNotificationNoOutput);
  Test('three requests → three responses', TestMultipleRequests);
end;

begin
  TestRunnerProgram.AddSuite(TStdioLoop.Create('Transport.Stdio: loop'));
  TestRunnerProgram.Run;
end.
