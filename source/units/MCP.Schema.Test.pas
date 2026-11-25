{ MCP.Schema.Test — the fluent schema builder (object envelope, all
  four property types, description handling, required-by-default with
  opt-out, the empty-required case) and class-derived schemas
  (SchemaFrom: published-property type mapping incl. enum values,
  declaration order, and the unsupported-kind registration error). }

program MCP.Schema.Test;

{$I MCP.inc}

uses
  Math,
  SysUtils,

  fpjson,
  MCP.Schema,
  TestingPascalLibrary;

type
  TProbeColor = (pcRed, pcGreen, pcBlue);

  TProbeArgs = class(TMCPArgs)
  private
    FLabelText: string;
    FCount: Integer;
    FRatio: Double;
    FFlag: Boolean;
    FColor: TProbeColor;
  published
    property labelText: string read FLabelText write FLabelText;
    property count: Integer read FCount write FCount;
    property ratio: Double read FRatio write FRatio;
    property flag: Boolean read FFlag write FFlag;
    property color: TProbeColor read FColor write FColor;
  end;

  // tkClass has no JSON Schema mapping — registration must fail.
  TUnmappableArgs = class(TMCPArgs)
  private
    FPayload: TObject;
  published
    property payload: TObject read FPayload write FPayload;
  end;

  // Optionality via standard property directives.
  TOptionalArgs = class(TMCPArgs)
  private
    FQuery: string;
    FRetries: Integer;
    FVerbose: Boolean;
    FColor: TProbeColor;
    FNickname: string;
  published
    property query: string read FQuery write FQuery;
    property retries: Integer read FRetries write FRetries default 3;
    property verbose: Boolean read FVerbose write FVerbose default False;
    property color: TProbeColor read FColor write FColor default pcGreen;
    property nickname: string read FNickname write FNickname stored False;
  end;

  TQWordArgs = class(TMCPArgs)
  private
    FValue: QWord;
  published
    property value: QWord read FValue write FValue;
  end;

  TSchemaBuilder = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestObjectEnvelope;
    procedure TestPropertyTypes;
    procedure TestDescriptions;
    procedure TestRequiredByDefault;
    procedure TestOptionalOptOut;
    procedure TestNoRequiredKeyWhenEmpty;
    procedure TestBuildReuseRaises;
    procedure TestAddAfterBuildRaises;
    procedure TestCopySeesConsumedState;
    procedure TestCopySharesInProgressState;
    procedure TestDefaultRecordRaises;
    procedure TestDuplicatePropertyRaises;
  end;

  TSchemaFromClass = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestTypeMapping;
    procedure TestEnumValues;
    procedure TestAllRequiredDeclarationOrder;
    procedure TestUnmappableKindRaises;
    procedure TestDefaultsBecomeOptional;
    procedure TestStoredFalseBecomesOptional;
    procedure TestSerializeRoundTrip;
    procedure TestSerializeQWord;
  end;

  // MCPWireNumber: the number text the wire carries.
  TWireNumber = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestJavaScriptForms;
    procedure TestEveryFormParsesBack;
    procedure TestNonFiniteRaises;
    procedure TestSerializeNaNRaises;
  end;

// The wire text of MCPWireNumber(AValue).
function WireText(AValue: Double): string;
var
  Node: TJSONData;
begin
  Node := MCPWireNumber(AValue);
  try
    Result := Node.AsJSON;
  finally
    Node.Free;
  end;
end;

