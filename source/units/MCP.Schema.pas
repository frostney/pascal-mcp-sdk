unit MCP.Schema;

// Fluent builder for the flat object schemas most tools need — a
// JSON Schema 2020-12 subset (type/properties/description/required)
// expressed as Pascal instead of a hand-written JSON string:
//
//   Server.RegisterTool('add', 'Add two numbers',
//     ObjectSchema.AddNumber('a', 'First addend')
//                 .AddNumber('b', 'Second addend'),
//     AddHandler);
//
// Properties are required by default (pass ARequired = False for
// optional ones). Build finalizes and transfers ownership of the
// finished TJSONObject; TMCPServer's TMCPSchema registration overloads
// call it for you. The JSON-string and definition-object registration
// paths remain the escape hatch for anything richer ($ref, enums,
// nested objects, title/annotations).

{$I Shared.inc}

interface

uses
  fpjson;

type
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

implementation

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
