{ MCP.Testing.Test — the in-process test client (#97) against a small
  server: the envelope it adds, each helper, captured notifications,
  MRTR rounds answered from canned responses, and errors surfaced as
  responses. Payloads with multi-byte UTF-8 are asserted byte-exact. }

program MCP.Testing.Test;

{$I MCP.inc}

uses
  Classes,
  SysUtils,

  fpjson,
  MCP.Protocol,
  MCP.Server,
  MCP.Testing,
  TestingPascalLibrary;

const
  UTF8_NAME = 'Ad' + #$C3#$A9 + ' ' + #$F0#$9F#$98#$80;

type
  TTestClientSuite = class(TTestSuite)
  private
    FServer: TMCPServer;
    FClient: TMCPTestClient;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;
    procedure TestEnvelopeAdded;
    procedure TestDiscoverAndLists;
    procedure TestCallTool;
    procedure TestNotificationsCaptured;
    procedure TestInputAnsweredFromCannedResponses;
    procedure TestUnansweredInputReturned;
    procedure TestPromptAndResource;
    procedure TestErrorsAreResponses;
    procedure TestBadJsonRaises;
    procedure TestEscapedUnicodeAsTheServerParsesIt;
    procedure TestNotificationsAcrossRounds;
    procedure TestCompletion;
    procedure TestGuideShowsTheExample;
    procedure TestFailedCallLeavesNoNotifications;
    procedure TestLogAndProgressInOrder;
    procedure TestStateOnlyRound;
  end;

function EchoHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPTextResult(AArguments.Get('message', '') + '|' + ACtx.ClientName +
    '|' + BoolToStr(ACtx.HasCapability('elicitation'), 'elicit', 'plain'));
end;

function ProgressHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  MCPReportProgress(ACtx, 1, 2, 'half');
  MCPReportProgress(ACtx, 2, 2, 'done');
  Result := MCPTextResult('ok');
end;

// Asks who to greet, keeping 'asked' as its state; the second round's
// text carries the state it got back, so the retry must echo it.
function AskNameHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Requests: TJSONObject;
  Content: TJSONObject;
begin
  MCPReportProgress(ACtx, 1, 2, 'round');
  Content := MCPElicitationContent(ACtx, 'who');
  if Content <> nil then
    Exit(MCPTextResult('Hello, ' + Content.Get('name', '?') + ' (' +
      ACtx.RequestState + ')'));
  Requests := TJSONObject.Create;
  Requests.Add('who', MCPElicitFormRequest('Who?',
    TJSONObject(GetJSON('{"type":"object","properties":{"name":' +
    '{"type":"string"}},"required":["name"]}'))));
  Result := MCPInputRequired(Requests, 'asked');
end;

// Progress, a log message, progress again.
function ChattyHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  MCPReportProgress(ACtx, 1, 3, 'one');
  MCPLogMessage(ACtx, 'info', 'between');
  MCPReportProgress(ACtx, 3, 3, 'three');
  Result := MCPTextResult('chatty');
end;

// Asks for nothing but keeps a state for its second round, which says
// whether input responses came with it.
function LaterHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  if ACtx.RequestState = '' then
    Exit(MCPInputRequired(TJSONObject.Create, 'later'));
  Result := MCPTextResult(BoolToStr(ACtx.InputResponses = nil, 'none', 'some') +
    '|' + ACtx.RequestState);
end;

function GreetPrompt(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  Result := MCPMessages([MCPUserMessage('Greet ' + AArguments.Get('name', ''))]);
end;

procedure TTestClientSuite.BeforeEach;
begin
  FServer := TMCPServer.Create('fixture', '1.0');
  FServer.RegisterTool('echo', 'Echo', '{"type":"object"}', EchoHandler);
  FServer.RegisterTool('progress', 'Progress', '{"type":"object"}',
    ProgressHandler);
  FServer.RegisterTool('ask_name', 'Asks', '{"type":"object"}', AskNameHandler);
  FServer.RegisterTool('chatty', 'Chatty', '{"type":"object"}', ChattyHandler);
  FServer.RegisterTool('later', 'Later', '{"type":"object"}', LaterHandler);
  FServer.RegisterPrompt('greet', 'Greet', PromptArguments.Add('name'),
    GreetPrompt);
  FServer.RegisterPromptCompletion('greet', 'name', ['Ada', 'Alan', 'Grace']);
  FServer.RegisterTextResource('mem://note', 'note', 'text/plain', UTF8_NAME);
  FClient := TMCPTestClient.Create(FServer);
end;

procedure TTestClientSuite.AfterEach;
begin
  FreeAndNil(FClient);
  FreeAndNil(FServer);
end;

// The string at APath in AResponse, which it frees.
function StringAt(AResponse: TJSONObject; const APath: string): string;
begin
  try
    Result := AResponse.FindPath(APath).AsString;
  finally
    AResponse.Free;
  end;
end;

// The first text block of a tool result, which it frees.
function TextOf(AResponse: TJSONObject): string;
begin
  Result := StringAt(AResponse, 'result.content[0].text');
end;

// The completion values of AResponse, comma-separated.
function SerializeValues(AResponse: TJSONObject): string;
var
  Values: TJSONData;
  I: Integer;
begin
  Result := '';
  Values := AResponse.FindPath('result.completion.values');
  if Values <> nil then
    for I := 0 to Values.Count - 1 do
      Result := Result + Values.Items[I].AsString + ',';
end;

// The text of the repository file ARelative, found from the working
// directory or one of its parents.
function RepoFile(const ARelative: string): string;
var
  Dir: string;
  Level: Integer;
  Bytes: TStringStream;
begin
  Result := '';
  Dir := IncludeTrailingPathDelimiter(GetCurrentDir);
  for Level := 0 to 4 do
  begin
    if FileExists(Dir + ARelative) then
    begin
      Bytes := TStringStream.Create('');
      try
        Bytes.LoadFromFile(Dir + ARelative);
        Exit(Bytes.DataString);
      finally
        Bytes.Free;
      end;
    end;
    Dir := IncludeTrailingPathDelimiter(ExtractFileDir(ExcludeTrailingPathDelimiter(Dir)));
  end;
end;

procedure TTestClientSuite.TestEnvelopeAdded;
begin
  // Client info and capabilities travel in every request's _meta.
  FClient.ClientName := 'suite';
  Expect<string>(TextOf(FClient.CallTool('echo', '{"message":"hi"}')))
    .ToBe('hi|suite|plain');
  FClient.SetClientCapabilities('{"elicitation":{}}');
  Expect<string>(TextOf(FClient.CallTool('echo', '{"message":"hi"}')))
    .ToBe('hi|suite|elicit');
end;

// The count of the array at APath in AResponse, which it frees.
function CountOf(AResponse: TJSONObject; const APath: string): Integer;
begin
  try
    Result := TJSONArray(AResponse.FindPath(APath)).Count;
  finally
    AResponse.Free;
  end;
end;

procedure TTestClientSuite.TestDiscoverAndLists;
begin
  Expect<string>(StringAt(FClient.Discover, 'result.serverInfo.name'))
    .ToBe('fixture');
  Expect<Integer>(CountOf(FClient.ListTools, 'result.tools')).ToBe(5);
  Expect<Integer>(CountOf(FClient.ListPrompts, 'result.prompts')).ToBe(1);
  Expect<Integer>(CountOf(FClient.ListResources, 'result.resources')).ToBe(1);
end;

procedure TTestClientSuite.TestCallTool;
begin
  Expect<string>(TextOf(FClient.CallTool('echo',
    '{"message":"' + UTF8_NAME + '"}'))).ToBe(UTF8_NAME + '|mcp-test-client|plain');
  // On the wire too, byte for byte.
  Expect<Boolean>(Pos('"text" : "' + UTF8_NAME + '|mcp-test-client|plain"',
    FClient.LastResponseLine) > 0).ToBe(True);
end;

// Escaped non-ASCII text reaches the handler as the server would parse
// it from a client, adjacent escapes included (#97 review): "\u4e16\u754c"
// is 世界, which FPC 3.2.2's own scanner would get wrong.
procedure TTestClientSuite.TestEscapedUnicodeAsTheServerParsesIt;
begin
  Expect<string>(TextOf(FClient.CallTool('echo',
    '{"message":"a\u4e16\u754cb"}'))).ToBe('a' + #$E4#$B8#$96 + #$E7#$95#$8C +
    'b|mcp-test-client|plain');
  Expect<Boolean>(Pos('"text" : "a' + #$E4#$B8#$96 + #$E7#$95#$8C + 'b|',
    FClient.LastResponseLine) > 0).ToBe(True);
end;

// A call answered over two rounds keeps both rounds' notifications, and
// a typed helper opts into progress with ProgressToken (#97 review).
procedure TTestClientSuite.TestNotificationsAcrossRounds;
begin
  FClient.SetClientCapabilities('{"elicitation":{}}');
  FClient.ProgressToken := 'p1';
  FClient.AnswerInput('who', '{"action":"accept","content":{"name":"Ada"}}');
  Expect<string>(TextOf(FClient.CallTool('ask_name'))).ToBe('Hello, Ada (asked)');
  Expect<Integer>(FClient.Notifications.Count).ToBe(2);
  Expect<Boolean>(Pos('"progressToken" : "p1"', FClient.Notifications[0]) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('"progressToken" : "p1"', FClient.Notifications[1]) > 0)
    .ToBe(True);
  // The next call starts empty.
  FClient.ProgressToken := '';
  TextOf(FClient.CallTool('echo'));
  Expect<Integer>(FClient.Notifications.Count).ToBe(0);
end;

// Complete sends the ref and argument the server completes from
// (#97 review).
procedure TTestClientSuite.TestCompletion;
var
  Response: TJSONObject;
begin
  Response := FClient.Complete('{"type":"ref/prompt","name":"greet"}', 'name',
    'A');
  try
    Expect<string>(SerializeValues(Response)).ToBe('Ada,Alan,');
  finally
    Response.Free;
  end;
end;

procedure TTestClientSuite.TestNotificationsCaptured;
var
  Response: TJSONObject;
begin
  Response := FClient.Request('tools/call', '{"name":"progress",' +
    '"_meta":{"progressToken":"t1"}}');
  Response.Free;
  Expect<Integer>(FClient.Notifications.Count).ToBe(2);
  Expect<Boolean>(Pos('"message" : "half"', FClient.Notifications[0]) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('"message" : "done"', FClient.Notifications[1]) > 0)
    .ToBe(True);
end;

procedure TTestClientSuite.TestInputAnsweredFromCannedResponses;
begin
  FClient.SetClientCapabilities('{"elicitation":{}}');
  FClient.AnswerInput('who', '{"action":"accept","content":{"name":"' +
    UTF8_NAME + '"}}');
  // One call: the client answers the round and retries with the state
  // the server sealed; the handler gets its own 'asked' back.
  Expect<string>(TextOf(FClient.CallTool('ask_name')))
    .ToBe('Hello, ' + UTF8_NAME + ' (asked)');
end;

procedure TTestClientSuite.TestUnansweredInputReturned;
var
  Response: TJSONObject;
begin
  FClient.SetClientCapabilities('{"elicitation":{}}');
  Response := FClient.CallTool('ask_name');
  try
    Expect<string>(Response.FindPath('result.resultType').AsString)
      .ToBe('input_required');
    Expect<Boolean>(Response.FindPath('result.inputRequests.who') <> nil)
      .ToBe(True);
  finally
    Response.Free;
  end;
end;

procedure TTestClientSuite.TestPromptAndResource;
begin
  Expect<string>(StringAt(FClient.GetPrompt('greet', '{"name":"' + UTF8_NAME +
    '"}'), 'result.messages[0].content.text')).ToBe('Greet ' + UTF8_NAME);
  Expect<string>(StringAt(FClient.ReadResource('mem://note'),
    'result.contents[0].text')).ToBe(UTF8_NAME);
  Expect<Boolean>(Pos('"text" : "' + UTF8_NAME + '"', FClient.LastResponseLine) > 0)
    .ToBe(True);
end;

procedure TTestClientSuite.TestErrorsAreResponses;
var
  Response: TJSONObject;
begin
  Response := FClient.CallTool('nope');
  try
    Expect<Integer>(Response.FindPath('error.code').AsInteger).ToBe(-32602);
  finally
    Response.Free;
  end;
  Response := FClient.Complete('{"type":"ref/prompt","name":"nope"}', 'name', 'A');
  try
    Expect<Integer>(Response.FindPath('error.code').AsInteger).ToBe(-32602);
  finally
    Response.Free;
  end;
end;

procedure TTestClientSuite.TestBadJsonRaises;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    FClient.CallTool('echo', '{not json').Free;
  except
    on E: EMCPTesting do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

// The guide's first example is MCP.Testing.Guide.Test.pas, which lwpt
// test runs: the guide shows the program as it is, with the guide's
// program name and mode line in place of the library's (#97 review).
procedure TTestClientSuite.TestGuideShowsTheExample;
var
  Example, Guide: string;
begin
  Example := RepoFile('source' + PathDelim + 'units' + PathDelim +
    'MCP.Testing.Guide.Test.pas');
  Guide := RepoFile('docs' + PathDelim + 'guides' + PathDelim + 'testing.md');
  Expect<Boolean>((Example <> '') and (Guide <> '')).ToBe(True);
  // Whatever line endings the checkout uses.
  Example := StringReplace(Example, #13, '', [rfReplaceAll]);
  Guide := StringReplace(Guide, #13, '', [rfReplaceAll]);
  // The program from its first line, as the guide names and compiles
  // it in a project of its own.
  Example := Copy(Example, Pos(#10 + 'program ', Example) + 1, MaxInt);
  Example := StringReplace(Example, 'program MCP.Testing.Guide.Test;',
    'program MyServer.Test;', []);
  Example := StringReplace(Example, '{$I MCP.inc}', '{$mode delphi}{$H+}', []);
  // The guide's first Pascal block.
  Guide := Copy(Guide, Pos('```pascal' + #10, Guide) + 10, MaxInt);
  Guide := Copy(Guide, 1, Pos(#10 + '```', Guide));
  Expect<string>(Guide).ToBe(TrimRight(Example) + #10);
end;

// A call that raises before it is sent leaves no notifications from the
// call before it (#97 review).
procedure TTestClientSuite.TestFailedCallLeavesNoNotifications;
var
  Raised: Boolean;
begin
  FClient.ProgressToken := 'p2';
  TextOf(FClient.CallTool('progress'));
  Expect<Integer>(FClient.Notifications.Count).ToBe(2);
  Raised := False;
  try
    FClient.CallTool('echo', '{not json').Free;
  except
    on E: EMCPTesting do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  Expect<Integer>(FClient.Notifications.Count).ToBe(0);
end;

// LogLevel opts a typed call into log messages, which keep their place
// between progress notifications (#97 review).
procedure TTestClientSuite.TestLogAndProgressInOrder;
begin
  FClient.ProgressToken := 'p3';
  FClient.LogLevel := 'info';
  Expect<string>(TextOf(FClient.CallTool('chatty'))).ToBe('chatty');
  Expect<Integer>(FClient.Notifications.Count).ToBe(3);
  Expect<Boolean>(Pos('"message" : "one"', FClient.Notifications[0]) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('notifications/message', FClient.Notifications[1]) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('"data" : "between"', FClient.Notifications[1]) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('"message" : "three"', FClient.Notifications[2]) > 0)
    .ToBe(True);
end;

// A round that asks for nothing is retried with its state alone, no
// inputResponses, as a client would (#97 review).
procedure TTestClientSuite.TestStateOnlyRound;
begin
  Expect<string>(TextOf(FClient.CallTool('later'))).ToBe('none|later');
end;

procedure TTestClientSuite.SetupTests;
begin
  Test('client info and capabilities go in the envelope', TestEnvelopeAdded);
  Test('discover and the list helpers', TestDiscoverAndLists);
  Test('CallTool returns the parsed response, UTF-8 byte-exact', TestCallTool);
  Test('notifications of the last request are captured in order',
    TestNotificationsCaptured);
  Test('an input_required round is answered from canned responses',
    TestInputAnsweredFromCannedResponses);
  Test('an unanswered round comes back as input_required',
    TestUnansweredInputReturned);
  Test('GetPrompt and ReadResource', TestPromptAndResource);
  Test('protocol errors come back as error responses', TestErrorsAreResponses);
  Test('malformed JSON arguments raise EMCPTesting', TestBadJsonRaises);
  Test('escaped Unicode reaches the handler as the server parses it',
    TestEscapedUnicodeAsTheServerParsesIt);
  Test('notifications of every round of one call are kept',
    TestNotificationsAcrossRounds);
  Test('Complete returns the completed values', TestCompletion);
  Test('the testing guide shows the example program lwpt test runs',
    TestGuideShowsTheExample);
  Test('a call that raises leaves no earlier notifications',
    TestFailedCallLeavesNoNotifications);
  Test('log messages and progress keep their order',
    TestLogAndProgressInOrder);
  Test('a state-only round is retried without inputResponses',
    TestStateOnlyRound);
end;

begin
  TestRunnerProgram.AddSuite(TTestClientSuite.Create('Testing: test client'));
  TestRunnerProgram.Run;
end.
