unit MCP.Transport.Stdio;

// stdio transport binding (spec revision 2026-07-28): newline-delimited
// JSON-RPC over the standard streams of a client-launched subprocess.
// This unit is a deliberately thin shell — every protocol decision
// lives in MCP.Server.HandleMessage; here we create one session for
// the connection and move lines. Each call supplies its output sink,
// so transport state never resides on the shared server or session.
//
// Binding rules implemented (spec .../draft/basic/transports/stdio,
// verified 2026-07-21):
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
// the response, flush. Input is read from the handle into the loop's
// own buffer, not through Text, so cancellation can reach a running
// handler (#93): whenever the handler asks ACtx.IsCancelled, the
// session's cancellation poll takes the bytes already waiting on stdin
// without blocking (select on Unix, PeekNamedPipe on Windows), hands
// any complete notifications/cancelled line to the core, which cancels
// the request, and keeps every other line queued in order. No thread is
// involved, so a stdio-only program needs no thread driver.
//
// The stdio binding says clients MUST send notifications/cancelled and
// servers SHOULD stop work as soon as practical and MUST NOT send any
// further messages for that request (verified 2026-07-21):
// https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio
// https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/cancellation
//
// Inbound lines are length-capped (default 4 MiB, the same order as
// the official SDKs' stdio buffer limit): an oversized line is
// consumed and answered with the server's parse-error response
// instead of accumulating unbounded memory — the response text stays
// a protocol decision (TMCPServer.OversizedLineResponse), the
// transport only enforces the byte budget.
//
// MCP.Transport.HTTP is the second binding (Streamable HTTP); it
// wraps the same TMCPServer without changes here.

{$I MCP.inc}

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

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  {$IFDEF WINDOWS}
  Windows,
  {$ENDIF}
  MCP.JSONRPC;

const
  READ_CHUNK = 65536;

type
  PText = ^Text;

  TQueuedLine = record
    Line: string;
    Overflow: Boolean;
  end;

  // Reads the input handle directly, into its own buffer, so that a
  // poll can take bytes that are waiting without blocking and without
  // the Text buffer holding back what was already read (#93). Complete
  // lines wait in a queue in arrival order; the line being received
  // grows until its LF, keeping at most FMax bytes (the excess is
  // consumed and the line flagged as overflowing, as before).
  TStdioReader = class
  private
    FHandle: THandle;
    FMax: Integer;
    FQueue: array of TQueuedLine;
    FHead: Integer;
    FPartial: string;
    FPartialLen: Integer;
    FPartialOverflow: Boolean;
    FEOF: Boolean;
    procedure Feed(const AChunk: string);
    procedure Push(const ALine: string; AOverflow: Boolean);
    function ReadChunk: Boolean;
    function DataWaiting: Boolean;
  public
    constructor Create(AHandle: THandle; AMax: Integer);
    // The next line, blocking until one is complete; False at EOF.
    function NextLine(out ALine: string; out AOverflow: Boolean): Boolean;
    // Takes whatever is waiting on the handle without blocking.
    procedure TakeWaiting;
    // Removes and returns the queued notifications/cancelled lines.
    function TakeCancellations: TStringArray;
  end;

constructor TStdioReader.Create(AHandle: THandle; AMax: Integer);
begin
  inherited Create;
  FHandle := AHandle;
  FMax := AMax;
end;

procedure TStdioReader.Push(const ALine: string; AOverflow: Boolean);
var
  Slot: Integer;
begin
  Slot := Length(FQueue);
  SetLength(FQueue, Slot + 1);
  FQueue[Slot].Line := ALine;
  FQueue[Slot].Overflow := AOverflow;
end;

procedure TStdioReader.Feed(const AChunk: string);
var
  I: Integer;
begin
  for I := 1 to Length(AChunk) do
    if AChunk[I] = #10 then
    begin
      Push(Copy(FPartial, 1, FPartialLen), FPartialOverflow);
      FPartialLen := 0;
      FPartialOverflow := False;
    end
    else if FPartialLen < FMax then
    begin
      // Amortized growth: appending char-by-char would be quadratic.
      if FPartialLen = Length(FPartial) then
        if FPartialLen = 0 then
          SetLength(FPartial, 256)
        else
          SetLength(FPartial, FPartialLen * 2);
      Inc(FPartialLen);
      FPartial[FPartialLen] := AChunk[I];
    end
    else
      FPartialOverflow := True; // consume to the newline, store nothing
end;

// One read from the handle; False (and EOF) when the input has ended.
function TStdioReader.ReadChunk: Boolean;
var
  Chunk: string;
  Got: LongInt;