// Doubles that exercise each branch: the shortest decimal needs 1, 15,
// 16 or 17 digits; plain and exponent notation on both sides of
// JavaScript's thresholds (1e-7 and 1e21); subnormal, largest finite,
// negative zero, and the 2^53 integer-node bound. Expected texts are
// what JSON.stringify writes for the same Double.
const
  WIRE_CASES: array[0..17] of record
    Value: Double;
    Text: string;
  end = (
    (Value: 0.25; Text: '0.25'),
    (Value: 0.1; Text: '0.1'),
    (Value: -0.5; Text: '-0.5'),
    (Value: 123.456; Text: '123.456'),
    (Value: 1 / 3; Text: '0.3333333333333333'),
    (Value: 1.0000000000000002; Text: '1.0000000000000002'),
    (Value: 0.30000000000000004; Text: '0.30000000000000004'),
    (Value: 5E-324; Text: '5e-324'),
    (Value: 1.7976931348623157E308; Text: '1.7976931348623157e+308'),
    (Value: 1E-7; Text: '1e-7'),
    (Value: 0.000001; Text: '0.000001'),
    (Value: 2.5E-10; Text: '2.5e-10'),
    (Value: 1E15; Text: '1000000000000000'),
    (Value: 9007199254740992.0; Text: '9007199254740992'),
    (Value: 1.2345678901234568E20; Text: '123456789012345680000'),
    (Value: 1E21; Text: '1e+21'),
    (Value: 100; Text: '100'),
    (Value: -0.0; Text: '0')
  );

procedure TSchemaBuilder.TestObjectEnvelope;
var
  Schema: TJSONObject;
begin
  Schema := ObjectSchema.AddString('name').Build;
  Expect<string>(Schema.Get('type', '')).ToBe('object');
  Expect<Boolean>(Schema.Find('properties') <> nil).ToBe(True);
  Schema.Free;
end;

procedure TSchemaBuilder.TestPropertyTypes;
var
  Schema: TJSONObject;
begin
  Schema := ObjectSchema
    .AddString('s').AddNumber('n').AddInteger('i').AddBoolean('b')
    .Build;
  Expect<string>(
    TJSONData(Schema.FindPath('properties.s.type')).AsString).ToBe('string');
  Expect<string>(
    TJSONData(Schema.FindPath('properties.n.type')).AsString).ToBe('number');
  Expect<string>(
    TJSONData(Schema.FindPath('properties.i.type')).AsString).ToBe('integer');
  Expect<string>(
    TJSONData(Schema.FindPath('properties.b.type')).AsString).ToBe('boolean');
  Schema.Free;
end;

procedure TSchemaBuilder.TestDescriptions;
var
  Schema: TJSONObject;
begin
  Schema := ObjectSchema
    .AddString('described', 'has one')
    .AddString('bare')
    .Build;
  Expect<string>(
    TJSONData(Schema.FindPath('properties.described.description')).AsString)
    .ToBe('has one');
  // An empty description is omitted, not emitted as "".
  Expect<Boolean>(
    Schema.FindPath('properties.bare.description') = nil).ToBe(True);
  Schema.Free;
end;

procedure TSchemaBuilder.TestRequiredByDefault;
var
  Schema: TJSONObject;
  Required: TJSONArray;
begin
  Schema := ObjectSchema.AddString('a').AddNumber('b').Build;
  Required := TJSONArray(Schema.Find('required'));
  Expect<Integer>(Required.Count).ToBe(2);
  Expect<string>(Required[0].AsString).ToBe('a');
  Expect<string>(Required[1].AsString).ToBe('b');
  Schema.Free;
end;

procedure TSchemaBuilder.TestOptionalOptOut;
var
  Schema: TJSONObject;
  Required: TJSONArray;
begin
  Schema := ObjectSchema
    .AddString('needed')
    .AddString('extra', 'optional trailing detail', False)
    .Build;
  Required := TJSONArray(Schema.Find('required'));
  Expect<Integer>(Required.Count).ToBe(1);
  Expect<string>(Required[0].AsString).ToBe('needed');
  Schema.Free;
end;

procedure TSchemaBuilder.TestNoRequiredKeyWhenEmpty;
var
  Schema: TJSONObject;
begin
  Schema := ObjectSchema.AddString('all', '', False).Build;
  Expect<Boolean>(Schema.Find('required') = nil).ToBe(True);
  Schema.Free;
end;

procedure TSchemaBuilder.TestBuildReuseRaises;
var
  Builder: TMCPSchema;
  ErrorMessage: string;
  Schema: TJSONObject;
