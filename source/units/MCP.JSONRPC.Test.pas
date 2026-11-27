{ MCP.JSONRPC.Test — the JSON-RPC 2.0 profile MCP mandates: request /
  notification classification, the id rules (string or number, never
  null), rejection of batches and non-object params, id preservation
  into error replies for malformed-but-parseable input, and the
  response builders (result / error shape, id cloning, null id for
  unreadable requests, single-line output with escaped newlines, and
  byte-exact UTF-8 without importing a transport). }

program MCP.JSONRPC.Test;

{$I MCP.inc}

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  Classes,
  SysUtils,

  fpjson,
  MCP.JSONRPC,
  TestingPascalLibrary;

const
  UTF8_WORLD = #$E4#$B8#$96 + #$E7#$95#$8C;
  UTF8_PAYLOAD = 'h' + #$C3#$A9 + 'llo ' + UTF8_WORLD;
  UTF8_GRINNING_FACE = #$F0#$9F#$98#$80;

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
    procedure TestInvalidNotificationShapeFlagged;
    procedure TestInvalidRequestShapeNotFlagged;
    procedure TestNullIdIsRequestShaped;
    procedure TestInvalidUTF8IsParseError;
    procedure TestUTF8FileNameRoundTrip;
  end;

  TUnicodeEscapeInput = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestAdjacentBMP;
    procedure TestAfterEscapedBackslash;
    procedure TestSurrogatePair;
    procedure TestHighHighLowMatchesFPJSON;
    procedure TestBMPBeforeSurrogatePair;
    procedure TestLoneSurrogate;
    procedure TestASCII;
    procedure TestMixedRawAndEscaped;
    procedure TestMalformed;
  end;

  TResponseBuilders = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestResultShape;
    procedure TestErrorShape;
    procedure TestErrorWithData;
    procedure TestNullIdWhenUnreadable;
    procedure TestSingleLineWithEscapedNewline;
    procedure TestUtf8Serialization;
  end;

{ ───────── helpers ───────── }

function ParseObj(const AJson: string): TJSONObject;
begin
  Result := TJSONObject(GetJSON(AJson));
end;

procedure ExpectParsedValue(const AWireValue, AExpected: string);
var
  Msg: TJSONRPCMessage;
begin
  Msg := ParseJSONRPCMessage(
    '{"jsonrpc":"2.0","id":1,"method":"x","params":{"value":"' +
    AWireValue + '"}}');
  try
    Expect<Integer>(Ord(Msg.Kind)).ToBe(Ord(jrkRequest));
    Expect<string>(Msg.Params.Get('value', '')).ToBe(AExpected);
  finally
    FreeJSONRPCMessage(Msg);
  end;
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
  // The advertised revisions use single-message receive; arrays are invalid.
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

procedure TParseInvalid.TestInvalidNotificationShapeFlagged;
var
  Msg: TJSONRPCMessage;
begin
  // Malformed but identifiably a notification (method, no id): callers
  // must be able to drop it instead of replying (MCP fire-and-forget).
  Msg := ParseJSONRPCMessage(
    '{"jsonrpc":"2.0","method":"notifications/cancelled","params":[1]}');
  Expect<Integer>(Ord(Msg.Kind)).ToBe(Ord(jrkInvalid));
  Expect<Boolean>(Msg.NotificationShaped).ToBe(True);
  FreeJSONRPCMessage(Msg);
end;

procedure TParseInvalid.TestInvalidRequestShapeNotFlagged;
var
  Msg: TJSONRPCMessage;
begin
  // The same malformation with an id stays answerable with -32600.
  Msg := ParseJSONRPCMessage(
    '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":[1]}');
  Expect<Integer>(Ord(Msg.Kind)).ToBe(Ord(jrkInvalid));
  Expect<Boolean>(Msg.NotificationShaped).ToBe(False);
  FreeJSONRPCMessage(Msg);
end;

procedure TParseInvalid.TestNullIdIsRequestShaped;
var
  Msg: TJSONRPCMessage;
begin
  // An id member — even the forbidden null — makes the message
  // request-shaped: only the complete absence of id marks a
  // notification (JSON-RPC 2.0 §4.1).
  Msg := ParseJSONRPCMessage(
    '{"jsonrpc":"2.0","id":null,"method":"notifications/cancelled"}');
  Expect<Integer>(Ord(Msg.Kind)).ToBe(Ord(jrkInvalid));
  Expect<Boolean>(Msg.NotificationShaped).ToBe(False);
  FreeJSONRPCMessage(Msg);
end;

