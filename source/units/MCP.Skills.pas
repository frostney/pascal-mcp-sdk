{ MCP.Skills — the Skills extension (io.modelcontextprotocol/skills,
  #115): skills defined in code, served as skill:// resources with the
  digests and sizes hosts verify, through skills/list, skills/get and
  resources/directory/read. Verified 2026-11-27 against
  modelcontextprotocol/ext-skills specification/beta/skills.mdx at
  ba23984 (Beta; SEP-2640) and https://agentskills.io/specification.
  The library writes SKILL.md from the frontmatter object and the body,
  so the entry's frontmatter and the file agree by construction. }

// Frontmatter := TJSONObject.Create(['name', 'git-workflow',
//   'description', 'Follow this team''s Git conventions']);
// RegisterSkill(Server, 'git-workflow', Frontmatter,
//   '# Git workflow' + LineEnding + 'Branch from main.' + LineEnding,
//   [MCPSkillFile('references/commits.md', CommitsText)]);

unit MCP.Skills;

{$I MCP.inc}

interface

uses
  SysUtils,

  fpjson,
  MCP.Server;

const
  MCP_SKILLS_EXTENSION = 'io.modelcontextprotocol/skills';
  // "Servers SHOULD NOT serve a skill that exceeds either limit"
  // (skills.mdx, Limits): registration refuses one.
  MCP_SKILL_MAX_FILES = 512;
  MCP_SKILL_MAX_BYTES = 16777216;

type
  // A file of a skill other than SKILL.md: APath relative to the skill
  // root, '/'-separated; Content its raw bytes; MimeType '' to guess
  // from the extension.
  TMCPSkillFile = record
    Path: string;
    Content: RawByteString; // never converted: the bytes the digest covers
    MimeType: string;
  end;

function MCPSkillFile(const APath: string; const AContent: RawByteString;
  const AMimeType: string = ''): TMCPSkillFile;

// Registers the skill at skill://ASkillPath/SKILL.md, before the server
// starts: AFrontmatter (owned, also on failure) needs a "name" equal to
// the last segment of ASkillPath and a "description"; ABody follows the
// frontmatter in SKILL.md; AFiles are its other files. The first call
// declares the extension (with directoryRead) and the resources
// capability, and serves skills/list, skills/get,
// resources/directory/read and the files over resources/read. Raises
// EMCPServer for a name, path, field or file the specifications refuse,
// a URI already served, or a skill over the limits, counting the files
// of skills nested in it.
procedure RegisterSkill(AServer: TMCPServer; const ASkillPath: string;
  AFrontmatter: TJSONObject; const ABody: string;
  const AFiles: array of TMCPSkillFile);

// The SKILL.md RegisterSkill writes: a YAML frontmatter block for
// AFrontmatter (borrowed), then ABody. Strings are double-quoted with
// only the escapes YAML 1.1 and 1.2 share, so any YAML parser reads the
// object back; a float, a key longer than 1024 characters, or text that
// is not UTF-8 raises EMCPServer.
function MCPSkillMarkdown(AFrontmatter: TJSONObject;
  const ABody: string): string;

implementation

uses
  MCP.Content,
  MCP.Crypto,
  MCP.Extensions,
  MCP.JSONRPC,
  MCP.Metadata,
  MCP.Pagination,
  MCP.Protocol;

const
  SKILL_SCHEME = 'skill://';
  DIRECTORY_MIME_TYPE = 'inode/directory';

type
  TSkillCatalog = class
  private
    FServer: TMCPServer; // borrowed: owns this catalog
    FSkills: array of record
      Root: string; // skill://<skill-path>, no trailing slash
      Frontmatter: TJSONObject; // owned
    end;
    FFiles: array of record
      Uri, MimeType, Digest: string;
      Content: RawByteString;
      Skill: Integer; // the skill whose SKILL.md this is, or -1
    end;
    function FileIndex(const AUri: string): Integer;
    function IsDirectory(const AUri: string): Boolean;
    function SkillEntry(ASkill: Integer): TJSONObject;
    procedure CheckLimits(const ARoot: string);
    function SkillsList(AParams: TJSONObject; const ACtx: TMCPRequestContext;
      ALegacy: Boolean): TJSONObject;
    function SkillsGet(AParams: TJSONObject; const ACtx: TMCPRequestContext;
      ALegacy: Boolean): TJSONObject;
    function DirectoryRead(AParams: TJSONObject;
      const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
    function ReadFile(const AUri: string;
      const ACtx: TMCPRequestContext): TJSONArray;
  public
    constructor Create(AServer: TMCPServer);
    destructor Destroy; override;
    procedure Add(const ASkillPath: string; AFrontmatter: TJSONObject;
      const ABody: string; const AFiles: array of TMCPSkillFile);
  end;

function MCPSkillFile(const APath: string; const AContent: RawByteString;
  const AMimeType: string): TMCPSkillFile;
begin
  Result.Path := APath;
  Result.Content := AContent;
  Result.MimeType := AMimeType;
end;

{ ───────── names, paths and media types ───────── }

// agentskills.io, name field: 1-64 characters of a-z, 0-9 and '-', no
// leading, trailing or doubled hyphen.
function IsSkillName(const AName: string): Boolean;
var
  I: Integer;
begin
  Result := (Length(AName) >= 1) and (Length(AName) <= 64) and
    (AName[1] <> '-') and (AName[Length(AName)] <> '-') and
    (Pos('--', AName) = 0);
  for I := 1 to Length(AName) do
    if not (AName[I] in ['a'..'z', '0'..'9', '-']) then
      Exit(False);
end;

// One '/'-separated segment the library puts in a URI as it is: RFC
// 3986 unreserved characters, and not "." or "..". The first segment of
// a skill path is the URI authority, which these keep a valid reg-name.
function IsPlainSegment(const ASegment: string): Boolean;
var
  I: Integer;
begin
  Result := (ASegment <> '') and (ASegment <> '.') and (ASegment <> '..');
  for I := 1 to Length(ASegment) do
    if not (ASegment[I] in ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_',
      '~']) then
      Exit(False);
end;

function IsPlainPath(const APath: string): Boolean;
var
  Segment: string;
begin
  Result := APath <> '';
  for Segment in APath.Split(['/']) do
    if not IsPlainSegment(Segment) then
      Exit(False);
end;

function LastSegment(const APath: string): string;
var
  Slash: Integer;
begin
  Slash := LastDelimiter('/', APath);
  Result := Copy(APath, Slash + 1, MaxInt);
end;

function GuessMimeType(const APath: string;
  const AContent: RawByteString): string;
var
  Extension: string;
begin
  Extension := LowerCase(ExtractFileExt(APath));
  if Extension = '.md' then
    Exit('text/markdown');
  if Extension = '.json' then
    Exit('application/json');
  if Extension = '.py' then
    Exit('text/x-python');
  if Extension = '.sh' then
    Exit('text/x-shellscript');
  if Extension = '.png' then
    Exit('image/png');
  if (Extension = '.jpg') or (Extension = '.jpeg') then
    Exit('image/jpeg');
  if InvalidUTF8Offset(AContent) = 0 then
    Exit('text/plain');
  Result := 'application/octet-stream';
end;

// "sha256:" and 64 lowercase hex characters (skills.mdx, Integrity and
// Verification).
function SkillDigest(const AContent: RawByteString): string;
var
  Digest: TSHA256Digest;
  I: Integer;
begin
  Digest := SHA256(AContent);
  Result := 'sha256:';
  for I := Low(Digest) to High(Digest) do
    Result := Result + LowerCase(IntToHex(Digest[I], 2));
end;

{ ───────── frontmatter ───────── }

// UTF-8 code points in AText (well-formed, so continuation bytes are
// the ones to skip).
function CodePoints(const AText: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to Length(AText) do
    if (Ord(AText[I]) and $C0) <> $80 then
      Inc(Result);
end;

function StringField(AFrontmatter: TJSONObject; const AName: string;
  ARequired: Boolean; AMaxPoints: Integer; out AValue: string): string;
var
  Field: TJSONData;
begin
  AValue := '';
  Result := '';
  Field := AFrontmatter.Find(AName);
  if Field = nil then
  begin
    if ARequired then
      Result := Format('frontmatter needs "%s"', [AName]);
    Exit;
  end;
  if Field.JSONType <> jtString then
    Exit(Format('frontmatter "%s" must be a string', [AName]));
  AValue := Field.AsString;
  // Only the fields with bounds have a length to check.
  if (AMaxPoints > 0) and ((AValue = '') or
    (CodePoints(AValue) > AMaxPoints)) then
    Result := Format('frontmatter "%s" must be 1 to %d characters',
      [AName, AMaxPoints]);
end;

// The Agent Skills fields this server checks; every other field passes
// through as written.
function FrontmatterProblem(AFrontmatter: TJSONObject;
  const ASkillName: string): string;
var
  Value: string;
  Metadata: TJSONData;
  I: Integer;
begin
  Result := StringField(AFrontmatter, 'name', True, 64, Value);
  if (Result = '') and not IsSkillName(Value) then
    Result := Format('frontmatter name "%s" must be 1 to 64 of a-z, 0-9 ' +
      'and single inner hyphens', [Value]);
  if (Result = '') and (Value <> ASkillName) then
    Result := Format('frontmatter name "%s" must equal the last segment ' +
      'of the skill path, "%s"', [Value, ASkillName]);
  if Result = '' then
    Result := StringField(AFrontmatter, 'description', True, 1024, Value);
  if Result = '' then
    Result := StringField(AFrontmatter, 'compatibility', False, 500, Value);
  if (Result = '') and (AFrontmatter.Find('license') <> nil) then
    Result := StringField(AFrontmatter, 'license', False, 0, Value);
  if (Result = '') and (AFrontmatter.Find('allowed-tools') <> nil) then
    Result := StringField(AFrontmatter, 'allowed-tools', False, 0, Value);
  if Result <> '' then
    Exit;
  Metadata := AFrontmatter.Find('metadata');
  if Metadata = nil then
    Exit;
  if Metadata.JSONType <> jtObject then
    Exit('frontmatter "metadata" must map strings to strings');
  for I := 0 to Metadata.Count - 1 do
    if (Metadata.Items[I] = nil) or
      (Metadata.Items[I].JSONType <> jtString) then
      Exit('frontmatter "metadata" must map strings to strings');
end;

// A YAML double-quoted scalar both YAML 1.1 and 1.2 read back as AText:
// '"' and '\' escaped, C0 controls, DEL, C1 controls, U+2028, U+2029,
// U+FFFE and U+FFFF as \uXXXX. Checked 2026-11-27 with PyYAML 6.0.1 (YAML 1.1), js-yaml
// 4.1.0 and yaml 2.6.1 (YAML 1.2).
// JSON's "\/" is left out, as YAML 1.1 has no such escape.
function YamlQuoted(const AText: string): string;
var
  I: Integer;
  C: Byte;
begin
  Result := '"';
  I := 1;
  while I <= Length(AText) do
  begin
    C := Ord(AText[I]);
    if (C = Ord('"')) or (C = Ord('\')) then
      Result := Result + '\' + AText[I]
    else if C = 10 then
      Result := Result + '\n'
    else if (C < $20) or (C = $7F) then
      Result := Result + '\u' + IntToHex(C, 4)
    else if (C = $C2) and (I < Length(AText)) and
      (Ord(AText[I + 1]) in [$80..$9F]) then
    begin
      Inc(I);
      Result := Result + '\u' + IntToHex(Ord(AText[I]), 4);
    end
    // U+2028 and U+2029, which YAML 1.1 reads as line breaks, folding
    // the indentation after them away (#115 review).
    else if (C = $E2) and (I + 2 <= Length(AText)) and
      (Ord(AText[I + 1]) = $80) and (Ord(AText[I + 2]) in [$A8, $A9]) then
    begin
      Result := Result + '\u202' + Chr(Ord('8') + Ord(AText[I + 2]) - $A8);
      Inc(I, 2);
    end
    // U+FFFE and U+FFFF, which YAML does not count as printable either.
    else if (C = $EF) and (I + 2 <= Length(AText)) and
      (Ord(AText[I + 1]) = $BF) and (Ord(AText[I + 2]) in [$BE, $BF]) then
    begin
      Result := Result + '\uFFF' + Chr(Ord('E') + Ord(AText[I + 2]) - $BE);
      Inc(I, 2);
    end
    else
      Result := Result + AText[I];
    Inc(I);
  end;
  Result := Result + '"';
end;

// A key YAML reads as that string when written plain: an identifier
// that YAML 1.1 does not turn into a boolean or null.
function YamlKey(const AKey: string): string;
const
  RESOLVED: array[0..10] of string = ('y', 'n', 'yes', 'no', 'on', 'off',
    'true', 'false', 'null', 'yaml', 'merge');
var
  I: Integer;
  Word: string;
begin
  Result := YamlQuoted(AKey);
  if (AKey = '') or not (AKey[1] in ['A'..'Z', 'a'..'z']) then
    Exit;
  for I := 1 to Length(AKey) do
    if not (AKey[I] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '-']) then
      Exit;
  for Word in RESOLVED do
    if LowerCase(AKey) = Word then
      Exit;
  Result := AKey;
end;

function YamlScalar(AValue: TJSONData): string;
begin
  case AValue.JSONType of
    jtString:
      Result := YamlQuoted(AValue.AsString);
    jtBoolean:
      Result := LowerCase(BoolToStr(AValue.AsBoolean, True));
    jtNull:
      Result := 'null';
    jtNumber:
      begin
        if TJSONNumber(AValue).NumberType = ntFloat then
          raise EMCPServer.Create('Skill frontmatter cannot hold a ' +
            'fractional number; write it as a string');
        Result := AValue.AsJSON;
      end;
    jtObject:
      Result := '{}';
    jtArray:
      Result := '[]';
  else
    raise EMCPServer.Create('Skill frontmatter holds an unknown value');
  end;
end;

// YAML parsers read an implicit key of at most 1024 characters
// (YAML 1.2 7.4.2, PyYAML's simple-key limit).
const
  MAX_KEY_POINTS = 1024;

procedure WriteYaml(AValue: TJSONData; const AIndent: string;
  var AOut: string);
var
  I: Integer;
  Item: TJSONData;
  Key: string;
begin
  for I := 0 to AValue.Count - 1 do
  begin
    Item := AValue.Items[I];
    if AValue.JSONType = jtObject then
    begin
      Key := YamlKey(TJSONObject(AValue).Names[I]);
      if CodePoints(Key) > MAX_KEY_POINTS then
        raise EMCPServer.CreateFmt('Skill frontmatter key "%s..." is longer ' +
          'than YAML parsers read', [Copy(Key, 1, 40)]);
      AOut := AOut + AIndent + Key + ':';
    end
    else
      // A list item that is a collection goes below its dash.
      AOut := AOut + AIndent + '-';
    if (Item.JSONType in [jtObject, jtArray]) and (Item.Count > 0) then
    begin
      AOut := AOut + #10;
      WriteYaml(Item, AIndent + '  ', AOut);
    end
    else
      AOut := AOut + ' ' + YamlScalar(Item) + #10;
  end;
end;

function MCPSkillMarkdown(AFrontmatter: TJSONObject;
  const ABody: string): string;
begin
  if AFrontmatter = nil then
    raise EMCPServer.Create('A skill needs its frontmatter');
  NilChildrenToNull(AFrontmatter);
  Result := '---' + #10;
  WriteYaml(AFrontmatter, '', Result);
  Result := Result + '---' + #10 + ABody;
  // Hosts parse SKILL.md as text, so it must be UTF-8 (#115 review).
  if InvalidUTF8Offset(Result) <> 0 then
    raise EMCPServer.Create('A skill''s frontmatter and body must be UTF-8 ' +
      'text');
end;

{ ───────── catalog ───────── }

constructor TSkillCatalog.Create(AServer: TMCPServer);
begin
  inherited Create;
  FServer := AServer;
end;

destructor TSkillCatalog.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FSkills) do
    FSkills[I].Frontmatter.Free;
  inherited Destroy;
end;

// Whether AUri lies under the directory or file ABase.
function IsUnder(const AUri, ABase: string): Boolean;
begin
  Result := Copy(AUri, 1, Length(ABase) + 1) = ABase + '/';
end;

function TSkillCatalog.FileIndex(const AUri: string): Integer;
begin
  for Result := 0 to High(FFiles) do
    if FFiles[Result].Uri = AUri then
      Exit;
  Result := -1;
end;

// A directory is any path some file lies under, at a segment boundary.
// Only a skill:// URI with an authority: "skill:" or "skill:/" would
// otherwise prefix every file (#115 review).
function TSkillCatalog.IsDirectory(const AUri: string): Boolean;
var
  I: Integer;
begin
  if (Copy(AUri, 1, Length(SKILL_SCHEME)) <> SKILL_SCHEME) or
    (Length(AUri) = Length(SKILL_SCHEME)) then
    Exit(False);
  for I := 0 to High(FFiles) do
    if IsUnder(FFiles[I].Uri, AUri) then
      Exit(True);
  Result := False;
end;

procedure TSkillCatalog.Add(const ASkillPath: string;
  AFrontmatter: TJSONObject; const ABody: string;
  const AFiles: array of TMCPSkillFile);
var
  Root, Problem: string;
  Normalized: TJSONObject;
  Uris: array of string;
  Contents: array of RawByteString;
  I, J, Skill, Slot: Integer;
begin
  try
    if not IsPlainPath(ASkillPath) then
      raise EMCPServer.CreateFmt('Skill path "%s" needs "/"-separated ' +
        'segments of letters, digits, "-", ".", "_" and "~"', [ASkillPath]);
    if AFrontmatter = nil then
      raise EMCPServer.Create('A skill needs its frontmatter');
    // A member stored as nil is a null, checked as one (#115 review).
    // The clone rebuilds fpjson's name lookup, which (FPC 3.2.2) still
    // misses a member replaced through Items[].
    NilChildrenToNull(AFrontmatter);
    Normalized := TJSONObject(AFrontmatter.Clone);
    AFrontmatter.Free;
    AFrontmatter := Normalized;
    Problem := FrontmatterProblem(AFrontmatter, LastSegment(ASkillPath));
    if Problem <> '' then
      raise EMCPServer.CreateFmt('Skill "%s": %s', [ASkillPath, Problem]);
    Root := SKILL_SCHEME + ASkillPath;
    SetLength(Uris, Length(AFiles) + 1);
    SetLength(Contents, Length(AFiles) + 1);
    Uris[0] := Root + '/SKILL.md';
    Contents[0] := MCPSkillMarkdown(AFrontmatter, ABody);
    for I := 0 to High(AFiles) do
    begin
      if not IsPlainPath(AFiles[I].Path) or (AFiles[I].Path = 'SKILL.md') then
        raise EMCPServer.CreateFmt('Skill "%s": file path "%s" needs ' +
          '"/"-separated segments of letters, digits, "-", ".", "_" and ' +
          '"~", and SKILL.md is written from the frontmatter',
          [ASkillPath, AFiles[I].Path]);
      if AFiles[I].MimeType = DIRECTORY_MIME_TYPE then
        raise EMCPServer.CreateFmt('Skill file "%s" cannot have the ' +
          'directory media type', [AFiles[I].Path]);
      Uris[I + 1] := Root + '/' + AFiles[I].Path;
      Contents[I + 1] := AFiles[I].Content;
    end;
    // A URI is served once, and none is both a file and a directory,
    // among this skill's files as against those served already.
    for I := 0 to High(Uris) do
    begin
      for J := 0 to I - 1 do
        if (Uris[J] = Uris[I]) or IsUnder(Uris[J], Uris[I]) or
          IsUnder(Uris[I], Uris[J]) then
          raise EMCPServer.CreateFmt('Skill files "%s" and "%s" clash: the ' +
            'same file, or one under the other', [Uris[J], Uris[I]]);
      if (FileIndex(Uris[I]) >= 0) or IsDirectory(Uris[I]) then
        raise EMCPServer.CreateFmt('Skill URI "%s" is already served',
          [Uris[I]]);
      for J := 0 to High(FFiles) do
        if IsUnder(Uris[I], FFiles[J].Uri) then
          raise EMCPServer.CreateFmt('Skill file "%s" lies under the file ' +
            '"%s"', [Uris[I], FFiles[J].Uri]);
    end;
  except
    AFrontmatter.Free;
    raise;
  end;
  Skill := Length(FSkills);
  SetLength(FSkills, Skill + 1);
  FSkills[Skill].Root := Root;
  FSkills[Skill].Frontmatter := AFrontmatter;
  for I := 0 to High(Uris) do
  begin
    Slot := Length(FFiles);
    SetLength(FFiles, Slot + 1);
    FFiles[Slot].Uri := Uris[I];
    FFiles[Slot].Content := Contents[I];
    FFiles[Slot].Digest := SkillDigest(Contents[I]);
    FFiles[Slot].Skill := -1;
    if I = 0 then
    begin
      FFiles[Slot].MimeType := 'text/markdown';
      FFiles[Slot].Skill := Skill;
    end
    else if AFiles[I - 1].MimeType <> '' then
      FFiles[Slot].MimeType := AFiles[I - 1].MimeType
    else
      FFiles[Slot].MimeType := GuessMimeType(AFiles[I - 1].Path,
        Contents[I]);
  end;
  try
    CheckLimits(Root);
  except
    // Leave the catalog as it was before this skill.
    SetLength(FFiles, Length(FFiles) - Length(Uris));
    FSkills[Skill].Frontmatter.Free;
    SetLength(FSkills, Skill);
    raise;
  end;
end;

// The skill at ARoot and the skills it is nested in, the only totals a
// new skill changes, its nested skills' files included (skills.mdx,
// Resources: "Completeness extends to nested skills").
procedure TSkillCatalog.CheckLimits(const ARoot: string);
var
  I, J, Count: Integer;
  Bytes: Int64;
begin
  for I := 0 to High(FSkills) do
  begin
    if (FSkills[I].Root <> ARoot) and not IsUnder(ARoot, FSkills[I].Root) then
      Continue;
    Count := 0;
    Bytes := 0;
    for J := 0 to High(FFiles) do
      if Copy(FFiles[J].Uri, 1, Length(FSkills[I].Root) + 1) =
        FSkills[I].Root + '/' then
      begin
        Inc(Count);
        Inc(Bytes, Length(FFiles[J].Content));
      end;
    if (Count > MCP_SKILL_MAX_FILES) or (Bytes > MCP_SKILL_MAX_BYTES) then
      raise EMCPServer.CreateFmt('Skill "%s" has %d files and %d bytes; ' +
        'hosts need at most %d files and %d bytes', [FSkills[I].Root, Count,
        Bytes, MCP_SKILL_MAX_FILES, MCP_SKILL_MAX_BYTES]);
  end;
end;

function TSkillCatalog.SkillEntry(ASkill: Integer): TJSONObject;
var
  Resources: TJSONArray;
  Resource: TJSONObject;
  Prefix: string;
  I: Integer;
begin
  Result := TJSONObject.Create;
  try
    Prefix := FSkills[ASkill].Root + '/';
    Result.Add('uri', Prefix + 'SKILL.md');
    Result.Add('frontmatter', FSkills[ASkill].Frontmatter.Clone);
    Resources := TJSONArray.Create;
    Result.Add('resources', Resources);
    for I := 0 to High(FFiles) do
      if Copy(FFiles[I].Uri, 1, Length(Prefix)) = Prefix then
      begin
        Resource := TJSONObject.Create;
        Resources.Add(Resource);
        Resource.Add('uri', FFiles[I].Uri);
        Resource.Add('digest', FFiles[I].Digest);
        Resource.Add('size', Length(FFiles[I].Content));
      end;
  except
    Result.Free;
    raise;
  end;
end;

function UriParam(AParams: TJSONObject): string;
var
  Uri: TJSONData;
begin
  Uri := nil;
  if AParams <> nil then
    Uri := AParams.Find('uri');
  if (Uri = nil) or (Uri.JSONType <> jtString) then
    raise EMCPProtocolError.Create(JSONRPC_INVALID_PARAMS,
      'Invalid params: uri must be a string');
  Result := Uri.AsString;
end;

function NotFound(const AWhat, AUri: string): EMCPProtocolError;
var
  Data: TJSONObject;
begin
  Data := TJSONObject.Create;
  Data.Add('uri', AUri);
  Result := EMCPProtocolError.Create(JSONRPC_INVALID_PARAMS, AWhat +
    ' not found', Data);
end;

// The page AParams' cursor selects from a list of ACount entries under
// AKey (MCP.Pagination); -32602 for a cursor that is not one of its.
procedure SelectPage(AParams: TJSONObject; const AKey: string;
  ACount, APageSize: Integer; out AFirst, ALast: Integer);
var
  Cursor: TJSONData;
begin
  Cursor := nil;
  if AParams <> nil then
    Cursor := AParams.Find('cursor');
  if not PageBounds(Cursor, AKey, ACount, APageSize, AFirst, ALast) then
    raise EMCPProtocolError.Create(JSONRPC_INVALID_PARAMS,
      'Invalid params: unknown cursor');
end;

// skills.mdx, Listing Skills: paginated, "An entry is atomic, and a
// skill's resources set is never split across pages".
function TSkillCatalog.SkillsList(AParams: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
var
  Skills: TJSONArray;
  First, Last, I: Integer;
begin
  SelectPage(AParams, 'skills/list', Length(FSkills), FServer.PageSize, First,
    Last);
  Result := TJSONObject.Create;
  try
    Skills := TJSONArray.Create;
    Result.Add('skills', Skills);
    for I := First to Last do
      Skills.Add(SkillEntry(I));
    if Last < High(FSkills) then
      Result.Add('nextCursor', ListCursor('skills/list', Last + 1));
  except
    Result.Free;
    raise;
  end;
end;

// skills.mdx, Getting a Skill: "If the URI does not identify a skill
// the server serves, the server MUST return error -32602".
function TSkillCatalog.SkillsGet(AParams: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
var
  Uri: string;
  Index: Integer;
begin
  Uri := UriParam(AParams);
  Index := FileIndex(Uri);
  if (Index < 0) or (FFiles[Index].Skill < 0) then
    raise NotFound('Skill', Uri);
  Result := TJSONObject.Create;
  try
    Result.Add('skill', SkillEntry(FFiles[Index].Skill));
  except
    Result.Free;
    raise;
  end;
end;

// The Resource a directory read lists for file AFile: SKILL.md named
// and described from its frontmatter (skills.mdx, Resource Metadata).
function ChildFile(const AUri, AMimeType: string;
  AFrontmatter: TJSONObject): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('uri', AUri);
  if AFrontmatter <> nil then
  begin
    Result.Add('name', AFrontmatter.Get('name', ''));
    Result.Add('description', AFrontmatter.Get('description', ''));
  end
  else
    Result.Add('name', LastSegment(AUri));
  Result.Add('mimeType', AMimeType);
end;

// skills.mdx, Reading Directories: every direct child, subdirectories
// as inode/directory, paginated; -32602 for a URI that is no directory.
function TSkillCatalog.DirectoryRead(AParams: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
var
  Uri, Child: string;
  Children: array of string;
  I, J, First, Last, Slash, Index: Integer;
  Resources: TJSONArray;
  Frontmatter: TJSONObject;
begin
  Uri := UriParam(AParams);
  if not IsDirectory(Uri) then
    raise NotFound('Directory', Uri);
  // Direct children, each once, sorted by URI.
  Children := nil;
  for I := 0 to High(FFiles) do
    if Copy(FFiles[I].Uri, 1, Length(Uri) + 1) = Uri + '/' then
    begin
      Child := Copy(FFiles[I].Uri, Length(Uri) + 2, MaxInt);
      Slash := Pos('/', Child);
      if Slash > 0 then
        Child := Copy(Child, 1, Slash - 1);
      Child := Uri + '/' + Child;
      J := 0;
      while (J < Length(Children)) and (Children[J] < Child) do
        Inc(J);
      if (J < Length(Children)) and (Children[J] = Child) then
        Continue;
      Insert(Child, Children, J);
    end;
  SelectPage(AParams, 'resources/directory/read ' + Uri, Length(Children),
    FServer.PageSize, First, Last);
  Result := TJSONObject.Create;
  try
    Resources := TJSONArray.Create;
    Result.Add('resources', Resources);
    for I := First to Last do
    begin
      Index := FileIndex(Children[I]);
      if Index < 0 then
        Resources.Add(TJSONObject.Create(['uri', Children[I], 'name',
          LastSegment(Children[I]), 'mimeType', DIRECTORY_MIME_TYPE]))
      else
      begin
        Frontmatter := nil;
        if FFiles[Index].Skill >= 0 then
          Frontmatter := FSkills[FFiles[Index].Skill].Frontmatter;
        Resources.Add(ChildFile(Children[I], FFiles[Index].MimeType,
          Frontmatter));
      end;
    end;
    if Last < High(Children) then
      Result.Add('nextCursor', ListCursor('resources/directory/read ' + Uri,
        Last + 1));
  except
    Result.Free;
    raise;
  end;
end;

// The exact bytes the digest covers: as text when they are UTF-8, as
// a base64 blob otherwise.
function TSkillCatalog.ReadFile(const AUri: string;
  const ACtx: TMCPRequestContext): TJSONArray;
var
  Index: Integer;
  Bytes: TBytes;
  Text: string;
begin
  Index := FileIndex(AUri);
  if Index < 0 then
    Exit(nil);
  if InvalidUTF8Offset(FFiles[Index].Content) = 0 then
  begin
    // The validated bytes, copied as they are into the server's UTF-8
    // text.
    SetLength(Text, Length(FFiles[Index].Content));
    if Length(Text) > 0 then
      Move(FFiles[Index].Content[1], Text[1], Length(Text));
    Exit(MCPTextContents(AUri, FFiles[Index].MimeType, Text));
  end;
  SetLength(Bytes, Length(FFiles[Index].Content));
  if Length(Bytes) > 0 then
    Move(FFiles[Index].Content[1], Bytes[0], Length(Bytes));
  Result := MCPBlobContents(AUri, FFiles[Index].MimeType, MCPBase64(Bytes));
end;

procedure RegisterSkill(AServer: TMCPServer; const ASkillPath: string;
  AFrontmatter: TJSONObject; const ABody: string;
  const AFiles: array of TMCPSkillFile);
const
  METHODS: array[0..2] of string = ('skills/list', 'skills/get',
    'resources/directory/read');
var
  Catalog: TSkillCatalog;
  Fresh: Boolean;
  Problem: string;
begin
  // Every check comes before the server changes, so a refused first
  // call leaves no half-installed extension behind (#115 review).
  Fresh := False;
  try
    if AServer = nil then
      raise EMCPServer.Create('RegisterSkill needs a server');
    Catalog := TSkillCatalog(AServer.Adopted(TSkillCatalog));
    Fresh := Catalog = nil;
    if Fresh then
      Problem := AServer.HookProblem(METHODS, SKILL_SCHEME)
    else
      Problem := AServer.HookProblem([], '');
    if Problem <> '' then
      raise EMCPServer.Create(Problem);
  except
    AFrontmatter.Free;
    raise;
  end;
  if Fresh then
    Catalog := TSkillCatalog.Create(AServer);
  try
    Catalog.Add(ASkillPath, AFrontmatter, ABody, AFiles);
  except
    if Fresh then
      Catalog.Free;
    raise;
  end;
  if Fresh then
  begin
    AServer.Adopt(Catalog);
    AServer.RegisterMethod(METHODS[0], Catalog.SkillsList, True);
    AServer.RegisterMethod(METHODS[1], Catalog.SkillsGet, True);
    AServer.RegisterMethod(METHODS[2], Catalog.DirectoryRead, True);
    AServer.RegisterResourceResolver(SKILL_SCHEME, Catalog.ReadFile);
  end;
  // Settings declared first are kept.
  AServer.EnsureExtension(MCP_SKILLS_EXTENSION,
    TJSONObject.Create(['directoryRead', True]));
end;

end.
