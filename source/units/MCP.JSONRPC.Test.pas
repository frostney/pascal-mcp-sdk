{ MCP.JSONRPC.Test — the JSON-RPC 2.0 profile MCP mandates: request /
  notification classification, the id rules (string or number, never
  null), rejection of batches and non-object params, id preservation
  into error replies for malformed-but-parseable input, and the
  response builders (result / error shape, id cloning, null id for
  unreadable requests, single-line output with escaped newlines). }

program MCP.JSONRPC.Test;

{$I Shared.inc}

uses
  SysUtils,

  fpjson,
  MCP.JSONRPC,
  TestingPascalLibrary;

type
  TParseValid = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestRequestWithNumberId;
    procedure TestRequestWithStringId;
    procedure TestNotification;
    procedure TestParamsCaptured;
    procedure TestParamsAbsent;
  end;

  TParseInvalid = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestGarbage;
    procedure TestNonObject;
    procedure TestBatchRejected;
    procedure TestWrongVersion;
    procedure TestMissingMethod;
    procedure TestNullId;
    procedure TestArrayParams;
    procedure TestIdPreservedOnInvalid;
  end;

  TResponseBuilders = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestResultShape;
    procedure TestErrorShape;
    procedure TestErrorWithData;
    procedure TestNullIdWhenUnreadable;
    procedure TestSingleLineWithEscapedNewline;
  end;

{ ───────── helpers ───────── }

function ParseObj(const AJson: string): TJSONObject;
begin
  Result := TJSONObject(GetJSON(AJson));
end;

{ ───────── valid input ───────── }

procedure TParseValid.TestRequestWithNumberId;
var
  Msg: TJSONRPCMessage;
begin
  Msg := ParseJSONRPCMessage(
    '{"jsonrpc":"2.0","id":7,"method":"tools/list"}');
  Expect<Integer>(Ord(Msg.Kind)).ToBe(Ord(jrkRequest));
  Expect<string>(Msg.Method).ToBe('tools/list');
  Expect<Integer>(Msg.Id.AsInteger).ToBe(7);
  FreeJSONRPCMessage(Msg);
end;

procedure TParseValid.TestRequestWithStringId;
var
  Msg: TJSONRPCMessage;
begin
  Msg := ParseJSONRPCMessage(
    '{"jsonrpc":"2.0","id":"discover-1","method":"server/discover"}');
  Expect<Integer>(Ord(Msg.Kind)).ToBe(Ord(jrkRequest));
  Expect<string>(Msg.Id.AsString).ToBe('discover-1');
  FreeJSONRPCMessage(Msg);
end;

procedure TParseValid.TestNotification;
var
  Msg: TJSONRPCMessage;
begin
  Msg := ParseJSONRPCMessage(
    '{"jsonrpc":"2.0","method":"notifications/cancelled"}');
  Expect<Integer>(Ord(Msg.Kind)).ToBe(Ord(jrkNotification));
  Expect<Boolean>(Msg.Id = nil).ToBe(True);
  FreeJSONRPCMessage(Msg);
end;

procedure TParseValid.TestParamsCaptured;
var
  Msg: TJSONRPCMessage;
begin
  Msg := ParseJSONRPCMessage(
    '{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"echo"}}');
  Expect<Boolean>(Msg.Params <> nil).ToBe(True);
  Expect<string>(Msg.Params.Get('name', '')).ToBe('echo');
  FreeJSONRPCMessage(Msg);
end;

procedure TParseValid.TestParamsAbsent;
var
  Msg: TJSONRPCMessage;
begin
  Msg := ParseJSONRPCMessage('{"jsonrpc":"2.0","id":1,"method":"x"}');
  Expect<Boolean>(Msg.Params = nil).ToBe(True);
  Expect<Integer>(Ord(Msg.Kind)).ToBe(Ord(jrkRequest));
  FreeJSONRPCMessage(Msg);
end;

procedure TParseValid.SetupTests;
begin
  Test('request with number id', TestRequestWithNumberId);
  Test('request with string id', TestRequestWithStringId);
  Test('notification (no id)', TestNotification);
  Test('params object captured', TestParamsCaptured);
  Test('absent params stay nil', TestParamsAbsent);
