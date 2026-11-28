{ MCP.Tasks.Test — the Tasks extension (#82): the declaration, which
  calls become tasks (tool support, the selector, the request's
  declaration, the classic era), the CreateTaskResult and DetailedTask
  shapes, completion, tool errors, protocol errors and faults, input
  rounds (partial answers, unknown keys, keys kept unique, requestState,
  the capability gate), cancellation, the errors (-32021, -32602, -32601,
  -32603), the limits (MaxActive, TtlMs, MaxKept), the registration
  guards, a non-ASCII result byte-exact on the wire, and teardown while a
  task runs. Shapes verified 2026-11-28 against modelcontextprotocol/
  ext-tasks specification/2026-07-28/tasks.md at cc9aaac. }

program MCP.Tasks.Test;

{$I MCP.inc}

uses
  // Task handlers run on threads.
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Math,
  SysUtils,

  fpjson,
  MCP.JSONRPC,
  MCP.Protocol,
  MCP.Server,
  MCP.Streams,
  MCP.Subscriptions,
  MCP.Tasks,
  MCP.Testing,
  TestingPascalLibrary;

const
  TASKS_CAPS = '{"elicitation":{},"extensions":' +
    '{"io.modelcontextprotocol/tasks":{}}}';
  META =
    '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":' + TASKS_CAPS + '}';
  NO_ARGUMENTS = '{"type":"object","properties":{}}';
  MS_SCHEMA = '{"type":"object","properties":{"ms":{"type":"integer"}}}';
  // "Grüße", raw UTF-8 bytes, and U+1F600 beside it.
  GRUSSE = 'Gr' + #$C3#$BC + #$C3#$9F + 'e';
  GRIN = #$F0#$9F#$98#$80;

procedure CaptureSink(const ALine: string; AUserData: Pointer);
begin
  PString(AUserData)^ := PString(AUserData)^ + ALine + #10;
end;

var
  // What the handlers saw, for the tests to check.
  SawCancel, WaitStarted, OwnerFreed, UsedAfterFree: Boolean;
  // Where the owner leaves its callbacks' answers when it is freed.
  OwnerLines: PString;
  // How long the stubborn handler ignores cancellation, in ms.
  StubbornMs: Integer;
  Rounds: Integer;

type
  // A tool's owner, adopted after EnableTasks: its handler reads it while
  // it runs, so teardown must stop the task before it frees the owner.
  TToolOwner = class
  public
    Calls: Integer;
    // A session of its own, to call back into the server while teardown
    // waits for it; and what those calls answered.
    Server: TMCPServer;
    Session: TMCPSession;
    CallbackLines: string;
    destructor Destroy; override;
    function Spin(AArguments: TJSONObject;
      const ACtx: TMCPRequestContext): TMCPToolResult;
  end;

  // A source for taskIds of another unit's, to make EnableTasks refuse.
  TTaskIdsStub = class(TMCPSubscriptionSource)
  public
    function FilterKey: string; override;
    function Agree(AValue: TJSONData;
      const ACtx: TMCPRequestContext): TJSONData; override;
    function Open(AAgreed: TJSONData;
      const ACtx: TMCPRequestContext): TMCPSubscriptionFeed; override;
  end;

  THookStub = class
    function Take(const AToolName: string; AArguments: TJSONObject;
      const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
  end;

destructor TToolOwner.Destroy;
begin
  if OwnerLines <> nil then
    OwnerLines^ := CallbackLines;
  Session.Free;
  OwnerFreed := True;
  inherited Destroy;
end;

function TToolOwner.Spin(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Line: string;
begin
  WaitStarted := True;
  while not ACtx.IsCancelled do
  begin
    Inc(Calls);
    Sleep(5);
  end;
  // Still reading its owner after the cancellation, and calling back into
  // the server while teardown waits for it: no task is admitted, and the
  // store has nothing left to find.
  Sleep(50);
  if OwnerFreed then
    UsedAfterFree := True;
  if Session <> nil then
  begin
    Server.HandleMessage(Session, '{"jsonrpc":"2.0","id":1,"method":' +
      '"tools/call","params":{"name":"wait","arguments":{"ms":0},' + META +
      '}}', Line);
    CallbackLines := Line;
    Server.HandleMessage(Session, '{"jsonrpc":"2.0","id":2,"method":' +
      '"tasks/get","params":{"taskId":"x",' + META + '}}', Line);
    CallbackLines := CallbackLines + #10 + Line;
  end;
  Inc(Calls);
  Result := MCPTextResult('spun');
end;

function TTaskIdsStub.FilterKey: string;
begin
  Result := 'taskIds';
end;

function TTaskIdsStub.Agree(AValue: TJSONData;
  const ACtx: TMCPRequestContext): TJSONData;
begin
  Result := nil;
end;

function TTaskIdsStub.Open(AAgreed: TJSONData;
  const ACtx: TMCPRequestContext): TMCPSubscriptionFeed;
begin
  Result := nil;
end;

function THookStub.Take(const AToolName: string; AArguments: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
begin
  Result := nil;
end;

type
  TTasksSuite = class(TTestSuite)
  private
    FServer: TMCPServer;
    FClient: TMCPTestClient;
    FTasks: TMCPTasks;
    procedure RegisterFixture;
    function Client: TMCPTestClient;
    // The taskId of a CreateTaskResult for tool AName ('' when the call
    // returned something else).
    function StartTask(const AName: string;
      const AArguments: string = '{}'): string;
    function GetTask(const ATaskId: string): TJSONObject;
    // tasks/get until the task reaches AStatus or ends, at most 5 s.
    function WaitFor(const ATaskId, AStatus: string): TJSONObject;
    function ErrorCode(AResponse: TJSONObject): Integer;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;
    procedure TestDeclaration;
    procedure TestSynchronousCalls;
    procedure TestCreateTaskResult;
    procedure TestCompletion;
    procedure TestToolErrors;
    procedure TestProtocolErrors;
    procedure TestInputRounds;
    procedure TestPartialAnswers;
    procedure TestInputCapabilityGate;
    procedure TestCancel;
    procedure TestMissingExtension;
    procedure TestClassicEra;
    procedure TestBadParams;
    procedure TestSelectorAfterInput;
    procedure TestMaxActive;
    procedure TestTtl;
    procedure TestMaxKept;
    procedure TestGuards;
    procedure TestUtf8Result;
    procedure TestTeardownCancels;
    procedure TestTeardownBeforeAdoptedOwners;
    procedure TestStateOnlyRound;
    procedure TestUnsendableResult;
    procedure TestMalformedAnswer;
    procedure TestStatusNotifications;
    procedure TestListenRefusals;
    procedure TestEnableRefusedCleanly;
  end;

function Echo(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPTextResult('echo');
end;

// Waits ms milliseconds (forever without), or until cancelled.
function Wait(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Left: Integer;
  Forever: Boolean;
begin
  WaitStarted := True;
  Forever := AArguments.Find('ms') = nil;
  Left := AArguments.Get('ms', 0);
  while Forever or (Left > 0) do
  begin
    if ACtx.IsCancelled then
    begin
      SawCancel := True;
      Exit(MCPErrorResult('cancelled'));
    end;
    Sleep(5);
    Dec(Left, 5);
  end;
  Result := MCPTextResult('waited');
end;

// Ignores cancellation for StubbornMs, then stops.
function Stubborn(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  WaitStarted := True;
  while not ACtx.IsCancelled do
    Sleep(5);
  Sleep(StubbornMs);
  Result := MCPTextResult('late');
end;

// An elicitation without its params.
function Bare(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPInputRequired(TJSONObject.Create(['e', TJSONObject.Create([
    'method', 'elicitation/create'])]));
end;

// An elicitation whose params lack its message and schema.
function Hollow(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPInputRequired(TJSONObject.Create(['e', TJSONObject.Create([
    'method', 'elicitation/create', 'params', TJSONObject.Create])]));
end;

// Nothing to ask the first time: runs again with its state.
function StateOnly(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  if ACtx.RequestState = 'again' then
    Exit(MCPTextResult('ran again'));
  Result := MCPInputRequired(nil, 'again');
end;

// A result the wire cannot carry: a non-finite number.
function Unsendable(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPStructuredResult(TJSONFloatNumber.Create(Infinity));
end;

function FailTool(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPErrorResult('it failed');
end;

function Crash(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := Default(TMCPToolResult);
  raise Exception.Create('boom');
end;

function Refuse(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := Default(TMCPToolResult);
  raise EMCPProtocolError.Create(JSONRPC_INVALID_PARAMS, 'refused',
    TJSONObject.Create(['why', 'test']));
end;

function Elicit(const AText: string): TJSONObject;
begin
  Result := MCPElicitFormRequest(AText, TJSONObject(MCPParseJSON(
    '{"type":"object","properties":{"v":{"type":"string"}}}')));
end;

function Answer(const ACtx: TMCPRequestContext; const AKey: string): string;
var
  Content: TJSONObject;
begin
  Content := MCPElicitationContent(ACtx, AKey);
  if Content = nil then
    Exit('?');
  Result := Content.Get('v', '?');
end;

// Asks under a key with a '#' of its own.
function Drafty(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  if (MCPInputResponse(ACtx, 'q#draft') <> nil) and
    (MCPInputResponse(ACtx, 'c#2') <> nil) then
    Exit(MCPTextResult(Answer(ACtx, 'q#draft') + Answer(ACtx, 'c#2')));
  Result := MCPInputRequired(TJSONObject.Create(['q#draft', Elicit('Q?'),
    'c#2', Elicit('C?')]));
end;

// Three rounds: "name", then "name" again with "city", then done.
function Ask(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Requests: TJSONObject;
begin
  Inc(Rounds);
  if ACtx.RequestState = '' then
  begin
    Requests := TJSONObject.Create(['name', Elicit('Name?')]);
    Exit(MCPInputRequired(Requests, 'r1:'));
  end;
  if Copy(ACtx.RequestState, 1, 3) = 'r1:' then
  begin
    Requests := TJSONObject.Create(['name', Elicit('Name again?'), 'city',
      Elicit('City?')]);
    Exit(MCPInputRequired(Requests, 'r2:' + Answer(ACtx, 'name')));
  end;
  Result := MCPTextResult(Copy(ACtx.RequestState, 4, MaxInt) + '/' +
    Answer(ACtx, 'name') + '/' + Answer(ACtx, 'city'));
end;

function Pair(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  if (MCPInputResponse(ACtx, 'a') <> nil) and
    (MCPInputResponse(ACtx, 'b') <> nil) then
    Exit(MCPTextResult(Answer(ACtx, 'a') + Answer(ACtx, 'b')));
  Result := MCPInputRequired(TJSONObject.Create(['a', Elicit('A?'), 'b',
    Elicit('B?')]));
end;

// Keys that differ only in case, and one with "=" in it.
function Cased(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  if (MCPInputResponse(ACtx, 'k') <> nil) and
    (MCPInputResponse(ACtx, 'K') <> nil) and
    (MCPInputResponse(ACtx, 'x=y') <> nil) then
    Exit(MCPTextResult(Answer(ACtx, 'k') + Answer(ACtx, 'K') +
      Answer(ACtx, 'x=y')));
  Result := MCPInputRequired(TJSONObject.Create(['k', Elicit('k?'), 'K',
    Elicit('K?'), 'x=y', Elicit('x=y?')]));
end;

function Sample(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPInputRequired(TJSONObject.Create(['s',
    MCPSamplingTextRequest('Hi?', 10)]));
end;

// The non-ASCII text, and what the handler knows of its client.
function Greeting(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPTextResult(GRUSSE + ' ' + GRIN + ' ' + ACtx.ClientName + '/' +
    ACtx.ClientVersion + ' ' + BoolToStr(ACtx.HasSubCapability('elicitation',
    'form'), 'form', 'no form') + ' ' + BoolToStr(ACtx.Meta <> nil, 'meta',
    'no meta') + ' ' + BoolToStr(Assigned(ACtx.Notifier), 'notifier',
    'no notifier'));
end;

// Gathers "who" synchronously, then runs the retry as a task.
function Gather(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  if MCPInputResponse(ACtx, 'who') = nil then
    Exit(MCPInputRequired(TJSONObject.Create(['who', Elicit('Who?')]),
      'gathering'));
  Result := MCPTextResult(ACtx.RequestState + ':' + Answer(ACtx, 'who'));
end;

function GatherSelector(const AToolName: string; AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPTaskSupport;
begin
  if (AToolName = 'gather') and (ACtx.InputResponses <> nil) then
    Result := tsRequired
  else
    Result := tsNone;
end;

procedure TTasksSuite.BeforeEach;
begin
  SawCancel := False;
  WaitStarted := False;
  OwnerFreed := False;
  UsedAfterFree := False;
  OwnerLines := nil;
  StubbornMs := 0;
  Rounds := 0;
  FServer := TMCPServer.Create('tasks', '1.0');
  FClient := nil;
  FTasks := nil;
end;

procedure TTasksSuite.AfterEach;
begin
  FreeAndNil(FClient);
  FreeAndNil(FServer);
end;

procedure TTasksSuite.RegisterFixture;
const
  OPTIONAL_TOOLS: array[0..14] of string = ('wait', 'fail', 'crash',
    'refuse', 'ask', 'pair', 'sample', 'greeting', 'cased', 'stubborn',
    'stateonly', 'unsendable', 'drafty', 'bare', 'hollow');
var
  Name: string;
begin
  FServer.RegisterTool('echo', 'Sync only', NO_ARGUMENTS, Echo);
  FServer.RegisterTool('wait', 'Waits', MS_SCHEMA, Wait);
  FServer.RegisterTool('must', 'Waits, only as a task', MS_SCHEMA, Wait);
  FServer.RegisterTool('fail', 'Tool error', NO_ARGUMENTS, FailTool);
  FServer.RegisterTool('crash', 'Raises', NO_ARGUMENTS, Crash);
  FServer.RegisterTool('refuse', 'Protocol error', NO_ARGUMENTS, Refuse);
  FServer.RegisterTool('ask', 'Three rounds', NO_ARGUMENTS, Ask);
  FServer.RegisterTool('pair', 'Two at once', NO_ARGUMENTS, Pair);
  FServer.RegisterTool('cased', 'Keys by case', NO_ARGUMENTS, Cased);
  FServer.RegisterTool('stubborn', 'Slow to stop', NO_ARGUMENTS, Stubborn);
  FServer.RegisterTool('drafty', 'A key with a #', NO_ARGUMENTS, Drafty);
  FServer.RegisterTool('bare', 'A malformed request', NO_ARGUMENTS, Bare);
  FServer.RegisterTool('hollow', 'Empty params', NO_ARGUMENTS, Hollow);
  FServer.RegisterTool('stateonly', 'A round without questions',
    NO_ARGUMENTS, StateOnly);
  FServer.RegisterTool('unsendable', 'A non-finite result', NO_ARGUMENTS,
    Unsendable);
  FServer.RegisterTool('sample', 'Sampling', NO_ARGUMENTS, Sample);
  FServer.RegisterTool('greeting', 'Non-ASCII', NO_ARGUMENTS, Greeting);
  FTasks := EnableTasks(FServer);
  for Name in OPTIONAL_TOOLS do
    FTasks.SetToolSupport(Name, tsOptional);
  FTasks.SetToolSupport('must', tsRequired);
  FTasks.PollIntervalMs := 50;
end;

function TTasksSuite.Client: TMCPTestClient;
begin
  if FClient = nil then
  begin
    FClient := TMCPTestClient.Create(FServer);
    FClient.SetClientCapabilities(TASKS_CAPS);
  end;
  Result := FClient;
end;

function TTasksSuite.StartTask(const AName, AArguments: string): string;
var
  Response: TJSONObject;
  Id: TJSONData;
begin
  Response := Client.CallTool(AName, AArguments);
  try
    Id := Response.FindPath('result.taskId');
    if Id = nil then
      Result := ''
    else
      Result := Id.AsString;
  finally
    Response.Free;
  end;
end;

function TTasksSuite.GetTask(const ATaskId: string): TJSONObject;
begin
  Result := Client.Request('tasks/get', '{"taskId":"' + ATaskId + '"}');
end;

function TTasksSuite.WaitFor(const ATaskId, AStatus: string): TJSONObject;
var
  Step: Integer;
  Status: string;
begin
  Result := nil;
  for Step := 1 to 500 do
  begin
    FreeAndNil(Result);
    Result := GetTask(ATaskId);
    if Result.FindPath('result.status') = nil then
      Exit;
    Status := Result.FindPath('result.status').AsString;
    if (Status = AStatus) or (Status = 'completed') or (Status = 'failed') or
      (Status = 'cancelled') then
      Exit;
    Sleep(10);
  end;
end;

// Whether the waiting handler has started, within 5 s.
function AwaitStart: Boolean;
var
  Step: Integer;
begin
  for Step := 1 to 500 do
    if not WaitStarted then
      Sleep(10);
  Result := WaitStarted;
end;

function TTasksSuite.ErrorCode(AResponse: TJSONObject): Integer;
begin
  if AResponse.FindPath('error.code') = nil then
    Exit(0);
  Result := AResponse.FindPath('error.code').AsInteger;
end;

procedure TTasksSuite.TestDeclaration;
var
  Response: TJSONObject;
begin
  RegisterFixture;
  Response := Client.Discover;
  try
    Expect<string>(Response.FindPath('result.capabilities.extensions')
      .AsJSON).ToBe('{ "io.modelcontextprotocol/tasks" : {} }');
    // The v1 slot is not used.
    Expect<Boolean>(Response.FindPath('result.capabilities.tasks') = nil)
      .ToBe(True);
  finally
    Response.Free;
  end;
end;

// A tool without task support, and an optional one for a request that
// does not declare the extension, run as usual.
procedure TTasksSuite.TestSynchronousCalls;
var
  Response: TJSONObject;
begin
  RegisterFixture;
  Response := Client.CallTool('echo');
  try
    Expect<string>(Response.FindPath('result.resultType').AsString)
      .ToBe('complete');
    Expect<string>(Response.FindPath('result.content[0].text').AsString)
      .ToBe('echo');
  finally
    Response.Free;
  end;
  Client.SetClientCapabilities('{}');
  Response := Client.CallTool('wait', '{"ms":0}');
  try
    Expect<string>(Response.FindPath('result.resultType').AsString)
      .ToBe('complete');
    Expect<Boolean>(Response.FindPath('result.taskId') = nil).ToBe(True);
    Expect<string>(Response.FindPath('result.content[0].text').AsString)
      .ToBe('waited');
  finally
    Response.Free;
  end;
end;

procedure TTasksSuite.TestCreateTaskResult;
var
  Response, Created: TJSONObject;
  TaskId: string;
begin
  RegisterFixture;
  Response := Client.CallTool('wait');
  try
    Created := TJSONObject(Response.Find('result'));
    Expect<string>(Created.Get('resultType', '')).ToBe('task');
    TaskId := Created.Get('taskId', '');
    // 128 random bits, base64url: 22 characters.
    Expect<Integer>(Length(TaskId)).ToBe(22);
    Expect<string>(Created.Get('status', '')).ToBe('working');
    Expect<Boolean>(Created.Get('ttlMs', Int64(0)) =
      MCP_TASK_DEFAULT_TTL_MS).ToBe(True);
    Expect<Integer>(Created.Get('pollIntervalMs', 0)).ToBe(50);
    Expect<Integer>(Length(Created.Get('createdAt', ''))).ToBe(24);
    Expect<string>(Copy(Created.Get('createdAt', ''), 24, 1)).ToBe('Z');
    Expect<Boolean>(Created.Find('lastUpdatedAt') <> nil).ToBe(True);
    // Flat, and without what only tasks/get carries.
    Expect<Boolean>((Created.Find('task') = nil) and
      (Created.Find('result') = nil) and (Created.Find('error') = nil) and
      (Created.Find('inputRequests') = nil) and
      (Created.Find('requestState') = nil)).ToBe(True);
    Expect<Boolean>(Created.FindPath('_meta') <> nil).ToBe(True);
  finally
    Response.Free;
  end;
  // Readable at once (Task Creation), and still working.
  Response := GetTask(TaskId);
  try
    Expect<string>(Response.FindPath('result.resultType').AsString)
      .ToBe('complete');
    Expect<string>(Response.FindPath('result.taskId').AsString).ToBe(TaskId);
    Expect<string>(Response.FindPath('result.status').AsString)
      .ToBe('working');
  finally
    Response.Free;
  end;
end;

procedure TTasksSuite.TestCompletion;
var
  Response: TJSONObject;
  TaskId: string;
begin
  RegisterFixture;
  TaskId := StartTask('wait', '{"ms":20}');
  Response := Client.AwaitTask(TaskId);
  try
    Expect<string>(Response.FindPath('result.status').AsString)
      .ToBe('completed');
    Expect<string>(Response.FindPath('result.result.content[0].text')
      .AsString).ToBe('waited');
    Expect<Boolean>(Response.FindPath('result.result.isError').AsBoolean)
      .ToBe(False);
    Expect<Boolean>(Response.FindPath('result.error') = nil).ToBe(True);
    // Stamped as the call would have answered it.
    Expect<string>(Response.FindPath('result.result.resultType').AsString)
      .ToBe('complete');
    Expect<Boolean>(Response.FindPath('result.result._meta') <> nil)
      .ToBe(True);
  finally
    Response.Free;
  end;
end;

// A tool error and a handler's own exception complete the task with
// isError; only JSON-RPC errors fail it.
procedure TTasksSuite.TestToolErrors;
var
  Response: TJSONObject;
begin
  RegisterFixture;
  Response := Client.AwaitTask(StartTask('fail'));
  try
    Expect<string>(Response.FindPath('result.status').AsString)
      .ToBe('completed');
    Expect<Boolean>(Response.FindPath('result.result.isError').AsBoolean)
      .ToBe(True);
    Expect<string>(Response.FindPath('result.result.content[0].text')
      .AsString).ToBe('it failed');
  finally
    Response.Free;
  end;
  Response := Client.AwaitTask(StartTask('crash'));
  try
    Expect<string>(Response.FindPath('result.status').AsString)
      .ToBe('completed');
    Expect<Boolean>(Response.FindPath('result.result.isError').AsBoolean)
      .ToBe(True);
  finally
    Response.Free;
  end;
end;

procedure TTasksSuite.TestProtocolErrors;
var
  Response: TJSONObject;
begin
  RegisterFixture;
  Response := Client.AwaitTask(StartTask('refuse'));
  try
    Expect<string>(Response.FindPath('result.status').AsString)
      .ToBe('failed');
    Expect<string>(Response.FindPath('result.error').AsJSON).ToBe(
      '{ "code" : -32602, "message" : "refused", "data" : { "why" : ' +
      '"test" } }');
    Expect<string>(Response.FindPath('result.statusMessage').AsString)
      .ToBe('refused');
    Expect<Boolean>(Response.FindPath('result.result') = nil).ToBe(True);
  finally
    Response.Free;
  end;
end;

// Each round's requests wait for tasks/update; the handler runs again
// with the answers and its state; a key reused in a later round is
// surfaced with a suffix, so no key is used twice.
procedure TTasksSuite.TestInputRounds;
var
  Response, Ack: TJSONObject;
  TaskId: string;
begin
  RegisterFixture;
  TaskId := StartTask('ask');
  Response := WaitFor(TaskId, 'input_required');
  try
    Expect<string>(Response.FindPath('result.status').AsString)
      .ToBe('input_required');
    Expect<string>(Response.FindPath('result.inputRequests.name.method')
      .AsString).ToBe('elicitation/create');
    Expect<Boolean>(Response.FindPath('result.requestState') = nil)
      .ToBe(True);
  finally
    Response.Free;
  end;
  // An unknown key is ignored, with the same empty ack.
  Ack := Client.Request('tasks/update', '{"taskId":"' + TaskId +
    '","inputResponses":{"nope":{"action":"accept"},"name":{"action":' +
    '"accept","content":{"v":"Ada"}}}}');
  try
    Expect<string>(Ack.Find('result').AsJSON).ToBe(
      '{ "resultType" : "complete", "_meta" : { ' +
      '"io.modelcontextprotocol/serverInfo" : { "name" : "tasks", ' +
      '"version" : "1.0" } } }');
  finally
    Ack.Free;
  end;
  Response := WaitFor(TaskId, 'input_required');
  try
    Expect<string>(Response.FindPath('result.status').AsString)
      .ToBe('input_required');
    Expect<Boolean>(Response.FindPath('result.inputRequests.name') = nil)
      .ToBe(True);
    Expect<Boolean>(Response.FindPath('result.inputRequests.name#2') <> nil)
      .ToBe(True);
    Expect<Boolean>(Response.FindPath('result.inputRequests.city') <> nil)
      .ToBe(True);
  finally
    Response.Free;
  end;
  // The suffixed key needs an answer of its own.
  Client.AnswerInput('name#2', '{"action":"accept","content":{"v":"Bo"}}');
  Client.AnswerInput('city', '{"action":"accept","content":{"v":"Oslo"}}');
  Response := Client.AwaitTask(TaskId);
  try
    Expect<string>(Response.FindPath('result.status').AsString)
      .ToBe('completed');
    Expect<string>(Response.FindPath('result.result.content[0].text')
      .AsString).ToBe('Ada/Bo/Oslo');
    Expect<Integer>(Rounds).ToBe(3);
  finally
    Response.Free;
  end;
end;

procedure TTasksSuite.TestPartialAnswers;
var
  Response: TJSONObject;
  TaskId: string;
begin
  RegisterFixture;
  TaskId := StartTask('pair');
  WaitFor(TaskId, 'input_required').Free;
  Client.Request('tasks/update', '{"taskId":"' + TaskId +
    '","inputResponses":{"a":{"action":"accept","content":{"v":"1"}}}}')
    .Free;
  // Still waiting, for b only, at once.
  Response := GetTask(TaskId);
  try
    Expect<string>(Response.FindPath('result.status').AsString)
      .ToBe('input_required');
    Expect<string>(Response.FindPath('result.inputRequests').AsJSON)
      .ToBe('{ "b" : ' + Response.FindPath('result.inputRequests.b').AsJSON +
      ' }');
  finally
    Response.Free;
  end;
  // An answer for a key already answered changes nothing.
  Client.Request('tasks/update', '{"taskId":"' + TaskId +
    '","inputResponses":{"a":{"action":"accept","content":{"v":"9"}}}}')
    .Free;
  Client.AnswerInput('b', '{"action":"accept","content":{"v":"2"}}');
  Response := Client.AwaitTask(TaskId);
  try
    Expect<string>(Response.FindPath('result.result.content[0].text')
      .AsString).ToBe('12');
  finally
    Response.Free;
  end;
  // Keys are matched exactly: by case, and with "=" in them.
  TaskId := StartTask('cased');
  WaitFor(TaskId, 'input_required').Free;
  Client.Request('tasks/update', '{"taskId":"' + TaskId +
    '","inputResponses":{"K":{"action":"accept","content":{"v":"2"}}}}')
    .Free;
  Response := GetTask(TaskId);
  try
    Expect<Boolean>((Response.FindPath('result.inputRequests.k') <> nil) and
      (Response.FindPath('result.inputRequests.K') = nil)).ToBe(True);
  finally
    Response.Free;
  end;
  Client.AnswerInput('k', '{"action":"accept","content":{"v":"1"}}');
  Client.AnswerInput('x=y', '{"action":"accept","content":{"v":"3"}}');
  Response := Client.AwaitTask(TaskId);
  try
    Expect<string>(Response.FindPath('result.result.content[0].text')
      .AsString).ToBe('123');
  finally
    Response.Free;
  end;
end;

// An input request the creating request's client did not declare fails
// the task with -32021, as a call's round would be refused.
// The questions go only to a poll that declares what they need: one
// that does not gets -32021, and the task waits on for one that does.
procedure TTasksSuite.TestInputCapabilityGate;
var
  Response: TJSONObject;
  TaskId: string;
  Step: Integer;
begin
  RegisterFixture;
  TaskId := StartTask('sample');
  Response := nil;
  for Step := 1 to 500 do
  begin
    FreeAndNil(Response);
    Response := GetTask(TaskId);
    if ErrorCode(Response) <> 0 then
      Break;
    Sleep(10);
  end;
  try
    Expect<Integer>(ErrorCode(Response)).ToBe(-32021);
    Expect<string>(Response.FindPath('error.data').AsJSON).ToBe(
      '{ "requiredCapabilities" : { "sampling" : {} } }');
  finally
    Response.Free;
  end;
  Client.SetClientCapabilities('{"sampling":{},"extensions":' +
    '{"io.modelcontextprotocol/tasks":{}}}');
  Response := GetTask(TaskId);
  try
    Expect<string>(Response.FindPath('result.status').AsString)
      .ToBe('input_required');
    Expect<string>(Response.FindPath('result.inputRequests.s.method')
      .AsString).ToBe('sampling/createMessage');
  finally
    Response.Free;
  end;
end;

procedure TTasksSuite.TestCancel;
var
  Response, Ack: TJSONObject;
  TaskId, Finished: string;
  Step: Integer;
begin
  RegisterFixture;
  TaskId := StartTask('wait');
  Expect<Boolean>(AwaitStart).ToBe(True);
  Ack := Client.Request('tasks/cancel', '{"taskId":"' + TaskId + '"}');
  try
    Expect<string>(Ack.FindPath('result.resultType').AsString)
      .ToBe('complete');
    Expect<Boolean>((Ack.FindPath('result.taskId') = nil) and
      (Ack.FindPath('result.status') = nil)).ToBe(True);
  finally
    Ack.Free;
  end;
  Response := GetTask(TaskId);
  try
    Expect<string>(Response.FindPath('result.status').AsString)
      .ToBe('cancelled');
    Expect<string>(Response.FindPath('result.statusMessage').AsString)
      .ToBe('The client cancelled the task');
  finally
    Response.Free;
  end;
  // The handler sees it and stops; its late result does not replace the
  // status.
  for Step := 1 to 500 do
    if not SawCancel then
      Sleep(10);
  Expect<Boolean>(SawCancel).ToBe(True);
  Sleep(20);
  Response := GetTask(TaskId);
  try
    Expect<string>(Response.FindPath('result.status').AsString)
      .ToBe('cancelled');
  finally
    Response.Free;
  end;
  // A finished task: the same ack, and nothing changes.
  Finished := StartTask('wait', '{"ms":0}');
  Client.AwaitTask(Finished).Free;
  Ack := Client.Request('tasks/cancel', '{"taskId":"' + Finished + '"}');
  try
    Expect<string>(Ack.FindPath('result.resultType').AsString)
      .ToBe('complete');
  finally
    Ack.Free;
  end;
  Response := GetTask(Finished);
  try
    Expect<string>(Response.FindPath('result.status').AsString)
      .ToBe('completed');
  finally
    Response.Free;
  end;
  // A task waiting for input is cancelled too.
  TaskId := StartTask('pair');
  WaitFor(TaskId, 'input_required').Free;
  Client.Request('tasks/cancel', '{"taskId":"' + TaskId + '"}').Free;
  Response := GetTask(TaskId);
  try
    Expect<string>(Response.FindPath('result.status').AsString)
      .ToBe('cancelled');
    Expect<Boolean>(Response.FindPath('result.inputRequests') = nil)
      .ToBe(True);
  finally
    Response.Free;
  end;
end;

procedure TTasksSuite.TestMissingExtension;
const
  TASK_READS: array[0..1] of string = ('tasks/get', 'tasks/cancel');
  DATA = '{ "requiredCapabilities" : { "extensions" : { ' +
    '"io.modelcontextprotocol/tasks" : {} } } }';
var
  Response: TJSONObject;
  TaskId, Method: string;
begin
  RegisterFixture;
  TaskId := StartTask('wait', '{"ms":0}');
  Client.SetClientCapabilities('{}');
  for Method in TASK_READS do
  begin
    Response := Client.Request(Method, '{"taskId":"' + TaskId + '"}');
    try
      Expect<Integer>(ErrorCode(Response)).ToBe(-32021);
      Expect<string>(Response.FindPath('error.data').AsJSON).ToBe(DATA);
    finally
      Response.Free;
    end;
  end;
  Response := Client.Request('tasks/update', '{"taskId":"' + TaskId +
    '","inputResponses":{}}');
  try
    Expect<Integer>(ErrorCode(Response)).ToBe(-32021);
  finally
    Response.Free;
  end;
  // A tool that runs only as a task cannot run for this request.
  Response := Client.CallTool('must', '{"ms":0}');
  try
    Expect<Integer>(ErrorCode(Response)).ToBe(-32021);
    Expect<string>(Response.FindPath('error.data').AsJSON).ToBe(DATA);
  finally
    Response.Free;
  end;
  // Declared on the request alone, it counts (per-request capabilities).
  Response := Client.Request('tools/call', '{"name":"must","arguments":' +
    '{"ms":0},"_meta":{"io.modelcontextprotocol/clientCapabilities":' +
    TASKS_CAPS + '}}');
  try
    Expect<string>(Response.FindPath('result.resultType').AsString)
      .ToBe('task');
  finally
    Response.Free;
  end;
end;

procedure TTasksSuite.TestClassicEra;
var
  Session: TMCPSession;
  Line: string;
begin
  RegisterFixture;
  Session := FServer.CreateSession;
  try
    FServer.HandleMessage(Session, '{"jsonrpc":"2.0","id":1,"method":' +
      '"initialize","params":{"protocolVersion":"2025-11-25",' +
      '"capabilities":{},"clientInfo":{"name":"c","version":"1"}}}', Line);
    // The classic initialize declares no Tasks.
    Expect<Boolean>(Pos('io.modelcontextprotocol/tasks', Line) = 0)
      .ToBe(True);
    FServer.HandleMessage(Session, '{"jsonrpc":"2.0","method":' +
      '"notifications/initialized"}', Line);
    FServer.HandleMessage(Session, '{"jsonrpc":"2.0","id":2,"method":' +
      '"tasks/get","params":{"taskId":"x"}}', Line);
    Expect<string>(Line).ToBe('{ "jsonrpc" : "2.0", "id" : 2, "error" : ' +
      '{ "code" : -32601, "message" : "Method not found: tasks/get" } }');
    // An optional tool runs as usual; one that runs only as a task is a
    // tool error.
    FServer.HandleMessage(Session, '{"jsonrpc":"2.0","id":3,"method":' +
      '"tools/call","params":{"name":"wait","arguments":{"ms":0}}}', Line);
    Expect<Boolean>(Pos('"text" : "waited"', Line) > 0).ToBe(True);
    FServer.HandleMessage(Session, '{"jsonrpc":"2.0","id":4,"method":' +
      '"tools/call","params":{"name":"must","arguments":{"ms":0}}}', Line);
    Expect<string>(Line).ToBe('{ "jsonrpc" : "2.0", "id" : 4, "result" : ' +
      '{ "content" : [{ "type" : "text", "text" : "Tool \"must\" runs only ' +
      'as a task, which is not available to legacy-era clients" }], ' +
      '"isError" : true } }');
  finally
    Session.Free;
  end;
end;

procedure TTasksSuite.TestBadParams;
var
  Response: TJSONObject;
  TaskId: string;
begin
  RegisterFixture;
  Response := GetTask('no-such-task');
  try
    Expect<Integer>(ErrorCode(Response)).ToBe(-32602);
    Expect<string>(Response.FindPath('error.message').AsString)
      .ToBe('Invalid params: Failed to retrieve task: Task not found');
  finally
    Response.Free;
  end;
  Response := Client.Request('tasks/get', '{"taskId":7}');
  try
    Expect<Integer>(ErrorCode(Response)).ToBe(-32602);
  finally
    Response.Free;
  end;
  Response := Client.Request('tasks/cancel', '{}');
  try
    Expect<Integer>(ErrorCode(Response)).ToBe(-32602);
  finally
    Response.Free;
  end;
  TaskId := StartTask('pair');
  Response := Client.Request('tasks/update', '{"taskId":"' + TaskId + '"}');
  try
    Expect<Integer>(ErrorCode(Response)).ToBe(-32602);
  finally
    Response.Free;
  end;
  Response := Client.Request('tasks/update', '{"taskId":"nope",' +
    '"inputResponses":{}}');
  try
    Expect<Integer>(ErrorCode(Response)).ToBe(-32602);
  finally
    Response.Free;
  end;
  // The removed v1 methods are unknown.
  Response := Client.Request('tasks/result', '{"taskId":"' + TaskId + '"}');
  try
    Expect<Integer>(ErrorCode(Response)).ToBe(-32601);
  finally
    Response.Free;
  end;
end;

// A call that gathers input first and becomes a task on its retry brings
// the answers and its state to the task's handler.
procedure TTasksSuite.TestSelectorAfterInput;
var
  Response: TJSONObject;
  TaskId: string;
begin
  FServer.RegisterTool('gather', 'Input, then a task', NO_ARGUMENTS, Gather);
  EnableTasks(FServer).SetSelector(GatherSelector);
  Response := Client.CallTool('gather');
  try
    Expect<string>(Response.FindPath('result.resultType').AsString)
      .ToBe('input_required');
    Expect<Boolean>(Response.FindPath('result.taskId') = nil).ToBe(True);
  finally
    Response.Free;
  end;
  Client.AnswerInput('who', '{"action":"accept","content":{"v":"Ada"}}');
  Response := Client.CallTool('gather');
  try
    Expect<string>(Response.FindPath('result.resultType').AsString)
      .ToBe('task');
    Expect<Boolean>(Response.FindPath('result.requestState') = nil)
      .ToBe(True);
    TaskId := Response.FindPath('result.taskId').AsString;
  finally
    Response.Free;
  end;
  Response := Client.AwaitTask(TaskId);
  try
    Expect<string>(Response.FindPath('result.result.content[0].text')
      .AsString).ToBe('gathering:Ada');
  finally
    Response.Free;
  end;
end;

procedure TTasksSuite.TestMaxActive;
var
  Response: TJSONObject;
  First, Freed: string;
  Step: Integer;
begin
  RegisterFixture;
  FTasks.MaxActive := 1;
  // A handler slow to stop keeps its place after it is cancelled.
  StubbornMs := 300;
  First := StartTask('stubborn');
  Expect<Boolean>(First <> '').ToBe(True);
  Expect<Boolean>(AwaitStart).ToBe(True);
  // Full: an optional tool runs as usual, a required one is refused.
  Response := Client.CallTool('wait', '{"ms":0}');
  try
    Expect<string>(Response.FindPath('result.resultType').AsString)
      .ToBe('complete');
  finally
    Response.Free;
  end;
  Client.Request('tasks/cancel', '{"taskId":"' + First + '"}').Free;
  Response := Client.CallTool('must', '{"ms":0}');
  try
    Expect<Integer>(ErrorCode(Response)).ToBe(-32603);
    Expect<string>(Response.FindPath('error.message').AsString)
      .ToBe('Too many tasks are running; try again later');
  finally
    Response.Free;
  end;
  // Once its handler has returned, the place is free.
  Freed := '';
  for Step := 1 to 500 do
  begin
    Freed := StartTask('must', '{"ms":0}');
    if Freed <> '' then
      Break;
    Sleep(10);
  end;
  Expect<Boolean>(Freed <> '').ToBe(True);
end;

procedure TTasksSuite.TestTtl;
var
  Response: TJSONObject;
  TaskId: string;
  Step: Integer;
begin
  RegisterFixture;
  FTasks.TtlMs := 100;
  TaskId := StartTask('wait');
  Expect<Boolean>(AwaitStart).ToBe(True);
  Response := GetTask(TaskId);
  try
    Expect<Integer>(Response.FindPath('result.ttlMs').AsInteger).ToBe(100);
  finally
    Response.Free;
  end;
  // The handler sees its deadline without any request.
  for Step := 1 to 500 do
    if not SawCancel then
      Sleep(10);
  Expect<Boolean>(SawCancel).ToBe(True);
  // Gone.
  Response := GetTask(TaskId);
  try
    Expect<Integer>(ErrorCode(Response)).ToBe(-32602);
  finally
    Response.Free;
  end;
  for Step := 1 to 500 do
    if not SawCancel then
      Sleep(10);
  Expect<Boolean>(SawCancel).ToBe(True);
end;

// No task goes before its ttlMs ends: a full store takes no new one.
procedure TTasksSuite.TestMaxKept;
var
  Response: TJSONObject;
  First, Second: string;
begin
  RegisterFixture;
  FTasks.MaxActive := 2;
  FTasks.MaxKept := 2;
  First := StartTask('wait', '{"ms":0}');
  Client.AwaitTask(First).Free;
  Second := StartTask('wait', '{"ms":0}');
  Client.AwaitTask(Second).Free;
  Response := Client.CallTool('wait', '{"ms":0}');
  try
    Expect<string>(Response.FindPath('result.resultType').AsString)
      .ToBe('complete');
  finally
    Response.Free;
  end;
  Response := Client.CallTool('must', '{"ms":0}');
  try
    Expect<Integer>(ErrorCode(Response)).ToBe(-32603);
  finally
    Response.Free;
  end;
  Response := GetTask(First);
  try
    Expect<string>(Response.FindPath('result.status').AsString)
      .ToBe('completed');
  finally
    Response.Free;
  end;
end;

procedure TTasksSuite.TestGuards;
var
  Raised: Boolean;
  Tasks: TMCPTasks;
  Stub: THookStub;
begin
  RegisterFixture;
  Expect<Boolean>(EnableTasks(FServer) = FTasks).ToBe(True);
  Raised := False;
  try
    FTasks.SetToolSupport('missing', tsOptional);
  except
    on E: EMCPServer do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  Raised := False;
  try
    FTasks.TtlMs := 0;
  except
    on E: EMCPServer do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  Raised := False;
  try
    FTasks.TtlMs := MCP_TASK_MAX_TTL_MS + 1;
  except
    on E: EMCPServer do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  FTasks.TtlMs := MCP_TASK_MAX_TTL_MS;
  Raised := False;
  try
    FTasks.MaxKept := FTasks.MaxActive - 1;
  except
    on E: EMCPServer do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  // One extension takes tool calls over.
  Stub := THookStub.Create;
  try
    Raised := False;
    try
      FServer.SetToolCallHook(Stub.Take);
    except
      on E: EMCPServer do
        Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
  finally
    Stub.Free;
  end;
  Tasks := FTasks;
  // After the server started.
  Client.Discover.Free;
  Raised := False;
  try
    Tasks.SetToolSupport('echo', tsOptional);
  except
    on E: EMCPServer do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TTasksSuite.TestUtf8Result;
var
  TaskId: string;
begin
  RegisterFixture;
  TaskId := StartTask('greeting');
  Client.AwaitTask(TaskId).Free;
  // Byte-exact on the encoded wire line; the handler had the creating
  // request's client, capabilities and _meta, and no notifier.
  Expect<Boolean>(Pos('"text" : "' + GRUSSE + ' ' + GRIN +
    ' mcp-test-client/1.0.0 form meta no notifier"',
    Client.LastResponseLine) > 0).ToBe(True);
end;

// Freeing the server cancels a running task and a parked one, and
// waits for their workers.
procedure TTasksSuite.TestTeardownCancels;
var
  Parked: string;
  Response: TJSONObject;
begin
  RegisterFixture;
  StartTask('wait');
  Expect<Boolean>(AwaitStart).ToBe(True);
  Parked := StartTask('pair');
  Response := WaitFor(Parked, 'input_required');
  try
    Expect<string>(Response.FindPath('result.status').AsString)
      .ToBe('input_required');
  finally
    Response.Free;
  end;
  FreeAndNil(FClient);
  FreeAndNil(FServer);
  Expect<Boolean>(SawCancel).ToBe(True);
end;

procedure TTasksSuite.TestTeardownBeforeAdoptedOwners;
var
  Owner: TToolOwner;
  Lines: string;
begin
  RegisterFixture;
  Owner := TToolOwner.Create;
  FServer.RegisterTool('spin', 'Reads its owner', NO_ARGUMENTS, Owner.Spin);
  FTasks.SetToolSupport('spin', tsOptional);
  FServer.Adopt(Owner);
  StartTask('spin');
  Expect<Boolean>(AwaitStart).ToBe(True);
  Owner.Server := FServer;
  Owner.Session := FServer.CreateSession;
  FreeAndNil(FClient);
  // The owner is freed with the server, so its callbacks are read first.
  Lines := '';
  OwnerLines := @Lines;
  FreeAndNil(FServer);
  Expect<Boolean>(OwnerFreed).ToBe(True);
  Expect<Boolean>(UsedAfterFree).ToBe(False);
  // The tools/call ran as usual, not as a task; tasks/get found nothing.
  Expect<Boolean>((Pos('"text" : "waited"', Lines) > 0) and
    (Pos('"resultType" : "task"', Lines) = 0) and
    (Pos('"code" : -32602', Lines) > 0)).ToBe(True);
end;

// A round that asks for nothing runs again at once with its state.
procedure TTasksSuite.TestStateOnlyRound;
var
  Response: TJSONObject;
  TaskId: string;
begin
  RegisterFixture;
  // AwaitTask answers a key with a '#' only with an answer of its own,
  // a numeric suffix the handler chose included.
  Client.AnswerInput('q', '{"action":"accept","content":{"v":"wrong"}}');
  Client.AnswerInput('c', '{"action":"accept","content":{"v":"wrong"}}');
  TaskId := StartTask('drafty');
  Response := Client.AwaitTask(TaskId);
  try
    Expect<string>(Response.FindPath('result.status').AsString)
      .ToBe('input_required');
  finally
    Response.Free;
  end;
  Client.AnswerInput('q#draft', '{"action":"accept","content":{"v":"o"}}');
  Client.AnswerInput('c#2', '{"action":"accept","content":{"v":"k"}}');
  Response := Client.AwaitTask(TaskId);
  try
    Expect<string>(Response.FindPath('result.result.content[0].text')
      .AsString).ToBe('ok');
  finally
    Response.Free;
  end;
  Response := Client.AwaitTask(StartTask('stateonly'));
  try
    Expect<string>(Response.FindPath('result.result.content[0].text')
      .AsString).ToBe('ran again');
  finally
    Response.Free;
  end;
end;

// A result the wire cannot carry fails the task once, with -32603,
// instead of failing every poll.
procedure TTasksSuite.TestUnsendableResult;
var
  Response: TJSONObject;
begin
  RegisterFixture;
  // A malformed input request fails the task before any client sees it.
  Response := Client.AwaitTask(StartTask('bare'));
  try
    Expect<string>(Response.FindPath('result.status').AsString)
      .ToBe('failed');
    Expect<string>(Response.FindPath('result.error.message').AsString)
      .ToBe('Tool "bare" produced a malformed input request: ' +
      'elicitation/create without its params');
  finally
    Response.Free;
  end;
  Response := Client.AwaitTask(StartTask('hollow'));
  try
    Expect<string>(Response.FindPath('result.error.message').AsString)
      .ToBe('Tool "hollow" produced a malformed input request: ' +
      'elicitation/create without its message, url or requestedSchema');
  finally
    Response.Free;
  end;
  Response := Client.AwaitTask(StartTask('unsendable'));
  try
    Expect<string>(Response.FindPath('result.status').AsString)
      .ToBe('failed');
    Expect<Integer>(Response.FindPath('result.error.code').AsInteger)
      .ToBe(-32603);
  finally
    Response.Free;
  end;
end;

// An answer that is no result object is refused, and its question stays
// open.
procedure TTasksSuite.TestMalformedAnswer;
var
  Response: TJSONObject;
  TaskId: string;
begin
  RegisterFixture;
  TaskId := StartTask('pair');
  WaitFor(TaskId, 'input_required').Free;
  Response := Client.Request('tasks/update', '{"taskId":"' + TaskId +
    '","inputResponses":{"a":{"action":"accept","content":{"v":"1"}},' +
    '"b":"yes"}}');
  try
    Expect<Integer>(ErrorCode(Response)).ToBe(-32602);
    Expect<string>(Response.FindPath('error.message').AsString)
      .ToBe('Invalid params: inputResponses["b"] must be an object');
  finally
    Response.Free;
  end;
  // Neither was taken.
  Response := GetTask(TaskId);
  try
    Expect<Boolean>((Response.FindPath('result.inputRequests.a') <> nil) and
      (Response.FindPath('result.inputRequests.b') <> nil)).ToBe(True);
  finally
    Response.Free;
  end;
end;

// A listen stream that lists a task gets its whole state, first as it
// is, then after each change, with the subscription id; unknown and
// repeated ids are left out of the acknowledgment.
procedure TTasksSuite.TestStatusNotifications;
var
  Session: TMCPSession;
  Host: TMCPStreamHost;
  Stream: TMCPStream;
  Line, Lines, TaskId: string;
  Notification: TJSONObject;
begin
  RegisterFixture;
  TaskId := StartTask('pair');
  WaitFor(TaskId, 'input_required').Free;
  Host := TMCPStreamHost.Create;
  Session := FServer.CreateSession;
  Stream := nil;
  try
    Session.StreamHost := Host;
    FServer.HandleMessage(Session, '{"jsonrpc":"2.0","id":9,"method":' +
      '"subscriptions/listen","params":{"notifications":{"taskIds":["' +
      TaskId + '","nope","' + TaskId + '"]},' + META + '}}', Line);
    Stream := Host.TakeParked;
    Expect<Boolean>(Stream <> nil).ToBe(True);
    Lines := '';
    Stream.Step(CaptureSink, @Lines);
    Expect<string>(Copy(Lines, 1, Pos(#10, Lines))).ToBe('{ "jsonrpc" : ' +
      '"2.0", "method" : "notifications/subscriptions/acknowledged", ' +
      '"params" : { "notifications" : { "taskIds" : ["' + TaskId + '"] }, ' +
      '"_meta" : { "io.modelcontextprotocol/subscriptionId" : 9 } } }'#10);
    Notification := TJSONObject(MCPParseJSON(Copy(Lines, Pos(#10, Lines) + 1,
      MaxInt)));
    try
      Expect<string>(Notification.Get('method', '')).ToBe(
        'notifications/tasks');
      Expect<string>(Notification.FindPath('params.status').AsString)
        .ToBe('input_required');
      Expect<Boolean>(Notification.FindPath('params.inputRequests.b') <> nil)
        .ToBe(True);
      Expect<Integer>(TJSONObject(Notification.FindPath('params._meta'))
        .Get('io.modelcontextprotocol/subscriptionId', 0)).ToBe(9);
    finally
      Notification.Free;
    end;
    // Nothing changed: nothing sent.
    Lines := '';
    Stream.Step(CaptureSink, @Lines);
    Expect<string>(Lines).ToBe('');
    // A partial answer is a change; then the result.
    Client.Request('tasks/update', '{"taskId":"' + TaskId +
      '","inputResponses":{"a":{"action":"accept","content":{"v":"1"}}}}')
      .Free;
    Lines := '';
    Stream.Step(CaptureSink, @Lines);
    Expect<Boolean>((Pos('"inputRequests" : { "b"', Lines) > 0) and
      (Pos('"a" :', Lines) = 0)).ToBe(True);
    Client.Request('tasks/update', '{"taskId":"' + TaskId +
      '","inputResponses":{"b":{"action":"accept","content":{"v":"2"}}}}')
      .Free;
    // Two changes before the stream is stepped again: working, then
    // completed, both sent, in order (#138 review).
    Client.AwaitTask(TaskId).Free;
    Lines := '';
    Stream.Step(CaptureSink, @Lines);
    Expect<Boolean>((Pos('"status" : "working"', Lines) > 0) and
      (Pos('"status" : "working"', Lines) <
      Pos('"status" : "completed"', Lines))).ToBe(True);
    Expect<Boolean>(Pos('"result" : { "content" : [{ "type" : "text", ' +
      '"text" : "12" }]', Lines) > 0).ToBe(True);
  finally
    Stream.Free;
    Session.Free;
    Host.Free;
  end;
end;

// A taskIds source added before EnableTasks: it refuses, and changes
// nothing, so the server neither declares Tasks nor serves its methods.
procedure TTasksSuite.TestEnableRefusedCleanly;
var
  Raised: Boolean;
  Response: TJSONObject;
begin
  FServer.RegisterTool('echo', 'Sync only', NO_ARGUMENTS, Echo);
  AddSubscriptionSource(FServer, TTaskIdsStub.Create);
  Raised := False;
  try
    EnableTasks(FServer);
  except
    on E: EMCPServer do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  Expect<Boolean>(FServer.Adopted(TMCPTasks) = nil).ToBe(True);
  Expect<string>(FServer.HookProblem(['tasks/get'], '')).ToBe('');
  Response := Client.Discover;
  try
    Expect<Boolean>(Pos('io.modelcontextprotocol/tasks',
      Response.AsJSON) = 0).ToBe(True);
  finally
    Response.Free;
  end;
end;

procedure TTasksSuite.TestListenRefusals;
var
  Session: TMCPSession;
  Host: TMCPStreamHost;
  Stream: TMCPStream;
  Line, Lines, TaskId: string;
begin
  RegisterFixture;
  Host := TMCPStreamHost.Create;
  Session := FServer.CreateSession;
  try
    Session.StreamHost := Host;
    // taskIds without the extension: -32021.
    FServer.HandleMessage(Session, '{"jsonrpc":"2.0","id":1,"method":' +
      '"subscriptions/listen","params":{"notifications":{"taskIds":[]},' +
      '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
      '"io.modelcontextprotocol/clientCapabilities":{}}}}', Line);
    Expect<Boolean>(Pos('"code" : -32021', Line) > 0).ToBe(True);
    Expect<Boolean>(Host.TakeParked = nil).ToBe(True);
    FServer.HandleMessage(Session, '{"jsonrpc":"2.0","id":2,"method":' +
      '"subscriptions/listen","params":{"notifications":{"taskIds":"x"},' +
      META + '}}', Line);
    Expect<Boolean>(Pos('"code" : -32602', Line) > 0).ToBe(True);
    Expect<Boolean>(Host.TakeParked = nil).ToBe(True);
    // A stream whose request did not declare elicitation gets no state of
    // a task that waits on an elicitation, as tasks/get would refuse it.
    TaskId := StartTask('pair');
    WaitFor(TaskId, 'input_required').Free;
    FServer.HandleMessage(Session, '{"jsonrpc":"2.0","id":3,"method":' +
      '"subscriptions/listen","params":{"notifications":{"taskIds":["' +
      TaskId + '"]},"_meta":{"io.modelcontextprotocol/protocolVersion":' +
      '"2026-07-28","io.modelcontextprotocol/clientCapabilities":' +
      '{"extensions":{"io.modelcontextprotocol/tasks":{}}}}}}', Line);
    Stream := Host.TakeParked;
    try
      Lines := '';
      Stream.Step(CaptureSink, @Lines);
      Expect<Boolean>((Pos('acknowledged', Lines) > 0) and
        (Pos('notifications/tasks', Lines) = 0)).ToBe(True);
    finally
      Stream.Free;
    end;
  finally
    Session.Free;
    Host.Free;
  end;
end;

procedure TTasksSuite.SetupTests;
begin
  Test('the extension is declared with {}', TestDeclaration);
  Test('a sync tool, and an optional one without the extension, run as ' +
    'usual', TestSynchronousCalls);
  Test('a task tool answers a flat CreateTaskResult, readable at once',
    TestCreateTaskResult);
  Test('tasks/get inlines the result once completed', TestCompletion);
  Test('a tool error and a raised exception complete with isError',
    TestToolErrors);
  Test('a JSON-RPC error fails the task with that error',
    TestProtocolErrors);
  Test('input rounds: answers, state, unknown keys, keys never reused',
    TestInputRounds);
  Test('a partial update leaves only the unanswered key', TestPartialAnswers);
  Test('a poll that lacks an input''s capability gets -32021',
    TestInputCapabilityGate);
  Test('tasks/cancel: empty ack, cancelled, idempotent, while waiting',
    TestCancel);
  Test('without the extension: -32021, and per-request declaration counts',
    TestMissingExtension);
  Test('a classic client: no declaration, -32601, required tools refused',
    TestClassicEra);
  Test('unknown tasks and bad params answer -32602', TestBadParams);
  Test('a selector runs the retry of an input round as a task',
    TestSelectorAfterInput);
  Test('MaxActive: optional calls run as usual, required ones -32603',
    TestMaxActive);
  Test('a task past its ttlMs is gone and its handler cancelled', TestTtl);
  Test('MaxKept: a full store takes no new task', TestMaxKept);
  Test('settings and late changes are guarded', TestGuards);
  Test('a non-ASCII result goes out byte-exact; the handler''s context',
    TestUtf8Result);
  Test('freeing the server cancels running tasks and waits',
    TestTeardownCancels);
  Test('teardown stops tasks before it frees what their tools use',
    TestTeardownBeforeAdoptedOwners);
  Test('a round that asks for nothing runs again with its state',
    TestStateOnlyRound);
  Test('an unsendable result or a malformed request fails with -32603',
    TestUnsendableResult);
  Test('an answer that is no object is refused and taken by no one',
    TestMalformedAnswer);
  Test('a listen stream gets a task''s state after each change',
    TestStatusNotifications);
  Test('taskIds without the extension or as a non-array are refused',
    TestListenRefusals);
  Test('EnableTasks refused by a listen conflict changes nothing',
    TestEnableRefusedCleanly);
end;

begin
  TestRunnerProgram.AddSuite(TTasksSuite.Create('Tasks extension'));
  TestRunnerProgram.Run;
end.
