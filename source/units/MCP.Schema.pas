unit MCP.Schema;

// Tool schemas expressed as Pascal instead of hand-written JSON
// strings — a JSON Schema 2020-12 subset (type/properties/
// description/required) via two paths:
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
//    names as allowed values. All published properties are required.
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
// with no JSON Schema mapping (objects, arrays, sets, ...).
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
        if Props^[I]^.PropType^.Kind = tkClass then
        begin
          Nested := GetObjectProp(Self, Props^[I]);
          if Nested is TMCPArgs then
          begin
            Nested.Free;
          end;
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
            ItemType := ArrayItemType(Prop^.PropType);
            if ItemType = '' then
              raise EMCPSchema.CreateFmt('Array property "%s" of %s has ' +
                'no JSON Schema mapping (element types: string, Integer, ' +
                'Int64, Double, Boolean)', [Prop^.Name, AClass.ClassName]);
            if ItemType = 'int64' then
              ItemType := 'integer';
            Result := Result.AddArray(Prop^.Name, ItemType, '', Req);
          end;
        tkClass:
          begin
            if not GetTypeData(Prop^.PropType)^.ClassType.InheritsFrom(
              TMCPArgs) then
              raise EMCPSchema.CreateFmt('Object property "%s" of %s must ' +
                'be a TMCPArgs descendant', [Prop^.Name, AClass.ClassName]);
            if ADepth >= MAX_NESTING then
              raise EMCPSchema.CreateFmt('Argument classes nest deeper ' +
                'than %d levels at "%s" of %s', [MAX_NESTING, Prop^.Name,
                AClass.ClassName]);
            Result := Result.AddPropertySchema(Prop^.Name, NestedSchema(
              TMCPArgsClass(GetTypeData(Prop^.PropType)^.ClassType),
              ADepth + 1), '', Req);
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
  // the way JavaScript does.
  if (Frac(AValue) = 0) and (Abs(AValue) < 9007199254740992.0) then
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
  Result := TJSONArray.Create;
  Raw := GetDynArrayProp(AObj, AProp);
  ItemType := ArrayItemType(AProp^.PropType);
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
end;

function MCPSerialize(AObj: TMCPArgs): TJSONObject;
var
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
            // An absent (nil) nested object is left out.
            if GetObjectProp(AObj, Prop) is TMCPArgs then
              Result.Add(Prop^.Name,
                MCPSerialize(TMCPArgs(GetObjectProp(AObj, Prop))));
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
  Core: TMCPSchemaCore;
  Prop: TJSONObject;
begin
  Core := ActiveCore;
  if Core.FProperties.IndexOfName(AName) >= 0 then
    raise EMCPSchema.CreateFmt(
      'Schema property "%s" is already defined', [AName]);
  Prop := TJSONObject.Create;
  Prop.Add('type', AJsonType);
  if ADescription <> '' then
    Prop.Add('description', ADescription);
  Core.FProperties.Add(AName, Prop);
  if ARequired then
    Core.FRequired.Add(AName);
  Core.FLast := Prop;
  Core.FLastName := AName;
  Result := Self;
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
  Prop: TJSONObject;
begin
  Prop := TJSONObject.Create;
  Prop.Add('type', 'array');
  Prop.Add('items', AItems.Build);
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
begin
  Core := FCore;
  if (Core = nil) or (Core.FRoot = nil) or (Core.FLast = nil) then
  begin
    AValue.Free;
    if (Core <> nil) and (Core.FRoot <> nil) then
      raise EMCPSchema.Create('WithDefault needs a property added before it');
    Core := ActiveCore; // raises
  end;
  if Core.FLast.Get('type', '') = 'object' then
  begin
    AValue.Free;
    raise EMCPSchema.CreateFmt('Property "%s" is an object; defaults ' +
      'apply to primitive properties', [Core.FLastName]);
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
  const APrefix: string; out AInstance: TMCPArgs;
  out AError: string): Boolean; forward;

function ArgumentPath(const APrefix, AName: string): string;
begin
  if APrefix = '' then
    Result := AName
  else
    Result := APrefix + '.' + AName;
end;

function ReadSignedInteger(AValue: TJSONData; out AResult: Int64): Boolean;
var
  UnsignedValue: QWord;
begin
  Result := (AValue.JSONType = jtNumber) and
    (TJSONNumber(AValue).NumberType in [ntInteger, ntInt64, ntQWord]);
  if not Result then
    Exit;
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
  Result := (AValue.JSONType = jtNumber) and
    (TJSONNumber(AValue).NumberType in [ntInteger, ntInt64, ntQWord]);
  if not Result then
    Exit;
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

// A JSON array into a published dynamic array of one of the supported
// element types (see ArrayItemType).
function BindArray(AInstance: TMCPArgs; AProp: PPropInfo; AValue: TJSONData;
  const APath: string; out AError: string): Boolean;
var
  Strings: array of string;
  Integers: array of LongInt;
  Int64s: array of Int64;
  Doubles: array of Double;
  Booleans: array of Boolean;
  Item: TJSONData;
  ItemType: string;
  I: Integer;
  Signed: Int64;
