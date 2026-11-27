unit MCP.Schema;

// Tool schemas expressed as Pascal instead of hand-written JSON
// strings — a JSON Schema 2020-12 subset (type, properties, required,
// items, enum, default, description) via two paths:
//
// 1. The fluent builder, when you want descriptions or optionals:
//
//      Server.RegisterTool('add', 'Add two numbers',
//        ObjectSchema.AddNumber('a', 'First addend')
//                    .AddNumber('b', 'Second addend'),
//        AddHandler);
//
// 2. An argument class, which expands into the schema automatically —
//    and doubles as the typed-argument carrier for TMCPServer's typed
//    registration overloads (the handler receives a populated,
//    validated instance instead of raw JSON):
//
//      type
//        TAddArgs = class(TMCPArgs)
//        private
//          FA, FB: Double;
//        published
//          property a: Double read FA write FA;
//          property b: Double read FB write FB;
//        end;
//
//      Server.RegisterTool('add', 'Add two numbers', TAddArgs, AddHandler);
//
//    SchemaFrom(TAddArgs) derives {"type":"object", properties:
//    {a,b: number}, required:[a,b]} from the published properties:
//    string kinds → "string", floats → "number", integer kinds →
//    "integer", Boolean → "boolean", enums → "string" with the enum
//    names as allowed values, field-backed dynamic arrays → "array",
//    TMCPArgs properties → nested objects (#95). Published properties
//    are required unless a directive says otherwise (see SchemaFrom).
//
//    Classes, not records: FPC 3.2.2 record RTTI enumerates every
//    field's offset and type (verified empirically) but carries NO
//    field names — and the rtti unit has no TRttiField at all, with
//    {$RTTI EXPLICIT} accepted only as a Delphi-compatibility no-op.
//    A names-supplied-by-caller record API would be positional and
//    corrupt memory on silent field reorders, so published class
//    properties — the one name-carrying reflection surface 3.2.2
//    guarantees, the same one fpjsonrtti builds on — are the
//    deliberate choice. Revisit for plain records when the toolchain
//    adopts FPC's extended RTTI (trunk: TRttiField for records). For
//    per-property descriptions use the fluent builder; RTTI carries
//    no place to put them.
//
// Only constant `stored` directives are supported for optionality.
// Field- and method-based `stored` expressions are unsupported because
// schema generation evaluates a fresh instance while argument binding
// evaluates the partially populated request instance.
//
// Properties are required by default (pass ARequired = False for
// optional ones). Build finalizes and transfers ownership of the
// finished TJSONObject; TMCPServer's registration overloads call it
// for you. The JSON-string and definition-object registration paths
// remain the escape hatch for anything richer ($ref, nested objects,
// title/annotations).

{$I MCP.inc}

interface

uses
  SysUtils,
  typinfo,

  fpjson;

type
  EMCPSchema = class(Exception);

  // A tool parameter mirrored into an HTTP header by x-mcp-header (#90):
  // the header is Mcp-Param-<Header>, and Path is the chain of property
  // names from the inputSchema root to the parameter.
  TMCPHeaderParameter = record
    Header: string;
    Path: array of string;
    ParamType: string; // 'string', 'integer' or 'boolean'
  end;
  TMCPHeaderParameters = array of TMCPHeaderParameter;

  // Base class for argument types. Published-property RTTI for every
  // descendant comes from MCP.inc's global {$M+} (no per-unit
  // override). Constructor kept virtual so the server can instantiate
  // argument objects from a class reference.
  TMCPArgs = class(TObject)
  public
    constructor Create; virtual;
    // Frees the nested TMCPArgs objects its published properties hold
    // (#95); do not free those yourself.
    destructor Destroy; override;
  end;

  TMCPArgsClass = class of TMCPArgs;

  // Heap-allocated builder state shared by every record copy of
  // TMCPSchema (issue #29): FPC 3.2.2 records have no copy hook, so
  // per-record fields cannot make `B := A; A.Build` visible through B.
  // The schema-in-progress and its consumed flag live here instead;
  // the record holds the core through a ref-counted interface field,
  // so copies alias the same core, Build-reuse raises through every
  // alias, and a never-built schema is freed with the last copy
  // instead of leaking.
  TMCPSchemaCore = class(TInterfacedObject)
  private
    FRoot: TJSONObject;
    FProperties: TJSONObject; // borrowed: owned by FRoot
    FRequired: TJSONArray;    // owned here until Build attaches it
    FLast: TJSONObject;       // borrowed: the property added last
    FLastName: string;
  public
    destructor Destroy; override;
  end;

  // Record copies share the same schema-in-progress: chaining and
  // reassigning mutate one underlying builder. Build is called exactly
  // once per schema (the registration overloads own that call) and is
  // detected through any copy afterwards.
  TMCPSchema = record
  private
    FLifetime: IInterface; // ref-counts FCore across record copies
    FCore: TMCPSchemaCore; // typed view of the same object
    function ActiveCore: TMCPSchemaCore;
    function AddProperty(const AName, AJsonType, ADescription: string;
      ARequired: Boolean): TMCPSchema;
    // Adds AProperty (ownership transfers) under AName.
    function AddPropertySchema(const AName: string; AProperty: TJSONObject;
      const ADescription: string; ARequired: Boolean): TMCPSchema;
    function SetDefault(AValue: TJSONData): TMCPSchema;
  public
    function AddString(const AName: string; const ADescription: string = '';
      ARequired: Boolean = True): TMCPSchema;
    function AddNumber(const AName: string; const ADescription: string = '';
      ARequired: Boolean = True): TMCPSchema;
    function AddInteger(const AName: string; const ADescription: string = '';
      ARequired: Boolean = True): TMCPSchema;
    function AddBoolean(const AName: string; const ADescription: string = '';
      ARequired: Boolean = True): TMCPSchema;
    // A string limited to AValues (#95).
    function AddEnum(const AName: string; const AValues: array of string;
      const ADescription: string = ''; ARequired: Boolean = True): TMCPSchema;
    // An array of AItemType ('string', 'number', 'integer' or 'boolean').
    function AddArray(const AName, AItemType: string;
      const ADescription: string = ''; ARequired: Boolean = True): TMCPSchema; overload;
    // An array of objects shaped by AItems (built and consumed here).
    function AddArray(const AName: string; constref AItems: TMCPSchema;
      const ADescription: string = ''; ARequired: Boolean = True): TMCPSchema; overload;
    // A nested object shaped by ASchema (built and consumed here).
    function AddObject(const AName: string; constref ASchema: TMCPSchema;
      const ADescription: string = ''; ARequired: Boolean = True): TMCPSchema;
    // A default for the property added last, which then becomes
    // optional: the server seeds the default into arguments that omit it.
    function WithDefault(const AValue: string): TMCPSchema; overload;
    function WithDefault(AValue: Int64): TMCPSchema; overload;
    function WithDefault(AValue: Double): TMCPSchema; overload;
    function WithDefault(AValue: Boolean): TMCPSchema; overload;

    // Finalizes the schema (attaches "required" when non-empty) and
    // transfers ownership. The record must not be used afterwards.
    function Build: TJSONObject;
  end;

// A fresh {"type":"object","properties":{}} schema to chain onto.
function ObjectSchema: TMCPSchema;

// Derive a schema from AClass's published properties (see the unit
// header for the type mapping). Raises EMCPSchema for property kinds
// with no JSON Schema mapping (sets, records, classes that are not
// TMCPArgs, arrays of other element types or behind methods, ...).
//
// Optionality comes from standard property directives:
//   property retries: Integer ... default 3;   → optional, "default": 3
//   property note: string ... stored False;    → optional, no default
// Ordinal kinds (integer, boolean, enum) can carry `default`; any
// property can opt out via `stored False`. Everything else is
// required.
function SchemaFrom(AClass: TMCPArgsClass): TMCPSchema;

// The optionality predicates SchemaFrom and the server's argument
// binder share. AInstance is any instance of the declaring class
// (needed to evaluate `stored` expressions).
function MCPPropHasDefault(AProp: PPropInfo): Boolean;
function MCPPropIsOptional(AInstance: TObject; AProp: PPropInfo): Boolean;

// The reverse of argument binding: serialize an instance's published
// properties to a JSON object (enums as their names). The typed
// structured-output path — MCPStructuredResult(text, instance) —
// pairs this with SchemaFrom(outputClass).
function MCPSerialize(AObj: TMCPArgs): TJSONObject;

// Instantiate AClass and fill its published properties from
// AArguments, nested argument objects and arrays included (#95).
// Missing required or mistyped arguments give False with AError set,
// naming the nested path ('Argument "opts.limit" must be an integer');
// the caller turns that into an in-band isError result. AArguments is
// borrowed; AInstance belongs to the caller on success.
function MCPBindArguments(AClass: TMCPArgsClass; AArguments: TJSONObject;
  out AInstance: TMCPArgs; out AError: string): Boolean;

// Compact JSON number node for wire output. fpjson's default float
// serialization is full-precision exponent form
// ('2.5000000000000000E-001'); the official SDKs put plain decimals
// on the wire. A value is written as the shortest decimal that parses
// back to the same Double, in the form JavaScript's Number#toString
// (and so JSON.stringify) gives it: 0.25, 1000000000000000, 1e+21,
// 5e-324. Integers of magnitude below 2^53 become integer nodes;
// negative zero is 0. NaN and infinities have no JSON form and raise
// EMCPSchema. The caller owns the returned node (add it to a JSON
// object or array, which then frees it). Used by MCPSerialize's float
// properties and the server's progress notifications.
function MCPWireNumber(AValue: Double): TJSONData;

// ── The enforced schema subset (ADR-0004; #23, #91) ──
//
// The server validates arguments and structured output itself only for
// schemas inside this JSON Schema 2020-12 subset; anything else is the
// handler's job (.ApplicationValidated for input; an output schema
// outside it is not checked). integer accepts integral floats within
// +-2^53; number excludes NaN and the infinities. Every schema node carries a
// "type" of object, array, string, number, integer, boolean or null,
// and may use:
//   object      properties (each a node), required (names)
//   array       items (a node)
//   primitives  enum (entries of another type never match), default
//               (a primitive)
//   any node    description, title; $schema at the root, naming
//               2020-12 (the default dialect; a schema declaring
//               another is outside the subset)
//   input only  x-mcp-header on a property (checked by
//               MCPHeaderParameters)
// Nesting is unlimited. Verified 2026-11-26 against the structured
// content and output schema rules of
// https://modelcontextprotocol.io/specification/2026-07-28/server/tools
// and (dialects) 2026-11-27 against
// https://modelcontextprotocol.io/specification/2026-07-28/basic#json-schema-usage

// '' when ASchema is inside the subset, otherwise the first violation
// ('uses unsupported keyword "format"', 'property "a.b" has
// unsupported type "x"', ...). AObjectRoot marks an input schema: it
// requires the root type object and admits x-mcp-header annotations,
// which an output schema cannot carry. ASchema is borrowed.
function MCPSchemaSubsetViolation(ASchema: TJSONObject;
  AObjectRoot: Boolean): string;

// Checks AValue against a subset schema: types (integer means an
// integral JSON number), required members, enum membership, nested
// properties and array items. Members a schema does not name are
// ignored. With ASeedDefaults, an absent optional property that
// declares a default is added to its object, so a handler sees the
// same view a typed handler gets. AKind names the value in errors:
// 'argument' gives 'Missing required argument "a.b"' and
// 'Argument "a.b" must be a string'. False with AError on the first
// violation. ASchema must be inside the subset (MCPSchemaSubsetViolation
// returned ''); both are borrowed, and AValue changes only by seeding.
function MCPValidateAgainstSchema(ASchema: TJSONObject; AValue: TJSONData;
  const AKind: string; ASeedDefaults: Boolean; out AError: string): Boolean;

