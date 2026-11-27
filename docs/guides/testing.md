# Testing Your Server

## Executive Summary

`MCP.Testing` gives you `TMCPTestClient`, which drives your
`TMCPServer` in-process the way a client would: no transport, no child
process, no JSON-RPC written by hand. It adds the per-request `_meta`
envelope every request needs, returns each parsed response, records
the progress and log notifications a call emits, and can answer
input-required rounds from canned responses. Use it from `lwpt test`
suites next to your units.

It is a harness for testing your own server, not a client for other
MCP servers: it calls the server's core directly.

## A first test

Register your tools on a server, wrap it, and assert on the response:

```pascal
program MyServer.Test;

{$mode delphi}

uses
  SysUtils, fpjson,
  MCP.Protocol, MCP.Server, MCP.Testing,
  TestingPascalLibrary,
  MyTools;   // your RegisterMyTools(Server)

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
  TestRunnerProgram.AddSuite(TMyToolsSuite.Create('My tools'));
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

`Notifications` holds the lines the last request emitted, in order. A
request opts into progress with a token in its `_meta`:

```pascal
Response := FClient.Request('tools/call',
  '{"name":"import","_meta":{"progressToken":"t1"}}');
Response.Free;
Expect<Integer>(FClient.Notifications.Count).ToBe(3);
```

## Input-required rounds

A tool that asks for input returns `input_required`. Give the client
canned answers, keyed like the tool's input requests, and `CallTool`
or `GetPrompt` answers each round and retries with the echoed
`requestState` until the result is complete:

```pascal
FClient.SetClientCapabilities('{"elicitation":{}}');
FClient.AnswerInput('who', '{"action":"accept","content":{"name":"Ada"}}');
Response := FClient.CallTool('greet_user');   // "Hello, Ada!"
```

Without an answer for a requested key, the `input_required` response
comes back as it is, so you can assert on what the tool asked for.

## What it does not cover

The client calls the core, so it tests your handlers, schemas and
results, not a transport. The library's own `mcpsmoke` battery and the
transport test suites cover stdio and HTTP framing.