begin
  Result := True;
  if AValue.JSONType <> jtArray then
    Exit(Mismatch(APath, 'an array', AError));
  ItemType := ArrayItemType(AProp^.PropType);
  SetLength(Strings, 0);
  for I := 0 to AValue.Count - 1 do
  begin
    Item := AValue.Items[I];
    if ItemType = 'string' then
    begin
      if Item.JSONType <> jtString then
        Exit(Mismatch(Format('%s[%d]', [APath, I]), 'a string', AError));
      SetLength(Strings, I + 1);
      Strings[I] := Item.AsString;
    end
    else if ItemType = 'number' then
    begin
      if Item.JSONType <> jtNumber then
        Exit(Mismatch(Format('%s[%d]', [APath, I]), 'a number', AError));
      SetLength(Doubles, I + 1);
      Doubles[I] := Item.AsFloat;
    end
    else if ItemType = 'boolean' then
    begin
      if Item.JSONType <> jtBoolean then
        Exit(Mismatch(Format('%s[%d]', [APath, I]), 'a boolean', AError));
      SetLength(Booleans, I + 1);
      Booleans[I] := Item.AsBoolean;
    end
    else
    begin
      if not ReadSignedInteger(Item, Signed) or ((ItemType = 'integer') and
        ((Signed < Low(LongInt)) or (Signed > High(LongInt)))) then
        Exit(Mismatch(Format('%s[%d]', [APath, I]), 'an integer', AError));
      if ItemType = 'integer' then
      begin
        SetLength(Integers, I + 1);
        Integers[I] := LongInt(Signed);
      end
      else
      begin
        SetLength(Int64s, I + 1);
        Int64s[I] := Signed;
      end;
    end;
  end;
  if ItemType = 'string' then
    SetDynArrayProp(AInstance, AProp, Pointer(Strings))
  else if ItemType = 'number' then
    SetDynArrayProp(AInstance, AProp, Pointer(Doubles))
  else if ItemType = 'boolean' then
    SetDynArrayProp(AInstance, AProp, Pointer(Booleans))
  else if ItemType = 'integer' then
    SetDynArrayProp(AInstance, AProp, Pointer(Integers))
  else
    SetDynArrayProp(AInstance, AProp, Pointer(Int64s));
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

// Populate one published property from its JSON argument. False (with
// AError set) on a type mismatch. APath names the argument in errors.
function BindProperty(AInstance: TMCPArgs; AProp: PPropInfo;
  AValue: TJSONData; const APath: string; out AError: string): Boolean;
var
  TypeData: PTypeData;
  SignedValue: Int64;
  UnsignedValue, Minimum, Maximum: QWord;
  Nested: TMCPArgs;
begin
  Result := True;
  case AProp^.PropType^.Kind of
    tkSString, tkLString, tkAString, tkWString, tkUString:
      if AValue.JSONType = jtString then
        SetStrProp(AInstance, AProp, AValue.AsString)
      else
        Exit(Mismatch(APath, 'a string', AError));
    tkFloat:
      if AValue.JSONType = jtNumber then
        SetFloatProp(AInstance, AProp, AValue.AsFloat)
      else
        Exit(Mismatch(APath, 'a number', AError));
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
      if ReadSignedInteger(AValue, SignedValue) then
        SetInt64Prop(AInstance, AProp, SignedValue)
      else
        Exit(Mismatch(APath, 'an integer', AError));
    tkQWord:
      if ReadUnsignedInteger(AValue, UnsignedValue) then
        SetQWordProperty(AInstance, AProp, UnsignedValue)
      else
        Exit(Mismatch(APath, 'an integer', AError));
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
        if AValue.JSONType <> jtObject then
          Exit(Mismatch(APath, 'an object', AError));
        if not BindObject(TMCPArgsClass(GetTypeData(AProp^.PropType)^.ClassType),
          TJSONObject(AValue), APath, Nested, AError) then
          Exit(False);
        SetObjectProp(AInstance, AProp, Nested);
      end;
  else
    // Unmappable kinds cannot get here: SchemaFrom rejected them at
    // registration.
    Exit(Mismatch(APath, 'a supported type', AError));
  end;
end;

function BindObject(AClass: TMCPArgsClass; AArguments: TJSONObject;
  const APrefix: string; out AInstance: TMCPArgs;
  out AError: string): Boolean;
var
  Info: PTypeInfo;
  Props: PPropList;
  Count, I: Integer;
  Value: TJSONData;
begin
  Result := False;
  AError := '';
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
      Value := AArguments.Find(Props^[I]^.Name);
      if (Value = nil) or ((Value.JSONType = jtNull) and
        (Props^[I]^.PropType^.Kind = tkClass)) then
      begin
        // The `default` directive is streaming metadata, not field
        // initialization — seed it explicitly. `stored False`
        // properties simply stay zero-initialized.
        if MCPPropHasDefault(Props^[I]) then
          SetOrdProp(AInstance, Props^[I], Props^[I]^.Default)
        else if IsStoredProp(AInstance, Props^[I]) then
        begin
          AError := Format('Missing required argument "%s"',
            [ArgumentPath(APrefix, Props^[I]^.Name)]);
          Exit(False);
        end;
        Continue;
      end;
      if not BindProperty(AInstance, Props^[I], Value,
        ArgumentPath(APrefix, Props^[I]^.Name), AError) then
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
  Result := BindObject(AClass, AArguments, '', AInstance, AError);
end;

end.