// The x-mcp-header annotations of a tool's inputSchema (#90), checked
// against the constraints the specification puts on them: a non-empty
// RFC 9110 token, case-insensitively unique, only on a string, integer
// or boolean property, and only on properties reachable from the root
// through "properties" keys alone (not through items, composition,
// conditionals, $ref or $defs). Returns '' with the annotations in
// AParameters, or the first violation. Verified 2026-11-26 against
// https://modelcontextprotocol.io/specification/2026-07-28/server/tools#x-mcp-header
// ASchema is borrowed.
function MCPHeaderParameters(ASchema: TJSONObject;
  out AParameters: TMCPHeaderParameters): string;

// An independent copy of AParameters, their paths included (dynamic
// arrays are shared by assignment), for lookups that hand cached
// parameters out.
function CopyHeaderParameters(
  const AParameters: TMCPHeaderParameters): TMCPHeaderParameters;

// A JSON integer as Int64: an integral float (2.0, 2e0) within 2^53
// counts, as JSON Schema's integer does; False otherwise.
function ReadSignedInteger(AValue: TJSONData; out AResult: Int64): Boolean;

implementation

uses
  Math;

constructor TMCPArgs.Create;
begin
  inherited Create;
end;

const
  // The compiler stores this sentinel when a property declares no
  // `default` directive (same convention as Delphi's NoDefault).
  MCP_NO_DEFAULT = Longint($80000000);

function MCPPropHasDefault(AProp: PPropInfo): Boolean;
begin
  // `default` is only expressible on ordinal properties.
  Result := (AProp^.PropType^.Kind in [tkInteger, tkBool, tkEnumeration])
    and (AProp^.Default <> MCP_NO_DEFAULT);
end;

function MCPPropIsOptional(AInstance: TObject; AProp: PPropInfo): Boolean;
begin
  Result := MCPPropHasDefault(AProp) or
    not IsStoredProp(AInstance, AProp);
end;

function GetQWordProperty(AInstance: TObject; AProp: PPropInfo): QWord;
var
  SignedBits: Int64;
begin
  // FPC 3.2.2 has tkQWord RTTI but exposes only signed Int64 property
  // accessors. Preserve the returned bits instead of interpreting the
  // value as signed.
  SignedBits := GetInt64Prop(AInstance, AProp);
  Move(SignedBits, Result, SizeOf(Result));
end;

function GetUnsignedOrdProperty(AInstance: TObject;
  AProp: PPropInfo): QWord;
begin
  // GetOrdProp sign-extends otULong values on FPC 3.2.2.
  Result := QWord(LongWord(GetOrdProp(AInstance, AProp)));
end;

// The JSON item type a published dynamic array maps to: 'string',
// 'number', 'boolean', 'integer' (LongInt elements) or 'int64' (Int64
// elements, also JSON integers); '' for an element type with no
// mapping.
function ArrayItemType(AArrayType: PTypeInfo): string; forward;

// Whether AProp reads and writes one and the same field: no accessor
// method runs, and what binding writes is what a handler reads (#95
// review).
function ReadsAndWritesOneField(AProp: PPropInfo): Boolean;
begin
  Result := ((AProp^.PropProcs and 3) = ptField) and
    (((AProp^.PropProcs shr 2) and 3) = ptField) and
    (AProp^.GetProc = AProp^.SetProc);
end;

// The JSON item type of the published dynamic-array property AProp,
// checked for every use (schema, binding, serialization, #95 review):
// the element type must have a mapping, and the property must read and
// write the same field (ReadsAndWritesOneField), since a getter method's
// fresh array is finalized before its pointer can be used (FPC 3.2.2
// GetDynArrayProp). Raises EMCPSchema otherwise.
function CheckedArrayItemType(AProp: PPropInfo;
  const AClassName: string): string;
begin
  Result := ArrayItemType(AProp^.PropType);
  if Result = '' then
    raise EMCPSchema.CreateFmt('Array property "%s" of %s has no JSON ' +
      'Schema mapping (element types: string, Integer, Int64, Double, ' +
      'Boolean)', [AProp^.Name, AClassName]);
  if not ReadsAndWritesOneField(AProp) then
    raise EMCPSchema.CreateFmt('Array property "%s" of %s must read and ' +
      'write the same field, not a method', [AProp^.Name, AClassName]);
end;

// The nested argument class of the published class property AProp;
// raises EMCPSchema when it is not a TMCPArgs descendant.
function CheckedArgsClass(AProp: PPropInfo;
  const AClassName: string): TMCPArgsClass;
var
  PropClass: TClass;
begin
  PropClass := GetTypeData(AProp^.PropType)^.ClassType;
  if not PropClass.InheritsFrom(TMCPArgs) then
    raise EMCPSchema.CreateFmt('Object property "%s" of %s must be a ' +
      'TMCPArgs descendant', [AProp^.Name, AClassName]);
  // The instance owns its nested objects; a field read and written
  // directly keeps replacement and destruction to one rule (#95 review).
  if not ReadsAndWritesOneField(AProp) then
    raise EMCPSchema.CreateFmt('Object property "%s" of %s must read and ' +
      'write the same field, not a method', [AProp^.Name, AClassName]);
  Result := TMCPArgsClass(PropClass);
end;

function ArrayItemType(AArrayType: PTypeInfo): string;
var
  Element: PTypeInfo;
begin
  Result := '';
  Element := GetTypeData(AArrayType)^.ElType2;
  if Element = nil then
    Exit;
  case Element^.Kind of
    tkAString:
      Result := 'string';
    tkFloat:
      if GetTypeData(Element)^.FloatType = ftDouble then
        Result := 'number';
    tkBool:
      if GetTypeData(Element)^.OrdType = otUByte then
        Result := 'boolean';
    tkInteger:
      if GetTypeData(Element)^.OrdType = otSLong then
        Result := 'integer';
    tkInt64:
      Result := 'int64';
  end;
end;

// Whether AProp holds a nested argument object its instance owns: a
// TMCPArgs-descendant property backed by one field (CheckedArgsClass's
// rule). Only these are read during ownership scans, so no getter runs
// and no foreign object is freed (#95 review).
function OwnsNested(AProp: PPropInfo): Boolean;
begin
  Result := (AProp^.PropType^.Kind = tkClass) and
    GetTypeData(AProp^.PropType)^.ClassType.InheritsFrom(TMCPArgs) and
    ReadsAndWritesOneField(AProp);
end;

// Whether an owned nested property of AInstance before AIndex holds
// AObject. Compares references only: AObject may already be freed.
function HeldByEarlier(AInstance: TObject; AProps: PPropList; AIndex: Integer;
  AObject: TObject): Boolean;
var
  I: Integer;
begin
  for I := 0 to AIndex - 1 do
    if OwnsNested(AProps^[I]) and
      (GetObjectProp(AInstance, AProps^[I]) = AObject) then
      Exit(True);
  Result := False;
end;

// Whether an owned nested property of AInstance other than AProp holds
// AObject.
function HeldElsewhere(AInstance: TObject; AProp: PPropInfo;
  AObject: TObject): Boolean;
var
  Info: PTypeInfo;
  Props: PPropList;
  Count, I: Integer;
begin
  Result := False;
  Info := PTypeInfo(AInstance.ClassInfo);
  Count := GetTypeData(Info)^.PropCount;
  GetMem(Props, Count * SizeOf(Pointer));
  try
    GetPropInfos(Info, Props);
    for I := 0 to Count - 1 do
      if (Props^[I] <> AProp) and OwnsNested(Props^[I]) and
        (GetObjectProp(AInstance, Props^[I]) = AObject) then
        Exit(True);
  finally
    FreeMem(Props);
  end;
end;

destructor TMCPArgs.Destroy;
var
  Info: PTypeInfo;
  Props: PPropList;
  Count, I: Integer;
  Nested: TObject;
begin
  // Nested argument objects (#95) belong to the instance that holds
  // them: the binder creates them, so the parent frees them.
  Info := PTypeInfo(ClassInfo);
  Count := GetTypeData(Info)^.PropCount;
  if Count > 0 then
  begin
    GetMem(Props, Count * SizeOf(Pointer));
    try
      GetPropInfos(Info, Props);
      for I := 0 to Count - 1 do
        if OwnsNested(Props^[I]) then
        begin
          Nested := GetObjectProp(Self, Props^[I]);
          // Freed once even when two properties hold the same object:
          // the earlier-reference check runs first, on the reference
          // alone, before anything touches the object.
          if (Nested <> nil) and not HeldByEarlier(Self, Props, I,
            Nested) then
            Nested.Free;
        end;
    finally
      FreeMem(Props);
    end;
  end;
  inherited Destroy;
end;

const
  // Guards against an argument class that contains itself.
  MAX_NESTING = 16;

function SchemaFromAt(AClass: TMCPArgsClass; ADepth: Integer): TMCPSchema; forward;

function NestedSchema(AClass: TMCPArgsClass; ADepth: Integer): TJSONObject;
begin
  Result := SchemaFromAt(AClass, ADepth).Build;
end;

function SchemaFrom(AClass: TMCPArgsClass): TMCPSchema;
begin
  Result := SchemaFromAt(AClass, 0);
end;

function SchemaFromAt(AClass: TMCPArgsClass; ADepth: Integer): TMCPSchema;
var
  ItemType: string;
  Info: PTypeInfo;
  Props: PPropList;
  Count, I, E: Integer;
  Prop: PPropInfo;
  EnumInfo: PTypeInfo;
  EnumValues: TJSONArray;
  PropObj: TJSONObject;
  Probe: TMCPArgs;
  NestedClass: TMCPArgsClass;
  Req: Boolean;
begin
  Result := ObjectSchema;
  Info := PTypeInfo(AClass.ClassInfo);
  Count := GetTypeData(Info)^.PropCount;
  if Count = 0 then
    Exit;
  // A throwaway instance lets IsStoredProp evaluate the supported
  // constant `stored` directives.
  Probe := AClass.Create;
  GetMem(Props, Count * SizeOf(Pointer));
  try
    // GetPropInfos preserves declaration order — the deterministic
    // ordering the rest of the library already promises.
    GetPropInfos(Info, Props);
    for I := 0 to Count - 1 do
    begin
      Prop := Props^[I];
      Req := not MCPPropIsOptional(Probe, Prop);
      case Prop^.PropType^.Kind of
        tkSString, tkLString, tkAString, tkWString, tkUString:
          Result := Result.AddString(Prop^.Name, '', Req);
        tkFloat:
          Result := Result.AddNumber(Prop^.Name, '', Req);
        tkInteger, tkInt64, tkQWord:
          Result := Result.AddInteger(Prop^.Name, '', Req);
        tkBool:
          Result := Result.AddBoolean(Prop^.Name, '', Req);
        tkDynArray:
          begin
            ItemType := CheckedArrayItemType(Prop, AClass.ClassName);
            if ItemType = 'int64' then
              ItemType := 'integer';
            Result := Result.AddArray(Prop^.Name, ItemType, '', Req);
          end;
        tkClass:
          begin
            NestedClass := CheckedArgsClass(Prop, AClass.ClassName);
            if ADepth >= MAX_NESTING then
              raise EMCPSchema.CreateFmt('Argument classes nest deeper ' +
                'than %d levels at "%s" of %s', [MAX_NESTING, Prop^.Name,
                AClass.ClassName]);
            Result := Result.AddPropertySchema(Prop^.Name,
              NestedSchema(NestedClass, ADepth + 1), '', Req);
          end;
        tkEnumeration:
          begin
            // Enums map to a string with the enum names as the
            // allowed values.
            Result := Result.AddString(Prop^.Name, '', Req);
            EnumInfo := Prop^.PropType;
            EnumValues := TJSONArray.Create;
            for E := GetTypeData(EnumInfo)^.MinValue to
              GetTypeData(EnumInfo)^.MaxValue do
              EnumValues.Add(GetEnumName(EnumInfo, E));
            PropObj := TJSONObject(
              Result.FCore.FProperties.Find(Prop^.Name));
            PropObj.Add('enum', EnumValues);
          end;
      else
        // The half-built schema is freed by the shared core when the
        // result record goes out of scope during unwinding.
        raise EMCPSchema.CreateFmt(
          'Property "%s" of %s has no JSON Schema mapping ' +
          '(supported: string, float, integer, boolean, enum, ' +
          'dynamic array, TMCPArgs object)',
          [Prop^.Name, AClass.ClassName]);
      end;
      if MCPPropHasDefault(Prop) then
      begin
        PropObj := TJSONObject(
          Result.FCore.FProperties.Find(Prop^.Name));
        case Prop^.PropType^.Kind of
          tkInteger:
            PropObj.Add('default', Prop^.Default);
          tkBool:
            PropObj.Add('default', Prop^.Default <> 0);
          tkEnumeration:
            PropObj.Add('default',
              GetEnumName(Prop^.PropType, Prop^.Default));
        end;
      end;
    end;
  finally
    FreeMem(Props);
    Probe.Free;
  end;
