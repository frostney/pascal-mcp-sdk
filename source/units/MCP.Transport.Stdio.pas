unit MCP.Transport.Stdio;

// stdio transport binding (spec revision 2026-07-28): newline-delimited
// JSON-RPC over the standard streams of a client-launched subprocess.
// This unit is a deliberately thin shell — every protocol decision
// lives in MCP.Server.HandleMessage; here we create one session for
// the connection and move lines. Each call supplies its output sink,
// so no transport state resides on the shared server; the session
// keeps only the loop's cancellation poll and its state (#93).
//
// Binding rules implemented (spec .../draft/basic/transports/stdio,
// verified 2026-07-21):
//   - one UTF-8 JSON-RPC message per line, no embedded newlines
//     (fpjson escapes newlines inside strings, so serialized responses
//     are single-line by construction); UTF-8 setup lives in MCP.JSONRPC,
//     and the loop sets its Text files to UTF-8 (#102);
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
// the response, flush. On a plain file input (stdin, a file, a pipe)
// the loop reads the handle into its own buffer, not through Text, so
// cancellation can reach a running handler (#93): whenever the handler
// asks ACtx.IsCancelled, the session's cancellation poll checks the
// lines already queued, then reads at most one chunk that is waiting,
// without blocking (poll on Unix, PeekNamedPipe on Windows), and hands
// a notifications/cancelled the core accepts for the running request
// is taken from the queue and cancels it. Every other line, a
// cancellation for a queued request included, stays queued in order. Once about one line's
// budget is queued the poll stops reading and the rest waits in the
// operating system's pipe. A Text with its own I/O driver is read
// through Text as before, without mid-request cancellation. No thread
// is involved, so a stdio-only program needs no thread driver.
//
// Push streams (events/stream, #126) live in the same loop: a handler
// parks one with the session's stream host, and the loop keeps it,
// waiting for input no longer than the next stream is due and stepping
// the due streams between lines, so other requests and streams carry
// on. A notifications/cancelled for an open stream removes it and sends
// nothing more; the end of input ends every stream. A Text with its own
// driver, or a Windows console, cannot be waited on with a time limit,
// so that loop offers no stream host.
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
  fpjson,
  MCP.JSONRPC,
  MCP.Streams;

const
  READ_CHUNK = 65536;
  // What a queued line costs besides its bytes, so empty and short
  // lines count against the queue's budget too.
  QUEUE_ENTRY_COST = 64;

type
  PText = ^Text;

  TQueuedLine = record
    Line: string;
    Overflow: Boolean;
    // The requestId of a notifications/cancelled the core would accept
    // (MCPCancellationTarget), owned; nil for any other line. Set once,
    // when the line is classified.
    CancelId: TJSONData;
  end;

  // The loop's input (#93). On a plain file Text (stdin, a file, a
  // pipe) it reads the handle directly, into its own buffer, so a poll
  // can take what is waiting without blocking and without the Text
  // buffer holding back what was already read; bytes the Text had
  // buffered before the loop started are taken over first. A Text with
  // its own I/O driver is read through Text as before, without
  // mid-request cancellation. Complete lines wait in a queue in arrival
  // order; the line being received grows until its LF, keeping at most
  // FMax bytes (the excess is consumed and the line flagged).
  TStdioReader = class
  private
    FInput: PText;
    FRaw: Boolean;
    FHandle: THandle;
    FMax: Integer;
    FQueueLimit: Int64;
    FQueue: array of TQueuedLine;
    FHead: Integer;
    FClassified: Integer; // entries before this index are classified
    FCancelCount: Integer;
    FQueuedBytes: Int64;
    FPartial: string;
    FPartialLen: Integer;
    FPartialOverflow: Boolean;
    FEOF: Boolean;
    FReadError: Integer;
    procedure Feed(const AChunk: string);
    procedure Push(const ALine: string; AOverflow: Boolean);
    procedure EndInput(AError: Integer);
    function ReadChunk(ABlocking: Boolean): Boolean;
    function DataWaiting: Boolean;
    procedure ClassifyQueued;
    function TakeQueuedCancellationOf(AId: TJSONData): Boolean;
    procedure RemoveAt(AIndex: Integer);
    procedure Compact;
  public
    constructor Create(var AInput: Text; AMax: Integer);
    destructor Destroy; override;
    // The next line, blocking until one is complete; False at the end
    // of input. Raises EInOutError when reading failed.
    function NextLine(out ALine: string; out AOverflow: Boolean): Boolean;
    // Reads at most one chunk that is already waiting, while fewer than
    // FQueueLimit bytes are queued; True when something was read.
    function ReadWaitingChunk: Boolean;
    // Whether the loop can wait for input with a time limit (#126): a
    // raw handle the platform can poll (on Windows a pipe or a disk
    // file, not a console), so push streams can step between lines.
    function CanWait: Boolean;
    // True when a line is queued or the input ended, so NextLine returns
    // at once; False when ATimeoutMs passed first. Input that keeps
    // arriving without completing a line still returns at the deadline.
    function WaitForLine(ATimeoutMs: Int64): Boolean;
    // Takes a queued or waiting notifications/cancelled for AId (an open
    // stream's request id, borrowed) out of the input: True when one
    // was there (#126 review).
    function TakeCancellationOf(AId: TJSONData): Boolean;
    // Removes and returns the first queued notifications/cancelled line
    // the core would accept for the request ASession is running.
    function TakeActiveCancellation(ASession: TMCPSession;
      out ALine: string): Boolean;
  end;

