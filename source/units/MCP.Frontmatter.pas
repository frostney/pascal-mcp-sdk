{ MCP.Frontmatter — the YAML frontmatter of a SKILL.md, read as JSON
  (#117). FPC 3.2.x ships no YAML parser, and a host compares the
  frontmatter it parses with the entry's field by field (ext-skills
  specification/beta/skills.mdx at ba23984, Frontmatter Verification),
  so this reads only a subset on which YAML 1.1 and 1.2 parsers agree,
  and refuses everything else with its line:

  - block mappings and block sequences, nested to any depth;
  - double-quoted strings on one line, with \\ \" \n \t \r \0 \xXX
    \uXXXX and \UXXXXXXXX (YAML 1.1 has no "\/");
  - single-quoted strings on one line ('' for a quote);
  - literal (|) and folded (>) block scalars with - or + chomping;
    folded ones without more-indented lines;
  - plain strings, also over several more-indented lines, that neither
    YAML version reads as anything else (quoted when they start with a
    digit, a sign or a dot);
  - true, false, null, ~, decimal integers without leading zeros, and
    the empty flow mapping and list.

  Refused: raw tabs (write \t in a double-quoted string), comments after
  a value, flow
  collections with content, anchors, aliases, tags, directives,
  duplicate keys, and plain values such as yes, on, 1.0, 012 or a date,
  which the two versions read differently (quote them). Checked
  2026-11-27 against PyYAML 6.0.1 (YAML 1.1), js-yaml 4.1.0 and yaml
  2.6.1 (YAML 1.2). No I/O. }

unit MCP.Frontmatter;

{$I MCP.inc}

interface

uses
  SysUtils,

  fpjson;

// The frontmatter of AText, a SKILL.md: a "---" line first, the YAML,
// then a "---" line, lines ending in LF or CRLF. True with AFrontmatter
// (new, the caller's) as the JSON object; False with AProblem naming the
// line, and AFrontmatter nil.
function ParseFrontmatter(const AText: string; out AFrontmatter: TJSONObject;
  out AProblem: string): Boolean;

implementation

uses
  MCP.JSONRPC;

type
  EFrontmatter = class(Exception);

  TFrontmatterReader = class
  private
    FLines: array of string;
    FFirstLine: Integer; // the file's line number of FLines[0]
    FPos: Integer;
    procedure Fail(ALine: Integer; const AWhat: string);
    function Indent(ALine: Integer): Integer;
    function IsSkippable(ALine: Integer): Boolean;
    procedure SkipBlank;
    function IsDash(ALine, AIndent: Integer): Boolean;
    function ParseMapping(AIndent: Integer): TJSONObject;
    function ParseSequence(AIndent: Integer): TJSONArray;
    function ParseValue(AParentIndent: Integer; const ARest: string;
      ALine: Integer; AInSequence: Boolean): TJSONData;
    function ParseNested(AParentIndent: Integer;
      AInSequence: Boolean): TJSONData;
    function ParseBlockScalar(AParentIndent: Integer; const AHeader: string;
      ALine: Integer): string;
    function ParsePlain(AParentIndent: Integer; const AFirst: string;
      ALine: Integer): TJSONData;
    function ParseKey(const AText: string; ALine: Integer;
      out ARest: string): string;
    procedure CheckPlain(const AText: string; ALine: Integer);
    procedure CheckCharacters;
  public
    constructor Create(const ALines: array of string; AFirstLine: Integer);
    function Read: TJSONObject;
  end;

