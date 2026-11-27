unit MCP.Completion;

// Argument completion (completion/complete, #81): the suggestion type
// handlers return, the static-list matcher, the request's parameters
// and the CompleteResult it answers with. Verified 2026-11-26 against
// https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/completion
//
// MCP.Server keeps the registrations and dispatch and re-exports the
// types and MCPCompleteFrom, so a server needs only MCP.Server in its
// uses clause. This unit has no registry of its own.

{$I MCP.inc}

interface

uses
  SysUtils,

  fpjson,
  MCP.Protocol;

type
  // Suggestions for one prompt argument or resource-template variable.
  // Values are ranked best first; the server sends at most 100 of them.
  // Total is the number of all matches (-1 when unknown) and HasMore
  // says more exist than were sent. Build it with MCPCompleteFrom or by
  // hand.
  TMCPCompletion = record
    Values: array of string;
    Total: Integer;
    HasMore: Boolean;
  end;

  // AArgument names the argument or variable being completed, AValue is
  // what the user has typed so far, and AContext holds the arguments the
  // client already resolved (borrowed; nil when none).
  TMCPCompletionHandler = function(const AArgument, AValue: string;
    AContext: TJSONObject; const ACtx: TMCPRequestContext): TMCPCompletion;
  TMCPCompletionMethod = function(const AArgument, AValue: string;
    AContext: TJSONObject; const ACtx: TMCPRequestContext): TMCPCompletion
    of object;

  // The parameters of one completion/complete request.
  TMCPCompleteRequest = record
    RefType: string;       // 'ref/prompt' or 'ref/resource'
    RefName: string;       // the prompt name or the URI template
    Argument: string;      // the argument or variable being completed
    Value: string;         // what the user has typed so far
    Context: TJSONObject;  // context.arguments, borrowed; nil when none
  end;

// The candidates that start with AValue, compared case-insensitively,
// in their given order: the completion a static list gives.
function MCPCompleteFrom(const AValue: string;
  const ACandidates: array of string): TMCPCompletion;

// Reads AParams (borrowed; may be nil) into ARequest. '' on success,
// otherwise the -32602 message for what is missing or malformed.
function ParseCompleteRequest(AParams: TJSONObject;
  out ARequest: TMCPCompleteRequest): string;

// '' when the reference names a completable target with AArgument,
// otherwise what is wrong: for ref/prompt APromptDefinition is the
// registered prompt's definition (borrowed; nil when unknown), for
// ref/resource ATemplateKnown says the URI template is registered.
function CompletionTargetFault(const ARefType, ARefName, AArgument: string;
  APromptDefinition: TJSONObject; ATemplateKnown: Boolean): string;

// The CompleteResult "completion" object for ACompletion, owned by the
// caller: at most 100 values (schema maxItems), total, and hasMore when
// values were left out or the handler says more exist.
function CompletionObject(const ACompletion: TMCPCompletion): TJSONObject;

implementation

uses
  Math;

function MCPCompleteFrom(const AValue: string;
  const ACandidates: array of string): TMCPCompletion;
var
  I: Integer;
  Prefix: string;
begin
  Result := Default(TMCPCompletion);
  Prefix := LowerCase(AValue);
  for I := 0 to High(ACandidates) do
    if Copy(LowerCase(ACandidates[I]), 1, Length(Prefix)) = Prefix then
    begin
      SetLength(Result.Values, Length(Result.Values) + 1);
      Result.Values[High(Result.Values)] := ACandidates[I];
    end;
  Result.Total := Length(Result.Values);
  Result.HasMore := False;
end;

// The string member AName of AObject, or False.
function StringMember(AObject: TJSONData; const AName: string;
  out AValue: string): Boolean;
var
  Data: TJSONData;
begin
  Result := False;
  AValue := '';
  if (AObject = nil) or (AObject.JSONType <> jtObject) then
    Exit;
  Data := TJSONObject(AObject).Find(AName);
  Result := (Data <> nil) and (Data.JSONType = jtString);
  if Result then
    AValue := Data.AsString;
