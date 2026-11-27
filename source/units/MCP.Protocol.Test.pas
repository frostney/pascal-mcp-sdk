{ MCP.Protocol.Test — the per-request metadata model of the stateless
  2026-07-28 revision: required _meta fields (-32602 when missing, in
  every shape: no params, no _meta, missing protocolVersion, missing or
  non-object clientCapabilities), version negotiation (-32022 with the
  supported/requested data payload), optional clientInfo / logLevel
  extraction, capability lookup, and result stamping (resultType
  "complete" + serverInfo _meta, idempotent, never clobbering fields the
  builder already set). }

program MCP.Protocol.Test;

{$I MCP.inc}

uses
  SysUtils,

  fpjson,
  jsonparser,
  MCP.JSONRPC,
  MCP.Protocol,
  TestingPascalLibrary;

type
  TMetaValidation = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestNilParams;
    procedure TestMissingMeta;
    procedure TestMissingVersion;
    procedure TestMissingCapabilities;
    procedure TestNonObjectCapabilities;
    procedure TestUnsupportedVersion;
    procedure TestValidMinimal;
    procedure TestClientInfoExtracted;
    procedure TestLogLevelExtracted;
    procedure TestUnknownLogLevelRejected;
    procedure TestWrongCaseLogLevelRejected;
    procedure TestHasCapability;
    procedure TestHasSubCapability;
    procedure TestMissingCapabilityData;
    procedure TestMissingRequiredMetaNames;
    procedure TestMissingRequiredMetaComplete;
  end;

  TStamping = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestStampsResultType;
    procedure TestStampsServerInfo;
    procedure TestPreservesExistingResultType;
    procedure TestIdempotent;
  end;

  TLegacyVersions = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestBatchRevisionExcluded;
  end;

  TCancellationContext = class(TTestSuite)
  private
    FCancelled: Boolean;
    function ProbeCancellation: Boolean;
  public
    procedure SetupTests; override;
    procedure TestMissingProbeIsNotCancelled;
    procedure TestProbeIsPolled;
  end;

const
  VALID_META =
    '{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{}}}';

var
  Supported: array[0..0] of string = (MCP_PROTOCOL_VERSION);

function ParseObj(const AJson: string): TJSONObject;
begin
  Result := TJSONObject(GetJSON(AJson));
end;

procedure FreeMetaError(var AError: TMCPMetaError);
begin
  FreeAndNil(AError.Data);
end;

{ ───────── _meta validation ───────── }

procedure TMetaValidation.TestNilParams;
var
  Ctx: TMCPRequestContext;
  MetaErr: TMCPMetaError;
begin
  Expect<Boolean>(
    ExtractRequestContext(nil, Supported, Ctx, MetaErr)).ToBe(False);
  Expect<Integer>(MetaErr.Code).ToBe(JSONRPC_INVALID_PARAMS);
  FreeMetaError(MetaErr);
end;

procedure TMetaValidation.TestMissingMeta;
var
  Params: TJSONObject;
  Ctx: TMCPRequestContext;
  MetaErr: TMCPMetaError;
begin
  Params := ParseObj('{"name":"echo"}');
  Expect<Boolean>(
    ExtractRequestContext(Params, Supported, Ctx, MetaErr)).ToBe(False);
  Expect<Integer>(MetaErr.Code).ToBe(JSONRPC_INVALID_PARAMS);
  FreeMetaError(MetaErr);
  Params.Free;
end;

procedure TMetaValidation.TestMissingVersion;
var
  Params: TJSONObject;
  Ctx: TMCPRequestContext;
  MetaErr: TMCPMetaError;
begin
  Params := ParseObj(
    '{"_meta":{"io.modelcontextprotocol/clientCapabilities":{}}}');
  Expect<Boolean>(
    ExtractRequestContext(Params, Supported, Ctx, MetaErr)).ToBe(False);
  Expect<Integer>(MetaErr.Code).ToBe(JSONRPC_INVALID_PARAMS);
  Expect<Boolean>(
    Pos('protocolVersion', MetaErr.Message) > 0).ToBe(True);
  FreeMetaError(MetaErr);
  Params.Free;
end;

// MissingRequiredMeta (#79): the first absent or mistyped required
// field, in the order ExtractRequestContext checks them. Required
// fields verified 2026-11-26 against
// https://modelcontextprotocol.io/specification/2026-07-28/basic/index#_meta
function MissingOf(const AJson: string): string;
var
  Params: TJSONObject;
begin
  Params := ParseObj(AJson);
  try
    Result := MissingRequiredMeta(Params);
  finally
    Params.Free;
  end;
end;

