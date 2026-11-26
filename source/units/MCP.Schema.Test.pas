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

  // #95: nested argument objects and arrays.
  TProbeLimits = class(TMCPArgs)
  private
    FLimit: Integer;
    FTags: TStringArray;
  published
    property limit: Integer read FLimit write FLimit;
    property tags: TStringArray read FTags write FTags;
  end;

  TProbeNumbers = array of Double;
  TProbeFlags = array of Boolean;
  TProbeCounts = array of Int64;

  TProbeNested = class(TMCPArgs)
  private
    FName: string;
    FOpts: TProbeLimits;
    FScores: TProbeNumbers;
    FFlags: TProbeFlags;
    FCounts: TProbeCounts;
    FExtra: TProbeLimits;
  published
    property name: string read FName write FName;
    property opts: TProbeLimits read FOpts write FOpts;
    property scores: TProbeNumbers read FScores write FScores;
    property flags: TProbeFlags read FFlags write FFlags;
    property counts: TProbeCounts read FCounts write FCounts;
    property extra: TProbeLimits read FExtra write FExtra stored False;
  end;

  TProbeBadArray = class(TMCPArgs)
  private
    FBytes: array of Byte;
  published
    property bytes: TBytes read FBytes write FBytes;
  end;

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
  TNestedSchemas = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestFluentEnumArrayObject;
    procedure TestWithDefault;
    procedure TestBuilderGuards;
    procedure TestSchemaFromNestedClass;
    procedure TestUnsupportedArrayElement;
    procedure TestBindNestedAndArrays;
    procedure TestBindErrorsNamePaths;
    procedure TestSerializeRoundTrip;
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

