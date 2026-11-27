unit MCP.Metadata;

// Definition metadata (#96): the icons, _meta entries and resource
// annotations the registration options add to tool, resource, template
// and prompt definitions. Verified 2026-11-26 against the 2026-07-28
// schema (Icon, Annotations, BaseMetadata):
// https://modelcontextprotocol.io/specification/2026-07-28/schema
//
// The checks report a problem as a message ('' when there is none):
// MCP.Server raises it as EMCPServer, so registration keeps one
// exception type. This unit has no registry and knows nothing of
// dispatch.

{$I MCP.inc}

interface

uses
  SysUtils,

  fpjson;

// '' when ASrc and ATheme make a valid icon, else the problem. Clients
// reject icon URIs other than https: and data:, so registration does
// too; ATheme is '', 'light' or 'dark'.
function IconProblem(const ASrc, ATheme: string): string;

// Appends an icon object to ADefinition's "icons" array, creating the
// array when absent. ASizes is space-separated ('48x48 96x96'). Check
// the icon with IconProblem first.
procedure AddIcon(ADefinition: TJSONObject; const ASrc, AMimeType, ASizes,
  ATheme: string);

// Sets AKey under ADefinition's "_meta", replacing an earlier value.
// Takes ownership of AValue; AKey must not be empty and AValue not nil
// (raise before calling).
procedure SetMetaEntry(ADefinition: TJSONObject; const AKey: string;
  AValue: TJSONData);

// Sets the string member AName, replacing an earlier value.
procedure SetStringMember(ADefinition: TJSONObject; const AName,
  AValue: string);

// A resource "annotations" object, or nil with AProblem set. AAudience
// lists 'user' and/or 'assistant'; APriority is 0..1 (< 0 leaves it
// out); ALastModified is an ISO 8601 timestamp ('' leaves it out). The
// result is the caller's.
function BuildAnnotations(const AAudience: array of string;
  APriority: Double; const ALastModified: string;
  out AProblem: string): TJSONObject;

implementation

uses
  MCP.Schema;

function IconProblem(const ASrc, ATheme: string): string;
begin
  Result := '';
  if not (SameText(Copy(ASrc, 1, 8), 'https://') or
    SameText(Copy(ASrc, 1, 5), 'data:')) then
    Exit(Format('Icon "%s" must be an https: or data: URI', [ASrc]));
  if (ATheme <> '') and (ATheme <> 'light') and (ATheme <> 'dark') then
    Result := Format('Icon theme "%s" must be light or dark', [ATheme]);
end;

procedure AddIcon(ADefinition: TJSONObject; const ASrc, AMimeType, ASizes,
  ATheme: string);
var
  Icons: TJSONData;
  Icon: TJSONObject;
  Sizes: TJSONArray;
  Parts: TStringArray;
  I: Integer;
begin
  Icon := TJSONObject.Create;
  try
    Icon.Add('src', ASrc);
    if AMimeType <> '' then
      Icon.Add('mimeType', AMimeType);
    if ASizes <> '' then
    begin
      Sizes := TJSONArray.Create;
      Icon.Add('sizes', Sizes);
      Parts := ASizes.Split([' '], TStringSplitOptions.ExcludeEmpty);
      for I := 0 to High(Parts) do
        Sizes.Add(Parts[I]);
    end;
    if ATheme <> '' then
      Icon.Add('theme', ATheme);
    Icons := ADefinition.Find('icons');
    if Icons = nil then
    begin
      Icons := TJSONArray.Create;
      ADefinition.Add('icons', Icons);
    end;
  except
    Icon.Free;
    raise;
  end;
  TJSONArray(Icons).Add(Icon);
end;

procedure SetMetaEntry(ADefinition: TJSONObject; const AKey: string;
  AValue: TJSONData);
var
  Meta: TJSONData;
begin
  Meta := ADefinition.Find('_meta');
  if Meta = nil then
  begin
    Meta := TJSONObject.Create;
    ADefinition.Add('_meta', Meta);
  end;
  TJSONObject(Meta).Delete(AKey);
  TJSONObject(Meta).Add(AKey, AValue);
end;

procedure SetStringMember(ADefinition: TJSONObject; const AName,
  AValue: string);
begin
  ADefinition.Delete(AName);
  ADefinition.Add(AName, AValue);
end;

// '' when every audience entry is one the schema names.
function AudienceProblem(const AAudience: array of string): string;
var
  Entry: string;
begin
  Result := '';
  for Entry in AAudience do
    if (Entry <> 'user') and (Entry <> 'assistant') then
      Exit(Format('Audience "%s" must be user or assistant', [Entry]));
end;

function BuildAnnotations(const AAudience: array of string;
  APriority: Double; const ALastModified: string;
  out AProblem: string): TJSONObject;
var
  Audience: TJSONArray;
  Entry: string;
begin
  Result := nil;
  AProblem := AudienceProblem(AAudience);
  if (AProblem = '') and (APriority > 1) then
    AProblem := 'Annotation priority must be between 0 and 1';
  if AProblem <> '' then
    Exit;
  Result := TJSONObject.Create;
  try
    if Length(AAudience) > 0 then
    begin
      Audience := TJSONArray.Create;
      Result.Add('audience', Audience);
      for Entry in AAudience do
        Audience.Add(Entry);
    end;
    if APriority >= 0 then
      Result.Add('priority', MCPWireNumber(APriority));
    if ALastModified <> '' then
      Result.Add('lastModified', ALastModified);
  except
    FreeAndNil(Result);
    raise;
  end;
end;

end.
