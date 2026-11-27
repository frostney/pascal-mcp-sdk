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

// Whether APath ('.'-separated keys) under ADefinition's _meta holds a
// string, returned in AValue ('' otherwise). ADefinition is borrowed.
function MetaPathString(ADefinition: TJSONObject; const APath: string;
  out AValue: string): Boolean;

// Why ADefinition (borrowed) is no valid tool definition, or '': it must
// exist, carry a name (in AToolName, '' when absent), an object
// inputSchema of root type "object", an object outputSchema when
// present, and x-mcp-header annotations a client accepts. Whether the
// name is taken is the registry's to check.
function ToolDefinitionProblem(ADefinition: TJSONObject;
  out AToolName: string): string;

// Sets the string member AName of ADefinition (borrowed), replacing an
// earlier value.
procedure SetStringMember(ADefinition: TJSONObject; const AName,
  AValue: string);

// A resource "annotations" object, or nil with AProblem set. AAudience
// lists 'user' and/or 'assistant'; APriority is 0..1 (< 0 leaves it
// out); ALastModified is a date-time with a time zone
// (2026-11-26T00:00:00Z, or a +HH:MM offset; '' leaves it out). The
// result is the caller's.
function BuildAnnotations(const AAudience: array of string;
  APriority: Double; const ALastModified: string;
  out AProblem: string): TJSONObject;

implementation

uses
  MCP.Schema;

// Whether AText is an IPv6 address (RFC 4291 section 2.2): eight
// groups of one to four hex digits, at most one "::" standing for one
// or more zero groups, and optionally a dotted IPv4 address in place of
// the last two groups.
function ValidIPv6(const AText: string): Boolean;
var
  Parts: TStringArray;
  Text: string;
  Groups, I, J, Value, Octets: Integer;
  Compressed: Boolean;
  Part, Octet: string;
begin
  Result := False;
  Text := AText;
  Compressed := Pos('::', Text) > 0;
  if Compressed and (Pos('::', Copy(Text, Pos('::', Text) + 1, MaxInt)) > 0) then
    Exit;
  if Compressed then
    Text := StringReplace(Text, '::', ':*:', []);
  Parts := Text.Split([':']);
  Groups := 0;
  for I := 0 to High(Parts) do
  begin
    Part := Parts[I];
    if Part = '*' then
      Continue;
    if Part = '' then
    begin
      // Only the empty ends a leading or trailing "::" leaves.
      if not Compressed or ((I <> 0) and (I <> High(Parts))) then
        Exit;
      Continue;
    end;
    if (I = High(Parts)) and (Pos('.', Part) > 0) then
    begin
      // A trailing IPv4 address: four decimal octets.
      Octets := 0;
      for Octet in Part.Split(['.']) do
      begin
        if (Octet = '') or (Length(Octet) > 3) or
          not TryStrToInt(Octet, Value) or (Value > 255) then
          Exit;
        for J := 1 to Length(Octet) do
          if not (Octet[J] in ['0'..'9']) then
            Exit;
        Inc(Octets);
      end;
      if Octets <> 4 then
        Exit;
      Inc(Groups, 2);
      Continue;
    end;
    if Length(Part) > 4 then
      Exit;
    for J := 1 to Length(Part) do
      if not (Part[J] in ['0'..'9', 'a'..'f', 'A'..'F']) then
        Exit;
    Inc(Groups);
  end;
  if Compressed then
    Result := Groups < 8
  else
    Result := Groups = 8;
end;

// Whether AHost is a registered name: unreserved characters and %XX
// escapes (RFC 3986 section 3.2.2), at least one character.
function ValidRegName(const AHost: string): Boolean;
var
  I: Integer;
begin
  Result := AHost <> '';
  I := 1;
  while Result and (I <= Length(AHost)) do
  begin
    if AHost[I] = '%' then
    begin
      Result := (I + 2 <= Length(AHost)) and
        (AHost[I + 1] in ['0'..'9', 'a'..'f', 'A'..'F']) and
        (AHost[I + 2] in ['0'..'9', 'a'..'f', 'A'..'F']);
      Inc(I, 3);
    end
    else
    begin
      Result := AHost[I] in ['A'..'Z', 'a'..'z', '0'..'9', '.', '-', '_', '~'];
      Inc(I);
    end;
  end;
end;

// Whether ASrc, an https: URI, has a usable authority: after any user
// info, a registered name (unreserved characters and %XX escapes) or a
// bracketed IPv6 address, and a port of digits when one is given
// (RFC 3986 section 3.2).
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
    if not ValidIPv6(Copy(Authority, 2, Stop - 2)) then
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
    if not ValidRegName(Host) then
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

function MetaPathString(ADefinition: TJSONObject; const APath: string;
  out AValue: string): Boolean;
var
  Node: TJSONData;
  Key: string;
