unit MCP.Testing;

// In-process test harness for a server built with this library (#97).
// TMCPTestClient drives a TMCPServer the way a client would, through
// the sans-I/O core (HandleMessage) with no transport and no process:
// it adds the per-request _meta envelope the 2026-07-28 revision
// requires on every request (verified 2026-11-26 against
// https://modelcontextprotocol.io/specification/2026-07-28/basic/index#_meta),
// returns each parsed response, records the notifications a request
// emits, and can answer input_required (MRTR) rounds from canned input
// responses.
//
// It is a test harness for one's own server, not an MCP client for
// other servers: it never leaves the process (VISION.md keeps a general
// client out of scope).
//
//   Client := TMCPTestClient.Create(Server);
//   Response := Client.CallTool('add', '{"a":2,"b":3}');
//   try
//     Expect<string>(Response.FindPath('result.content[0].text').AsString)
//       .ToBe('5');
//   finally
//     Response.Free;
//   end;

{$I MCP.inc}

interface

uses
  Classes,
  SysUtils,

  fpjson,
  MCP.Server;

type
  EMCPTesting = class(Exception);

  TMCPTestClient = class
  private
    FServer: TMCPServer;   // borrowed: outlives the client
    FSession: TMCPSession; // owned
    FCapabilities: TJSONObject;
    FClientName: string;
    FClientVersion: string;
    FNotifications: TStringList;
    FInputResponses: TJSONObject;
    FNextId: Integer;
    FLastResponseLine: string;
    FProgressToken: string;
    FLogLevel: string;
    function Envelope(const AParamsJson: string): TJSONObject;
    // One round: sends AMethod with AParams (consumed) and returns the
    // parsed response. Notifications accumulate across a call's rounds.
    function Send(const AMethod: string; AParams: TJSONObject): TJSONObject;
    // Every public call starts here, before it checks its arguments, so
    // a call that raises leaves no earlier notifications behind.
    procedure StartCall;
    function AnswersFor(ARequests: TJSONObject): TJSONObject;
    function SendAnsweringInput(const AMethod: string;
      AParams: TJSONObject): TJSONObject;
  public
    constructor Create(AServer: TMCPServer);
    destructor Destroy; override;

    // The clientCapabilities every request declares, as JSON
    // ('{"elicitation":{},"sampling":{}}'); '{}' by default.
    procedure SetClientCapabilities(const AJson: string);
    // The clientInfo every request carries ('mcp-test-client', '1.0.0'
    // by default), as handlers see it in ACtx.ClientName and
    // ACtx.ClientVersion.
    property ClientName: string read FClientName write FClientName;
    property ClientVersion: string read FClientVersion write FClientVersion;
    // When not '', every request opts into progress notifications with
    // this progressToken, and into log messages at and above this level
    // ('debug' .. 'emergency'), so a typed helper's call records what
    // MCPReportProgress and MCPLogMessage send.
    property ProgressToken: string read FProgressToken write FProgressToken;
    property LogLevel: string read FLogLevel write FLogLevel;

    // A canned answer for the input request AKey of an input_required
    // round, as the response JSON the client would send
    // ('{"action":"accept","content":{"name":"Ada"}}'). CallTool and
    // GetPrompt retry with the answers and the echoed requestState while
    // every requested key has one, at most MAX_INPUT_ROUNDS (10) times;
    // otherwise, or at that limit, they return the latest response,
    // input_required as it is.
    procedure AnswerInput(const AKey, AResponseJson: string);
    // Forgets every canned answer.
    procedure ClearInputAnswers;

    // Every helper below returns the whole parsed JSON-RPC response, a
    // result or an error, as a new object the caller frees; each raises
    // EMCPTesting when the server sends no response or a JSON argument
    // is malformed. JSON text is parsed as the server parses it
    // (MCPParseJSON), escapes included.

    // One request with the _meta envelope added to AParamsJson (an
    // object); a key of yours in _meta wins over the envelope's.
    function Request(const AMethod: string;
      const AParamsJson: string = '{}'): TJSONObject;

    function Discover: TJSONObject;
    function ListTools: TJSONObject;
    function CallTool(const AName: string;
      const AArgumentsJson: string = '{}'): TJSONObject;
    function ListResources: TJSONObject;
    function ReadResource(const AUri: string): TJSONObject;
    function ListPrompts: TJSONObject;
    function GetPrompt(const AName: string;
      const AArgumentsJson: string = '{}'): TJSONObject;
    // ARefJson: '{"type":"ref/prompt","name":"greet"}' or a ref/resource.
    function Complete(const ARefJson, AArgument, AValue: string): TJSONObject;

    // The notification lines (progress, log messages) the last helper
    // call emitted, in order, across every input round it answered.
    // Owned by the client; cleared when the next call starts.
    property Notifications: TStringList read FNotifications;
    // The raw response line of the last round, as the server wrote it,
    // for byte-exact assertions.
    property LastResponseLine: string read FLastResponseLine;
    // The client's own session (owned), for calls into the server that
    // need one, such as HandleMessage with a hand-written line.
    property Session: TMCPSession read FSession;
  end;

implementation

