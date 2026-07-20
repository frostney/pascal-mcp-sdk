{ MCP.Protocol.Test — the per-request metadata model of the stateless
  2026-07-28 revision: required _meta fields (-32602 when missing, in
  every shape: no params, no _meta, missing protocolVersion, missing or
  non-object clientCapabilities), version negotiation (-32022 with the
  supported/requested data payload), optional clientInfo / logLevel
  extraction, capability lookup, and result stamping (resultType
  "complete" + serverInfo _meta, idempotent, never clobbering fields the
  builder already set). }

program MCP.Protocol.Test;

{$I Shared.inc}

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
    procedure TestHasCapability;
  end;

  TStamping = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestStampsResultType;
    procedure TestStampsServerInfo;
    procedure TestPreservesExistingResultType;
    procedure TestIdempotent;
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

procedure TMetaValidation.TestHasCapability;
var
  Params: TJSONObject;
  Ctx: TMCPRequestContext;
  MetaErr: TMCPMetaError;
begin
  Params := ParseObj(
    '{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{"roots":{}}}}');
  Expect<Boolean>(
    ExtractRequestContext(Params, Supported, Ctx, MetaErr)).ToBe(True);
  Expect<Boolean>(Ctx.HasCapability('roots')).ToBe(True);
  Expect<Boolean>(Ctx.HasCapability('sampling')).ToBe(False);
  Params.Free;
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
  Test('HasCapability lookup', TestHasCapability);
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

begin
  TestRunnerProgram.AddSuite(
    TMetaValidation.Create('Protocol: _meta validation'));
  TestRunnerProgram.AddSuite(TStamping.Create('Protocol: result stamping'));
  TestRunnerProgram.Run;
end.