end;

type
  // Float node serializing as the shortest round-trip decimal — see
  // MCPWireNumber's interface comment.
  TMCPWireFloat = class(TJSONFloatNumber)
  protected
    function GetAsString: TJSONStringType; override;
  end;

// The decimal ADigits x 10^(AExponent - Length(ADigits) + 1), i.e.
// d.ddd x 10^AExponent, written as JavaScript's Number#toString
// writes a finite number (ECMA-262, Number::toString): plain notation
// for exponents from -7 to 20, exponent notation (1e+21, 5e-324)
// outside. ADigits has no trailing zeros.
function JSNumberText(ANegative: Boolean; const ADigits: string;
  AExponent: Integer): string;
var
  K, N: Integer;
begin
  K := Length(ADigits);
  N := AExponent + 1;
  if (K <= N) and (N <= 21) then
    Result := ADigits + StringOfChar('0', N - K)
  else if (0 < N) and (N <= 21) then
    Result := Copy(ADigits, 1, N) + '.' + Copy(ADigits, N + 1, K - N)
  else if (-6 < N) and (N <= 0) then
    Result := '0.' + StringOfChar('0', -N) + ADigits
  else
  begin
    Result := ADigits[1];
    if K > 1 then
      Result := Result + '.' + Copy(ADigits, 2, K - 1);
    if N - 1 >= 0 then
      Result := Result + 'e+' + IntToStr(N - 1)
    else
      Result := Result + 'e-' + IntToStr(1 - N);
  end;
  if ANegative then
    Result := '-' + Result;
end;

// Unsigned big integer for exact decimal conversion: 32-bit limbs,
// least significant first, no leading zero limbs (zero is empty).
type
  TWireBig = array of LongWord;

procedure BigTrim(var A: TWireBig);
var
  N: Integer;
begin
  N := Length(A);
  while (N > 0) and (A[N - 1] = 0) do
    Dec(N);
  SetLength(A, N);
end;

function BigFrom(AValue: QWord): TWireBig;
begin
  SetLength(Result, 2);
  Result[0] := LongWord(AValue and $FFFFFFFF);
  Result[1] := LongWord(AValue shr 32);
  BigTrim(Result);
end;

procedure BigMulSmall(var A: TWireBig; AFactor: LongWord);
var
  I: Integer;
  Carry: QWord;
begin
  Carry := 0;
  for I := 0 to High(A) do
  begin
    Carry := QWord(A[I]) * AFactor + Carry;
    A[I] := LongWord(Carry and $FFFFFFFF);
    Carry := Carry shr 32;
  end;
  if Carry <> 0 then
  begin
    SetLength(A, Length(A) + 1);
    A[High(A)] := LongWord(Carry);
  end;
end;

procedure BigShl(var A: TWireBig; ABits: Integer);
var
  Words, Bits, I: Integer;
  Old: TWireBig;
begin
  if (Length(A) = 0) or (ABits = 0) then
    Exit;
  Words := ABits div 32;
  Bits := ABits mod 32;
  Old := Copy(A);
  SetLength(A, Length(Old) + Words + 1);
  for I := 0 to High(A) do
    A[I] := 0;
  for I := 0 to High(Old) do
  begin
    A[I + Words] := A[I + Words] or (Old[I] shl Bits);
    if Bits > 0 then
      A[I + Words + 1] := Old[I] shr (32 - Bits);
  end;
  BigTrim(A);
end;

procedure BigMulPow10(var A: TWireBig; APower: Integer);
begin
  while APower >= 9 do
  begin
    BigMulSmall(A, 1000000000);
    Dec(APower, 9);
  end;
  while APower > 0 do
  begin
    BigMulSmall(A, 10);
    Dec(APower);
  end;
end;

function BigCompare(const A, B: TWireBig): Integer;
var
  I: Integer;
begin
  if Length(A) <> Length(B) then
    Exit(Ord(Length(A) > Length(B)) * 2 - 1);
  for I := High(A) downto 0 do
    if A[I] <> B[I] then
      Exit(Ord(A[I] > B[I]) * 2 - 1);
  Result := 0;
end;

function BigAdd(const A, B: TWireBig): TWireBig;
var
  I: Integer;
  Carry: QWord;
begin
  SetLength(Result, Max(Length(A), Length(B)) + 1);
  Carry := 0;
  for I := 0 to High(Result) do
  begin
    if I < Length(A) then
      Carry := Carry + A[I];
    if I < Length(B) then
      Carry := Carry + B[I];
    Result[I] := LongWord(Carry and $FFFFFFFF);
    Carry := Carry shr 32;
  end;
  BigTrim(Result);
end;

// A := A - B, for A >= B.
procedure BigSub(var A: TWireBig; const B: TWireBig);
var
  I: Integer;
  Borrow, Diff: Int64;
begin
  Borrow := 0;
  for I := 0 to High(A) do
  begin
    Diff := Int64(A[I]) - Borrow;
    if I < Length(B) then
      Diff := Diff - B[I];
    if Diff < 0 then
    begin
      Inc(Diff, Int64(1) shl 32);
      Borrow := 1;
    end
    else
      Borrow := 0;
    A[I] := LongWord(Diff);
  end;
  BigTrim(A);
end;

// Burger and Dybvig's free-format algorithm ("Printing
// Floating-Point Numbers Quickly and Accurately", 1996) in exact
// integer arithmetic. R/S is the value; MPlus/S and MMinus/S are the
// distances to the upper and lower ends of its rounding interval. A
// decimal on an end of the interval reads back as the value only when
// its significand is even (round-half-even), so Even says whether the
// ends belong to it.
type
  TWireDigits = record
    R, S, MPlus, MMinus: TWireBig;
    Even: Boolean;
    K: Integer; // the value is 0.ddd x 10^K
  end;

// R, S, MPlus and MMinus for a finite AValue > 0, all scaled by 2 so
// the half-gaps stay integral. The gap below a power of two is half
// the gap above it.
procedure WireInterval(AValue: Double; var AState: TWireDigits);
var
  Bits, F: QWord;
  BiasedExp, E: Integer;
  PowerOfTwo: Boolean;
begin
  Move(AValue, Bits, SizeOf(Bits));
  BiasedExp := Integer((Bits shr 52) and $7FF);
  F := Bits and QWord($FFFFFFFFFFFFF);
  if BiasedExp = 0 then
    E := -1074
  else
  begin
    F := F or (QWord(1) shl 52);
    E := BiasedExp - 1075;
  end;
  AState.Even := not Odd(F);
  PowerOfTwo := (F = QWord(1) shl 52) and (E > -1074);
  AState.R := BigFrom(F);
  BigShl(AState.R, 1 + Max(E, 0));
  AState.S := BigFrom(2);
  BigShl(AState.S, Max(-E, 0));
  AState.MPlus := BigFrom(1);
  BigShl(AState.MPlus, Max(E, 0));
  AState.MMinus := Copy(AState.MPlus);
  if PowerOfTwo then
  begin
    BigShl(AState.R, 1);
    BigShl(AState.S, 1);
    BigShl(AState.MPlus, 1);
  end;
end;

// K: the smallest power of ten above the interval's top. Starts from
// an estimate and corrects it exactly.
procedure WireScale(AValue: Double; var AState: TWireDigits);
var
  Cmp: Integer;
  Top: TWireBig;
begin
  AState.K := Ceil(Log10(AValue) - 1E-10);
  if AState.K >= 0 then
    BigMulPow10(AState.S, AState.K)
  else
  begin
    BigMulPow10(AState.R, -AState.K);
    BigMulPow10(AState.MPlus, -AState.K);
    BigMulPow10(AState.MMinus, -AState.K);
  end;
  repeat
    Top := BigAdd(AState.R, AState.MPlus);
    Cmp := BigCompare(Top, AState.S);
    if (Cmp > 0) or (AState.Even and (Cmp = 0)) then
    begin
      BigMulSmall(AState.S, 10);
      Inc(AState.K);
      Continue;
    end;
    BigMulSmall(Top, 10);
    Cmp := BigCompare(Top, AState.S);
    if (Cmp < 0) or (not AState.Even and (Cmp = 0)) then
    begin
      BigMulSmall(AState.R, 10);
      BigMulSmall(AState.MPlus, 10);
      BigMulSmall(AState.MMinus, 10);
      Dec(AState.K);
      Continue;
    end;
    Break;
  until False;
end;

// The last digit D, once the remaining R is within the interval below
// (ALow), above (AHigh) or both: the nearer of D and D + 1, the even
// one on a tie, as JavaScript's Number#toString picks (ECMA-262,
// Number::toString).
function WireLastDigit(const AState: TWireDigits; D: Integer;
  ALow, AHigh: Boolean): Integer;
var
  Twice: TWireBig;
  Cmp: Integer;
begin
  Result := D;
  if ALow and AHigh then
  begin
    Twice := Copy(AState.R);
    BigShl(Twice, 1);
    Cmp := BigCompare(Twice, AState.S);
    if (Cmp > 0) or ((Cmp = 0) and Odd(D)) then
      Result := D + 1;
  end
  else if AHigh then
    Result := D + 1;
end;

// Appends the final digit, carrying a 10 into the digits before it;
// the positions the carry leaves are trailing zeros.
procedure WireAppendLast(var ADigits: string; D: Integer; var AK: Integer);
begin
  while (D = 10) and (ADigits <> '') do
  begin
    D := Ord(ADigits[Length(ADigits)]) - Ord('0') + 1;
    Delete(ADigits, Length(ADigits), 1);
  end;
  if D = 10 then
  begin
    // 0.99...9 rounded up: 0.1 x 10^(K + 1).
    ADigits := '1';
    Inc(AK);
  end
  else
    ADigits := ADigits + Chr(Ord('0') + D);
end;

// The shortest decimal digits and exponent E (d.ddd x 10^E) that read
// back as a finite AValue > 0.
procedure ShortestDigits(AValue: Double; out ADigits: string;
  out AExponent: Integer);
var
  State: TWireDigits;
  D, Cmp: Integer;
  Low, High: Boolean;