// JSON-RPC messages MUST be UTF-8 on every transport, verified
// 2026-11-27 against
// https://modelcontextprotocol.io/specification/2026-07-28/basic/transports#messages:
// ill-formed input is a parse error, not text to echo.
procedure TParseInvalid.TestInvalidUTF8IsParseError;
const
  BAD: array[0..5] of string = (
    #$C3#$41,               // lead byte, then no continuation
    #$C0#$AF,               // overlong '/'
    #$ED#$A0#$80,           // UTF-16 surrogate D800
    #$F4#$90#$80#$80,       // past U+10FFFF
    #$80,                   // lone continuation byte
    #$FF);
var
  I: Integer;
  Msg: TJSONRPCMessage;
begin
  for I := Low(BAD) to High(BAD) do
  begin
    Msg := ParseJSONRPCMessage('{"jsonrpc":"2.0","id":1,"method":"x",' +
      '"params":{"v":"a' + BAD[I] + 'b"}}');
    Expect<Integer>(Msg.ErrorCode).ToBe(JSONRPC_PARSE_ERROR);
    FreeJSONRPCMessage(Msg);
  end;
  // Truncated at the very end of the input: the length check, not a
  // bad continuation byte, refuses it, at the lead byte's offset.
  Msg := ParseJSONRPCMessage('{"jsonrpc":"2.0","id":1,"method":"x"}' + #$E4#$B8);
  Expect<Integer>(Msg.ErrorCode).ToBe(JSONRPC_PARSE_ERROR);
  Expect<Boolean>(Pos('invalid UTF-8 at byte 38', Msg.ErrorMessage) > 0)
    .ToBe(True);
  FreeJSONRPCMessage(Msg);
  Msg := ParseJSONRPCMessage('{"jsonrpc":"2.0","id":1,"method":"x",' +
    '"params":{"v":"' + UTF8_PAYLOAD + UTF8_GRINNING_FACE + #$F4#$8F#$BF#$BF +
    '"}}');
  Expect<Integer>(Ord(Msg.Kind)).ToBe(Ord(jrkRequest));
  FreeJSONRPCMessage(Msg);
end;

// A UTF-8 file name reaches the OS as the same bytes (#102 review): the
// library pins the file-system code pages with the string one. CI runs
// this suite under LC_ALL=C too, where the locale's code page is ASCII.
procedure TParseInvalid.TestUTF8FileNameRoundTrip;
var
  Dir, Path: string;
  Handle: THandle;
  Found: TSearchRec;
begin
  Dir := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'mcp-utf8-' + IntToStr(GetProcessID) + PathDelim;
  ForceDirectories(Dir);
  Path := Dir + 'Z' + #$C3#$BC + 'rich.conf';
  Handle := FileCreate(Path);
  Expect<Boolean>(Handle <> THandle(-1)).ToBe(True);
  FileClose(Handle);
  try
    Expect<Boolean>(FileExists(Path)).ToBe(True);
    {$IFDEF UNIX}
    // At the OS boundary the name is the UTF-8 bytes themselves, as
    // another process creating it would have written them.
    Expect<Integer>(FpAccess(PAnsiChar(RawByteString(Dir + 'Z' + #$C3#$BC +
      'rich.conf')), F_OK)).ToBe(0);
    {$ENDIF}
    Expect<Integer>(FindFirst(Dir + '*.conf', faAnyFile, Found)).ToBe(0);
    try
      Expect<string>(Found.Name).ToBe('Z' + #$C3#$BC + 'rich.conf');
    finally
      FindClose(Found);
    end;
  finally
    DeleteFile(Path);
    RemoveDir(Dir);
  end;
end;

procedure TParseInvalid.SetupTests;
begin
  Test('unparseable input → -32700', TestGarbage);
  Test('non-object → -32600', TestNonObject);
  Test('batch array → -32600 (advertised revisions are single-message)',
    TestBatchRejected);
  Test('jsonrpc ≠ "2.0" → -32600', TestWrongVersion);
  Test('missing method → -32600', TestMissingMethod);
  Test('null id → -32600 (MCP forbids null ids)', TestNullId);
  Test('array params → -32600', TestArrayParams);
  Test('readable id preserved on invalid message', TestIdPreservedOnInvalid);
  Test('invalid notification shape flagged for dropping',
    TestInvalidNotificationShapeFlagged);
  Test('invalid request shape stays answerable',
    TestInvalidRequestShapeNotFlagged);
  Test('null id counts as request-shaped', TestNullIdIsRequestShaped);
  Test('ill-formed UTF-8 → -32700; well-formed four-byte accepted',
    TestInvalidUTF8IsParseError);
  Test('a UTF-8 file name keeps its bytes on any locale',
    TestUTF8FileNameRoundTrip);
end;

{ ───────── Unicode escape input ───────── }

procedure TUnicodeEscapeInput.TestAdjacentBMP;
begin
  ExpectParsedValue('a\u4e16\u754cb', 'a' + UTF8_WORLD + 'b');
end;

procedure TUnicodeEscapeInput.TestAfterEscapedBackslash;
begin
  ExpectParsedValue('C:\\u4e16', 'C:\u4e16');
end;

procedure TUnicodeEscapeInput.TestSurrogatePair;
begin
  ExpectParsedValue('\ud83d\ude00', UTF8_GRINNING_FACE);
end;

// A high surrogate with no low one, then a pair: the library leaves
// surrogate escapes to fpjson, so it does what the fpjson it was built
// with does. FPC 3.2.2's drops the whole run; FPC 3.2.4's rejects it,
// and the message is then a parse error (verified 2026-11-27 with
// 3.2.2 and 3.2.4-rc2).
procedure TUnicodeEscapeInput.TestHighHighLowMatchesFPJSON;
const
  RUN = '\ud83d\ud83d\ude00';
var
  Baseline: TJSONObject;
  Msg: TJSONRPCMessage;
begin
  try
    Baseline := ParseObj('{"value":"' + RUN + '"}');
  except
    // 3.2.4 rejects this run with EScannerError; EParserError is also
    // the base of 3.2.2's EJSONParser, which it raises for invalid
    // JSON, though it accepts this run.
    on EParserError do
      Baseline := nil;
  end;
  if Baseline <> nil then
    try
      ExpectParsedValue(RUN, Baseline.Get('value', ''));
    finally
      Baseline.Free;
    end
  else
  begin
    Msg := ParseJSONRPCMessage('{"jsonrpc":"2.0","id":1,"method":"x",' +
      '"params":{"value":"' + RUN + '"}}');
    try
      Expect<Integer>(Ord(Msg.Kind)).ToBe(Ord(jrkInvalid));
      Expect<Integer>(Msg.ErrorCode).ToBe(JSONRPC_PARSE_ERROR);
    finally
      FreeJSONRPCMessage(Msg);
    end;
  end;
end;

procedure TUnicodeEscapeInput.TestBMPBeforeSurrogatePair;
begin
  ExpectParsedValue('\u4e16\ud83d\ude00', #$E4#$B8#$96 +
    UTF8_GRINNING_FACE);
end;

procedure TUnicodeEscapeInput.TestLoneSurrogate;
begin
  // Leave the lone high surrogate for fpjson, which drops it.
  ExpectParsedValue('x\ud83dy', 'xy');
end;

procedure TUnicodeEscapeInput.TestASCII;
begin
  ExpectParsedValue('a\u0022b', 'a"b');
end;

procedure TUnicodeEscapeInput.TestMixedRawAndEscaped;
begin
  ExpectParsedValue(#$E4#$B8#$96 + '\u754c', UTF8_WORLD);
end;

procedure TUnicodeEscapeInput.TestMalformed;
var
  Msg: TJSONRPCMessage;
begin
  Msg := ParseJSONRPCMessage(
    '{"jsonrpc":"2.0","id":1,"method":"x","params":{"value":"\u4g16"}}');
  try
    Expect<Integer>(Ord(Msg.Kind)).ToBe(Ord(jrkInvalid));
    Expect<Integer>(Msg.ErrorCode).ToBe(JSONRPC_PARSE_ERROR);
  finally
    FreeJSONRPCMessage(Msg);
  end;
end;

procedure TUnicodeEscapeInput.SetupTests;
begin
  Test('adjacent non-ASCII BMP escapes decode to exact UTF-8',
    TestAdjacentBMP);
  Test('escape after escaped backslash stays literal',
    TestAfterEscapedBackslash);
  Test('surrogate pair round-trips as four-byte UTF-8 via fpjson',
    TestSurrogatePair);
  Test('high-high-low run follows the fpjson it is built with',
    TestHighHighLowMatchesFPJSON);
  Test('non-surrogate BMP before surrogate pair stays correct',
    TestBMPBeforeSurrogatePair);
  Test('lone surrogate keeps fpjson behavior', TestLoneSurrogate);
  Test('ASCII Unicode escape stays escaped for fpjson', TestASCII);
  Test('mixed raw and escaped non-ASCII input', TestMixedRawAndEscaped);
  Test('malformed Unicode escape stays a parse error', TestMalformed);
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

procedure TResponseBuilders.TestUtf8Serialization;
var
  Payload: TJSONObject;
  Line: string;
begin
  Payload := ParseObj('{"text":"' + UTF8_PAYLOAD + '"}');
  Line := BuildResultResponse(nil, Payload);
  Expect<string>(Line).ToBe('{ "jsonrpc" : "2.0", "id" : null, ' +
    '"result" : { "text" : "' + UTF8_PAYLOAD + '" } }');
end;

procedure TResponseBuilders.SetupTests;
begin
  Test('result response shape', TestResultShape);
  Test('error response shape', TestErrorShape);
  Test('error data payload carried', TestErrorWithData);
  Test('nil id serializes as JSON null', TestNullIdWhenUnreadable);
  Test('single line, newlines escaped', TestSingleLineWithEscapedNewline);
  Test('non-ASCII serializes as byte-exact UTF-8', TestUtf8Serialization);
end;

begin
  TestRunnerProgram.AddSuite(TParseValid.Create('JSONRPC: valid input'));
  TestRunnerProgram.AddSuite(TParseInvalid.Create('JSONRPC: invalid input'));
  TestRunnerProgram.AddSuite(
    TUnicodeEscapeInput.Create('JSONRPC: Unicode escape input'));
  TestRunnerProgram.AddSuite(
    TResponseBuilders.Create('JSONRPC: response builders'));
  TestRunnerProgram.Run;
end.