uses
  MCP.JSONRPC,
  MCP.Protocol;

const
  MAX_INPUT_ROUNDS = 10;

// Parses JSON text as the server does (MCPParseJSON: UTF-8, strict,
// non-ASCII escapes decoded first); raises EMCPTesting on anything but
// an object.
function ParseObject(const AJson, AWhat: string): TJSONObject;
var
  Data: TJSONData;
begin
  try
    Data := MCPParseJSON(AJson);
  except
    on E: Exception do
      raise EMCPTesting.CreateFmt('%s is not valid JSON: %s',
        [AWhat, E.Message]);
  end;
  if (Data = nil) or (Data.JSONType <> jtObject) then
  begin
    Data.Free;
    raise EMCPTesting.CreateFmt('%s must be a JSON object', [AWhat]);
  end;
  Result := TJSONObject(Data);
end;

procedure CollectNotification(const ALine: string; AUserData: Pointer);
begin
  TStringList(AUserData).Add(ALine);
end;

constructor TMCPTestClient.Create(AServer: TMCPServer);
begin
  inherited Create;
  if AServer = nil then
    raise EMCPTesting.Create('TMCPTestClient needs a server');
  FServer := AServer;
  FSession := AServer.CreateSession;
  FCapabilities := TJSONObject.Create;
  FClientName := 'mcp-test-client';
  FClientVersion := '1.0.0';
  FNotifications := TStringList.Create;
  FInputResponses := TJSONObject.Create;
end;

destructor TMCPTestClient.Destroy;
begin
  FInputResponses.Free;
  FNotifications.Free;
  FCapabilities.Free;
  FSession.Free;
  inherited Destroy;
end;

procedure TMCPTestClient.SetClientCapabilities(const AJson: string);
var
  Capabilities: TJSONObject;
begin
  Capabilities := ParseObject(AJson, 'clientCapabilities');
  FCapabilities.Free;
  FCapabilities := Capabilities;
end;

procedure TMCPTestClient.AnswerInput(const AKey, AResponseJson: string);
var
  Answer: TJSONObject;
begin
  Answer := ParseObject(AResponseJson, 'input response "' + AKey + '"');
  FInputResponses.Delete(AKey);
  FInputResponses.Add(AKey, Answer);
end;

procedure TMCPTestClient.ClearInputAnswers;
begin
  FInputResponses.Clear;
end;

function TMCPTestClient.Envelope(const AParamsJson: string): TJSONObject;
var
  Meta, Info: TJSONObject;
begin
  Result := ParseObject(AParamsJson, 'params');
  try
    if Result.Find('_meta') = nil then
      Result.Add('_meta', TJSONObject.Create);
    if Result.Find('_meta').JSONType <> jtObject then
      raise EMCPTesting.Create('params._meta must be an object');
    Meta := TJSONObject(Result.Find('_meta'));
    if Meta.Find(META_KEY_PROTOCOL_VERSION) = nil then
      Meta.Add(META_KEY_PROTOCOL_VERSION, MCP_PROTOCOL_VERSION);
    if Meta.Find(META_KEY_CLIENT_CAPABILITIES) = nil then
      Meta.Add(META_KEY_CLIENT_CAPABILITIES, FCapabilities.Clone);
    if Meta.Find(META_KEY_CLIENT_INFO) = nil then
    begin
      Info := TJSONObject.Create;
      Meta.Add(META_KEY_CLIENT_INFO, Info);
      Info.Add('name', FClientName);
      Info.Add('version', FClientVersion);
    end;
    if (FProgressToken <> '') and (Meta.Find('progressToken') = nil) then
      Meta.Add('progressToken', FProgressToken);
    if (FLogLevel <> '') and (Meta.Find(META_KEY_LOG_LEVEL) = nil) then
      Meta.Add(META_KEY_LOG_LEVEL, FLogLevel);
  except
    Result.Free;
    raise;
  end;
end;

procedure TMCPTestClient.StartCall;
begin
  FNotifications.Clear;
end;

function TMCPTestClient.Send(const AMethod: string;
  AParams: TJSONObject): TJSONObject;
var
  Message: TJSONObject;
  Line, Response: string;
begin
  Inc(FNextId);
  Message := TJSONObject.Create;
  try
    Message.Add('params', AParams);
  except
    Message.Free;
    AParams.Free;
    raise;
  end;
  try
    Message.Add('jsonrpc', JSONRPC_VERSION);
    Message.Add('id', FNextId);
    Message.Add('method', AMethod);
    Line := Message.AsJSON;
  finally
    Message.Free;
  end;
  if not FServer.HandleMessage(FSession, Line, CollectNotification,
    FNotifications, Response) then
    raise EMCPTesting.CreateFmt('%s produced no response', [AMethod]);
  FLastResponseLine := Response;
  Result := ParseObject(Response, 'the response');
end;

// The canned answers for every key of ARequests, or nil when one has
// none. A round that asks for nothing gets an empty object.
function TMCPTestClient.AnswersFor(ARequests: TJSONObject): TJSONObject;
var
  I: Integer;
  Answer: TJSONData;
