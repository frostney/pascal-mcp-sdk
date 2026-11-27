program mcpconformance;

// Conformance fixture: the surface the official MCP conformance suite
// (modelcontextprotocol/conformance) tests a server through, registered
// with the library's public API only. The suite looks tools, prompts
// and resources up by the names its reference fixture uses
// (examples/servers/typescript/everything-server.ts in that repository),
// so this program registers the same names with the same behaviour.
// Tools named fixture_* are this fixture's own, for content types the
// suite does not exercise (mcpsmoke drives them over stdio).
// tools/conformance/run.mjs starts it with `--http <port>` and compares
// each scenario with tools/conformance/baseline.json; any scenario that
// still fails here is a gap in the library, listed there with its issue.
//
// It is a test fixture, not an example: mcpdemo is the example program.
// Nothing here works around a library gap; a handler that cannot do what
// a scenario asks fails that scenario honestly.

{$I MCP.inc}

uses
  // Thread driver for the HTTP listener; must be first (Unix).
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  StrUtils,
  SysUtils,

  fpjson,
  jsonparser,

  MCP.Content,
  MCP.Protocol,
  MCP.Server,
  MCP.Transport.HTTP,
  MCP.Transport.Stdio;

const
  // A 1x1 PNG, as the reference fixture uses, and a complete one-frame
  // WAV (16-bit mono PCM at 8 kHz, one silent sample) a client can
  // decode.
  PNG_BASE64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==';
  WAV_BASE64 = 'UklGRiYAAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAAZGF0YQIAAAAAAA==';

  NO_ARGUMENTS = '{"type":"object","properties":{}}';

  // json_schema_2020_12_tool: 2020-12 keywords outside the enforced
  // subset ($defs, $ref, allOf/anyOf, if/then/else), so the handler owns
  // validation (ApplicationValidated).
  JSON_SCHEMA_2020_12 =
    '{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object",' +
    '"$defs":{"address":{"$anchor":"addressDef","type":"object","properties":' +
    '{"street":{"type":"string"},"city":{"type":"string"}}}},' +
    '"properties":{"name":{"type":"string"},"address":{"$ref":"#/$defs/address"},' +
    '"contactMethod":{"type":"string","enum":["phone","email"]},' +
    '"phone":{"type":"string"},"email":{"type":"string"}},' +
    '"allOf":[{"anyOf":[{"required":["phone"]},{"required":["email"]}]}],' +
    '"if":{"properties":{"contactMethod":{"const":"phone"}},"required":["contactMethod"]},' +
    '"then":{"required":["phone"]},"else":{"required":["email"]},' +
    '"additionalProperties":false}';

  // A tool whose arguments are mirrored into Mcp-Param-* headers.
  CUSTOM_HEADER_SCHEMA =
    '{"type":"object","properties":{"region":{"type":"string",' +
    '"x-mcp-header":"Region"},"query":{"type":"string"}},"required":["region"]}';

  CONFIRM_SCHEMA =
    '{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"]}';

function JSONObjectOf(const AJson: string): TJSONObject;
begin
  Result := GetJSON(AJson) as TJSONObject;
end;

// A one-string-field elicitation schema.
function FieldSchema(const AField: string): TJSONObject;
begin
  Result := JSONObjectOf('{"type":"object","properties":{"' + AField +
    '":{"type":"string"}},"required":["' + AField + '"]}');
end;

// The accepted elicitation's AField, or 'unknown'.
function ElicitedText(const ACtx: TMCPRequestContext;
  const AKey, AField: string): string;
var
  Content: TJSONObject;
begin
  Content := MCPElicitationContent(ACtx, AKey);
  if Content = nil then
    Exit('unknown');
  Result := Content.Get(AField, 'unknown');
end;

// One input request under AKey.
function OneRequest(const AKey: string; ARequest: TJSONObject): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add(AKey, ARequest);
end;

{ ───────── content tools ───────── }

