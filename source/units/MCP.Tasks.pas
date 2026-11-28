{ MCP.Tasks — the Tasks extension (io.modelcontextprotocol/tasks, #82)
  on the 2026-07-28 revision. A tools/call the server lets run as a task
  is answered at once with a CreateTaskResult, while the tool's handler
  runs on a thread of its own; the client polls tasks/get, answers the
  task's input requests with tasks/update, and may cancel it with
  tasks/cancel. Verified 2026-11-28 against
  modelcontextprotocol/ext-tasks specification/2026-07-28/tasks.md at
  cc9aaac (v0.2.3; SEP-2663).

  Which calls become tasks is the server's decision, per call: a tool
  set to tsOptional runs as a task when the request declares the
  extension and as usual otherwise, one set to tsRequired only as a task
  (-32021 for a request that does not declare it), and a selector can
  decide per call, such as after a first round of input. A task's
  handler is the tool's ordinary handler. When it asks for input
  (MCPInputRequired), the task waits in input_required with those
  requests, under keys unique over its lifetime, until tasks/update has
  answered every one; the handler then runs again with the answers and
  its requestState, as for a retried call; a round that asks for nothing
  runs again at once with its state. The questions are checked against
  the capabilities of the request that polls for them. Tasks live in
  this process's memory until their ttlMs ends. A subscriptions/listen
  stream that lists taskIds gets notifications/tasks with a task's whole
  state after each change (Task Status Notifications, #138;
  MCP.Subscriptions).
}

unit MCP.Tasks;

{$I MCP.inc}

interface

uses
  Classes,
  SysUtils,

  fpjson,
  MCP.Protocol,
  MCP.Server;

const
  MCP_TASKS_EXTENSION = 'io.modelcontextprotocol/tasks';
  // How long a task stays readable after it was created, and the poll
  // interval suggested to clients, unless set otherwise.
  MCP_TASK_DEFAULT_TTL_MS = 3600000;
  // The longest ttlMs: the largest integer a JSON number carries exactly.
  MCP_TASK_MAX_TTL_MS = 9007199254740991;
  MCP_TASK_DEFAULT_POLL_INTERVAL_MS = 1000;
  // Tasks not yet finished at once, and tasks kept in all, finished ones
  // included, unless set otherwise.
  MCP_TASK_DEFAULT_MAX_ACTIVE = 32;
  MCP_TASK_DEFAULT_MAX_KEPT = 1000;

type
  // Whether a tools/call may run as a task: never (tsNone, the default),
  // when the request declares the extension and as usual otherwise
  // (tsOptional), or only as a task (tsRequired).
  TMCPTaskSupport = (tsNone, tsOptional, tsRequired);

  // Decides for one tools/call, before its handler runs: AArguments and
  // everything ACtx borrows are valid for the call only. ACtx carries the
  // call's input responses when it retries an input round, so a tool can
  // gather input first and run as a task after.
  TMCPTaskSelector = function(const AToolName: string; AArguments: TJSONObject;
    const ACtx: TMCPRequestContext): TMCPTaskSupport;
  TMCPTaskSelectorMethod = function(const AToolName: string;
    AArguments: TJSONObject;
    const ACtx: TMCPRequestContext): TMCPTaskSupport of object;

  TMCPTasks = class
  private
    FServer: TMCPServer; // borrowed: the server owns this object
    FLock: TRTLCriticalSection;
    FTools: TJSONObject; // tool name: TMCPTaskSupport as an integer
    FSelector: TMCPTaskSelector;
    FSelectorMethod: TMCPTaskSelectorMethod;
    FTtlMs: Int64;
    FPollIntervalMs: Integer;
    FMaxActive: Integer;
    FMaxKept: Integer;
    FTasks: TList; // TTaskEntry, owned, oldest first
    FRetired: TList; // TTaskEntry, owned: out of reach, worker still running
    FReaped: TList; // TTaskEntry, owned: worker done, to free outside FLock
    FDrained: TList; // TTaskEntry, owned: every entry, once Drain has run
    // Workers done whose task is still kept: joined and freed outside
    // FLock, so a finished task holds no thread (#82 review).
    FIdle: TList; // TTaskWorker, owned
    // The listen streams' task feeds (TTaskFeed, borrowed: each stream
    // owns its feed), told of every change under FLock (#138).
    FFeeds: TList;
    FDraining: Boolean;
    procedure EnsureMutable;
    // Under FLock: queues AEntry's state for each feed that follows it.
    procedure Changed(AEntry: TObject);
    procedure SetTtlMs(AValue: Int64);
    procedure SetPollIntervalMs(AValue: Integer);
    procedure SetMaxActive(AValue: Integer);
    procedure SetMaxKept(AValue: Integer);
    function SupportFor(const AToolName: string; AArguments: TJSONObject;
      const ACtx: TMCPRequestContext): TMCPTaskSupport;
    // Under FLock: retires tasks past their ttlMs, and moves retired ones
    // whose worker has stopped to FReaped.
    procedure Purge;
    // Joins and frees what Purge reaped, outside FLock: a join on Windows
    // may run synchronized callbacks (#82 review).
    procedure Reap;
    // Tasks whose worker has not stopped, retired ones included.
    function ActiveCount: Integer;
    // Cancels every task and waits for its handler, before the server
    // frees anything (TMCPDrain).
    procedure Drain;
    function FindEntry(const ATaskId: string): TObject;
    function TaskFor(AParams: TJSONObject; const ACtx: TMCPRequestContext;
      ALegacy: Boolean; const AMethod: string): TObject;
    function ToolCall(const AToolName: string; AArguments: TJSONObject;
      const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
    function GetTask(AParams: TJSONObject; const ACtx: TMCPRequestContext;
      ALegacy: Boolean): TJSONObject;
    function UpdateTask(AParams: TJSONObject; const ACtx: TMCPRequestContext;
      ALegacy: Boolean): TJSONObject;
    function CancelTask(AParams: TJSONObject; const ACtx: TMCPRequestContext;
      ALegacy: Boolean): TJSONObject;
  public
    constructor Create(AServer: TMCPServer);
    // Frees the tasks; the server has drained them already (EnableTasks
    // sets the drain), cancelling every task and waiting for its handler
    // to return, so a handler that never asks IsCancelled holds the
    // server's destruction up until it ends.
    destructor Destroy; override;
    // Tool AToolName (registered already) runs as a task as ASupport
    // says, unless a selector decides for it. An unknown tool or a
    // started server raises EMCPServer.
    procedure SetToolSupport(const AToolName: string;
      ASupport: TMCPTaskSupport);
    // Decides for every call in place of SetToolSupport; nil for none.
    // Setting one replaces the other.
    procedure SetSelector(ASelector: TMCPTaskSelector); overload;
    procedure SetSelector(ASelector: TMCPTaskSelectorMethod); overload;
    // A task's ttlMs: how long after creation it stays readable (1 to
    // MCP_TASK_MAX_TTL_MS). A task still running then is cancelled, and
    // dropped at the next request to the task store.
    property TtlMs: Int64 read FTtlMs write SetTtlMs;
    // The pollIntervalMs suggested to clients (at least 1).
    property PollIntervalMs: Integer read FPollIntervalMs
      write SetPollIntervalMs;
    // Tasks whose handler has not returned at once, cancelled and expired
    // ones included (at least 1); a call past it runs as usual when its
    // tool allows that, and is refused with -32603 otherwise.
    property MaxActive: Integer read FMaxActive write SetMaxActive;
    // Tasks kept in all until their ttlMs ends (at least MaxActive); a
    // call past it is treated as past MaxActive. No task goes before its
    // ttlMs ends.
    property MaxKept: Integer read FMaxKept write SetMaxKept;
  end;

// Turns the Tasks extension on for AServer, before it starts, and returns
// its settings (owned by the server; calling again returns the same
// object): server/discover declares io.modelcontextprotocol/tasks, and
// tasks/get, tasks/update and tasks/cancel are served, for 2026-07-28
// requests that declare the extension (-32021 for those that do not; a
// classic-handshake client gets -32601). On Streamable HTTP these carry
// Mcp-Name with the taskId. Task handlers run on threads, so on Unix the
// program lists cthreads first in its uses clause; without it this raises
// EMCPServer, as does a first call after the server started (a later
// call returns the same settings, whose setters then raise).
function EnableTasks(AServer: TMCPServer): TMCPTasks;

implementation

uses
  DateUtils,

  MCP.Content,
  MCP.Crypto,
  MCP.Errors,
  MCP.JSONRPC,
  MCP.Streams,
  MCP.Subscriptions;

type
  TTaskStatus = (tkWorking, tkInputRequired, tkCompleted, tkFailed,
    tkCancelled);

const
  STATUS_NAMES: array[TTaskStatus] of string = ('working', 'input_required',
    'completed', 'failed', 'cancelled');
  TASK_METHODS: array[0..2] of string = ('tasks/get', 'tasks/update',
    'tasks/cancel');
  // How often a parked worker looks for its answers and its deadline. It
  // sleeps rather than waiting on an event: the RTL turns an event's
  // timeout into a wall-clock deadline, which a clock stepped back
  // stretches, while a sleep is relative (#82 review).
  PARK_POLL_MS = 25;
  // Every capability an input request can need, so the kind check alone
  // decides at Park; the poll's own capabilities decide what is sent.
  EVERY_INPUT_CAPABILITY = '{"elicitation":{"form":{},"url":{}},' +
    '"sampling":{"tools":{}},"roots":{}}';

type
  TTaskWorker = class;

  // One task. FOwner's lock guards every field a worker and a request
  // both reach; the tool name, arguments, request _meta, client and
  // deadline never change after creation.
  TTaskEntry = class
  public
    Owner: TMCPTasks;
    Id: string;
    ToolName: string;
    Arguments: TJSONObject; // owned
    Meta: TJSONObject; // owned: the creating request's _meta
    ClientName, ClientVersion: string;
    Status: TTaskStatus;
    StatusMessage: string;
    CreatedAt, UpdatedAt: string;
    // On MCPNowMs: when the task was created and when its ttlMs ends.
    CreatedMs, DeadlineMs: Int64;
    // Counts every change tasks/get would show.
    Version: Int64;
    CallResult: TJSONObject; // owned: the CallToolResult once completed
    Error: TJSONObject; // owned: the JSON-RPC error once failed
    // The round in progress: surfaced key -> request (owned), surfaced
    // key -> the handler's key (owned), and the answers, under the
    // handler's keys (owned).
    Pending: TJSONObject;
    KeyMap: TJSONObject;
    Answers: TJSONObject;
    // Every key ever surfaced, so none is used twice, compared exactly.
    UsedKeys: TJSONObject;
    // What the next round of the handler starts with.
    NextResponses: TJSONObject; // owned; nil for none
    NextState: string;
    CancelRequested: Boolean;
    // Set under the lock when the worker's loop has ended; Joined once
    // its thread was joined, which happens once only (#82 review: a
    // second pthread_join is undefined).
    WorkerDone, Joined: Boolean;
    Worker: TTaskWorker; // owned
    constructor Create(AOwner: TMCPTasks);
    destructor Destroy; override;
    function Terminal: Boolean;
    // Under the lock.
    procedure SetStatus(AStatus: TTaskStatus; const AMessage: string = '');
    // The task changed (under the lock): lastUpdatedAt and Version.
    procedure Touch;
    // The Task fields (new); with ADetailed the status's own payload
    // too (result, error or inputRequests). Under the lock.
    function Snapshot(ADetailed: Boolean): TJSONObject;
    // Under the lock: tasks/cancel, the ttlMs ending or the server going
    // away.
    function Stopped: Boolean;
    // The handler's cancellation probe: Stopped, taking the lock.
    function IsCancelled: Boolean;
    function Running: Boolean;
  end;

  TTaskWorker = class(TThread)
  private
    FEntry: TTaskEntry;
    // A handler round: its run, or False when the handler raised and the
    // task failed.
    function RunRound(AResponses: TJSONObject; const AState: string;
      out ARun: TMCPToolRun): Boolean;
    procedure Fail(ACode: Integer; const AMessage: string; AData: TJSONData);
    procedure FailWith(E: EMCPProtocolError);
    procedure Complete(AResult: TJSONObject);
    // Holds the round's input requests (owned) for tasks/get: False when
    // the task ended instead.
    function Park(ARun: TMCPToolRun): Boolean;
    // Until tasks/update has answered every request: False when the task
    // ended first, or its ttlMs did.
    function AwaitAnswers(out AResponses: TJSONObject;
      out AState: string): Boolean;
    // The rounds of the task, until it ends.
    procedure Work;
  protected
    procedure Execute; override;
  public
    constructor Create(AEntry: TTaskEntry);
  end;

// Under the lock: every listen feed stops reaching the store (below).
procedure DetachFeeds(AFeeds: TList); forward;

function UtcStamp: string;
begin
  Result := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"."zzz"Z"',
    LocalTimeToUniversal(Now));
end;

function NewTaskId: string;
begin
  // 128 bits from the CSPRNG: task IDs act as bearer tokens for the
  // task's state, so they must not be guessable (Security
  // Considerations).
  Result := string(Base64UrlEncode(SecureRandomBytes(16)));
end;

function ExtensionRequired: EMCPProtocolError;
var
  Data, Capabilities, Extensions: TJSONObject;
begin
  Extensions := TJSONObject.Create([MCP_TASKS_EXTENSION, TJSONObject.Create]);
  Capabilities := TJSONObject.Create(['extensions', Extensions]);
  Data := TJSONObject.Create(['requiredCapabilities', Capabilities]);
  Result := EMCPProtocolError.Create(MCP_ERROR_MISSING_CLIENT_CAPABILITY,
    'Missing required client capability: the ' + MCP_TASKS_EXTENSION +
    ' extension', Data);
end;

function InvalidParams(const AWhat: string): EMCPProtocolError;
begin
  Result := EMCPProtocolError.Create(JSONRPC_INVALID_PARAMS,
    'Invalid params: ' + AWhat);
end;

// A copy of AData (borrowed) through its wire text, so what is stored can
// always be sent: a nil child becomes null, as the serializer writes it,
// and a value the serializer refuses (a non-finite number) raises here,
// once, instead of on every poll (#82 review).
function WireCopy(AData: TJSONData): TJSONData;
begin
  Result := MCPParseJSON(SerializeCompact(AData));
end;

{ TTaskEntry }

constructor TTaskEntry.Create(AOwner: TMCPTasks);
begin
  inherited Create;
  Owner := AOwner;
  KeyMap := TJSONObject.Create;
  UsedKeys := TJSONObject.Create;
end;

destructor TTaskEntry.Destroy;
begin
  Worker.Free;
  Arguments.Free;
  Meta.Free;
  CallResult.Free;
  Error.Free;
  Pending.Free;
  KeyMap.Free;
  Answers.Free;
  UsedKeys.Free;
  NextResponses.Free;
  inherited Destroy;
end;

function TTaskEntry.Terminal: Boolean;
begin
  Result := Status in [tkCompleted, tkFailed, tkCancelled];
end;

procedure TTaskEntry.SetStatus(AStatus: TTaskStatus; const AMessage: string);
begin
  Status := AStatus;
  StatusMessage := AMessage;
  Touch;
end;

procedure TTaskEntry.Touch;
begin
  UpdatedAt := UtcStamp;
  Inc(Version);
  Owner.Changed(Self);
end;

function TTaskEntry.Snapshot(ADetailed: Boolean): TJSONObject;
begin
  Result := TJSONObject.Create;
  try
    Result.Add('taskId', Id);
    Result.Add('status', STATUS_NAMES[Status]);
    if StatusMessage <> '' then
      Result.Add('statusMessage', StatusMessage);
    Result.Add('createdAt', CreatedAt);
    Result.Add('lastUpdatedAt', UpdatedAt);
    Result.Add('ttlMs', Owner.FTtlMs);
    Result.Add('pollIntervalMs', Owner.FPollIntervalMs);
    if not ADetailed then
      Exit;
    case Status of
      tkCompleted:
        Result.Add('result', CallResult.Clone);
      tkFailed:
        Result.Add('error', Error.Clone);
      tkInputRequired:
        Result.Add('inputRequests', Pending.Clone);
    end;
  except
    Result.Free;
    raise;
  end;
end;

function TTaskEntry.Stopped: Boolean;
begin
  Result := CancelRequested or Owner.FDraining or (MCPNowMs >= DeadlineMs);
end;

function TTaskEntry.IsCancelled: Boolean;
begin
  System.EnterCriticalSection(Owner.FLock);
  try
    Result := Stopped;
  finally
    System.LeaveCriticalSection(Owner.FLock);
  end;
end;

// Under the lock.
function TTaskEntry.Running: Boolean;
begin
  Result := (Worker <> nil) and not WorkerDone;
end;

// Joins AEntry's worker unless that happened already; outside the lock,
// and only once its thread is no longer needed by anyone else.
procedure Join(AEntry: TTaskEntry);
begin
  if (AEntry.Worker <> nil) and not AEntry.Joined then
  begin
    AEntry.Worker.WaitFor;
    AEntry.Joined := True;
  end;
end;

{ TTaskWorker }

constructor TTaskWorker.Create(AEntry: TTaskEntry);
begin
  FEntry := AEntry;
  inherited Create(True);
  FreeOnTerminate := False;
end;

procedure TTaskWorker.Fail(ACode: Integer; const AMessage: string;
  AData: TJSONData);
var
  Error: TJSONObject;
begin
  Error := TJSONObject.Create(['code', ACode, 'message', AMessage]);
  if AData <> nil then
    Error.Add('data', AData);
  System.EnterCriticalSection(FEntry.Owner.FLock);
  try
    if FEntry.Terminal then
      Error.Free
    else
    begin
      FEntry.Error := Error;
      FEntry.SetStatus(tkFailed, AMessage);
    end;
  finally
    System.LeaveCriticalSection(FEntry.Owner.FLock);
  end;
end;

// A handler's deliberate JSON-RPC error, answered as a request's would
// be (ProtocolErrorReply): its code, message and data, a -32021 whose
// data no longer validates becoming -32603 (#82 review).
procedure TTaskWorker.FailWith(E: EMCPProtocolError);
var
  Message: TJSONRPCMessage;
  Reply: TJSONData;
  Error: TJSONObject;
  LogLine: string;
begin
  Message := Default(TJSONRPCMessage);
  Message.Method := 'tasks/' + FEntry.ToolName;
  Reply := MCPParseJSON(ProtocolErrorReply(Message, E, LogLine));
  try
    if LogLine <> '' then
      MCPLogDiagnostic(LogLine);
    Error := TJSONObject(TJSONObject(Reply).Extract('error'));
  finally
    Reply.Free;
  end;
  System.EnterCriticalSection(FEntry.Owner.FLock);
  try
    if FEntry.Terminal then
      Error.Free
    else
    begin
      FEntry.Error := Error;
      FEntry.SetStatus(tkFailed, Error.Get('message', ''));
    end;
  finally
    System.LeaveCriticalSection(FEntry.Owner.FLock);
  end;
end;

function TTaskWorker.RunRound(AResponses: TJSONObject; const AState: string;
  out ARun: TMCPToolRun): Boolean;
var
  Ctx: TMCPRequestContext;
  Capabilities: TJSONData;
begin
  ARun := Default(TMCPToolRun);
  // The creating request's context, with nothing that ends with it: no
  // notifications (progress and logging are not delivered for tasks), no
  // stream, no request id; this task's input and its own cancellation.
  Ctx := Default(TMCPRequestContext);
  Ctx.ProtocolVersion := MCP_PROTOCOL_VERSION;
  Ctx.ClientName := FEntry.ClientName;
  Ctx.ClientVersion := FEntry.ClientVersion;
  Ctx.Meta := FEntry.Meta;
  Capabilities := FEntry.Meta.Find(META_KEY_CLIENT_CAPABILITIES);
  if (Capabilities <> nil) and (Capabilities.JSONType = jtObject) then
    Ctx.ClientCapabilities := TJSONObject(Capabilities);
  Ctx.InputResponses := AResponses;
  Ctx.RequestState := AState;
  Ctx.CancellationProbe := FEntry.IsCancelled;
  try
    ARun := FEntry.Owner.FServer.RunTool(FEntry.ToolName, FEntry.Arguments,
      Ctx);
    Result := True;
  except
    // A JSON-RPC error during execution fails the task with that error
    // (Task Execution Errors); a fault the server would answer -32603.
    on E: EMCPProtocolError do
    begin
      FailWith(E);
      Result := False;
    end;
    on E: Exception do
    begin
      Fail(JSONRPC_INTERNAL_ERROR, FEntry.Owner.FServer.ClientFaultMessage(
        'tasks/' + FEntry.ToolName, E), nil);
      Result := False;
    end;
  end;
end;

procedure TTaskWorker.Complete(AResult: TJSONObject);
var
  Stored: TJSONData;
begin
  try
    // The result the call would have answered, stamped as it would have
    // been (#82 review): resultType and the serverInfo _meta.
    StampResult(AResult, FEntry.Owner.FServer.Name,
      FEntry.Owner.FServer.Version);
    Stored := WireCopy(AResult);
  finally
    AResult.Free;
  end;
  System.EnterCriticalSection(FEntry.Owner.FLock);
  try
    // A cancelled task keeps its status; the late result is dropped.
    if FEntry.Terminal then
      Stored.Free
    else
    begin
      FEntry.CallResult := TJSONObject(Stored);
      FEntry.SetStatus(tkCompleted);
    end;
  finally
    System.LeaveCriticalSection(FEntry.Owner.FLock);
  end;
end;

// Why the first request in ARequests lacks what its kind requires, ''
// when none does (#82 review): elicitation/create a message and, in url
// mode, a url, otherwise a requestedSchema object; sampling/createMessage
// a messages array and a numeric maxTokens; roots/list nothing, though
// its params, when present, are an object too. Field requirements from
// the 2026-07-28 schema (ElicitRequestFormParams, ElicitRequestURLParams,
// CreateMessageRequestParams), verified 2026-11-28.
function MalformedRequest(ARequests: TJSONObject): string;
var
  I: Integer;
  Request: TJSONObject;
  Params: TJSONData;
  P: TJSONObject;
  Method: string;

  function Has(const AName: string; AType: TJSONtype): Boolean;
  begin
    Result := (P.Find(AName) <> nil) and (P.Find(AName).JSONType = AType);
  end;

begin
  Result := '';
  for I := 0 to ARequests.Count - 1 do
  begin
    Request := TJSONObject(ARequests.Items[I]);
    Method := Request.Get('method', '');
    Params := Request.Find('params');
    if Params = nil then
    begin
      if Method <> 'roots/list' then
        Exit(Method + ' without its params');
      Continue;
    end;
    if Params.JSONType <> jtObject then
      Exit(Method + ' params that are no object');
    P := TJSONObject(Params);
    if (Method = 'elicitation/create') and (not Has('message', jtString) or
      ((P.Get('mode', 'form') = 'url') and not Has('url', jtString)) or
      ((P.Get('mode', 'form') <> 'url') and
      not Has('requestedSchema', jtObject))) then
      Exit(Method + ' without its message, url or requestedSchema');
    if (Method = 'sampling/createMessage') and
      (not Has('messages', jtArray) or not Has('maxTokens', jtNumber)) then
      Exit(Method + ' without its messages or maxTokens');
  end;
end;

function TTaskWorker.Park(ARun: TMCPToolRun): Boolean;
var
  Unknown, Member, Key, Surfaced, Malformed: string;
  Requests, Every: TJSONObject;
  I, Suffix: Integer;
  Ctx: TMCPRequestContext;
begin
  ARun.Meta.Free;
  Requests := nil;
  Every := nil;
  try
    Requests := TJSONObject(WireCopy(ARun.InputRequests));
    FreeAndNil(ARun.InputRequests);
    // Only kinds that are no input request at all fail the task here;
    // whether the client may get them is checked on each poll, against
    // the capabilities that poll declares (#82 review).
    Every := TJSONObject(MCPParseJSON(EVERY_INPUT_CAPABILITY));
    Ctx := Default(TMCPRequestContext);
    Ctx.ProtocolVersion := MCP_PROTOCOL_VERSION;
    Ctx.ClientCapabilities := Every;
    MissingInputCapability(Requests, Ctx, Unknown, Member);
    if Unknown <> '' then
    begin
      Fail(JSONRPC_INTERNAL_ERROR, 'Tool "' + FEntry.ToolName +
        '" produced an unsupported input request kind "' + Unknown + '"',
        nil);
      Exit(False);
    end;
    Malformed := MalformedRequest(Requests);
    if Malformed <> '' then
    begin
      Fail(JSONRPC_INTERNAL_ERROR, 'Tool "' + FEntry.ToolName +
        '" produced a malformed input request: ' + Malformed, nil);
      Exit(False);
    end;
    System.EnterCriticalSection(FEntry.Owner.FLock);
    try
      if FEntry.Terminal or FEntry.Stopped then
        Exit(False);
      // Keys stay unique over the task's lifetime (Task Update Requests):
      // a handler key answered in an earlier round is surfaced with a
      // suffix.
      FEntry.Pending := TJSONObject.Create;
      FEntry.KeyMap.Clear;
      FEntry.Answers := TJSONObject.Create;
      for I := 0 to Requests.Count - 1 do
      begin
        Key := Requests.Names[I];
        Surfaced := Key;
        Suffix := 1;
        while FEntry.UsedKeys.IndexOfName(Surfaced) >= 0 do
        begin
          Inc(Suffix);
          Surfaced := Key + '#' + IntToStr(Suffix);
        end;
        FEntry.UsedKeys.Add(Surfaced, True);
        FEntry.KeyMap.Add(Surfaced, Key);
        FEntry.Pending.Add(Surfaced, Requests.Items[I].Clone);
      end;
      FEntry.NextState := ARun.RequestState;
      FEntry.SetStatus(tkInputRequired);
      Result := True;
    finally
      System.LeaveCriticalSection(FEntry.Owner.FLock);
    end;
  finally
    ARun.InputRequests.Free;
    Requests.Free;
    Every.Free;
  end;
end;

function TTaskWorker.AwaitAnswers(out AResponses: TJSONObject;
  out AState: string): Boolean;
var
  Left: Int64;
begin
  AResponses := nil;
  AState := '';
  repeat
    // Every PARK_POLL_MS: the answers, tasks/cancel, the server going
    // away and the deadline, which no request needs to come for.
    System.EnterCriticalSection(FEntry.Owner.FLock);
    try
      if FEntry.Terminal or FEntry.Stopped then
        Exit(False);
      if FEntry.Pending.Count = 0 then
      begin
        AResponses := FEntry.Answers;
        FEntry.Answers := nil;
        FreeAndNil(FEntry.Pending);
        AState := FEntry.NextState;
        Exit(True);
      end;
    finally
      System.LeaveCriticalSection(FEntry.Owner.FLock);
    end;
    Left := FEntry.DeadlineMs - MCPNowMs;
    if Left > PARK_POLL_MS then
      Left := PARK_POLL_MS;
    if Left > 0 then
      Sleep(Left);
  until False;
end;

procedure TTaskWorker.Execute;
begin
  try
    try
      Work;
    except
      // Nothing escapes a worker: the task fails instead of staying
      // working until its ttlMs ends.
      on E: Exception do
        Fail(JSONRPC_INTERNAL_ERROR, FEntry.Owner.FServer.ClientFaultMessage(
          'tasks/' + FEntry.ToolName, E), nil);
    end;
  finally
    System.EnterCriticalSection(FEntry.Owner.FLock);
    FEntry.WorkerDone := True;
    System.LeaveCriticalSection(FEntry.Owner.FLock);
  end;
end;

procedure TTaskWorker.Work;
var
  Responses: TJSONObject;
  State: string;
  Run: TMCPToolRun;
begin
  System.EnterCriticalSection(FEntry.Owner.FLock);
  try
    Responses := FEntry.NextResponses;
    FEntry.NextResponses := nil;
    State := FEntry.NextState;
  finally
    System.LeaveCriticalSection(FEntry.Owner.FLock);
  end;
  repeat
    try
      // Each round starts only while the task may run (#82 review).
      if FEntry.IsCancelled or not RunRound(Responses, State, Run) then
        Exit;
    finally
      FreeAndNil(Responses);
    end;
    if not Run.InputRequired then
    begin
      Complete(Run.Result);
      Exit;
    end;
    // A round that asks for nothing runs again with its state, as a
    // client retries one (#82 review).
    if (Run.InputRequests = nil) or (Run.InputRequests.Count = 0) then
    begin
      Run.InputRequests.Free;
      Run.Meta.Free;
      State := Run.RequestState;
      Continue;
    end;
    if not Park(Run) or not AwaitAnswers(Responses, State) then
      Exit;
  until False;
end;

{ TMCPTasks }

constructor TMCPTasks.Create(AServer: TMCPServer);
begin
  inherited Create;
  FServer := AServer;
  InitCriticalSection(FLock);
  FTools := TJSONObject.Create;
  FTtlMs := MCP_TASK_DEFAULT_TTL_MS;
  FPollIntervalMs := MCP_TASK_DEFAULT_POLL_INTERVAL_MS;
  FMaxActive := MCP_TASK_DEFAULT_MAX_ACTIVE;
  FMaxKept := MCP_TASK_DEFAULT_MAX_KEPT;
  FTasks := TList.Create;
  FRetired := TList.Create;
  FReaped := TList.Create;
  FDrained := TList.Create;
  FIdle := TList.Create;
  FFeeds := TList.Create;
end;

// Cancels AEntry's handler and, at its next look, a parked worker (under
// the lock).
procedure Release(AEntry: TTaskEntry);
begin
  AEntry.CancelRequested := True;
end;

procedure TMCPTasks.Drain;
var
  I: Integer;
begin
  System.EnterCriticalSection(FLock);
  try
    // From here no task is admitted, and the store's lists are this
    // drain's alone: a handler that calls back into the store while it
    // is joined finds nothing to free (#82 review).
    FDraining := True;
    DetachFeeds(FFeeds);
    for I := 0 to FTasks.Count - 1 do
      FDrained.Add(FTasks[I]);
    for I := 0 to FRetired.Count - 1 do
      FDrained.Add(FRetired[I]);
    for I := 0 to FReaped.Count - 1 do
      FDrained.Add(FReaped[I]);
    FTasks.Clear;
    FRetired.Clear;
    FReaped.Clear;
    for I := 0 to FDrained.Count - 1 do
      Release(TTaskEntry(FDrained[I]));
  finally
    System.LeaveCriticalSection(FLock);
  end;
  // Outside the lock, which the workers take on their way out; only this
  // thread reaches FDrained now, and the idle workers.
  for I := 0 to FDrained.Count - 1 do
    Join(TTaskEntry(FDrained[I]));
  Reap;
end;

destructor TMCPTasks.Destroy;
var
  I: Integer;
begin
  // The server drained the tasks first; a TMCPTasks freed on its own
  // drains here. Either way every entry ends up in FDrained, joined.
  Drain;
  for I := 0 to FDrained.Count - 1 do
    TTaskEntry(FDrained[I]).Free;
  FTasks.Free;
  FRetired.Free;
  FReaped.Free;
  FDrained.Free;
  FIdle.Free;
  FFeeds.Free;
  FTools.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TMCPTasks.EnsureMutable;
var
  Problem: string;
begin
  Problem := FServer.HookProblem([], '');
  if Problem <> '' then
    raise EMCPServer.Create(Problem);
end;

procedure TMCPTasks.SetToolSupport(const AToolName: string;
  ASupport: TMCPTaskSupport);
begin
  EnsureMutable;
  if not FServer.HasTool(AToolName) then
    raise EMCPServer.CreateFmt('SetToolSupport: no tool named "%s" is ' +
      'registered', [AToolName]);
  // Names are matched exactly, case and all (#82 review).
  if FTools.IndexOfName(AToolName) >= 0 then
    FTools.Delete(FTools.IndexOfName(AToolName));
  FTools.Add(AToolName, Ord(ASupport));
end;

procedure TMCPTasks.SetSelector(ASelector: TMCPTaskSelector);
begin
  EnsureMutable;
  FSelector := ASelector;
  FSelectorMethod := nil;
end;

procedure TMCPTasks.SetSelector(ASelector: TMCPTaskSelectorMethod);
begin
  EnsureMutable;
  FSelectorMethod := ASelector;
  FSelector := nil;
end;

procedure TMCPTasks.SetTtlMs(AValue: Int64);
begin
  EnsureMutable;
  if (AValue < 1) or (AValue > MCP_TASK_MAX_TTL_MS) then
    raise EMCPServer.Create('TtlMs must be from 1 to MCP_TASK_MAX_TTL_MS');
  FTtlMs := AValue;
end;

procedure TMCPTasks.SetPollIntervalMs(AValue: Integer);
begin
  EnsureMutable;
  if AValue < 1 then
    raise EMCPServer.Create('PollIntervalMs must be at least 1');
  FPollIntervalMs := AValue;
end;

procedure TMCPTasks.SetMaxActive(AValue: Integer);
begin
  EnsureMutable;
  if (AValue < 1) or (AValue > FMaxKept) then
    raise EMCPServer.Create('MaxActive must be from 1 to MaxKept');
  FMaxActive := AValue;
end;

procedure TMCPTasks.SetMaxKept(AValue: Integer);
begin
  EnsureMutable;
  if AValue < FMaxActive then
    raise EMCPServer.Create('MaxKept must be at least MaxActive');
  FMaxKept := AValue;
end;

function TMCPTasks.SupportFor(const AToolName: string;
  AArguments: TJSONObject; const ACtx: TMCPRequestContext): TMCPTaskSupport;
begin
  if Assigned(FSelectorMethod) then
    Exit(FSelectorMethod(AToolName, AArguments, ACtx));
  if Assigned(FSelector) then
    Exit(FSelector(AToolName, AArguments, ACtx));
  Result := TMCPTaskSupport(FTools.Get(AToolName, Ord(tsNone)));
end;

procedure TMCPTasks.Purge;
var
  I: Integer;
  Entry: TTaskEntry;
begin
  for I := FRetired.Count - 1 downto 0 do
  begin
    Entry := TTaskEntry(FRetired[I]);
    if not Entry.Running then
    begin
      FRetired.Delete(I);
      FReaped.Add(Entry);
    end;
  end;
  // Past its ttlMs, a task may be deleted (Task Polling); one still
  // running is cancelled first, and stays counted until it stops. A kept
  // task whose worker is done gives its thread up.
  for I := FTasks.Count - 1 downto 0 do
  begin
    Entry := TTaskEntry(FTasks[I]);
    if (Entry.Worker <> nil) and Entry.WorkerDone then
    begin
      FIdle.Add(Entry.Worker);
      Entry.Worker := nil;
    end;
    if MCPNowMs >= Entry.DeadlineMs then
    begin
      FTasks.Delete(I);
      Release(Entry);
      FRetired.Add(Entry);
    end;
  end;
end;

procedure TMCPTasks.Reap;
var
  I: Integer;
  Entries, Workers: TList;
begin
  Workers := nil;
  Entries := TList.Create;
  try
    Workers := TList.Create;
    System.EnterCriticalSection(FLock);
    try
      for I := 0 to FReaped.Count - 1 do
        Entries.Add(FReaped[I]);
      FReaped.Clear;
      for I := 0 to FIdle.Count - 1 do
        Workers.Add(FIdle[I]);
      FIdle.Clear;
    finally
      System.LeaveCriticalSection(FLock);
    end;
    for I := 0 to Entries.Count - 1 do
    begin
      Join(TTaskEntry(Entries[I]));
      TTaskEntry(Entries[I]).Free;
    end;
    // Done already: the join returns at once.
    for I := 0 to Workers.Count - 1 do
    begin
      TTaskWorker(Workers[I]).WaitFor;
      TTaskWorker(Workers[I]).Free;
    end;
  finally
    Workers.Free;
    Entries.Free;
  end;
end;

function TMCPTasks.ActiveCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FTasks.Count - 1 do
    if TTaskEntry(FTasks[I]).Running then
      Inc(Result);
  for I := 0 to FRetired.Count - 1 do
    if TTaskEntry(FRetired[I]).Running then
      Inc(Result);
end;

function TMCPTasks.FindEntry(const ATaskId: string): TObject;
var
  I: Integer;
begin
  for I := 0 to FTasks.Count - 1 do
    if TTaskEntry(FTasks[I]).Id = ATaskId then
      Exit(TTaskEntry(FTasks[I]));
  Result := nil;
end;

function TMCPTasks.ToolCall(const AToolName: string; AArguments: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
var
  Support: TMCPTaskSupport;
  Entry: TTaskEntry;
  Full: Boolean;
begin
  Support := SupportFor(AToolName, AArguments, ACtx);
  if Support = tsNone then
    Exit(nil);
  if ALegacy then
  begin
    if Support = tsOptional then
      Exit(nil);
    // The extension is defined for 2026-07-28, and a classic tool error
    // is how this server tells a classic client a call cannot run.
    Exit(TJSONObject.Create(['content', TJSONArray.Create([MCPTextContent(
      'Tool "' + AToolName + '" runs only as a task, which is not available ' +
      'to legacy-era clients')]), 'isError', True]));
  end;
  // Never a task for a request that did not declare the extension, and
  // -32021 when the call cannot run otherwise (Capability Negotiation).
  if not ACtx.HasExtension(MCP_TASKS_EXTENSION) then
  begin
    if Support = tsRequired then
      raise ExtensionRequired;
    Exit(nil);
  end;

  Result := nil;
  try
    System.EnterCriticalSection(FLock);
    try
      Purge;
      // No task goes before its ttlMs ends (wire-fields: no early expiry),
      // so a full store takes no new one, nor one that is shutting down
      // (#82 review).
      Full := FDraining or (ActiveCount >= FMaxActive) or
        (FTasks.Count >= FMaxKept);
      if Full and (Support = tsRequired) then
        raise EMCPProtocolError.Create(JSONRPC_INTERNAL_ERROR,
          'Too many tasks are running; try again later');
      if not Full then
      begin
        Entry := TTaskEntry.Create(Self);
        try
          Entry.Id := NewTaskId;
          Entry.ToolName := AToolName;
          Entry.Arguments := TJSONObject(AArguments.Clone);
          if ACtx.Meta <> nil then
            Entry.Meta := TJSONObject(ACtx.Meta.Clone)
          else
            Entry.Meta := TJSONObject.Create;
          // A call that retries an input round brings its answers and
          // state to the handler's first run, as a synchronous call would.
          if ACtx.InputResponses <> nil then
            Entry.NextResponses := TJSONObject(ACtx.InputResponses.Clone);
          Entry.NextState := ACtx.RequestState;
          Entry.ClientName := ACtx.ClientName;
          Entry.ClientVersion := ACtx.ClientVersion;
          Entry.CreatedMs := MCPNowMs;
          // Saturating: a ttlMs past the clock's range never ends.
          if Entry.CreatedMs > High(Int64) - FTtlMs then
            Entry.DeadlineMs := High(Int64)
          else
            Entry.DeadlineMs := Entry.CreatedMs + FTtlMs;
          Entry.CreatedAt := UtcStamp;
          Entry.SetStatus(tkWorking);
          Entry.Worker := TTaskWorker.Create(Entry);
        except
          Entry.Free;
          raise;
        end;
        // Readable before the CreateTaskResult goes out (Task Creation).
        FTasks.Add(Entry);
        Result := Entry.Snapshot(False);
        Result.Add('resultType', 'task');
        // A call cancelled already never sends its taskId, so its task
        // would run where no client can cancel it: it starts cancelled
        // (#82 review).
        if ACtx.IsCancelled then
        begin
          Entry.SetStatus(tkCancelled, 'The client cancelled the request');
          Release(Entry);
        end;
        Entry.Worker.Start;
      end;
    finally
      System.LeaveCriticalSection(FLock);
    end;
  finally
    // Reaped on every way out, errors included (#82 review).
    Reap;
  end;
end;

function TMCPTasks.TaskFor(AParams: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean;
  const AMethod: string): TObject;
var
  IdData: TJSONData;
begin
  // The extension is defined for 2026-07-28: a classic client gets the
  // answer for a method this server does not have.
  if ALegacy then
    raise EMCPProtocolError.Create(JSONRPC_METHOD_NOT_FOUND,
      'Method not found: ' + AMethod);
  if not ACtx.HasExtension(MCP_TASKS_EXTENSION) then
    raise ExtensionRequired;
  IdData := nil;
  if AParams <> nil then
    IdData := AParams.Find('taskId');
  if (IdData = nil) or (IdData.JSONType <> jtString) then
    raise InvalidParams('taskId must be a string');
  Purge;
  Result := FindEntry(IdData.AsString);
  if Result = nil then
    raise InvalidParams('Failed to retrieve task: Task not found');
end;

// The questions a task waits on go only to a poll whose request declares
// what they need, as for a call's input round; the task waits on for a
// poll that does (#82 review).
procedure CheckInputCapabilities(AEntry: TTaskEntry;
  const ACtx: TMCPRequestContext);
var
  Missing, Member, Unknown: string;
begin
  if (AEntry.Status <> tkInputRequired) or (AEntry.Pending = nil) then
    Exit;
  Missing := MissingInputCapability(AEntry.Pending, ACtx, Unknown, Member);
  if Missing = '' then
    Exit;
  if Member <> '' then
    raise EMCPProtocolError.Create(MCP_ERROR_MISSING_CLIENT_CAPABILITY,
      'Missing required client capability: ' + Missing + '.' + Member,
      BuildMissingCapabilityData(Missing, Member));
  raise EMCPProtocolError.Create(MCP_ERROR_MISSING_CLIENT_CAPABILITY,
    'Missing required client capability: ' + Missing,
    BuildMissingCapabilityData(Missing));
end;

function TMCPTasks.GetTask(AParams: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
var
  Entry: TTaskEntry;
begin
  try
    System.EnterCriticalSection(FLock);
    try
      Entry := TTaskEntry(TaskFor(AParams, ACtx, ALegacy, 'tasks/get'));
      CheckInputCapabilities(Entry, ACtx);
      Result := Entry.Snapshot(True);
    finally
      System.LeaveCriticalSection(FLock);
    end;
  finally
    // Reaped on every way out, errors included (#82 review).
    Reap;
  end;
end;

function TMCPTasks.UpdateTask(AParams: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
var
  Entry: TTaskEntry;
  Responses: TJSONData;
  I, Slot, Outstanding: Integer;
  Key: string;
begin
  try
    System.EnterCriticalSection(FLock);
    try
      Entry := TTaskEntry(TaskFor(AParams, ACtx, ALegacy, 'tasks/update'));
      Responses := AParams.Find('inputResponses');
      if (Responses = nil) or (Responses.JSONType <> jtObject) then
        raise InvalidParams('inputResponses must be an object');
      // Only keys outstanding now count: others, answered, superseded or
      // never issued, are ignored, and a partial set leaves the task in
      // input_required for the rest (Task Update Requests).
      if (Entry.Status = tkInputRequired) and (Entry.Pending <> nil) then
      begin
        // An answer is a result object; none is taken while one is not
        // (#82 review).
        for I := 0 to TJSONObject(Responses).Count - 1 do
          if (Entry.Pending.IndexOfName(TJSONObject(Responses).Names[I]) >= 0)
            and (TJSONObject(Responses).Items[I].JSONType <> jtObject) then
            raise InvalidParams('inputResponses["' +
              TJSONObject(Responses).Names[I] + '"] must be an object');
        Outstanding := Entry.Pending.Count;
        for I := 0 to TJSONObject(Responses).Count - 1 do
        begin
          Key := TJSONObject(Responses).Names[I];
          Slot := Entry.Pending.IndexOfName(Key);
          if Slot < 0 then
            Continue;
          Entry.Answers.Add(Entry.KeyMap.Get(Key, ''),
            TJSONObject(Responses).Items[I].Clone);
          Entry.Pending.Delete(Slot);
        end;
        // Every request answered: working again at once, so no poll sees
        // input_required without its requests; the worker takes the
        // answers. Fewer open requests is a change too.
        if Entry.Pending.Count = 0 then
          Entry.SetStatus(tkWorking)
        else if Entry.Pending.Count < Outstanding then
          Entry.Touch;
      end;
      Result := TJSONObject.Create;
    finally
      System.LeaveCriticalSection(FLock);
    end;
  finally
    // Reaped on every way out, errors included (#82 review).
    Reap;
  end;
end;

function TMCPTasks.CancelTask(AParams: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
var
  Entry: TTaskEntry;
begin
  try
    System.EnterCriticalSection(FLock);
    try
      Entry := TTaskEntry(TaskFor(AParams, ACtx, ALegacy, 'tasks/cancel'));
      // A finished task stays as it is: the ack is the same either way.
      if not Entry.Terminal then
      begin
        FreeAndNil(Entry.Pending);
        Entry.SetStatus(tkCancelled, 'The client cancelled the task');
        Release(Entry);
      end;
      Result := TJSONObject.Create;
    finally
      System.LeaveCriticalSection(FLock);
    end;
  finally
    // Reaped on every way out, errors included (#82 review).
    Reap;
  end;
end;

type
  // notifications/tasks on subscriptions/listen (Task Status
  // Notifications): the taskIds filter key.
  TTaskSource = class(TMCPSubscriptionSource)
  private
    FTasks: TMCPTasks; // borrowed: the server owns both
  public
    constructor Create(ATasks: TMCPTasks);
    function FilterKey: string; override;
    function Agree(AValue: TJSONData;
      const ACtx: TMCPRequestContext): TJSONData; override;
    function Open(AAgreed: TJSONData;
      const ACtx: TMCPRequestContext): TMCPSubscriptionFeed; override;
  end;

  // One stream's tasks, and the states it has yet to send, queued at
  // each change so none is lost between two polls (#138 review).
  TTaskFeed = class(TMCPSubscriptionFeed)
  private
    FTasks: TMCPTasks; // borrowed; nil once the store has drained
    FIds: TJSONObject; // the task ids it follows
    // The listen request's capabilities (owned), which a task's input
    // requests are checked against, as on tasks/get.
    FCapabilities: TJSONObject;
    FQueue: TJSONArray; // owned: {method, params} objects, oldest first
    FCapacity: Integer;
  public
    constructor Create(ATasks: TMCPTasks; AIds: TJSONArray;
      const ACtx: TMCPRequestContext);
    destructor Destroy; override;
    // Under the store's lock: AEntry's state, when the feed follows it
    // and the listen request may see its input requests.
    procedure Enqueue(AEntry: TTaskEntry);
    procedure Collect(AOut: TJSONArray); override;
  end;

const
  // States a feed holds for a reader that has not collected them, at
  // least one per task it follows. Past it, the oldest state of the
  // changed task gives way, so every task's latest state is still sent
  // and a stalled stream costs bounded memory (#138 review).
  MAX_QUEUED_STATES = 64;

// Under the lock: every feed of AFeeds stops reaching the store.
procedure DetachFeeds(AFeeds: TList);
var
  I: Integer;
begin
  for I := 0 to AFeeds.Count - 1 do
    TTaskFeed(AFeeds[I]).FTasks := nil;
  AFeeds.Clear;
end;

procedure TMCPTasks.Changed(AEntry: TObject);
var
  I: Integer;
begin
  for I := 0 to FFeeds.Count - 1 do
    TTaskFeed(FFeeds[I]).Enqueue(TTaskEntry(AEntry));
end;

constructor TTaskSource.Create(ATasks: TMCPTasks);
begin
  inherited Create;
  FTasks := ATasks;
end;

function TTaskSource.FilterKey: string;
begin
  Result := 'taskIds';
end;

function Listed(AIds: TJSONArray; const AId: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to AIds.Count - 1 do
    if AIds.Strings[I] = AId then
      Exit(True);
  Result := False;
end;

// The tasks the server agrees to notify about are those of AValue it
// knows now. A client that did not declare the extension gets -32021.
function TTaskSource.Agree(AValue: TJSONData;
  const ACtx: TMCPRequestContext): TJSONData;
var
  I: Integer;
  Ids: TJSONArray;
begin
  if not ACtx.HasExtension(MCP_TASKS_EXTENSION) then
    raise ExtensionRequired;
  if AValue.JSONType <> jtArray then
    raise InvalidParams('notifications.taskIds must be an array of strings');
  for I := 0 to AValue.Count - 1 do
    if AValue.Items[I].JSONType <> jtString then
      raise InvalidParams('notifications.taskIds must be an array of ' +
        'strings');
  Ids := TJSONArray.Create;
  try
    System.EnterCriticalSection(FTasks.FLock);
    try
      FTasks.Purge;
      for I := 0 to AValue.Count - 1 do
        if (FTasks.FindEntry(AValue.Items[I].AsString) <> nil) and
          not Listed(Ids, AValue.Items[I].AsString) then
          Ids.Add(AValue.Items[I].AsString);
    finally
      System.LeaveCriticalSection(FTasks.FLock);
    end;
  except
    Ids.Free;
    raise;
  end;
  FTasks.Reap;
  // No task it knows: nothing to follow, and the key is left out of the
  // acknowledgment, so the stream takes no feed (#138 review).
  if Ids.Count = 0 then
  begin
    Ids.Free;
    Exit(nil);
  end;
  Result := Ids;
end;

function TTaskSource.Open(AAgreed: TJSONData;
  const ACtx: TMCPRequestContext): TMCPSubscriptionFeed;
begin
  Result := TTaskFeed.Create(FTasks, TJSONArray(AAgreed), ACtx);
end;

constructor TTaskFeed.Create(ATasks: TMCPTasks; AIds: TJSONArray;
  const ACtx: TMCPRequestContext);
var
  I: Integer;
  Entry: TTaskEntry;
begin
  inherited Create;
  FIds := TJSONObject.Create;
  FQueue := TJSONArray.Create;
  if ACtx.ClientCapabilities <> nil then
    FCapabilities := TJSONObject(ACtx.ClientCapabilities.Clone)
  else
    FCapabilities := TJSONObject.Create;
  for I := 0 to AIds.Count - 1 do
    FIds.Add(AIds.Strings[I], True);
  FCapacity := MAX_QUEUED_STATES;
  if FCapacity < AIds.Count then
    FCapacity := AIds.Count;
  System.EnterCriticalSection(ATasks.FLock);
  try
    // A store that is shutting down tells this feed nothing.
    if ATasks.FDraining then
      Exit;
    FTasks := ATasks;
    ATasks.FFeeds.Add(Self);
    // Each task's state as it is now comes first.
    for I := 0 to AIds.Count - 1 do
    begin
      Entry := TTaskEntry(ATasks.FindEntry(AIds.Strings[I]));
      if Entry <> nil then
        Enqueue(Entry);
    end;
  finally
    System.LeaveCriticalSection(ATasks.FLock);
  end;
end;

destructor TTaskFeed.Destroy;
var
  Tasks: TMCPTasks;
begin
  // The stream ends before the server frees the store (the transports
  // end their streams first); a drained store has let go of the feed.
  Tasks := FTasks;
  if Tasks <> nil then
  begin
    System.EnterCriticalSection(Tasks.FLock);
    try
      Tasks.FFeeds.Remove(Self);
    finally
      System.LeaveCriticalSection(Tasks.FLock);
    end;
  end;
  FIds.Free;
  FCapabilities.Free;
  FQueue.Free;
  inherited Destroy;
end;

// A task's state as tasks/get answers it. One waiting on input requests
// the listen request did not declare what they need for is left out, as
// tasks/get would refuse it (#82 review).
procedure TTaskFeed.Enqueue(AEntry: TTaskEntry);
var
  Ctx: TMCPRequestContext;
  Missing, Member, Unknown: string;
  I: Integer;
begin
  if FIds.IndexOfName(AEntry.Id) < 0 then
    Exit;
  if (AEntry.Status = tkInputRequired) and (AEntry.Pending <> nil) then
  begin
    Ctx := Default(TMCPRequestContext);
    Ctx.ProtocolVersion := MCP_PROTOCOL_VERSION;
    Ctx.ClientCapabilities := FCapabilities;
    Missing := MissingInputCapability(AEntry.Pending, Ctx, Unknown, Member);
    if Missing <> '' then
      Exit;
  end;
  // A state after the ttlMs ended is not sent: tasks/get no longer finds
  // the task (#138 review).
  if MCPNowMs >= AEntry.DeadlineMs then
    Exit;
  if FQueue.Count >= FCapacity then
    for I := 0 to FQueue.Count - 1 do
      if FQueue.Objects[I].FindPath('params.taskId').AsString = AEntry.Id then
      begin
        FQueue.Delete(I);
        Break;
      end;
  FQueue.Add(TJSONObject.Create(['method', 'notifications/tasks', 'params',
    AEntry.Snapshot(True)]));
end;

procedure TTaskFeed.Collect(AOut: TJSONArray);
var
  Tasks: TMCPTasks;
begin
  Tasks := FTasks;
  if Tasks = nil then
    Exit;
  System.EnterCriticalSection(Tasks.FLock);
  try
    while FQueue.Count > 0 do
      AOut.Add(FQueue.Extract(0));
  finally
    System.LeaveCriticalSection(Tasks.FLock);
  end;
end;

function ThreadsAvailable: Boolean;
{$IFDEF UNIX}
var
  Manager: TThreadManager;
{$ENDIF}
begin
  {$IFDEF UNIX}
  // Without a thread driver (cthreads), the RTL's stand-in manager has
  // no InitManager, and starting a thread would stop the program with
  // runtime error 232.
  Result := GetThreadManager(Manager) and Assigned(Manager.InitManager);
  {$ELSE}
  Result := True;
  {$ENDIF}
end;

function EnableTasks(AServer: TMCPServer): TMCPTasks;
var
  Problem: string;
begin
  if AServer = nil then
    raise EMCPServer.Create('EnableTasks needs a server');
  Result := TMCPTasks(AServer.Adopted(TMCPTasks));
  if Result <> nil then
    Exit;
  if not ThreadsAvailable then
    raise EMCPServer.Create('Tasks run on threads: list cthreads first in ' +
      'the program''s uses clause');
  // Everything that could refuse is checked before the server changes
  // (#138 review); the tool-call hook, the one step left that can, goes
  // first.
  Problem := AServer.HookProblem(TASK_METHODS, '');
  if Problem = '' then
    Problem := MCPSubscriptionSourceProblem(AServer, 'taskIds');
  if Problem <> '' then
    raise EMCPServer.Create(Problem);
  Result := TMCPTasks.Create(AServer);
  try
    // The server drains the tasks before it frees anything, the tool
    // owners an application adopted included (#82 review).
    AServer.SetToolCallHook(Result.ToolCall, Result.Drain);
  except
    Result.Free;
    raise;
  end;
  AServer.Adopt(Result);
  // Task status notifications on subscriptions/listen.
  AddSubscriptionSource(AServer, TTaskSource.Create(Result));
  AServer.RegisterMethod(TASK_METHODS[0], Result.GetTask);
  AServer.RegisterMethod(TASK_METHODS[1], Result.UpdateTask);
  AServer.RegisterMethod(TASK_METHODS[2], Result.CancelTask);
  // Mcp-Name carries params.taskId (Streamable HTTP: Routing Headers).
  AServer.RegisterRoute(TASK_METHODS[0], 'taskId', nil);
  AServer.RegisterRoute(TASK_METHODS[1], 'taskId', nil);
  AServer.RegisterRoute(TASK_METHODS[2], 'taskId', nil);
  AServer.EnsureExtension(MCP_TASKS_EXTENSION);
  AServer.RestrictExtensionToModern(MCP_TASKS_EXTENSION);
  // No settings are defined; {} whatever is declared before or after.
  AServer.PinExtensionSettings(MCP_TASKS_EXTENSION, TJSONObject.Create);
end;

end.
