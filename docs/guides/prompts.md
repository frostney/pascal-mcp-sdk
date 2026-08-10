# Prompts

## Executive Summary

A prompt is a reusable message template your server offers to the
*user* of an MCP client (tools are model-invoked; prompts are
user-invoked — a slash command, a menu entry). The client lists your
prompts, the user picks one and fills its declared arguments, and your
handler returns the messages the client feeds to its model. Register
prompts with `RegisterPrompt`; build messages with `MCPMessages` and
the message helpers.

## Registering a prompt

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

`PromptArguments` declares the arguments fluently — each `Add` takes a
name, an optional description, and an optional `ARequired` flag
(`True` by default):

```pascal
PromptArguments
  .Add('name', 'Who to greet')
  .Add('tone', 'Formal or casual', False)
```

Clients render these as input fields before invoking the prompt. The
no-arguments overloads exist too — `RegisterPrompt(Name, Description,
Handler)` — for prompts that take nothing.

The handler receives the filled arguments as a `TJSONObject` (prompt
arguments are string-valued, per spec) and returns a `TJSONArray` of
messages. Build them with the helpers:

- `MCPUserMessage('...')` — a `user`-role text message.
- `MCPAssistantMessage('...')` — an `assistant`-role text message.
- `MCPPromptMessage(Role, Text)` — any role explicitly.
- `MCPMessages([...])` — collects messages into the result array.

As with tools, both plain-function and `of object` method handlers
are supported, and registration must happen before serving starts.

## Error behaviour

Prompts have no in-band `isError` channel — that is a tools concept.
Errors on `prompts/get` are protocol errors: an unknown prompt name
answers the spec error code for the era, a **missing required
argument is rejected with `-32602`** before your handler runs (the
server checks the declared arguments), and a handler exception
becomes a JSON-RPC internal error (its message subject to
[error redaction](configuration.md#redacterrordetails)).

## Prompts that need more input (MRTR)

A prompt handler can pause for more input mid-call, exactly like a
tool: register the **result-handler** variant, whose handler returns
`TMCPPromptResult` instead of a bare message array, and answer
`MCPPromptInputRequired(...)` on the first round:

```pascal
function PickTargetPrompt(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPPromptResult;
var
  Content: TJSONObject;
begin
  Content := MCPElicitationContent(ACtx, 'target');
  if Content = nil then
    Exit(MCPPromptInputRequired(TJSONObject.Create(['target',
      MCPElicitFormRequest('Which environment?',
      ObjectSchema.AddString('env', 'Environment name'))])));
  Result := MCPPromptMessagesResult(MCPMessages([MCPUserMessage(
    'Describe the ' + Content.Get('env', '?') + ' environment.')]));
end;
```

The client fulfils the requests and retries `prompts/get`; your
handler re-enters with the responses on `ACtx`. The entry builders and
accessors are shared with tools — see
[Client requests](../reference/client-requests.md).

> Prompt behaviour (`prompts/list`, `prompts/get`, spec error codes,
> MRTR on `prompts/get`) implements spec revision 2026-07-28 — see
> [Spec grounding](../internals/architecture.md#spec-grounding).
