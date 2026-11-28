program mcpsmoke;

// End-to-end smoke test: launches the mcpdemo binary as a real
// subprocess (the way an MCP client launches a stdio server), drives
// the full v1 surface over its actual stdin/stdout, and checks every
// response — including the error paths a modern client relies on
// (-32022 for an unsupported version, the initialize rejection, -32602
// for an unknown tool) and the EOF shutdown contract. This is the
// process-level complement to the in-process *.Test.pas suites; CI
// runs it as the "example-server smoke test" leg.
//
// A second battery launches the conformance fixture (mcpconformance,
// next to mcpdemo) the same way and checks the content types mcpdemo
// does not register: audio, resource links, embedded resources and
// mixed results, and non-text prompt messages (#87).
//
// Usage: mcpsmoke [path-to-mcpdemo]   (default: ./build/mcpdemo; the
// fixture is always the mcpconformance next to mcpsmoke)

{$I MCP.inc}

uses
  SysUtils,
  Classes,
  Process,

  fpjson,
  jsonparser,
  jsonscanner,
  MCP.Crypto;

const
  META_MODERN =
    '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientInfo":{"name":"mcpsmoke","version":"0.1.0"},' +
    '"io.modelcontextprotocol/clientCapabilities":{}}';
  UTF8_PAYLOAD = 'h' + #$C3#$A9 + 'llo ' + #$E4#$B8#$96 + #$E7#$95#$8C;
  UTF8_WORLD = #$E4#$B8#$96 + #$E7#$95#$8C;
  // base64 of mcpdemo's inline 1x1 PNG, written out literally: the
  // pixel check asserts it on the encoded wire line, so a platform's
  // string handling cannot reshape the payload undetected.
  ONE_PIXEL_PNG_BASE64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk' +
    'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
  // Modern _meta declaring the elicitation capability the MRTR
  // battery needs.
  META_MRTR =
    '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientInfo":{"name":"mcpsmoke","version":"0.1.0"},' +
    '"io.modelcontextprotocol/clientCapabilities":{"elicitation":{}}}';

  // Modern _meta declaring the Tasks extension (#82), with elicitation
  // for a task's input round.
  META_TASKS =
    '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientInfo":{"name":"mcpsmoke","version":"0.1.0"},' +
    '"io.modelcontextprotocol/clientCapabilities":{"elicitation":{},' +
    '"extensions":{"io.modelcontextprotocol/tasks":{}}}}';

var
  Failures: Integer = 0;

procedure Check(ACondition: Boolean; const AWhat: string);
begin
  if ACondition then
    WriteLn('ok    ', AWhat)
  else
  begin
    WriteLn('FAIL  ', AWhat);
    Inc(Failures);
  end;
end;

function DemoBinary: string;
begin
  if ParamCount >= 1 then
    Result := ParamStr(1)
  else
  begin
    Result := 'build' + DirectorySeparator + 'mcpdemo';
    {$IFDEF WINDOWS}
    Result := Result + '.exe';
    {$ENDIF}
  end;
end;

// Blocking line read from the child's stdout. Byte-at-a-time is plenty
// for a smoke test; a missing newline within the deadline is a failure.
function ReadLine(AProcess: TProcess; out ALine: string): Boolean;
var
  B: Byte;
  Deadline: QWord;
begin
  ALine := '';
  Deadline := GetTickCount64 + 10000;
  while GetTickCount64 < Deadline do
  begin
    if AProcess.Output.NumBytesAvailable > 0 then
    begin
      if AProcess.Output.Read(B, 1) <> 1 then
        Exit(False);
      if B = 10 then
        Exit(True);
      if B <> 13 then
        ALine := ALine + Chr(B);
    end
    else if not AProcess.Running then
      Exit(False)
    else
      Sleep(5);
  end;
  Result := False;
end;

procedure SendLine(AProcess: TProcess; const ALine: string);
var
  Payload: string;
begin
  Payload := ALine + #10;
  AProcess.Input.Write(Payload[1], Length(Payload));
end;

// Read and parse the next line without sending anything — for
// sequences where one request produces several lines (notifications
// followed by the response).
function NextJson(AProcess: TProcess): TJSONObject;
var
  Line: string;
  Data: TJSONData;
begin
  Result := nil;
  if not ReadLine(AProcess, Line) then
    Exit;
  try
    Data := GetJSON(Line);
  except
    Exit;
  end;
  if (Data <> nil) and (Data.JSONType = jtObject) then
    Result := TJSONObject(Data)
  else
    Data.Free;
end;

// Send one request, capture one response line, and parse it. nil on
// transport failure (counted by the caller via Check).
function RoundTripWithLine(AProcess: TProcess; const ARequest: string;
  out ALine: string): TJSONObject;
var
  Data: TJSONData;
begin
  Result := nil;
  SendLine(AProcess, ARequest);
  if not ReadLine(AProcess, ALine) then
    Exit;
  try
    Data := GetJSON(ALine);
  except
    Exit;
  end;
  if (Data <> nil) and (Data.JSONType = jtObject) then
    Result := TJSONObject(Data)
  else
    Data.Free;
end;

function RoundTrip(AProcess: TProcess; const ARequest: string): TJSONObject;
var
  Line: string;
begin
  Result := RoundTripWithLine(AProcess, ARequest, Line);
end;

function FindPath(AObj: TJSONObject; const APath: string): TJSONData;
begin
  if AObj = nil then
    Result := nil
  else
    Result := AObj.FindPath(APath);
end;

function PathString(AObj: TJSONObject; const APath: string): string;
var
  Data: TJSONData;
begin
  Data := FindPath(AObj, APath);
  if (Data <> nil) and (Data.JSONType = jtString) then
    Result := Data.AsString
  else
    Result := '';
end;

function PathInt(AObj: TJSONObject; const APath: string): Integer;
var
  Data: TJSONData;
begin
  Data := FindPath(AObj, APath);
  if (Data <> nil) and (Data.JSONType = jtNumber) then
    Result := Data.AsInteger
  else
    Result := 0;
end;

// The conformance fixture lwpt builds next to mcpsmoke itself, so a
// demo given from elsewhere does not move it.
function FixtureBinary: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + 'mcpconformance';
  {$IFDEF WINDOWS}
  Result := Result + '.exe';
  {$ENDIF}
end;

// Closes stdin and waits for a clean exit, as a client does at the end.
procedure Shutdown(AProcess: TProcess; const ALabel: string);
var
  WaitedMs: Integer;
begin
  AProcess.CloseInput;
  WaitedMs := 0;
  while AProcess.Running and (WaitedMs < 5000) do
  begin
    Sleep(50);
    Inc(WaitedMs, 50);
  end;
  Check(not AProcess.Running, ALabel + ': exits on stdin EOF');
  if AProcess.Running then
    AProcess.Terminate(1)
  else
    Check(AProcess.ExitStatus = 0, ALabel + ': exit status 0');
end;

// Content types over stdio, against the conformance fixture (#87).
// Shapes verified 2026-11-26 against
// https://modelcontextprotocol.io/specification/2026-07-28/server/tools#tool-result
// and .../server/prompts#embedded-resources (an embedded resource in a
// prompt message MUST carry a URI and a MIME type).
var
  // The demo's tools/list names, unpaged, for the paged run to match.
  DemoToolNames: string;

