# Testing Your Server

## Executive Summary

The test client in `MCP.Testing`, `TMCPTestClient`, drives your
`TMCPServer` in-process the way a client would: no transport, no child
process, no JSON-RPC written by hand. It adds the per-request `_meta`
envelope every request needs, returns each parsed response, records
the progress and log notifications a call emits, and can answer
input-required rounds from canned responses. Use it from `lwpt test`
suites next to your units.

It is a harness for testing your own server, not a client for other
MCP servers: it calls the server's core directly.

## A first test

Register your tools on a server, wrap it, and assert on the response.
This program is the library's own
[`MCP.Testing.Guide.Test.pas`](https://github.com/frostney/pascal-mcp-sdk/blob/main/source/units/MCP.Testing.Guide.Test.pas)
(with the library's shared `{$I MCP.inc}` in place of the mode line),
so `lwpt test` compiles and runs it:

```pascal
program MyServer.Test;

{$mode delphi}{$H+}

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
```

Every helper returns the whole JSON-RPC response, which you free: a
`result` on success, an `error` for a protocol error such as an
unknown tool. Malformed JSON you pass in raises `EMCPTesting`.

## The helpers

| Method | Sends |
| --- | --- |
| `Discover` | `server/discover` |
| `ListTools`, `ListResources`, `ListPrompts` | the list methods |
| `CallTool(Name, ArgumentsJson)` | `tools/call` |
| `ReadResource(Uri)` | `resources/read` |
| `GetPrompt(Name, ArgumentsJson)` | `prompts/get` |
| `Complete(RefJson, Argument, Value)` | `completion/complete` |
| `Request(Method, ParamsJson)` | anything else; `_meta` is added to your params |

## Client capabilities and identity

By default each request declares no client capabilities. Declare the
ones a test needs, and set the client name a handler sees in
`ACtx.ClientName`:

```pascal
FClient.SetClientCapabilities('{"elicitation":{},"sampling":{}}');
FClient.ClientName := 'my-suite';
```

## Notifications

`Notifications` holds the lines the last call emitted, in order,
across every input round it answered. Set `ProgressToken` or `LogLevel`
to opt every request into progress or log messages:

```pascal
FClient.ProgressToken := 't1';
FClient.LogLevel := 'info';
Response := FClient.CallTool('import');
Response.Free;
Expect<Integer>(FClient.Notifications.Count).ToBe(3);
```

`LastResponseLine` is the raw response line of the last round, for
asserting bytes on the wire.

## Input-required rounds

A tool that asks for input returns `input_required`. Give the client
canned answers, keyed like the tool's input requests, and `CallTool`
or `GetPrompt` answers each round and retries with the echoed
`requestState` until the result is complete, at most ten times:

```pascal
FClient.SetClientCapabilities('{"elicitation":{}}');
FClient.AnswerInput('who', '{"action":"accept","content":{"name":"Ada"}}');
Response := FClient.CallTool('greet_user');   // "Hello, Ada!"
```

Without an answer for a requested key, or after ten rounds, the latest
`input_required` response comes back as it is, so you can assert on
what the tool asked for. The full API is in the
[test client reference](../reference/testing.md).

## What it does not cover

The client calls the core, so it tests your handlers, schemas and
results, not a transport. The library's own `mcpsmoke` battery and the
transport test suites cover stdio and HTTP framing.