procedure TMetaValidation.TestMissingRequiredMetaNames;
begin
  Expect<string>(MissingRequiredMeta(nil)).ToBe('_meta');
  Expect<string>(MissingOf('{}')).ToBe('_meta');
  Expect<string>(MissingOf('{"_meta":[]}')).ToBe('_meta');
  Expect<string>(MissingOf(
    '{"_meta":{"io.modelcontextprotocol/clientCapabilities":{}}}'))
    .ToBe('_meta["io.modelcontextprotocol/protocolVersion"]');
  Expect<string>(MissingOf(
    '{"_meta":{"io.modelcontextprotocol/protocolVersion":7,' +
    '"io.modelcontextprotocol/clientCapabilities":{}}}'))
    .ToBe('_meta["io.modelcontextprotocol/protocolVersion"]');
  Expect<string>(MissingOf(
    '{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":"none"}}'))
    .ToBe('_meta["io.modelcontextprotocol/clientCapabilities"]');
end;

procedure TMetaValidation.TestMissingRequiredMetaComplete;
begin
  // Complete, even with a version the server does not support: that
  // is -32022, not a malformed request.
  Expect<string>(MissingOf(
    '{"_meta":{"io.modelcontextprotocol/protocolVersion":"1999-01-01",' +
    '"io.modelcontextprotocol/clientCapabilities":{}}}')).ToBe('');
end;

procedure TMetaValidation.TestMissingCapabilities;
var
  Params: TJSONObject;
  Ctx: TMCPRequestContext;
  MetaErr: TMCPMetaError;
begin
  Params := ParseObj(
    '{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}');
  Expect<Boolean>(
    ExtractRequestContext(Params, Supported, Ctx, MetaErr)).ToBe(False);
  Expect<Integer>(MetaErr.Code).ToBe(JSONRPC_INVALID_PARAMS);
  Expect<Boolean>(
    Pos('clientCapabilities', MetaErr.Message) > 0).ToBe(True);
  FreeMetaError(MetaErr);
  Params.Free;
end;

procedure TMetaValidation.TestNonObjectCapabilities;
var
  Params: TJSONObject;
  Ctx: TMCPRequestContext;
  MetaErr: TMCPMetaError;
begin
  Params := ParseObj(
    '{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":"nope"}}');
  Expect<Boolean>(
    ExtractRequestContext(Params, Supported, Ctx, MetaErr)).ToBe(False);
  Expect<Integer>(MetaErr.Code).ToBe(JSONRPC_INVALID_PARAMS);
  FreeMetaError(MetaErr);
  Params.Free;
end;

procedure TMetaValidation.TestUnsupportedVersion;
var
  Params: TJSONObject;
  Ctx: TMCPRequestContext;
  MetaErr: TMCPMetaError;
  Data: TJSONObject;
begin
  Params := ParseObj(
    '{"_meta":{"io.modelcontextprotocol/protocolVersion":"1900-01-01",' +
    '"io.modelcontextprotocol/clientCapabilities":{}}}');
  Expect<Boolean>(
    ExtractRequestContext(Params, Supported, Ctx, MetaErr)).ToBe(False);
  Expect<Integer>(MetaErr.Code)
    .ToBe(MCP_ERROR_UNSUPPORTED_PROTOCOL_VERSION);
  Data := TJSONObject(MetaErr.Data);
  Expect<string>(Data.Get('requested', '')).ToBe('1900-01-01');
  Expect<string>(TJSONArray(Data.Find('supported')).Strings[0])
    .ToBe(MCP_PROTOCOL_VERSION);
  FreeMetaError(MetaErr);
  Params.Free;
end;

procedure TMetaValidation.TestValidMinimal;
var
  Params: TJSONObject;
  Ctx: TMCPRequestContext;
  MetaErr: TMCPMetaError;
begin
  Params := ParseObj(VALID_META);
  Expect<Boolean>(
    ExtractRequestContext(Params, Supported, Ctx, MetaErr)).ToBe(True);
  Expect<string>(Ctx.ProtocolVersion).ToBe(MCP_PROTOCOL_VERSION);
  Expect<Boolean>(Ctx.ClientCapabilities <> nil).ToBe(True);
  Expect<string>(Ctx.ClientName).ToBe('');
  Params.Free;
end;

procedure TMetaValidation.TestClientInfoExtracted;
var
  Params: TJSONObject;
  Ctx: TMCPRequestContext;
  MetaErr: TMCPMetaError;