// The comma-separated names of a tools/list result's tools.
function ToolNames(AResponse: TJSONObject): string;
var
  Tools: TJSONData;
  I: Integer;
begin
  Result := '';
  Tools := FindPath(AResponse, 'result.tools');
  if (Tools = nil) or (Tools.JSONType <> jtArray) then
    Exit;
  for I := 0 to Tools.Count - 1 do
    Result := Result + TJSONObject(Tools.Items[I]).Get('name', '') + ',';
end;

// Pagination over stdio (#94; spec verified 2026-11-26:
// https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/pagination):
// mcpdemo --page-size 2 hands tools/list out in pages whose names, in
// order, are the unpaged list's, the last without a nextCursor, and
// refuses another list's cursor.
procedure PagedDemoBattery;
var
  Paged: TProcess;
  Response: TJSONObject;
  Tools: TJSONData;
  Cursor, Names, FirstCursor: string;
  Pages: Integer;
  PageOk, PagesOk, Answered: Boolean;
begin
  Paged := TProcess.Create(nil);
  try
    Paged.Executable := DemoBinary;
    Paged.Parameters.Add('--page-size');
    Paged.Parameters.Add('2');
    Paged.Options := [poUsePipes];
    try
      Paged.Execute;
    except
      on E: Exception do
      begin
        Check(False, 'pagination: launch ' + DemoBinary + ': ' + E.Message);
        Exit;
      end;
    end;
    try
      Cursor := '';
      FirstCursor := '';
      Names := '';
      Pages := 0;
      PagesOk := True;
      Answered := True;
      repeat
        if Cursor = '' then
          Response := RoundTrip(Paged, '{"jsonrpc":"2.0","id":1,' +
            '"method":"tools/list","params":{' + META_MODERN + '}}')
        else
          Response := RoundTrip(Paged, '{"jsonrpc":"2.0","id":1,' +
            '"method":"tools/list","params":{"cursor":"' + Cursor + '",' +
            META_MODERN + '}}');
        if Response = nil then
        begin
          Answered := False;
          Break;
        end;
        try
          // An error reply has no result.tools: the walk stops there.
          Tools := FindPath(Response, 'result.tools');
          PageOk := (Tools <> nil) and (Tools.JSONType = jtArray) and
            (Tools.Count > 0) and (Tools.Count <= 2) and
            (FindPath(Response, 'result.ttlMs') <> nil) and
            (FindPath(Response, 'result.cacheScope') <> nil);
          PagesOk := PagesOk and PageOk;
          if PageOk then
            Names := Names + ToolNames(Response);
          if FindPath(Response, 'result.nextCursor') <> nil then
            Cursor := PathString(Response, 'result.nextCursor')
          else
            Cursor := '';
        finally
          Response.Free;
        end;
        if Pages = 0 then
          FirstCursor := Cursor;
        Inc(Pages);
      until (Cursor = '') or not PageOk or (Pages > 50);
      Check(Answered, 'pagination: every tools/list page answered');
      Check(PagesOk and (Pages > 1),
        'pagination: pages of one or two tools, with caching fields');
      Check(Answered and PagesOk and (Cursor = ''),
        'pagination: the walk ends on a page without nextCursor');
      Check((DemoToolNames <> '') and (Names = DemoToolNames),
        'pagination: the pages concatenate to the unpaged list, in order');
      Response := RoundTrip(Paged, '{"jsonrpc":"2.0","id":2,' +
        '"method":"prompts/list","params":{"cursor":"' + FirstCursor + '",' +
        META_MODERN + '}}');
      try
        Check(PathInt(Response, 'error.code') = -32602,
          'pagination: another list''s cursor → -32602');
      finally
        Response.Free;
      end;
    finally
      Shutdown(Paged, 'pagination');
    end;
  finally
    Paged.Free;
  end;
end;

procedure FixtureContentBattery;
const
  // The fixture's complete one-frame WAV, written out literally.
  ONE_FRAME_WAV_BASE64 =
    'UklGRiYAAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAAZGF0YQIAAAAAAA==';
var
  Fixture: TProcess;
  Response: TJSONObject;
  ResponseLine: string;
