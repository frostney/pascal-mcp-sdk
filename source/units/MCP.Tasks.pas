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
  its requestState, as for a retried call. Tasks live in this process's
  memory until their ttlMs ends. notifications/tasks is not sent: it
  needs subscriptions/listen, which this server does not serve.
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
    FTools: TStringList; // tool name = TMCPTaskSupport as an integer
    FSelector: TMCPTaskSelector;
    FSelectorMethod: TMCPTaskSelectorMethod;
    FTtlMs: Int64;
    FPollIntervalMs: Integer;
    FMaxActive: Integer;
    FMaxKept: Integer;
    FTasks: TList; // TTaskEntry, owned, oldest first
    FRetired: TList; // TTaskEntry, owned: out of reach, worker still running
    procedure EnsureMutable;
    procedure SetTtlMs(AValue: Int64);
    procedure SetPollIntervalMs(AValue: Integer);
    procedure SetMaxActive(AValue: Integer);
    procedure SetMaxKept(AValue: Integer);
    function SupportFor(const AToolName: string; AArguments: TJSONObject;
      const ACtx: TMCPRequestContext): TMCPTaskSupport;
    // Under FLock: drops tasks past their ttlMs and finished tasks beyond
    // MaxKept, keeping ARoom places free for tasks about to be added, and
    // frees retired ones whose worker has stopped.
    procedure Purge(ARoom: Integer);
    function ActiveCount: Integer;
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
    // Cancels every task and waits for its handler to return, so a
    // handler that never asks IsCancelled holds this up until it ends.
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
    // A task's ttlMs: how long after creation it stays readable (at
    // least 1). A task still running then is cancelled and dropped.
    property TtlMs: Int64 read FTtlMs write SetTtlMs;
    // The pollIntervalMs suggested to clients (at least 1).
    property PollIntervalMs: Integer read FPollIntervalMs
      write SetPollIntervalMs;
    // Tasks not yet finished at once (at least 1); a call past it runs as
    // usual when its tool allows that, and is refused with -32603
    // otherwise.
    property MaxActive: Integer read FMaxActive write SetMaxActive;
    // Tasks kept in all (at least MaxActive); the oldest finished ones go
    // first to make room.
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
// EMCPServer, as does a started server.
function EnableTasks(AServer: TMCPServer): TMCPTasks;

implementation

uses
  DateUtils,

  MCP.Content,
  MCP.Crypto,
  MCP.Errors,
  MCP.JSONRPC,
  MCP.Streams;

type
  TTaskStatus = (tkWorking, tkInputRequired, tkCompleted, tkFailed,
    tkCancelled);

const
  STATUS_NAMES: array[TTaskStatus] of string = ('working', 'input_required',
    'completed', 'failed', 'cancelled');
  TASK_METHODS: array[0..2] of string = ('tasks/get', 'tasks/update',
    'tasks/cancel');

type
  TTaskWorker = class;

  // One task. FOwner's lock guards every field a worker and a request
  // both reach; the tool name, arguments and request _meta never change
  // after creation.
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
    CreatedMs: Int64;
    CallResult: TJSONObject; // owned: the CallToolResult once completed
    Error: TJSONObject; // owned: the JSON-RPC error once failed
    // The round in progress: surfaced key -> request (owned), surfaced
    // key = the handler's key (owned), and the answers, under the
    // handler's keys (owned).
    Pending: TJSONObject;
    KeyMap: TStringList;
    Answers: TJSONObject;
    // Every key ever surfaced, so none is used twice.
    UsedKeys: TStringList;
    // What the next round of the handler starts with.
    NextResponses: TJSONObject; // owned; nil for none
    NextState: string;
    CancelRequested: Boolean;
    Wake: PRTLEvent;
    Worker: TTaskWorker; // owned
    constructor Create(AOwner: TMCPTasks);
    destructor Destroy; override;
    function Terminal: Boolean;
    // Under the lock.
    procedure SetStatus(AStatus: TTaskStatus; const AMessage: string = '');
    // The Task fields (new); with ADetailed the status's own payload
    // too (result, error or inputRequests). Under the lock.
    function Snapshot(ADetailed: Boolean): TJSONObject;
    // The handler's cancellation probe: tasks/cancel, the ttlMs ending or
    // the server going away.
    function IsCancelled: Boolean;
  end;

  TTaskWorker = class(TThread)
  private
    FEntry: TTaskEntry;
    // A handler round: its run, or False when the handler raised and the
    // task failed.
    function RunRound(AResponses: TJSONObject; const AState: string;
      out ARun: TMCPToolRun): Boolean;
    procedure Fail(ACode: Integer; const AMessage: string; AData: TJSONData);
    // Holds the round's input requests (owned) for tasks/get: False when
    // the task ended instead.
    function Park(ARun: TMCPToolRun): Boolean;
    // The rounds of the task, until it ends.
    procedure Work;
  protected
    procedure Execute; override;
  public
    constructor Create(AEntry: TTaskEntry);
  end;

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