var
  // The read function the RTL gives every plain file Text, taken at
  // initialization from a Text this unit opens on the null device, so a
  // host that installs its own driver on Input does not change it.
  PlainFileReadFunc: CodePointer = nil;

procedure FindPlainFileReadFunc;
var
  Probe: Text;
begin
  Assign(Probe, {$IFDEF WINDOWS}'NUL'{$ELSE}'/dev/null'{$ENDIF});
  try
    Reset(Probe);
  except
    // No null device: every input is then read through Text.
    on EInOutError do
      Exit;
  end;
  PlainFileReadFunc := TextRec(Probe).InOutFunc;
  try
    Close(Probe);
  except
    on EInOutError do;
  end;
end;

// Whether AInput is a plain file Text: any other read function is a
// custom driver whose handle means nothing here.
function IsPlainFileInput(var AInput: Text): Boolean;
begin
  Result := (PlainFileReadFunc <> nil) and
    (TextRec(AInput).Mode = fmInput) and
    (TextRec(AInput).InOutFunc = PlainFileReadFunc);
end;

constructor TStdioReader.Create(var AInput: Text; AMax: Integer);
var
  Buffered: string;
begin
  inherited Create;
  FInput := @AInput;
  FMax := AMax;
  // Backpressure: a poll stops reading once this much is queued, and
  // the rest waits in the operating system's pipe for the loop.
  FQueueLimit := Int64(AMax) + READ_CHUNK;
  FRaw := IsPlainFileInput(AInput);
  if not FRaw then
    Exit;
  FHandle := TextRec(AInput).Handle;
  // By byte offset: a buffer from SetTextBuf can be larger than the
  // TextBuf type BufPtr declares.
  with TextRec(AInput) do
    if BufPos < BufEnd then
    begin
      SetString(Buffered, PChar(BufPtr) + BufPos, BufEnd - BufPos);
      BufPos := BufEnd;
      Feed(Buffered);
    end;
end;

destructor TStdioReader.Destroy;
var
  I: Integer;
begin
  for I := FHead to High(FQueue) do
    FQueue[I].CancelId.Free;
  inherited Destroy;
end;

procedure TStdioReader.Push(const ALine: string; AOverflow: Boolean);
var
  Slot: Integer;