const
  INDICATORS = ['-', '?', ':', ',', '[', ']', '{', '}', '#', '&', '*', '!',
    '|', '>', '''', '"', '%', '@', '`'];

// The UTF-8 bytes of ACodePoint (a Unicode scalar value).
function CodePointUTF8(ACodePoint: Cardinal): string;
begin
  if ACodePoint < $80 then
    Result := Chr(ACodePoint)
  else if ACodePoint < $800 then
    Result := Chr($C0 or (ACodePoint shr 6)) + Chr($80 or (ACodePoint and $3F))
  else if ACodePoint < $10000 then
    Result := Chr($E0 or (ACodePoint shr 12)) +
      Chr($80 or ((ACodePoint shr 6) and $3F)) + Chr($80 or (ACodePoint and $3F))
  else
    Result := Chr($F0 or (ACodePoint shr 18)) +
      Chr($80 or ((ACodePoint shr 12) and $3F)) +
      Chr($80 or ((ACodePoint shr 6) and $3F)) + Chr($80 or (ACodePoint and $3F));
end;

constructor TFrontmatterReader.Create(const ALines: array of string;
  AFirstLine: Integer);
var
  I: Integer;
begin
  inherited Create;
  SetLength(FLines, Length(ALines));
  for I := 0 to High(ALines) do
    FLines[I] := ALines[I];
  FFirstLine := AFirstLine;
  FPos := 0;
end;

procedure TFrontmatterReader.Fail(ALine: Integer; const AWhat: string);
begin
  raise EFrontmatter.CreateFmt('line %d: %s', [FFirstLine + ALine, AWhat]);
end;

// Leading spaces of line ALine; a tab among them is refused, as YAML
// forbids it.
function TFrontmatterReader.Indent(ALine: Integer): Integer;
var
  Text: string;
begin
  Text := FLines[ALine];
  Result := 0;
  while (Result < Length(Text)) and (Text[Result + 1] = ' ') do
    Inc(Result);
  if (Result < Length(Text)) and (Text[Result + 1] = #9) then
    Fail(ALine, 'a tab in indentation');
end;

// A blank line or a whole-line comment, outside block scalars.
function TFrontmatterReader.IsSkippable(ALine: Integer): Boolean;
var
  Text: string;
begin
  Text := Trim(FLines[ALine]);
  Result := (Text = '') or (Text[1] = '#');
end;

procedure TFrontmatterReader.SkipBlank;
begin
  while (FPos <= High(FLines)) and IsSkippable(FPos) do
    Inc(FPos);
end;

// Whether line ALine is a "-" item at AIndent.
function TFrontmatterReader.IsDash(ALine, AIndent: Integer): Boolean;
var
  Text: string;
begin
  Text := Copy(FLines[ALine], AIndent + 1, MaxInt);
  Result := (Indent(ALine) = AIndent) and
    ((Text = '-') or (Copy(Text, 1, 2) = '- '));
end;

// The UTF-16 code units of UTF-8 AText: one per code point, two for
// one beyond U+FFFF (four UTF-8 bytes).
function UTF16Units(const AText: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to Length(AText) do
    if (Ord(AText[I]) and $C0) <> $80 then
    begin
      Inc(Result);
      if Ord(AText[I]) >= $F0 then
        Inc(Result);
    end;
end;

// Refuses raw characters YAML parsers read differently or not at all:
// C0 controls, tab included (PyYAML ends a plain value at a tab and
// refuses what follows, wherever trimming would hide it), DEL, the C1
// controls (U+0085 is a line break to
// YAML 1.1), U+2028 and U+2029 (line breaks to YAML 1.1), U+FEFF,
// U+FFFE and U+FFFF. Escapes in double-quoted strings write them.
procedure TFrontmatterReader.CheckCharacters;
var
  Line, I: Integer;
  Text: string;
  C: Byte;
begin
  for Line := 0 to High(FLines) do
  begin
    Text := FLines[Line];
    for I := 1 to Length(Text) do
    begin
      C := Ord(Text[I]);
      if (C < $20) or (C = $7F) or
        ((C = $C2) and (I < Length(Text)) and
        (Ord(Text[I + 1]) in [$80..$9F])) or
        ((C = $E2) and (I + 2 <= Length(Text)) and (Ord(Text[I + 1]) = $80)
        and (Ord(Text[I + 2]) in [$A8, $A9])) or
        ((C = $EF) and (I + 2 <= Length(Text)) and
        (((Ord(Text[I + 1]) = $BB) and (Ord(Text[I + 2]) = $BF)) or
        ((Ord(Text[I + 1]) = $BF) and (Ord(Text[I + 2]) in [$BE, $BF])))) then
        Fail(Line, 'a tab, control, line separator or noncharacter that ' +
          'YAML parsers read differently; write it as an escape (\t, \uXXXX) ' +
          'in a double-quoted string');
    end;
  end;
end;

function TFrontmatterReader.Read: TJSONObject;
begin
  CheckCharacters;
  SkipBlank;
  if FPos > High(FLines) then
    Exit(TJSONObject.Create);
  if Indent(FPos) <> 0 then
    Fail(FPos, 'the frontmatter must start at the left margin');
  Result := ParseMapping(0);
  if FPos <= High(FLines) then
  begin
    Result.Free;
    Fail(FPos, 'unexpected indentation');
  end;
end;

// Decodes a double-quoted scalar's body (between the quotes) into
// AValue; '' or the problem.
function DoubleQuoted(const AText: string; out AValue: string): string;
var
  I, J, Digits: Integer;
  CodePoint: Cardinal;
begin
  Result := '';
  AValue := '';
  I := 1;
  while I <= Length(AText) do
  begin
    if AText[I] <> '\' then
    begin
      AValue := AValue + AText[I];
      Inc(I);
      Continue;
    end;
    if I = Length(AText) then
      Exit('a backslash ends the string');
    Inc(I);
    Digits := 0;
    case AText[I] of
      '\', '"':
        AValue := AValue + AText[I];
      'n':
        AValue := AValue + #10;
      't':
        AValue := AValue + #9;
      'r':
        AValue := AValue + #13;
      '0':
        AValue := AValue + #0;
      'x':
        Digits := 2;
      'u':
        Digits := 4;
      'U':
        Digits := 8;
    else
      Exit(Format('the escape \%s, which YAML 1.1 and 1.2 do not share',
        [AText[I]]));
    end;
    if Digits > 0 then
    begin
      CodePoint := 0;
      for J := 1 to Digits do
      begin
        if (I + J > Length(AText)) or
          not (AText[I + J] in ['0'..'9', 'a'..'f', 'A'..'F']) then
          Exit('an escape with too few hex digits');
        CodePoint := CodePoint * 16 + Cardinal(StrToInt('$' + AText[I + J]));
      end;
      if (CodePoint > $10FFFF) or ((CodePoint >= $D800) and
        (CodePoint <= $DFFF)) then
        Exit('an escape that is no Unicode scalar value');
      AValue := AValue + CodePointUTF8(CodePoint);
      Inc(I, Digits);
    end;
    Inc(I);
  end;
end;

// The index of AText's closing quote (AText[1] is the opening one), or 0.
function QuoteEnd(const AText: string): Integer;
var
  I: Integer;
begin
  I := 2;
  while I <= Length(AText) do
    if (AText[1] = '"') and (AText[I] = '\') then
      Inc(I, 2)
    else if (AText[1] = '''') and (AText[I] = '''') and
      (I < Length(AText)) and (AText[I + 1] = '''') then
      Inc(I, 2)
    else if AText[I] = AText[1] then
      Exit(I)
    else
      Inc(I);
  Result := 0;
end;

// A quoted scalar that is all of AText: its value in AValue; '' or the
// problem.
function QuotedScalar(const AText: string; out AValue: string): string;
var
  Close: Integer;
begin
  AValue := '';
  Close := QuoteEnd(AText);
  if Close = 0 then
    Exit('a quoted string must end on its line');
  if Trim(Copy(AText, Close + 1, MaxInt)) <> '' then
    Exit('text after a quoted string');
  if AText[1] = '"' then
    Exit(DoubleQuoted(Copy(AText, 2, Close - 2), AValue));
  AValue := StringReplace(Copy(AText, 2, Close - 2), '''''', '''',
    [rfReplaceAll]);
  Result := '';
end;

// Whether plain AText is a decimal integer both YAML versions read so.
function IsPlainInteger(const AText: string): Boolean;
var
  Digits: string;
  I: Integer;
begin
  Digits := AText;
  if (Digits <> '') and (Digits[1] = '-') then
    Delete(Digits, 1, 1);
  Result := (Digits <> '') and ((Digits = '0') or (Digits[1] <> '0')) and
    (Length(Digits) <= 16);
  for I := 1 to Length(Digits) do
    if not (Digits[I] in ['0'..'9']) then
      Exit(False);
  // JavaScript parsers keep integers exactly up to 2^53 - 1 only.
  if Result then
    Result := StrToInt64(Digits) <= 9007199254740991;
end;

// A plain scalar as both YAML versions read it, or nil when they read
// it differently or as something other than this (quote it then).
function PlainValue(const AText: string; out AWhy: string): TJSONData;
var
  Lower: string;
begin
  Result := nil;
  AWhy := Format('"%s" is not a string in every YAML version; quote it',
    [AText]);
  if (AText = 'true') or (AText = 'false') then
    Exit(TJSONBoolean.Create(AText = 'true'));
  if (AText = 'null') or (AText = '~') then
    Exit(TJSONNull.Create);
  if IsPlainInteger(AText) then
    Exit(TJSONInt64Number.Create(StrToInt64(AText)));
  // YAML 1.1 booleans and nulls in any case, numbers, dates, floats,
  // .inf and .nan, and the merge and value keys: some parser reads each
  // as no string.
  Lower := LowerCase(AText);
  if (Lower = 'y') or (Lower = 'n') or (Lower = 'yes') or (Lower = 'no') or
    (Lower = 'on') or (Lower = 'off') or (Lower = 'true') or
    (Lower = 'false') or (Lower = 'null') or (AText = '<<') or
    (AText = '=') then
    Exit;
  // Numbers, dates, times and floats in their many spellings all start
  // so; refusing every such plain value is simpler than telling them
  // apart, even where both versions would read text (3d-printing).
  if (AText[1] in ['0'..'9', '.']) or ((AText[1] in ['+', '-']) and
    (Length(AText) > 1) and (AText[2] in ['0'..'9', '.'])) then
  begin
    AWhy := Format('"%s" starts with a digit, a sign or a dot, which is ' +
      'read here only quoted; quote it', [AText]);
    Exit;
  end;
  Result := TJSONString.Create(AText);
end;

function TFrontmatterReader.ParseKey(const AText: string; ALine: Integer;
  out ARest: string): string;
var
  Close, Colon, KeyEnd: Integer;
  Problem: string;
  Value: TJSONData;
begin
  if AText[1] in ['"', ''''] then
  begin
    Close := QuoteEnd(AText);
    if (Close = 0) or (Copy(AText, Close + 1, 1) <> ':') then
      Fail(ALine, 'a quoted key must be followed by ":"');
    Problem := QuotedScalar(Copy(AText, 1, Close), Result);
    if Problem <> '' then
      Fail(ALine, Problem);
    KeyEnd := Close;
    ARest := Copy(AText, Close + 2, MaxInt);
  end
  else
  begin
    Colon := Pos(': ', AText + ' ');
    if (Colon = 0) or (AText[1] in INDICATORS) then
      Fail(ALine, 'expected "key: value"');
    Result := TrimRight(Copy(AText, 1, Colon - 1));
    KeyEnd := Colon - 1;
    if (Result = '') or (Pos(' #', Result) > 0) or (Pos(':', Result) > 0) then
      Fail(ALine, 'a plain key with ":" or " #"; quote it');
    // A key YAML 1.1 reads as a boolean, a number or null.
    Value := PlainValue(Result, Problem);
    try
      if (Value = nil) or (Value.JSONType <> jtString) then
        Fail(ALine, 'the key ' + Problem);
    finally
      Value.Free;
    end;
    ARest := Copy(AText, Colon + 1, MaxInt);
  end;
  if (ARest <> '') and (ARest[1] <> ' ') then
    Fail(ALine, 'expected a space after ":"');
  ARest := Trim(ARest);
  // YAML parsers read an implicit key of at most 1024 characters up to
  // its colon, quotes and escapes counted (yaml counts UTF-16 units).
  if UTF16Units(Copy(AText, 1, KeyEnd)) > 1024 then
    Fail(ALine, 'a key longer than the 1024 characters YAML parsers read');
  // fpjson keeps a key to 255 bytes (FPC 3.2.2): a longer one would not
  // reach the listing as written.
  if Length(Result) > 255 then
    Fail(ALine, 'a key longer than 255 bytes, the most the server keeps');
end;

function TFrontmatterReader.ParseMapping(AIndent: Integer): TJSONObject;
var
  Line: Integer;
  Key, Rest: string;
begin
  Result := TJSONObject.Create;
  try
    SkipBlank;
    while (FPos <= High(FLines)) and (Indent(FPos) = AIndent) and
      not IsDash(FPos, AIndent) do
    begin
      Line := FPos;
      Key := ParseKey(Copy(FLines[Line], AIndent + 1, MaxInt), Line, Rest);
      if Result.IndexOfName(Key) >= 0 then
        Fail(Line, Format('the key "%s" appears twice', [Key]));
      Inc(FPos);
      Result.Add(Key, ParseValue(AIndent, Rest, Line, False));
      SkipBlank;
    end;
    if (FPos <= High(FLines)) and (Indent(FPos) > AIndent) then
      Fail(FPos, 'unexpected indentation');
  except
    Result.Free;
    raise;
  end;
end;

function TFrontmatterReader.ParseSequence(AIndent: Integer): TJSONArray;
var
  Line: Integer;
  Rest: string;
begin
  Result := TJSONArray.Create;
  try
    SkipBlank;
    while (FPos <= High(FLines)) and IsDash(FPos, AIndent) do
    begin
      Line := FPos;
      Rest := Trim(Copy(FLines[Line], AIndent + 2, MaxInt));
      if (Rest <> '') and not (Rest[1] in ['"', '''']) and
        (Pos(': ', Rest + ' ') > 0) then
        Fail(Line, 'a mapping on a dash line; write it on the lines below ' +
          'the dash');
      Inc(FPos);
      Result.Add(ParseValue(AIndent, Rest, Line, True));
      SkipBlank;
    end;
    if (FPos <= High(FLines)) and (Indent(FPos) > AIndent) then
      Fail(FPos, 'unexpected indentation');
  except
    Result.Free;
    raise;
  end;
end;

// The collection below a "key:" or "-" line with nothing after it, or
// null when nothing more indented follows. Below a key, a sequence may
// also sit at the key's own indentation.
function TFrontmatterReader.ParseNested(AParentIndent: Integer;
  AInSequence: Boolean): TJSONData;
var
  Next: Integer;
begin
  SkipBlank;
  if FPos > High(FLines) then
    Exit(TJSONNull.Create);
  Next := Indent(FPos);
  if IsDash(FPos, Next) and ((Next > AParentIndent) or
    ((Next = AParentIndent) and not AInSequence)) then
    Exit(ParseSequence(Next));
  if Next <= AParentIndent then
    Exit(TJSONNull.Create);
  Result := ParseMapping(Next);
end;

function TFrontmatterReader.ParseValue(AParentIndent: Integer;
  const ARest: string; ALine: Integer; AInSequence: Boolean): TJSONData;
var
  Value, Problem: string;
begin
  if ARest = '' then
    Exit(ParseNested(AParentIndent, AInSequence));
  if ARest[1] in ['|', '>'] then
    Exit(TJSONString.Create(ParseBlockScalar(AParentIndent, ARest, ALine)));
  if ARest[1] in ['"', ''''] then
  begin
    Problem := QuotedScalar(ARest, Value);
    if Problem <> '' then
      Fail(ALine, Problem);
    Exit(TJSONString.Create(Value));
  end;
  // A whole value: a more-indented line after it is refused where it
  // stands.
  if ARest = '{}' then
    Exit(TJSONObject.Create);
  if ARest = '[]' then
    Exit(TJSONArray.Create);
  // "-", "?" and ":" start a plain value when no space follows them
  // (-7, ?x); the other indicators never do.
  if (ARest[1] in INDICATORS) and not ((ARest[1] in ['-', '?', ':']) and
    (Length(ARest) > 1) and (ARest[2] <> ' ')) then
    Fail(ALine, 'flow collections, anchors, aliases, tags, comments and ' +
      'values starting with an indicator are not read here; use block ' +
      'style or quote the value');
  Result := ParsePlain(AParentIndent, ARest, ALine);
end;

// Refuses plain text that holds a mapping or comment indicator: ":"
// followed by whitespace or ending it, or "#" after whitespace.
procedure TFrontmatterReader.CheckPlain(const AText: string; ALine: Integer);
begin
  if (Pos(': ', AText) > 0) or (Pos(' #', AText) > 0) or
    ((AText <> '') and (AText[Length(AText)] = ':')) then
    Fail(ALine, 'a plain value with ": " or " #"; quote it');
end;

// A plain scalar, continued on more-indented lines joined by spaces.
function TFrontmatterReader.ParsePlain(AParentIndent: Integer;
  const AFirst: string; ALine: Integer): TJSONData;
var
  Text, Part, Why: string;
  Next: Integer;
begin
  Text := AFirst;
  CheckPlain(AFirst, ALine);
  // A comment line ends the value, as in YAML.
  while (FPos <= High(FLines)) and not IsSkippable(FPos) and
    (Indent(FPos) > AParentIndent) do
  begin
    Part := Trim(FLines[FPos]);
    CheckPlain(Part, FPos);
    Text := Text + ' ' + Part;
    Inc(FPos);
  end;
  // A blank line and more of the value would fold to a line break.
  Next := FPos;
  while (Next <= High(FLines)) and (Trim(FLines[Next]) = '') do
    Inc(Next);
  if (Next > FPos) and (Next <= High(FLines)) and
    (Indent(Next) > AParentIndent) and not IsSkippable(Next) then
    Fail(FPos, 'a blank line inside a plain value; use a block scalar');
  Result := PlainValue(Text, Why);
  if Result = nil then
    Fail(ALine, Why);
end;

// A literal (|) or folded (>) block scalar after its header on line
// ALine, with clip, strip (-) or keep (+) chomping.
function TFrontmatterReader.ParseBlockScalar(AParentIndent: Integer;
  const AHeader: string; ALine: Integer): string;
var
  Chomp: Char;
  Literal: Boolean;
  Lines: array of string;
  ContentIndent, I, Trailing, Count: Integer;
  Text: string;
begin
  Literal := AHeader[1] = '|';
  Chomp := ' ';
  if Length(AHeader) = 2 then
    Chomp := AHeader[2];
  if (Length(AHeader) > 2) or not (Chomp in [' ', '-', '+']) then
    Fail(ALine, 'a block scalar header other than |, |-, |+, >, >- or >+');
  ContentIndent := 0;
  Count := 0;
  Lines := nil;
  while FPos <= High(FLines) do
  begin
    Text := FLines[FPos];
    if Trim(Text) = '' then
    begin
      // A whitespace line longer than the content indentation (or, before
      // the text, than the parent's) is read differently by parsers.
      if ((ContentIndent = 0) and (Length(Text) > AParentIndent)) or
        ((ContentIndent > 0) and (Length(Text) > ContentIndent)) then
        Fail(FPos, 'a whitespace-only line with more spaces than the ' +
          'block scalar''s indentation');
      SetLength(Lines, Count + 1);
      Lines[Count] := '';
      Inc(Count);
      Inc(FPos);
      Continue;
    end;
    I := Indent(FPos);
    if I <= AParentIndent then
      Break;
    if ContentIndent = 0 then
      ContentIndent := I
    else if I < ContentIndent then
      Fail(FPos, 'a block scalar line indented less than its first line');
    if (not Literal) and (I > ContentIndent) then
      Fail(FPos, 'a more-indented line in a folded block scalar; use |');
    SetLength(Lines, Count + 1);
    Lines[Count] := Copy(Text, ContentIndent + 1, MaxInt);
    Inc(Count);
    Inc(FPos);
  end;
  Trailing := 0;
  while (Count > 0) and (Lines[Count - 1] = '') do
  begin
    Dec(Count);
    Inc(Trailing);
  end;
  Result := '';
  for I := 0 to Count - 1 do
    if Literal then
    begin
      if I > 0 then
        Result := Result + #10;
      Result := Result + Lines[I];
    end
    // Folded: a break between two text lines becomes a space, and each
    // empty line a line break.
    else if Lines[I] = '' then
      Result := Result + #10
    else if (I > 0) and (Lines[I - 1] <> '') then
      Result := Result + ' ' + Lines[I]
    else
      Result := Result + Lines[I];
  if (Count > 0) and (Chomp <> '-') then
    Result := Result + #10;
  if Chomp = '+' then
    Result := Result + StringOfChar(#10, Trailing);
end;

function ParseFrontmatter(const AText: string; out AFrontmatter: TJSONObject;
  out AProblem: string): Boolean;
var
  Lines: TStringArray;
  I, Close: Integer;
  Reader: TFrontmatterReader;
begin
  AFrontmatter := nil;
  AProblem := '';
  Result := False;
  if InvalidUTF8Offset(AText) <> 0 then
  begin
    AProblem := Format('byte %d: a SKILL.md must be UTF-8 text',
      [InvalidUTF8Offset(AText)]);
    Exit;
  end;
  Lines := AText.Split([#10]);
  for I := 0 to High(Lines) do
    if (Lines[I] <> '') and (Lines[I][Length(Lines[I])] = #13) then
      SetLength(Lines[I], Length(Lines[I]) - 1);
  if (Length(Lines) = 0) or (Lines[0] <> '---') then
  begin
    AProblem := 'line 1: a SKILL.md must start with a "---" line';
    Exit;
  end;
  Close := 0;
  for I := 1 to High(Lines) do
    if Lines[I] = '---' then
    begin
      Close := I;
      Break;
    end;
  if Close = 0 then
  begin
    AProblem := 'line 1: the frontmatter opened here has no closing "---" ' +
      'line';
    Exit;
  end;
  Reader := TFrontmatterReader.Create(Copy(Lines, 1, Close - 1), 2);
  try
    try
      AFrontmatter := Reader.Read;
      Result := True;
    except
      on E: EFrontmatter do
        AProblem := E.Message;
    end;
  finally
    Reader.Free;
  end;
end;

end.