begin
  AValue := '';
  Node := ADefinition.Find('_meta');
  for Key in APath.Split(['.']) do
  begin
    if (Node = nil) or (Node.JSONType <> jtObject) then
      Exit(False);
    Node := TJSONObject(Node).Find(Key);
  end;
  Result := (Node <> nil) and (Node.JSONType = jtString);
  if Result then
    AValue := Node.AsString;
end;

function ToolDefinitionProblem(ADefinition: TJSONObject;
  out AToolName: string): string;
var
  InputSchema, OutputSchema, SchemaType: TJSONData;
  HeaderParams: TMCPHeaderParameters;
  Violation: string;
begin
  AToolName := '';
  if ADefinition = nil then
    Exit('Tool definition must not be nil');
  AToolName := ADefinition.Get('name', '');
  if AToolName = '' then
    Exit('Tool definition must carry a non-empty name');
  // Tool.inputSchema is a required JSON Schema object:
  // https://modelcontextprotocol.io/specification/2026-07-28/server/tools
  // https://modelcontextprotocol.io/specification/2026-07-28/schema
  // (verified 2026-07-21).
  InputSchema := ADefinition.Find('inputSchema');
  if (InputSchema = nil) or (InputSchema.JSONType <> jtObject) then
    Exit(Format('Tool "%s" definition must carry an object-valued ' +
      'inputSchema', [AToolName]));
  SchemaType := TJSONObject(InputSchema).Find('type');
  if (SchemaType = nil) or (SchemaType.JSONType <> jtString) or
    (SchemaType.AsString <> 'object') then
    Exit(Format('Tool "%s" inputSchema must have root type "object"',
      [AToolName]));
  // Any root type since SEP-2106 (tools#structured-content, verified
  // 2026-11-26); the schema itself is still a JSON object.
  OutputSchema := ADefinition.Find('outputSchema');
  if (OutputSchema <> nil) and (OutputSchema.JSONType <> jtObject) then
    Exit(Format('Tool "%s" definition must carry an object-valued ' +
      'outputSchema', [AToolName]));
  // x-mcp-header annotations a client would reject make it drop the
  // whole tool, so they fail here instead (#90).
  Violation := MCPHeaderParameters(TJSONObject(InputSchema), HeaderParams);
  if Violation <> '' then
    Exit(Format('Tool "%s" inputSchema: %s', [AToolName, Violation]));
  Result := '';
end;

procedure SetStringMember(ADefinition: TJSONObject; const AName,
  AValue: string);
begin
  ADefinition.Delete(AName);
  ADefinition.Add(AName, AValue);
end;

// Whether AText is a date-time with a time zone, as clients check
// lastModified (the TypeScript SDK's zod iso.datetime with offsets):
// YYYY-MM-DDTHH:MM:SS, an optional fraction, then Z or +HH:MM / -HH:MM
// (RFC 3339 section 5.6).
function ValidTimestamp(const AText: string): Boolean;

  function Digits(AFrom, ACount: Integer; AMax: Integer): Boolean;
  var
    I, Value: Integer;
  begin
    Value := 0;
    for I := AFrom to AFrom + ACount - 1 do
    begin
      if (I > Length(AText)) or not (AText[I] in ['0'..'9']) then
        Exit(False);
      Value := Value * 10 + Ord(AText[I]) - Ord('0');
    end;
    Result := Value <= AMax;
  end;

var
  At: Integer;
begin
  Result := (Length(AText) >= 20) and Digits(1, 4, 9999) and
    (AText[5] = '-') and Digits(6, 2, 12) and (AText[8] = '-') and
    Digits(9, 2, 31) and (AText[11] = 'T') and Digits(12, 2, 23) and
    (AText[14] = ':') and Digits(15, 2, 59) and (AText[17] = ':') and
    Digits(18, 2, 59) and (Copy(AText, 6, 2) <> '00') and
    (Copy(AText, 9, 2) <> '00');
  if not Result then
    Exit;
  At := 20;
  if AText[At] = '.' then
  begin
    Inc(At);
    if (At > Length(AText)) or not (AText[At] in ['0'..'9']) then
      Exit(False);
    while (At <= Length(AText)) and (AText[At] in ['0'..'9']) do
      Inc(At);
  end;
  if At > Length(AText) then
    Exit(False);
  if AText[At] = 'Z' then
    Exit(At = Length(AText));
  Result := (AText[At] in ['+', '-']) and (Length(AText) = At + 5) and
    Digits(At + 1, 2, 23) and (AText[At + 3] = ':') and Digits(At + 4, 2, 59);
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
  // Clients reject the whole list over one bad timestamp (#96 review).
  if (AProblem = '') and (ALastModified <> '') and
    not ValidTimestamp(ALastModified) then
    AProblem := Format('lastModified "%s" must be a date-time with a time ' +
      'zone, such as 2026-11-26T00:00:00Z', [ALastModified]);
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
