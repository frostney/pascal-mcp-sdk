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

// '' when ASrc and ATheme make a valid icon for ADefinition (borrowed),
// else the problem. Clients reject icon URIs other than https: and
// data:, so registration does too: no whitespace, an https: URI needs a
// valid host (and port, if given), a data: URI its comma and, when it
// says ;base64, base64 data. ATheme is '', 'light' or 'dark'. An
// "icons" member already on ADefinition must be an array.
function IconProblem(ADefinition: TJSONObject;
  const ASrc, ATheme: string): string;

// Appends an icon object to ADefinition's (borrowed) "icons" array, creating the
// array when absent. ASizes is space-separated ('48x48 96x96'). Check
// the icon with IconProblem first.
procedure AddIcon(ADefinition: TJSONObject; const ASrc, AMimeType, ASizes,
  ATheme: string);

// '' when AKey and AValue (both borrowed here) can go under
// ADefinition's "_meta", else the
// problem: AKey must not be empty, AValue not nil, and a "_meta"
// member already on ADefinition must be an object.
function MetaProblem(ADefinition: TJSONObject; const AKey: string;
  AValue: TJSONData): string;

// Sets AKey under ADefinition's (borrowed) "_meta", replacing an
// earlier value.
// Takes ownership of AValue; check MetaProblem first. Children of
// AValue stored as nil become JSON nulls, so the definition still
// clones for every list.
procedure SetMetaEntry(ADefinition: TJSONObject; const AKey: string;
  AValue: TJSONData);

// Replaces every child stored as nil (which fpjson writes as null but
// cannot clone, FPC 3.2.2) with a JSON null, so a definition can be
// cloned for every list. AData is borrowed and changed in place.
procedure NilChildrenToNull(AData: TJSONData);

// Sets the string member AName of ADefinition (borrowed), replacing an
// earlier value.
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

// Whether ASrc, an https: URI, has a usable authority: a host of
// letters, digits, '.', '-', '_' and '~' (or a bracketed IPv6
// address), after any user info, and a port of digits when one is
// given (RFC 3986 section 3.2).
function ValidHttpsAuthority(const ASrc: string): Boolean;
var
  Authority, Host, Port: string;
  Stop, I: Integer;
begin
  Authority := Copy(ASrc, 9, MaxInt);
  Stop := Length(Authority) + 1;
  for I := Length(Authority) downto 1 do
    if Authority[I] in ['/', '?', '#'] then
      Stop := I;
  Authority := Copy(Authority, 1, Stop - 1);
  Delete(Authority, 1, LastDelimiter('@', Authority));
  Port := '';
  if Copy(Authority, 1, 1) = '[' then
  begin
    Stop := Pos(']', Authority);
    if Stop < 3 then
      Exit(False);
    Host := Copy(Authority, 2, Stop - 2);
    for I := 1 to Length(Host) do
      if not (Host[I] in ['0'..'9', 'a'..'f', 'A'..'F', ':', '.']) then
        Exit(False);
    Delete(Authority, 1, Stop);
    if Authority <> '' then
    begin
      if Authority[1] <> ':' then
        Exit(False);
      Port := Copy(Authority, 2, MaxInt);
      if Port = '' then
        Exit(False);
    end;
  end
  else
  begin
    Stop := Pos(':', Authority);
    if Stop > 0 then
    begin
      Host := Copy(Authority, 1, Stop - 1);
      Port := Copy(Authority, Stop + 1, MaxInt);
      if Port = '' then
        Exit(False);
    end
    else
      Host := Authority;
    if Host = '' then
      Exit(False);
    for I := 1 to Length(Host) do
      if not (Host[I] in ['A'..'Z', 'a'..'z', '0'..'9', '.', '-', '_', '~']) then
        Exit(False);
  end;
  for I := 1 to Length(Port) do
    if not (Port[I] in ['0'..'9']) then
      Exit(False);
  Result := True;
end;

// Whether ASrc, a data: URI, has its comma and, when it says
// ";base64", base64 data: the alphabet, padding only at the end, and a
// length that is a multiple of four (RFC 2397, RFC 4648).
function ValidDataUri(const ASrc: string): Boolean;
var
  Comma, I, Padding: Integer;
  Data: string;
begin
  Comma := Pos(',', ASrc);
  if Comma = 0 then
    Exit(False);
  if not SameText(Copy(ASrc, Comma - 7, 7), ';base64') then
    Exit(True);
  Data := Copy(ASrc, Comma + 1, MaxInt);
  if Length(Data) mod 4 <> 0 then
    Exit(False);
  Padding := 0;
  for I := 1 to Length(Data) do
    if Data[I] = '=' then
      Inc(Padding)
    else if (Padding > 0) or
      not (Data[I] in ['A'..'Z', 'a'..'z', '0'..'9', '+', '/']) then
      Exit(False);
  Result := Padding <= 2;
end;

// Whether ASrc has whitespace or control characters, which no URI may.
function HasUriBlank(const ASrc: string): Boolean;
var
  I: Integer;
begin
  for I := 1 to Length(ASrc) do
    if Ord(ASrc[I]) <= 32 then
      Exit(True);
  Result := False;
end;

function IconProblem(ADefinition: TJSONObject;
  const ASrc, ATheme: string): string;
var
  Icons: TJSONData;
begin
  Result := '';
  if HasUriBlank(ASrc) then
    Exit(Format('Icon "%s" must not contain spaces', [ASrc]));
  if SameText(Copy(ASrc, 1, 8), 'https://') then
  begin
    if not ValidHttpsAuthority(ASrc) then
      Exit(Format('Icon "%s" needs a valid host and port', [ASrc]));
  end
  else if SameText(Copy(ASrc, 1, 5), 'data:') then
  begin
    // data:[<media type>][;base64],<data> (RFC 2397)
    if not ValidDataUri(ASrc) then
      Exit(Format('Icon "%s" is no valid data: URI', [ASrc]));
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
