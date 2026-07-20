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
//    Classes, not records: FPC 3.2.2 RTTI does not expose field names
//    for plain records (only managed-field layout), and Delphi-style
//    extended RTTI/attributes are not available — published class
//    properties are the one reflection surface the compiler
//    guarantees, the same one fpjsonrtti streaming builds on. For
//    per-property descriptions use the fluent builder; RTTI carries
//    no place to put them.
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

  // Record copies share the underlying JSON objects, so chaining and
  // reassigning both mutate the same schema-in-progress. Build is
  // called exactly once per schema (the registration overloads own
  // that call); a schema that is never built leaks its objects, so
  // build what you create.
  TMCPSchema = record
  private
    FRoot: TJSONObject;
    FProperties: TJSONObject; // borrowed: owned by FRoot
    FRequired: TJSONArray;    // owned here until Build attaches it
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
function SchemaFrom(AClass: TMCPArgsClass): TMCPSchema;

implementation

constructor TMCPArgs.Create;
begin
  inherited Create;
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
begin
  Result := ObjectSchema;
  Info := PTypeInfo(AClass.ClassInfo);
  Count := GetTypeData(Info)^.PropCount;
  if Count = 0 then
    Exit;
  GetMem(Props, Count * SizeOf(Pointer));
  try
    // GetPropInfos preserves declaration order — the deterministic
    // ordering the rest of the library already promises.
    GetPropInfos(Info, Props);
    for I := 0 to Count - 1 do
    begin
      Prop := Props^[I];
      case Prop^.PropType^.Kind of
        tkSString, tkLString, tkAString, tkWString, tkUString:
          Result := Result.AddString(Prop^.Name);
        tkFloat:
          Result := Result.AddNumber(Prop^.Name);
        tkInteger, tkInt64, tkQWord:
          Result := Result.AddInteger(Prop^.Name);
        tkBool:
          Result := Result.AddBoolean(Prop^.Name);
        tkEnumeration:
          begin
            // Enums map to a string with the enum names as the
            // allowed values.
            Result := Result.AddString(Prop^.Name);
            EnumInfo := Prop^.PropType;
            EnumValues := TJSONArray.Create;
            for E := GetTypeData(EnumInfo)^.MinValue to
              GetTypeData(EnumInfo)^.MaxValue do
              EnumValues.Add(GetEnumName(EnumInfo, E));
            PropObj := TJSONObject(Result.FProperties.Find(Prop^.Name));
            PropObj.Add('enum', EnumValues);
          end;
      else
        begin
          // Free the half-built schema before failing registration.
          Result.FRequired.Free;
          Result.FRoot.Free;
          raise EMCPSchema.CreateFmt(
            'Property "%s" of %s has no JSON Schema mapping ' +
            '(supported: string, float, integer, boolean, enum)',
            [Prop^.Name, AClass.ClassName]);
        end;
      end;
    end;
  finally
    FreeMem(Props);
  end;
end;

function ObjectSchema: TMCPSchema;
begin
  Result.FProperties := TJSONObject.Create;
  Result.FRequired := TJSONArray.Create;
  Result.FRoot := TJSONObject.Create;
  Result.FRoot.Add('type', 'object');
  Result.FRoot.Add('properties', Result.FProperties);
end;

function TMCPSchema.AddProperty(const AName, AJsonType, ADescription: string;
  ARequired: Boolean): TMCPSchema;
var
  Prop: TJSONObject;
begin
  Prop := TJSONObject.Create;
  Prop.Add('type', AJsonType);
  if ADescription <> '' then
    Prop.Add('description', ADescription);
  FProperties.Add(AName, Prop);
  if ARequired then
    FRequired.Add(AName);
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
begin
  if FRequired.Count > 0 then
    FRoot.Add('required', FRequired)
  else
    FRequired.Free;
  Result := FRoot;
end;

end.
