program mcpdemo;

// Example stdio MCP server: the smallest complete pascal-mcp program.
// Exposes two tools (echo, add — one via the simple registration form,
// one via a full definition with an outputSchema) and one static
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
  MCP.Server,
  MCP.Transport.Stdio;

function EchoHandler(AArguments: TJSONObject;
  const ACtx: TMcpRequestContext): TMcpToolResult;
begin
  Result := McpTextResult(AArguments.Get('message', ''));
end;

function AddHandler(AArguments: TJSONObject;
  const ACtx: TMcpRequestContext): TMcpToolResult;
var
  Sum: Double;
  Structured: TJSONObject;
begin
  if (AArguments.Find('a') = nil) or (AArguments.Find('b') = nil) then
    // Input problems are execution errors (isError: true): in-band
    // text a model can read and act on, not a protocol error.
    Exit(McpErrorResult('Both "a" and "b" are required numbers'));
  Sum := AArguments.Get('a', 0.0) + AArguments.Get('b', 0.0);
  Structured := TJSONObject.Create;
  Structured.Add('sum', Sum);
  Result := McpStructuredResult('The sum is ' + FloatToStr(Sum), Structured);
end;

function AddToolDefinition: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('name', 'add');
  Result.Add('title', 'Adder');
  Result.Add('description', 'Add two numbers and return the sum');
  Result.Add('inputSchema', GetJSON(
    '{"type":"object","properties":{' +
    '"a":{"type":"number"},"b":{"type":"number"}},' +
    '"required":["a","b"]}'));
  Result.Add('outputSchema', GetJSON(
    '{"type":"object","properties":{"sum":{"type":"number"}},' +
    '"required":["sum"]}'));
end;

var
  Server: TMcpServer;

begin
  Server := TMcpServer.Create('pascal-mcp-demo', '0.1.0');
  try
    Server.Instructions :=
      'Demo server for the pascal-mcp library. Use "echo" to mirror a ' +
      'message, "add" to add two numbers; read mcp://pascal-mcp/greeting ' +
      'for a hello.';

    Server.RegisterTool('echo', 'Echo a message back to the caller',
      '{"type":"object","properties":{"message":{"type":"string"}},' +
      '"required":["message"]}',
      EchoHandler);

    Server.RegisterTool(AddToolDefinition, AddHandler);

    Server.RegisterTextResource('mcp://pascal-mcp/greeting', 'greeting',
      'text/plain', 'Hello from pascal-mcp, a FreePascal MCP server.',
      'A static greeting resource');

    McpLogToStderr('mcpdemo: serving MCP ' + MCP_PROTOCOL_VERSION +
      ' on stdio (2 tools, 1 resource)');
    RunMcpStdioServer(Server);
  finally
    Server.Free;
  end;
end.
