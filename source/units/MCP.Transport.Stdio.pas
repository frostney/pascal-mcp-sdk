unit MCP.Transport.Stdio;

// stdio transport binding (spec revision 2026-07-28): newline-delimited
// JSON-RPC over the standard streams of a client-launched subprocess.
// This unit is a deliberately thin shell — every protocol decision
// lives in MCP.Server.HandleMessage; here we only move lines.
//
// Binding rules implemented (spec .../draft/basic/transports/stdio):
//   - one UTF-8 JSON-RPC message per line, no embedded newlines
//     (fpjson escapes newlines inside strings, so serialized responses
//     are single-line by construction);
//   - stdout carries nothing but MCP messages — diagnostics belong on
//     stderr (MCPLogToStderr);
//   - responses are terminated with a bare LF on every platform (a
//     platform WriteLn would emit CRLF on Windows); inbound lines get
//     a stray trailing CR stripped for the mirror-image reason;
//   - EOF on stdin is the graceful-shutdown signal: the loop returns
//     and the server process is expected to exit promptly.
//
// The loop is synchronous and single-threaded: read a line, handle it,
// write the response, flush. That serial model is what makes ignoring
// notifications/cancelled correct (see MCP.Server).
//
// MCP.Transport.HTTP is the planned second binding (Streamable HTTP);
// it will wrap the same TMCPServer without changes here.

{$I Shared.inc}

interface

uses
  SysUtils,

  MCP.Server;

// Serve AServer over the program's standard input/output until EOF.
procedure RunMCPStdioServer(AServer: TMCPServer);

// The same loop over arbitrary Text files — the seam tests drive with
// temp files, and custom stream transports (sockets reusing the stdio
// framing, as the spec suggests) can reuse.
procedure RunMCPStdioLoop(var AInput, AOutput: Text; AServer: TMCPServer);

// Diagnostics channel: stderr is the only stream a stdio MCP server may
// log to. Writes one line and flushes.
procedure MCPLogToStderr(const AMessage: string);

implementation

procedure RunMCPStdioLoop(var AInput, AOutput: Text; AServer: TMCPServer);
var
  Line, Response: string;
begin
  while not EOF(AInput) do
  begin
    ReadLn(AInput, Line);
    // A client writing CRLF line endings leaves a trailing CR on
    // non-Windows reads; it is insignificant whitespace either way.
    while (Line <> '') and (Line[Length(Line)] in [#13, #10]) do
      SetLength(Line, Length(Line) - 1);
    if Line = '' then
      Continue;
    if AServer.HandleMessage(Line, Response) then
    begin
      Write(AOutput, Response, #10);
      Flush(AOutput);
    end;
  end;
end;

procedure RunMCPStdioServer(AServer: TMCPServer);
begin
  RunMCPStdioLoop(Input, Output, AServer);
end;

procedure MCPLogToStderr(const AMessage: string);
begin
  Write(ErrOutput, AMessage, #10);
  Flush(ErrOutput);
end;

end.