begin
  Result := TJSONObject.Create;
  try
    if ARequests <> nil then
      for I := 0 to ARequests.Count - 1 do
      begin
        Answer := FInputResponses.Find(ARequests.Names[I]);
        if Answer = nil then
        begin
          FreeAndNil(Result);
          Exit;
        end;
        Result.Add(ARequests.Names[I], Answer.Clone);
      end;
  except
    Result.Free;
    raise;
  end;
end;

// The params of a retry: ARetry's, with AAnswers (consumed) as
// inputResponses when it has any, and the echoed requestState of
// AResult when it carries one.
function RetryParams(ARetry, AAnswers, AResult: TJSONObject): TJSONObject;
var
  StateData: TJSONData;
begin
  Result := nil;
  try
    Result := TJSONObject(ARetry.Clone);
    Result.Delete('inputResponses');
    Result.Delete('requestState');
    // A round that asked for nothing is retried with its state alone,
    // as a client would (#97 review).
    if AAnswers.Count > 0 then
    begin
      Result.Add('inputResponses', AAnswers);
      AAnswers := nil;
    end;
    StateData := AResult.Find('requestState');
    if (StateData <> nil) and (StateData.JSONType = jtString) then
      Result.Add('requestState', StateData.AsString);
  except
    Result.Free;
    AAnswers.Free;
    raise;
  end;
  AAnswers.Free;
end;

// Sends AMethod and answers input_required rounds from the canned
// answers while every requested key has one, at most MAX_INPUT_ROUNDS
// times. AParams is consumed.
function TMCPTestClient.SendAnsweringInput(const AMethod: string;
  AParams: TJSONObject): TJSONObject;
var
  Round: Integer;
  ResultObj, Requests, Answers, Retry: TJSONObject;
begin
  try
    Retry := TJSONObject(AParams.Clone);
  except
    AParams.Free;
    raise;
  end;
  try
    Result := Send(AMethod, AParams);
    for Round := 1 to MAX_INPUT_ROUNDS do
    begin
      if (Result.FindPath('result.resultType') = nil) or
        (Result.FindPath('result.resultType').AsString <>
        RESULT_TYPE_INPUT_REQUIRED) then
        Exit;
      ResultObj := TJSONObject(Result.Find('result'));
      Requests := nil;
      if (ResultObj.Find('inputRequests') <> nil) and
        (ResultObj.Find('inputRequests').JSONType = jtObject) then
        Requests := TJSONObject(ResultObj.Find('inputRequests'));
      Answers := AnswersFor(Requests);
      if Answers = nil then
        Exit;
      AParams := RetryParams(Retry, Answers, ResultObj);
      FreeAndNil(Result);
      Result := Send(AMethod, AParams);
    end;
  finally
    Retry.Free;
  end;
end;

function TMCPTestClient.Request(const AMethod: string;
  const AParamsJson: string): TJSONObject;
begin
  StartCall;
  Result := Send(AMethod, Envelope(AParamsJson));
end;

function TMCPTestClient.Discover: TJSONObject;
begin
  Result := Request('server/discover');
end;

function TMCPTestClient.ListTools: TJSONObject;
begin
  Result := Request('tools/list');
end;

// {"name":AName,"arguments":<AArgumentsJson>} with the envelope.
function NamedCallParams(AClient: TMCPTestClient; const AName,
  AArgumentsJson: string): TJSONObject;
begin
  Result := AClient.Envelope('{}');
  try
    Result.Add('name', AName);
    Result.Add('arguments', ParseObject(AArgumentsJson, 'arguments'));
  except
    Result.Free;
    raise;
  end;
end;

function TMCPTestClient.CallTool(const AName: string;
  const AArgumentsJson: string): TJSONObject;
begin
  StartCall;
  Result := SendAnsweringInput('tools/call',
    NamedCallParams(Self, AName, AArgumentsJson));
end;

function TMCPTestClient.ListResources: TJSONObject;
begin
  Result := Request('resources/list');
end;

function TMCPTestClient.ReadResource(const AUri: string): TJSONObject;
var
  Params: TJSONObject;
begin
  StartCall;
  Params := Envelope('{}');
  try
    Params.Add('uri', AUri);
  except
    Params.Free;
    raise;
  end;
  Result := Send('resources/read', Params);
end;

function TMCPTestClient.ListPrompts: TJSONObject;
begin
  Result := Request('prompts/list');
end;

function TMCPTestClient.GetPrompt(const AName: string;
  const AArgumentsJson: string): TJSONObject;
begin
  StartCall;
  Result := SendAnsweringInput('prompts/get',
    NamedCallParams(Self, AName, AArgumentsJson));
end;

function TMCPTestClient.Complete(const ARefJson, AArgument,
  AValue: string): TJSONObject;
var
  Params, Argument: TJSONObject;
begin
  StartCall;
  Params := Envelope('{}');
  try
    Params.Add('ref', ParseObject(ARefJson, 'ref'));
    Argument := TJSONObject.Create;
    Params.Add('argument', Argument);
    Argument.Add('name', AArgument);
    Argument.Add('value', AValue);
  except
    Params.Free;
    raise;
  end;
  Result := Send('completion/complete', Params);
end;

end.
