{ MCP.Testing.Guide.Test — the example of docs/guides/testing.md
  ("A first test"), compiled and run by lwpt test so the guide cannot
  drift from code that works (#97 review). MCP.Testing.Test checks that
  the guide still shows this program, under its own name and mode
  line. }

program MCP.Testing.Guide.Test;

{$I MCP.inc}

uses
  SysUtils,

  fpjson,
  MCP.Protocol,
  MCP.Schema,
  MCP.Server,
  MCP.Testing,
  TestingPascalLibrary;

function AddHandler(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPTextResult(IntToStr(AArguments.Get('a', 0) +
    AArguments.Get('b', 0)));
end;

// In your project this lives with your tools.
procedure RegisterMyTools(AServer: TMCPServer);
begin
  AServer.RegisterTool('add', 'Add two integers',
    ObjectSchema.AddInteger('a').AddInteger('b'), AddHandler);
end;

type
  TMyToolsSuite = class(TTestSuite)
  private
    FServer: TMCPServer;
    FClient: TMCPTestClient;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;
    procedure TestAdd;
  end;

procedure TMyToolsSuite.BeforeEach;
begin
  FServer := TMCPServer.Create('my-server', '1.0.0');
  RegisterMyTools(FServer);
  FClient := TMCPTestClient.Create(FServer);
end;

procedure TMyToolsSuite.AfterEach;
begin
  FreeAndNil(FClient);
  FreeAndNil(FServer);
end;

procedure TMyToolsSuite.TestAdd;
var
  Response: TJSONObject;
begin
  Response := FClient.CallTool('add', '{"a":2,"b":3}');
  try
    Expect<string>(Response.FindPath('result.content[0].text').AsString)
      .ToBe('5');
  finally
    Response.Free;
  end;
end;

procedure TMyToolsSuite.SetupTests;
begin
  Test('add sums its arguments', TestAdd);
end;

begin
  TestRunnerProgram.AddSuite(TMyToolsSuite.Create('Guide: my tools'));
  TestRunnerProgram.Run;
end.
