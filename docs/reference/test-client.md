# Test Client

From `MCP.Testing` (#97). `TMCPTestClient` drives a `TMCPServer`
in-process through `HandleMessage`, for testing your own server; the
[testing guide](../guides/testing.md) shows a whole suite.

```pascal
constructor Create(AServer: TMCPServer);   // borrowed; outlives the client
procedure SetClientCapabilities(const AJson: string);
property ClientName: string;               // 'mcp-test-client'
property ClientVersion: string;            // '1.0.0'
property ProgressToken: string;            // '' = no progress opt-in
property LogLevel: string;                 // '' = no log opt-in
procedure AnswerInput(const AKey, AResponseJson: string);
procedure ClearInputAnswers;

function Request(const AMethod: string;
  const AParamsJson: string = '{}'): TJSONObject;
function Discover: TJSONObject;
function ListTools: TJSONObject;
function CallTool(const AName: string;
  const AArgumentsJson: string = '{}'): TJSONObject;
function ListResources: TJSONObject;
function ReadResource(const AUri: string): TJSONObject;
function ListPrompts: TJSONObject;
function GetPrompt(const AName: string;
  const AArgumentsJson: string = '{}'): TJSONObject;
function Complete(const ARefJson, AArgument, AValue: string): TJSONObject;
function AwaitTask(const ATaskId: string;
  ATimeoutMs: Integer = 10000): TJSONObject;

property Notifications: TStringList;       // owned by the client
property LastResponseLine: string;
property Session: TMCPSession;             // owned by the client
```

| Member | Meaning |
| --- | --- |
| `Create` | Opens a session on `AServer` (which freezes its configuration). The server is borrowed and must outlive the client |
| `SetClientCapabilities` | The `clientCapabilities` every request declares, as a JSON object; `{}` by default. Raises `EMCPTesting` for anything else |
| `ClientName`, `ClientVersion` | The `clientInfo` every request carries, as handlers see it in `ACtx.ClientName` and `ACtx.ClientVersion` |
| `ProgressToken`, `LogLevel` | When not `''`, every request opts into progress (with this token) and log messages (at and above this level), so `Notifications` records what `MCPReportProgress` and `MCPLogMessage` send |
| `AnswerInput` | A canned response for the input request `AKey` of an `input_required` round, as the response JSON a client would send; replaces an earlier one for the key |
| `ClearInputAnswers` | Forgets every canned response |
| `Request` | One request with the `_meta` envelope added to `AParamsJson` (an object); a key of yours in `_meta` wins over the envelope's |
| `CallTool`, `GetPrompt` | Answer `input_required` rounds from the canned responses and retry with the echoed `requestState`, while every requested key has an answer, at most ten times; then, or without an answer, they return the latest response. A round that asks for nothing is retried with its `requestState` alone |
| `Discover`, the list methods, `ReadResource`, `Complete` | One request each |
| `AwaitTask` | Polls `tasks/get` for a task (declare the Tasks extension with `SetClientCapabilities` first) until it is completed, failed or cancelled, and returns that response. While the task waits for input, it answers the requests it has canned answers for with `tasks/update`, keys matched exactly, so a key the server suffixed (`confirm#2`) needs an answer of its own. It returns an `input_required` response as it is when a requested key has no answer, and an error response as it is; past `ATimeoutMs` it raises `EMCPTesting` |
| `Notifications` | The notification lines the last call emitted, in order, across every round it answered; cleared when a call starts, before it checks its arguments |
| `LastResponseLine` | The raw response line of the last round, for byte-exact assertions; `''` when that round got no response, such as a cancelled one |
| `Session` | The client's session, for a hand-written `HandleMessage` line |

Every call returns the whole parsed JSON-RPC response, a `result` or an
`error`, as a new object you free. JSON you pass in is parsed as the
server parses a client's line (`MCPParseJSON` from `MCP.JSONRPC`),
escapes included. Malformed JSON, or a request the server does not
answer, raises `EMCPTesting`.