{ TTaskEntry }

constructor TTaskEntry.Create(AOwner: TMCPTasks);
begin
  inherited Create;
  Owner := AOwner;
  KeyMap := TStringList.Create;
  UsedKeys := TStringList.Create;
  UsedKeys.Sorted := True;
  UsedKeys.CaseSensitive := True;
  Wake := RTLEventCreate;
end;

destructor TTaskEntry.Destroy;
begin
  Worker.Free;
  RTLEventDestroy(Wake);
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
  UpdatedAt := UtcStamp;
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

function TTaskEntry.IsCancelled: Boolean;
begin
  System.EnterCriticalSection(Owner.FLock);
  try
    Result := CancelRequested;
  finally
    System.LeaveCriticalSection(Owner.FLock);
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

function TTaskWorker.RunRound(AResponses: TJSONObject; const AState: string;
  out ARun: TMCPToolRun): Boolean;
var
  Ctx: TMCPRequestContext;
  Capabilities: TJSONData;
  Problem: EMCPProtocolError;
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
      Problem := E;
      if Problem.Data <> nil then
        Fail(Problem.Code, Problem.Message, Problem.Data.Clone)
      else
        Fail(Problem.Code, Problem.Message, nil);
      Result := False;
    end;
    on E: Exception do
    begin
      Fail(JSONRPC_INTERNAL_ERROR, 'Internal error: ' + E.Message, nil);
      Result := False;
    end;
  end;
end;

function TTaskWorker.Park(ARun: TMCPToolRun): Boolean;
var
  Missing, Member, Unknown, Key, Surfaced: string;
  Requests: TJSONObject;
  I, Suffix: Integer;
  Ctx: TMCPRequestContext;
  Capabilities: TJSONData;
begin
  Requests := ARun.InputRequests;
  ARun.Meta.Free;
  // The same gate as a call's input round: kinds the creating request's
  // client declared.
  Ctx := Default(TMCPRequestContext);
  Ctx.ProtocolVersion := MCP_PROTOCOL_VERSION;
  Capabilities := FEntry.Meta.Find(META_KEY_CLIENT_CAPABILITIES);
  if (Capabilities <> nil) and (Capabilities.JSONType = jtObject) then
    Ctx.ClientCapabilities := TJSONObject(Capabilities);
  try
    if (Requests = nil) or (Requests.Count = 0) then
      Unknown := '(none)'
    else
      Missing := MissingInputCapability(Requests, Ctx, Unknown, Member);
  except
    Requests.Free;
    raise;
  end;
  if Unknown <> '' then
  begin
    Requests.Free;
    Fail(JSONRPC_INTERNAL_ERROR, 'Tool "' + FEntry.ToolName +
      '" produced an unsupported input request kind "' + Unknown + '"', nil);
    Exit(False);
  end;
  if Missing <> '' then
  begin
    Requests.Free;
    if Member <> '' then
      Fail(MCP_ERROR_MISSING_CLIENT_CAPABILITY, 'Missing required client ' +
        'capability: ' + Missing + '.' + Member,
        BuildMissingCapabilityData(Missing, Member))
    else
      Fail(MCP_ERROR_MISSING_CLIENT_CAPABILITY, 'Missing required client ' +
        'capability: ' + Missing, BuildMissingCapabilityData(Missing));
    Exit(False);
  end;

  System.EnterCriticalSection(FEntry.Owner.FLock);
  try
    if FEntry.Terminal or FEntry.CancelRequested then
    begin
      Requests.Free;
      Exit(False);
    end;
    // Keys stay unique over the task's lifetime (Task Update Requests): a
    // handler key answered in an earlier round is surfaced with a suffix.
    FEntry.Pending := TJSONObject.Create;
    FEntry.KeyMap.Clear;
    FEntry.Answers := TJSONObject.Create;
    for I := 0 to Requests.Count - 1 do
    begin
      Key := Requests.Names[I];
      Surfaced := Key;
      Suffix := 1;
      while FEntry.UsedKeys.IndexOf(Surfaced) >= 0 do
      begin
        Inc(Suffix);
        Surfaced := Key + '#' + IntToStr(Suffix);
      end;
      FEntry.UsedKeys.Add(Surfaced);
      FEntry.KeyMap.Values[Surfaced] := Key;
      FEntry.Pending.Add(Surfaced, Requests.Items[I].Clone);
    end;
    Requests.Free;
    FEntry.NextState := ARun.RequestState;
    RTLEventResetEvent(FEntry.Wake);
    FEntry.SetStatus(tkInputRequired);
    Result := True;
  finally
    System.LeaveCriticalSection(FEntry.Owner.FLock);
  end;