function SimpleText(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPTextResult('This is a simple text response for testing.');
end;

function ImageContent(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPImageResult(PNG_BASE64, 'image/png');
end;

function AudioContent(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPAudioResult(WAV_BASE64, 'audio/wav');
end;

function EmbeddedResource(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPContentResult([MCPEmbeddedText('test://embedded-resource',
    'text/plain', 'This is an embedded resource content.')]);
end;

// Not in the reference fixture: no scenario returns a resource link.
// The name and description carry multi-byte UTF-8, the URI stays ASCII.
function FixtureResourceLink(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPContentResult([
    MCPTextContent('Linked resource:'),
    MCPResourceLink('test://static-text', 'static-text ' + #$E4#$B8#$96,
      'text/plain', 'Caf' + #$C3#$A9 + ' ' + #$F0#$9F#$98#$80)]);
end;

// Non-object structured output (#91, not a suite scenario): an array
// of UTF-8 strings, sent with its JSON as the text block.
function FixtureArrayOutput(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Values: TJSONArray;
begin
  Values := TJSONArray.Create;
  Values.Add('Gr' + #$C3#$BC + #$C3#$9F + 'e');
  Values.Add(#$F0#$9F#$98#$80);
  Result := MCPStructuredResult(Values);
end;

// Output that breaks its integer outputSchema (#91): the server answers
// isError instead of sending it.
function FixtureBadOutput(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPStructuredResult(TJSONString.Create('not a number'));
end;

// A tool definition with an outputSchema, for the #91 fixture tools.
function OutputTool(const AName, ADescription,
  AOutputSchema: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('name', AName);
  Result.Add('description', ADescription);
  Result.Add('inputSchema', GetJSON(NO_ARGUMENTS));
  Result.Add('outputSchema', GetJSON(AOutputSchema));
end;

function MultipleContentTypes(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  Result := MCPContentResult([
    MCPTextContent('Multiple content types test:'),
    MCPImageContent(PNG_BASE64, 'image/png'),
    MCPEmbeddedText('test://mixed-content-resource', 'application/json',
      '{"test":"data","value":123}')]);
end;

{ ───────── notification and error tools ───────── }

function WithLogging(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  MCPLogMessage(ACtx, 'info', 'Tool execution started');
  MCPLogMessage(ACtx, 'info', 'Tool processing data');
  MCPLogMessage(ACtx, 'info', 'Tool execution completed');
  Result := MCPTextResult('Tool with logging executed successfully');
end;

function WithProgress(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  MCPReportProgress(ACtx, 0, 100, 'Completed step 0 of 100');
  Sleep(50);
  MCPReportProgress(ACtx, 50, 100, 'Completed step 50 of 100');
  Sleep(50);
  MCPReportProgress(ACtx, 100, 100, 'Completed step 100 of 100');
  Result := MCPTextResult(ACtx.ProgressToken);
end;

function ErrorHandling(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  // The exception path on purpose: tools/call turns it into isError.
  Result := Default(TMCPToolResult);
  raise Exception.Create('This tool intentionally returns an error for testing');
end;

// '' when AArguments[AName] is absent or a string, else the problem.
function OptionalString(AArguments: TJSONObject; const AName: string): string;
var
  Value: TJSONData;
begin
  Result := '';
  Value := AArguments.Find(AName);
  if (Value <> nil) and (Value.JSONType <> jtString) then
    Result := '"' + AName + '" must be a string';
end;

// The checks JSON_SCHEMA_2020_12 states, which this handler owns
// because the tool is ApplicationValidated (ADR-0004): known members
// only, string fields, an address object of strings, contactMethod in
// its enum, and the phone or email that contactMethod selects.
function JsonSchemaViolation(AArguments: TJSONObject): string;
const
  KNOWN: array[0..4] of string =
    ('name', 'address', 'contactMethod', 'phone', 'email');
var
  I: Integer;
  Address: TJSONData;
  Method: string;
begin
  for I := 0 to AArguments.Count - 1 do
    if not AnsiMatchStr(AArguments.Names[I], KNOWN) then
      Exit('unexpected argument "' + AArguments.Names[I] + '"');
  for I := 0 to High(KNOWN) do
    if (KNOWN[I] <> 'address') and (OptionalString(AArguments, KNOWN[I]) <> '') then
      Exit(OptionalString(AArguments, KNOWN[I]));
  Address := AArguments.Find('address');
  if Address <> nil then
  begin
    if Address.JSONType <> jtObject then
      Exit('"address" must be an object');
    if (OptionalString(TJSONObject(Address), 'street') <> '') or
      (OptionalString(TJSONObject(Address), 'city') <> '') then
      Exit('"address" street and city must be strings');
  end;
  if (AArguments.Find('phone') = nil) and (AArguments.Find('email') = nil) then
    Exit('one of "phone" or "email" is required');
  Method := AArguments.Get('contactMethod', '');
  if (AArguments.Find('contactMethod') <> nil) and
    not AnsiMatchStr(Method, ['phone', 'email']) then
    Exit('"contactMethod" must be "phone" or "email"');
  if (Method = 'phone') and (AArguments.Find('phone') = nil) then
    Exit('"phone" is required when contactMethod is "phone"');
  if (Method <> 'phone') and (AArguments.Find('email') = nil) then
    Exit('"email" is required unless contactMethod is "phone"');
  Result := '';
end;

function JsonSchemaTool(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Violation: string;
begin
  Violation := JsonSchemaViolation(AArguments);
  if Violation <> '' then
    Exit(MCPErrorResult('Invalid arguments: ' + Violation));
  Result := MCPTextResult('JSON Schema 2020-12 tool called with: ' +
    AArguments.AsJSON);
end;

// CUSTOM_HEADER_SCHEMA's checks: a required string region and an
// optional string query (ApplicationValidated, as above).
function CustomHeaders(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Region: TJSONData;
begin
  Region := AArguments.Find('region');
  if (Region = nil) or (Region.JSONType <> jtString) then
    Exit(MCPErrorResult('Invalid arguments: "region" must be a string'));
  if OptionalString(AArguments, 'query') <> '' then
    Exit(MCPErrorResult('Invalid arguments: ' +
      OptionalString(AArguments, 'query')));
  Result := MCPTextResult('Custom headers tool called with: ' +
    AArguments.AsJSON);
end;

// Needs sampling: an input request for it is answered -32021 by the
// library when the client did not declare the capability.
function MissingCapability(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  if MCPInputResponse(ACtx, 'sampling') <> nil then
    Exit(MCPTextResult('Success'));
  Result := MCPInputRequired(OneRequest('sampling',
    MCPSamplingTextRequest('Say hello', 10)));
end;

function StreamingElicitation(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  MCPReportProgress(ACtx, 50, 100);
  Result := MCPTextResult('Streaming complete');
end;

function LoggingTool(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  MCPLogMessage(ACtx, 'info', 'Diagnostic trace logging activated');
  Result := MCPTextResult('Logging evaluated');
end;

{ ───────── input_required (MRTR) tools ───────── }

function IRElicitation(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  if MCPInputResponse(ACtx, 'user_name') <> nil then
    Exit(MCPTextResult('Hello, ' + ElicitedText(ACtx, 'user_name', 'name') + '!'));
  Result := MCPInputRequired(OneRequest('user_name',
    MCPElicitFormRequest('What is your name?', FieldSchema('name'))));
end;

function IRSampling(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Response: TJSONObject;
begin
  Response := MCPInputResponse(ACtx, 'sample_request');
  if Response <> nil then
    Exit(MCPTextResult('Sampling result: ' + Response.AsJSON));
  Result := MCPInputRequired(OneRequest('sample_request',
    MCPSamplingTextRequest('What is the capital of France?', 100)));
end;

function IRListRoots(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Response: TJSONObject;
begin
  Response := MCPInputResponse(ACtx, 'roots_request');
  if Response <> nil then
    Exit(MCPTextResult('Found root(s): ' + Response.AsJSON));
  Result := MCPInputRequired(OneRequest('roots_request', MCPRootsRequest));
end;

function IRRequestState(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Content: TJSONObject;
begin
  Content := MCPElicitationContent(ACtx, 'confirm');
  if (ACtx.RequestState = 'request-state') and (Content <> nil) and
    Content.Get('ok', False) then
    Exit(MCPTextResult('state-ok: requestState validated'));
  Result := MCPInputRequired(OneRequest('confirm',
    MCPElicitFormRequest('Please confirm', JSONObjectOf(CONFIRM_SCHEMA))),
    'request-state');
end;

function IRMultipleInputs(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Requests: TJSONObject;
begin
  if (ACtx.RequestState = 'multiple-inputs') and
    (MCPInputResponse(ACtx, 'user_name') <> nil) and
    (MCPInputResponse(ACtx, 'greeting') <> nil) and
    (MCPInputResponse(ACtx, 'client_roots') <> nil) then
    Exit(MCPTextResult('Name: ' + ElicitedText(ACtx, 'user_name', 'name')));
  Requests := TJSONObject.Create;
  Requests.Add('user_name', MCPElicitFormRequest('What is your name?',
    FieldSchema('name')));
  Requests.Add('greeting', MCPSamplingTextRequest('Generate a greeting', 50));
  Requests.Add('client_roots', MCPRootsRequest);
  Result := MCPInputRequired(Requests, 'multiple-inputs');
end;

// The state only names the round: the library passes the client's echo
// through unverified until #89, so nothing from it reaches the result.
function IRMultiRound(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  if (ACtx.RequestState = 'round1') and
    (MCPInputResponse(ACtx, 'step1') <> nil) then
    Exit(MCPInputRequired(OneRequest('step2',
      MCPElicitFormRequest('Step 2: What is your favorite color?',
      FieldSchema('color'))), 'round2'));
  if (ACtx.RequestState = 'round2') and
    (MCPInputResponse(ACtx, 'step2') <> nil) then
    Exit(MCPTextResult('Multi-round complete: favorite color ' +
      ElicitedText(ACtx, 'step2', 'color')));
  Result := MCPInputRequired(OneRequest('step1',
    MCPElicitFormRequest('Step 1: What is your name?', FieldSchema('name'))),
    'round1');
end;

// The suite sends this state back modified and expects a JSON-RPC
// error. The handler compares the echo with what it minted; a mismatch
// can only raise, which tools/call reports as an isError result, so the
// scenario fails until the library verifies requestState itself (#89).
function IRTamperedState(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
const
  MINTED = 'tamper-test';
begin
  if ACtx.RequestState <> '' then
  begin
    if ACtx.RequestState <> MINTED then
      raise Exception.Create('requestState integrity check failed');
    if MCPInputResponse(ACtx, 'confirm') <> nil then
      Exit(MCPTextResult('integrity-ok: state verified'));
  end;
  Result := MCPInputRequired(OneRequest('confirm',
    MCPElicitFormRequest('Please confirm', JSONObjectOf(CONFIRM_SCHEMA))),
    MINTED);
end;

function IRCapabilities(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Requests: TJSONObject;
begin
  if (ACtx.InputResponses <> nil) and (ACtx.InputResponses.Count > 0) then
    Exit(MCPTextResult('capabilities-ok: received'));
  Requests := TJSONObject.Create;
  if ACtx.HasCapability('elicitation') then
    Requests.Add('elicit_input', MCPElicitFormRequest('Elicitation input',
      FieldSchema('value')));
  if ACtx.HasCapability('sampling') then
    Requests.Add('sample_input', MCPSamplingTextRequest('Sample request', 50));
  if Requests.Count = 0 then
  begin
    Requests.Free;
    Exit(MCPTextResult('No supported capabilities declared'));
  end;
  Result := MCPInputRequired(Requests, 'capabilities-test');
end;

{ ───────── prompts ───────── }

function SimplePrompt(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  Result := MCPMessages([MCPUserMessage('This is a simple prompt for testing.')]);
end;

// The string value of the prompt argument AName; anything else is
// refused, so a wrong type is never turned into an empty string.
function StringArgument(AArguments: TJSONObject; const AName: string): string;
var
  Value: TJSONData;
begin
  Value := AArguments.Find(AName);
  if (Value = nil) or (Value.JSONType <> jtString) then
    raise Exception.Create('argument "' + AName + '" must be a string');
  Result := Value.AsString;
end;

// An absolute URI as RFC 3986 spells it: a scheme, a colon, and only
// visible ASCII after it (non-ASCII has to be percent-encoded).
function IsAbsoluteURI(const AValue: string): Boolean;
var
  I, Colon: Integer;
begin
  Colon := Pos(':', AValue);
  Result := (Colon > 1) and (Colon < Length(AValue)) and
    (AValue[1] in ['A'..'Z', 'a'..'z']);
  for I := 2 to Colon - 1 do
    if not (AValue[I] in ['A'..'Z', 'a'..'z', '0'..'9', '+', '-', '.']) then
      Exit(False);
  for I := Colon + 1 to Length(AValue) do
    if not (AValue[I] in [#33..#126]) or (AValue[I] in ['"', '<', '>', '\',
      '^', '`', '{', '|', '}']) then
      Exit(False);
end;

function PromptWithArguments(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  Result := MCPMessages([MCPUserMessage('Prompt with arguments: arg1=''' +
    StringArgument(AArguments, 'arg1') + ''', arg2=''' +
    StringArgument(AArguments, 'arg2') + '''')]);
end;

function PromptWithEmbeddedResource(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TJSONArray;
var
  Uri: string;
begin
  // An embedded resource MUST carry a valid URI (prompts spec): refuse
  // anything else rather than emit a message clients reject.
  Uri := StringArgument(AArguments, 'resourceUri');
  if not IsAbsoluteURI(Uri) then
    raise Exception.Create('resourceUri must be an absolute URI');
  Result := MCPMessages([
    MCPContentMessage('user', MCPEmbeddedText(Uri,
      'text/plain', 'Embedded resource content for testing.')),
    MCPUserMessage('Please process the embedded resource above.')]);
end;

function PromptWithImage(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  Result := MCPMessages([
    MCPContentMessage('user', MCPImageContent(PNG_BASE64, 'image/png')),
    MCPUserMessage('Please analyze the image above.')]);
end;

function IRPrompt(AArguments: TJSONObject;
  const ACtx: TMCPRequestContext): TMCPPromptResult;
begin
  if MCPInputResponse(ACtx, 'user_context') <> nil then
    Exit(MCPPromptMessagesResult(MCPMessages([MCPUserMessage(
      'Prompt with context: ' + ElicitedText(ACtx, 'user_context', 'context'))])));
  Result := MCPPromptInputRequired(OneRequest('user_context',
    MCPElicitFormRequest('What context should the prompt use?',
    FieldSchema('context'))));
end;

{ ───────── resources ───────── }

function StaticBinary(const AUri: string;
  const ACtx: TMCPRequestContext): TJSONArray;
begin
  Result := MCPBlobContents(AUri, 'image/png', PNG_BASE64);
end;

function TemplateData(const AUri: string; AVars: TJSONObject;
  const ACtx: TMCPRequestContext): TJSONArray;
var
  Data: TJSONObject;
begin
  Data := TJSONObject.Create;
  try
    Data.Add('id', AVars.Get('id', ''));
    Data.Add('templateTest', True);
    Data.Add('data', 'Data for ID: ' + AVars.Get('id', ''));
    Result := MCPTextContents(AUri, 'application/json', Data.AsJSON);
  finally
    Data.Free;
  end;
end;

type
  TArgumentlessTool = record
    Name: string;
    Description: string;
    Handler: TMCPToolHandler;
  end;

const
  // Every tool without arguments, under the reference fixture's names.
  ARGUMENTLESS_TOOLS: array[0..19] of TArgumentlessTool = (
    (Name: 'test_simple_text';
     Description: 'Tests simple text content response'; Handler: SimpleText),
    (Name: 'test_image_content';
     Description: 'Tests image content response'; Handler: ImageContent),
    (Name: 'test_audio_content';
     Description: 'Tests audio content response'; Handler: AudioContent),
    (Name: 'test_embedded_resource';
     Description: 'Tests embedded resource content response';
     Handler: EmbeddedResource),
    (Name: 'fixture_resource_link';
     Description: 'Returns text and a resource link (not a suite scenario)';
     Handler: FixtureResourceLink),
    (Name: 'test_multiple_content_types';
     Description: 'Tests response with multiple content types (text, image, resource)';
     Handler: MultipleContentTypes),
    (Name: 'test_tool_with_logging';
     Description: 'Tests tool that emits log messages during execution';
     Handler: WithLogging),
    (Name: 'test_tool_with_progress';
     Description: 'Tests tool that reports progress notifications';
     Handler: WithProgress),
    (Name: 'test_error_handling';
     Description: 'Tests error response handling'; Handler: ErrorHandling),
    (Name: 'test_missing_capability';
     Description: 'Test tool requiring sampling'; Handler: MissingCapability),
    (Name: 'test_input_required_result_elicitation';
     Description: 'MRTR: returns InputRequiredResult with elicitation request';
     Handler: IRElicitation),
    (Name: 'test_input_required_result_sampling';
     Description: 'MRTR: returns InputRequiredResult with sampling request';
     Handler: IRSampling),
    (Name: 'test_input_required_result_list_roots';
     Description: 'MRTR: returns InputRequiredResult with roots/list request';
     Handler: IRListRoots),
    (Name: 'test_input_required_result_request_state';
     Description: 'MRTR: returns InputRequiredResult with requestState';
     Handler: IRRequestState),
    (Name: 'test_input_required_result_multiple_inputs';
     Description: 'MRTR: returns InputRequiredResult with several input requests';
     Handler: IRMultipleInputs),
    (Name: 'test_input_required_result_multi_round';
     Description: 'MRTR: two input_required rounds before completing';
     Handler: IRMultiRound),
    (Name: 'test_input_required_result_tampered_state';
     Description: 'MRTR: requestState integrity test'; Handler: IRTamperedState),
    (Name: 'test_input_required_result_capabilities';
     Description: 'MRTR: respects client capabilities in inputRequests';
     Handler: IRCapabilities),
    (Name: 'test_streaming_elicitation';
     Description: 'Diagnostic tool validating response progress streams';
     Handler: StreamingElicitation),
    (Name: 'test_logging_tool';
     Description: 'Diagnostic logging validator tool'; Handler: LoggingTool));

procedure RegisterTools(AServer: TMCPServer);
var
  I: Integer;
begin
  for I := Low(ARGUMENTLESS_TOOLS) to High(ARGUMENTLESS_TOOLS) do
    AServer.RegisterTool(ARGUMENTLESS_TOOLS[I].Name,
      ARGUMENTLESS_TOOLS[I].Description, NO_ARGUMENTS,
      ARGUMENTLESS_TOOLS[I].Handler);
  AServer.RegisterTool('json_schema_2020_12_tool',
    'Tool with JSON Schema 2020-12 features', JSON_SCHEMA_2020_12,
    JsonSchemaTool).ApplicationValidated;
  AServer.RegisterTool(OutputTool('fixture_array_output',
    'Returns an array of UTF-8 strings as structured output (not a suite ' +
    'scenario)', '{"type":"array","items":{"type":"string"}}'),
    FixtureArrayOutput);
  AServer.RegisterTool(OutputTool('fixture_bad_output',
    'Returns output that breaks its schema (not a suite scenario)',
    '{"type":"integer"}'), FixtureBadOutput);
  AServer.RegisterTool('test_custom_headers',
    'Tool whose region argument is mirrored into an Mcp-Param header',
    CUSTOM_HEADER_SCHEMA, CustomHeaders).ApplicationValidated;
end;

procedure RegisterPrompts(AServer: TMCPServer);
begin
  AServer.RegisterPrompt('test_simple_prompt',
    'A simple prompt without arguments', SimplePrompt);
  AServer.RegisterPrompt('test_prompt_with_arguments',
    'A prompt with required arguments',
    PromptArguments.Add('arg1', 'First test argument')
      .Add('arg2', 'Second test argument'), PromptWithArguments);
  AServer.RegisterPrompt('test_prompt_with_embedded_resource',
    'A prompt that includes an embedded resource',
    PromptArguments.Add('resourceUri', 'URI of the resource to embed'),
    PromptWithEmbeddedResource);
  AServer.RegisterPrompt('test_prompt_with_image',
    'A prompt that includes image content', PromptWithImage);
  AServer.RegisterPrompt('test_input_required_result_prompt',
    'MRTR: prompt that asks for context first', IRPrompt);
end;

procedure RegisterResources(AServer: TMCPServer);
begin
  AServer.RegisterTextResource('test://static-text', 'static-text',
    'text/plain', 'This is the content of the static text resource.',
    'A static text resource for testing');
  AServer.RegisterResource('test://static-binary', 'static-binary',
    'image/png', StaticBinary, 'A static binary resource (image) for testing');
  AServer.RegisterTextResource('test://watched-resource', 'watched-resource',
    'text/plain', 'Watched resource content', 'A resource that auto-updates');
  AServer.RegisterResourceTemplate('test://template/{id}/data', 'template',
    'application/json', TemplateData,
    'A resource template with parameter substitution');
end;

var
  Server: TMCPServer;
  Transport: TMCPHTTPServer;
  Port: Integer;

begin
  Server := TMCPServer.Create('mcp-conformance-test-server', '1.0.0');
  try
    RegisterTools(Server);
    RegisterPrompts(Server);
    RegisterResources(Server);

    if (ParamCount = 2) and (ParamStr(1) = '--http') and
      TryStrToInt(ParamStr(2), Port) and (Port > 0) and (Port <= 65535) then
    begin
      Transport := TMCPHTTPServer.Create(Server);
      try
        Transport.Port := Port;
        MCPLogToStderr('mcpconformance: serving MCP ' + MCP_PROTOCOL_VERSION +
          ' on http://127.0.0.1:' + IntToStr(Port) + Transport.EndpointPath);
        Transport.Run;
      finally
        Transport.Free;
      end;
    end
    else
      RunMCPStdioServer(Server);
  finally
    Server.Free;
  end;
end.
