# Cookbook

Complete, runnable patterns. Every snippet here is lifted from — or
directly runnable against — the demo server,
[mcpdemo.pas](../../source/apps/mcpdemo.pas): the smallest complete
pascal-mcp-sdk program, exercising every registration style. Clone the
repo and `lwpt build` (or `fpc @lwpt.cfg -FEbuild
source/apps/mcpdemo.pas` — no lwpt needed) to get `build/mcpdemo`.

## One server, both transports

The same registrations serve stdio by default and Streamable HTTP
behind a flag — the transport is chosen at the end, not woven through
the code:

```pascal
if UseHTTP then
begin
  Transport := TMCPHTTPServer.Create(Server);
  try
    Transport.Port := HTTPPort;
    MCPLogToStderr('serving on http://127.0.0.1:' +
      IntToStr(HTTPPort) + Transport.EndpointPath);
    Transport.Run;            // blocks until Transport.Stop
  finally
    Transport.Free;
  end;
end
else
begin
  MCPLogToStderr('serving on stdio');
  RunMCPStdioServer(Server);  // serves until the client closes stdin
end;
```

Try both against the demo: `./build/mcpdemo` (stdio) and
`./build/mcpdemo --http 3000`.

## A tool with progress and log notifications

`echo` reports progress and logs unconditionally — both calls no-op
unless the client opted in, so the handler needs no conditionals:

```pascal
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

  MCPReportProgress(ACtx, 0.5, 1.0, 'echoing');
  MCPLogMessage(ACtx, 'info', 'echo invoked');
  Result := MCPTextResult(MessageData.AsString);
  MCPReportProgress(ACtx, 1.0, 1.0);
end;

Server.RegisterTool('echo', 'Echo a message back to the caller',
  ObjectSchema.AddString('message', 'Text to echo back'),
  EchoHandler);
```

(The manual argument checks are belt-and-braces here — the fluent
schema already makes the server reject a missing or mistyped
`message` before the handler runs.)

## Typed input, typed output, annotations

`add` declares both schemas as classes and chains behavior hints:

```pascal
type
  TAddArgs = class(TMCPArgs)
  private
    FA, FB: Double;
  published
    property a: Double read FA write FA;
    property b: Double read FB write FB;
  end;

  TSumResult = class(TMCPArgs)
  private
    FSum: Double;
  published
    property sum: Double read FSum write FSum;
  end;

function AddHandler(AArgs: TMCPArgs;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Res: TSumResult;
begin
  Res := TSumResult.Create;
  Res.sum := (AArgs as TAddArgs).a + (AArgs as TAddArgs).b;
  Result := MCPStructuredResult('The sum is ' + FloatToStr(Res.sum), Res);
end;

Server.RegisterTool('add', 'Add two numbers and return the sum',
  TAddArgs, TSumResult, AddHandler)
  .Title('Adder').ReadOnlyHint.IdempotentHint;
```

A call answers both human-readable `content` and
`structuredContent: {"sum": 42}` matching the output schema.

## A tool that asks the user something (MRTR)

`greet_user` runs in two rounds: the first answers `input_required`
with an elicitation form; the client shows it, gathers the answer, and
retries the same call, which re-enters the same handler:

```pascal
function GreetUserHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Content: TJSONObject;
begin
  Content := MCPElicitationContent(ACtx, 'who');
  if Content = nil then                       // round 1: ask
    Exit(MCPInputRequired(TJSONObject.Create(['who',
      MCPElicitFormRequest('Who should be greeted?',
      ObjectSchema.AddString('name', 'Name of the person to greet'))]),
      'greet-round-1'));
  // round 2: the answer arrived on ACtx
  Result := MCPTextResult('Hello, ' + Content.Get('name', 'stranger') + '!');
end;

Server.RegisterTool('greet_user',
  'Greet a person; asks who to greet via elicitation (MRTR)',
  '{"type":"object"}', GreetUserHandler);
```

The raw `'{"type":"object"}'` schema means "no declared arguments" —
this tool gets its input by asking, not from the caller.

## A prompt with arguments

```pascal
function GreetPromptHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  Result := MCPMessages([MCPUserMessage(
    'Compose a short, friendly greeting for ' +
    AArguments.Get('name', 'the user') + '.')]);
end;

Server.RegisterPrompt('greet', 'Compose a friendly greeting',
  PromptArguments.Add('name', 'Who to greet'), GreetPromptHandler);
```

## A static resource and a template

```pascal
Server.RegisterTextResource('mcp://pascal-mcp-sdk/greeting', 'greeting',
  'text/plain', 'Hello from pascal-mcp-sdk, a FreePascal MCP server.',
  'A static greeting resource');

function ShoutReader(const AUri: string; AVars: TJSONObject;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  Result := MCPTextContents(AUri, 'text/plain',
    UpperCase(AVars.Get('text', '')));
end;

Server.RegisterResourceTemplate('mcp://pascal-mcp-sdk/shout/{text}',
  'shout', 'text/plain', ShoutReader, 'Uppercase echo of {text}');
```

Reading `mcp://pascal-mcp-sdk/shout/hello` answers `HELLO` — the
`{text}` variable arrives in `AVars`.

## Driving it all by hand

Every request needs `_meta`; the heredoc closes stdin, which is the
graceful shutdown:

```sh
./build/mcpdemo <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"add","arguments":{"a":19,"b":23},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"mcp://pascal-mcp-sdk/shout/hello","_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
EOF
```

Over HTTP, the same bodies POST to the endpoint:

```sh
./build/mcpdemo --http 3000 &
curl -s http://127.0.0.1:3000/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}'
```

## Where to go deeper

The demo server is ~200 lines including comments —
[read it whole](../../source/apps/mcpdemo.pas). The E2E battery
[mcpsmoke.pas](../../source/apps/mcpsmoke.pas) drives every one of
these registrations the way a real client does, error paths included,
and doubles as a protocol-level reference in Pascal.