end;

procedure TTaskWorker.Execute;
begin
  try
    Work;
  except
    // Nothing escapes a worker: the task fails instead of staying
    // working until its ttlMs ends.
    on E: Exception do
      Fail(JSONRPC_INTERNAL_ERROR, 'Internal error: ' + E.Message, nil);
  end;
end;

procedure TTaskWorker.Work;
var
  Responses: TJSONObject;
  State: string;
  Run: TMCPToolRun;
  Waiting: Boolean;
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
      if not RunRound(Responses, State, Run) then
        Exit;
    finally
      FreeAndNil(Responses);
    end;
    if not Run.InputRequired then
    begin
      System.EnterCriticalSection(FEntry.Owner.FLock);
      try
        // A cancelled task keeps its status; the late result is dropped.
        if FEntry.Terminal then
          Run.Result.Free
        else
        begin
          FEntry.CallResult := Run.Result;
          FEntry.SetStatus(tkCompleted);
        end;
      finally
        System.LeaveCriticalSection(FEntry.Owner.FLock);
      end;
      Exit;
    end;
    if not Park(Run) then
      Exit;
    // Until tasks/update has answered every request, or the task ends.
    repeat
      RTLEventWaitFor(FEntry.Wake);
      System.EnterCriticalSection(FEntry.Owner.FLock);
      try
        if FEntry.Terminal or FEntry.CancelRequested then
          Exit;
        Waiting := FEntry.Pending.Count > 0;
        if not Waiting then
        begin
          Responses := FEntry.Answers;
          FEntry.Answers := nil;
          FreeAndNil(FEntry.Pending);
          State := FEntry.NextState;
        end;
      finally
        System.LeaveCriticalSection(FEntry.Owner.FLock);
      end;
    until not Waiting;
  until False;
end;

{ TMCPTasks }

constructor TMCPTasks.Create(AServer: TMCPServer);
begin
  inherited Create;
  FServer := AServer;
  InitCriticalSection(FLock);
  FTools := TStringList.Create;
  FTools.CaseSensitive := True;
  FTtlMs := MCP_TASK_DEFAULT_TTL_MS;
  FPollIntervalMs := MCP_TASK_DEFAULT_POLL_INTERVAL_MS;
  FMaxActive := MCP_TASK_DEFAULT_MAX_ACTIVE;
  FMaxKept := MCP_TASK_DEFAULT_MAX_KEPT;
  FTasks := TList.Create;
  FRetired := TList.Create;
end;

// Cancels AEntry's handler and lets its worker go (under the lock).
procedure Release(AEntry: TTaskEntry);
begin
  AEntry.CancelRequested := True;
  RTLEventSetEvent(AEntry.Wake);
end;

destructor TMCPTasks.Destroy;
var
  I: Integer;
  Entries: TList;
begin
  Entries := TList.Create;
  try
    System.EnterCriticalSection(FLock);
    try
      for I := 0 to FTasks.Count - 1 do
        Entries.Add(FTasks[I]);
      for I := 0 to FRetired.Count - 1 do
        Entries.Add(FRetired[I]);
      FTasks.Clear;
      FRetired.Clear;
      for I := 0 to Entries.Count - 1 do
        Release(TTaskEntry(Entries[I]));
    finally
      System.LeaveCriticalSection(FLock);
    end;
    // Outside the lock, which the workers take on their way out.
    for I := 0 to Entries.Count - 1 do
      if TTaskEntry(Entries[I]).Worker <> nil then
        TTaskEntry(Entries[I]).Worker.WaitFor;
    for I := 0 to Entries.Count - 1 do
      TTaskEntry(Entries[I]).Free;
  finally
    Entries.Free;
  end;
  FTasks.Free;
  FRetired.Free;
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
  FTools.Values[AToolName] := IntToStr(Ord(ASupport));
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
  if AValue < 1 then
    raise EMCPServer.Create('TtlMs must be at least 1');
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
var
  Value: string;
begin
  if Assigned(FSelectorMethod) then
    Exit(FSelectorMethod(AToolName, AArguments, ACtx));
  if Assigned(FSelector) then
    Exit(FSelector(AToolName, AArguments, ACtx));
  Value := FTools.Values[AToolName];
  if Value = '' then
    Result := tsNone
  else
    Result := TMCPTaskSupport(StrToInt(Value));
end;