begin
  Builder := ObjectSchema.AddString('name');
  Schema := Builder.Build;
  ErrorMessage := '';
  try
    Builder.Build;
  except
    on E: EMCPSchema do
      ErrorMessage := E.Message;
  end;
  Expect<string>(ErrorMessage).ToBe('Schema was already built');
  Schema.Free;
end;

procedure TSchemaBuilder.TestAddAfterBuildRaises;
var
  Builder: TMCPSchema;
  ErrorMessage: string;
  Schema: TJSONObject;
begin
  Builder := ObjectSchema;
  Schema := Builder.Build;
  ErrorMessage := '';
  try
    Builder.AddString('late');
  except
    on E: EMCPSchema do
      ErrorMessage := E.Message;
  end;
  Expect<string>(ErrorMessage).ToBe('Schema was already built');
  Schema.Free;
end;

procedure TSchemaBuilder.TestCopySeesConsumedState;
var
  Original, Copied: TMCPSchema;
  ErrorMessage: string;
  Schema: TJSONObject;
begin
  // The reuse guard must survive record copies (issue #29): after any
  // alias builds, every other alias is consumed too.
  Original := ObjectSchema.AddString('name');
  Copied := Original;
  Schema := Original.Build;
  ErrorMessage := '';
  try
    Copied.AddString('late');
  except
    on E: EMCPSchema do
      ErrorMessage := E.Message;
  end;
  Expect<string>(ErrorMessage).ToBe('Schema was already built');
  ErrorMessage := '';
  try
    Copied.Build;
  except
    on E: EMCPSchema do
      ErrorMessage := E.Message;
  end;
  Expect<string>(ErrorMessage).ToBe('Schema was already built');
  Schema.Free;
end;

procedure TSchemaBuilder.TestCopySharesInProgressState;
var
  Original, Copied: TMCPSchema;
  Schema: TJSONObject;
begin
  // Copies alias one schema-in-progress by design: additions through
  // either alias land in the same schema.
  Original := ObjectSchema.AddString('first');
  Copied := Original;
  Copied.AddNumber('second');
  Schema := Original.Build;
  Expect<Integer>(TJSONObject(Schema.Find('properties')).Count).ToBe(2);
  Schema.Free;
end;

procedure TSchemaBuilder.TestDefaultRecordRaises;
var
  Unbound: TMCPSchema;
  ErrorMessage: string;
begin
  // A default record never went through ObjectSchema: building it must
  // raise instead of dereferencing nil.
  Unbound := Default(TMCPSchema);
  ErrorMessage := '';
  try
    Unbound.Build;
  except
    on E: EMCPSchema do
      ErrorMessage := E.Message;
  end;
  Expect<string>(ErrorMessage).ToBe('Schema was already built');
end;

procedure TSchemaBuilder.TestDuplicatePropertyRaises;
var
  Builder: TMCPSchema;
  ErrorMessage: string;
  Schema: TJSONObject;
begin
  Builder := ObjectSchema.AddString('duplicate');
  ErrorMessage := '';
  try
    Builder.AddNumber('duplicate');
  except
    on E: EMCPSchema do
      ErrorMessage := E.Message;
  end;
  Expect<string>(ErrorMessage)
    .ToBe('Schema property "duplicate" is already defined');
  Schema := Builder.Build;
  Expect<Integer>(TJSONObject(Schema.Find('properties')).Count).ToBe(1);
  Schema.Free;
end;

procedure TSchemaBuilder.SetupTests;
begin
  Test('object envelope with properties', TestObjectEnvelope);
  Test('string/number/integer/boolean property types', TestPropertyTypes);
  Test('descriptions present or omitted', TestDescriptions);
  Test('properties required by default', TestRequiredByDefault);
  Test('ARequired = False leaves a property optional', TestOptionalOptOut);
  Test('no required key when nothing is required',
    TestNoRequiredKeyWhenEmpty);
  Test('Build rejects builder reuse', TestBuildReuseRaises);
  Test('property add rejects builder reuse', TestAddAfterBuildRaises);
  Test('record copy sees consumed state', TestCopySeesConsumedState);
  Test('record copies share the schema-in-progress',
    TestCopySharesInProgressState);
  Test('default record rejects Build', TestDefaultRecordRaises);
  Test('duplicate property names rejected', TestDuplicatePropertyRaises);
