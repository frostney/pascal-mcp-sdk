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
  jsonparser,
  // UTF-8 string conversion (cwstring), as every program using the
  // library gets it through MCP.Server.
  MCP.JSONRPC,
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
  // #91: the enforced subset, recursive, and value validation against
  // it. Messages asserted byte-exact, non-ASCII names included.
  TSubsetSchemas = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestAcceptedSchemas;
    procedure TestRejectedKeywords;
    procedure TestObjectRootRequired;
    procedure TestTypes;
    procedure TestNestedPathsInMessages;
    procedure TestArrayItems;
    procedure TestEnumsOfAnyPrimitive;
    procedure TestDefaultsSeededOnlyWhenAsked;
    procedure TestRootValueMessages;
    procedure TestIntegralFloats;
    procedure TestExactNumericEnums;
    procedure TestDeclaredDialect;
    procedure TestBuiltValues;
    procedure TestKeywordShapes;
    procedure TestOnlyConformingDefaultsSeeded;
  end;

  TWireNumber = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestJavaScriptForms;
    procedure TestNonFiniteRaises;
    procedure TestSerializeNaNRaises;
    procedure TestSerializedFloatStaysFloat;
    procedure TestAssignedFloatNodeStaysValid;
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
// JavaScript's thresholds (1e-7 and 1e21); subnormal, smallest normal,
// largest finite, negative zero, and the 2^53 integer-node bound;
// a value whose shortest decimal an Extended-based parse misreads
// (3.9174595656667484e+280); a last-digit tie that goes to the even
// digit (708094031835588.25); a power of two whose lower gap is
// narrower (2^-1017). Expected texts are what JSON.stringify writes
// for the same Double. Each value is given by its bits: a decimal
// literal would go through the compiler's own Extended-based parse,
// the double rounding this checks for.
const
  WIRE_CASES: array[0..23] of record
    Bits: QWord; // the Double, bit for bit
    Text: string;
  end = (
    (Bits: QWord($3FD0000000000000); Text: '0.25'), // 0.25
    (Bits: QWord($3FB999999999999A); Text: '0.1'), // 0.1
    (Bits: QWord($BFE0000000000000); Text: '-0.5'), // -0.5
    (Bits: QWord($405EDD2F1A9FBE77); Text: '123.456'), // 123.456
    (Bits: QWord($3FD5555555555555); Text: '0.3333333333333333'), // 1/3
    (Bits: QWord($3FF0000000000001); Text: '1.0000000000000002'), // 1.0000000000000002
    (Bits: QWord($3FD3333333333334); Text: '0.30000000000000004'), // 0.30000000000000004
    (Bits: QWord($0000000000000001); Text: '5e-324'), // 5e-324, smallest subnormal
    (Bits: QWord($7FEFFFFFFFFFFFFF); Text: '1.7976931348623157e+308'), // largest finite
    (Bits: QWord($3E7AD7F29ABCAF48); Text: '1e-7'), // 1e-7
    (Bits: QWord($3EB0C6F7A0B5ED8D); Text: '0.000001'), // 0.000001
    (Bits: QWord($3DF12E0BE826D695); Text: '2.5e-10'), // 2.5e-10
    (Bits: QWord($430C6BF526340000); Text: '1000000000000000'), // 1e15
    (Bits: QWord($4340000000000000); Text: '9007199254740992'), // 2^53
    (Bits: QWord($441AC53A7E04BCDA); Text: '123456789012345680000'), // 1.2345678901234568e20
    (Bits: QWord($444B1AE4D6E2EF50); Text: '1e+21'), // 1e21
    (Bits: QWord($4059000000000000); Text: '100'), // 100
    (Bits: QWord($8000000000000000); Text: '0'), // -0
    (Bits: QWord($0010000000000000); Text: '2.2250738585072014e-308'), // smallest normal
    (Bits: QWord($00005C0AB9347ED7); Text: '5e-310'), // 5e-310, subnormal
    (Bits: QWord($0060000000000000); Text: '7.120236347223045e-307'), // 2^-1017, narrower gap below
    (Bits: QWord($4304200FE9E18E22); Text: '708094031835588.2'), // last-digit tie goes to even
    (Bits: QWord($7A3143DC27F61CA2); Text: '3.9174595656667484e+280'), // an Extended-based parse misreads it
    (Bits: QWord($44B52D02C7E14AF6); Text: '1e+23') // 1e23
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
  Value: Double;
begin
  for I := Low(WIRE_CASES) to High(WIRE_CASES) do
  begin
    Move(WIRE_CASES[I].Bits, Value, SizeOf(Value));
    Expect<string>(WireText(Value)).ToBe(WIRE_CASES[I].Text);
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

procedure TWireNumber.TestSerializedFloatStaysFloat;
var
  Obj: TProbeArgs;
  Json: TJSONObject;
begin
  Obj := TProbeArgs.Create;
  try
    Obj.ratio := 1.0;
    Json := MCPSerialize(Obj);
    try
      // Integral text on the wire, still a float node underneath: a
      // fraction assigned later is kept.
      Expect<string>(Json.Find('ratio').AsJSON).ToBe('1');
      Json.Find('ratio').AsFloat := 1.5;
      Expect<string>(Json.Find('ratio').AsJSON).ToBe('1.5');
    finally
      Json.Free;
    end;
  finally
    Obj.Free;
  end;
end;

procedure TWireNumber.TestAssignedFloatNodeStaysValid;
var
  Node: TJSONData;
  Raised: Boolean;
begin
  Node := MCPWireNumber(0.25);
  try
    Node.AsFloat := 0;
    Expect<string>(Node.AsJSON).ToBe('0');
    Node.AsFloat := NaN;
    Raised := False;
    try
      Node.AsJSON;
    except
      on EMCPSchema do
        Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
  finally
    Node.Free;
  end;
end;

procedure TWireNumber.SetupTests;
begin
  Test('numbers are written as JavaScript writes them',
    TestJavaScriptForms);
  Test('NaN and infinities raise EMCPSchema', TestNonFiniteRaises);
  Test('MCPSerialize raises on a NaN float property',
    TestSerializeNaNRaises);
  Test('a serialized integral float stays a float node',
    TestSerializedFloatStaysFloat);
  Test('a wire float assigned zero or NaN writes 0 or raises',
    TestAssignedFloatNodeStaysValid);
end;

{ ───────── the enforced subset (#91) ───────── }

function ObjectOf(const AJson: string): TJSONObject;
begin
  Result := TJSONObject(GetJSON(AJson));
end;

function Violation(const ASchema: string; AObjectRoot: Boolean = False): string;
var
  Schema: TJSONObject;
begin
  Schema := ObjectOf(ASchema);
  try
    Result := MCPSchemaSubsetViolation(Schema, AObjectRoot);
  finally
    Schema.Free;
  end;
end;

// '' when AValue conforms to ASchema, else the error.
function Check(const ASchema, AValue: string; const AKind: string = 'argument';
  ASeed: Boolean = False): string;
var
  Schema: TJSONObject;
  Value: TJSONData;
begin
  Schema := ObjectOf(ASchema);
  Value := GetJSON(AValue);
  try
    if MCPValidateAgainstSchema(Schema, Value, AKind, ASeed, Result) then
      Result := '';
  finally
    Value.Free;
    Schema.Free;
  end;
end;

procedure TSubsetSchemas.TestAcceptedSchemas;
begin
  Expect<string>(Violation('{"$schema":"https://json-schema.org/draft/2020-12/schema",' +
    '"type":"object","title":"t","description":"d","properties":{' +
    '"a":{"type":"array","items":{"type":"object","properties":{' +
    '"b":{"type":"integer","enum":[1,2],"default":1}},"required":["b"]}},' +
    '"n":{"type":"null"}},"required":["a"]}')).ToBe('');
  Expect<string>(Violation('{"type":"array","items":{"type":"string"}}')).ToBe('');
  Expect<string>(Violation('{"type":"boolean"}')).ToBe('');
end;

procedure TSubsetSchemas.TestRejectedKeywords;
begin
  Expect<string>(Violation('{"type":"object","properties":{"a":{"type":"string",' +
    '"format":"uri"}}}')).ToBe('property "a" uses unsupported keyword "format"');
  Expect<string>(Violation('{"type":"object","properties":{"x":{"type":"array",' +
    '"items":{"type":"object","properties":{"y":{"$ref":"#"}}}}}}'))
    .ToBe('property "x[].y" needs a single "type"');
  Expect<string>(Violation('{"type":["string","null"]}')).ToBe('needs a single "type"');
  Expect<string>(Violation('{"type":"date"}')).ToBe('has unsupported type "date"');
  Expect<string>(Violation('{"type":"object","properties":{"a":{"type":"string"}},' +
    '"additionalProperties":false}')).ToBe('uses unsupported keyword "additionalProperties"');
  // Keywords belong to their type: items on a string, enum on an object.
  Expect<string>(Violation('{"type":"string","items":{"type":"string"}}'))
    .ToBe('uses unsupported keyword "items"');
  Expect<string>(Violation('{"type":"object","enum":[1]}'))
    .ToBe('uses unsupported keyword "enum"');
  Expect<string>(Violation('{"type":"object","properties":{"a":{"type":"string",' +
    '"default":{}}}}')).ToBe('property "a" default must be a primitive');
  Expect<string>(Violation('{"type":"object","properties":{"z":{"type":"string",' +
    '"$schema":"x"}}}')).ToBe('property "z" uses unsupported keyword "$schema"');
end;

procedure TSubsetSchemas.TestObjectRootRequired;
begin
  Expect<string>(Violation('{"type":"array","items":{"type":"string"}}', True))
    .ToBe('must have root type "object"');
  Expect<string>(Violation('{"type":"object"}', True)).ToBe('');
end;

procedure TSubsetSchemas.TestTypes;
begin
  Expect<string>(Check('{"type":"integer"}', '2')).ToBe('');
  Expect<string>(Check('{"type":"integer"}', '2.5')).ToBe('Argument must be an integer');
  Expect<string>(Check('{"type":"number"}', '2')).ToBe('');
  Expect<string>(Check('{"type":"string"}', '2')).ToBe('Argument must be a string');
  Expect<string>(Check('{"type":"boolean"}', 'null')).ToBe('Argument must be a boolean');
  Expect<string>(Check('{"type":"null"}', 'null')).ToBe('');
  Expect<string>(Check('{"type":"object"}', '[]')).ToBe('Argument must be an object');
  Expect<string>(Check('{"type":"array"}', '{}')).ToBe('Argument must be an array');
end;

procedure TSubsetSchemas.TestNestedPathsInMessages;
const
  NAME = 'gr' + #$C3#$B6 + #$C3#$9F + 'e';
begin
  Expect<string>(Check('{"type":"object","properties":{"' + NAME +
    '":{"type":"object","properties":{"w":{"type":"number"}},"required":["w"]}}}',
    '{"' + NAME + '":{}}')).ToBe('Missing required argument "' + NAME + '.w"');
  Expect<string>(Check('{"type":"object","properties":{"' + NAME +
    '":{"type":"object","properties":{"w":{"type":"number"}}}}}',
    '{"' + NAME + '":{"w":"x"}}', 'structured output'))
    .ToBe('Structured output "' + NAME + '.w" must be a number');
end;

procedure TSubsetSchemas.TestArrayItems;
begin
  Expect<string>(Check('{"type":"array","items":{"type":"object",' +
    '"properties":{"id":{"type":"string"}},"required":["id"]}}',
    '[{"id":"1"},{"id":2}]', 'structured output'))
    .ToBe('Structured output "[1].id" must be a string');
  Expect<string>(Check('{"type":"array","items":{"type":"integer"}}', '[1,2,3]'))
    .ToBe('');
end;

procedure TSubsetSchemas.TestEnumsOfAnyPrimitive;
begin
  Expect<string>(Check('{"type":"string","enum":["a","b"]}', '"c"'))
    .ToBe('Argument must be a string from the declared enum values');
  Expect<string>(Check('{"type":"integer","enum":[1,3]}', '3')).ToBe('');
  Expect<string>(Check('{"type":"integer","enum":[1,3]}', '2'))
    .ToBe('Argument must be an integer from the declared enum values');
  Expect<string>(Check('{"type":"boolean","enum":[true]}', 'false'))
    .ToBe('Argument must be a boolean from the declared enum values');
end;

procedure TSubsetSchemas.TestDefaultsSeededOnlyWhenAsked;
var
  Schema, Value: TJSONObject;
  Error: string;
begin
  Schema := ObjectOf('{"type":"object","properties":{"o":{"type":"object",' +
    '"properties":{"n":{"type":"integer","default":7}}}}}');
  Value := ObjectOf('{"o":{}}');
  try
    Expect<Boolean>(MCPValidateAgainstSchema(Schema, Value, 'argument', False,
      Error)).ToBe(True);
    Expect<Boolean>(Value.FindPath('o.n') = nil).ToBe(True);
    Expect<Boolean>(MCPValidateAgainstSchema(Schema, Value, 'argument', True,
      Error)).ToBe(True);
    Expect<Integer>(TJSONData(Value.FindPath('o.n')).AsInteger).ToBe(7);
  finally
    Value.Free;
    Schema.Free;
  end;
end;

procedure TSubsetSchemas.TestRootValueMessages;
begin
  Expect<string>(Check('{"type":"array"}', '"x"', 'structured output'))
    .ToBe('Structured output must be an array');
  Expect<string>(Check('{"type":"object","required":["a"]}', '{}',
    'structured output')).ToBe('Missing required structured output "a"');
end;

// JSON Schema 2020-12 validation §6.1.1 (verified 2026-11-27,
// https://json-schema.org/draft/2020-12/json-schema-validation#name-type):
// an integer is any number with a zero fractional part.
procedure TSubsetSchemas.TestIntegralFloats;
begin
  Expect<string>(Check('{"type":"integer"}', '2.0')).ToBe('');
  Expect<string>(Check('{"type":"integer"}', '2e0')).ToBe('');
  Expect<string>(Check('{"type":"integer"}', '-0.0')).ToBe('');
  Expect<string>(Check('{"type":"integer"}', '2.000001'))
    .ToBe('Argument must be an integer');
  // Past 2^53 a float cannot be known to be integral.
  Expect<string>(Check('{"type":"integer"}', '1e300'))
    .ToBe('Argument must be an integer');
end;

procedure TSubsetSchemas.TestExactNumericEnums;
begin
  // 2^53 and 2^53 + 1 are the same double but different integers.
  Expect<Boolean>(Check('{"type":"integer","enum":[9007199254740992]}',
    '9007199254740993') <> '').ToBe(True);
  Expect<string>(Check('{"type":"integer","enum":[9007199254740993]}',
    '9007199254740993')).ToBe('');
  Expect<Boolean>(Check('{"type":"integer","enum":[18446744073709551615]}',
    '-1') <> '').ToBe(True);
  Expect<string>(Check('{"type":"integer","enum":[18446744073709551615]}',
    '18446744073709551615')).ToBe('');
  // An integral float equals the integer it spells.
  Expect<string>(Check('{"type":"number","enum":[1]}', '1.0')).ToBe('');
  Expect<string>(Check('{"type":"number","enum":[1.5]}', '1.5')).ToBe('');
  Expect<Boolean>(Check('{"type":"number","enum":[1]}', '1.5') <> '')
    .ToBe(True);
end;

// A schema declaring another dialect is not enforced by 2020-12 rules
// (verified 2026-11-27 against
// https://modelcontextprotocol.io/specification/2026-07-28/basic#json-schema-usage).
procedure TSubsetSchemas.TestDeclaredDialect;
begin
  Expect<string>(Violation(
    '{"$schema":"https://json-schema.org/draft/2020-12/schema#","type":"string"}'))
    .ToBe('');
  Expect<string>(Violation(
    '{"$schema":"http://json-schema.org/draft-07/schema#","type":"string"}'))
    .ToBe('declares $schema other than JSON Schema 2020-12');
  Expect<string>(Violation('{"$schema":7,"type":"string"}'))
    .ToBe('declares $schema other than JSON Schema 2020-12');
end;

// '' when the built AValue (consumed) conforms to ASchema, else the
// error. Built values reach shapes parsing never produces: QWord nodes
// for small values, nil members and items, non-finite floats.
function CheckBuilt(const ASchema: string; AValue: TJSONData): string;
var
  Schema: TJSONObject;
begin
  Schema := ObjectOf(ASchema);
  try
    if MCPValidateAgainstSchema(Schema, AValue, 'structured output', False,
      Result) then
      Result := '';
  finally
    AValue.Free;
    Schema.Free;
  end;
end;

function WithNilMember(const AName: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add(AName, TJSONData(nil));
end;

function NilItemArray: TJSONArray;
begin
  Result := TJSONArray.Create;
  Result.Add(TJSONData(nil));
end;

procedure TSubsetSchemas.TestBuiltValues;
begin
  // A small value in a QWord node equals the integral float 2.0.
  Expect<string>(CheckBuilt('{"type":"integer","enum":[2.0]}',
    TJSONQWordNumber.Create(2))).ToBe('');
  Expect<Boolean>(CheckBuilt('{"type":"integer","enum":[3.0]}',
    TJSONQWordNumber.Create(2)) <> '').ToBe(True);
  // A nil member is a present null, not an absent one.
  Expect<string>(CheckBuilt('{"type":"object","properties":{"a":{"type":' +
    '"null"}},"required":["a"]}', WithNilMember('a'))).ToBe('');
  Expect<string>(CheckBuilt('{"type":"object","properties":{"a":{"type":' +
    '"string"}}}', WithNilMember('a')))
    .ToBe('Structured output "a" must be a string');
  // A nil item is null: checked, not dereferenced.
  Expect<string>(CheckBuilt('{"type":"array","items":{"type":"null"}}',
    NilItemArray)).ToBe('');
  Expect<string>(CheckBuilt('{"type":"array","items":{"type":"string"}}',
    NilItemArray)).ToBe('Structured output "[0]" must be a string');
  // NaN and infinities have no JSON form.
  Expect<string>(CheckBuilt('{"type":"number"}',
    TJSONFloatNumber.Create(NaN))).ToBe('Structured output must be a number');
  Expect<string>(CheckBuilt('{"type":"number"}',
    TJSONFloatNumber.Create(Infinity))).ToBe('Structured output must be a number');
end;

procedure TSubsetSchemas.TestKeywordShapes;
begin
  Expect<string>(Violation('{"type":"object","required":[7]}'))
    .ToBe('required must list property names');
  Expect<string>(Violation('{"type":"string","title":7}'))
    .ToBe('title must be a string');
  Expect<string>(Violation('{"type":"object","properties":{"a":{"type":' +
    '"string","description":true}}}'))
    .ToBe('property "a" description must be a string');
end;

// A default that breaks its own schema is not seeded: omitting the
// property stays valid, and the handler never sees the bad value.
procedure TSubsetSchemas.TestOnlyConformingDefaultsSeeded;
var
  Schema, Value: TJSONObject;
  Error: string;
begin
  Schema := ObjectOf('{"type":"object","properties":{' +
    '"a":{"type":"string","default":null},' +
    '"b":{"type":"string","enum":["x"],"default":"y"},' +
    '"c":{"type":"string","default":"ok"}}}');
  Value := ObjectOf('{}');
  try
    Expect<Boolean>(MCPValidateAgainstSchema(Schema, Value, 'argument', True,
      Error)).ToBe(True);
    Expect<string>(Value.AsJSON).ToBe('{ "c" : "ok" }');
  finally
    Value.Free;
    Schema.Free;
  end;
end;

procedure TSubsetSchemas.SetupTests;
begin
  Test('nested objects, arrays, enums, defaults and null accepted',
    TestAcceptedSchemas);
  Test('keywords outside the subset named with their path',
    TestRejectedKeywords);
  Test('input schemas need an object root', TestObjectRootRequired);
  Test('each type checked; integer means an integral number', TestTypes);
  Test('nested paths in messages, non-ASCII byte-exact',
    TestNestedPathsInMessages);
  Test('array items checked with their index', TestArrayItems);
  Test('enums of strings, integers and booleans', TestEnumsOfAnyPrimitive);
  Test('defaults seeded into nested objects only when asked',
    TestDefaultsSeededOnlyWhenAsked);
  Test('root-level messages for output values', TestRootValueMessages);
  Test('integral floats are integers; fractions and huge floats are not',
    TestIntegralFloats);
  Test('numeric enums compare exactly, integers without rounding',
    TestExactNumericEnums);
  Test('only a 2020-12 $schema is inside the subset', TestDeclaredDialect);
  Test('built values: small QWords, nil members and items, non-finite',
    TestBuiltValues);
  Test('required names, title and description need their shapes',
    TestKeywordShapes);
  Test('only defaults that conform are seeded',
    TestOnlyConformingDefaultsSeeded);
end;

begin
  TestRunnerProgram.AddSuite(TSchemaBuilder.Create('Schema: fluent builder'));
  TestRunnerProgram.AddSuite(
    TSchemaFromClass.Create('Schema: derived from classes'));
  TestRunnerProgram.AddSuite(TWireNumber.Create('Schema: wire numbers'));
  TestRunnerProgram.AddSuite(TSubsetSchemas.Create('Schema: enforced subset'));
  TestRunnerProgram.Run;
end.