end;

{ ───────── invalid input ───────── }

procedure TParseInvalid.TestGarbage;
var
  Msg: TJSONRPCMessage;
begin
  Msg := ParseJSONRPCMessage('this is not json');
  Expect<Integer>(Ord(Msg.Kind)).ToBe(Ord(jrkInvalid));
  Expect<Integer>(Msg.ErrorCode).ToBe(JSONRPC_PARSE_ERROR);
  FreeJSONRPCMessage(Msg);
end;

procedure TParseInvalid.TestNonObject;
var
  Msg: TJSONRPCMessage;
begin
  Msg := ParseJSONRPCMessage('"just a string"');
  Expect<Integer>(Ord(Msg.Kind)).ToBe(Ord(jrkInvalid));
  Expect<Integer>(Msg.ErrorCode).ToBe(JSONRPC_INVALID_REQUEST);
  FreeJSONRPCMessage(Msg);
end;

procedure TParseInvalid.TestBatchRejected;
var
  Msg: TJSONRPCMessage;
begin
  // MCP removed JSON-RPC batching; arrays are invalid requests.
  Msg := ParseJSONRPCMessage(
    '[{"jsonrpc":"2.0","id":1,"method":"tools/list"}]');
  Expect<Integer>(Ord(Msg.Kind)).ToBe(Ord(jrkInvalid));
  Expect<Integer>(Msg.ErrorCode).ToBe(JSONRPC_INVALID_REQUEST);
  FreeJSONRPCMessage(Msg);
end;

procedure TParseInvalid.TestWrongVersion;
var
  Msg: TJSONRPCMessage;
begin
  Msg := ParseJSONRPCMessage('{"jsonrpc":"1.0","id":1,"method":"x"}');
  Expect<Integer>(Ord(Msg.Kind)).ToBe(Ord(jrkInvalid));
  Expect<Integer>(Msg.ErrorCode).ToBe(JSONRPC_INVALID_REQUEST);
  FreeJSONRPCMessage(Msg);
end;

procedure TParseInvalid.TestMissingMethod;
var
  Msg: TJSONRPCMessage;
begin
  Msg := ParseJSONRPCMessage('{"jsonrpc":"2.0","id":1}');
  Expect<Integer>(Ord(Msg.Kind)).ToBe(Ord(jrkInvalid));
  FreeJSONRPCMessage(Msg);
end;

procedure TParseInvalid.TestNullId;
var
  Msg: TJSONRPCMessage;
begin
  // MCP tightens JSON-RPC: the id MUST NOT be null.
  Msg := ParseJSONRPCMessage(
    '{"jsonrpc":"2.0","id":null,"method":"tools/list"}');
  Expect<Integer>(Ord(Msg.Kind)).ToBe(Ord(jrkInvalid));
  Expect<Integer>(Msg.ErrorCode).ToBe(JSONRPC_INVALID_REQUEST);
  FreeJSONRPCMessage(Msg);
end;

procedure TParseInvalid.TestArrayParams;
var
  Msg: TJSONRPCMessage;
begin
  Msg := ParseJSONRPCMessage(
    '{"jsonrpc":"2.0","id":1,"method":"x","params":[1,2]}');
  Expect<Integer>(Ord(Msg.Kind)).ToBe(Ord(jrkInvalid));
  FreeJSONRPCMessage(Msg);
end;

procedure TParseInvalid.TestIdPreservedOnInvalid;
var
  Msg: TJSONRPCMessage;
begin
  // A readable id survives validation failure so the error reply can
  // carry it (JSON-RPC 2.0 §5).
  Msg := ParseJSONRPCMessage('{"jsonrpc":"1.0","id":42,"method":"x"}');
  Expect<Integer>(Ord(Msg.Kind)).ToBe(Ord(jrkInvalid));
  Expect<Boolean>(Msg.Id <> nil).ToBe(True);
  Expect<Integer>(Msg.Id.AsInteger).ToBe(42);
  FreeJSONRPCMessage(Msg);
end;

