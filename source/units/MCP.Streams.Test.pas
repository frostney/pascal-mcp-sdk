{ MCP.Streams.Test — the clock streams run on (MCPNowMs): it never goes
  back and it advances in milliseconds. On macOS it is the Mach clock,
  not FPC's GetTickCount64, which is wall time there (#134). }

program MCP.Streams.Test;

{$I MCP.inc}

uses
  SysUtils,

  MCP.Streams,
  TestingPascalLibrary;

type
  TStreamClock = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestNeverGoesBack;
    procedure TestAdvancesAcrossASleep;
    {$IFDEF DARWIN}
    procedure TestNotWallTimeOnMacOS;
    {$ENDIF}
  end;

procedure TStreamClock.TestNeverGoesBack;
var
  Last, Now: Int64;
  I: Integer;
  WentBack: Boolean;
begin
  WentBack := False;
  Last := MCPNowMs;
  for I := 1 to 100000 do
  begin
    Now := MCPNowMs;
    if Now < Last then
      WentBack := True;
    Last := Now;
  end;
  Expect<Boolean>(WentBack).ToBe(False);
end;

procedure TStreamClock.TestAdvancesAcrossASleep;
var
  Started, Elapsed, TickStarted, TickElapsed: Int64;
begin
  // GetTickCount64's span encloses MCPNowMs's, so a slow runner adds
  // to both.
  TickStarted := Int64(GetTickCount64);
  Started := MCPNowMs;
  Sleep(100);
  Elapsed := MCPNowMs - Started;
  TickElapsed := Int64(GetTickCount64) - TickStarted;
  // Not slower than milliseconds: a sleep never ends early.
  Expect<Boolean>(Elapsed >= 90).ToBe(True);
  // Not faster either: in microseconds it would read about 100000
  // (#134 review).
  Expect<Boolean>(Elapsed <= TickElapsed + 50).ToBe(True);
end;

{$IFDEF DARWIN}
// GetTickCount64 is wall time on macOS: milliseconds since 1970, far
// from any uptime the Mach clock counts.
procedure TStreamClock.TestNotWallTimeOnMacOS;
begin
  Expect<Boolean>(Abs(MCPNowMs - Int64(GetTickCount64)) > 86400000)
    .ToBe(True);
end;
{$ENDIF}

procedure TStreamClock.SetupTests;
begin
  Test('never goes back', TestNeverGoesBack);
  Test('advances in milliseconds across a sleep', TestAdvancesAcrossASleep);
  {$IFDEF DARWIN}
  Test('is not wall time on macOS', TestNotWallTimeOnMacOS);
  {$ENDIF}
end;

begin
  TestRunnerProgram.AddSuite(TStreamClock.Create('Streams: clock'));
  TestRunnerProgram.Run;
end.