procedure TMCPTasks.Purge(ARoom: Integer);
var
  I, Excess: Integer;
  Entry: TTaskEntry;
  Now: Int64;
begin
  for I := FRetired.Count - 1 downto 0 do
  begin
    Entry := TTaskEntry(FRetired[I]);
    if (Entry.Worker = nil) or Entry.Worker.Finished then
    begin
      FRetired.Delete(I);
      if Entry.Worker <> nil then
        Entry.Worker.WaitFor;
      Entry.Free;
    end;
  end;
  // Past its ttlMs, a task may be deleted (Task Polling); one still
  // running is cancelled first.
  Now := MCPNowMs;
  for I := FTasks.Count - 1 downto 0 do
  begin
    Entry := TTaskEntry(FTasks[I]);
    if Now - Entry.CreatedMs >= FTtlMs then
    begin
      FTasks.Delete(I);
      Release(Entry);
      FRetired.Add(Entry);
    end;
  end;
  // Then the oldest finished tasks, to keep MaxKept.
  Excess := FTasks.Count + ARoom - FMaxKept;
  I := 0;
  while (Excess > 0) and (I < FTasks.Count) do
  begin
    Entry := TTaskEntry(FTasks[I]);
    if Entry.Terminal then
    begin
      FTasks.Delete(I);
      Release(Entry);
      FRetired.Add(Entry);
      Dec(Excess);
    end
    else
      Inc(I);
  end;
end;

function TMCPTasks.ActiveCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FTasks.Count - 1 do
    if not TTaskEntry(FTasks[I]).Terminal then
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

  System.EnterCriticalSection(FLock);
  try
    Purge(1);
    if ActiveCount >= FMaxActive then
    begin
      if Support = tsOptional then
        Exit(nil);
      raise EMCPProtocolError.Create(JSONRPC_INTERNAL_ERROR,
        'Too many tasks are running; try again later');
    end;
    Entry := TTaskEntry.Create(Self);
    try
      Entry.Id := NewTaskId;
      Entry.ToolName := AToolName;
      Entry.Arguments := TJSONObject(AArguments.Clone);
      if ACtx.Meta <> nil then
        Entry.Meta := TJSONObject(ACtx.Meta.Clone)
      else
        Entry.Meta := TJSONObject.Create;
      // A call that retries an input round brings its answers and state
      // to the handler's first run, as a synchronous call would.
      if ACtx.InputResponses <> nil then
        Entry.NextResponses := TJSONObject(ACtx.InputResponses.Clone);
      Entry.NextState := ACtx.RequestState;
      Entry.ClientName := ACtx.ClientName;
      Entry.ClientVersion := ACtx.ClientVersion;
      Entry.CreatedMs := MCPNowMs;
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
    Entry.Worker.Start;
  finally
    System.LeaveCriticalSection(FLock);
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
  Purge(0);
  Result := FindEntry(IdData.AsString);
  if Result = nil then
    raise InvalidParams('Failed to retrieve task: Task not found');
end;

function TMCPTasks.GetTask(AParams: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
begin
  System.EnterCriticalSection(FLock);
  try
    Result := TTaskEntry(TaskFor(AParams, ACtx, ALegacy, 'tasks/get'))
      .Snapshot(True);
  finally
    System.LeaveCriticalSection(FLock);
  end;
end;

function TMCPTasks.UpdateTask(AParams: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
var
  Entry: TTaskEntry;
  Responses: TJSONData;
  I, Slot: Integer;
  Key: string;
begin
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
      for I := 0 to TJSONObject(Responses).Count - 1 do
      begin
        Key := TJSONObject(Responses).Names[I];
        Slot := Entry.Pending.IndexOfName(Key);
        if Slot < 0 then
          Continue;
        Entry.Answers.Add(Entry.KeyMap.Values[Key],
          TJSONObject(Responses).Items[I].Clone);
        Entry.Pending.Delete(Slot);
      end;
      // Every request answered: working again at once, so no poll sees
      // input_required without its requests; the worker takes the
      // answers.
      if Entry.Pending.Count = 0 then
      begin
        Entry.SetStatus(tkWorking);
        RTLEventSetEvent(Entry.Wake);
      end;
    end;
    Result := TJSONObject.Create;
  finally
    System.LeaveCriticalSection(FLock);
  end;
end;

function TMCPTasks.CancelTask(AParams: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
var
  Entry: TTaskEntry;
begin
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
  Problem := AServer.HookProblem(TASK_METHODS, '');
  if Problem <> '' then
    raise EMCPServer.Create(Problem);
  Result := TMCPTasks.Create(AServer);
  try
    AServer.SetToolCallHook(Result.ToolCall);
  except
    Result.Free;
    raise;
  end;
  AServer.Adopt(Result);
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