end;

procedure TSchemaFromClass.TestTypeMapping;
var
  Schema: TJSONObject;
begin
  Schema := SchemaFrom(TProbeArgs).Build;
  Expect<string>(Schema.Get('type', '')).ToBe('object');
  Expect<string>(
    TJSONData(Schema.FindPath('properties.labelText.type')).AsString)
    .ToBe('string');
  Expect<string>(
    TJSONData(Schema.FindPath('properties.count.type')).AsString)
    .ToBe('integer');
  Expect<string>(
    TJSONData(Schema.FindPath('properties.ratio.type')).AsString)
    .ToBe('number');
  Expect<string>(
    TJSONData(Schema.FindPath('properties.flag.type')).AsString)
    .ToBe('boolean');
  Expect<string>(
    TJSONData(Schema.FindPath('properties.color.type')).AsString)
    .ToBe('string');
  Schema.Free;
end;

procedure TSchemaFromClass.TestEnumValues;
var
  Schema: TJSONObject;
  Values: TJSONArray;
begin
  Schema := SchemaFrom(TProbeArgs).Build;
  Values := TJSONArray(Schema.FindPath('properties.color.enum'));
  Expect<Integer>(Values.Count).ToBe(3);
  Expect<string>(Values[0].AsString).ToBe('pcRed');
  Expect<string>(Values[2].AsString).ToBe('pcBlue');
  Schema.Free;
end;

procedure TSchemaFromClass.TestAllRequiredDeclarationOrder;
var
  Schema: TJSONObject;
  Required: TJSONArray;
begin
  Schema := SchemaFrom(TProbeArgs).Build;
  Required := TJSONArray(Schema.Find('required'));
  Expect<Integer>(Required.Count).ToBe(5);
  Expect<string>(Required[0].AsString).ToBe('labelText');
  Expect<string>(Required[4].AsString).ToBe('color');
  Schema.Free;
end;

procedure TSchemaFromClass.TestUnmappableKindRaises;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    SchemaFrom(TUnmappableArgs);
  except
    on EMCPSchema do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TSchemaFromClass.TestDefaultsBecomeOptional;
var
  Schema: TJSONObject;
  Required: TJSONArray;
begin
  Schema := SchemaFrom(TOptionalArgs).Build;
  // Only `query` is required; the defaults and stored-False are not.
  Required := TJSONArray(Schema.Find('required'));
  Expect<Integer>(Required.Count).ToBe(1);
  Expect<string>(Required[0].AsString).ToBe('query');
  Expect<Integer>(
    TJSONData(Schema.FindPath('properties.retries.default')).AsInteger)
    .ToBe(3);
  Expect<Boolean>(
    TJSONData(Schema.FindPath('properties.verbose.default')).AsBoolean)
    .ToBe(False);
  Expect<string>(
    TJSONData(Schema.FindPath('properties.color.default')).AsString)
    .ToBe('pcGreen');
  Schema.Free;
end;

procedure TSchemaFromClass.TestStoredFalseBecomesOptional;
var
  Schema: TJSONObject;
begin
  Schema := SchemaFrom(TOptionalArgs).Build;
  // stored False → optional without a default key.
  Expect<Boolean>(
    Schema.FindPath('properties.nickname.default') = nil).ToBe(True);
  Expect<Boolean>(
    Schema.FindPath('properties.nickname.type') <> nil).ToBe(True);
  Schema.Free;
end;

procedure TSchemaFromClass.SetupTests;
begin
  Test('published properties map to schema types', TestTypeMapping);
  Test('enum properties carry their allowed values', TestEnumValues);
  Test('all properties required, declaration order',
    TestAllRequiredDeclarationOrder);
  Test('unmappable property kinds raise EMCPSchema',
    TestUnmappableKindRaises);
  Test('default directives become optional with schema default',
    TestDefaultsBecomeOptional);
  Test('stored False becomes optional', TestStoredFalseBecomesOptional);
  Test('MCPSerialize mirrors published properties',
    TestSerializeRoundTrip);
  Test('MCPSerialize preserves High(QWord)', TestSerializeQWord);