begin
  Fixture := TProcess.Create(nil);
  try
    Fixture.Executable := FixtureBinary;
    Fixture.Options := [poUsePipes];
    try
      Fixture.Execute;
    except
      on E: Exception do
      begin
        Check(False, 'content: launch ' + FixtureBinary + ': ' + E.Message);
        Exit;
      end;
    end;

    Response := RoundTripWithLine(Fixture,
      '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{' +
      '"name":"test_audio_content",' + META_MODERN + '}}', ResponseLine);
    Check((PathString(Response, 'result.content[0].type') = 'audio') and
      (PathString(Response, 'result.content[0].mimeType') = 'audio/wav') and
      (Pos('"data" : "' + ONE_FRAME_WAV_BASE64 + '"', ResponseLine) > 0),
      'content: audio block (MCPAudioResult), payload byte-exact');
    Response.Free;

    Response := RoundTripWithLine(Fixture,
      '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{' +
      '"name":"test_multiple_content_types",' + META_MODERN + '}}',
      ResponseLine);
    Check((PathString(Response, 'result.content[0].type') = 'text') and
      (PathString(Response, 'result.content[1].type') = 'image') and
      (PathString(Response, 'result.content[2].type') = 'resource') and
      (PathString(Response, 'result.content[2].resource.mimeType') =
      'application/json'),
      'content: mixed text, image and embedded resource, in order');
    Response.Free;

    Response := RoundTripWithLine(Fixture,
      '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{' +
      '"name":"fixture_resource_link",' + META_MODERN + '}}', ResponseLine);
    Check((PathString(Response, 'result.content[1].type') = 'resource_link') and
      (Pos('"uri" : "test://static-text", "name" : "static-text ' +
      #$E4#$B8#$96 + '", "description" : "Caf' + #$C3#$A9 + ' ' +
      #$F0#$9F#$98#$80 + '", "mimeType" : "text/plain"', ResponseLine) > 0),
      'content: resource link (MCPResourceLink), UTF-8 byte-exact');
    Response.Free;

    // Non-object structured output and its JSON text block (#91).
    Response := RoundTripWithLine(Fixture,
      '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{' +
      '"name":"fixture_array_output",' + META_MODERN + '}}', ResponseLine);
    Check(Pos('"content" : [{ "type" : "text", "text" : "[\"Gr' +
      #$C3#$BC + #$C3#$9F + 'e\", \"' + #$F0#$9F#$98#$80 + '\"]" }], ' +
      '"isError" : false, "structuredContent" : ["Gr' + #$C3#$BC + #$C3#$9F +
      'e", "' + #$F0#$9F#$98#$80 + '"]', ResponseLine) > 0,
      'output: array structuredContent and its JSON text, UTF-8 byte-exact');
    Response.Free;

    Response := RoundTripWithLine(Fixture,
      '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{' +
      '"name":"fixture_bad_output",' + META_MODERN + '}}', ResponseLine);
    Check(Pos('"text" : "Tool \"fixture_bad_output\" produced output that ' +
      'does not match its outputSchema: Structured output must be an ' +
      'integer" }], "isError" : true', ResponseLine) > 0,
      'output: output breaking its schema becomes isError');
    Response.Free;

    Response := RoundTripWithLine(Fixture,
      '{"jsonrpc":"2.0","id":3,"method":"prompts/get","params":{' +
      '"name":"test_prompt_with_embedded_resource","arguments":{' +
      '"resourceUri":"test://embedded/%E4%B8%96%E7%95%8C"},' + META_MODERN +
      '}}', ResponseLine);
    Check((PathString(Response, 'result.messages[0].content.type') =
      'resource') and (Pos('"uri" : "test://embedded/%E4%B8%96%E7%95%8C"',
      ResponseLine) > 0) and
      (PathString(Response, 'result.messages[0].content.resource.mimeType') =
      'text/plain'),
      'content: prompt message with an embedded resource and its MIME type');
    Response.Free;

    // A handler's deliberate JSON-RPC error (#88) reaches stdout with its
    // code, message and data.
    Response := RoundTripWithLine(Fixture,
      '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{' +
      '"name":"fixture_protocol_error",' + META_MODERN + '}}', ResponseLine);
    Check((PathInt(Response, 'error.code') = 4290) and
      (Pos('"message" : "Quota exhausted: ' + #$E2#$82#$AC + '0 left"',
      ResponseLine) > 0) and
      (PathInt(Response, 'error.data.retryAfterSeconds') = 60),
      'content: handler-raised protocol error, code, message and data');
    Response.Free;

    // The fixture's ApplicationValidated tools check their own arguments.
    Response := RoundTrip(Fixture,
      '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{' +
      '"name":"json_schema_2020_12_tool","arguments":{' +
      '"contactMethod":"phone","email":"a@example.com"},' + META_MODERN + '}}');
    Check((FindPath(Response, 'result.isError') <> nil) and
      FindPath(Response, 'result.isError').AsBoolean,
      'content: json_schema_2020_12_tool refuses phone without a phone');
    Response.Free;
    Response := RoundTrip(Fixture,
      '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{' +
      '"name":"test_custom_headers","arguments":{},' + META_MODERN + '}}');
    Check((FindPath(Response, 'result.isError') <> nil) and
      FindPath(Response, 'result.isError').AsBoolean,
      'content: test_custom_headers refuses a missing region');
    Response.Free;

    Response := RoundTrip(Fixture,
      '{"jsonrpc":"2.0","id":4,"method":"prompts/get","params":{' +
      '"name":"test_prompt_with_embedded_resource",' + META_MODERN + '}}');
    Check(PathInt(Response, 'error.code') = -32602,
      'content: prompt missing its required argument → -32602');
    Response.Free;
    Response := RoundTrip(Fixture,
      '{"jsonrpc":"2.0","id":8,"method":"prompts/get","params":{' +
      '"name":"test_prompt_with_embedded_resource","arguments":{' +
      '"resourceUri":"not a URI"},' + META_MODERN + '}}');
    Check((Response <> nil) and (Response.Find('error') <> nil),
      'content: prompt refuses a malformed resource URI');
    Response.Free;

    Shutdown(Fixture, 'content');
  finally
    Fixture.Free;
  end;
end;


// The "a" field (argument digest) of a sealed requestState's envelope,
// '' when the token does not decode.
function EnvelopeArgumentsDigest(const AToken: string): string;
var
  Parts: TStringArray;
  Envelope: RawByteString;
  Data: TJSONData;
begin
  Result := '';
  Parts := AToken.Split(['.']);
  if (Length(Parts) <> 3) or not TryBase64UrlDecode(Parts[1], Envelope) then
    Exit;
  Data := GetJSON(Envelope);
  try
    if (Data.JSONType = jtObject) and (TJSONObject(Data).Find('a') <> nil) then
      Result := TJSONObject(Data).Get('a', '');
  finally
    Data.Free;
  end;
end;

// "sha256:" and the lowercase hex of ADigest, as Skills entries write it.
function HexDigest(const ADigest: TSHA256Digest): string;
var
  I: Integer;
begin
  Result := 'sha256:';
  for I := Low(ADigest) to High(ADigest) do
    Result := Result + LowerCase(IntToHex(ADigest[I], 2));
end;

// A skill written to a temporary directory and served by
// `mcpdemo --skills-dir` (#117): its frontmatter read from the YAML, its
// SKILL.md the bytes on disk, matching the listed digest.
procedure SkillsDirBattery;
const
  SKILL_MD = '---' + #10 + 'name: from-disk' + #10 + 'description: >-' + #10 +
    '  Loaded from a' + #10 + '  directory' + #10 + '---' + #10 + 'Hello.' +
    #10;
var
  Dir, Text: string;
  Stream: TFileStream;
  Demo: TProcess;
  Response: TJSONObject;
  Digest: string;
  Attempt: Integer;
begin
  // A directory of its own: created new, never reused, a bounded number
  // of tries; cleanup covers everything after it exists.
  Dir := '';
  for Attempt := 1 to 100 do
  begin
    Dir := IncludeTrailingPathDelimiter(GetTempDir(False)) +
      'mcpsmoke-skills-' + IntToStr(GetProcessID) + '-' +
      IntToStr(Random(1000000));
    if CreateDir(Dir) then
      Break;
    Dir := '';
  end;
  if Dir = '' then
  begin
    Check(False, 'skills from disk: a temporary directory');
    Exit;
  end;
  Demo := nil;
  try
    CreateDir(Dir + PathDelim + 'from-disk');
    Stream := TFileStream.Create(Dir + PathDelim + 'from-disk' + PathDelim +
      'SKILL.md', fmCreate);
    try
      Stream.WriteBuffer(SKILL_MD[1], Length(SKILL_MD));
    finally
      Stream.Free;
    end;
    Demo := TProcess.Create(nil);
    Demo.Executable := DemoBinary;
    Demo.Parameters.Add('--skills-dir');
    Demo.Parameters.Add(Dir);
    Demo.Options := [poUsePipes];
    try
      Demo.Execute;
    except
      on E: Exception do
      begin
        Check(False, 'skills from disk: launch ' + DemoBinary + ': ' +
          E.Message);
        Exit;
      end;
    end;
    try
      Response := RoundTrip(Demo, '{"jsonrpc":"2.0","id":1,' +
        '"method":"skills/get","params":{' +
        '"uri":"skill://disk/from-disk/SKILL.md",' + META_MODERN + '}}');
      Digest := PathString(Response, 'result.skill.resources[0].digest');
      Check(PathInt(Response, 'result.skill.resources[0].size') =
        Length(SKILL_MD), 'skills from disk: the listed size is the file''s');
      Check(PathString(Response, 'result.skill.frontmatter.description') =
        'Loaded from a directory', 'skills from disk: the folded ' +
        'description read from the YAML');
      Response.Free;
      Response := RoundTrip(Demo, '{"jsonrpc":"2.0","id":2,' +
        '"method":"resources/read","params":{' +
        '"uri":"skill://disk/from-disk/SKILL.md",' + META_MODERN + '}}');
      Text := PathString(Response, 'result.contents[0].text');
      Check((Text = SKILL_MD) and (HexDigest(SHA256(Text)) = Digest),
        'skills from disk: SKILL.md served as on disk, matching its digest');
      Response.Free;
    finally
      Shutdown(Demo, 'skills from disk');
    end;
  finally
    Demo.Free;
    DeleteFile(Dir + PathDelim + 'from-disk' + PathDelim + 'SKILL.md');
    RemoveDir(Dir + PathDelim + 'from-disk');
    RemoveDir(Dir);
  end;
end;

// The minute clock with its time fixed (`mcpdemo --clock-at`), 10
// seconds into minute M: maxAgeMs 30000 replays from 20 seconds before
// M, so the tick of M is in the window and the one before is not
// (events.mdx, Cursor Lifecycle, verified 2026-11-27; #118 review).
procedure FixedClockBattery;
const
  M = 29929560; // 2026-11-27T10:00:00Z in minutes since 1970
var
  Clock: TProcess;
  Response: TJSONObject;
begin
  Clock := TProcess.Create(nil);
  try
    Clock.Executable := DemoBinary;
    Clock.Parameters.Add('--clock-at');
    Clock.Parameters.Add(IntToStr(Int64(M) * 60000 + 10000));
    Clock.Options := [poUsePipes];
    try
      Clock.Execute;
    except
      on E: Exception do
      begin
        Check(False, 'fixed clock: launch ' + DemoBinary + ': ' + E.Message);
        Exit;
      end;
    end;
    try
      Response := RoundTrip(Clock, '{"jsonrpc":"2.0","id":1,' +
        '"method":"events/poll","params":{"name":"clock.minute",' +
        '"maxAgeMs":30000,"cursor":"' + IntToStr(M - 1) + '",' + META_MODERN +
        '}}');
      Check((PathString(Response, 'result.events[0].eventId') = 'minute-' +
        IntToStr(M)) and (PathString(Response, 'result.events[0].timestamp') =
        '2026-11-27T10:00:00Z') and (FindPath(Response, 'result.events[1]') =
        nil) and not FindPath(Response, 'result.truncated').AsBoolean,
        'events/poll at a fixed time: the tick inside a 30 s window replayed');
      Response.Free;
      Response := RoundTrip(Clock, '{"jsonrpc":"2.0","id":2,' +
        '"method":"events/poll","params":{"name":"clock.minute",' +
        '"maxAgeMs":30000,"cursor":"' + IntToStr(M - 3) + '",' + META_MODERN +
        '}}');
      Check((PathString(Response, 'result.events[0].eventId') = 'minute-' +
        IntToStr(M)) and FindPath(Response, 'result.truncated').AsBoolean,
        'events/poll at a fixed time: older ticks skipped and truncated');
      Response.Free;
    finally
      Shutdown(Clock, 'fixed clock');
    end;
  finally
    Clock.Free;
  end;
end;

// The Tasks extension over stdio, against the conformance fixture (#82):
// a task created, polled to its result, answered through tasks/update,
// cancelled, and a task still running when stdin ends. Shapes verified
// 2026-11-28 against modelcontextprotocol/ext-tasks
// specification/2026-07-28/tasks.md at cc9aaac.
procedure TasksBattery;
var
  Fixture: TProcess;
  NextId: Integer;

  function Call(const AMethod, AParams: string; out ALine: string): TJSONObject;
  begin
    Inc(NextId);
    Result := RoundTripWithLine(Fixture, '{"jsonrpc":"2.0","id":' +
      IntToStr(NextId) + ',"method":"' + AMethod + '","params":{' + AParams +
      ',' + META_TASKS + '}}', ALine);
  end;

  function Start(const AParams: string): string;
  var
    Response: TJSONObject;
    Line: string;
  begin
    Response := Call('tools/call', AParams, Line);
    Result := PathString(Response, 'result.taskId');
    Check((PathString(Response, 'result.resultType') = 'task') and
      (Length(Result) = 22) and
      (PathString(Response, 'result.status') <> ''),
      'tasks: tools/call answers a CreateTaskResult');
    Response.Free;
  end;

  // tasks/get until the status is AStatus, at most 5 s; the last line.
  function Await(const ATaskId, AStatus: string; out ALine: string): Boolean;
  var
    Response: TJSONObject;
    Step: Integer;
  begin
    Result := False;
    for Step := 1 to 250 do
    begin
      Response := Call('tasks/get', '"taskId":"' + ATaskId + '"', ALine);
      Result := PathString(Response, 'result.status') = AStatus;
      Response.Free;
      if Result then
        Exit;
      Sleep(20);
    end;
  end;

var
  TaskId, Line: string;
  Response: TJSONObject;
begin
  NextId := 0;
  Fixture := TProcess.Create(nil);
  try
    Fixture.Executable := FixtureBinary;
    Fixture.Options := [poUsePipes];
    try
      Fixture.Execute;
    except
      on E: Exception do
      begin
        Check(False, 'tasks: launch ' + FixtureBinary + ': ' + E.Message);
        Exit;
      end;
    end;

    Response := Call('server/discover', '"x":0', Line);
    Check(Pos('"io.modelcontextprotocol/tasks" : {}', Line) > 0,
      'tasks: server/discover declares the extension');
    Response.Free;

    TaskId := Start('"name":"slow_compute","arguments":{"seconds":0,' +
      '"label":"Gr' + #$C3#$BC + #$C3#$9F + 'e ' + #$F0#$9F#$98#$80 + '"}');
    Check(Await(TaskId, 'completed', Line) and (Pos('"text" : "Computed Gr' +
      #$C3#$BC + #$C3#$9F + 'e ' + #$F0#$9F#$98#$80 + '"', Line) > 0),
      'tasks: tasks/get inlines the result, UTF-8 byte-exact');

    TaskId := Start('"name":"confirm_delete","arguments":{"filename":' +
      '"a.txt"}');
    Check(Await(TaskId, 'input_required', Line) and
      (Pos('"inputRequests" : { "confirm" : { "method" : ' +
      '"elicitation/create"', Line) > 0),
      'tasks: input_required carries the input request');
    Response := Call('tasks/update', '"taskId":"' + TaskId +
      '","inputResponses":{"confirm":{"action":"accept","content":' +
      '{"confirm":true}}}', Line);
    Check(PathString(Response, 'result.resultType') = 'complete',
      'tasks: tasks/update acknowledged');
    Response.Free;
    Check(Await(TaskId, 'completed', Line) and
      (Pos('"text" : "Deleted a.txt"', Line) > 0),
      'tasks: the answered task completes');

    TaskId := Start('"name":"slow_compute","arguments":{"seconds":60}');
    Response := Call('tasks/cancel', '"taskId":"' + TaskId + '"', Line);
    Check(PathString(Response, 'result.resultType') = 'complete',
      'tasks: tasks/cancel acknowledged');
    Response.Free;
    Check(Await(TaskId, 'cancelled', Line), 'tasks: the task is cancelled');

    Response := Call('tasks/get', '"taskId":"nope"', Line);
    Check(PathInt(Response, 'error.code') = -32602,
      'tasks: an unknown task answers -32602');
    Response.Free;

    // A task still running when stdin ends is cancelled, and the
    // process exits as usual.
    Start('"name":"slow_compute","arguments":{"seconds":60}');
    Shutdown(Fixture, 'tasks');
  finally
    Fixture.Free;
  end;
end;

// Push delivery over stdio (#126), the minute clock fixed 10 seconds
// into minute M: a stream from M-2 opens with active and the two ticks,
// each with its cursor; a second stream and a tools/list are answered
// while it is open; its heartbeat follows the 1 s grant; once it is
// cancelled nothing more comes for it (events.mdx, Push-Based
// Delivery, verified 2026-11-27).
procedure PushBattery;
const
  M = 29929560; // 2026-11-27T10:00:00Z in minutes since 1970
  SUB = 'io.modelcontextprotocol/subscriptionId';
var
  Clock: TProcess;
  Message: TJSONObject;

  function Next: TJSONObject;
  begin
    FreeAndNil(Message);
    Message := NextJson(Clock);
    Result := Message;
  end;

  function Arrived(const AMethod: string; ASubscription: Integer): Boolean;
  var
    Meta, Id: TJSONData;
  begin
    Result := False;
    if (Message = nil) or (PathString(Message, 'method') <> AMethod) then
      Exit;
    // A key with dots: looked up by name, not by path.
    Meta := FindPath(Message, 'params._meta');
    if (Meta = nil) or (Meta.JSONType <> jtObject) then
      Exit;
    Id := TJSONObject(Meta).Find(SUB);
    Result := (Id <> nil) and (Id.JSONType = jtNumber) and
      (Id.AsInteger = ASubscription);
  end;

begin
  Message := nil;
  Clock := TProcess.Create(nil);
  try
    Clock.Executable := DemoBinary;
    Clock.Parameters.Add('--clock-at');
    Clock.Parameters.Add(IntToStr(Int64(M) * 60000 + 10000));
    Clock.Options := [poUsePipes];
    try
      Clock.Execute;
    except
      on E: Exception do
      begin
        Check(False, 'push: launch ' + DemoBinary + ': ' + E.Message);
        Exit;
      end;
    end;
    try
      SendLine(Clock, '{"jsonrpc":"2.0","id":21,"method":"events/stream",' +
        '"params":{"name":"clock.minute","cursor":"' + IntToStr(M - 2) +
        '","heartbeatMs":1000,' + META_MODERN + '}}');
      Next;
      Check(Arrived('notifications/events/active', 21) and
        (PathString(Message, 'params.cursor') = IntToStr(M - 2)) and
        (FindPath(Message, 'params.heartbeatMs').AsInteger = 1000),
        'events/stream: active first, with the client''s cursor and the grant');
      Next;
      Check(Arrived('notifications/events/event', 21) and
        (PathString(Message, 'params.eventId') = 'minute-' + IntToStr(M - 1))
        and (PathString(Message, 'params.cursor') = IntToStr(M - 1)),
        'events/stream: the first tick with the cursor after it');
      Next;
      Check(Arrived('notifications/events/event', 21) and
        (PathString(Message, 'params.cursor') = IntToStr(M)),
        'events/stream: the second tick with the cursor after it');
      SendLine(Clock, '{"jsonrpc":"2.0","id":22,"method":"events/stream",' +
        '"params":{"name":"clock.minute",' + META_MODERN + '}}');
      Next;
      Check(Arrived('notifications/events/active', 22) and
        (PathString(Message, 'params.cursor') = IntToStr(M)),
        'events/stream: a second stream from now, beside the first');
      SendLine(Clock, '{"jsonrpc":"2.0","id":23,"method":"tools/list",' +
        '"params":{' + META_MODERN + '}}');
      Next;
      Check((Message <> nil) and (FindPath(Message, 'id') <> nil) and
        (FindPath(Message, 'id').AsInteger = 23) and
        (FindPath(Message, 'result.tools') <> nil),
        'events/stream: a request is answered while streams are open');
      Next;
      Check(Arrived('notifications/events/heartbeat', 21) and
        (PathString(Message, 'params.cursor') = IntToStr(M)),
        'events/stream: a heartbeat after the granted second');
      SendLine(Clock, '{"jsonrpc":"2.0","method":"notifications/cancelled",' +
        '"params":{"requestId":21}}');
      Sleep(1500);
      SendLine(Clock, '{"jsonrpc":"2.0","id":24,"method":"tools/list",' +
        '"params":{' + META_MODERN + '}}');
      Next;
      Check((Message <> nil) and (FindPath(Message, 'id') <> nil) and
        (FindPath(Message, 'id').AsInteger = 24),
        'events/stream: nothing more for a cancelled stream');
    finally
      FreeAndNil(Message);
      Shutdown(Clock, 'push');
    end;
  finally
    Clock.Free;
  end;
end;

var
  Demo: TProcess;
  Response: TJSONObject;
  ResponseLine, SealedState, SkillDigest, SkillText, EventCursor: string;
  SkillSize: Integer;
  ServerInfo: TJSONData;
  StartedAt: QWord;
  WaitedMs: Integer;

begin
  Demo := TProcess.Create(nil);
  try
    Demo.Executable := DemoBinary;
    Demo.Options := [poUsePipes];
    try
      Demo.Execute;
    except
      on E: Exception do
      begin
        WriteLn('FAIL  cannot launch ', DemoBinary, ': ', E.Message);
        Halt(1);
      end;
    end;

    // server/discover — the mandatory entry point.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{' +
      META_MODERN + '}}');
    Check(PathString(Response, 'result.resultType') = 'complete',
      'discover: resultType complete');
    Check(PathString(Response, 'result.supportedVersions[0]') = '2026-07-28',
      'discover: supportedVersions lists 2026-07-28');
    Check(FindPath(Response, 'result.capabilities.tools') <> nil,
      'discover: tools capability');
    ServerInfo := FindPath(Response, 'result.capabilities.extensions');
    Check((ServerInfo <> nil) and (ServerInfo.JSONType = jtObject) and
      (TJSONObject(ServerInfo).Find('io.modelcontextprotocol/ui') <> nil),
      'discover: MCP Apps extension declared (#98)');
    // The serverInfo _meta key contains dots, so FindPath (which
    // splits on dots) cannot address it — navigate by hand.
    ServerInfo := FindPath(Response, 'result._meta');
    if (ServerInfo <> nil) and (ServerInfo.JSONType = jtObject) then
      ServerInfo := TJSONObject(ServerInfo).Find(
        'io.modelcontextprotocol/serverInfo')
    else
      ServerInfo := nil;
    Check((ServerInfo <> nil) and (ServerInfo.JSONType = jtObject) and
      (TJSONObject(ServerInfo).Get('name', '') = 'pascal-mcp-sdk-demo'),
      'discover: serverInfo stamped');
    Check(PathString(Response, 'result.serverInfo.name') = 'pascal-mcp-sdk-demo',
      'discover: top-level serverInfo (required by RC wire schema)');
    Check(FindPath(Response, 'result.ttlMs') <> nil,
      'discover: ttlMs present (SEP-2549)');
    Check(FindPath(Response, 'result.capabilities.completions') <> nil,
      'discover: completions capability (a completion is registered)');
    Check(PathString(Response, 'result.serverInfo.title') = 'pascal-mcp-sdk demo',
      'discover: serverInfo title (#96)');
    Response.Free;

    // tools/list.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{' +
      META_MODERN + '}}');
    Check(PathString(Response, 'result.tools[0].name') = 'echo',
      'tools/list: echo first (registration order)');
    Check(PathString(Response, 'result.tools[0]._meta.ui.resourceUri') =
      'ui://pascal-mcp-sdk/echo-card',
      'tools/list: echo links its MCP Apps card (#98)');
    Check(PathString(Response, 'result.tools[1].name') = 'add',
      'tools/list: add second');
    Check(FindPath(Response, 'result.tools[1].outputSchema') <> nil,
      'tools/list: add carries outputSchema');
    Check(PathString(Response, 'result.cacheScope') = 'private',
      'tools/list: cacheScope present (SEP-2549)');
    DemoToolNames := ToolNames(Response);
    Response.Free;

    // tools/call echo.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{' +
      '"name":"echo","arguments":{"message":"round trip"},' +
      META_MODERN + '}}');
    Check(PathString(Response, 'result.content[0].text') = 'round trip',
      'tools/call echo: text mirrored');
    Response.Free;

    Response := RoundTripWithLine(Demo,
      '{"jsonrpc":"2.0","id":19,"method":"tools/call","params":{' +
      '"name":"echo","arguments":{"message":"' + UTF8_PAYLOAD + '"},' +
      META_MODERN + '}}', ResponseLine);
    Check(Pos('"text" : "' + UTF8_PAYLOAD + '"', ResponseLine) > 0,
      'tools/call echo: non-ASCII bytes mirrored as UTF-8');
    Response.Free;

    Response := RoundTripWithLine(Demo,
      '{"jsonrpc":"2.0","id":23,"method":"tools/call","params":{' +
      '"name":"echo","arguments":{"message":"a\u4e16\u754cb"},' +
      META_MODERN + '}}', ResponseLine);
    Check(Pos('"text" : "a' + UTF8_WORLD + 'b"', ResponseLine) > 0,
      'tools/call echo: adjacent escapes mirrored as exact UTF-8 bytes');
    Response.Free;

    // Raw handlers validate arguments against their advertised schema.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{' +
      '"name":"echo","arguments":{},' + META_MODERN + '}}');
    Check((FindPath(Response, 'result.isError') <> nil) and
      FindPath(Response, 'result.isError').AsBoolean,
      'tools/call echo (bad args): isError true');
    Response.Free;

    // tools/call add — structured content.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{' +
      '"name":"add","arguments":{"a":19,"b":23},' + META_MODERN + '}}');
    Check(PathInt(Response, 'result.structuredContent.sum') = 42,
      'tools/call add: structuredContent.sum = 42');
    Response.Free;

    // tools/call pixel — image content built by MCPImageResult from
    // raw bytes; the wire form is the spec's ImageContent block.
    Response := RoundTripWithLine(Demo,
      '{"jsonrpc":"2.0","id":33,"method":"tools/call","params":{' +
      '"name":"pixel",' + META_MODERN + '}}', ResponseLine);
    Check(PathString(Response, 'result.content[0].type') = 'image',
      'tools/call pixel: image content block');
    Check(PathString(Response, 'result.content[0].mimeType') = 'image/png',
      'tools/call pixel: mimeType passed through');
    Check(Pos('"data" : "' + ONE_PIXEL_PNG_BASE64 + '"', ResponseLine) > 0,
      'tools/call pixel: image bytes base64-encoded byte-exactly');
    Response.Free;

    // tools/call add with missing argument — execution error in-band.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{' +
      '"name":"add","arguments":{"a":19},' + META_MODERN + '}}');
    Check((FindPath(Response, 'result.isError') <> nil) and
      FindPath(Response, 'result.isError').AsBoolean,
      'tools/call add (bad args): isError true');
    Response.Free;

    // tools/call unknown — protocol error.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{' +
      '"name":"nope",' + META_MODERN + '}}');
    Check(PathInt(Response, 'error.code') = -32602,
      'tools/call unknown: -32602');
    Response.Free;

    // MRTR (#4): round 1 returns input_required with an elicitation
    // form and opaque state; the retry with inputResponses completes.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{' +
      '"name":"greet_user",' + META_MRTR + '}}');
    Check(PathString(Response, 'result.resultType') = 'input_required',
      'MRTR round 1: resultType input_required');
    Check(PathString(Response, 'result.inputRequests.who.method') =
      'elicitation/create', 'MRTR round 1: elicitation request present');
    // The handler's state leaves sealed (#89), never as plain text: the
    // MRTR page makes requestState attacker-controlled input whose
    // integrity a server MUST protect (verified 2026-11-26,
    // https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr).
    SealedState := PathString(Response, 'result.requestState');
    Check((Pos('v1.', SealedState) = 1) and
      (Pos('greet-round-1', SealedState) = 0),
      'MRTR round 1: requestState sealed');
    // The envelope binds the arguments by the SHA-256 of their canonical
    // form: {} here, whose digest is fixed. CI runs this battery under
    // LC_ALL=C too, where a code page conversion once changed it.
    Check(EnvelopeArgumentsDigest(SealedState) =
      'RBNvo1WzZ4oRRq0W9-hknpT7T8If536DEMBg9hyq_4o',
      'MRTR round 1: argument digest is SHA-256 of {} on any locale');
    Response.Free;
    // A forged state is refused before the handler runs.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":33,"method":"tools/call","params":{' +
      '"name":"greet_user","inputResponses":{"who":{"action":"accept",' +
      '"content":{"name":"Ada"}}},"requestState":"greet-round-1",' +
      META_MRTR + '}}');
    Check(PathInt(Response, 'error.code') = -32602,
      'MRTR retry: forged requestState → -32602');
    Response.Free;
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{' +
      '"name":"greet_user","inputResponses":{"who":{"action":"accept",' +
      '"content":{"name":"Ada"}}},"requestState":"' + SealedState + '",' +
      META_MRTR + '}}');
    Check(PathString(Response, 'result.resultType') = 'complete',
      'MRTR retry: resultType complete');
    Check(PathString(Response, 'result.content[0].text') = 'Hello, Ada!',
      'MRTR retry: elicited name woven into the result');
    Response.Free;

    // completion/complete (#81): the demo's static name list, by
    // prefix ignoring case; verified 2026-11-26 against
    // https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/completion
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":34,"method":"completion/complete","params":{' +
      '"ref":{"type":"ref/prompt","name":"greet"},' +
      '"argument":{"name":"name","value":"a"},' + META_MODERN + '}}');
    Check((PathString(Response, 'result.completion.values[0]') = 'Ada') and
      (PathString(Response, 'result.completion.values[1]') = 'Alan') and
      (PathInt(Response, 'result.completion.total') = 2),
      'completion/complete: prefix matches from the prompt argument');
    Response.Free;
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":35,"method":"completion/complete","params":{' +
      '"ref":{"type":"ref/prompt","name":"nope"},' +
      '"argument":{"name":"name","value":"a"},' + META_MODERN + '}}');
    Check(PathInt(Response, 'error.code') = -32602,
      'completion/complete: unknown prompt → -32602');
    Response.Free;

    // Cancellation reaches a running handler (#93; spec verified
    // 2026-11-27: the receiver SHOULD stop and not respond,
    // https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/cancellation).
    // countdown's first progress event shows it is running before the
    // cancellation is sent; the next request is then answered long
    // before the countdown would end, with nothing for the cancelled one.
    StartedAt := GetTickCount64;
    SendLine(Demo, '{"jsonrpc":"2.0","id":40,"method":"tools/call",' +
      '"params":{"name":"countdown","arguments":{"seconds":5},' +
      '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
      '"io.modelcontextprotocol/clientCapabilities":{},' +
      '"progressToken":"cd"}}}');
    Response := NextJson(Demo);
    Check(PathString(Response, 'method') = 'notifications/progress',
      'cancellation: countdown running (first progress event)');
    Response.Free;
    SendLine(Demo, '{"jsonrpc":"2.0","method":"notifications/cancelled",' +
      '"params":{"requestId":40,"reason":"smoke"}}');
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":41,"method":"tools/list","params":{' +
      META_MODERN + '}}');
    Check((PathInt(Response, 'id') = 41) and
      (GetTickCount64 - StartedAt < 3500),
      'cancellation: running countdown cancelled, its response withheld');
    Response.Free;

    // MRTR without the declared capability — the spec forbids sending
    // the request kind, so the call fails with -32021 and its data
    // names what the client lacks (spec verified 2026-11-27:
    // https://modelcontextprotocol.io/specification/2026-07-28/basic/index#_meta).
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":32,"method":"tools/call","params":{' +
      '"name":"greet_user",' + META_MODERN + '}}');
    Check(PathInt(Response, 'error.code') = -32021,
      'MRTR without capability: -32021');
    Check(FindPath(Response, 'error.data.requiredCapabilities.elicitation') <>
      nil, 'MRTR without capability: error data names elicitation');
    Response.Free;

    // A client that declares only URL elicitation cannot take the form
    // greet_user sends (#108; client/elicitation#capabilities, verified
    // 2026-11-27).
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":33,"method":"tools/call","params":{' +
      '"name":"greet_user","_meta":{' +
      '"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
      '"io.modelcontextprotocol/clientCapabilities":' +
      '{"elicitation":{"url":{}}}}}}');
    Check((PathInt(Response, 'error.code') = -32021) and
      (FindPath(Response, 'error.data.requiredCapabilities.elicitation.form')
      <> nil), 'MRTR URL-only client: -32021 names elicitation.form');
    Response.Free;

    // Skills (#115): the entry's digest and size match the bytes
    // resources/read returns (skills.mdx, Integrity and Verification,
    // verified 2026-11-27).
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":37,"method":"skills/list","params":{' +
      META_MODERN + '}}');
    SkillDigest := PathString(Response, 'result.skills[0].resources[0].digest');
    SkillSize := PathInt(Response, 'result.skills[0].resources[0].size');
    Check((PathString(Response, 'result.skills[0].uri') =
      'skill://pascal-mcp-sdk/echo-usage/SKILL.md') and
      (PathString(Response, 'result.skills[0].frontmatter.name') =
      'echo-usage') and (FindPath(Response, 'result.ttlMs') <> nil),
      'skills/list: the demo skill with its frontmatter and cache fields');
    Response.Free;
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":38,"method":"resources/read","params":{' +
      '"uri":"skill://pascal-mcp-sdk/echo-usage/SKILL.md",' + META_MODERN +
      '}}');
    SkillText := PathString(Response, 'result.contents[0].text');
    Check((Length(SkillText) = SkillSize) and
      (HexDigest(SHA256(SkillText)) = SkillDigest) and
      (Pos('name: "echo-usage"', SkillText) > 0),
      'skills: SKILL.md read back matches its listed digest and size');
    Response.Free;
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":40,"method":"skills/get","params":{' +
      '"uri":"skill://pascal-mcp-sdk/echo-usage/SKILL.md",' + META_MODERN +
      '}}');
    Check((PathString(Response, 'result.skill.resources[0].digest') =
      SkillDigest) and (PathString(Response, 'result.skill.frontmatter.license')
      = 'MIT'), 'skills/get: the demo skill''s entry, with the listed digest');
    Response.Free;
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":39,"method":"resources/directory/read",' +
      '"params":{"uri":"skill://pascal-mcp-sdk/echo-usage",' + META_MODERN +
      '}}');
    Check(PathString(Response, 'result.resources[1].mimeType') =
      'inode/directory', 'resources/directory/read: the skill root lists ' +
      'its examples directory');
    Response.Free;

    // Events (#118): a poll from now gives the current minute; three
    // minutes back with maxEvents 2 gives the next two and hasMore,
    // whether or not the minute turns in between (events.mdx,
    // Poll-Based Delivery, verified 2026-11-27).
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":41,"method":"events/poll","params":{' +
      '"name":"clock.minute","cursor":null,' + META_MODERN + '}}');
    EventCursor := PathString(Response, 'result.cursor');
    Check((EventCursor <> '') and (FindPath(Response, 'result.events') <> nil)
      and (FindPath(Response, 'result.events').Count = 0),
      'events/poll from now: a fresh cursor and no events');
    Response.Free;
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":42,"method":"events/poll","params":{' +
      '"name":"clock.minute","maxEvents":2,"cursor":"' +
      IntToStr(StrToInt64Def(EventCursor, 0) - 3) + '",' + META_MODERN + '}}');
    Check((PathString(Response, 'result.events[0].eventId') = 'minute-' +
      IntToStr(StrToInt64Def(EventCursor, 0) - 2)) and
      (PathString(Response, 'result.events[1].name') = 'clock.minute') and
      (FindPath(Response, 'result.events[2]') = nil) and
      (FindPath(Response, 'result.hasMore') <> nil) and
      FindPath(Response, 'result.hasMore').AsBoolean,
      'events/poll from a cursor: two occurrences, more waiting');
    Response.Free;
    // maxAgeMs bounds the replay: one minute back at most, truncated.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":43,"method":"events/poll","params":{' +
      '"name":"clock.minute","maxAgeMs":60000,"cursor":"' +
      IntToStr(StrToInt64Def(EventCursor, 0) - 3) + '",' + META_MODERN + '}}');
    Check((FindPath(Response, 'result.truncated') <> nil) and
      FindPath(Response, 'result.truncated').AsBoolean and
      (FindPath(Response, 'result.events') <> nil) and
      (FindPath(Response, 'result.events').Count <= 2),
      'events/poll with maxAgeMs: older minutes skipped and truncated');
    Response.Free;

    // The MCP Apps card is an ordinary resources/read (#98).
    Response := RoundTripWithLine(Demo,
      '{"jsonrpc":"2.0","id":36,"method":"resources/read","params":{' +
      '"uri":"ui://pascal-mcp-sdk/echo-card",' + META_MODERN + '}}',
      ResponseLine);
    Check((PathString(Response, 'result.contents[0].mimeType') =
      'text/html;profile=mcp-app') and
      (Pos('<!DOCTYPE html>', ResponseLine) > 0) and
      (Pos('"prefersBorder" : true', ResponseLine) > 0),
      'resources/read: MCP Apps card with its media type and _meta.ui');
    // The View opens with the handshake a host waits for before it
    // sends the tool result (ext-apps specification 2026-01-26).
    Check((Pos('ui/initialize', ResponseLine) > 0) and
      (Pos('ui/notifications/initialized', ResponseLine) > 0) and
      (Pos('ui/resource-teardown', ResponseLine) > 0),
      'MCP Apps: the served card names ui/initialize, initialized and ' +
      'teardown (its behavior runs only in a host)');
    Response.Free;

    // resources/list + read.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":7,"method":"resources/list","params":{' +
      META_MODERN + '}}');
    Check(PathString(Response, 'result.resources[0].uri') =
      'mcp://pascal-mcp-sdk/greeting',
      'resources/list: greeting present');
    Check(PathString(Response, 'result.resources[0].title') = 'Greeting',
      'resources/list: greeting title (#96)');
    Response.Free;

    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":8,"method":"resources/read","params":{' +
      '"uri":"mcp://pascal-mcp-sdk/greeting",' + META_MODERN + '}}');
    Check(Pos('Hello from pascal-mcp-sdk',
      PathString(Response, 'result.contents[0].text')) > 0,
      'resources/read: greeting text');
    Response.Free;

    // Unsupported protocol version — -32022 with the supported list.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":9,"method":"tools/list","params":{' +
      '"_meta":{"io.modelcontextprotocol/protocolVersion":"1900-01-01",' +
      '"io.modelcontextprotocol/clientCapabilities":{}}}}');
    Check(PathInt(Response, 'error.code') = -32022,
      'unsupported version: -32022');
    Check(PathString(Response, 'error.data.supported[0]') = '2026-07-28',
      'unsupported version: supported list in data');
    Response.Free;

    // resources/templates/list + a templated read.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":21,"method":"resources/templates/list",' +
      '"params":{' + META_MODERN + '}}');
    Check(PathString(Response, 'result.resourceTemplates[0].uriTemplate') =
      'mcp://pascal-mcp-sdk/shout/{text}',
      'templates/list: shout template present');
    Response.Free;

    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":22,"method":"resources/read","params":{' +
      '"uri":"mcp://pascal-mcp-sdk/shout/hey",' + META_MODERN + '}}');
    Check(PathString(Response, 'result.contents[0].text') = 'HEY',
      'resources/read: template variable extracted (shout/hey → HEY)');
    Response.Free;

    // prompts/list + prompts/get.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":8,"method":"prompts/list","params":{' +
      META_MODERN + '}}');
    Check(PathString(Response, 'result.prompts[0].name') = 'greet',
      'prompts/list: greet present');
    Check(FindPath(Response, 'result.ttlMs') <> nil,
      'prompts/list: ttlMs present (SEP-2549)');
    Response.Free;

    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":9,"method":"prompts/get","params":{' +
      '"name":"greet","arguments":{"name":"Ada"},' + META_MODERN + '}}');
    Check(Pos('Ada', PathString(Response,
      'result.messages[0].content.text')) > 0,
      'prompts/get: argument woven into message');
    Response.Free;

    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":10,"method":"prompts/get","params":{' +
      '"name":"greet",' + META_MODERN + '}}');
    Check(PathInt(Response, 'error.code') = -32602,
      'prompts/get: missing required argument → -32602');
    Response.Free;

    // In-request notifications: with progressToken + logLevel opted
    // in, echo emits progress(0.5) + log(info) + progress(1.0) before
    // its response — four lines total, in order.
    SendLine(Demo,
      '{"jsonrpc":"2.0","id":16,"method":"tools/call","params":{' +
      '"name":"echo","arguments":{"message":"noisy hi"},' +
      '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
      '"io.modelcontextprotocol/clientCapabilities":{},' +
      '"io.modelcontextprotocol/logLevel":"info",' +
      '"progressToken":5}}}');
    Response := NextJson(Demo);
    Check(PathString(Response, 'method') = 'notifications/progress',
      'notify: first line is progress');
    Check(PathInt(Response, 'params.progressToken') = 5,
      'notify: token echoed');
    Response.Free;
    Response := NextJson(Demo);
    Check(PathString(Response, 'method') = 'notifications/message',
      'notify: log message with opt-in');
    Check(PathString(Response, 'params.level') = 'info',
      'notify: log level carried');
    Response.Free;
    Response := NextJson(Demo);
    Check(PathString(Response, 'method') = 'notifications/progress',
      'notify: completion progress');
    Response.Free;
    Response := NextJson(Demo);
    Check(PathString(Response, 'result.content[0].text') = 'noisy hi',
      'notify: response arrives after notifications');
    Response.Free;

    // ── Legacy era (dual-era default): the path today's clients
    //    (Claude Code / Claude Desktop) actually take. ──

    // Bare legacy request before the handshake → -32600.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":10,"method":"tools/list","params":{}}');
    Check(PathInt(Response, 'error.code') = -32600,
      'legacy: request before initialize → -32600');
    Response.Free;

    // ping is valid at any time in the legacy era.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":11,"method":"ping"}');
    Check((Response <> nil) and (Response.Find('result') <> nil),
      'legacy: ping answered');
    Response.Free;

    // initialize — negotiate a legacy revision.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":12,"method":"initialize","params":{' +
      '"protocolVersion":"2025-06-18","capabilities":{},' +
      '"clientInfo":{"name":"legacy-smoke","version":"0"}}}');
    Check(PathString(Response, 'result.protocolVersion') = '2025-06-18',
      'legacy: initialize echoes 2025-06-18');
    Check(PathString(Response, 'result.serverInfo.name') = 'pascal-mcp-sdk-demo',
      'legacy: initialize serverInfo');
    Check(FindPath(Response, 'result.resultType') = nil,
      'legacy: initialize result unstamped');
    Response.Free;

    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":120,"method":"tools/list","params":{}}');
    Check((PathInt(Response, 'error.code') = -32600) and
      (PathString(Response, 'error.message') =
      'Received request before initialization is complete: send ' +
      'notifications/initialized first'),
      'legacy: request before initialized notification → -32600');
    Response.Free;

    SendLine(Demo,
      '{"jsonrpc":"2.0","method":"notifications/initialized"}');

    // Legacy tools/call — no _meta anywhere.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{' +
      '"name":"echo","arguments":{"message":"legacy round trip"}}}');
    Check(PathString(Response, 'result.content[0].text') =
      'legacy round trip',
      'legacy: tools/call echo works');
    Check(FindPath(Response, 'result.resultType') = nil,
      'legacy: tools/call result unstamped');
    Response.Free;

    // A cancellation for a request that has already finished is
    // accepted silently and does not disturb the next request on the
    // same session.
    SendLine(Demo,
      '{"jsonrpc":"2.0","method":"notifications/cancelled",' +
      '"params":{"requestId":13,"reason":"finished already"}}');
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":122,"method":"ping"}');
    Check((Response <> nil) and (PathInt(Response, 'id') = 122) and
      (Response.Find('result') <> nil),
      'legacy: cancellation for finished id silent; next request served');
    Response.Free;

    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":121,"method":"initialize","params":{' +
      '"protocolVersion":"2025-11-25","capabilities":{},' +
      '"clientInfo":{"name":"legacy-again","version":"1"}}}');
    Check((PathInt(Response, 'error.code') = -32600) and
      (PathString(Response, 'error.message') =
      'Server is already initialized: initialize may only be sent once'),
      'legacy: second initialize → -32600 already initialized');
    Response.Free;

    // Legacy resource-not-found uses the era-correct -32002.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":14,"method":"resources/read","params":{' +
      '"uri":"mcp://nope"}}');
    Check(PathInt(Response, 'error.code') = -32002,
      'legacy: resource not found → -32002');
    Response.Free;

    // Both eras concurrently: a modern request after the legacy
    // handshake is still served statelessly with modern stamps.
    Response := RoundTrip(Demo,
      '{"jsonrpc":"2.0","id":15,"method":"tools/list","params":{' +
      META_MODERN + '}}');
    Check(PathString(Response, 'result.resultType') = 'complete',
      'dual-era: modern request after legacy handshake stays modern');
    Response.Free;

    // EOF on stdin → prompt exit (the graceful-shutdown contract).
    Shutdown(Demo, 'shutdown');
  finally
    Demo.Free;
  end;

  FixtureContentBattery;
  PagedDemoBattery;
  SkillsDirBattery;
  FixedClockBattery;
  PushBattery;
  TasksBattery;

  WriteLn;
  if Failures = 0 then
    WriteLn('mcpsmoke: all checks passed')
  else
    WriteLn('mcpsmoke: ', Failures, ' check(s) FAILED');
  if Failures > 0 then
    Halt(1);
end.
