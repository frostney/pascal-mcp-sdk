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
    function Envelope(const AParamsJson: string): TJSONObject;
    function Send(const AMethod: string; AParams: TJSONObject): TJSONObject;
    function SendAnsweringInput(const AMethod: string;
      AParams: TJSONObject): TJSONObject;
  public
    constructor Create(AServer: TMCPServer);
    destructor Destroy; override;

    // The clientCapabilities every request declares, as JSON
    // ('{"elicitation":{},"sampling":{}}'); '{}' by default.
    procedure SetClientCapabilities(const AJson: string);
    property ClientName: string read FClientName write FClientName;
    property ClientVersion: string read FClientVersion write FClientVersion;

    // A canned answer for the input request AKey of an input_required
    // round, as the response JSON the client would send
    // ('{"action":"accept","content":{"name":"Ada"}}'). CallTool and
    // GetPrompt retry with the answers and the echoed requestState while
    // every requested key has one; otherwise they return the
    // input_required response as it is.
    procedure AnswerInput(const AKey, AResponseJson: string);
    procedure ClearInputAnswers;

    // One request with the _meta envelope added to AParamsJson (an
    // object). Returns the whole parsed JSON-RPC response, which the
    // caller frees; raises EMCPTesting when the server sends none.
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

    // The notification lines (progress, log messages) the last request
    // emitted, in order.
    property Notifications: TStringList read FNotifications;
    property Session: TMCPSession read FSession;
  end;

implementation

uses
  jsonparser,
  jsonscanner,
  MCP.Protocol;

const
  MAX_INPUT_ROUNDS = 10;

// Parses JSON text as the library does (UTF-8, strict); raises on
// anything but an object.
function ParseObject(const AJson, AWhat: string): TJSONObject;
var
  Parser: TJSONParser;
  Data: TJSONData;
begin
  Parser := TJSONParser.Create(AJson, [joUTF8, joStrict]);
  try
    try
      Data := Parser.Parse;
    except
      on E: Exception do
        raise EMCPTesting.CreateFmt('%s is not valid JSON: %s',
          [AWhat, E.Message]);
    end;
  finally
    Parser.Free;
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
  if Result.Find('_meta') = nil then
    Result.Add('_meta', TJSONObject.Create);
  if Result.Find('_meta').JSONType <> jtObject then
  begin
    Result.Free;
    raise EMCPTesting.Create('params._meta must be an object');
  end;
  Meta := TJSONObject(Result.Find('_meta'));
  if Meta.Find(META_KEY_PROTOCOL_VERSION) = nil then
    Meta.Add(META_KEY_PROTOCOL_VERSION, MCP_PROTOCOL_VERSION);
  if Meta.Find(META_KEY_CLIENT_CAPABILITIES) = nil then
    Meta.Add(META_KEY_CLIENT_CAPABILITIES, FCapabilities.Clone);
  if Meta.Find(META_KEY_CLIENT_INFO) = nil then
  begin
    Info := TJSONObject.Create;
    Info.Add('name', FClientName);
    Info.Add('version', FClientVersion);
    Meta.Add(META_KEY_CLIENT_INFO, Info);
  end;
end;

// Sends AMethod with AParams (consumed) and returns the response.
function TMCPTestClient.Send(const AMethod: string;
  AParams: TJSONObject): TJSONObject;
var
  Message: TJSONObject;
  Line, Response: string;
begin
  Inc(FNextId);
  Message := TJSONObject.Create;
  try
    Message.Add('jsonrpc', '2.0');
    Message.Add('id', FNextId);
    Message.Add('method', AMethod);
    Message.Add('params', AParams);
    Line := Message.AsJSON;
  finally
    Message.Free;
  end;
  FNotifications.Clear;
  if not FServer.HandleMessage(FSession, Line, CollectNotification,
    FNotifications, Response) then
    raise EMCPTesting.CreateFmt('%s produced no response', [AMethod]);
  Result := ParseObject(Response, 'the response');
end;

// Sends AMethod and answers input_required rounds from the canned
// answers while every requested key has one.
function TMCPTestClient.SendAnsweringInput(const AMethod: string;
  AParams: TJSONObject): TJSONObject;
var
  Round, I: Integer;
  ResultObj, Requests, Answers: TJSONObject;
  Retry: TJSONObject;
  StateData: TJSONData;
  Answerable: Boolean;
begin
  Retry := TJSONObject(AParams.Clone);
  try
    Result := Send(AMethod, AParams);
    for Round := 1 to MAX_INPUT_ROUNDS do
    begin
      if (Result.FindPath('result.resultType') = nil) or
        (Result.FindPath('result.resultType').AsString <> 'input_required') then
        Exit;
      ResultObj := TJSONObject(Result.Find('result'));
      Requests := nil;
      if (ResultObj.Find('inputRequests') <> nil) and
        (ResultObj.Find('inputRequests').JSONType = jtObject) then
        Requests := TJSONObject(ResultObj.Find('inputRequests'));
      Answers := TJSONObject.Create;
      Answerable := True;
      if Requests <> nil then
        for I := 0 to Requests.Count - 1 do
          if FInputResponses.Find(Requests.Names[I]) = nil then
            Answerable := False
          else
            Answers.Add(Requests.Names[I],
              FInputResponses.Find(Requests.Names[I]).Clone);
      if not Answerable then
      begin
        Answers.Free;
        Exit;
      end;
      AParams := TJSONObject(Retry.Clone);
      AParams.Delete('inputResponses');
      AParams.Delete('requestState');
      AParams.Add('inputResponses', Answers);
      StateData := ResultObj.Find('requestState');
      if (StateData <> nil) and (StateData.JSONType = jtString) then
        AParams.Add('requestState', StateData.AsString);
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
  Result.Add('name', AName);
  try
    Result.Add('arguments', ParseObject(AArgumentsJson, 'arguments'));
  except
    Result.Free;
    raise;
  end;
end;

function TMCPTestClient.CallTool(const AName: string;
  const AArgumentsJson: string): TJSONObject;
begin
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
  Params := Envelope('{}');
  Params.Add('uri', AUri);
  Result := Send('resources/read', Params);
end;

function TMCPTestClient.ListPrompts: TJSONObject;
begin
  Result := Request('prompts/list');
end;

function TMCPTestClient.GetPrompt(const AName: string;
  const AArgumentsJson: string): TJSONObject;
begin
  Result := SendAnsweringInput('prompts/get',
    NamedCallParams(Self, AName, AArgumentsJson));
end;

function TMCPTestClient.Complete(const ARefJson, AArgument,
  AValue: string): TJSONObject;
var
  Params, Argument: TJSONObject;
begin
  Params := Envelope('{}');
  try
    Params.Add('ref', ParseObject(ARefJson, 'ref'));
  except
    Params.Free;
    raise;
  end;
  Argument := TJSONObject.Create;
  Argument.Add('name', AArgument);
  Argument.Add('value', AValue);
  Params.Add('argument', Argument);
  Result := Send('completion/complete', Params);
end;

end.
