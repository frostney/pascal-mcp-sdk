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

{$I Shared.inc}

interface

uses
  SysUtils,
  typinfo,

  fpjson;

type
  EMCPSchema = class(Exception);

  // Base class for argument types: {$M+} turns on published-property
  // RTTI for every descendant. Constructor kept virtual so the server
  // can instantiate argument objects from a class reference.
  {$M+}
  TMCPArgs = class(TObject)
  public
    constructor Create; virtual;
  end;
  {$M-}

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

implementation

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
    GetPropInfos(Info, Props);
    for I := 0 to Count - 1 do
    begin
      Prop := Props^[I];
      case Prop^.PropType^.Kind of
        tkSString, tkLString, tkAString, tkWString, tkUString:
          Result.Add(Prop^.Name, GetStrProp(AObj, Prop));
        tkFloat:
          Result.Add(Prop^.Name, GetFloatProp(AObj, Prop));
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
        begin
          Result.Free;
          raise EMCPSchema.CreateFmt(
            'Property "%s" of %s has no JSON mapping',
            [Prop^.Name, AObj.ClassName]);
        end;
      end;
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
