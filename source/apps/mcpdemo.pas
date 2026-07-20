program mcpdemo;

// Example stdio MCP server: the smallest complete pascal-mcp-sdk program.
// Exposes two tools (echo, add — registered through the fluent
// MCP.Schema builder, add with an output schema) and one static
// resource, then serves newline-delimited JSON-RPC on stdin/stdout
// until the client closes stdin.
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
  Result := MCPTextResult(AArguments.Get('message', ''));
end;

function AddHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Sum: Double;
  Structured: TJSONObject;
begin
  if (AArguments.Find('a') = nil) or (AArguments.Find('b') = nil) then
    // Input problems are execution errors (isError: true): in-band
    // text a model can read and act on, not a protocol error.
    Exit(MCPErrorResult('Both "a" and "b" are required numbers'));
  Sum := AArguments.Get('a', 0.0) + AArguments.Get('b', 0.0);
  Structured := TJSONObject.Create;
  Structured.Add('sum', Sum);
  Result := MCPStructuredResult('The sum is ' + FloatToStr(Sum), Structured);
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
      ObjectSchema.AddNumber('a', 'First addend')
                  .AddNumber('b', 'Second addend'),
      ObjectSchema.AddNumber('sum', 'The sum of a and b'),
      AddHandler);

    Server.RegisterTextResource('mcp://pascal-mcp-sdk/greeting', 'greeting',
      'text/plain', 'Hello from pascal-mcp-sdk, a FreePascal MCP server.',
      'A static greeting resource');

    MCPLogToStderr('mcpdemo: serving MCP ' + MCP_PROTOCOL_VERSION +
      ' on stdio (2 tools, 1 resource)');
    RunMCPStdioServer(Server);
  finally
    Server.Free;
  end;
end.