end;

// context.arguments as an object, or nil.
function ContextArguments(AParams: TJSONObject): TJSONObject;
var
  ContextData, Arguments: TJSONData;
begin
  Result := nil;
  ContextData := AParams.Find('context');
  if (ContextData = nil) or (ContextData.JSONType <> jtObject) then
    Exit;
  Arguments := TJSONObject(ContextData).Find('arguments');
  if (Arguments <> nil) and (Arguments.JSONType = jtObject) then
    Result := TJSONObject(Arguments);
end;

function ParseCompleteRequest(AParams: TJSONObject;
  out ARequest: TMCPCompleteRequest): string;
var
  Ref, Argument: TJSONData;
  NameKey: string;
begin
  ARequest := Default(TMCPCompleteRequest);
  if AParams = nil then
    Exit('Invalid params: completion/complete needs ref and argument');
  Ref := AParams.Find('ref');
  Argument := AParams.Find('argument');
  if not (StringMember(Ref, 'type', ARequest.RefType) and
    ((ARequest.RefType = 'ref/prompt') or
    (ARequest.RefType = 'ref/resource'))) then
    Exit('Invalid params: ref must be a ref/prompt or ref/resource ' +
      'reference');
  if ARequest.RefType = 'ref/prompt' then
    NameKey := 'name'
  else
    NameKey := 'uri';
  if not StringMember(Ref, NameKey, ARequest.RefName) then
    Exit('Invalid params: ' + ARequest.RefType + ' needs a ' + NameKey);
  if not (StringMember(Argument, 'name', ARequest.Argument) and
    StringMember(Argument, 'value', ARequest.Value)) then
    Exit('Invalid params: argument needs a name and a value');
  ARequest.Context := ContextArguments(AParams);
  Result := '';
end;

// The prompt's declared argument names include AArgument.
function PromptDeclaresArgument(ADefinition: TJSONObject;
  const AArgument: string): Boolean;
var
  Arguments: TJSONData;
  I: Integer;
begin
  Result := False;
  Arguments := ADefinition.Find('arguments');
  if (Arguments = nil) or (Arguments.JSONType <> jtArray) then
    Exit;
  for I := 0 to Arguments.Count - 1 do
    if (Arguments.Items[I].JSONType = jtObject) and
      (TJSONObject(Arguments.Items[I]).Get('name', '') = AArgument) then
      Exit(True);
end;

function CompletionTargetFault(const ARefType, ARefName, AArgument: string;
  APromptDefinition: TJSONObject; ATemplateKnown: Boolean): string;
begin
  Result := '';
  if ARefType = 'ref/prompt' then
  begin
    if APromptDefinition = nil then
      Result := 'unknown prompt "' + ARefName + '"'
    else if not PromptDeclaresArgument(APromptDefinition, AArgument) then
      Result := 'prompt "' + ARefName + '" has no argument "' +
        AArgument + '"';
  end
  else if not ATemplateKnown then
    Result := 'unknown resource template "' + ARefName + '"'
  else if Pos('{' + AArgument + '}', ARefName) = 0 then
    Result := 'resource template "' + ARefName + '" has no variable "' +
      AArgument + '"';
end;

function CompletionObject(const ACompletion: TMCPCompletion): TJSONObject;
const
  MAX_VALUES = 100;
var
  Values: TJSONArray;
  I: Integer;
begin
  Values := TJSONArray.Create;
  for I := 0 to Min(High(ACompletion.Values), MAX_VALUES - 1) do
    Values.Add(ACompletion.Values[I]);
  Result := TJSONObject.Create;
  Result.Add('values', Values);
  if ACompletion.Total >= 0 then
    Result.Add('total', Max(ACompletion.Total, Length(ACompletion.Values)));
  Result.Add('hasMore', ACompletion.HasMore or
    (Length(ACompletion.Values) > MAX_VALUES));
end;

end.
