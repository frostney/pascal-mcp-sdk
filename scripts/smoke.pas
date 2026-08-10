program smoke;

// `lwpt run smoke` entry point: runs the built E2E battery.
//
// Run-scripts execute via InstantFPC from a cache directory (no project
// include paths), so this wrapper stays self-contained — it cannot
// `{$I Shared.inc}` and must not use MCP.* units. It only locates the
// binary `lwpt build` produced and propagates its exit code.

{$mode delphi}{$H+}

uses
  SysUtils;

var
  Bin: string;
  i: Integer;
  Args: array of string;
begin
  Bin := 'build' + DirectorySeparator + 'mcpsmoke';
  {$IFDEF MSWINDOWS}
  if not FileExists(Bin) and FileExists(Bin + '.exe') then
    Bin := Bin + '.exe';
  {$ENDIF}
  if not FileExists(Bin) then
  begin
    WriteLn(ErrOutput, 'smoke: ', Bin, ' not found - run `lwpt build` first');
    Halt(127);
  end;

  SetLength(Args, ParamCount);
  for i := 1 to ParamCount do
    Args[i - 1] := ParamStr(i);

  try
    Halt(ExecuteProcess(ExpandFileName(Bin), Args));
  except
    on E: EOSError do
    begin
      WriteLn(ErrOutput, 'smoke: failed to run ', Bin, ': ', E.Message);
      Halt(126);
    end;
  end;
end.
