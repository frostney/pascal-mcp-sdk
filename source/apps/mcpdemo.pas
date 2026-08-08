program mcpdemo;

// Example MCP server: the smallest complete pascal-mcp-sdk program.
// Exposes two tools showing both registration styles — echo via the
// fluent schema builder, add via a typed argument class (the class
// expands into the schema, and the handler receives a populated,
// validated instance) — plus one static resource. By default it
// serves newline-delimited JSON-RPC on stdin/stdout until the client
// closes stdin; with `--http <port>` the same registrations are
// served over Streamable HTTP on 127.0.0.1 instead (modern era only).
//
// Try it by hand (all on one line; _meta is required on every request):
//   ./build/mcpdemo <<'EOF'
//   {"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
//   EOF

{$I Shared.inc}

uses
  // Thread driver for the HTTP listener; must be first (Unix).
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils,

  fpjson,

  MCP.Protocol,
  MCP.Schema,
  MCP.Server,
  MCP.Transport.HTTP,
  MCP.Transport.Stdio;

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
  Server: TMCPServer;
  Transport: TMCPHTTPServer;
  HTTPPort: Word;

begin
  Server := TMCPServer.Create('pascal-mcp-sdk-demo', '0.1.0');
  try
    Server.Instructions :=
      'Demo server for the pascal-mcp-sdk library. Use "echo" to mirror a ' +
      'message, "add" to add two numbers; read mcp://pascal-mcp-sdk/greeting ' +
      'for a hello.';

    Server.RegisterTool('echo', 'Echo a message back to the caller',
      ObjectSchema.AddString('message', 'Text to echo back'),
      EchoHandler);

    Server.RegisterTool('add', 'Add two numbers and return the sum',
      TAddArgs, TSumResult, AddHandler)
      .Title('Adder').ReadOnlyHint.IdempotentHint;

    Server.RegisterTool('greet_user',
      'Greet a person; asks who to greet via elicitation (MRTR)',
      '{"type":"object"}', GreetUserHandler);

    Server.RegisterPrompt('greet', 'Compose a friendly greeting',
      PromptArguments.Add('name', 'Who to greet'), GreetPromptHandler);

    Server.RegisterTextResource('mcp://pascal-mcp-sdk/greeting', 'greeting',
      'text/plain', 'Hello from pascal-mcp-sdk, a FreePascal MCP server.',
      'A static greeting resource');

    Server.RegisterResourceTemplate('mcp://pascal-mcp-sdk/shout/{text}',
      'shout', 'text/plain', ShoutReader, 'Uppercase echo of {text}');

    if HTTPPortFromArgs(HTTPPort) then
    begin
      Transport := TMCPHTTPServer.Create(Server);
      try
        Transport.Port := HTTPPort;
        MCPLogToStderr('mcpdemo: serving MCP ' + MCP_PROTOCOL_VERSION +
          ' on http://127.0.0.1:' + IntToStr(HTTPPort) +
          Transport.EndpointPath +
          ' (2 tools, 1 resource, 1 template, 1 prompt)');
        Transport.Run;
      finally
        Transport.Free;
      end;
    end
    else
    begin
      MCPLogToStderr('mcpdemo: serving MCP ' + MCP_PROTOCOL_VERSION +
        ' on stdio (2 tools, 1 resource, 1 template, 1 prompt)');
      RunMCPStdioServer(Server);
    end;
  finally
    Server.Free;
  end;
end.