end;

procedure TSchemaFromClass.TestSerializeRoundTrip;
var
  Obj: TProbeArgs;
  Json: TJSONObject;
begin
  Obj := TProbeArgs.Create;
  Obj.labelText := 'probe';
  Obj.count := 5;
  Obj.ratio := 1.5;
  Obj.flag := True;
  Obj.color := pcBlue;
  Json := MCPSerialize(Obj);
  Expect<string>(Json.Get('labelText', '')).ToBe('probe');
  Expect<Integer>(Json.Get('count', 0)).ToBe(5);
  Expect<Boolean>(Json.Get('ratio', 0.0) = 1.5).ToBe(True);
  Expect<Boolean>(Json.Get('flag', False)).ToBe(True);
  // Enums serialize as their names, matching the derived schema.
  Expect<string>(Json.Get('color', '')).ToBe('pcBlue');
  Json.Free;
  Obj.Free;
end;

procedure TSchemaFromClass.TestSerializeQWord;
var
  Obj: TQWordArgs;
  Json: TJSONObject;
  Value: TJSONData;
begin
  Obj := TQWordArgs.Create;
  Obj.value := High(QWord);
  Json := MCPSerialize(Obj);
  Value := Json.Find('value');
  Expect<Integer>(Ord(TJSONNumber(Value).NumberType)).ToBe(Ord(ntQWord));
  Expect<QWord>(Value.AsQWord).ToBe(High(QWord));
  Json.Free;
  Obj.Free;
end;

procedure TWireNumber.TestJavaScriptForms;
var
  I: Integer;
begin
  for I := Low(WIRE_CASES) to High(WIRE_CASES) do
    Expect<string>(WireText(WIRE_CASES[I].Value)).ToBe(WIRE_CASES[I].Text);
end;

procedure TWireNumber.TestEveryFormParsesBack;
var
  I, Code: Integer;
  Back: Double;
begin
  for I := Low(WIRE_CASES) to High(WIRE_CASES) do
  begin
    Val(WireText(WIRE_CASES[I].Value), Back, Code);
    Expect<Integer>(Code).ToBe(0);
    Expect<Boolean>(Back = WIRE_CASES[I].Value).ToBe(True);
  end;
end;

procedure TWireNumber.TestNonFiniteRaises;
var
  Raised, I: Integer;
  Values: array[0..2] of Double;
begin
  Values[0] := NaN;
  Values[1] := Infinity;
  Values[2] := NegInfinity;
  Raised := 0;
  for I := Low(Values) to High(Values) do
    try
      MCPWireNumber(Values[I]).Free;
    except
      on EMCPSchema do
        Inc(Raised);
    end;
  Expect<Integer>(Raised).ToBe(3);
end;

procedure TWireNumber.TestSerializeNaNRaises;
var
  Obj: TProbeArgs;
  Raised: Boolean;
begin
  Obj := TProbeArgs.Create;
  try
    Obj.ratio := NaN;
    Raised := False;
    try
      MCPSerialize(Obj).Free;
    except
      on EMCPSchema do
        Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
  finally
    Obj.Free;
  end;
end;

procedure TWireNumber.SetupTests;
begin
  Test('numbers are written as JavaScript writes them',
    TestJavaScriptForms);
  Test('every written number parses back to the same Double',
    TestEveryFormParsesBack);
  Test('NaN and infinities raise EMCPSchema', TestNonFiniteRaises);
  Test('MCPSerialize raises on a NaN float property',
    TestSerializeNaNRaises);
end;

begin
  TestRunnerProgram.AddSuite(TSchemaBuilder.Create('Schema: fluent builder'));
  TestRunnerProgram.AddSuite(
    TSchemaFromClass.Create('Schema: derived from classes'));
  TestRunnerProgram.AddSuite(TWireNumber.Create('Schema: wire numbers'));
  TestRunnerProgram.Run;
end.
