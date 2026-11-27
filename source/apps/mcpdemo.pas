program mcpdemo;

// Example MCP server: the smallest complete pascal-mcp-sdk program.
// Exposes tools showing every registration style — echo via the
// fluent schema builder, add via a typed argument class (the class
// expands into the schema, and the handler receives a populated,
// validated instance), greet_user via a raw schema string, and pixel
// returning binary image content, countdown stopping early when the
// client cancels — plus a static resource, a resource
// template, and a prompt. By default it
// serves newline-delimited JSON-RPC on stdin/stdout until the client
// closes stdin; with `--http <port>` the same registrations are
// served over Streamable HTTP on 127.0.0.1 instead (modern era only),
// and with `--page-size <n>` stdio hands its lists out in pages of n.
//
// Try it by hand (all on one line; _meta is required on every request):
//   ./build/mcpdemo <<'EOF'
//   {"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
//   EOF

{$I MCP.inc}

uses
  // Thread driver for the HTTP listener; must be first (Unix).
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils,
  DateUtils,
  Math,

  fpjson,

  MCP.Apps,
  MCP.Events,
  MCP.Protocol,
  MCP.Schema,
  MCP.Server,
  MCP.Skills,
  MCP.Transport.HTTP,
  MCP.Transport.Stdio;

const
  // A minimal MCP App view. It opens with the View handshake the host
  // waits for (ui/initialize, then ui/notifications/initialized once the
  // host answers with a result, a failure line otherwise; ext-apps
  // specification 2026-01-26, lifecycle, verified 2026-11-27), shows the
  // text of the tool result the host sends
  // (ui/notifications/tool-result), and answers ui/resource-teardown.
  // It listens to its parent only.
  ECHO_CARD_HTML =
    '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Echo</title>' +
    '<style>body{font:16px system-ui;margin:0;padding:16px}' +
    'p{border:1px solid #ccc;border-radius:8px;padding:12px}</style>' +
    '</head><body><p id="out">Waiting for the result</p><script>' +
    'const out=document.getElementById("out");let ready=false;' +
    'const send=m=>parent.postMessage(Object.assign({jsonrpc:"2.0"},m),"*");' +
    'addEventListener("message",e=>{const m=e.data;' +
    'if(e.source!==parent||!m)return;' +
    'if(m.id===1&&!ready&&!m.method){' +
    'const r=m.result;if(m.jsonrpc!=="2.0"||!r||typeof r!=="object"||' +
    'typeof r.protocolVersion!=="string"){' +
    'out.textContent="The host refused this view";return;}' +
    'ready=true;send({method:"ui/notifications/initialized",params:{}});' +
    'return;}' +
    'if(m.method==="ui/resource-teardown"&&m.id!==undefined){' +
    'send({id:m.id,result:{}});return;}' +
    'if(ready&&m.method==="ui/notifications/tool-result"){' +
    'const c=(m.params.content||[])[0];out.textContent=c?c.text:"";}});' +
    'send({id:1,method:"ui/initialize",params:{appInfo:{name:"echo-card",' +
    'version:"1.0.0"},appCapabilities:{},protocolVersion:"2026-01-26"}});' +
    '</script></body></html>';

function EchoHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  MessageData: TJSONData;
begin
  MessageData := AArguments.Find('message');
  if MessageData = nil then
    Exit(MCPErrorResult('Missing required argument "message"'));
  if MessageData.JSONType <> jtString then
    Exit(MCPErrorResult('Argument "message" must be a string'));

  // In-request notifications are no-ops unless the client opted in
  // (_meta.progressToken / logLevel) — safe to call unconditionally.
  MCPReportProgress(ACtx, 0.5, 1.0, 'echoing');
  MCPLogMessage(ACtx, 'info', 'echo invoked');
  Result := MCPTextResult(MessageData.AsString);
  MCPReportProgress(ACtx, 1.0, 1.0);
end;

// Counts down, reporting progress, and stops as soon as the client
// cancels: ACtx.IsCancelled sees a notifications/cancelled on stdio or a
// closed connection on HTTP while the handler runs.
function CountdownHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Seconds, Tick: Integer;
begin
  Seconds := AArguments.Get('seconds', 3);
  // A bound on the duration: stdio serves one request at a time.
  if (Seconds < 1) or (Seconds > 60) then
    Exit(MCPErrorResult('seconds must be between 1 and 60'));
  for Tick := 1 to Seconds * 10 do
  begin
    if ACtx.IsCancelled then
      Exit(MCPTextResult('cancelled'));
    if Tick mod 10 = 0 then
      MCPReportProgress(ACtx, Tick div 10, Seconds);
    Sleep(100);
  end;
  Result := MCPTextResult('liftoff');