begin
  Params := ParseObj(
    '{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientInfo":' +
    '{"name":"ExampleClient","version":"1.2.3"},' +
    '"io.modelcontextprotocol/clientCapabilities":{}}}');
  Expect<Boolean>(
    ExtractRequestContext(Params, Supported, Ctx, MetaErr)).ToBe(True);
  Expect<string>(Ctx.ClientName).ToBe('ExampleClient');
  Expect<string>(Ctx.ClientVersion).ToBe('1.2.3');
  Params.Free;
end;

procedure TMetaValidation.TestLogLevelExtracted;
var
  Params: TJSONObject;
  Ctx: TMCPRequestContext;
  MetaErr: TMCPMetaError;
begin
  Params := ParseObj(
    '{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/logLevel":"debug",' +
    '"io.modelcontextprotocol/clientCapabilities":{}}}');
  Expect<Boolean>(
    ExtractRequestContext(Params, Supported, Ctx, MetaErr)).ToBe(True);
  Expect<string>(Ctx.LogLevel).ToBe('debug');
  Params.Free;
end;

procedure TMetaValidation.TestUnknownLogLevelRejected;
var
  Params: TJSONObject;
  Ctx: TMCPRequestContext;
  MetaErr: TMCPMetaError;
begin
  Params := ParseObj(
    '{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/logLevel":"verbose",' +
    '"io.modelcontextprotocol/clientCapabilities":{}}}');
  Expect<Boolean>(
    ExtractRequestContext(Params, Supported, Ctx, MetaErr)).ToBe(False);
  Expect<Integer>(MetaErr.Code).ToBe(JSONRPC_INVALID_PARAMS);
  Expect<Boolean>(Pos('logLevel', MetaErr.Message) > 0).ToBe(True);
  FreeMetaError(MetaErr);
  Params.Free;
end;

procedure TMetaValidation.TestWrongCaseLogLevelRejected;
var
  Params: TJSONObject;
  Ctx: TMCPRequestContext;
  MetaErr: TMCPMetaError;
begin
  Params := ParseObj(
    '{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/logLevel":"INFO",' +
    '"io.modelcontextprotocol/clientCapabilities":{}}}');
  Expect<Boolean>(
    ExtractRequestContext(Params, Supported, Ctx, MetaErr)).ToBe(False);
  Expect<Integer>(MetaErr.Code).ToBe(JSONRPC_INVALID_PARAMS);
  Expect<Boolean>(Pos('logLevel', MetaErr.Message) > 0).ToBe(True);
  FreeMetaError(MetaErr);
  Params.Free;
end;

procedure TMetaValidation.TestHasCapability;
var
  Params: TJSONObject;
  Ctx: TMCPRequestContext;
  MetaErr: TMCPMetaError;
begin
  // A defined capability counts only in its schema shape; the set is
  // open, so a client's own capability counts whatever its value
  // (ClientCapabilities, schema 2026-07-28, verified 2026-11-27:
  // https://modelcontextprotocol.io/specification/2026-07-28/schema#clientcapabilities).
  Params := ParseObj(
    '{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{"roots":{},' +
    '"sampling":null,"elicitation":false,"com.example/feature":true,' +
    '"com.example/other":null}}}');
  try
    Expect<Boolean>(
      ExtractRequestContext(Params, Supported, Ctx, MetaErr)).ToBe(True);
    Expect<Boolean>(Ctx.HasCapability('roots')).ToBe(True);
    Expect<Boolean>(Ctx.HasCapability('sampling')).ToBe(False);
    Expect<Boolean>(Ctx.HasCapability('elicitation')).ToBe(False);
    Expect<Boolean>(Ctx.HasCapability('com.example/feature')).ToBe(True);
    Expect<Boolean>(Ctx.HasCapability('com.example/other')).ToBe(True);
    Expect<Boolean>(Ctx.HasCapability('com.example/absent')).ToBe(False);
    // A member stored as nil is still a present key.
    Ctx.ClientCapabilities.Add('com.example/built', TJSONData(nil));
    Expect<Boolean>(Ctx.HasCapability('com.example/built')).ToBe(True);
  finally
    Params.Free;
  end;
end;

// The capability members a client declares (#108): an empty
// elicitation object means form only (verified 2026-11-27,
// https://modelcontextprotocol.io/specification/2026-07-28/client/elicitation#capabilities),
// and a classic client's capability that is no object declares none.
procedure TMetaValidation.TestHasSubCapability;
var
  Ctx: TMCPRequestContext;

  function Members(const AVersion, ACapabilities: string): string;
  begin
    Ctx := Default(TMCPRequestContext);
    Ctx.ProtocolVersion := AVersion;
    Ctx.ClientCapabilities := ParseObj(ACapabilities);
    try
      Result := BoolToStr(Ctx.HasSubCapability('elicitation', 'form'),
        'F', 'f') + BoolToStr(Ctx.HasSubCapability('elicitation', 'url'),
        'U', 'u') + BoolToStr(Ctx.HasSubCapability('sampling', 'tools'),
        'T', 't');
    finally
      Ctx.ClientCapabilities.Free;
    end;
  end;

