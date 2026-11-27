{ MCP.Frontmatter.Test — the YAML subset a SKILL.md frontmatter is read
  with (#117). Every accepted case's expected JSON is what PyYAML 6.0.1
  (YAML 1.1), js-yaml 4.1.0 and yaml 2.6.1 (YAML 1.2) read from the same
  text, checked 2026-11-27; every refused case names its line. The 24
  SKILL.md files of this repository's .agents/skills read the same in
  all four on that date. }

program MCP.Frontmatter.Test;

{$I MCP.inc}

uses
  StrUtils,
  SysUtils,

  fpjson,
  MCP.Frontmatter,
  TestingPascalLibrary;

type
  TFrontmatterSuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestScalars;
    procedure TestBlockScalars;
    procedure TestCollections;
    procedure TestLinesAndComments;
    procedure TestRefused;
    procedure TestDocumentShape;
  end;

// The compact JSON of the frontmatter in ALines' "^"-separated lines,
// or "REFUSED " and the problem.
function Parsed(const ALines: string): string;
var
  Frontmatter: TJSONObject;
  Problem: string;
begin
  if not ParseFrontmatter('---' + #10 + StringReplace(ALines, '^', #10,
    [rfReplaceAll]) + '---' + #10 + 'Body' + #10, Frontmatter, Problem) then
    Exit('REFUSED ' + Problem);
  try
    Result := Frontmatter.FormatJSON([foSingleLineArray, foSingleLineObject,
      foSkipWhiteSpace]);
  finally
    Frontmatter.Free;
  end;
end;

procedure TFrontmatterSuite.TestScalars;
begin
  Expect<string>(Parsed('name: a^description: Extract PDF text, fill ' +
    'forms. Use when needed.^')).ToBe('{"name":"a","description":"Extract ' +
    'PDF text, fill forms. Use when needed."}');
  Expect<string>(Parsed('name: "a"^description: ''it''''s fine''^other: ' +
    '"x\tyé\x41\U0001F600"^')).ToBe('{"name":"a","description":' +
    '"it''s fine","other":"x\ty' + #$C3#$A9 + 'A' + #$F0#$9F#$98#$80 + '"}');
  Expect<string>(Parsed('description: "Grüße"^plain: Gr' +
    #$C3#$BC#$C3#$9F + 'e und so^')).ToBe('{"description":"Gr' + #$C3#$BC +
    #$C3#$9F + 'e","plain":"Gr' + #$C3#$BC#$C3#$9F + 'e und so"}');
  Expect<string>(Parsed('url: http://example.com/x^')).ToBe(
    '{"url":"http://example.com/x"}');
  Expect<string>(Parsed('"on": 1^''yes key'': 2^')).ToBe(
    '{"on":1,"yes key":2}');
  Expect<string>(Parsed('a: -x^b: ?y^c: :z^n2: -7^')).ToBe(
    '{"a":"-x","b":"?y","c":":z","n2":-7}');
  Expect<string>(Parsed('count: 3^zero: 0^t: true^f: false^nil: null^' +
    'tilde: ~^empty_obj: {}^empty_list: []^nothing:^')).ToBe('{"count":3,' +
    '"zero":0,"t":true,"f":false,"nil":null,"tilde":null,"empty_obj":{},' +
    '"empty_list":[],"nothing":null}');
end;

procedure TFrontmatterSuite.TestBlockScalars;
begin
  Expect<string>(Parsed('description: >-^  Line one^  continues^^  new ' +
    'para^')).ToBe('{"description":"Line one continues\nnew para"}');
  Expect<string>(Parsed('description: >^  a^  b^^^')).ToBe(
    '{"description":"a b\n"}');
  Expect<string>(Parsed('description: >+^  a^  b^^^next: x^')).ToBe(
    '{"description":"a b\n\n\n","next":"x"}');
  Expect<string>(Parsed('description: |^  line 1^    indented^  line 3^'))
    .ToBe('{"description":"line 1\n  indented\nline 3\n"}');
  Expect<string>(Parsed('description: |-^  a^^  b^^')).ToBe(
    '{"description":"a\n\nb"}');
  Expect<string>(Parsed('description: |+^  a^^^x: z^')).ToBe(
    '{"description":"a\n\n\n","x":"z"}');
  Expect<string>(Parsed('d: >^^  a^  b^')).ToBe('{"d":"\na b\n"}');
end;

procedure TFrontmatterSuite.TestCollections;
begin
  Expect<string>(Parsed('metadata:^  author: example-org^  version: "1.0"^' +
    '  deep:^    k: v^')).ToBe('{"metadata":{"author":"example-org",' +
    '"version":"1.0","deep":{"k":"v"}}}');
  Expect<string>(Parsed('tags:^  - a^  - "b c"^  -^    k: v^  -^    - 1^' +
    '    - 2^')).ToBe('{"tags":["a","b c",{"k":"v"},[1,2]]}');
  Expect<string>(Parsed('tags:^- a^- b^next: c^')).ToBe(
    '{"tags":["a","b"],"next":"c"}');
end;

procedure TFrontmatterSuite.TestLinesAndComments;
begin
  Expect<string>(Parsed('description: This is a long^  description over^' +
    '  three lines^name: x^')).ToBe('{"description":"This is a long ' +
    'description over three lines","name":"x"}');
  Expect<string>(Parsed('# comment^name: a^  # indented comment^' +
    'description: b^')).ToBe('{"name":"a","description":"b"}');
end;

// What the two YAML versions read differently, or this reader does not
// read, names its line (the frontmatter starts on line 2).
procedure TFrontmatterSuite.TestRefused;
begin
  Expect<string>(Parsed('flag: yes^')).ToBe('REFUSED line 2: "yes" is not ' +
    'a string in every YAML version; quote it');
  Expect<string>(Parsed('x: True^')).ToBe('REFUSED line 2: "True" is not a ' +
    'string in every YAML version; quote it');
  Expect<string>(Parsed('version: 1.0^')).ToBe('REFUSED line 2: "1.0" starts ' +
    'with a digit, a sign or a dot, which is read here only quoted; quote it');
  Expect<string>(Parsed('mode: 012^')).ToBe('REFUSED line 2: "012" starts ' +
    'with a digit, a sign or a dot, which is read here only quoted; quote it');
  Expect<string>(Parsed('when: 2026-01-01^')).ToBe('REFUSED line 2: ' +
    '"2026-01-01" starts with a digit, a sign or a dot, which is read here ' +
    'only quoted; quote it');
  // Refused even where both versions read text: simpler than telling
  // numbers, dates and times apart.
  Expect<string>(Parsed('name: 3d-printing^')).ToBe('REFUSED line 2: ' +
    '"3d-printing" starts with a digit, a sign or a dot, which is read ' +
    'here only quoted; quote it');
  Expect<string>(Parsed('on: 1^')).ToBe('REFUSED line 2: the key "on" is ' +
    'not a string in every YAML version; quote it');
  Expect<Boolean>(Pos('REFUSED line 2: flow collections',
    Parsed('tags: [a, b]^')) = 1).ToBe(True);
  Expect<Boolean>(Pos('REFUSED line 2: flow collections',
    Parsed('a: &x 1^b: *x^')) = 1).ToBe(True);
  Expect<string>(Parsed('name: a # note^')).ToBe('REFUSED line 2: a plain ' +
    'value with ": " or " #"; quote it');
  Expect<Boolean>(Pos('REFUSED line 3: a tab, control',
    Parsed('metadata:^' + #9 + 'k: v^')) = 1).ToBe(True);
  Expect<string>(Parsed('a: 1^a: 2^')).ToBe('REFUSED line 3: the key "a" ' +
    'appears twice');
  Expect<string>(Parsed('a: "x\/y"^')).ToBe('REFUSED line 2: the escape \/, ' +
    'which YAML 1.1 and 1.2 do not share');
  Expect<string>(Parsed('items:^  - k: v^')).ToBe('REFUSED line 3: a mapping ' +
    'on a dash line; write it on the lines below the dash');
  Expect<string>(Parsed('d: >^  a^    b^')).ToBe('REFUSED line 4: a ' +
    'more-indented line in a folded block scalar; use |');
  Expect<string>(Parsed('d: - x^')).ToBe('REFUSED line 2: flow collections, ' +
    'anchors, aliases, tags, comments and values starting with an ' +
    'indicator are not read here; use block style or quote the value');
  Expect<string>(Parsed('d: "open^')).ToBe('REFUSED line 2: a quoted string ' +
    'must end on its line');
  // Raw characters YAML 1.1 reads as line breaks, or no parser accepts:
  // written as escapes they pass (#117 review).
  Expect<Boolean>(Pos('REFUSED line 2: a tab, control, line separator',
    Parsed('d: "first' + #$C2#$85 + 'second"^')) = 1).ToBe(True);
  Expect<Boolean>(Pos('REFUSED line 2: a tab, control, line separator',
    Parsed('d: a' + #$E2#$80#$A8 + 'b^')) = 1).ToBe(True);
  Expect<string>(Parsed('d: "a\u0085b\u2028c"^')).ToBe('{"d":"a' + #$C2#$85 +
    'b' + #$E2#$80#$A8 + 'c"}');
  // A raw tab anywhere, a trailing one included, since trimming would
  // hide it; written as \t it passes (#117 review).
  Expect<Boolean>(Pos('REFUSED line 2: a tab, control',
    Parsed('d: one' + #9 + '# comment^')) = 1).ToBe(True);
  Expect<Boolean>(Pos('REFUSED line 2: a tab, control',
    Parsed('d: one' + #9 + '^')) = 1).ToBe(True);
  Expect<Boolean>(Pos('REFUSED line 2: a tab, control',
    Parsed('d: "a' + #9 + 'b"^')) = 1).ToBe(True);
  Expect<string>(Parsed('d: "a\tb"^')).ToBe('{"d":"a\tb"}');
  // The raw key span to its colon counts, in UTF-16 units: 169 escapes
  // of six and five emoji of two make 1026 with the quotes.
  Expect<string>(Parsed('"' + DupeString('\u0061', 169) +
    DupeString(#$F0#$9F#$98#$80, 5) + '": v^')).ToBe('REFUSED line 2: a key ' +
    'longer than the 1024 characters YAML parsers read');
  // Integers JavaScript parsers keep exactly, and no larger.
  Expect<string>(Parsed('rank: 9007199254740991^')).ToBe(
    '{"rank":9007199254740991}');
  // Negative zero: 0 to PyYAML, -0 to yaml.
  Expect<string>(Parsed('rank: -0^')).ToBe('REFUSED line 2: "-0" starts ' +
    'with a digit, a sign or a dot, which is read here only quoted; quote it');
  Expect<string>(Parsed('rank: 9007199254740993^')).ToBe('REFUSED line 2: ' +
    '"9007199254740993" starts with a digit, a sign or a dot, which is read ' +
    'here only quoted; quote it');
  // An empty flow collection is a whole value.
  Expect<string>(Parsed('d: []^  prose^')).ToBe('REFUSED line 3: unexpected ' +
    'indentation');
  // A key longer than the server keeps.
  Expect<string>(Parsed(StringOfChar('k', 256) + ': v^')).ToBe('REFUSED line ' +
    '2: a key longer than 255 bytes, the most the server keeps');
  // A continuation line is named as itself.
  Expect<string>(Parsed('d: one^  two: three^')).ToBe('REFUSED line 3: a ' +
    'plain value with ": " or " #"; quote it');
end;

// The "---" lines around it, CRLF line ends, and nothing more.
procedure TFrontmatterSuite.TestDocumentShape;
var
  Frontmatter: TJSONObject;
  Problem, Text: string;
begin
  Expect<Boolean>(ParseFrontmatter('---' + #13#10 + 'name: a' + #13#10 +
    '---' + #13#10 + 'Body', Frontmatter, Problem)).ToBe(True);
  Expect<string>(Frontmatter.Get('name', '')).ToBe('a');
  Frontmatter.Free;
  Expect<Boolean>(ParseFrontmatter('name: a' + #10, Frontmatter, Problem))
    .ToBe(False);
  Expect<string>(Problem).ToBe('line 1: a SKILL.md must start with a "---" ' +
    'line');
  Expect<Boolean>(Frontmatter = nil).ToBe(True);
  Expect<Boolean>(ParseFrontmatter('---' + #10 + 'name: a' + #10,
    Frontmatter, Problem)).ToBe(False);
  Expect<string>(Problem).ToBe('line 1: the frontmatter opened here has no ' +
    'closing "---" line');
  // Not UTF-8: a lone $FF byte, set in place at run time, since a
  // constant or a concatenation would convert it.
  Text := '---' + #10 + 'd: x' + #10 + '---' + #10;
  Text[8] := Chr($FF);
  Expect<Boolean>(ParseFrontmatter(Text, Frontmatter, Problem)).ToBe(False);
  Expect<string>(Problem).ToBe('byte 8: a SKILL.md must be UTF-8 text');
  Expect<string>(Parsed('')).ToBe('{}');
end;

procedure TFrontmatterSuite.SetupTests;
begin
  Test('plain, quoted and typed scalars as YAML 1.1 and 1.2 read them',
    TestScalars);
  Test('literal and folded block scalars with chomping', TestBlockScalars);
  Test('nested mappings and sequences', TestCollections);
  Test('multi-line plain values and comment lines', TestLinesAndComments);
  Test('values the YAML versions read differently are refused with a line',
    TestRefused);
  Test('the --- lines, CRLF, and missing delimiters', TestDocumentShape);
end;

begin
  TestRunnerProgram.AddSuite(TFrontmatterSuite.Create(
    'Frontmatter: YAML subset'));
  TestRunnerProgram.Run;
end.
