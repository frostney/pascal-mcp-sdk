program conformance;

// `lwpt run conformance` entry point: runs the official MCP conformance
// suite (tools/conformance/run.mjs) against the built conformance
// fixture (mcpconformance, the suite's reference surface) over
// Streamable HTTP. Needs Node >= 22 and npm registry access.
//
// Self-contained for the same reason as smoke.pas: run-scripts execute
// via InstantFPC from a cache directory with no project include paths.

{$mode delphi}{$H+}

uses
  SysUtils;

const
  // ExeSearch matches the file name literally.
  NodeName = {$IFDEF MSWINDOWS}'node.exe'{$ELSE}'node'{$ENDIF};

var
  Bin: string;
  i: Integer;
  Args: array of string;
begin
  Bin := 'build' + DirectorySeparator + 'mcpconformance';
  {$IFDEF MSWINDOWS}
  if not FileExists(Bin) and FileExists(Bin + '.exe') then
    Bin := Bin + '.exe';
  {$ENDIF}
  if not FileExists(Bin) then
  begin
    WriteLn(ErrOutput, 'conformance: ', Bin, ' not found - run `lwpt build` first');
    Halt(127);
  end;

  SetLength(Args, ParamCount + 2);
  Args[0] := 'tools' + DirectorySeparator + 'conformance' + DirectorySeparator + 'run.mjs';
  Args[1] := ExpandFileName(Bin);
  for i := 1 to ParamCount do
    Args[i + 1] := ParamStr(i);

  try
    Halt(ExecuteProcess(ExeSearch(NodeName, GetEnvironmentVariable('PATH')), Args));
  except
    on E: EOSError do
    begin
      WriteLn(ErrOutput, 'conformance: failed to run node: ', E.Message);
      Halt(126);
    end;
  end;
end.