begin
  Expect<string>(Members('2026-07-28', '{}')).ToBe('fut');
  Expect<string>(Members('2026-07-28', '{"elicitation":{}}')).ToBe('Fut');
  Expect<string>(Members('2026-07-28', '{"elicitation":{"url":{}}}'))
    .ToBe('fUt');
  Expect<string>(Members('2026-07-28', '{"elicitation":{"form":{},' +
    '"url":{}},"sampling":{"tools":{}}}')).ToBe('FUT');
  // The schema types sampling.tools as an object, so true declares
  // neither it nor sampling.
  Expect<string>(Members('2026-07-28', '{"sampling":{"tools":true}}'))
    .ToBe('fut');
  // Classic clients count by presence, but false declares no mode.
  Expect<string>(Members('2025-11-25', '{"elicitation":false}')).ToBe('fut');
  Expect<string>(Members('2025-11-25', '{"elicitation":{}}')).ToBe('Fut');
  Expect<string>(Members('2025-11-25', '{"sampling":{"tools":true}}'))
    .ToBe('fuT');
end;

procedure EmptyCapabilityData;
begin
  BuildMissingCapabilityData([]).Free;
end;

procedure RepeatedCapabilityData;
begin
  BuildMissingCapabilityData(['sampling', 'roots', 'sampling']).Free;
end;

procedure MemberWithoutCapability;
begin
  BuildMissingCapabilityData('', 'url').Free;
end;

procedure CapabilityWithoutMember;
begin
  BuildMissingCapabilityData('elicitation', '').Free;
end;

function ArgumentRefused(AProc: TProcedure): Boolean;
begin
  Result := False;
  try
    AProc();
  except
    on E: EArgumentException do
      Result := True;
  end;
end;

// -32021 data names at least one capability, so an empty list is a
// caller bug, not data the validator would reject later.
procedure TMetaValidation.TestMissingCapabilityData;
var
  Data: TJSONObject;
begin
  Data := BuildMissingCapabilityData(['sampling', 'com.example/feature']);
  try
    Expect<string>(Data.AsJSON).ToBe('{ "requiredCapabilities" : ' +
      '{ "sampling" : {}, "com.example/feature" : {} } }');
    Expect<Boolean>(IsMissingCapabilityData(Data)).ToBe(True);
  finally
    Data.Free;
  end;
  Expect<Boolean>(ArgumentRefused(EmptyCapabilityData)).ToBe(True);
  // A repeat is refused before anything is allocated.
  Expect<Boolean>(ArgumentRefused(RepeatedCapabilityData)).ToBe(True);
  // One member of a capability (#108), shaped as -32021 requires
  // (MissingRequiredClientCapabilityError, schema 2026-07-28, verified
  // 2026-11-27: https://modelcontextprotocol.io/specification/2026-07-28/schema).
  Data := BuildMissingCapabilityData('elicitation', 'url');
  try
    Expect<string>(Data.AsJSON).ToBe('{ "requiredCapabilities" : ' +
      '{ "elicitation" : { "url" : {} } } }');
    Expect<Boolean>(IsMissingCapabilityData(Data)).ToBe(True);
  finally
    Data.Free;
  end;
  Expect<Boolean>(ArgumentRefused(MemberWithoutCapability)).ToBe(True);
  Expect<Boolean>(ArgumentRefused(CapabilityWithoutMember)).ToBe(True);
end;

procedure TMetaValidation.SetupTests;
begin
  Test('nil params → -32602', TestNilParams);
  Test('missing _meta → -32602', TestMissingMeta);
  Test('missing protocolVersion → -32602', TestMissingVersion);
  Test('missing clientCapabilities → -32602', TestMissingCapabilities);
  Test('non-object clientCapabilities → -32602', TestNonObjectCapabilities);
  Test('unknown version → -32022 with supported list',
    TestUnsupportedVersion);
  Test('minimal valid _meta accepted', TestValidMinimal);
  Test('clientInfo extracted', TestClientInfoExtracted);
  Test('logLevel extracted', TestLogLevelExtracted);
  Test('unknown logLevel → -32602', TestUnknownLogLevelRejected);
  Test('wrong-case logLevel → -32602', TestWrongCaseLogLevelRejected);
  Test('HasCapability: defined capabilities in shape, custom by presence',
    TestHasCapability);
  Test('HasSubCapability: members, empty elicitation, classic values',
    TestHasSubCapability);
  Test('BuildMissingCapabilityData lists every name or one member, refuses none or repeats',
    TestMissingCapabilityData);
  Test('MissingRequiredMeta names the first missing field',
    TestMissingRequiredMetaNames);
  Test('MissingRequiredMeta is empty for a complete envelope',
    TestMissingRequiredMetaComplete);