procedure TParseInvalid.SetupTests;
begin
  Test('unparseable input → -32700', TestGarbage);
  Test('non-object → -32600', TestNonObject);
  Test('batch array → -32600 (MCP has no batching)', TestBatchRejected);
  Test('jsonrpc ≠ "2.0" → -32600', TestWrongVersion);
  Test('missing method → -32600', TestMissingMethod);
  Test('null id → -32600 (MCP forbids null ids)', TestNullId);
  Test('array params → -32600', TestArrayParams);
  Test('readable id preserved on invalid message', TestIdPreservedOnInvalid);
end;

{ ───────── response builders ───────── }

procedure TResponseBuilders.TestResultShape;
var
  Id: TJSONData;
  Payload, Response: TJSONObject;
begin
  Id := TJSONIntegerNumber.Create(3);
  Payload := TJSONObject.Create;
  Payload.Add('ok', True);
  Response := ParseObj(BuildResultResponse(Id, Payload));
  Expect<string>(Response.Get('jsonrpc', '')).ToBe('2.0');
  Expect<Integer>(Response.Get('id', 0)).ToBe(3);
  Expect<Boolean>(TJSONObject(Response.Find('result')).Get('ok', False))
    .ToBe(True);
  Response.Free;
  Id.Free;
end;

procedure TResponseBuilders.TestErrorShape;
var
  Id: TJSONData;
  Response, ErrorObj: TJSONObject;
begin
  Id := TJSONString.Create('r-1');
  Response := ParseObj(BuildErrorResponse(Id, JSONRPC_METHOD_NOT_FOUND,
    'Method not found'));
  Expect<string>(Response.Get('id', '')).ToBe('r-1');
  ErrorObj := TJSONObject(Response.Find('error'));
  Expect<Integer>(ErrorObj.Get('code', 0)).ToBe(JSONRPC_METHOD_NOT_FOUND);
  Expect<string>(ErrorObj.Get('message', '')).ToBe('Method not found');
  Response.Free;
  Id.Free;
end;

procedure TResponseBuilders.TestErrorWithData;
var
  Data, Response: TJSONObject;
begin
  Data := TJSONObject.Create;
  Data.Add('requested', '1900-01-01');
  Response := ParseObj(BuildErrorResponse(nil,
    MCP_ERROR_UNSUPPORTED_PROTOCOL_VERSION, 'Unsupported', Data));
  Expect<string>(
    TJSONObject(Response.FindPath('error.data')).Get('requested', ''))
    .ToBe('1900-01-01');
  Response.Free;
end;

procedure TResponseBuilders.TestNullIdWhenUnreadable;
var
  Response: TJSONObject;
begin
  Response := ParseObj(BuildErrorResponse(nil, JSONRPC_PARSE_ERROR, 'Parse'));
  Expect<Integer>(Ord(Response.Find('id').JSONType)).ToBe(Ord(jtNull));
  Response.Free;
end;

procedure TResponseBuilders.TestSingleLineWithEscapedNewline;
var
  Payload: TJSONObject;
  Line: string;
begin
  // The stdio framing invariant: embedded newlines must leave the
  // serializer escaped, never literal.
  Payload := TJSONObject.Create;
  Payload.Add('text', 'line one'#10'line two');
  Line := BuildResultResponse(nil, Payload);
  Expect<Integer>(Pos(#10, Line)).ToBe(0);
  Expect<Boolean>(Pos('\n', Line) > 0).ToBe(True);
end;

procedure TResponseBuilders.SetupTests;
begin
  Test('result response shape', TestResultShape);
  Test('error response shape', TestErrorShape);
  Test('error data payload carried', TestErrorWithData);
  Test('nil id serializes as JSON null', TestNullIdWhenUnreadable);
  Test('single line, newlines escaped', TestSingleLineWithEscapedNewline);
end;

begin
  TestRunnerProgram.AddSuite(TParseValid.Create('JSONRPC: valid input'));
  TestRunnerProgram.AddSuite(TParseInvalid.Create('JSONRPC: invalid input'));
  TestRunnerProgram.AddSuite(
    TResponseBuilders.Create('JSONRPC: response builders'));
  TestRunnerProgram.Run;
end.