begin
  WireInterval(AValue, State);
  WireScale(AValue, State);
  ADigits := '';
  repeat
    BigMulSmall(State.R, 10);
    BigMulSmall(State.MPlus, 10);
    BigMulSmall(State.MMinus, 10);
    D := 0;
    while BigCompare(State.R, State.S) >= 0 do
    begin
      BigSub(State.R, State.S);
      Inc(D);
    end;
    Cmp := BigCompare(State.R, State.MMinus);
    Low := (Cmp < 0) or (State.Even and (Cmp = 0));
    Cmp := BigCompare(BigAdd(State.R, State.MPlus), State.S);
    High := (Cmp > 0) or (State.Even and (Cmp = 0));
    if Low or High then
    begin
      WireAppendLast(ADigits, WireLastDigit(State, D, Low, High), State.K);
      Break;
    end;
    ADigits := ADigits + Chr(Ord('0') + D);
  until False;
  while (Length(ADigits) > 1) and (ADigits[Length(ADigits)] = '0') do
    Delete(ADigits, Length(ADigits), 1);
  AExponent := State.K - 1;
end;

function TMCPWireFloat.GetAsString: TJSONStringType;
var
  Value: Double;
  Digits: string;
  Exponent: Integer;
begin
  // The node stays an ordinary, assignable fpjson float, so the value
  // is checked here as well as at creation.
  Value := AsFloat;
  if IsNan(Value) or IsInfinite(Value) then
    raise EMCPSchema.Create('NaN and infinite numbers have no JSON form');
  if Value = 0 then
    Exit('0');
  ShortestDigits(Abs(Value), Digits, Exponent);
  Result := JSNumberText(Value < 0, Digits, Exponent);
end;

// A float node that writes its value as MCPWireNumber does, for a
// typed float property: it stays a float node however integral the
// value, so assigning a fraction to it later keeps the fraction.
function WireFloatNode(AValue: Double): TJSONData;
begin
  if IsNan(AValue) or IsInfinite(AValue) then
    raise EMCPSchema.Create('NaN and infinite numbers have no JSON form');
  Result := TMCPWireFloat.Create(AValue);
end;

function MCPWireNumber(AValue: Double): TJSONData;
begin
  if IsNan(AValue) or IsInfinite(AValue) then
    raise EMCPSchema.Create('NaN and infinite numbers have no JSON form');
  // Every integer below 2^53 is an exact Double and fits an Int64;
  // integral values beyond it keep the float node, which writes them
  // the way JavaScript does. The range test comes first: Frac past 2^63
  // overflows on AArch64 (FPC 3.2.2).
  if (Abs(AValue) < 9007199254740992.0) and (Frac(AValue) = 0) then
    Result := TJSONInt64Number.Create(Trunc(AValue))
  else
    Result := TMCPWireFloat.Create(AValue);
end;

// A published dynamic array as a JSON array.
function SerializeArray(AObj: TMCPArgs; AProp: PPropInfo): TJSONArray;
var
  Raw: Pointer;
  ItemType: string;
  I: Integer;
begin
  // Checked first: a field-backed property's array outlives the read,
  // and an unmapped element type is never read as another (#95 review).
  ItemType := CheckedArrayItemType(AProp, AObj.ClassName);
  Raw := GetDynArrayProp(AObj, AProp);
  Result := TJSONArray.Create;
  try
    for I := 0 to DynArraySize(Raw) - 1 do
      if ItemType = 'string' then
        Result.Add(PAnsiString(Raw)[I])
      else if ItemType = 'number' then
        Result.Add(WireFloatNode(PDouble(Raw)[I]))
      else if ItemType = 'boolean' then
        Result.Add(PBoolean(Raw)[I])
      else if ItemType = 'integer' then
        Result.Add(PLongInt(Raw)[I])
      else
        Result.Add(PInt64(Raw)[I]);
  except
    // A NaN element has no JSON form: free the partial array.
    Result.Free;
    raise;
  end;
end;

function SerializeAt(AObj: TMCPArgs; ADepth: Integer): TJSONObject;
var
  Nested: TObject;
  Info: PTypeInfo;
  Props: PPropList;
  Count, I: Integer;
  Prop: PPropInfo;
  TypeData: PTypeData;
begin
  Result := TJSONObject.Create;
  Info := PTypeInfo(AObj.ClassInfo);
  Count := GetTypeData(Info)^.PropCount;
  if Count = 0 then
    Exit;
  GetMem(Props, Count * SizeOf(Pointer));
  try
    try
      GetPropInfos(Info, Props);
      for I := 0 to Count - 1 do
      begin
        Prop := Props^[I];
        case Prop^.PropType^.Kind of
          tkSString, tkLString, tkAString, tkWString, tkUString:
            Result.Add(Prop^.Name, GetStrProp(AObj, Prop));
          tkFloat:
            Result.Add(Prop^.Name, WireFloatNode(GetFloatProp(AObj, Prop)));
          tkInteger:
            begin
              TypeData := GetTypeData(Prop^.PropType);
              if TypeData^.OrdType in [otUByte, otUWord, otULong] then
                Result.Add(Prop^.Name, GetUnsignedOrdProperty(AObj, Prop))
              else
                Result.Add(Prop^.Name, GetOrdProp(AObj, Prop));
            end;
          tkInt64:
            Result.Add(Prop^.Name, GetInt64Prop(AObj, Prop));
          tkQWord:
            Result.Add(Prop^.Name, GetQWordProperty(AObj, Prop));
          tkBool:
            Result.Add(Prop^.Name, GetOrdProp(AObj, Prop) <> 0);
          tkEnumeration:
            Result.Add(Prop^.Name, GetEnumProp(AObj, Prop));
          tkDynArray:
            Result.Add(Prop^.Name, SerializeArray(AObj, Prop));
          tkClass:
            begin
              // Checked as SchemaFrom and the binder check it, so an
              // unmapped class raises instead of vanishing (#95 review);
              // read once, and an absent (nil) one is left out.
              CheckedArgsClass(Prop, AObj.ClassName);
              Nested := GetObjectProp(AObj, Prop);
              if Nested <> nil then
              begin
                if ADepth >= MAX_NESTING then
                  raise EMCPSchema.CreateFmt('Argument objects nest deeper ' +
                    'than %d levels at "%s" of %s', [MAX_NESTING, Prop^.Name,
                    AObj.ClassName]);
                Result.Add(Prop^.Name, SerializeAt(TMCPArgs(Nested),
                  ADepth + 1));
              end;
            end;
        else
          raise EMCPSchema.CreateFmt(
            'Property "%s" of %s has no JSON mapping',
            [Prop^.Name, AObj.ClassName]);
        end;
      end;
    except
      // An unmappable property or a value with no JSON form (a NaN
      // float): free the partial object, then let the error through.
      Result.Free;
      raise;
    end;
  finally
    FreeMem(Props);
  end;
end;

function MCPSerialize(AObj: TMCPArgs): TJSONObject;
begin
  Result := SerializeAt(AObj, 0);
end;

destructor TMCPSchemaCore.Destroy;
begin
  // A schema that was never built still owns its JSON: free it with
  // the last record copy instead of leaking.
  if FRoot <> nil then
  begin
    FRequired.Free;
    FRoot.Free;
  end;
  inherited Destroy;
end;

function ObjectSchema: TMCPSchema;
var
  Core: TMCPSchemaCore;
begin
  Core := TMCPSchemaCore.Create;
  Result.FCore := Core;
  Result.FLifetime := Core;
  Core.FProperties := TJSONObject.Create;
  Core.FRequired := TJSONArray.Create;
  Core.FRoot := TJSONObject.Create;
  Core.FRoot.Add('type', 'object');
  Core.FRoot.Add('properties', Core.FProperties);
end;

function TMCPSchema.ActiveCore: TMCPSchemaCore;
begin
  // FCore = nil covers the default record (never created through
  // ObjectSchema/SchemaFrom); a nil FRoot on a live core means some
  // copy already called Build.
  if (FCore = nil) or (FCore.FRoot = nil) then
    raise EMCPSchema.Create('Schema was already built');
  Result := FCore;
end;

function TMCPSchema.AddProperty(const AName, AJsonType, ADescription: string;
  ARequired: Boolean): TMCPSchema;
var
  Prop: TJSONObject;
begin
  Prop := TJSONObject.Create;
  Prop.Add('type', AJsonType);
  // One place for the name, required and last-property rules.
  Result := AddPropertySchema(AName, Prop, ADescription, ARequired);
end;

function TMCPSchema.AddPropertySchema(const AName: string;
  AProperty: TJSONObject; const ADescription: string;
  ARequired: Boolean): TMCPSchema;
var
  Core: TMCPSchemaCore;
begin
  Core := FCore;
  if (Core = nil) or (Core.FRoot = nil) then
  begin
    AProperty.Free;
    Core := ActiveCore; // raises
  end;
  if Core.FProperties.IndexOfName(AName) >= 0 then
  begin
    AProperty.Free;
    raise EMCPSchema.CreateFmt(
      'Schema property "%s" is already defined', [AName]);
  end;
  if (ADescription <> '') and (AProperty.Find('description') = nil) then
    AProperty.Add('description', ADescription);
  Core.FProperties.Add(AName, AProperty);
  if ARequired then
    Core.FRequired.Add(AName);
  Core.FLast := AProperty;
  Core.FLastName := AName;
  Result := Self;
end;

function TMCPSchema.AddEnum(const AName: string; const AValues: array of string;
  const ADescription: string; ARequired: Boolean): TMCPSchema;
var
  Prop: TJSONObject;
  Values: TJSONArray;
  I: Integer;
begin
  if Length(AValues) = 0 then
    raise EMCPSchema.CreateFmt('Enum property "%s" needs values', [AName]);
  Values := TJSONArray.Create;
  for I := 0 to High(AValues) do
    Values.Add(AValues[I]);
  Prop := TJSONObject.Create;
  Prop.Add('type', 'string');
  Prop.Add('enum', Values);
  Result := AddPropertySchema(AName, Prop, ADescription, ARequired);
end;

function TMCPSchema.AddArray(const AName, AItemType: string;
  const ADescription: string; ARequired: Boolean): TMCPSchema;
var
  Prop, Items: TJSONObject;
begin
  if (AItemType <> 'string') and (AItemType <> 'number') and
    (AItemType <> 'integer') and (AItemType <> 'boolean') then
    raise EMCPSchema.CreateFmt('Array property "%s" item type "%s" must be ' +
      'string, number, integer or boolean', [AName, AItemType]);
  Items := TJSONObject.Create;
  Items.Add('type', AItemType);
  Prop := TJSONObject.Create;
  Prop.Add('type', 'array');
  Prop.Add('items', Items);
  Result := AddPropertySchema(AName, Prop, ADescription, ARequired);
end;

function TMCPSchema.AddArray(const AName: string; constref AItems: TMCPSchema;
  const ADescription: string; ARequired: Boolean): TMCPSchema;
var
  Prop, Items: TJSONObject;
begin
  // Built first: if AItems was already built, nothing is left over.
  Items := AItems.Build;
  Prop := TJSONObject.Create;
  Prop.Add('type', 'array');
  Prop.Add('items', Items);
  Result := AddPropertySchema(AName, Prop, ADescription, ARequired);
end;

function TMCPSchema.AddObject(const AName: string; constref ASchema: TMCPSchema;
  const ADescription: string; ARequired: Boolean): TMCPSchema;
begin
  Result := AddPropertySchema(AName, ASchema.Build, ADescription, ARequired);
end;