end;

type
  // The argument class IS the input schema: two required numbers.
  // The server validates and populates it before AddHandler runs, so
  // the handler contains arithmetic and nothing else.
  TAddArgs = class(TMCPArgs)
  private
    FA, FB: Double;
  published
    property a: Double read FA write FA;
    property b: Double read FB write FB;
  end;

  // The result class is the output schema the same way; the handler
  // returns an instance and MCPStructuredResult serializes it.
  TSumResult = class(TMCPArgs)
  private
    FSum: Double;
  published
    property sum: Double read FSum write FSum;
  end;

// Template reader: AVars carries the variables matched from the URI.
function ShoutReader(const AUri: string; AVars: TJSONObject;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  Result := MCPTextContents(AUri, 'text/plain',
    UpperCase(AVars.Get('text', '')));
end;

// Prompt handler: returns the messages a client feeds to its model.
function GreetPromptHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  Result := MCPMessages([MCPUserMessage(
    'Compose a short, friendly greeting for ' +
    AArguments.Get('name', 'the user') + '.')]);
end;

// MRTR example: the first round returns input_required with an
// elicitation form; the client gathers the name and retries the same
// call with inputResponses + the echoed requestState.
function GreetUserHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Content: TJSONObject;
begin
  Content := MCPElicitationContent(ACtx, 'who');
  if Content = nil then
    Exit(MCPInputRequired(TJSONObject.Create(['who',
      MCPElicitFormRequest('Who should be greeted?',
      ObjectSchema.AddString('name', 'Name of the person to greet'))]),
      'greet-round-1'));
  Result := MCPTextResult('Hello, ' + Content.Get('name', 'stranger') + '!');
end;

const
  // A 1x1 fully transparent PNG, inline so the demo needs no asset
  // file. Handlers hold image bytes rather than base64, so this uses
  // the TBytes overload of MCPImageResult and lets the library encode.
  ONE_PIXEL_PNG: array[0..69] of Byte = (
    $89, $50, $4E, $47, $0D, $0A, $1A, $0A, $00,
    $00, $00, $0D, $49, $48, $44, $52, $00, $00,
    $00, $01, $00, $00, $00, $01, $08, $06, $00,
    $00, $00, $1F, $15, $C4, $89, $00, $00, $00,
    $0D, $49, $44, $41, $54, $78, $DA, $63, $64,
    $60, $F8, $5F, $0F, $00, $02, $87, $01, $80,
    $EB, $47, $BA, $92, $00, $00, $00, $00, $49,
    $45, $4E, $44, $AE, $42, $60, $82);

function PixelHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Pixel: TBytes;
  I: Integer;
begin
  SetLength(Pixel, Length(ONE_PIXEL_PNG));
  for I := 0 to High(ONE_PIXEL_PNG) do
    Pixel[I] := ONE_PIXEL_PNG[I];
  Result := MCPImageResult(Pixel, 'image/png');
end;

function AddHandler(AArgs: TMCPArgs;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Args: TAddArgs;
  Res: TSumResult;
begin
  Args := AArgs as TAddArgs;
  Res := TSumResult.Create;
  Res.sum := Args.a + Args.b;
  Result := MCPStructuredResult('The sum is ' + FloatToStr(Res.sum), Res);
end;

// Banner suffix derived from the live registries, so it can never drift
// from what was actually registered. Templates have no public count, so
// the summary claims only what the server exposes.
function RegistrationSummary(AServer: TMCPServer): string;

  function Plural(ACount: Integer; const ANoun: string): string;
  begin
    Result := IntToStr(ACount) + ' ' + ANoun;
    if ACount <> 1 then
      Result := Result + 's';
  end;

begin
  Result := '(' + Plural(AServer.ToolCount, 'tool') + ', ' +
    Plural(AServer.ResourceCount, 'resource') + ', ' +
    Plural(AServer.PromptCount, 'prompt') + ')';
end;

// `--page-size <n>` serves stdio with its lists in pages of n (#94).
function PageSizeFromArgs(out ASize: Integer): Boolean;
begin
  Result := (ParamCount = 2) and (ParamStr(1) = '--page-size') and
    TryStrToInt(ParamStr(2), ASize) and (ASize > 0);
  if not Result then
    ASize := 0;
end;

var
  // `--clock-at <ms>` fixes the clock (Unix milliseconds), so mcpsmoke
  // can check replay windows without racing the minute.
  ClockAtMs: Int64 = -1;

function ClockNowMs: Int64;
var
  Utc: TDateTime;
begin
  if ClockAtMs >= 0 then
    Exit(ClockAtMs);
  // One sample: DateTimeToUnix drops its milliseconds, which are added
  // back from the same instant.
  Utc := LocalTimeToUniversal(SysUtils.Now);
  Result := DateTimeToUnix(Utc) * 1000 + MilliSecondOf(Utc);
end;

// The Events demo (#118): one occurrence per minute of UTC time, the
// cursor the minute read last (minutes since 1970). Stateless: the
// clock is the upstream. A cursor over an hour old is truncated to the
// last hour.
function ClockMinuteCheck(const AQuery: TMCPEventQuery;
  const ACtx: TMCPRequestContext): TMCPEventPoll;
var
  NowMs, Now, Minute, Last, Floor: Int64;
begin
  NowMs := ClockNowMs;
  Now := NowMs div 60000;
  if AQuery.FromNow or not TryStrToInt64(AQuery.Cursor, Minute) or
    (Minute > Now) then
    Exit(MCPEventPoll(IntToStr(Now)));
  Result := MCPEventPoll(IntToStr(Now), TJSONArray.Create);
  // Replay starts at the later of the cursor and now minus maxAgeMs,
  // and at most an hour back; skipping is "truncated" (events.mdx,
  // Cursor Lifecycle).
  // The cutoff from the actual instant: a tick at minute m (m * 60000
  // ms) is replayed when m * 60000 >= now - maxAgeMs, so the last minute
  // skipped is the one before the first such m (#118 review).
  Floor := Now - 60;
  if (AQuery.MaxAgeMs >= 0) and (AQuery.MaxAgeMs < NowMs) then
    Floor := Max(Floor, (NowMs - AQuery.MaxAgeMs + 59999) div 60000 - 1);
  if Minute < Floor then
  begin
    Minute := Floor;
    Result.Truncated := True;
  end;
  Last := Now;
  // Compared before adding, so no cursor overflows.
  if (AQuery.MaxEvents >= 0) and (Last - Minute > AQuery.MaxEvents) then
  begin
    Last := Minute + AQuery.MaxEvents;
    Result.HasMore := True;
  end;
  while Minute < Last do
  begin
    Inc(Minute);
    Result.Events.Add(MCPEventOccurrence('minute-' + IntToStr(Minute),
      // Literal colons: unquoted, FormatDateTime takes the locale's time
      // separator (#118 review).
      FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"Z"',
      UnixToDateTime(Minute * 60)),
      TJSONObject.Create(['minute', Minute])));
  end;
  Result.Cursor := IntToStr(Last);
  Result.NextPollMs := 60000;
end;

// `--skills-dir <dir>` also serves the skills under <dir> (#117), at
// skill://disk/...; mcpsmoke uses it to check skills loaded from disk.
function SkillsDirFromArgs(out ADir: string): Boolean;
begin
  Result := (ParamCount = 2) and (ParamStr(1) = '--skills-dir');
  if Result then
    ADir := ParamStr(2)
  else
    ADir := '';
end;

// `--http <port>` selects the Streamable HTTP binding; anything else
// (including no arguments) serves stdio.
function HTTPPortFromArgs(out APort: Word): Boolean;
var
  PortValue: Integer;
begin
  Result := (ParamCount = 2) and (ParamStr(1) = '--http') and
    TryStrToInt(ParamStr(2), PortValue) and (PortValue > 0) and
    (PortValue <= 65535);
  if Result then
    APort := Word(PortValue)
  else
    APort := 0;
end;

var
  SkillsDir: string;
  Server: TMCPServer;
  Transport: TMCPHTTPServer;
  HTTPPort: Word;
  PageSize: Integer;

begin
  Server := TMCPServer.Create('pascal-mcp-sdk-demo', '0.1.0');
  try
    // Display metadata clients show for the server (serverInfo).
    Server.Title := 'pascal-mcp-sdk demo';
    Server.WebsiteUrl := 'https://frostney.github.io/pascal-mcp-sdk/';
    Server.Instructions :=
      'Demo server for the pascal-mcp-sdk library. Use "echo" to mirror a ' +
      'message, "add" to add two numbers, "pixel" for a sample image; ' +
      'read mcp://pascal-mcp-sdk/greeting for a hello.';

    Server.RegisterTool('echo', 'Echo a message back to the caller',
      ObjectSchema.AddString('message', 'Text to echo back'),
      EchoHandler).AppResource('ui://pascal-mcp-sdk/echo-card', []);

    Server.RegisterTool('add', 'Add two numbers and return the sum',
      TAddArgs, TSumResult, AddHandler)
      .Title('Adder').ReadOnlyHint.IdempotentHint;

    Server.RegisterTool('greet_user',
      'Greet a person; asks who to greet via elicitation (MRTR)',
      '{"type":"object"}', GreetUserHandler)
      // Refused up front for a client without elicitation, instead of
      // after the handler ran.
      .RequiresClientCapability('elicitation');

    Server.RegisterTool('countdown',
      'Count down the given seconds; stops early when cancelled',
      ObjectSchema.AddInteger('seconds', 'Seconds to count down, 1 to 60'),
      CountdownHandler);

    Server.RegisterTool('pixel',
      'Return a 1x1 transparent PNG as image content',
      '{"type":"object"}', PixelHandler);

    Server.RegisterPrompt('greet', 'Compose a friendly greeting',
      PromptArguments.Add('name', 'Who to greet'), GreetPromptHandler);
    // Suggestions while the user types the name (completion/complete).
    Server.RegisterPromptCompletion('greet', 'name',
      ['Ada', 'Alan', 'Grace', 'Niklaus']);

    Server.RegisterTextResource('mcp://pascal-mcp-sdk/greeting', 'greeting',
      'text/plain', 'Hello from pascal-mcp-sdk, a FreePascal MCP server.',
      'A static greeting resource').Title('Greeting');

    // MCP Apps: a client that supports the extension renders echo's
    // result in this card (linked from the echo tool above); every other client gets the plain text.
    RegisterAppResource(Server, 'ui://pascal-mcp-sdk/echo-card', 'Echo card',
      ECHO_CARD_HTML, MCPAppUiMeta([], [], [], [], [], '', 1),
      'Shows the echoed message on a card');

    // Skills (#115): one skill, with an example file, that a client
    // supporting the extension lists, verifies and loads.
    RegisterSkill(Server, 'pascal-mcp-sdk/echo-usage',
      TJSONObject.Create(['name', 'echo-usage', 'description',
      'Call the echo tool and read its card', 'license', 'MIT']),
      '# Echo usage' + #10 + #10 + 'Call `echo` with a `message`; see ' +
      '[the example](examples/call.json).' + #10,
      [MCPSkillFile('examples/call.json',
      '{"name":"echo","arguments":{"message":"hi"}}' + #10)]);

    // Events (#118): a minute clock a client polls with events/poll.
    RegisterEvent(Server, 'clock.minute', 'Fires once a minute (UTC)',
      ObjectSchema, ObjectSchema.AddInteger('minute', 'Minutes since 1970'),
      ClockMinuteCheck, 60000);

    Server.RegisterResourceTemplate('mcp://pascal-mcp-sdk/shout/{text}',
      'shout', 'text/plain', ShoutReader, 'Uppercase echo of {text}');

    if PageSizeFromArgs(PageSize) then
      Server.PageSize := PageSize;
    if (ParamCount = 2) and (ParamStr(1) = '--clock-at') then
      ClockAtMs := StrToInt64Def(ParamStr(2), -1);
    if SkillsDirFromArgs(SkillsDir) then
      RegisterSkillDirectory(Server, SkillsDir, 'disk');

    if HTTPPortFromArgs(HTTPPort) then
    begin
      Transport := TMCPHTTPServer.Create(Server);
      try
        Transport.Port := HTTPPort;
        MCPLogToStderr('mcpdemo: serving MCP ' + MCP_PROTOCOL_VERSION +
          ' on http://127.0.0.1:' + IntToStr(HTTPPort) +
          Transport.EndpointPath + ' ' + RegistrationSummary(Server));
        Transport.Run;
      finally
        Transport.Free;
      end;
    end
    else
    begin
      MCPLogToStderr('mcpdemo: serving MCP ' + MCP_PROTOCOL_VERSION +
        ' on stdio ' + RegistrationSummary(Server));
      RunMCPStdioServer(Server);
    end;
  finally
    Server.Free;
  end;
end.