begin
  SetLength(Chunk, READ_CHUNK);
  Got := FileRead(FHandle, Chunk[1], READ_CHUNK);
  if Got <= 0 then
  begin
    FEOF := True;
    // A last line without its LF still counts, as before.
    if (FPartialLen > 0) or FPartialOverflow then
    begin
      Push(Copy(FPartial, 1, FPartialLen), FPartialOverflow);
      FPartialLen := 0;
      FPartialOverflow := False;
    end;
    Exit(False);
  end;
  SetLength(Chunk, Got);
  Feed(Chunk);
  Result := True;
end;

// Whether a read would return at once: data or EOF is waiting.
function TStdioReader.DataWaiting: Boolean;
{$IFDEF UNIX}
var
  ReadSet: TFDSet;
begin
  fpFD_ZERO(ReadSet);
  fpFD_SET(FHandle, ReadSet);
  Result := fpSelect(FHandle + 1, @ReadSet, nil, nil, 0) > 0;
end;
{$ELSE}
{$IFDEF WINDOWS}
var
  Available: DWORD;
begin
  case GetFileType(FHandle) of
    FILE_TYPE_PIPE:
      Result := PeekNamedPipe(FHandle, nil, 0, nil, @Available, nil) and
        (Available > 0);
    FILE_TYPE_DISK:
      Result := True;
  else
    // A console cannot be peeked without consuming key events.
    Result := False;
  end;
end;
{$ELSE}
begin
  Result := False;
end;
{$ENDIF}
{$ENDIF}

procedure TStdioReader.TakeWaiting;
begin
  while not FEOF and DataWaiting do
    if not ReadChunk then
      Break;
end;

function TStdioReader.NextLine(out ALine: string;
  out AOverflow: Boolean): Boolean;
begin
  while (FHead >= Length(FQueue)) and not FEOF do
    ReadChunk;
  if FHead >= Length(FQueue) then
  begin
    ALine := '';
    AOverflow := False;
    Exit(False);
  end;
  ALine := FQueue[FHead].Line;
  AOverflow := FQueue[FHead].Overflow;
  Inc(FHead);
  if FHead = Length(FQueue) then
  begin
    FQueue := nil;
    FHead := 0;
  end;
  Result := True;
end;

// A cancellation notification: cheap text check first, parse second.
function IsCancellationLine(const ALine: string): Boolean;
var
  Msg: TJSONRPCMessage;
begin
  Result := False;
  if Pos('notifications/cancelled', ALine) = 0 then
    Exit;
  Msg := ParseJSONRPCMessage(ALine);
  try
    Result := (Msg.Kind = jrkNotification) and
      (Msg.Method = 'notifications/cancelled');
  finally
    FreeJSONRPCMessage(Msg);
  end;
end;

function TStdioReader.TakeCancellations: TStringArray;
var
  I, Kept: Integer;
begin
  Result := nil;
  Kept := FHead;
  for I := FHead to High(FQueue) do
    if not FQueue[I].Overflow and IsCancellationLine(FQueue[I].Line) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := FQueue[I].Line;
    end
    else
    begin
      FQueue[Kept] := FQueue[I];
      Inc(Kept);
    end;
  SetLength(FQueue, Kept);
end;

type
  TStdioPollState = record
    Server: TMCPServer;
    Reader: TStdioReader;
  end;
  PStdioPollState = ^TStdioPollState;

// The session's cancellation poll (#93): a notifications/cancelled that
// arrived while the handler runs is handed to the core at once, which
// cancels the active request the ordinary way. Every other line stays
// queued, in order, for the loop.
function StdioCancellationPoll(ASession: TMCPSession;
  AUserData: Pointer): Boolean;
var
  Lines: TStringArray;
  I: Integer;
  Ignored: string;
begin
  Result := False;
  with PStdioPollState(AUserData)^ do
  begin
    Reader.TakeWaiting;
    Lines := Reader.TakeCancellations;
    for I := 0 to High(Lines) do
      Server.HandleMessage(ASession, Lines[I], Ignored);
  end;
end;

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
  Reader: TStdioReader;
  PollState: TStdioPollState;
begin
  Reader := TStdioReader.Create(TextRec(AInput).Handle, AMaxLineLength);
  Session := AServer.CreateSession;
  try
    PollState.Server := AServer;
    PollState.Reader := Reader;
    Session.SetCancellationPoll(StdioCancellationPoll, @PollState);
    while Reader.NextLine(Line, Overflow) do
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
    Reader.Free;
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
