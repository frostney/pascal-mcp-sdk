program mcpdemo;

// Example stdio MCP server: the smallest complete pascal-mcp-sdk program.
// Exposes two tools showing both registration styles — echo via the
// fluent schema builder, add via a typed argument class (the class
// expands into the schema, and the handler receives a populated,
// validated instance) — plus one static resource, then serves
// newline-delimited JSON-RPC on stdin/stdout until the client closes
// stdin.
//
// Try it by hand (all on one line; _meta is required on every request):
//   ./build/mcpdemo <<'EOF'
//   {"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
//   EOF

{$I Shared.inc}

uses
  SysUtils,

  fpjson,

  MCP.Protocol,
  MCP.Schema,
  MCP.Server,
  MCP.Transport.Stdio;

function EchoHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  // In-request notifications are no-ops unless the client opted in
  // (_meta.progressToken / logLevel) — safe to call unconditionally.
  MCPReportProgress(ACtx, 0.5, 1.0, 'echoing');
  MCPLogMessage(ACtx, 'info', 'echo invoked');
  Result := MCPTextResult(AArguments.Get('message', ''));
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

var
  Server: TMCPServer;

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
      TAddArgs, TSumResult, AddHandler);

    Server.RegisterPrompt('greet', 'Compose a friendly greeting',
      PromptArguments.Add('name', 'Who to greet'), GreetPromptHandler);

    Server.RegisterTextResource('mcp://pascal-mcp-sdk/greeting', 'greeting',
      'text/plain', 'Hello from pascal-mcp-sdk, a FreePascal MCP server.',
      'A static greeting resource');

    Server.RegisterResourceTemplate('mcp://pascal-mcp-sdk/shout/{text}',
      'shout', 'text/plain', ShoutReader, 'Uppercase echo of {text}');

    MCPLogToStderr('mcpdemo: serving MCP ' + MCP_PROTOCOL_VERSION +
      ' on stdio (2 tools, 1 resource, 1 template, 1 prompt)');
    RunMCPStdioServer(Server);
  finally
    Server.Free;
  end;
end.
