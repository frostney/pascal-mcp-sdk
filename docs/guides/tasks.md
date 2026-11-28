# Tasks

## Executive Summary

Tasks is the official extension for tool calls that take too long to
answer while the client waits, such as a build, a batch job or a step
that needs a person's approval (`io.modelcontextprotocol/tasks`,
defined by
[SEP-2663](https://github.com/modelcontextprotocol/ext-tasks/blob/cc9aaac/specification/2026-07-28/tasks.md)).
Instead of the result, the server answers a `tools/call` with a task
handle at once and runs the tool on its own. The client then polls
`tasks/get` until the task is done, answers the task's questions with
`tasks/update`, and may stop it with `tasks/cancel`.

`MCP.Tasks` runs a task with the tool's ordinary handler, on a thread
of its own. You choose which tools may run as tasks; the client opts in
on each request. A handler that asks for input with `MCPInputRequired`
works unchanged: as a task, its questions wait in the task until the
client answers them.

## Turn tasks on

```pascal
program builds;

uses
  {$IFDEF UNIX}
  cthreads, // first: task handlers run on threads
  {$ENDIF}
  fpjson, MCP.Protocol, MCP.Server, MCP.Tasks, MCP.Transport.Stdio;

function RunBuild(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Build: TBuild;
begin
  Build := StartBuild(AArguments.Get('target', 'all'));
  try
    while not Build.Done do
    begin
      // tasks/cancel, the task's ttlMs ending, or the server stopping.
      if ACtx.IsCancelled then
      begin
        Build.Abort;
        Exit(MCPErrorResult('Build cancelled'));
      end;
      Sleep(200);
    end;
    Result := MCPTextResult(Build.Summary);
  finally
    Build.Free;
  end;
end;

var
  Server: TMCPServer;
  Tasks: TMCPTasks;
begin
  Server := TMCPServer.Create('builds', '1.0.0');
  Server.RegisterTool('build', 'Builds a target',
    '{"type":"object","properties":{"target":{"type":"string"}}}', RunBuild);
  Tasks := EnableTasks(Server);
  Tasks.SetToolSupport('build', tsOptional);
  RunMCPStdioServer(Server);
  Server.Free;
end.
```

`EnableTasks` declares the extension with `{}` on `server/discover` and
serves `tasks/get`, `tasks/update` and `tasks/cancel`. Calling it again
returns the same settings object, which the server owns. Call it, and
change its settings, before the server starts. Task handlers run on
threads, so on Unix the program lists `cthreads` first in its uses
clause; without it `EnableTasks` raises `EMCPServer` rather than let
the first task stop the program with runtime error 232.

## Which calls become tasks

The server decides, call by call; the client never asks for a task.
`SetToolSupport(Name, Support)` sets it per tool, for a tool that is
already registered:

| Support | The request declares the extension | It does not |
| --- | --- | --- |
| `tsNone` (the default) | the call runs as usual | the call runs as usual |
| `tsOptional` | a task | the call runs as usual |
| `tsRequired` | a task | `-32021`, with `data.requiredCapabilities.extensions` naming the extension |

A request declares the extension in its own
`_meta["io.modelcontextprotocol/clientCapabilities"].extensions`, so a
client can opt in for one call. A server never answers a task to a
request that did not declare it.

`SetSelector` decides instead, for every call, from the tool's name,
its arguments and the request's context. A selector is how a tool
gathers input first and becomes a task after, as the extension
recommends: answer `tsNone` while `ACtx.InputResponses` is nil, so the
first round runs as an ordinary input round, and `tsRequired` for the
retry, which then runs as a task with the answers and `requestState`
the retry brought:

```pascal
function Mode(const AToolName: string; AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPTaskSupport;
begin
  if (AToolName = 'deploy') and (ACtx.InputResponses <> nil) then
    Result := tsRequired
  else
    Result := tsNone;
end;

Tasks.SetSelector(Mode);
```

At most `MaxActive` tasks (32 by default) are running or waiting for
input at once, a cancelled or expired one counting until its handler
returns, and at most `MaxKept` (1000 by default) are kept until their
`ttlMs` ends. Past either, a call whose tool allows it runs as usual, and one
that runs only as a task answers `-32603`.

The extension is defined for the 2026-07-28 revision. The classic
`initialize` does not declare it, a classic client's `tasks/*` request
gets `-32601`, a `tsOptional` tool runs as usual for it, and a
`tsRequired` one answers a tool error saying tasks are not available to
it.

## What the client sees

The `tools/call` answer is a `CreateTaskResult`: `resultType` `"task"`,
and at the top level the task's `taskId`, `status`, `createdAt`,
`lastUpdatedAt`, `ttlMs` and `pollIntervalMs`. The task can be read
before this answer goes out. Its id is 128 random bits, base64url
encoded, since it is the only thing that gives access to the task.

A `tools/call` the client cancels while its task is being created
never sends the task's id, so that task starts cancelled.

`tasks/get` answers the task as it is now, with `resultType`
`"complete"` and, by status:

| Status | What else it carries |
| --- | --- |
| `working` | nothing |
| `input_required` | `inputRequests`: the questions still open |
| `completed` | `result`: the `CallToolResult` the call would have answered, a tool error (`isError: true`) included |
| `failed` | `error`: the JSON-RPC error the handler raised as `EMCPProtocolError`, or `-32603` for a fault, such as a result the wire cannot carry, and that error's message as `statusMessage`. Faults follow `RedactErrorDetails` |
| `cancelled` | `statusMessage` `"The client cancelled the task"` |

A handler's other exceptions become an `isError` result, as in a call,
so the task completes. `tasks/update` and `tasks/cancel` answer an
empty result. A `taskId` that is not a string answers `-32602`, and so
does one that names no task, because it never existed or it expired.
A request that does not declare the extension gets `-32021` from all
three methods. `tasks/list` and `tasks/result`, from the earlier Tasks
of the 2025-11-25 revision, are not methods here (`-32601`).

On Streamable HTTP, `tasks/get`, `tasks/update` and `tasks/cancel`
carry the `Mcp-Name` header with the task id, so a load balancer can
send them to the instance that holds the task; a missing or different
one answers `-32020`.

## Input during a task

When a task's handler returns `MCPInputRequired(Requests, State)`, the
task goes to `input_required` with those requests. The client answers
them with `tasks/update`, one at a time or together; keys it was not
asked, or already answered, are ignored, and an answer that is not an
object is refused with `-32602` and taken for none. Once every request
has an answer, the task is `working` again and the handler runs again,
with the answers in `ACtx.InputResponses` and its `State` in
`ACtx.RequestState`, as for a retried call. A round that asks for
nothing runs again at once with its state. The state stays on the
server, so it is not sealed.

A key stays unique over the task's lifetime: when a later round asks
under a key an earlier round already used, the client sees it with a
suffix (`confirm#2`), and the handler still reads its answer under
`confirm`.

The questions follow the same rule as a call's input round: each goes
only to a request that declared its kind, such as `elicitation`. A
`tasks/get` that did not declare what a question needs gets `-32021`,
and the task waits on for a poll that did. A question that is no input
request, or lacks what its kind needs (an elicitation's message and
schema or url, a sampling request's messages and `maxTokens`), fails the
task with `-32603`. A waiting task looks for its answers every 25 ms.

## Cancellation and lifetime

`tasks/cancel` cancels at once: the task's status is `cancelled` from
the next `tasks/get`, and the handler's `ACtx.IsCancelled` turns true,
so it can stop. A result it still returns is dropped. A finished task
stays as it is, and the answer is the same.

A task can be read for `TtlMs` after it was created (one hour by
default), and never goes before that. Once it has passed, the task is
gone at the next request, and the handler's `IsCancelled` is true from
that moment, whether a request comes or not. `PollIntervalMs` (one
second by default) is the poll interval suggested to clients.

A finished task keeps its result, not its thread: the thread is freed
at the next request to the task store.

Tasks live in the server's memory: they end with the process. Freeing
the server cancels every task and waits until its handler returns,
before it frees anything else, so a handler can still use what the
server owns, such as an object it adopted. A handler that never asks
`IsCancelled` holds up shutdown until it ends. On stdio, `RunMCPStdioServer` returns at the end of input once
the queued requests are served, and freeing the server then ends the
tasks still running.

## Status notifications

A client that would rather not poll opens `subscriptions/listen` with
the tasks it wants to follow:

```json
{"jsonrpc": "2.0", "id": 9, "method": "subscriptions/listen", "params": {
  "notifications": {"taskIds": ["Zm9vYmFyYmF6cXV4cXV1"]},
  "_meta": {
    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities": {
      "elicitation": {},
      "extensions": {"io.modelcontextprotocol/tasks": {}}}}}}
```

The stream acknowledges the tasks it found first
(`notifications/subscriptions/acknowledged`, with only those of the
listed ids it knows), then sends `notifications/tasks` with each task's
whole state, as `tasks/get` would answer it: once at the start, and
again after each change, a partly answered input round included. Each
change is sent, in order, even when several come between two of the
stream's polls (every 100 ms); a reader that falls 64 states behind
loses the oldest. Every frame carries the request's id as
`_meta["io.modelcontextprotocol/subscriptionId"]`. A state waiting on a
question the listen request did not declare what it needs for, as
`tasks/get` would refuse it, is left out: declare `elicitation` in the
example to see those. A task that expires sends nothing more. A request
that lists `taskIds` without declaring the extension gets `-32021`. See
[Server API](../reference/server.md#subscriptions) for the limits and
how the stream ends.

## Threads

Each task's handler runs on a thread of its own, beside the requests
the transport is serving, on stdio too. A handler that can run as a
task must be safe to run at the same time as the other handlers.

The handler gets the creating request's context, `_meta` and declared
client capabilities included, without what ends with that request:
progress and log notifications are not delivered for tasks, so
`MCPReportProgress` and `MCPLogMessage` send nothing, and
`ACtx.RequestId` and the stream host are nil.

## Testing

`TMCPTestClient.AwaitTask(TaskId)` polls `tasks/get` until the task
ends, and answers its questions from the answers `AnswerInput` set, a
suffixed key (`confirm#2`) only with an answer of its own. See
[Testing](testing.md#tasks).

## Not served

- **The Tasks of the 2025-11-25 revision** (a `task` parameter on the
  request, `tasks/list`, `tasks/result`) are not served: the extension
  replaces them. A `task` parameter on `tools/call` is ignored.
- **Tasks that outlive the process** need a store outside it, which
  `MCP.Tasks` does not have.

## Who can reach a task

The extension asks a server to check, on every task request, that the
caller may reach that task. The library has no authentication of its
own (see [Deployment](deployment.md#tls-auth-and-the-proxy-in-front)),
and a request carries no caller identity it could bind a task to, so a
task's id is its only key, as the extension allows: whoever holds the
id can read the task, answer its questions and cancel it. That fits a
server with one caller, such as a stdio server its client starts, or
one Streamable HTTP server per user. Do not enable Tasks on a server
several callers share, even behind an authenticating proxy: the proxy
knows who calls, but not whose task an id names.

## Related pages

- [Server API reference](../reference/server.md#tasks), for
  `EnableTasks`, `TMCPTasks`, the selector types and the tool-call
  hook.
- [Tools](tools.md), for input rounds (`MCPInputRequired`) and
  `IsCancelled`.
- [Events](events.md) and [Skills](skills.md), the other extensions.
