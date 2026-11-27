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

// The candidates that start with AValue, in their given order: the
// completion a static list gives. Case is ignored for ASCII, Latin-1,
// Latin Extended-A, Greek and Cyrillic letters, by a fixed simple fold
// that does not depend on the locale.
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
  Math,

  MCP.UriTemplate;

// A simple, locale-independent case fold of one code point: ASCII,
// Latin-1, Latin Extended-A, Greek and Cyrillic capitals to their small
// letters; anything else unchanged.
function FoldCodePoint(C: Cardinal): Cardinal;
begin
  Result := C;
  case C of
    $41..$5A, $C0..$D6, $D8..$DE, $391..$3A1, $3A3..$3AB, $410..$42F:
      Result := C + $20;
    $400..$40F:
      Result := C + $50;
    $100..$12F, $132..$137, $14A..$177:
      Result := C or 1;
    $130: // dotted capital I: its simple lowercase is i
      Result := $69;
    $139..$148, $179..$17E:
      if Odd(C) then
        Result := C + 1;
  end;
end;

// AText (UTF-8) with every code point folded by FoldCodePoint, as code
// points; ill-formed bytes are kept as themselves.
function FoldedCodePoints(const AText: string): UnicodeString;
var
  Wide: UnicodeString;
  I: Integer;
  C: Cardinal;
begin
  // UTF8Decode reads bytes, not the system code page, so the fold is
  // the same on any locale.
  Wide := UTF8Decode(AText);
  SetLength(Result, Length(Wide));
  for I := 1 to Length(Wide) do
  begin
    C := Ord(Wide[I]);
    // Surrogate halves pass through: none of the folded ranges is
    // outside the Basic Multilingual Plane.
    Result[I] := WideChar(FoldCodePoint(C));
  end;
end;

function MCPCompleteFrom(const AValue: string;
  const ACandidates: array of string): TMCPCompletion;
var
  I: Integer;
  Prefix: UnicodeString;
begin
  Result := Default(TMCPCompletion);
  Prefix := FoldedCodePoints(AValue);
  for I := 0 to High(ACandidates) do
    if Copy(FoldedCodePoints(ACandidates[I]), 1, Length(Prefix)) = Prefix then
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

// context.arguments in AArguments (nil when context or its arguments
// are omitted). '' or the -32602 message: a supplied context must be an
// object, and its arguments an object of strings (CompleteRequestParams).
function ContextArguments(AParams: TJSONObject;
  out AArguments: TJSONObject): string;
var
  ContextData, Arguments: TJSONData;
  I: Integer;
begin
  Result := '';
  AArguments := nil;
  ContextData := AParams.Find('context');
  if ContextData = nil then
    Exit;
  if ContextData.JSONType <> jtObject then
    Exit('Invalid params: context must be an object');
  Arguments := TJSONObject(ContextData).Find('arguments');
  if Arguments = nil then
    Exit;
  if Arguments.JSONType <> jtObject then
    Exit('Invalid params: context.arguments must be an object');
  for I := 0 to Arguments.Count - 1 do
    if Arguments.Items[I].JSONType <> jtString then
      Exit('Invalid params: context.arguments values must be strings');
  AArguments := TJSONObject(Arguments);
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
  Result := ContextArguments(AParams, ARequest.Context);
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
  else if not UriTemplateHasVariable(ARefName, AArgument) then
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
  // More exist when the handler says so, when values were cut to the
  // cap, or when a known total exceeds what is sent.
  Result.Add('hasMore', ACompletion.HasMore or
    (Length(ACompletion.Values) > MAX_VALUES) or
    (ACompletion.Total > Min(Length(ACompletion.Values), MAX_VALUES)));
end;

end.