end;

{ ───────── result stamping ───────── }

procedure TStamping.TestStampsResultType;
var
  ResultObj: TJSONObject;
begin
  ResultObj := TJSONObject.Create;
  StampResult(ResultObj, 'srv', '1.0');
  Expect<string>(ResultObj.Get('resultType', '')).ToBe('complete');
  ResultObj.Free;
end;

procedure TStamping.TestStampsServerInfo;
var
  ResultObj, Meta, Info: TJSONObject;
begin
  ResultObj := TJSONObject.Create;
  StampResult(ResultObj, 'srv', '1.0');
  Meta := TJSONObject(ResultObj.Find('_meta'));
  Info := TJSONObject(Meta.Find(META_KEY_SERVER_INFO));
  Expect<string>(Info.Get('name', '')).ToBe('srv');
  Expect<string>(Info.Get('version', '')).ToBe('1.0');
  ResultObj.Free;
end;

procedure TStamping.TestPreservesExistingResultType;
var
  ResultObj: TJSONObject;
begin
  ResultObj := TJSONObject.Create;
  ResultObj.Add('resultType', 'input_required');
  StampResult(ResultObj, 'srv', '1.0');
  Expect<string>(ResultObj.Get('resultType', '')).ToBe('input_required');
  ResultObj.Free;
end;

procedure TStamping.TestIdempotent;
var
  ResultObj: TJSONObject;
begin
  ResultObj := TJSONObject.Create;
  StampResult(ResultObj, 'srv', '1.0');
  StampResult(ResultObj, 'other', '9.9');
  Expect<string>(
    TJSONObject(TJSONObject(ResultObj.Find('_meta'))
      .Find(META_KEY_SERVER_INFO)).Get('name', '')).ToBe('srv');
  Expect<Integer>(ResultObj.Count).ToBe(2); // resultType + _meta, once
  ResultObj.Free;
end;

procedure TStamping.SetupTests;
begin
  Test('resultType "complete" stamped', TestStampsResultType);
  Test('serverInfo stamped in _meta', TestStampsServerInfo);
  Test('existing resultType preserved', TestPreservesExistingResultType);
  Test('stamping is idempotent', TestIdempotent);
end;

{ ───────── legacy versions ───────── }

procedure TLegacyVersions.TestBatchRevisionExcluded;
begin
  Expect<Boolean>(IsLegacyProtocolVersion('2025-03-26')).ToBe(False);
end;

procedure TLegacyVersions.SetupTests;
begin
  Test('2025-03-26 batch revision excluded', TestBatchRevisionExcluded);
end;

{ ───────── cooperative cancellation context ───────── }

function TCancellationContext.ProbeCancellation: Boolean;
begin
  Result := FCancelled;
end;

procedure TCancellationContext.TestMissingProbeIsNotCancelled;
var
  Ctx: TMCPRequestContext;
begin
  Ctx := Default(TMCPRequestContext);
  Expect<Boolean>(Ctx.IsCancelled).ToBe(False);
end;

procedure TCancellationContext.TestProbeIsPolled;
var
  Ctx: TMCPRequestContext;
begin
  Ctx := Default(TMCPRequestContext);
  Ctx.CancellationProbe := ProbeCancellation;
  FCancelled := False;
  Expect<Boolean>(Ctx.IsCancelled).ToBe(False);
  FCancelled := True;
  Expect<Boolean>(Ctx.IsCancelled).ToBe(True);
end;

procedure TCancellationContext.SetupTests;
begin
  Test('missing cancellation probe reports false',
    TestMissingProbeIsNotCancelled);
  Test('cancellation probe is polled cooperatively', TestProbeIsPolled);
end;

begin
  TestRunnerProgram.AddSuite(
    TMetaValidation.Create('Protocol: _meta validation'));
  TestRunnerProgram.AddSuite(TStamping.Create('Protocol: result stamping'));
  TestRunnerProgram.AddSuite(
    TLegacyVersions.Create('Protocol: legacy versions'));
  TestRunnerProgram.AddSuite(
    TCancellationContext.Create('Protocol: cancellation context'));
  TestRunnerProgram.Run;
end.
