{ MCP.RequestState.Test — the sealing envelope on its own: canonical
  JSON, the token shape, and each verification failure with the reason
  it reports (MCP.Server.Test covers the same paths through dispatch). }

program MCP.RequestState.Test;

{$I MCP.inc}

uses
  SysUtils,

  fpjson,
  jsonparser,
  MCP.RequestState,
  TestingPascalLibrary;

const
  KEY_A = 'key-a-0123456789-0123456789-0123456789';
  KEY_B = 'key-b-0123456789-0123456789-0123456789';

type
  TCanonical = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestSortsMembersRecursively;
    procedure TestScalarsAndArrays;
  end;

  TSealing = class(TTestSuite)
  private
    FSealer: TMCPRequestStateSealer;
    FArguments: TJSONObject;
    function Reason(const AMethod, ATarget: string; AArguments: TJSONObject;
      const AToken: string): string;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;
    procedure TestTokenShape;
    procedure TestRoundTrip;
    procedure TestReasons;
    procedure TestOtherKeyRejected;
    procedure TestExpired;
    procedure TestNoKeysRefused;
  end;

function ParseObject(const AJson: string): TJSONObject;
begin
  Result := TJSONObject(GetJSON(AJson));
end;

function Canonical(const AJson: string): string;
var
  Data: TJSONData;
begin
  Data := GetJSON(AJson);
  try
    Result := CanonicalJSON(Data);
  finally
    Data.Free;
  end;
end;

procedure TCanonical.TestSortsMembersRecursively;
begin
  Expect<string>(Canonical('{"b":1,"a":{"z":true,"y":null}}'))
    .ToBe('{"a":{"y":null,"z":true},"b":1}');
  // Byte order: uppercase sorts before lowercase.
  Expect<string>(Canonical('{"b":1,"B":2,"a":3}'))
    .ToBe('{"B":2,"a":3,"b":1}');
end;

procedure TCanonical.TestScalarsAndArrays;
begin
  Expect<string>(Canonical('[3,"x",[{"b":0,"a":0}],false]'))
    .ToBe('[3,"x",[{"a":0,"b":0}],false]');
  Expect<string>(Canonical('{"q":"a\"b"}')).ToBe('{"q":"a\"b"}');
end;

procedure TCanonical.SetupTests;
begin
  Test('object members sorted by name at every depth',
    TestSortsMembersRecursively);
  Test('arrays keep their order; scalars and escapes as JSON',
    TestScalarsAndArrays);
end;

procedure TSealing.BeforeEach;
begin
  FSealer := TMCPRequestStateSealer.Create('srv', [KEY_A], 60000);
  FArguments := ParseObject('{"n":1}');
end;

procedure TSealing.AfterEach;
begin
  FArguments.Free;
  FSealer.Free;
end;

function TSealing.Reason(const AMethod, ATarget: string;
  AArguments: TJSONObject; const AToken: string): string;
var
  State: string;
begin
  if FSealer.Unseal(AMethod, ATarget, AArguments, AToken, State, Result) then
    Result := 'accepted:' + State;
end;

procedure TSealing.TestTokenShape;
var
  Token: string;
begin
  Token := FSealer.Seal('tools/call', 't', FArguments, 'secret-ish');
  Expect<Boolean>(Pos('v1.', Token) = 1).ToBe(True);
  // Three dot-separated parts: version, envelope, tag.
  Expect<Integer>(Length(Token) - Length(StringReplace(Token, '.', '',
    [rfReplaceAll]))).ToBe(2);
end;

procedure TSealing.TestRoundTrip;
begin
  Expect<string>(Reason('tools/call', 't', FArguments,
    FSealer.Seal('tools/call', 't', FArguments, 'st-' + #$C3#$A9)))
    .ToBe('accepted:st-' + #$C3#$A9);
end;

procedure TSealing.TestReasons;
var
  Token: string;
  Other: TJSONObject;
begin
  Token := FSealer.Seal('tools/call', 't', FArguments, 's');
  Expect<string>(Reason('tools/call', 't', FArguments, 'plain'))
    .ToBe('malformed token');
  Expect<string>(Reason('tools/call', 't', FArguments, Token + 'x'))
    .ToBe('authentication tag does not verify');
  Expect<string>(Reason('prompts/get', 't', FArguments, Token))
    .ToBe('bound to another method');
  Expect<string>(Reason('tools/call', 'u', FArguments, Token))
    .ToBe('bound to another target');
  Other := ParseObject('{"n":2}');
  try
    Expect<string>(Reason('tools/call', 't', Other, Token))
      .ToBe('bound to other arguments');
  finally
    Other.Free;
  end;
  // nil and {} are the same request: no arguments.
  Token := FSealer.Seal('tools/call', 't', nil, 's');
  Other := ParseObject('{}');
  try
    Expect<string>(Reason('tools/call', 't', Other, Token)).ToBe('accepted:s');
  finally
    Other.Free;
  end;
end;

procedure TSealing.TestOtherKeyRejected;
var
  Other: TMCPRequestStateSealer;
  Token, State, Why: string;
begin
  Token := FSealer.Seal('tools/call', 't', FArguments, 's');
  Other := TMCPRequestStateSealer.Create('srv', [KEY_B], 60000);
  try
    Expect<Boolean>(Other.Unseal('tools/call', 't', FArguments, Token,
      State, Why)).ToBe(False);
    Expect<string>(Why).ToBe('authentication tag does not verify');
  finally
    Other.Free;
  end;
end;

procedure TSealing.TestExpired;
var
  Short: TMCPRequestStateSealer;
  Token, State, Why: string;
begin
  Short := TMCPRequestStateSealer.Create('srv', [KEY_A], 1);
  try
    Token := Short.Seal('tools/call', 't', FArguments, 's');
    Sleep(20);
    Expect<Boolean>(Short.Unseal('tools/call', 't', FArguments, Token,
      State, Why)).ToBe(False);
    Expect<string>(Why).ToBe('expired');
    Expect<string>(State).ToBe('');
  finally
    Short.Free;
  end;
end;

procedure TSealing.TestNoKeysRefused;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    TMCPRequestStateSealer.Create('srv', [], 60000).Free;
  except
    on E: Exception do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TSealing.SetupTests;
begin
  Test('token is v1.<envelope>.<tag>', TestTokenShape);
  Test('round trip returns the state byte-exact', TestRoundTrip);
  Test('each binding failure reports its reason', TestReasons);
  Test('a token from another key does not verify', TestOtherKeyRejected);
  Test('an expired token reports expired and no state', TestExpired);
  Test('a sealer without keys cannot be built', TestNoKeysRefused);
end;

begin
  TestRunnerProgram.AddSuite(TCanonical.Create('RequestState: canonical JSON'));
  TestRunnerProgram.AddSuite(TSealing.Create('RequestState: sealing'));
  TestRunnerProgram.Run;
end.
