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
  public
    function AddString(const AName: string; const ADescription: string = '';
      ARequired: Boolean = True): TMCPSchema;
    function AddNumber(const AName: string; const ADescription: string = '';
      ARequired: Boolean = True): TMCPSchema;
    function AddInteger(const AName: string; const ADescription: string = '';
      ARequired: Boolean = True): TMCPSchema;
    function AddBoolean(const AName: string; const ADescription: string = '';
      ARequired: Boolean = True): TMCPSchema;

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

function SchemaFrom(AClass: TMCPArgsClass): TMCPSchema;
var
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
          '(supported: string, float, integer, boolean, enum)',
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

// Shortest decimal for a finite, non-zero AValue that parses back to
// the same Double, as JSNumberText writes it; '' when none does.
// System.Str gives 17 significant digits of a Double on every target
// (FloatToStrF stops at 15 where Extended is Double, as on Win64 and
// AArch64); each shorter candidate is that decimal rounded to fewer
// digits, and only a candidate that Val parses back into a Double
// equal to AValue is returned. (Where Val parses through Extended, a
// shorter candidate lying within 2^-64 of a halfway point between two
// Doubles could be rounded twice; the 17-digit candidate is too close
// to AValue for that.)
function ShortestRoundTrip(AValue: Double): string;
var
  S, Mantissa, Candidate: string;
  Negative: Boolean;
  EPos, Exponent, Count, I, Code: Integer;
  Digits: array[1..17] of Byte;
  Back: Double;
begin
  Result := '';
  // ' d.dddddddddddddddE+ddd' (one sign position, 17 digits).
  Str(AValue:24, S);
  S := Trim(S);
  Negative := (S <> '') and (S[1] = '-');
  if Negative then
    Delete(S, 1, 1);
  EPos := Pos('E', S);
  if (EPos <> 19) or (S[2] <> '.') then
    Exit;
  Mantissa := S[1] + Copy(S, 3, 16);
  Val(Copy(S, EPos + 1, MaxInt), Exponent, Code);
  if Code <> 0 then
    Exit;
  for Count := 1 to 17 do
  begin
    for I := 1 to 17 do
      Digits[I] := Ord(Mantissa[I]) - Ord('0');
    // Round the 17-digit decimal half up at Count digits; a carry out
    // of the first digit becomes 1 x 10^(Exponent + 1).
    Candidate := '';
    if (Count < 17) and (Digits[Count + 1] >= 5) then
    begin
      I := Count;
      while (I >= 1) and (Digits[I] = 9) do
      begin
        Digits[I] := 0;
        Dec(I);
      end;
      if I >= 1 then
        Inc(Digits[I])
      else
        Candidate := '1';
    end;
    if Candidate = '1' then
      Candidate := JSNumberText(Negative, '1', Exponent + 1)
    else
    begin
      for I := 1 to Count do
        Candidate := Candidate + Chr(Ord('0') + Digits[I]);
      while (Length(Candidate) > 1) and (Candidate[Length(Candidate)] = '0') do
        Delete(Candidate, Length(Candidate), 1);
      Candidate := JSNumberText(Negative, Candidate, Exponent);
    end;
    // A candidate rounded past the largest Double overflows on the way
    // back: it does not round-trip, so try the next length.
    try
      Val(Candidate, Back, Code);
    except
      on EMathError do
        Code := -1;
    end;
    if (Code = 0) and (Back = AValue) then
      Exit(Candidate);
  end;
end;

function TMCPWireFloat.GetAsString: TJSONStringType;
begin
  Result := ShortestRoundTrip(AsFloat);
  // No candidate parsed back exactly (a parser that does not round
  // correctly): fpjson's full-precision form, never an unchecked one.
  if Result = '' then
    Result := inherited GetAsString;
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
            Result.Add(Prop^.Name, MCPWireNumber(GetFloatProp(AObj, Prop)));
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
  Result := Self;
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
end;

end.
