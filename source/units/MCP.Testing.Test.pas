{ MCP.Testing.Test — the in-process test client (#97) against a small
  server: the envelope it adds, each helper, captured notifications,
  MRTR rounds answered from canned responses, and errors surfaced as
  responses. Payloads with multi-byte UTF-8 are asserted byte-exact. }

program MCP.Testing.Test;

{$I MCP.inc}

uses
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

function AskNameHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Requests: TJSONObject;
  Content: TJSONObject;
begin
  Content := MCPElicitationContent(ACtx, 'who');
  if Content <> nil then
    Exit(MCPTextResult('Hello, ' + Content.Get('name', '?')));
  Requests := TJSONObject.Create;
  Requests.Add('who', MCPElicitFormRequest('Who?',
    TJSONObject(GetJSON('{"type":"object","properties":{"name":' +
    '{"type":"string"}},"required":["name"]}'))));
  Result := MCPInputRequired(Requests, 'asked');
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
  FServer.RegisterPrompt('greet', 'Greet', PromptArguments.Add('name'),
    GreetPrompt);
  FServer.RegisterTextResource('mem://note', 'note', 'text/plain', UTF8_NAME);
  FClient := TMCPTestClient.Create(FServer);
end;

procedure TTestClientSuite.AfterEach;
begin
  FreeAndNil(FClient);
  FreeAndNil(FServer);
end;

function TextOf(AResponse: TJSONObject): string;
begin
  try
    Result := AResponse.FindPath('result.content[0].text').AsString;
  finally
    AResponse.Free;
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

procedure TTestClientSuite.TestDiscoverAndLists;
var
  Response: TJSONObject;
begin
  Response := FClient.Discover;
  Expect<string>(Response.FindPath('result.serverInfo.name').AsString)
    .ToBe('fixture');
  Response.Free;
  Response := FClient.ListTools;
  Expect<Integer>(TJSONArray(Response.FindPath('result.tools')).Count).ToBe(3);
  Response.Free;
  Response := FClient.ListPrompts;
  Expect<Integer>(TJSONArray(Response.FindPath('result.prompts')).Count).ToBe(1);
  Response.Free;
  Response := FClient.ListResources;
  Expect<Integer>(TJSONArray(Response.FindPath('result.resources')).Count)
    .ToBe(1);
  Response.Free;
end;

procedure TTestClientSuite.TestCallTool;
begin
  Expect<string>(TextOf(FClient.CallTool('echo',
    '{"message":"' + UTF8_NAME + '"}'))).ToBe(UTF8_NAME + '|mcp-test-client|plain');
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
  // One call: the client answers the round and retries with the state.
  Expect<string>(TextOf(FClient.CallTool('ask_name'))).ToBe('Hello, ' + UTF8_NAME);
end;

procedure TTestClientSuite.TestUnansweredInputReturned;
var
  Response: TJSONObject;
begin
  FClient.SetClientCapabilities('{"elicitation":{}}');
  Response := FClient.CallTool('ask_name');
  Expect<string>(Response.FindPath('result.resultType').AsString)
    .ToBe('input_required');
  Expect<Boolean>(Response.FindPath('result.inputRequests.who') <> nil)
    .ToBe(True);
  Response.Free;
end;

procedure TTestClientSuite.TestPromptAndResource;
var
  Response: TJSONObject;
begin
  Response := FClient.GetPrompt('greet', '{"name":"' + UTF8_NAME + '"}');
  Expect<string>(Response.FindPath('result.messages[0].content.text').AsString)
    .ToBe('Greet ' + UTF8_NAME);
  Response.Free;
  Response := FClient.ReadResource('mem://note');
  Expect<string>(Response.FindPath('result.contents[0].text').AsString)
    .ToBe(UTF8_NAME);
  Response.Free;
end;

procedure TTestClientSuite.TestErrorsAreResponses;
var
  Response: TJSONObject;
begin
  Response := FClient.CallTool('nope');
  Expect<Integer>(Response.FindPath('error.code').AsInteger).ToBe(-32602);
  Response.Free;
  Response := FClient.Complete('{"type":"ref/prompt","name":"greet"}', 'name', 'A');
  Expect<Boolean>((Response.Find('result') <> nil) or
    (Response.Find('error') <> nil)).ToBe(True);
  Response.Free;
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
end;

begin
  TestRunnerProgram.AddSuite(TTestClientSuite.Create('Testing: test client'));
  TestRunnerProgram.Run;
end.