{ ───────── nested schemas and arrays (#95) ───────── }

function Built(ASchema: TMCPSchema): string;
var
  Schema: TJSONObject;
begin
  Schema := ASchema.Build;
  try
    Result := Schema.AsJSON;
  finally
    Schema.Free;
  end;
end;

procedure TNestedSchemas.TestFluentEnumArrayObject;
begin
  Expect<string>(Built(ObjectSchema
    .AddEnum('mode', ['fast', 'b' + #$C3#$BC + 'ndig'], 'How')
    .AddArray('tags', 'string')
    .AddArray('points', ObjectSchema.AddNumber('x').AddNumber('y'))
    .AddObject('opts', ObjectSchema.AddBoolean('dry', '', False), 'Options')))
    .ToBe('{ "type" : "object", "properties" : { "mode" : { "type" : "string", ' +
    '"enum" : ["fast", "b' + #$C3#$BC + 'ndig"], "description" : "How" }, ' +
    '"tags" : { "type" : "array", "items" : { "type" : "string" } }, ' +
    '"points" : { "type" : "array", "items" : { "type" : "object", ' +
    '"properties" : { "x" : { "type" : "number" }, "y" : { "type" : "number" } }, ' +
    '"required" : ["x", "y"] } }, "opts" : { "type" : "object", "properties" : ' +
    '{ "dry" : { "type" : "boolean" } }, "description" : "Options" } }, ' +
    '"required" : ["mode", "tags", "points", "opts"] }');
end;

procedure TNestedSchemas.TestWithDefault;
begin
  // A default makes the property optional.
  Expect<string>(Built(ObjectSchema.AddString('a').AddInteger('n').WithDefault(3)
    .AddNumber('r').WithDefault(0.5).AddBoolean('b').WithDefault(True)
    .AddString('s').WithDefault('x')))
    .ToBe('{ "type" : "object", "properties" : { "a" : { "type" : "string" }, ' +
    '"n" : { "type" : "integer", "default" : 3 }, "r" : { "type" : "number", ' +
    '"default" : 0.5 }, "b" : { "type" : "boolean", "default" : true }, ' +
    '"s" : { "type" : "string", "default" : "x" } }, "required" : ["a"] }');
end;

function SchemaRaises(ASchema: TMCPSchema): Boolean;
begin
  Result := False;
  try
    ASchema.Build.Free;
  except
    on E: EMCPSchema do
      Result := True;
  end;
end;

procedure TNestedSchemas.TestBuilderGuards;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    ObjectSchema.WithDefault('x').Build.Free;
  except
    on E: EMCPSchema do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  Raised := False;
  try
    ObjectSchema.AddArray('a', 'date').Build.Free;
  except
    on E: EMCPSchema do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  Raised := False;
  try
    ObjectSchema.AddEnum('e', []).Build.Free;
  except
    on E: EMCPSchema do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TNestedSchemas.TestSchemaFromNestedClass;
begin
  Expect<string>(Built(SchemaFrom(TProbeNested)))
    .ToBe('{ "type" : "object", "properties" : { "name" : { "type" : "string" }, ' +
    '"opts" : { "type" : "object", "properties" : { "limit" : { "type" : ' +
    '"integer" }, "tags" : { "type" : "array", "items" : { "type" : "string" } } }, ' +
    '"required" : ["limit", "tags"] }, "scores" : { "type" : "array", "items" : ' +
    '{ "type" : "number" } }, "flags" : { "type" : "array", "items" : { "type" : ' +
    '"boolean" } }, "counts" : { "type" : "array", "items" : { "type" : ' +
    '"integer" } }, "extra" : { "type" : "object", "properties" : { "limit" : ' +
    '{ "type" : "integer" }, "tags" : { "type" : "array", "items" : { "type" : ' +
    '"string" } } }, "required" : ["limit", "tags"] } }, "required" : ["name", ' +
    '"opts", "scores", "flags", "counts"] }');
end;

procedure TNestedSchemas.TestUnsupportedArrayElement;
var
  Message: string;
begin
  Message := '';
  try
    SchemaFrom(TProbeBadArray).Build.Free;
  except
    on E: EMCPSchema do
      Message := E.Message;
  end;
  Expect<Boolean>(Pos('Array property "bytes"', Message) = 1).ToBe(True);
end;

function BindJson(AClass: TMCPArgsClass; const AJson: string;
  out AInstance: TMCPArgs): string;
var
  Arguments: TJSONObject;
begin
  Arguments := TJSONObject(GetJSON(AJson));
  try
    if MCPBindArguments(AClass, Arguments, AInstance, Result) then
      Result := '';
  finally
    Arguments.Free;
  end;
end;

procedure TNestedSchemas.TestBindNestedAndArrays;
var
  Instance: TMCPArgs;
  Probe: TProbeNested;
begin
  Expect<string>(BindJson(TProbeNested, '{"name":"größ",' +
    '"opts":{"limit":7,"tags":["a","é"]},"scores":[0.5,2],' +
    '"flags":[true,false],"counts":[9007199254740993]}', Instance)).ToBe('');
  Probe := Instance as TProbeNested;
  try
    Expect<string>(Probe.name).ToBe('gr' + #$C3#$B6 + #$C3#$9F);
    Expect<Integer>(Probe.opts.limit).ToBe(7);
    Expect<string>(Probe.opts.tags[1]).ToBe(#$C3#$A9);
    Expect<Integer>(Length(Probe.scores)).ToBe(2);
    Expect<Boolean>(Probe.flags[1]).ToBe(False);
    Expect<Boolean>(Probe.counts[0] = 9007199254740993).ToBe(True);
    // Optional nested object, absent: nil.
    Expect<Boolean>(Probe.extra = nil).ToBe(True);
  finally
    Instance.Free;
  end;
end;

procedure TNestedSchemas.TestBindErrorsNamePaths;
var
  Instance: TMCPArgs;
const
  BASE = '"name":"n","scores":[],"flags":[],"counts":[]';
begin
  Expect<string>(BindJson(TProbeNested, '{' + BASE + ',"opts":{"tags":[]}}',
    Instance)).ToBe('Missing required argument "opts.limit"');
  Expect<string>(BindJson(TProbeNested, '{' + BASE +
    ',"opts":{"limit":"x","tags":[]}}', Instance))
    .ToBe('Argument "opts.limit" must be an integer');
  Expect<string>(BindJson(TProbeNested, '{' + BASE +
    ',"opts":{"limit":1,"tags":["a",2]}}', Instance))
    .ToBe('Argument "opts.tags[1]" must be a string');
  Expect<string>(BindJson(TProbeNested, '{' + BASE + ',"opts":[]}', Instance))
    .ToBe('Argument "opts" must be an object');
  Expect<string>(BindJson(TProbeNested, '{"name":"n","opts":{"limit":1,' +
    '"tags":[]},"scores":"x","flags":[],"counts":[]}', Instance))
    .ToBe('Argument "scores" must be an array');
  Expect<string>(BindJson(TProbeNested, '{"name":"n","opts":{"limit":1,' +
    '"tags":[]},"scores":[],"flags":[],"counts":[1.5]}', Instance))
    .ToBe('Argument "counts[0]" must be an integer');
  Expect<Boolean>(Instance = nil).ToBe(True);
end;

procedure TNestedSchemas.TestSerializeRoundTrip;
var
  Instance: TMCPArgs;
  Serialized: TJSONObject;
begin
  Expect<string>(BindJson(TProbeNested, '{"name":"n","opts":{"limit":7,' +
    '"tags":["a"]},"scores":[0.25],"flags":[true],"counts":[3]}', Instance))
    .ToBe('');
  Serialized := MCPSerialize(Instance);
  try
    Expect<string>(Serialized.AsJSON).ToBe('{ "name" : "n", "opts" : ' +
      '{ "limit" : 7, "tags" : ["a"] }, "scores" : [0.25], "flags" : [true], ' +
      '"counts" : [3] }');
  finally
    Serialized.Free;
    Instance.Free;
  end;
end;

procedure TNestedSchemas.SetupTests;
begin
  Test('fluent enum, arrays and nested object, byte-exact',
    TestFluentEnumArrayObject);
  Test('WithDefault for each type makes the property optional',
    TestWithDefault);
  Test('builder guards: default first, unknown item type, empty enum',
    TestBuilderGuards);
  Test('SchemaFrom maps nested classes and arrays', TestSchemaFromNestedClass);
  Test('an unsupported array element type is refused',
    TestUnsupportedArrayElement);
  Test('binding fills nested objects and arrays, UTF-8 byte-exact',
    TestBindNestedAndArrays);
  Test('binding errors name the nested path', TestBindErrorsNamePaths);
  Test('MCPSerialize writes nested objects and arrays',
    TestSerializeRoundTrip);
end;

begin
  TestRunnerProgram.AddSuite(TSchemaBuilder.Create('Schema: fluent builder'));
  TestRunnerProgram.AddSuite(
    TSchemaFromClass.Create('Schema: derived from classes'));
  TestRunnerProgram.AddSuite(TWireNumber.Create('Schema: wire numbers'));
  TestRunnerProgram.AddSuite(
    TNestedSchemas.Create('Schema: nested objects and arrays'));
  TestRunnerProgram.Run;
end.
