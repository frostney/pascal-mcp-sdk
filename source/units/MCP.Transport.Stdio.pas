unit MCP.Transport.Stdio;

// stdio transport binding (spec revision 2026-07-28): newline-delimited
// JSON-RPC over the standard streams of a client-launched subprocess.
// This unit is a deliberately thin shell — every protocol decision
// lives in MCP.Server.HandleMessage; here we create one session for
// the connection and move lines. Each call supplies its output sink,
// so transport state never resides on the shared server or session.
//
// Binding rules implemented (spec .../draft/basic/transports/stdio,
// verified 2026-07-20):
//   - one UTF-8 JSON-RPC message per line, no embedded newlines
//     (fpjson escapes newlines inside strings, so serialized responses
//     are single-line by construction); UTF-8 setup lives in MCP.JSONRPC;
//   - stdout carries nothing but MCP messages — diagnostics belong on
//     stderr (MCPLogToStderr);
//   - responses are terminated with a bare LF on every platform (a
//     platform WriteLn would emit CRLF on Windows); inbound lines get
//     a stray trailing CR stripped for the mirror-image reason;
//   - EOF on stdin is the graceful-shutdown signal: the loop returns
//     and the server process is expected to exit promptly.
//
// The loop is synchronous and single-threaded: create one connection
// session, read a line, handle it with this request's output sink, write
// the response, flush. That serial model is what makes ignoring
// notifications/cancelled correct (see MCP.Server).
//
// Inbound lines are length-capped (default 4 MiB, the same order as
// the official SDKs' stdio buffer limit): an oversized line is
// consumed and answered with the server's parse-error response
// instead of accumulating unbounded memory — the response text stays
// a protocol decision (TMCPServer.OversizedLineResponse), the
// transport only enforces the byte budget.
//
// MCP.Transport.HTTP is the planned second binding (Streamable HTTP);
// it will wrap the same TMCPServer without changes here.

{$I Shared.inc}

interface

uses
  SysUtils,

  MCP.Server;

const
  // Default inbound line cap in bytes.
  MCP_STDIO_DEFAULT_MAX_LINE = 4 * 1024 * 1024;

// Serve AServer over the program's standard input/output until EOF.
procedure RunMCPStdioServer(AServer: TMCPServer;
  AMaxLineLength: Integer = MCP_STDIO_DEFAULT_MAX_LINE);

// The same loop over arbitrary Text files — the seam tests drive with
// temp files, and custom stream transports (sockets reusing the stdio
// framing, as the spec suggests) can reuse.
procedure RunMCPStdioLoop(var AInput, AOutput: Text; AServer: TMCPServer;
  AMaxLineLength: Integer = MCP_STDIO_DEFAULT_MAX_LINE);

// Diagnostics channel: stderr is the only stream a stdio MCP server may
// log to. Writes one line and flushes.
procedure MCPLogToStderr(const AMessage: string);

implementation

// Read one LF-terminated line, storing at most AMax bytes. True when
// a line (possibly empty) was read; False on EOF with nothing read.
// AOverflow reports that the line exceeded AMax — the excess is
// consumed so the stream stays line-synchronized.
function ReadBoundedLine(var AInput: Text; AMax: Integer;
  out ALine: string; out AOverflow: Boolean): Boolean;
var
  C: Char;
  Len: Integer;
begin
  ALine := '';
  Len := 0;
  AOverflow := False;
  if EOF(AInput) then
    Exit(False);
  while not EOF(AInput) do
  begin
    Read(AInput, C);
    if C = #10 then
      Break;
    if Len < AMax then
    begin
      // Amortized growth: appending char-by-char would be quadratic.
      if Len = Length(ALine) then
        if Len = 0 then
          SetLength(ALine, 256)
        else
          SetLength(ALine, Len * 2);
      Inc(Len);
      ALine[Len] := C;
    end
    else
      AOverflow := True; // keep consuming to the newline, store nothing
  end;
  SetLength(ALine, Len);
  Result := True;
end;

type
  PText = ^Text;

// Notification sink: in-request notifications (progress, log
// messages) are written to the same output stream as responses, one
// line each, flushed immediately so they precede the response.
procedure StdioNotificationSink(const ALine: string; AUserData: Pointer);
begin
  Write(PText(AUserData)^, ALine, #10);
  Flush(PText(AUserData)^);
end;

procedure RunMCPStdioLoop(var AInput, AOutput: Text; AServer: TMCPServer;
  AMaxLineLength: Integer);
var
  Line, Response: string;
  Overflow: Boolean;
  Session: TMCPSession;
begin
  Session := AServer.CreateSession;
  try
    while ReadBoundedLine(AInput, AMaxLineLength, Line, Overflow) do
    begin
      if Overflow then
      begin
        Write(AOutput, AServer.OversizedLineResponse(AMaxLineLength), #10);
        Flush(AOutput);
        Continue;
      end;
      // A client writing CRLF line endings leaves a trailing CR on
      // non-Windows reads; it is insignificant whitespace either way.
      while (Line <> '') and (Line[Length(Line)] in [#13, #10]) do
        SetLength(Line, Length(Line) - 1);
      if Line = '' then
        Continue;
      if AServer.HandleMessage(Session, Line, StdioNotificationSink,
        @AOutput, Response) then
      begin
        Write(AOutput, Response, #10);
        Flush(AOutput);
      end;
    end;
  finally
    Session.Free;
  end;
end;

procedure RunMCPStdioServer(AServer: TMCPServer; AMaxLineLength: Integer);
begin
  RunMCPStdioLoop(Input, Output, AServer, AMaxLineLength);
end;

procedure MCPLogToStderr(const AMessage: string);
begin
  Write(ErrOutput, AMessage, #10);
  Flush(ErrOutput);
end;

end.
