{ MCP.Skills.Test — the Skills extension (#115): the declaration,
  skills/list and skills/get entries with digests computed outside
  Pascal (Python hashlib), the files over resources/read as text and as
  a blob, nested skills in the enclosing manifest, paging that keeps an
  entry whole, directory reads, the frontmatter writer and the
  registration guards. Shapes verified 2026-11-27 against
  modelcontextprotocol/ext-skills specification/beta/skills.mdx at
  ba23984 and https://agentskills.io/specification. }

program MCP.Skills.Test;

{$I MCP.inc}

uses
  SysUtils,

  fpjson,
  jsonparser,
  MCP.JSONRPC,
  MCP.Protocol,
  MCP.Server,
  MCP.Skills,
  MCP.Testing,
  TestingPascalLibrary;

const
  META =
    '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{}}';
  // sha256 and sizes from Python's hashlib over the exact bytes.
  DIGEST_GIT = 'sha256:66d07730c749a68c1cb8837eae6a59df47b04444b48bf76c9f6c631fd916c2c4';
  DIGEST_REBASE = 'sha256:9c3474bebc1f3cff4252f48d2b77b28f7ff9c22dd879eb86cd9f44db3fe77196';
  DIGEST_REFUNDS = 'sha256:9e1f9c19d7482d24e367227fbb5dc2fe9f289c386424bf0c75926be8e10977d8';
  DIGEST_COMMITS = 'sha256:ec6c670d5c3de3539ccc588c99ff9d82575ef9eadefe21b2fbe17e4467be5fa2';
  DIGEST_LOGO = 'sha256:d44c4eee8f72efac76c1f294e7260408825c8dad42adaaf6e9bee7e7ef4c7de3';
  DIGEST_EMAIL = 'sha256:7b7c2be2390a57bc8874adae23a60940ac18fa1fdadca60de307406f50d1aee8';

type
  TSkillsSuite = class(TTestSuite)
  private
    FServer: TMCPServer;
    FSession: TMCPSession;
    FClient: TMCPTestClient;
    function Send(const ALine: string): string;
    function Call(const AMethod, AParams: string): TJSONObject;
    procedure RegisterFixture;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;
    procedure TestDeclaration;
    procedure TestListEntries;
    procedure TestGetSkill;
    procedure TestReadFiles;
    procedure TestNestedManifest;
    procedure TestPaging;
    procedure TestDirectoryRead;
    procedure TestDirectoryPaging;
    procedure TestNotListed;
    procedure TestClassicEra;
    procedure TestMarkdownWriter;
    procedure TestRegistrationGuards;
    procedure TestLimits;
    procedure TestExplicitSettingsKept;
    procedure TestByteLimit;
    procedure TestAtomicFirstCall;
    procedure TestShadowingResource;
    procedure TestRawBytes;
    procedure TestTemplateCannotAddFiles;
    procedure TestNilFrontmatterMember;
  end;

  // A handler that takes skills/get first.
  TGuardHandler = class
  public
    function Answer(AParams: TJSONObject; const ACtx: TMCPRequestContext;
      ALegacy: Boolean): TJSONObject;
  end;

function ExtraReader(const AUri: string; AVariables: TJSONObject;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  Result := MCPTextContents(AUri, 'text/plain', 'extra');
end;

function Body(const AText: string): string;
begin
  Result := StringReplace(AText, '|', #10, [rfReplaceAll]);
end;

function Logo: string;
begin
  Result := #$89'PNG'#13#10#$1A#10#0#$FF;
end;

procedure TSkillsSuite.RegisterFixture;
var
  Description, GitBody: string;
begin
  Description := 'Follow the team''s Git conventions';
  // "Grüße", raw UTF-8 bytes, through a variable.
  GitBody := '# Git' + #10 + 'Gr' + #$C3#$BC + #$C3#$9F + 'e' + #10;
  RegisterSkill(FServer, 'git-workflow', TJSONObject.Create(['name',
    'git-workflow', 'description', Description]), GitBody,
    [MCPSkillFile('references/commits.md', Body('Use feat: and fix:|')),
    MCPSkillFile('assets/logo.png', Logo)]);
  RegisterSkill(FServer, 'git-workflow/rebase',
    TJSONObject(GetJSON('{"name":"rebase","description":"Rebase safely",' +
    '"metadata":{"owner":"platform"}}')), Body('Never force-push.|'), []);
  RegisterSkill(FServer, 'acme/billing/refunds', TJSONObject.Create(['name',
    'refunds', 'description', 'Process refunds', 'license', 'Apache-2.0']),
    Body('Check the order first.|'),
    [MCPSkillFile('examples/email.md', Body('Dear customer,|'))]);
end;

procedure TSkillsSuite.BeforeEach;
begin
  FServer := TMCPServer.Create('skills', '1.0');
  FSession := nil;
  FClient := nil;
end;

procedure TSkillsSuite.AfterEach;
begin
  FreeAndNil(FClient);
  FreeAndNil(FSession);
  FreeAndNil(FServer);
end;

function TSkillsSuite.Send(const ALine: string): string;
begin
  if FSession = nil then
    FSession := FServer.CreateSession;
  FServer.HandleMessage(FSession, ALine, Result);
end;

// Parsed answers through the test client (MCP.Testing), which adds the
// request metadata and parses as the server does; exact wire lines and
// the classic handshake use Send.
function TSkillsSuite.Call(const AMethod, AParams: string): TJSONObject;
begin
  if FClient = nil then
    FClient := TMCPTestClient.Create(FServer);
  Result := FClient.Request(AMethod, '{' + AParams + '}');
end;

function Str(AResponse: TJSONObject; const APath: string): string;
var
  Data: TJSONData;
begin
  Data := AResponse.FindPath(APath);
  if Data = nil then
    Exit('<absent>');
  Result := Data.AsString;
end;

// skills.mdx, Capability Negotiation: the extension with directoryRead,
// and the resources capability it requires.
procedure TSkillsSuite.TestDeclaration;
var
  Line: string;
begin
  RegisterFixture;
  Line := Send('{"jsonrpc":"2.0","id":1,"method":"server/discover",' +
    '"params":{' + META + '}}');
  Expect<Boolean>(Pos('"capabilities" : { "resources" : {}, "extensions" : ' +
    '{ "io.modelcontextprotocol/skills" : { "directoryRead" : true } } }',
    Line) > 0).ToBe(True);
end;

// skills.mdx, Listing Skills and Skill Entries, byte-exact.
procedure TSkillsSuite.TestListEntries;
var
  Line: string;
begin
  RegisterFixture;
  Line := Send('{"jsonrpc":"2.0","id":4,"method":"skills/list","params":{' +
    META + '}}');
  Expect<string>(Line).ToBe('{ "jsonrpc" : "2.0", "id" : 4, "result" : ' +
    '{ "skills" : [' +
    '{ "uri" : "skill://git-workflow/SKILL.md", "frontmatter" : ' +
    '{ "name" : "git-workflow", "description" : ' +
    '"Follow the team''s Git conventions" }, "resources" : [' +
    '{ "uri" : "skill://git-workflow/SKILL.md", "digest" : "' + DIGEST_GIT +
    '", "size" : 92 }, ' +
    '{ "uri" : "skill://git-workflow/references/commits.md", "digest" : "' +
    DIGEST_COMMITS + '", "size" : 19 }, ' +
    '{ "uri" : "skill://git-workflow/assets/logo.png", "digest" : "' +
    DIGEST_LOGO + '", "size" : 10 }, ' +
    '{ "uri" : "skill://git-workflow/rebase/SKILL.md", "digest" : "' +
    DIGEST_REBASE + '", "size" : 100 }] }, ' +
    '{ "uri" : "skill://git-workflow/rebase/SKILL.md", "frontmatter" : ' +
    '{ "name" : "rebase", "description" : "Rebase safely", "metadata" : ' +
    '{ "owner" : "platform" } }, "resources" : [' +
    '{ "uri" : "skill://git-workflow/rebase/SKILL.md", "digest" : "' +
    DIGEST_REBASE + '", "size" : 100 }] }, ' +
    '{ "uri" : "skill://acme/billing/refunds/SKILL.md", "frontmatter" : ' +
    '{ "name" : "refunds", "description" : "Process refunds", "license" : ' +
    '"Apache-2.0" }, "resources" : [' +
    '{ "uri" : "skill://acme/billing/refunds/SKILL.md", "digest" : "' +
    DIGEST_REFUNDS + '", "size" : 100 }, ' +
    '{ "uri" : "skill://acme/billing/refunds/examples/email.md", ' +
    '"digest" : "' + DIGEST_EMAIL + '", "size" : 15 }] }], ' +
    '"ttlMs" : 300000, "cacheScope" : "private", "resultType" : "complete", ' +
    '"_meta" : { "io.modelcontextprotocol/serverInfo" : { "name" : "skills", ' +
    '"version" : "1.0" } } } }');
end;

// skills.mdx, Getting a Skill: the entry, and -32602 for a URI that is
// no skill, a supporting file included.
procedure TSkillsSuite.TestGetSkill;
var
  Response: TJSONObject;
begin
  RegisterFixture;
  Expect<string>(Send('{"jsonrpc":"2.0","id":5,"method":"skills/get",' +
    '"params":{"uri":"skill://acme/billing/refunds/SKILL.md",' + META + '}}'))
    .ToBe('{ "jsonrpc" : "2.0", "id" : 5, "result" : { "skill" : ' +
    '{ "uri" : "skill://acme/billing/refunds/SKILL.md", "frontmatter" : ' +
    '{ "name" : "refunds", "description" : "Process refunds", "license" : ' +
    '"Apache-2.0" }, "resources" : [' +
    '{ "uri" : "skill://acme/billing/refunds/SKILL.md", "digest" : "' +
    DIGEST_REFUNDS + '", "size" : 100 }, ' +
    '{ "uri" : "skill://acme/billing/refunds/examples/email.md", ' +
    '"digest" : "' + DIGEST_EMAIL + '", "size" : 15 }] }, ' +
    '"ttlMs" : 300000, "cacheScope" : "private", "resultType" : "complete", ' +
    '"_meta" : { "io.modelcontextprotocol/serverInfo" : { "name" : "skills", ' +
    '"version" : "1.0" } } } }');
  Response := Call('skills/get', '"uri":"skill://acme/billing/refunds/SKILL.md"');
  try
    Expect<string>(Str(Response, 'result.skill.frontmatter.license'))
      .ToBe('Apache-2.0');
    Expect<string>(Str(Response, 'result.skill.resources[1].digest'))
      .ToBe(DIGEST_EMAIL);
    Expect<string>(Str(Response, 'result.resultType')).ToBe('complete');
    Expect<string>(Str(Response, 'result.cacheScope')).ToBe('private');
    Expect<Boolean>(Response.FindPath('result.nextCursor') = nil).ToBe(True);
  finally
    Response.Free;
  end;
  Expect<string>(Send('{"jsonrpc":"2.0","id":2,"method":"skills/get",' +
    '"params":{"uri":"skill://git-workflow/references/commits.md",' + META +
    '}}')).ToBe('{ "jsonrpc" : "2.0", "id" : 2, "error" : { "code" : ' +
    '-32602, "message" : "Skill not found", "data" : { "uri" : ' +
    '"skill://git-workflow/references/commits.md" } } }');
  Response := Call('skills/get', '');
  try
    Expect<Integer>(TJSONData(Response.FindPath('error.code')).AsInteger)
      .ToBe(-32602);
  finally
    Response.Free;
  end;
end;

// The exact bytes the digests cover: SKILL.md as written, non-ASCII
// text as text, the PNG as a base64 blob.
procedure TSkillsSuite.TestReadFiles;
var
  Line: string;
begin
  RegisterFixture;
  Line := Send('{"jsonrpc":"2.0","id":1,"method":"resources/read",' +
    '"params":{"uri":"skill://git-workflow/SKILL.md",' + META + '}}');
  Expect<Boolean>(Pos('"contents" : [{ "uri" : ' +
    '"skill://git-workflow/SKILL.md", "mimeType" : "text/markdown", ' +
    '"text" : "---\nname: \"git-workflow\"\ndescription: \"Follow the ' +
    'team''s Git conventions\"\n---\n# Git\nGr' + #$C3#$BC + #$C3#$9F +
    'e\n" }]', Line) > 0).ToBe(True);
  Line := Send('{"jsonrpc":"2.0","id":2,"method":"resources/read",' +
    '"params":{"uri":"skill://git-workflow/assets/logo.png",' + META + '}}');
  Expect<Boolean>(Pos('"contents" : [{ "uri" : ' +
    '"skill://git-workflow/assets/logo.png", "mimeType" : "image/png", ' +
    '"blob" : "iVBORw0KGgoA/w==" }]', Line) > 0).ToBe(True);
  Line := Send('{"jsonrpc":"2.0","id":3,"method":"resources/read",' +
    '"params":{"uri":"skill://git-workflow/nope.md",' + META + '}}');
  Expect<Boolean>(Pos('"code" : -32602', Line) > 0).ToBe(True);
end;

// skills.mdx, Resources: "Completeness extends to nested skills".
procedure TSkillsSuite.TestNestedManifest;
var
  Response: TJSONObject;
begin
  RegisterFixture;
  Response := Call('skills/get', '"uri":"skill://git-workflow/SKILL.md"');
  try
    Expect<Integer>(TJSONArray(Response.FindPath('result.skill.resources'))
      .Count).ToBe(4);
    Expect<string>(Str(Response, 'result.skill.resources[3].uri'))
      .ToBe('skill://git-workflow/rebase/SKILL.md');
  finally
    Response.Free;
  end;
end;

// Pages of whole entries; the cursor of one page leads to the next,
// and a made-up one is -32602.
procedure TSkillsSuite.TestPaging;
var
  Response: TJSONObject;
  Cursor: string;
begin
  FServer.PageSize := 2;
  RegisterFixture;
  Response := Call('skills/list', '');
  try
    Expect<Integer>(TJSONArray(Response.FindPath('result.skills')).Count)
      .ToBe(2);
    Expect<Integer>(TJSONArray(Response.FindPath(
      'result.skills[0].resources')).Count).ToBe(4);
    Cursor := Str(Response, 'result.nextCursor');
  finally
    Response.Free;
  end;
  Response := Call('skills/list', '"cursor":"' + Cursor + '"');
  try
    Expect<Integer>(TJSONArray(Response.FindPath('result.skills')).Count)
      .ToBe(1);
    Expect<string>(Str(Response, 'result.skills[0].frontmatter.name'))
      .ToBe('refunds');
    Expect<Boolean>(Response.FindPath('result.nextCursor') = nil).ToBe(True);
  finally
    Response.Free;
  end;
  Response := Call('skills/list', '"cursor":"bm9wZQ=="');
  try
    Expect<Integer>(TJSONData(Response.FindPath('error.code')).AsInteger)
      .ToBe(-32602);
  finally
    Response.Free;
  end;
end;

// skills.mdx, Reading Directories: direct children sorted, directories
// as inode/directory, SKILL.md named from its frontmatter; -32602 for a
// file or an unknown URI.
procedure TSkillsSuite.TestDirectoryRead;
var
  Line: string;
  Response: TJSONObject;
begin
  RegisterFixture;
  Line := Send('{"jsonrpc":"2.0","id":7,"method":"resources/directory/read",' +
    '"params":{"uri":"skill://git-workflow",' + META + '}}');
  Expect<Boolean>(Pos('"resources" : [' +
    '{ "uri" : "skill://git-workflow/SKILL.md", "name" : "git-workflow", ' +
    '"description" : "Follow the team''s Git conventions", "mimeType" : ' +
    '"text/markdown" }, ' +
    '{ "uri" : "skill://git-workflow/assets", "name" : "assets", ' +
    '"mimeType" : "inode/directory" }, ' +
    '{ "uri" : "skill://git-workflow/rebase", "name" : "rebase", ' +
    '"mimeType" : "inode/directory" }, ' +
    '{ "uri" : "skill://git-workflow/references", "name" : "references", ' +
    '"mimeType" : "inode/directory" }], "ttlMs" : 300000', Line) > 0)
    .ToBe(True);
  Response := Call('resources/directory/read',
    '"uri":"skill://git-workflow/references"');
  try
    Expect<string>(Str(Response, 'result.resources[0].name'))
      .ToBe('commits.md');
    Expect<string>(Str(Response, 'result.resources[0].mimeType'))
      .ToBe('text/markdown');
  finally
    Response.Free;
  end;
  // A directory above the skills is one too.
  Response := Call('resources/directory/read', '"uri":"skill://acme"');
  try
    Expect<string>(Str(Response, 'result.resources[0].uri'))
      .ToBe('skill://acme/billing');
  finally
    Response.Free;
  end;
  Response := Call('resources/directory/read',
    '"uri":"skill://git-workflow/SKILL.md"');
  try
    Expect<string>(Str(Response, 'error.message')).ToBe('Directory not found');
  finally
    Response.Free;
  end;
  Response := Call('resources/directory/read', '"uri":"skill:"');
  try
    Expect<string>(Str(Response, 'error.message')).ToBe('Directory not found');
  finally
    Response.Free;
  end;
  Response := Call('resources/directory/read', '"uri":"skill:/"');
  try
    Expect<string>(Str(Response, 'error.message')).ToBe('Directory not found');
  finally
    Response.Free;
  end;
  Response := Call('resources/directory/read', '"uri":"skill://git"');
  try
    Expect<Integer>(TJSONData(Response.FindPath('error.code')).AsInteger)
      .ToBe(-32602);
  finally
    Response.Free;
  end;
end;

// A directory's cursor is its own: another directory's is refused.
procedure TSkillsSuite.TestDirectoryPaging;
var
  Response: TJSONObject;
  Cursor: string;
begin
  FServer.PageSize := 3;
  RegisterFixture;
  // Five children, so offset 3 is a page boundary here too.
  RegisterSkill(FServer, 'many', TJSONObject.Create(['name', 'many',
    'description', 'd']), 'Body', [MCPSkillFile('a.md', 'a'),
    MCPSkillFile('b.md', 'b'), MCPSkillFile('c.md', 'c'),
    MCPSkillFile('d.md', 'd')]);
  Response := Call('resources/directory/read', '"uri":"skill://git-workflow"');
  try
    Expect<Integer>(TJSONArray(Response.FindPath('result.resources')).Count)
      .ToBe(3);
    Cursor := Str(Response, 'result.nextCursor');
  finally
    Response.Free;
  end;
  Response := Call('resources/directory/read', '"uri":"skill://git-workflow",' +
    '"cursor":"' + Cursor + '"');
  try
    Expect<string>(Str(Response, 'result.resources[0].name'))
      .ToBe('references');
  finally
    Response.Free;
  end;
  Response := Call('resources/directory/read', '"uri":"skill://many",' +
    '"cursor":"' + Cursor + '"');
  try
    Expect<Integer>(TJSONData(Response.FindPath('error.code')).AsInteger)
      .ToBe(-32602);
  finally
    Response.Free;
  end;
end;

// Skill files are read, not listed.
procedure TSkillsSuite.TestNotListed;
var
  Response: TJSONObject;
begin
  RegisterFixture;
  Response := Call('resources/list', '');
  try
    Expect<Integer>(TJSONArray(Response.FindPath('result.resources')).Count)
      .ToBe(0);
  finally
    Response.Free;
  end;
end;

// The classic handshake gets the same entries, without the 2026-07-28
// result stamps.
procedure TSkillsSuite.TestClassicEra;
var
  Line: string;
begin
  RegisterFixture;
  Send('{"jsonrpc":"2.0","id":1,"method":"initialize","params":' +
    '{"protocolVersion":"2025-11-25","capabilities":{},' +
    '"clientInfo":{"name":"c","version":"1"}}}');
  Send('{"jsonrpc":"2.0","method":"notifications/initialized"}');
  Line := Send('{"jsonrpc":"2.0","id":2,"method":"skills/get","params":' +
    '{"uri":"skill://git-workflow/rebase/SKILL.md"}}');
  Expect<Boolean>(Pos('"skill" : { "uri" : ' +
    '"skill://git-workflow/rebase/SKILL.md"', Line) > 0).ToBe(True);
  Expect<Boolean>(Pos('resultType', Line) = 0).ToBe(True);
  Expect<Boolean>(Pos('ttlMs', Line) = 0).ToBe(True);
end;

// Strings double-quoted with the escapes YAML 1.1 and 1.2 share (no
// "\/"), keys YAML 1.1 would resolve quoted, nested maps and lists.
procedure TSkillsSuite.TestMarkdownWriter;
var
  Frontmatter: TJSONObject;
  Text: string;
begin
  Text := 'a/b "q" \ ' + #9 + #10 + #$7F + #$C2#$85 + #$C3#$A9;
  Frontmatter := TJSONObject.Create(['name', 'x', 'description', Text,
    'on', True, 'with space', 3, 'metadata', TJSONObject.Create(['k', 'v']),
    'tags', TJSONArray.Create(['a', 'b']), 'empty', TJSONObject.Create,
    'none', TJSONNull.Create, 'license', '',
    'examples', TJSONArray.Create([TJSONObject.Create(['title', 's']),
    TJSONArray.Create([1, 2])])]);
  try
    // U+FFFE and U+2028 from JSON, parsed as the server parses requests:
    // a Pascal constant or plain GetJSON would convert them on the way.
    Frontmatter.Add('odd', MCPParseJSON('"\uFFFE\u2028  x"'));
    Expect<string>(MCPSkillMarkdown(Frontmatter, 'Body')).ToBe('---' + #10 +
      'name: "x"' + #10 +
      'description: "a/b \"q\" \\ \u0009\n\u007F\u0085' + #$C3#$A9 + '"' +
      #10 +
      '"on": true' + #10 +
      '"with space": 3' + #10 +
      'metadata:' + #10 + '  k: "v"' + #10 +
      'tags:' + #10 + '  - "a"' + #10 + '  - "b"' + #10 +
      'empty: {}' + #10 +
      'none: null' + #10 +
      'license: ""' + #10 +
      'examples:' + #10 + '  -' + #10 + '    title: "s"' + #10 +
      '  -' + #10 + '    - 1' + #10 + '    - 2' + #10 +
      'odd: "\uFFFE\u2028  x"' + #10 +
      '---' + #10 + 'Body');
  finally
    Frontmatter.Free;
  end;
end;

var
  GuardServer: TMCPServer;
  GuardHandler: TGuardHandler;

function TGuardHandler.Answer(AParams: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
begin
  Result := TJSONObject.Create;
end;

var
  GuardBody: string = 'Body';

function Refused(const APath, AFrontmatter: string;
  const AFiles: array of TMCPSkillFile): Boolean;
begin
  Result := False;
  try
    RegisterSkill(GuardServer, APath, TJSONObject(GetJSON(AFrontmatter)),
      GuardBody, AFiles);
  except
    on E: EMCPServer do
      Result := True;
  end;
end;

// The Agent Skills name and field rules, URI-safe paths, one URI per
// file, and nothing after the server started.
procedure TSkillsSuite.TestRegistrationGuards;
const
  OK = '{"name":"ok","description":"d"}';
begin
  GuardServer := FServer;
  try
    Expect<Boolean>(Refused('Bad', '{"name":"Bad","description":"d"}', []))
      .ToBe(True);
    Expect<Boolean>(Refused('a--b', '{"name":"a--b","description":"d"}', []))
      .ToBe(True);
    Expect<Boolean>(Refused('-a', '{"name":"-a","description":"d"}', []))
      .ToBe(True);
    Expect<Boolean>(Refused('x/ok', '{"name":"other","description":"d"}', []))
      .ToBe(True);
    Expect<Boolean>(Refused('ok', '{"name":"ok"}', [])).ToBe(True);
    Expect<Boolean>(Refused('ok', '{"name":"ok","description":""}', []))
      .ToBe(True);
    Expect<Boolean>(Refused('ok', '{"name":"ok","description":"d",' +
      '"compatibility":""}', [])).ToBe(True);
    Expect<Boolean>(Refused('ok', '{"name":"ok","description":"d",' +
      '"metadata":{"n":1}}', [])).ToBe(True);
    Expect<Boolean>(Refused('ok', '{"name":"ok","description":"d",' +
      '"score":1.5}', [])).ToBe(True);
    // fpjson keeps keys to 255 characters, but escapes write each control
    // character as six: 200 of them pass the 1024 YAML parsers read.
    Expect<Boolean>(Refused('ok', '{"name":"ok","description":"d","' +
      StringReplace(StringOfChar('!', 200), '!', '\u0001', [rfReplaceAll]) +
      '":"v"}', [])).ToBe(True);
    // Files that clash among themselves or claim the directory type.
    Expect<Boolean>(Refused('ok', OK, [MCPSkillFile('refs', 'x'),
      MCPSkillFile('refs/guide.md', 'y')])).ToBe(True);
    Expect<Boolean>(Refused('ok', OK, [MCPSkillFile('SKILL.md/guide.md',
      'y')])).ToBe(True);
    Expect<Boolean>(Refused('ok', OK, [MCPSkillFile('d', 'x',
      'inode/directory')])).ToBe(True);
    // SKILL.md is text a host parses.
    // A lone $FF byte, set at run time: a constant would be converted.
    GuardBody := 'Bad x';
    GuardBody[5] := Chr($FF);
    Expect<Boolean>(Refused('ok', OK, [])).ToBe(True);
    GuardBody := 'Body';
    Expect<Boolean>(Refused('a b/ok', OK, [])).ToBe(True);
    Expect<Boolean>(Refused('../ok', OK, [])).ToBe(True);
    Expect<Boolean>(Refused('ok', OK, [MCPSkillFile('../x.md', 'x')]))
      .ToBe(True);
    Expect<Boolean>(Refused('ok', OK, [MCPSkillFile('SKILL.md', 'x')]))
      .ToBe(True);
    Expect<Boolean>(Refused('ok', OK, [MCPSkillFile('a.md', 'x'),
      MCPSkillFile('a.md', 'y')])).ToBe(True);
    // Accepted, then the same URI again, and a file under a file.
    Expect<Boolean>(Refused('ok', OK, [MCPSkillFile('a.md', 'x')]))
      .ToBe(False);
    Expect<Boolean>(Refused('ok', OK, [])).ToBe(True);
    Expect<Boolean>(Refused('ok/a.md/deeper', '{"name":"deeper",' +
      '"description":"d"}', [])).ToBe(True);
    // The refused registrations left nothing behind.
    Expect<Boolean>(Pos('"skills" : [{ "uri" : "skill://ok/SKILL.md"',
      Send('{"jsonrpc":"2.0","id":1,"method":"skills/list","params":{' +
      META + '}}')) > 0).ToBe(True);
    Expect<Boolean>(Refused('later', '{"name":"later","description":"d"}',
      [])).ToBe(True);
  finally
    GuardServer := nil;
  end;
end;

// skills.mdx, Limits: 512 files, counting a nested skill's in its
// enclosing one; the refused skill is not served.
procedure TSkillsSuite.TestLimits;
var
  Files: array of TMCPSkillFile;
  I: Integer;
  Line: string;
begin
  SetLength(Files, 510);
  for I := 0 to High(Files) do
    Files[I] := MCPSkillFile('f' + IntToStr(I) + '.md', 'x');
  RegisterSkill(FServer, 'big', TJSONObject.Create(['name', 'big',
    'description', 'd']), 'Body', Files);
  RegisterSkill(FServer, 'big/inner', TJSONObject.Create(['name', 'inner',
    'description', 'd']), 'Body', []);
  GuardServer := FServer;
  try
    Expect<Boolean>(Refused('big/more', '{"name":"more","description":"d"}',
      [])).ToBe(True);
  finally
    GuardServer := nil;
  end;
  Line := Send('{"jsonrpc":"2.0","id":1,"method":"skills/get","params":' +
    '{"uri":"skill://big/more/SKILL.md",' + META + '}}');
  Expect<Boolean>(Pos('Skill not found', Line) > 0).ToBe(True);
end;

// 16 MiB, the generated SKILL.md counted: one byte over is refused.
procedure TSkillsSuite.TestByteLimit;
const
  // '---\nname: "big"\ndescription: "d"\n---\nBody'
  SKILL_MD_BYTES = 41;
begin
  RegisterSkill(FServer, 'big', TJSONObject.Create(['name', 'big',
    'description', 'd']), 'Body', [MCPSkillFile('blob.bin',
    StringOfChar('x', MCP_SKILL_MAX_BYTES - SKILL_MD_BYTES))]);
  GuardServer := FServer;
  try
    // A name of the same length, so its SKILL.md is the same size too.
    Expect<Boolean>(Refused('bog', '{"name":"bog","description":"d"}',
      [MCPSkillFile('blob.bin', StringOfChar('x', MCP_SKILL_MAX_BYTES -
      SKILL_MD_BYTES + 1))])).ToBe(True);
  finally
    GuardServer := nil;
  end;
end;

// A refused first call installs nothing, and a later valid one works.
procedure TSkillsSuite.TestAtomicFirstCall;
var
  Line: string;
begin
  GuardServer := FServer;
  try
    Expect<Boolean>(Refused('Bad', '{"name":"Bad","description":"d"}', []))
      .ToBe(True);
    Line := Send('{"jsonrpc":"2.0","id":1,"method":"server/discover",' +
      '"params":{' + META + '}}');
    Expect<Boolean>(Pos(MCP_SKILLS_EXTENSION, Line) = 0).ToBe(True);
    FreeAndNil(FSession);
    FreeAndNil(FServer);
    // A method the hooks already serve blocks the whole setup.
    FServer := TMCPServer.Create('skills', '1.0');
    GuardServer := FServer;
    FServer.RegisterMethod('skills/get', GuardHandler.Answer);
    Expect<Boolean>(Refused('ok', '{"name":"ok","description":"d"}', []))
      .ToBe(True);
    Line := Send('{"jsonrpc":"2.0","id":2,"method":"skills/list",' +
      '"params":{' + META + '}}');
    Expect<Boolean>(Pos('"code" : -32601', Line) > 0).ToBe(True);
    Expect<Boolean>(Pos(MCP_SKILLS_EXTENSION, Send('{"jsonrpc":"2.0","id":3,' +
      '"method":"server/discover","params":{' + META + '}}')) = 0).ToBe(True);
  finally
    GuardServer := nil;
  end;
end;

// A registered resource under skill:// would shadow a skill file:
// startup fails, whichever was registered first.
procedure TSkillsSuite.TestShadowingResource;
var
  Message: string;
begin
  FServer.RegisterTextResource('skill://x/SKILL.md', 'x', 'text/markdown',
    'shadow');
  RegisterSkill(FServer, 'x', TJSONObject.Create(['name', 'x',
    'description', 'd']), 'Body', []);
  Message := '';
  try
    FServer.CreateSession.Free;
  except
    on E: EMCPServer do
      Message := E.Message;
  end;
  Expect<string>(Message).ToBe('Resource "skill://x/SKILL.md" lies under a ' +
    'URI prefix an extension serves');
end;

// The bytes as given, whatever code page a string carries: a $E9 tagged
// Windows-1252 is one byte, hashed and served as a blob, not converted
// to UTF-8 on the way (#115 review). Digest from Python's hashlib.
procedure TSkillsSuite.TestRawBytes;
var
  Latin: RawByteString;
  Response: TJSONObject;
begin
  Latin := 'x';
  Latin[1] := Chr($E9);
  SetCodePage(Latin, 1252, False);
  RegisterSkill(FServer, 'raw', TJSONObject.Create(['name', 'raw',
    'description', 'd']), 'Body', [MCPSkillFile('latin.txt', Latin)]);
  Response := Call('skills/get', '"uri":"skill://raw/SKILL.md"');
  try
    Expect<string>(Str(Response, 'result.skill.resources[1].digest'))
      .ToBe('sha256:de2e331d891ae267a7009cb45b4e8830f170e0c937288ea2731a1941c7a53b0d');
    Expect<Integer>(TJSONData(Response.FindPath(
      'result.skill.resources[1].size')).AsInteger).ToBe(1);
  finally
    Response.Free;
  end;
  Response := Call('resources/read', '"uri":"skill://raw/latin.txt"');
  try
    Expect<string>(Str(Response, 'result.contents[0].blob')).ToBe('6Q==');
  finally
    Response.Free;
  end;
end;

// Under skill:// only the catalog answers: a template there does not
// serve a file the manifest leaves out (#115 review).
procedure TSkillsSuite.TestTemplateCannotAddFiles;
var
  Response: TJSONObject;
begin
  FServer.RegisterResourceTemplate('skill://x/{name}', 'extra',
    'text/plain', ExtraReader);
  RegisterSkill(FServer, 'x', TJSONObject.Create(['name', 'x',
    'description', 'd']), 'Body', []);
  Response := Call('resources/read', '"uri":"skill://x/extra.md"');
  try
    Expect<Integer>(TJSONData(Response.FindPath('error.code')).AsInteger)
      .ToBe(-32602);
  finally
    Response.Free;
  end;
  Response := Call('resources/read', '"uri":"skill://x/SKILL.md"');
  try
    Expect<string>(Str(Response, 'result.contents[0].mimeType'))
      .ToBe('text/markdown');
  finally
    Response.Free;
  end;
end;

// A member stored as nil is a null, and checked as one (#115 review).
procedure TSkillsSuite.TestNilFrontmatterMember;
var
  Frontmatter: TJSONObject;
  Raised: Boolean;
begin
  Frontmatter := TJSONObject.Create(['name', 'n', 'description', 'd']);
  Frontmatter.Add('license', TJSONData(nil));
  Raised := False;
  try
    RegisterSkill(FServer, 'n', Frontmatter, 'Body', []);
  except
    on E: EMCPServer do
      Raised := Pos('"license" must be a string', E.Message) > 0;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

// Settings declared first survive the opt-in, as for MCP Apps.
procedure TSkillsSuite.TestExplicitSettingsKept;
begin
  FServer.DeclareExtension(MCP_SKILLS_EXTENSION);
  RegisterFixture;
  Expect<Boolean>(Pos('"io.modelcontextprotocol/skills" : {}',
    Send('{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{' +
    META + '}}')) > 0).ToBe(True);
end;

procedure TSkillsSuite.SetupTests;
begin
  Test('the extension and the resources capability are declared',
    TestDeclaration);
  Test('skills/list entries with digests, byte-exact', TestListEntries);
  Test('skills/get, and -32602 for a URI that is no skill', TestGetSkill);
  Test('files read as written: text, non-ASCII and a blob', TestReadFiles);
  Test('an enclosing skill lists its nested skill''s files',
    TestNestedManifest);
  Test('skills/list pages whole entries', TestPaging);
  Test('directory reads: children, directories, -32602', TestDirectoryRead);
  Test('a directory read cursor belongs to its directory',
    TestDirectoryPaging);
  Test('skill files are not in resources/list', TestNotListed);
  Test('classic clients get entries without the modern stamps',
    TestClassicEra);
  Test('the frontmatter writer quotes for YAML 1.1 and 1.2',
    TestMarkdownWriter);
  Test('names, fields, paths and URIs are checked at registration',
    TestRegistrationGuards);
  Test('the file limit counts nested skills', TestLimits);
  Test('explicit extension settings survive the opt-in',
    TestExplicitSettingsKept);
  Test('the byte limit counts SKILL.md, refusing one byte over',
    TestByteLimit);
  Test('a refused first call installs nothing', TestAtomicFirstCall);
  Test('a resource under skill:// fails startup', TestShadowingResource);
  Test('file bytes are kept whatever their code page', TestRawBytes);
  Test('a template under skill:// serves no file of a skill',
    TestTemplateCannotAddFiles);
  Test('a frontmatter member stored as nil is checked as null',
    TestNilFrontmatterMember);
end;

begin
  GuardHandler := TGuardHandler.Create;
  TestRunnerProgram.AddSuite(TSkillsSuite.Create('Skills: Skills extension'));
  TestRunnerProgram.Run;
end.