begin
  // The loop skips empty lines (a lone CR included), so they are not
  // queued at all.
  if not AOverflow and ((ALine = '') or (ALine = #13)) then
    Exit;
  Slot := Length(FQueue);
  SetLength(FQueue, Slot + 1);
  FQueue[Slot].Line := ALine;
  FQueue[Slot].Overflow := AOverflow;
  FQueue[Slot].CancelId := nil;
  Inc(FQueuedBytes, Length(ALine) + QUEUE_ENTRY_COST);
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

procedure TStdioReader.EndInput(AError: Integer);
begin
  FEOF := True;
  FReadError := AError;
  // A last line without its LF still counts at a clean end, as before;
  // after a failed read it may be cut short, so it is dropped.
  if (AError = 0) and ((FPartialLen > 0) or FPartialOverflow) then
  begin
    Push(Copy(FPartial, 1, FPartialLen), FPartialOverflow);
    FPartialLen := 0;
    FPartialOverflow := False;
  end;
end;

// Blocks until the handle is readable (or has ended).
procedure WaitReadable(AHandle: THandle);
{$IFDEF UNIX}
var
  Fd: pollfd;
begin
  Fd.fd := AHandle;
  Fd.events := POLLIN;
  Fd.revents := 0;
  fpPoll(@Fd, 1, -1);
end;
{$ELSE}
begin
end;
{$ENDIF}

// One read from the handle; False when nothing was read. A read that
// fails is the end of input, remembered for NextLine to report, except
// the normal ends: a closed pipe on Windows is EOF, and on Unix an
// interrupted read is retried and a would-block one waits when
// ABlocking (the loop), or returns at once from a poll.
function TStdioReader.ReadChunk(ABlocking: Boolean): Boolean;
var
  Chunk: string;
  Got: LongInt;
  Failure: Integer;
begin
  SetLength(Chunk, READ_CHUNK);
  repeat
    Got := FileRead(FHandle, Chunk[1], READ_CHUNK);
    if Got >= 0 then
      Break;
    {$IFDEF UNIX}
    Failure := fpgeterrno;
    if Failure = ESysEINTR then
      Continue;
    if Failure = ESysEAGAIN then
    begin
      if not ABlocking then
        Exit(False);
      WaitReadable(FHandle);
      Continue;
    end;
    {$ELSE}
    {$IFDEF WINDOWS}
    Failure := GetLastError;
    if Failure = ERROR_BROKEN_PIPE then
      Failure := 0;
    {$ELSE}
    Failure := 0;
    {$ENDIF}
    {$ENDIF}
    EndInput(Failure);
    Exit(False);
  until False;
  if Got = 0 then
  begin
    EndInput(0);
    Exit(False);
  end;
  SetLength(Chunk, Got);
  Feed(Chunk);
  Result := True;
end;

// Whether a read would return at once: data or the end is waiting.
function TStdioReader.DataWaiting: Boolean;
{$IFDEF UNIX}
var
  Fd: pollfd;
begin
  // poll, not select: a descriptor above 1023 fits no TFDSet.
  Fd.fd := FHandle;
  Fd.events := POLLIN;
  Fd.revents := 0;
  Result := fpPoll(@Fd, 1, 0) > 0;
end;
{$ELSE}
{$IFDEF WINDOWS}
var
  Available: DWORD;
begin
  case GetFileType(FHandle) of
    FILE_TYPE_PIPE:
      // A failed peek is a closed pipe: the read returns at once.
      Result := not PeekNamedPipe(FHandle, nil, 0, nil, @Available, nil) or
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

function TStdioReader.ReadWaitingChunk: Boolean;
begin
  Result := FRaw and not FEOF and
    (FQueuedBytes + FPartialLen < FQueueLimit) and DataWaiting;
  if Result then
    ReadChunk(False);
end;

function TStdioReader.CanWait: Boolean;
begin
  Result := FRaw;
  {$IFDEF WINDOWS}
  if Result then
    Result := GetFileType(FHandle) in [FILE_TYPE_PIPE, FILE_TYPE_DISK];
  {$ENDIF}
end;

// Waits at most ATimeoutMs for the handle to become readable.
procedure WaitReadableFor(AHandle: THandle; ATimeoutMs: Int64);
{$IFDEF UNIX}
var
  Fd: pollfd;
begin
  if ATimeoutMs > MaxInt then
    ATimeoutMs := MaxInt;
  Fd.fd := AHandle;
  Fd.events := POLLIN;
  Fd.revents := 0;
  fpPoll(@Fd, 1, ATimeoutMs);
end;
{$ELSE}
begin
  // A pipe cannot be waited on: peek again after a short sleep.
  if ATimeoutMs > 10 then
    ATimeoutMs := 10;
  Sleep(ATimeoutMs);
end;
{$ENDIF}

function TStdioReader.WaitForLine(ATimeoutMs: Int64): Boolean;
var
  Deadline, Left: Int64;
begin
  Deadline := MCPNowMs + ATimeoutMs;
  repeat
    if (FHead < Length(FQueue)) or FEOF then
      Exit(True);
    // One read even when a stream is already due; then the deadline,
    // so a feed that never completes a line cannot starve the streams
    // (#126 review).
    if DataWaiting then
      ReadChunk(False)
    else
    begin
      Left := Deadline - MCPNowMs;
      if Left > 0 then
        WaitReadableFor(FHandle, Left);
    end;
    if (FHead < Length(FQueue)) or FEOF then
      Exit(True);
  until MCPNowMs >= Deadline;
  Result := False;
end;

// Read one LF-terminated line through Text, storing at most AMax bytes:
// the path for a Text with its own I/O driver. True when a line
// (possibly empty) was read; False on EOF with nothing read. AOverflow
// reports that the line exceeded AMax; the excess is consumed so the
// stream stays line-synchronized.
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
      if Len = Length(ALine) then
        if Len = 0 then
          SetLength(ALine, 256)
        else
          SetLength(ALine, Len * 2);
      Inc(Len);
      ALine[Len] := C;
    end
    else
      AOverflow := True;
  end;
  SetLength(ALine, Len);
  Result := True;
end;

function TStdioReader.NextLine(out ALine: string;
  out AOverflow: Boolean): Boolean;
var
  Failure: EInOutError;
begin
  if not FRaw then
    Exit(ReadBoundedLine(FInput^, FMax, ALine, AOverflow));
  while (FHead >= Length(FQueue)) and not FEOF do
    ReadChunk(True);
  if FHead >= Length(FQueue) then
  begin
    ALine := '';
    AOverflow := False;
    if FReadError <> 0 then
    begin
      Failure := EInOutError.CreateFmt('Reading the MCP input failed ' +
        '(error %d)', [FReadError]);
      Failure.ErrorCode := FReadError;
      raise Failure;
    end;
    Exit(False);
  end;
  ALine := FQueue[FHead].Line;
  AOverflow := FQueue[FHead].Overflow;
  // Released as it is taken: a long queue keeps no served lines.
  FQueue[FHead].Line := '';
  Dec(FQueuedBytes, Length(ALine) + QUEUE_ENTRY_COST);
  if FQueue[FHead].CancelId <> nil then
  begin
    FreeAndNil(FQueue[FHead].CancelId);
    Dec(FCancelCount);
  end;
  Inc(FHead);
  if FClassified < FHead then
    FClassified := FHead;
  if FHead = Length(FQueue) then
  begin
    FQueue := nil;
    FHead := 0;
    FClassified := 0;
  end
  else if FHead * 2 >= Length(FQueue) then
    Compact;
  Result := True;
end;

// Drops the served slots of a queue that never empties, so a sustained
// backlog keeps no more slots than lines waiting.
procedure TStdioReader.Compact;
var
  I: Integer;
begin
  for I := FHead to High(FQueue) do
  begin
    FQueue[I - FHead] := FQueue[I];
    FQueue[I].Line := '';
    FQueue[I].CancelId := nil;
  end;
  SetLength(FQueue, Length(FQueue) - FHead);
  Dec(FClassified, FHead);
  FHead := 0;
end;

// Classifies the queued lines not seen yet, once each: a
// notifications/cancelled the core would accept keeps its requestId
// (MCPCancellationTarget, the core's rule, method compared decoded, so
// an escaped spelling counts). The cheap text check only skips lines
// with neither the plain name nor any escape.
procedure TStdioReader.ClassifyQueued;
begin
  while FClassified < Length(FQueue) do
  begin
    with FQueue[FClassified] do
      if not Overflow and ((Pos('notifications/cancelled', Line) > 0) or
        (Pos('\', Line) > 0)) then
      begin
        CancelId := MCPCancellationTarget(Line);
        if CancelId <> nil then
          Inc(FCancelCount);
      end;
    Inc(FClassified);
  end;
end;

procedure TStdioReader.RemoveAt(AIndex: Integer);
var
  I: Integer;
begin
  Dec(FQueuedBytes, Length(FQueue[AIndex].Line) + QUEUE_ENTRY_COST);
  if FQueue[AIndex].CancelId <> nil then
  begin
    FreeAndNil(FQueue[AIndex].CancelId);
    Dec(FCancelCount);
  end;
  for I := AIndex to High(FQueue) - 1 do
    FQueue[I] := FQueue[I + 1];
  FQueue[High(FQueue)].Line := '';
  FQueue[High(FQueue)].CancelId := nil;
  SetLength(FQueue, Length(FQueue) - 1);
  Dec(FClassified);
end;

function TStdioReader.TakeActiveCancellation(ASession: TMCPSession;
  out ALine: string): Boolean;
var
  I: Integer;
begin
  ALine := '';
  ClassifyQueued;
  // The first one the core would accept for the running request: a
  // malformed one naming it was never classified as one (#93 review).
  if FCancelCount > 0 then
    for I := FHead to High(FQueue) do
      if (FQueue[I].CancelId <> nil) and
        ASession.IsActiveRequestId(FQueue[I].CancelId) then
      begin
        ALine := FQueue[I].Line;
        RemoveAt(I);
        Exit(True);
      end;
  Result := False;
end;

// A cancellation for AId among the queued lines, taken out.
function TStdioReader.TakeQueuedCancellationOf(AId: TJSONData): Boolean;
var
  I: Integer;
begin
  ClassifyQueued;
  if FCancelCount > 0 then
    for I := FHead to High(FQueue) do
      if (FQueue[I].CancelId <> nil) and
        SameRequestId(FQueue[I].CancelId, AId) then
      begin
        RemoveAt(I);
        Exit(True);
      end;
  Result := False;
end;

function TStdioReader.TakeCancellationOf(AId: TJSONData): Boolean;
begin
  Result := TakeQueuedCancellationOf(AId) or
    (ReadWaitingChunk and TakeQueuedCancellationOf(AId));
end;

type
  TStdioPollState = record
    Reader: TStdioReader;
  end;
  PStdioPollState = ^TStdioPollState;

// The session's cancellation poll (#93). The lines already queued are
// checked first, then at most one chunk that is waiting is read and
// checked: a notifications/cancelled the core accepts for the running
// request is taken out of the queue and the poll reports it, which
// cancels the request. It is not dispatched, so its reason is not
// logged: a stderr write must not hold up the handler's IsCancelled
// (#93 review). A cancellation for another request, and every other
// line, stays queued in order for the loop.
function StdioCancellationPoll(ASession: TMCPSession;
  AUserData: Pointer): Boolean;
var
  Line: string;
begin
  with PStdioPollState(AUserData)^ do
    Result := Reader.TakeActiveCancellation(ASession, Line) or
      (Reader.ReadWaitingChunk and
      Reader.TakeActiveCancellation(ASession, Line));
end;

// Notification sink: in-request notifications (progress, log
// messages) are written to the same output stream as responses, one
// line each, flushed immediately so they precede the response.
procedure StdioNotificationSink(const ALine: string; AUserData: Pointer);
begin
  Write(PText(AUserData)^, ALine, #10);
  Flush(PText(AUserData)^);
end;

type
  // The loop's open push streams (#126), each with the time it is next
  // due, stepped between lines on the one thread.
  // An open stream's live cancellation check: a notifications/cancelled
  // for it that is queued or waiting on stdin while the stream steps.
  TStdioStreamProbe = class
  private
    FReader: TStdioReader; // borrowed
    FId: TJSONData;        // borrowed: the stream's
  public
    constructor Create(AReader: TStdioReader; AId: TJSONData);
    function Cancelled: Boolean;
  end;

  TStdioStreams = class
  private
    FReader: TStdioReader; // borrowed
    FStreams: array of TMCPStream; // owned
    FProbes: array of TStdioStreamProbe; // owned
    FDue: array of Int64;
    procedure Drop(AIndex: Integer);
  public
    constructor Create(AReader: TStdioReader);
    destructor Destroy; override;
    function Count: Integer;
    // Takes ownership of AStream and steps it at once (its first frame).
    procedure Add(AStream: TMCPStream; var AOutput: Text);
    procedure StepDue(var AOutput: Text);
    // Milliseconds until the next stream is due (0 when one is).
    function NextWait: Int64;
    // A notifications/cancelled for an open stream ends it, and nothing
    // more is sent (events.mdx, Lifecycle); True when ALine was one.
    function Cancels(const ALine: string): Boolean;
  end;

constructor TStdioStreamProbe.Create(AReader: TStdioReader; AId: TJSONData);
begin
  inherited Create;
  FReader := AReader;
  FId := AId;
end;

function TStdioStreamProbe.Cancelled: Boolean;
begin
  Result := FReader.TakeCancellationOf(FId);
end;

constructor TStdioStreams.Create(AReader: TStdioReader);
begin
  inherited Create;
  FReader := AReader;
end;

destructor TStdioStreams.Destroy;
var
  I: Integer;
begin
  // The input ended: every stream ends with it.
  for I := 0 to High(FStreams) do
  begin
    FStreams[I].Cancel;
    FStreams[I].Free;
    FProbes[I].Free;
  end;
  inherited Destroy;
end;

function TStdioStreams.Count: Integer;
begin
  Result := Length(FStreams);
end;

procedure TStdioStreams.Drop(AIndex: Integer);
var
  I: Integer;
begin
  FStreams[AIndex].Free;
  FProbes[AIndex].Free;
  for I := AIndex to High(FStreams) - 1 do
  begin
    FStreams[I] := FStreams[I + 1];
    FProbes[I] := FProbes[I + 1];
    FDue[I] := FDue[I + 1];
  end;
  SetLength(FStreams, Length(FStreams) - 1);
  SetLength(FProbes, Length(FProbes) - 1);
  SetLength(FDue, Length(FDue) - 1);
end;

procedure TStdioStreams.Add(AStream: TMCPStream; var AOutput: Text);
begin
  SetLength(FStreams, Length(FStreams) + 1);
  SetLength(FProbes, Length(FProbes) + 1);
  SetLength(FDue, Length(FDue) + 1);
  FStreams[High(FStreams)] := AStream;
  FProbes[High(FProbes)] := TStdioStreamProbe.Create(FReader, AStream.Id);
  AStream.CancelProbe := FProbes[High(FProbes)].Cancelled;
  FDue[High(FDue)] := MCPNowMs;
  StepDue(AOutput);
end;

procedure TStdioStreams.StepDue(var AOutput: Text);
var
  I: Integer;
begin
  I := 0;
  while I < Length(FStreams) do
  begin
    if FDue[I] <= MCPNowMs then
    begin
      try
        FDue[I] := FStreams[I].Step(StdioNotificationSink, @AOutput);
      except
        // A failed stdout write is the whole loop's end; anything else
        // ends only this stream.
        on EInOutError do
          raise;
        on E: Exception do
        begin
          MCPLogToStderr('events stream ended: ' + E.ClassName + ': ' +
            E.Message);
          FStreams[I].Cancel;
        end;
      end;
      if FStreams[I].Finished then
      begin
        Drop(I);
        Continue;
      end;
    end;
    Inc(I);
  end;
end;

function TStdioStreams.NextWait: Int64;
var
  I: Integer;
  Now: Int64;
begin
  Result := High(Int64);
  Now := MCPNowMs;
  for I := 0 to High(FDue) do
    if FDue[I] - Now < Result then
      Result := FDue[I] - Now;
  if Result < 0 then
    Result := 0;
end;

function TStdioStreams.Cancels(const ALine: string): Boolean;
var
  Target: TJSONData;
  I: Integer;
begin
  Result := False;
  // The reader's own filter: only a line that may be a cancellation is
  // parsed twice (#126 review).
  if (Length(FStreams) = 0) or ((Pos('notifications/cancelled', ALine) = 0)
    and (Pos('\', ALine) = 0)) then
    Exit;
  Target := MCPCancellationTarget(ALine);
  if Target = nil then
    Exit;
  try
    for I := 0 to High(FStreams) do
      if SameRequestId(FStreams[I].Id, Target) then
      begin
        FStreams[I].Cancel;
        Drop(I);
        Exit(True);
      end;
  finally
    Target.Free;
  end;
end;

procedure RunMCPStdioLoop(var AInput, AOutput: Text; AServer: TMCPServer;
  AMaxLineLength: Integer);
var
  Line, Response: string;
  Overflow, Produced: Boolean;
  Session: TMCPSession;
  Reader: TStdioReader;
  PollState: TStdioPollState;
  SavedCodePage: TSystemCodePage;
  Host: TMCPStreamHost;
  Streams: TStdioStreams;
  Parked: TMCPStream;
begin
  // The wire is UTF-8 whatever the locale: a Text file converts what
  // it writes to its own code page, which the RTL took from the locale
  // at startup (US-ASCII under LC_ALL=C, turning every non-ASCII byte
  // into '?'). AOutput is the caller's, so its code page is restored on
  // return. AInput needs none: the reader takes its handle's bytes as
  // they are.
  // The raw field: restoring through SetTextCodePage would turn a saved
  // 0 into DefaultSystemCodePage.
  SavedCodePage := TextRec(AOutput).CodePage;
  SetTextCodePage(AOutput, CP_UTF8);
  try
    Session := AServer.CreateSession;
    Reader := nil;
    Host := nil;
    Streams := nil;
    try
      Reader := TStdioReader.Create(AInput, AMaxLineLength);
      PollState.Reader := Reader;
      Session.SetCancellationPoll(StdioCancellationPoll, @PollState);
      Streams := TStdioStreams.Create(Reader);
      // Push streams need a loop that can wait with a time limit; a Text
      // with its own driver, or a Windows console, cannot (#126).
      if Reader.CanWait then
      begin
        Host := TMCPStreamHost.Create;
        Session.StreamHost := Host;
      end;
      repeat
        if Streams.Count > 0 then
        begin
          Streams.StepDue(AOutput);
          if (Streams.Count > 0) and not Reader.WaitForLine(Streams.NextWait)
          then
            Continue;
        end;
        if not Reader.NextLine(Line, Overflow) then
          Break;
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
        if (Line = '') or Streams.Cancels(Line) then
          Continue;
        Produced := AServer.HandleMessage(Session, Line,
          StdioNotificationSink, @AOutput, Response);
        Parked := nil;
        if Host <> nil then
          Parked := Host.TakeParked;
        // A stream's handler answers with a placeholder: the stream
        // writes its own frames from here on, unless the request was
        // cancelled and the core answers nothing (#126 review).
        if (Parked <> nil) and Produced then
          Streams.Add(Parked, AOutput)
        else if Parked <> nil then
        begin
          Parked.Cancel;
          Parked.Free;
        end
        else if Produced then
        begin
          Write(AOutput, Response, #10);
          Flush(AOutput);
        end;
      until False;
    finally
      Streams.Free;
      Session.Free;
      Host.Free;
      Reader.Free;
    end;
  finally
    TextRec(AOutput).CodePage := SavedCodePage;
  end;
end;

procedure RunMCPStdioServer(AServer: TMCPServer; AMaxLineLength: Integer);
begin
  RunMCPStdioLoop(Input, Output, AServer, AMaxLineLength);
end;

procedure MCPLogToStderr(const AMessage: string);
begin
  // The library's one stderr writer: locked, UTF-8 unless stderr is a
  // Windows console, and the host's code page restored afterwards.
  MCPWriteStderrLine(AMessage);
end;

initialization
  FindPlainFileReadFunc;

end.