function TMCPSchema.SetDefault(AValue: TJSONData): TMCPSchema;
var
  Core: TMCPSchemaCore;
  I: Integer;
  Problem: string;
begin
  Core := FCore;
  if (Core = nil) or (Core.FRoot = nil) or (Core.FLast = nil) then
  begin
    AValue.Free;
    if (Core <> nil) and (Core.FRoot <> nil) then
      raise EMCPSchema.Create('WithDefault needs a property added before it');
    Core := ActiveCore; // raises
  end;
  // The default must fit its property, or the server either refuses
  // the schema at startup or silently skips seeding it (#95 review).
  Problem := '';
  if (Core.FLast.Get('type', '') = 'object') or
    (Core.FLast.Get('type', '') = 'array') then
    Problem := 'defaults apply to primitive properties'
  else if Core.FLast.Find('default') <> nil then
    Problem := 'it already has a default'
  else if not MCPValidateAgainstSchema(Core.FLast, AValue, 'default', False,
    Problem) then
    Problem := 'the default does not fit it (' + Problem + ')'
  else
    Problem := '';
  if Problem <> '' then
  begin
    AValue.Free;
    raise EMCPSchema.CreateFmt('Property "%s": %s', [Core.FLastName,
      Problem]);
  end;
  Core.FLast.Add('default', AValue);
  for I := Core.FRequired.Count - 1 downto 0 do
    if Core.FRequired[I].AsString = Core.FLastName then
      Core.FRequired.Delete(I);
  Result := Self;
end;

function TMCPSchema.WithDefault(const AValue: string): TMCPSchema;
begin
  Result := SetDefault(TJSONString.Create(AValue));
end;

function TMCPSchema.WithDefault(AValue: Int64): TMCPSchema;
begin
  Result := SetDefault(TJSONInt64Number.Create(AValue));
end;

function TMCPSchema.WithDefault(AValue: Double): TMCPSchema;
begin
  Result := SetDefault(MCPWireNumber(AValue));
end;

function TMCPSchema.WithDefault(AValue: Boolean): TMCPSchema;
begin
  Result := SetDefault(TJSONBoolean.Create(AValue));
end;

function TMCPSchema.AddString(const AName: string; const ADescription: string;
  ARequired: Boolean): TMCPSchema;
begin
  Result := AddProperty(AName, 'string', ADescription, ARequired);
end;

function TMCPSchema.AddNumber(const AName: string; const ADescription: string;
  ARequired: Boolean): TMCPSchema;
begin
  Result := AddProperty(AName, 'number', ADescription, ARequired);
end;

function TMCPSchema.AddInteger(const AName: string; const ADescription: string;
  ARequired: Boolean): TMCPSchema;
begin
  Result := AddProperty(AName, 'integer', ADescription, ARequired);
end;

function TMCPSchema.AddBoolean(const AName: string; const ADescription: string;
  ARequired: Boolean): TMCPSchema;
begin
  Result := AddProperty(AName, 'boolean', ADescription, ARequired);
end;

function TMCPSchema.Build: TJSONObject;
var
  Core: TMCPSchemaCore;
begin
  Core := ActiveCore;
  if Core.FRequired.Count > 0 then
    Core.FRoot.Add('required', Core.FRequired)
  else
    Core.FRequired.Free;
  Result := Core.FRoot;
  // Consumed state is recorded on the shared core so every record
  // copy sees it.
  Core.FRoot := nil;
  Core.FProperties := nil;
  Core.FRequired := nil;
  Core.FLast := nil;
end;


