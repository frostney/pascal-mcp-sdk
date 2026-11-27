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

// '' when ASrc and ATheme make a valid icon for ADefinition, else the
// problem. Clients reject icon URIs other than https: and data:, so
// registration does too: an https: URI needs a host, a data: URI its
// comma. ATheme is '', 'light' or 'dark'. An "icons" member already on
// ADefinition must be an array.
function IconProblem(ADefinition: TJSONObject;
  const ASrc, ATheme: string): string;

// Appends an icon object to ADefinition's "icons" array, creating the
// array when absent. ASizes is space-separated ('48x48 96x96'). Check
// the icon with IconProblem first.
procedure AddIcon(ADefinition: TJSONObject; const ASrc, AMimeType, ASizes,
  ATheme: string);

// '' when AKey and AValue can go under ADefinition's "_meta", else the
// problem: AKey must not be empty, AValue not nil, and a "_meta"
// member already on ADefinition must be an object.
function MetaProblem(ADefinition: TJSONObject; const AKey: string;
  AValue: TJSONData): string;

// Sets AKey under ADefinition's "_meta", replacing an earlier value.
// Takes ownership of AValue; check MetaProblem first. Children of
// AValue stored as nil become JSON nulls, so the definition still
// clones for every list.
procedure SetMetaEntry(ADefinition: TJSONObject; const AKey: string;
  AValue: TJSONData);

// Replaces every child stored as nil (which fpjson writes as null but
// cannot clone, FPC 3.2.2) with a JSON null, so a definition can be
// cloned for every list.
procedure NilChildrenToNull(AData: TJSONData);

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

// The host of an https: URI ('' when it has none): what follows
// "https://" up to the path, query or fragment, less any user info and
// port.
function HttpsHost(const ASrc: string): string;
var
  Stop: Integer;
begin
  Result := Copy(ASrc, 9, MaxInt);
  Stop := Length(Result) + 1;
  if Pos('/', Result) > 0 then
    Stop := Pos('/', Result);
  if (Pos('?', Result) > 0) and (Pos('?', Result) < Stop) then
    Stop := Pos('?', Result);
  if (Pos('#', Result) > 0) and (Pos('#', Result) < Stop) then
    Stop := Pos('#', Result);
  Result := Copy(Result, 1, Stop - 1);
  Delete(Result, 1, Pos('@', Result));
  if Pos(':', Result) > 0 then
    Result := Copy(Result, 1, Pos(':', Result) - 1);
end;

function IconProblem(ADefinition: TJSONObject;
  const ASrc, ATheme: string): string;
var
  Icons: TJSONData;
begin
  Result := '';
  if SameText(Copy(ASrc, 1, 8), 'https://') then
  begin
    if HttpsHost(ASrc) = '' then
      Exit(Format('Icon "%s" needs a host', [ASrc]));
  end
  else if SameText(Copy(ASrc, 1, 5), 'data:') then
  begin
    // data:[<media type>][;base64],<data> (RFC 2397)
    if Pos(',', ASrc) = 0 then
      Exit(Format('Icon "%s" is no data: URI (it has no comma)', [ASrc]));
  end
  else
    Exit(Format('Icon "%s" must be an https: or data: URI', [ASrc]));
  if (ATheme <> '') and (ATheme <> 'light') and (ATheme <> 'dark') then
    Exit(Format('Icon theme "%s" must be light or dark', [ATheme]));
  Icons := ADefinition.Find('icons');
  if (Icons <> nil) and (Icons.JSONType <> jtArray) then
    Result := '"icons" of the definition must be an array';
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

function MetaProblem(ADefinition: TJSONObject; const AKey: string;
  AValue: TJSONData): string;
var
  Meta: TJSONData;
begin
  Result := '';
  if (AKey = '') or (AValue = nil) then
    Exit('_meta needs a key and a value');
  Meta := ADefinition.Find('_meta');
  if (Meta <> nil) and (Meta.JSONType <> jtObject) then
    Result := '"_meta" of the definition must be an object';
end;

procedure NilChildrenToNull(AData: TJSONData);
var
  I: Integer;
begin
  if (AData = nil) or not (AData.JSONType in [jtObject, jtArray]) then
    Exit;
  for I := 0 to AData.Count - 1 do
    if AData.Items[I] = nil then
      AData.Items[I] := TJSONNull.Create
    else
      NilChildrenToNull(AData.Items[I]);
end;

procedure SetMetaEntry(ADefinition: TJSONObject; const AKey: string;
  AValue: TJSONData);
var
  Meta: TJSONData;
begin
  NilChildrenToNull(AValue);
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