{ ───────── argument binding (moved from MCP.Server; #95) ───────── }

function BindObject(AClass: TMCPArgsClass; AArguments: TJSONObject;
  const APrefix: string; ADepth: Integer; out AInstance: TMCPArgs;
  out AError: string): Boolean; forward;
function IsFiniteNumber(AValue: TJSONData): Boolean; forward;
function MemberIndex(AObject: TJSONObject; const AName: string): Integer;
  forward;

function JoinPath(const APath, AName: string): string; forward;
function IsIntegralNumber(AValue: TJSONData): Boolean; forward;
function MatchesType(AValue: TJSONData; const AType: string): Boolean;
  forward;

// A JSON integer as Int64. A float with no fractional part (2.0, 2e0)
// counts as JSON Schema's integer does, within +-2^53 (IsIntegralNumber),
// so binding agrees with the subset validator (#95 review).
function ReadSignedInteger(AValue: TJSONData; out AResult: Int64): Boolean;
var
  UnsignedValue: QWord;
begin
  Result := (AValue.JSONType = jtNumber) and IsIntegralNumber(AValue);
  if not Result then
    Exit;
  if TJSONNumber(AValue).NumberType = ntFloat then
  begin
    AResult := Trunc(AValue.AsFloat); // within 2^53: exact, no overflow
    Exit;
  end;
  if TJSONNumber(AValue).NumberType = ntQWord then
  begin
    UnsignedValue := AValue.AsQWord;
    if UnsignedValue > QWord(High(Int64)) then
      Exit(False);
    AResult := Int64(UnsignedValue);
  end
  else
    AResult := AValue.AsInt64;
end;

function ReadUnsignedInteger(AValue: TJSONData; out AResult: QWord): Boolean;
var
  SignedValue: Int64;
begin
  Result := (AValue.JSONType = jtNumber) and IsIntegralNumber(AValue);
  if not Result then
    Exit;
  if TJSONNumber(AValue).NumberType = ntFloat then
  begin
    SignedValue := Trunc(AValue.AsFloat); // within 2^53
    if SignedValue < 0 then
      Exit(False);
    AResult := QWord(SignedValue);
    Exit;
  end;
  if TJSONNumber(AValue).NumberType = ntQWord then
    AResult := AValue.AsQWord
  else
  begin
    SignedValue := AValue.AsInt64;
    if SignedValue < 0 then
      Exit(False);
    AResult := QWord(SignedValue);
  end;
end;

function Mismatch(const APath, AExpected: string; out AError: string): Boolean;
begin
  AError := Format('Argument "%s" must be %s', [APath, AExpected]);
  Result := False;
end;

// 'a string', 'an integer', ... for an ArrayItemType result.
function ItemPhrase(const AItemType: string): string;
begin
  if (AItemType = 'integer') or (AItemType = 'int64') then
    Result := 'an integer'
  else
    Result := 'a ' + AItemType;
end;

// Whether a JSON array item fits AItemType (an ArrayItemType result); an
// integer item's value comes back in ASigned. An item stored as nil is a
// null: wrong for every element type.
function ItemAccepted(AItem: TJSONData; const AItemType: string;
  const AMinimum, AMaximum: Int64; out ASigned: Int64): Boolean;
begin
  ASigned := 0;
  if AItem = nil then
    Exit(False);
  if (AItemType <> 'integer') and (AItemType <> 'int64') then
    Exit(MatchesType(AItem, AItemType));
  Result := ReadSignedInteger(AItem, ASigned) and (ASigned >= AMinimum) and
    (ASigned <= AMaximum);
end;

// The declared bounds of an integer element type, so a subrange such as
// -100..100 binds only values inside it, as a flat property does (#95
// review).
procedure ElementBounds(AProp: PPropInfo; const AItemType: string;
  out AMinimum, AMaximum: Int64);
var
  Element: PTypeData;
begin
  AMinimum := Low(Int64);
  AMaximum := High(Int64);
  Element := GetTypeData(GetTypeData(AProp^.PropType)^.ElType2);
  if AItemType = 'integer' then
  begin
    AMinimum := Element^.MinValue;
    AMaximum := Element^.MaxValue;
  end
  else if AItemType = 'int64' then
  begin
    AMinimum := Element^.MinInt64Value;
    AMaximum := Element^.MaxInt64Value;
  end;
end;

type
  // The bound items of one array, in the field its element type uses.
  TBoundItems = record
    ItemType: string;
    Strings: array of string;
    Integers: array of LongInt;
    Int64s: array of Int64;
    Doubles: array of Double;
    Booleans: array of Boolean;
  end;

// Sized once for the item count (#95 review).
procedure SizeItems(var AItems: TBoundItems; ACount: Integer);
begin
  if AItems.ItemType = 'string' then
    SetLength(AItems.Strings, ACount)
  else if AItems.ItemType = 'number' then
    SetLength(AItems.Doubles, ACount)
  else if AItems.ItemType = 'boolean' then
    SetLength(AItems.Booleans, ACount)
  else if AItems.ItemType = 'integer' then
    SetLength(AItems.Integers, ACount)
  else
    SetLength(AItems.Int64s, ACount);
end;

// Store one item that ItemAccepted passed.
procedure StoreItem(var AItems: TBoundItems; AIndex: Integer; AItem: TJSONData;
  ASigned: Int64);
begin
  if AItems.ItemType = 'string' then
    AItems.Strings[AIndex] := AItem.AsString
  else if AItems.ItemType = 'number' then
    AItems.Doubles[AIndex] := AItem.AsFloat
  else if AItems.ItemType = 'boolean' then
    AItems.Booleans[AIndex] := AItem.AsBoolean
  else if AItems.ItemType = 'integer' then
    AItems.Integers[AIndex] := LongInt(ASigned)
  else // 'int64', the one type left after CheckedArrayItemType
    AItems.Int64s[AIndex] := ASigned;
end;

procedure PublishItems(AInstance: TMCPArgs; AProp: PPropInfo;
  const AItems: TBoundItems);
begin
  if AItems.ItemType = 'string' then
    SetDynArrayProp(AInstance, AProp, Pointer(AItems.Strings))
  else if AItems.ItemType = 'number' then
    SetDynArrayProp(AInstance, AProp, Pointer(AItems.Doubles))
  else if AItems.ItemType = 'boolean' then
    SetDynArrayProp(AInstance, AProp, Pointer(AItems.Booleans))
  else if AItems.ItemType = 'integer' then
    SetDynArrayProp(AInstance, AProp, Pointer(AItems.Integers))
  else
    SetDynArrayProp(AInstance, AProp, Pointer(AItems.Int64s));
end;

// A JSON array into a published dynamic array of one of the supported
// element types (see ArrayItemType).
function BindArray(AInstance: TMCPArgs; AProp: PPropInfo; AValue: TJSONData;
  const APath: string; out AError: string): Boolean;
var
  Items: TBoundItems;
  I: Integer;
  Signed, Minimum, Maximum: Int64;
begin
  Result := True;
  Items.ItemType := CheckedArrayItemType(AProp, AInstance.ClassName);
  if AValue.JSONType <> jtArray then
    Exit(Mismatch(APath, 'an array', AError));
  ElementBounds(AProp, Items.ItemType, Minimum, Maximum);
  SizeItems(Items, AValue.Count);
  for I := 0 to AValue.Count - 1 do
  begin
    if not ItemAccepted(AValue.Items[I], Items.ItemType, Minimum, Maximum,
      Signed) then
      Exit(Mismatch(Format('%s[%d]', [APath, I]), ItemPhrase(Items.ItemType),
        AError));
    StoreItem(Items, I, AValue.Items[I], Signed);
  end;
  PublishItems(AInstance, AProp, Items);
end;

procedure SetQWordProperty(AInstance: TMCPArgs; AProp: PPropInfo;
  const AValue: QWord);
var
  SignedBits: Int64;
begin
  // FPC 3.2.2 has tkQWord RTTI but exposes only signed Int64 property
  // accessors. Pass the unsigned value's bits through unchanged.
  Move(AValue, SignedBits, SizeOf(SignedBits));
  SetInt64Prop(AInstance, AProp, SignedBits);
end;

// An integer property of any width, inside its declared range.
function BindInteger(AInstance: TMCPArgs; AProp: PPropInfo; AValue: TJSONData;
  const APath: string; out AError: string): Boolean;
var
  TypeData: PTypeData;
  SignedValue: Int64;
  UnsignedValue, Minimum, Maximum: QWord;
begin
  Result := True;
  case AProp^.PropType^.Kind of
    tkInteger:
      begin
        TypeData := GetTypeData(AProp^.PropType);
        if TypeData^.OrdType in [otUByte, otUWord, otULong] then
        begin
          if not ReadUnsignedInteger(AValue, UnsignedValue) then
            Exit(Mismatch(APath, 'an integer', AError));
          Minimum := QWord(LongWord(TypeData^.MinValue));
          Maximum := QWord(LongWord(TypeData^.MaxValue));
          if (UnsignedValue < Minimum) or (UnsignedValue > Maximum) then
            Exit(Mismatch(APath, 'an integer', AError));
          SetOrdProp(AInstance, AProp, Int64(UnsignedValue));
        end
        else
        begin
          if not ReadSignedInteger(AValue, SignedValue) or
            (SignedValue < TypeData^.MinValue) or
            (SignedValue > TypeData^.MaxValue) then
            Exit(Mismatch(APath, 'an integer', AError));
          SetOrdProp(AInstance, AProp, SignedValue);
        end;
      end;
    tkInt64:
      // Inside the declared range, as tkInteger is (#95 review).
      if ReadSignedInteger(AValue, SignedValue) and
        (SignedValue >= GetTypeData(AProp^.PropType)^.MinInt64Value) and
        (SignedValue <= GetTypeData(AProp^.PropType)^.MaxInt64Value) then
        SetInt64Prop(AInstance, AProp, SignedValue)
      else
        Exit(Mismatch(APath, 'an integer', AError));
    tkQWord:
      if ReadUnsignedInteger(AValue, UnsignedValue) then
        SetQWordProperty(AInstance, AProp, UnsignedValue)
      else
        Exit(Mismatch(APath, 'an integer', AError));
  end;
end;

// Populate one published property from its JSON argument. False (with
// AError set) on a type mismatch. APath names the argument in errors.
function BindProperty(AInstance: TMCPArgs; AProp: PPropInfo;
  AValue: TJSONData; const APath: string; ADepth: Integer;
  out AError: string): Boolean;
var
  Nested: TMCPArgs;
  NestedClass: TMCPArgsClass;
  Previous: TObject;
begin
  Result := True;
  case AProp^.PropType^.Kind of
    tkSString, tkLString, tkAString, tkWString, tkUString:
      if AValue.JSONType = jtString then
        SetStrProp(AInstance, AProp, AValue.AsString)
      else
        Exit(Mismatch(APath, 'a string', AError));
    tkFloat:
      // A built NaN or infinity is no JSON number (#95 review).
      if (AValue.JSONType = jtNumber) and IsFiniteNumber(AValue) then
        SetFloatProp(AInstance, AProp, AValue.AsFloat)
      else
        Exit(Mismatch(APath, 'a number', AError));
    tkInteger, tkInt64, tkQWord:
      Exit(BindInteger(AInstance, AProp, AValue, APath, AError));
    tkBool:
      if AValue.JSONType = jtBoolean then
        SetOrdProp(AInstance, AProp, Ord(AValue.AsBoolean))
      else
        Exit(Mismatch(APath, 'a boolean', AError));
    tkEnumeration:
      if (AValue.JSONType = jtString) and
        (GetEnumValue(AProp^.PropType, AValue.AsString) >= 0) then
        SetEnumProp(AInstance, AProp, AValue.AsString)
      else
        Exit(Mismatch(APath, 'a string from the declared enum values', AError));
    tkDynArray:
      Exit(BindArray(AInstance, AProp, AValue, APath, AError));
    tkClass:
      begin
        NestedClass := CheckedArgsClass(AProp, AInstance.ClassName);
        if AValue.JSONType <> jtObject then
          Exit(Mismatch(APath, 'an object', AError));
        if not BindObject(NestedClass, TJSONObject(AValue), APath,
          ADepth + 1, Nested, AError) then
          Exit(False);
        // The instance owns its nested objects (TMCPArgs.Destroy): one
        // its constructor made is replaced and freed unless another
        // property still holds it. Field-backed (CheckedArgsClass), so
        // neither the read nor the write runs code that could raise.
        Previous := GetObjectProp(AInstance, AProp);
        SetObjectProp(AInstance, AProp, Nested);
        if (Previous <> nil) and (Previous <> Nested) and
          not HeldElsewhere(AInstance, AProp, Previous) then
          Previous.Free;
      end;
  else
    // Unmappable kinds cannot get here: SchemaFrom rejected them at
    // registration.
    Exit(Mismatch(APath, 'a supported type', AError));
  end;
end;

// BindProperty for a member or item that may be stored as nil, which
// is a JSON null and goes through the same checks as a parsed one.
function BindValue(AInstance: TMCPArgs; AProp: PPropInfo; AValue: TJSONData;
  const APath: string; ADepth: Integer; out AError: string): Boolean;
var
  Null: TJSONNull;
begin
  if AValue <> nil then
    Exit(BindProperty(AInstance, AProp, AValue, APath, ADepth, AError));
  Null := TJSONNull.Create;
  try
    Result := BindProperty(AInstance, AProp, Null, APath, ADepth, AError);
  finally
    Null.Free;
  end;
end;

function BindObject(AClass: TMCPArgsClass; AArguments: TJSONObject;
  const APrefix: string; ADepth: Integer; out AInstance: TMCPArgs;
  out AError: string): Boolean;
var
  Info: PTypeInfo;
  Props: PPropList;
  Count, I, Index: Integer;
  Value: TJSONData;
begin
  Result := False;
  AError := '';
  AInstance := nil;
  // The same bound SchemaFrom puts on registered classes, for direct
  // callers too.
  if ADepth > MAX_NESTING then
    raise EMCPSchema.CreateFmt('Argument classes nest deeper than %d ' +
      'levels at "%s"', [MAX_NESTING, APrefix]);
  AInstance := AClass.Create;
  Info := PTypeInfo(AClass.ClassInfo);
  Count := GetTypeData(Info)^.PropCount;
  if Count = 0 then
    Exit(True);
  GetMem(Props, Count * SizeOf(Pointer));
  try
    GetPropInfos(Info, Props);
    for I := 0 to Count - 1 do
    begin
      // A present null is a value, not an omission: for a nested object
      // it fails the type check like any other non-object (#95 review).
      // MemberIndex also sees a member stored as nil, a built null.
      Index := MemberIndex(AArguments, Props^[I]^.Name);
      if Index < 0 then
      begin
        // The `default` directive is streaming metadata, not field
        // initialization — seed it explicitly. `stored False`
        // properties simply stay zero-initialized.
        if MCPPropHasDefault(Props^[I]) then
          SetOrdProp(AInstance, Props^[I], Props^[I]^.Default)
        else if IsStoredProp(AInstance, Props^[I]) then
        begin
          AError := Format('Missing required argument "%s"',
            [JoinPath(APrefix, Props^[I]^.Name)]);
          Exit(False);
        end;
        Continue;
      end;
      Value := AArguments.Items[Index];
      if not BindValue(AInstance, Props^[I], Value,
        JoinPath(APrefix, Props^[I]^.Name), ADepth, AError) then
        Exit(False);
    end;
    Result := True;
  finally
    FreeMem(Props);
    if not Result then
      FreeAndNil(AInstance);
  end;
end;

function MCPBindArguments(AClass: TMCPArgsClass; AArguments: TJSONObject;
  out AInstance: TMCPArgs; out AError: string): Boolean;
begin
  Result := BindObject(AClass, AArguments, '', 0, AInstance, AError);
end;


{ ───────── the enforced schema subset (#91) ───────── }

function IsSubsetType(const AType: string): Boolean;
begin
  Result := (AType = 'object') or (AType = 'array') or (AType = 'string') or
    (AType = 'number') or (AType = 'integer') or (AType = 'boolean') or
    (AType = 'null');
end;

function IsPrimitiveType(const AType: string): Boolean;
begin
  Result := (AType <> 'object') and (AType <> 'array');
end;

// 'property "a.b" ' for a nested node, '' for the root.
function NodeLabel(const APath: string): string;
begin
  if APath = '' then
    Result := ''
  else
    Result := 'property "' + APath + '" ';
end;

function JoinPath(const APath, AName: string): string;
begin
  if APath = '' then
    Result := AName
  else
    Result := APath + '.' + AName;
end;

function NodeViolation(ANode: TJSONObject; const APath: string;
  ARoot, AInput: Boolean): string; forward;

// True for a $schema value naming JSON Schema 2020-12, the dialect the
// subset's rules come from.
function IsDefaultDialect(AValue: TJSONData): Boolean;
var
  Uri: string;
begin
  if AValue.JSONType <> jtString then
    Exit(False);
  Uri := AValue.AsString;
  if (Uri <> '') and (Uri[Length(Uri)] = '#') then
    SetLength(Uri, Length(Uri) - 1);
  Result := (Uri = 'https://json-schema.org/draft/2020-12/schema') or
    (Uri = 'http://json-schema.org/draft/2020-12/schema');
end;

// properties: an object of node schemas, each checked in turn.
function PropertiesViolation(AValue: TJSONData; const APath: string;
  AInput: Boolean): string;
var
  I: Integer;
  Member: TJSONData;
begin
  if AValue.JSONType <> jtObject then
    Exit(NodeLabel(APath) + 'properties must be an object');
  for I := 0 to AValue.Count - 1 do
  begin
    Member := TJSONObject(AValue).Items[I];
    if (Member = nil) or (Member.JSONType <> jtObject) then
      Exit(Format('property "%s" must be an object schema',
        [JoinPath(APath, TJSONObject(AValue).Names[I])]));
    Result := NodeViolation(TJSONObject(Member),
      JoinPath(APath, TJSONObject(AValue).Names[I]), False, AInput);
    if Result <> '' then
      Exit;
  end;
  Result := '';
end;

type
  TJSONTypeSet = set of TJSONType;

// True when every item of AValue (an array) is non-nil with a JSON
// type in ATypes; AAllowNil lets a nil item (written as null) pass.
function ItemsOfTypes(AValue: TJSONData; ATypes: TJSONTypeSet;
  AAllowNil: Boolean): Boolean;
var
  I: Integer;
begin
  for I := 0 to AValue.Count - 1 do
    if AValue.Items[I] = nil then
    begin
      if not AAllowNil then
        Exit(False);
    end
    else if not (AValue.Items[I].JSONType in ATypes) then
      Exit(False);
  Result := True;
end;

// The annotation keywords any node may carry; False when Key is none.
function AnnotationViolation(const AKey: string; AValue: TJSONData;
  const APath: string; ARoot, AInput: Boolean;
  out AViolation: string): Boolean;
begin
  AViolation := '';
  Result := True;
  if (AKey = 'description') or (AKey = 'title') then
  begin
    if AValue.JSONType <> jtString then
      AViolation := NodeLabel(APath) + AKey + ' must be a string';
  end
  else if ARoot and (AKey = '$schema') then
  begin
    if not IsDefaultDialect(AValue) then
      AViolation := 'declares $schema other than JSON Schema 2020-12';
  end
  else
    // x-mcp-header names a routing header in an input schema; it does
    // not constrain the value, and MCPHeaderParameters checks its own
    // rules (#90). Anywhere else it stays outside the subset.
    Result := (AKey = 'type') or (AInput and (AKey = 'x-mcp-header'));
end;

const
  PRIMITIVE_JSON: TJSONTypeSet = [jtString, jtNumber, jtBoolean, jtNull];

// The keyword ANode[AIndex] is allowed for a node of AType.
function KeywordViolation(ANode: TJSONObject; AIndex: Integer;
  const AType, APath: string; ARoot, AInput: Boolean): string;
var
  Key: string;
  Value: TJSONData;
begin
  Result := '';
  Key := ANode.Names[AIndex];
  Value := ANode.Items[AIndex];
  if Value = nil then
    Exit(NodeLabel(APath) + Key + ' must not be nil');
  if AnnotationViolation(Key, Value, APath, ARoot, AInput, Result) then
    Exit;
  if (Key = 'properties') and (AType = 'object') then
    Result := PropertiesViolation(Value, APath, AInput)
  else if (Key = 'required') and (AType = 'object') then
  begin
    if Value.JSONType <> jtArray then
      Result := NodeLabel(APath) + 'required must be an array'
    else if not ItemsOfTypes(Value, [jtString], False) then
      Result := NodeLabel(APath) + 'required must list property names';
  end
  else if (Key = 'items') and (AType = 'array') then
  begin
    if Value.JSONType <> jtObject then
      Exit(NodeLabel(APath) + 'items must be an object schema');
    Result := NodeViolation(TJSONObject(Value), APath + '[]', False, AInput);
  end
  else if (Key = 'enum') and IsPrimitiveType(AType) then
  begin
    // Entries of another type are allowed, as before #91: they can
    // never match a value of the declared type.
    if Value.JSONType <> jtArray then
      Result := NodeLabel(APath) + 'enum must be an array';
  end
  else if (Key = 'default') and IsPrimitiveType(AType) then
  begin
    if not (Value.JSONType in PRIMITIVE_JSON) then
      Result := NodeLabel(APath) + 'default must be a primitive';
  end
  else
    Result := NodeLabel(APath) + 'uses unsupported keyword "' + Key + '"';
end;

function NodeViolation(ANode: TJSONObject; const APath: string;
  ARoot, AInput: Boolean): string;
var
  TypeData: TJSONData;
  NodeType: string;
  I: Integer;
begin
  TypeData := ANode.Find('type');
  if (TypeData = nil) or (TypeData.JSONType <> jtString) or
    not IsSubsetType(TypeData.AsString) then
  begin
    if (TypeData <> nil) and (TypeData.JSONType = jtString) then
      Exit(NodeLabel(APath) + 'has unsupported type "' +
        TypeData.AsString + '"');
    Exit(NodeLabel(APath) + 'needs a single "type"');
  end;
  NodeType := TypeData.AsString;
  for I := 0 to ANode.Count - 1 do
  begin
    Result := KeywordViolation(ANode, I, NodeType, APath, ARoot, AInput);
    if Result <> '' then
      Exit;
  end;
  Result := '';
end;

function MCPSchemaSubsetViolation(ASchema: TJSONObject;
  AObjectRoot: Boolean): string;
begin
  if ASchema = nil then
    Exit('is missing');
  if AObjectRoot and (ASchema.Get('type', '') <> 'object') then
    Exit('must have root type "object"');
  Result := NodeViolation(ASchema, '', True, AObjectRoot);
end;

// 'a string', 'an integer', ... for messages.
function TypePhrase(const AType: string): string;
begin
  if (AType = 'integer') or (AType = 'object') or (AType = 'array') then
    Result := 'an ' + AType
  else if AType = 'null' then
    Result := 'null'
  else
    Result := 'a ' + AType;
end;

const
  // 2^53: past it a double no longer holds every integer, so a float
  // there cannot be told apart from its neighbours.
  MAX_EXACT_FLOAT_INTEGER = 9007199254740992.0;

// True for a finite double with no fractional part. Every double of
// magnitude 2^52 or more is integral, and Frac is not called on those:
// on AArch64 (FPC 3.2.2) it truncates through a 64-bit integer and
// raises an arithmetic overflow past 2^63.
function IsIntegralDouble(F: Double): Boolean;
begin
  if IsNan(F) or IsInfinite(F) then
    Exit(False);
  Result := (Abs(F) >= 4503599627370496.0) or (Frac(F) = 0);
end;

// JSON Schema's integer is a number with a zero fractional part
// (json-schema-validation 2020-12 §6.1.1, verified 2026-11-27), so 2.0
// and 2e0 count. Floats are accepted within +-2^53, where that is exact.
function IsIntegralNumber(AValue: TJSONData): Boolean;
var
  F: Double;
begin
  if TJSONNumber(AValue).NumberType in [ntInteger, ntInt64, ntQWord] then
    Exit(True);
  F := AValue.AsFloat;
  Result := (Abs(F) <= MAX_EXACT_FLOAT_INTEGER) and IsIntegralDouble(F);
end;

// True when the integer of magnitude AMagnitude (sign apart) is exact
// as a double: at most 53 significant bits. Bit tests only, so no
// float-to-integer conversion can trap (AArch64 raises on those).
function IsExactAsDouble(AMagnitude: QWord): Boolean;
var
  Bits: Integer;
  Probe: QWord;
begin
  Bits := 0;
  Probe := AMagnitude;
  while Probe <> 0 do
  begin
    Inc(Bits);
    Probe := Probe shr 1;
  end;
  if Bits <= 53 then
    Exit(True);
  Result := AMagnitude and ((QWord(1) shl (Bits - 53)) - 1) = 0;
end;

// Exact equality of two JSON numbers: integers compare as integers
// (no rounding through a double), floats as floats, and a float equals
// an integer when it is integral and the same value: the integer is
// exact as a double and converts to exactly that float.
function SameNumber(A, B: TJSONData): Boolean;
var
  IntA, IntB, Negative: Boolean;
  Integral, Other: TJSONData;
  Magnitude: QWord;
  Signed: Int64;
  F, Exact: Double;
begin
  IntA := TJSONNumber(A).NumberType in [ntInteger, ntInt64, ntQWord];
  IntB := TJSONNumber(B).NumberType in [ntInteger, ntInt64, ntQWord];
  if not IntA and not IntB then
    Exit(A.AsFloat = B.AsFloat);
  if IntA and IntB then
  begin
    // A QWord above High(Int64) equals only the same QWord.
    if (TJSONNumber(A).NumberType = ntQWord) or
      (TJSONNumber(B).NumberType = ntQWord) then
      Exit(A.AsJSON = B.AsJSON);
    Exit(A.AsInt64 = B.AsInt64);
  end;
  if IntA then
  begin
    Integral := A;
    Other := B;
  end
  else
  begin
    Integral := B;
    Other := A;
  end;
  F := Other.AsFloat;
  if not IsIntegralDouble(F) then
    Exit(False);
  // A QWord node holds small values too (CreateJSON(QWord(2))).
  if TJSONNumber(Integral).NumberType = ntQWord then
  begin
    Negative := False;
    Magnitude := Integral.AsQWord;
  end
  else
  begin
    Signed := Integral.AsInt64;
    Negative := Signed < 0;
    if Negative then
      Magnitude := QWord(-(Signed + 1)) + 1
    else
      Magnitude := QWord(Signed);
  end;
  if (Negative <> (F < 0)) or not IsExactAsDouble(Magnitude) then
    Exit((Magnitude = 0) and (F = 0));
  // An assignment converts (a Double(...) cast would reinterpret bits).
  Exact := Magnitude;
  Result := Exact = Abs(F);
end;

// A float node can hold NaN or an infinity, which has no JSON form.
function IsFiniteNumber(AValue: TJSONData): Boolean;
begin
  Result := (TJSONNumber(AValue).NumberType <> ntFloat) or
    (not IsNan(AValue.AsFloat) and not IsInfinite(AValue.AsFloat));
end;

const
  // The schema type each JSON type satisfies; 'integer' is checked apart.
  JSON_TYPE_NAMES: array[TJSONtype] of string = ('', 'number', 'string',
    'boolean', 'null', 'array', 'object');

// AValue nil is a member or item stored as nil, which fpjson writes as
// null: it is JSON null here too. AType is one of the subset's types.
function MatchesType(AValue: TJSONData; const AType: string): Boolean;
begin
  if AValue = nil then
    Exit(AType = 'null');
  if AType = 'integer' then
    Exit((AValue.JSONType = jtNumber) and IsIntegralNumber(AValue));
  Result := (AType <> '') and (JSON_TYPE_NAMES[AValue.JSONType] = AType) and
    ((AValue.JSONType <> jtNumber) or IsFiniteNumber(AValue));
end;
// Equal primitive JSON values: same JSON type and the same text (for
// numbers, the same numeric value).
function SamePrimitive(A, B: TJSONData): Boolean;
begin
  if (A = nil) or (B = nil) then
    Exit(((A = nil) or (A.JSONType = jtNull)) and
      ((B = nil) or (B.JSONType = jtNull)));
  if A.JSONType <> B.JSONType then
    Exit(False);
  case A.JSONType of
    jtNumber:
      Result := SameNumber(A, B);
    jtNull:
      Result := True;
  else
    Result := A.AsJSON = B.AsJSON;
  end;
end;

// 'Argument "a.b"' or 'Argument' (root) for the value at APath.
function Subject(const AKind, APath: string): string;
begin
  Result := UpperCase(Copy(AKind, 1, 1)) + Copy(AKind, 2, MaxInt);
  if APath <> '' then
    Result := Result + ' "' + APath + '"';
end;

function ValidateNode(ANode: TJSONObject; AValue: TJSONData;
  const AKind, APath: string; ASeedDefaults: Boolean;
  out AError: string): Boolean; forward;

// The index of member AName, -1 when absent. fpjson's IndexOfName
// misses a member stored as nil (FPC 3.2.2), which is a present null.
function MemberIndex(AObject: TJSONObject; const AName: string): Integer;
begin
  Result := AObject.IndexOfName(AName);
  if Result >= 0 then
    Exit;
  for Result := 0 to AObject.Count - 1 do
    if AObject.Names[Result] = AName then
      Exit;
  Result := -1;
end;

function ValidateMembers(ANode, AValue: TJSONObject;
  const AKind, APath: string; ASeedDefaults: Boolean;
  out AError: string): Boolean;
var
  Data, Member, DefaultData: TJSONData;
  Properties: TJSONObject;
  I, Index: Integer;
  Ignored: string;
begin
  Result := False;
  Data := ANode.Find('required');
  if (Data <> nil) and (Data.JSONType = jtArray) then
    for I := 0 to Data.Count - 1 do
      if (Data.Items[I].JSONType = jtString) and
        (MemberIndex(AValue, Data.Items[I].AsString) < 0) then
      begin
        AError := Format('Missing required %s "%s"',
          [AKind, JoinPath(APath, Data.Items[I].AsString)]);
        Exit;
      end;
  Data := ANode.Find('properties');
  if (Data <> nil) and (Data.JSONType = jtObject) then
  begin
    Properties := TJSONObject(Data);
    for I := 0 to Properties.Count - 1 do
    begin
      // Present (a nil member is a present null) versus absent.
      Index := MemberIndex(AValue, Properties.Names[I]);
      if Index < 0 then
      begin
        // Only a default that conforms is seeded, so the handler sees
        // a value its schema allows.
        DefaultData := TJSONObject(Properties.Items[I]).Find('default');
        if ASeedDefaults and (DefaultData <> nil) and
          ValidateNode(TJSONObject(Properties.Items[I]), DefaultData, AKind,
          '', False, Ignored) then
          AValue.Add(Properties.Names[I], DefaultData.Clone);
        Continue;
      end;
      Member := AValue.Items[Index];
      if not ValidateNode(TJSONObject(Properties.Items[I]), Member, AKind,
        JoinPath(APath, Properties.Names[I]), ASeedDefaults, AError) then
        Exit;
    end;
  end;
  Result := True;
end;

function ValidateNode(ANode: TJSONObject; AValue: TJSONData;
  const AKind, APath: string; ASeedDefaults: Boolean;
  out AError: string): Boolean;
var
  NodeType: string;
  EnumData, ItemSchema: TJSONData;
  I: Integer;
  Matched: Boolean;
begin
  Result := False;
  AError := '';
  NodeType := ANode.Get('type', '');
  if not MatchesType(AValue, NodeType) then
  begin
    AError := Subject(AKind, APath) + ' must be ' + TypePhrase(NodeType);
    Exit;
  end;
  EnumData := ANode.Find('enum');
  if (EnumData <> nil) and (EnumData.JSONType = jtArray) then
  begin
    Matched := False;
    for I := 0 to EnumData.Count - 1 do
      if SamePrimitive(EnumData.Items[I], AValue) then
        Matched := True;
    if not Matched then
    begin
      AError := Subject(AKind, APath) + ' must be ' + TypePhrase(NodeType) +
        ' from the declared enum values';
      Exit;
    end;
  end;
  if NodeType = 'object' then
    Exit(ValidateMembers(ANode, TJSONObject(AValue), AKind, APath,
      ASeedDefaults, AError));
  ItemSchema := ANode.Find('items');
  if (NodeType = 'array') and (ItemSchema <> nil) and
    (ItemSchema.JSONType = jtObject) then
    for I := 0 to AValue.Count - 1 do
      if not ValidateNode(TJSONObject(ItemSchema), AValue.Items[I], AKind,
        Format('%s[%d]', [APath, I]), ASeedDefaults, AError) then
        Exit;
  Result := True;
end;

// True when AValue holds a NaN or infinite float anywhere, which no
// JSON text can carry.
function HasNonFiniteNumber(AValue: TJSONData): Boolean;
var
  I: Integer;
begin
  if AValue = nil then
    Exit(False);
  case AValue.JSONType of
    jtNumber:
      Exit(not IsFiniteNumber(AValue));
    jtObject, jtArray:
      for I := 0 to AValue.Count - 1 do
        if HasNonFiniteNumber(AValue.Items[I]) then
          Exit(True);
  end;
  Result := False;
end;

function MCPValidateAgainstSchema(ASchema: TJSONObject; AValue: TJSONData;
  const AKind: string; ASeedDefaults: Boolean; out AError: string): Boolean;
begin
  Result := ValidateNode(ASchema, AValue, AKind, '', ASeedDefaults, AError);
  // Parts no keyword constrains (items of an array without "items",
  // members no property names) must still be writable JSON.
  if Result and HasNonFiniteNumber(AValue) then
  begin
    AError := Subject(AKind, '') + ' contains a NaN or infinite number';
    Result := False;
  end;
end;


{ ───────── x-mcp-header annotations (#90) ───────── }

const
  HEADER_KEYWORD = 'x-mcp-header';

function IsTokenChar(AChar: Char): Boolean;
begin
  Result := AChar in ['!', '#', '$', '%', '&', '''', '*', '+', '-', '.',
    '^', '_', '`', '|', '~', '0'..'9', 'A'..'Z', 'a'..'z'];
end;

function IsHeaderToken(const AValue: string): Boolean;
var
  I: Integer;
begin
  Result := AValue <> '';
  for I := 1 to Length(AValue) do
    if not IsTokenChar(AValue[I]) then
      Exit(False);
end;

const
  // Marks a path segment that is a subschema array index, not a name.
  INDEX_MARK = #1;

function IndexSegment(AIndex: Integer): string;
begin
  Result := INDEX_MARK + IntToStr(AIndex);
end;

// The path for messages: names joined by dots, a name holding a dot,
// bracket, quote or nothing quoted as ["..."], and array branches as
// [n], so a literal key "a.b" and the nesting a -> b differ.
function PathText(const APath: array of string): string;
var
  I: Integer;
  Segment: string;
begin
  Result := '';
  for I := 0 to High(APath) do
  begin
    Segment := APath[I];
    if (Segment <> '') and (Segment[1] = INDEX_MARK) then
      Result := Result + '[' + Copy(Segment, 2, MaxInt) + ']'
    else if (Segment = '') or (Pos('.', Segment) > 0) or
      (Pos('[', Segment) > 0) or (Pos('"', Segment) > 0) then
      Result := Result + '["' + StringReplace(Segment, '"', '\"',
        [rfReplaceAll]) + '"]'
    else
    begin
      if I > 0 then
        Result := Result + '.';
      Result := Result + Segment;
    end;
  end;
end;

function ExtendPath(const APath: array of string;
  const AName: string): TStringArray;
var
  I: Integer;
begin
  SetLength(Result, Length(APath) + 1);
  for I := 0 to High(APath) do
    Result[I] := APath[I];
  Result[High(Result)] := AName;
end;

// One annotation on the node at APath, which is a property reachable
// through "properties" alone (AReachable) or not.
function CheckAnnotation(ANode: TJSONObject; const APath: array of string;
  AReachable: Boolean; var AParameters: TMCPHeaderParameters): string;
var
  Value: TJSONData;
  ParamType: string;
  I, Slot: Integer;
begin
  Result := '';
  Value := ANode.Find(HEADER_KEYWORD);
  if not AReachable or (Length(APath) = 0) then
    Exit(Format('x-mcp-header at "%s" is not on a property reachable ' +
      'through "properties" from the root', [PathText(APath)]));
  if (Value.JSONType <> jtString) or not IsHeaderToken(Value.AsString) then
    Exit(Format('x-mcp-header of "%s" must be a non-empty HTTP token',
      [PathText(APath)]));
  ParamType := ANode.Get('type', '');
  if (ParamType <> 'string') and (ParamType <> 'integer') and
    (ParamType <> 'boolean') then
    Exit(Format('x-mcp-header of "%s" needs type string, integer or ' +
      'boolean, not "%s"', [PathText(APath), ParamType]));
  for I := 0 to High(AParameters) do
    if SameText(AParameters[I].Header, Value.AsString) then
      Exit(Format('x-mcp-header "%s" is used twice, at "%s" and "%s" ' +
        '(headers compare case-insensitively)', [Value.AsString,
        PathText(AParameters[I].Path), PathText(APath)]));
  Slot := Length(AParameters);
  SetLength(AParameters, Slot + 1);
  AParameters[Slot].Header := Value.AsString;
  AParameters[Slot].ParamType := ParamType;
  SetLength(AParameters[Slot].Path, Length(APath));
  for I := 0 to High(APath) do
    AParameters[Slot].Path[I] := APath[I];
end;

type
  TSchemaKeywordKind = (skNone, skSubschema, skSubschemaArray, skSubschemaMap);

// How a JSON Schema 2020-12 keyword holds subschemas (plus the draft
// names "definitions", "additionalItems" and "dependencies"). Other
// keywords, such as examples, enum, const and default, hold data,
// never annotations.
function SchemaKeywordKind(const AKey: string): TSchemaKeywordKind;
begin
  if (AKey = 'items') or (AKey = 'additionalProperties') or (AKey = 'not') or
    (AKey = 'if') or (AKey = 'then') or (AKey = 'else') or
    (AKey = 'contains') or (AKey = 'propertyNames') or
    (AKey = 'unevaluatedItems') or (AKey = 'unevaluatedProperties') or
    (AKey = 'additionalItems') or (AKey = 'contentSchema') then
    Result := skSubschema
  else if (AKey = 'allOf') or (AKey = 'anyOf') or (AKey = 'oneOf') or
    (AKey = 'prefixItems') then
    Result := skSubschemaArray
  else if (AKey = 'properties') or (AKey = 'patternProperties') or
    (AKey = '$defs') or (AKey = 'definitions') or
    (AKey = 'dependentSchemas') or (AKey = 'dependencies') then
    // draft-07 "dependencies" maps to schemas or to name arrays; only an
    // object entry is visited, an array of names is data.
    Result := skSubschemaMap
  else
    Result := skNone;
end;

function CollectHeaders(AData: TJSONData; const APath: array of string;
  AReachable: Boolean; var AParameters: TMCPHeaderParameters): string;
  forward;

// The subschemas AValue holds for a keyword of AKind, each under
// APath.AKey; only "properties" keeps the reachable chain going.
function CollectFromKeyword(const AKey: string; AValue: TJSONData;
  AKind: TSchemaKeywordKind; const APath: array of string;
  AReachable: Boolean; var AParameters: TMCPHeaderParameters): string;
var
  I: Integer;
begin
  Result := '';
  case AKind of
    skSubschema:
      if AValue.JSONType = jtArray then // items as an array (drafts)
        Result := CollectFromKeyword(AKey, AValue, skSubschemaArray, APath,
          False, AParameters)
      else
        Result := CollectHeaders(AValue, ExtendPath(APath, AKey), False,
          AParameters);
    skSubschemaArray:
      if AValue.JSONType = jtArray then
        for I := 0 to AValue.Count - 1 do
        begin
          Result := CollectHeaders(AValue.Items[I],
            ExtendPath(ExtendPath(APath, AKey), IndexSegment(I)), False,
            AParameters);
          if Result <> '' then
            Exit;
        end;
    skSubschemaMap:
      if AValue.JSONType = jtObject then
        for I := 0 to AValue.Count - 1 do
        begin
          // properties is the one chain along which annotations are
          // allowed; $defs, patternProperties and the rest are not.
          if (AKey = 'properties') and AReachable then
            Result := CollectHeaders(AValue.Items[I],
              ExtendPath(APath, TJSONObject(AValue).Names[I]), AReachable,
              AParameters)
          else
            Result := CollectHeaders(AValue.Items[I],
              ExtendPath(ExtendPath(APath, AKey),
              TJSONObject(AValue).Names[I]), False, AParameters);
          if Result <> '' then
            Exit;
        end;
  end;
end;

function CollectHeaders(AData: TJSONData; const APath: array of string;
  AReachable: Boolean; var AParameters: TMCPHeaderParameters): string;
var
  I: Integer;
  Obj: TJSONObject;
  Kind: TSchemaKeywordKind;
begin
  Result := '';
  // A nil child (programmatic schemas) holds no schema.
  if (AData = nil) or (AData.JSONType <> jtObject) then
    Exit;
  Obj := TJSONObject(AData);
  if Obj.Find(HEADER_KEYWORD) <> nil then
  begin
    Result := CheckAnnotation(Obj, APath, AReachable, AParameters);
    if Result <> '' then
      Exit;
  end;
  for I := 0 to Obj.Count - 1 do
  begin
    Kind := SchemaKeywordKind(Obj.Names[I]);
    if (Kind = skNone) or (Obj.Items[I] = nil) then
      Continue;
    Result := CollectFromKeyword(Obj.Names[I], Obj.Items[I], Kind, APath,
      AReachable, AParameters);
    if Result <> '' then
      Exit;
  end;
end;

function MCPHeaderParameters(ASchema: TJSONObject;
  out AParameters: TMCPHeaderParameters): string;
begin
  AParameters := nil;
  if ASchema = nil then
    Exit('');
  Result := CollectHeaders(ASchema, [], True, AParameters);
  if Result <> '' then
    AParameters := nil;
end;

function CopyHeaderParameters(
  const AParameters: TMCPHeaderParameters): TMCPHeaderParameters;
var
  I: Integer;
begin
  Result := Copy(AParameters);
  for I := 0 to High(Result) do
    Result[I].Path := Copy(AParameters[I].Path);
end;

end.
