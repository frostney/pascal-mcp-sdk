unit MCP.UriTemplate;

// RFC 6570 level-1 URI templates for resource templates: validation at
// registration and matching a URI to a template on resources/read.
// {var} captures one or more characters excluding '/', delimited by
// the complete following literal with bounded backtracking. Variable
// names use [A-Za-z0-9_]. Captures are raw URI substrings;
// percent-decoding is deliberately not performed. Resource-template
// semantics verified 2026-07-20:
// https://modelcontextprotocol.io/specification/2026-07-28/server/resources
//
// MCP.Server re-exports MatchUriTemplate. Moved out of MCP.Server
// (#81) to keep that unit under its complexity ceiling.

{$I MCP.inc}

interface

uses
  SysUtils,

  fpjson;

// '' in AError and True when ATemplate is a valid level-1 template;
// otherwise False with what is wrong.
function TryValidateUriTemplate(const ATemplate: string;
  out AError: string): Boolean;

// True when ATemplate (valid) has a variable named exactly AName.
function UriTemplateHasVariable(const ATemplate, AName: string): Boolean;

// On success AVars carries the captured variables (caller frees).
function MatchUriTemplate(const ATemplate, AUri: string;
  out AVars: TJSONObject): Boolean;

implementation

function UriTemplateHasVariable(const ATemplate, AName: string): Boolean;
var
  Open, Close: Integer;
begin
  Result := False;
  Open := Pos('{', ATemplate);
  while Open > 0 do
  begin
    Close := Pos('}', ATemplate, Open + 1);
    if Close = 0 then
      Exit;
    if Copy(ATemplate, Open + 1, Close - Open - 1) = AName then
      Exit(True);
    Open := Pos('{', ATemplate, Close + 1);
  end;
end;

function IsUriTemplateVariableCharacter(ACharacter: Char): Boolean; inline;
begin
  Result := ACharacter in ['A'..'Z', 'a'..'z', '0'..'9', '_'];
end;

function TryValidateUriTemplate(const ATemplate: string;
  out AError: string): Boolean;
var
  CloseBrace, Index, VariableIndex: Integer;
  PreviousWasVariable: Boolean;
begin
  Result := False;
  AError := '';
  if ATemplate = '' then
  begin
    AError := 'Resource template registration requires a non-empty uriTemplate';
    Exit;
  end;
  Index := 1;
  PreviousWasVariable := False;
  while Index <= Length(ATemplate) do
  begin
    if ATemplate[Index] = '}' then
    begin
      AError := Format('Invalid resource template "%s": stray "}" at ' +
        'character %d', [ATemplate, Index]);
      Exit;
    end;
    if ATemplate[Index] <> '{' then
    begin
      PreviousWasVariable := False;
      Inc(Index);
      Continue;
    end;
    if PreviousWasVariable then
    begin
      AError := Format('Invalid resource template "%s": adjacent variables ' +
        'require separating literal text', [ATemplate]);
      Exit;
    end;
    CloseBrace := Index + 1;
    while (CloseBrace <= Length(ATemplate)) and
      (ATemplate[CloseBrace] <> '}') do
      Inc(CloseBrace);
    if CloseBrace > Length(ATemplate) then
    begin
      AError := Format('Invalid resource template "%s": unclosed variable ' +
        'at character %d', [ATemplate, Index]);
      Exit;
    end;
    if CloseBrace = Index + 1 then
    begin
      AError := Format('Invalid resource template "%s": variable name must ' +
        'not be empty', [ATemplate]);
      Exit;
    end;
    for VariableIndex := Index + 1 to CloseBrace - 1 do
      if not IsUriTemplateVariableCharacter(ATemplate[VariableIndex]) then
      begin
        AError := Format('Invalid resource template "%s": variable name ' +
          'must contain only A-Z, a-z, 0-9, and _', [ATemplate]);
        Exit;
      end;
    PreviousWasVariable := True;
    Index := CloseBrace + 1;
  end;
  Result := True;
end;

function MatchUriTemplate(const ATemplate, AUri: string;
  out AVars: TJSONObject): Boolean;
type
  TVariableCapture = record
    Name: string;
    Value: string;
  end;
  TVariableCaptures = array of TVariableCapture;
  TFailedStateRow = array of Boolean;
  TFailedStateRows = array of TFailedStateRow;
var
  Captures: TVariableCaptures;
  FailedStates: TFailedStateRows;
  I: Integer;
  ValidationError: string;

  function IsFailedState(ATemplateIndex, AUriIndex: Integer): Boolean;
  begin
    Result := (Length(FailedStates[ATemplateIndex]) <> 0) and
      FailedStates[ATemplateIndex][AUriIndex];
  end;

  procedure RememberFailedState(ATemplateIndex, AUriIndex: Integer);
  begin
    if Length(FailedStates[ATemplateIndex]) = 0 then
      SetLength(FailedStates[ATemplateIndex], Length(AUri) + 2);
    FailedStates[ATemplateIndex][AUriIndex] := True;
  end;

  procedure RememberFailedVariableStates(ATemplateIndex, AFirstUriIndex,
    ALastUriIndex: Integer);
  var
    UriIndex: Integer;
  begin
    // With repeated-variable equality deliberately out of scope, a failed
    // variable match also proves every later start in this path segment
    // fails: each has a strict subset of the same possible endpoints.
    for UriIndex := AFirstUriIndex to ALastUriIndex do
      RememberFailedState(ATemplateIndex, UriIndex);
  end;

  function MatchFrom(ATemplateIndex, AUriIndex: Integer): Boolean;
  var
    CaptureIndex, CloseBrace, MaxValueEnd, ValueEnd: Integer;
    StartTemplateIndex, StartUriIndex: Integer;
  begin
    StartTemplateIndex := ATemplateIndex;
    StartUriIndex := AUriIndex;
    if IsFailedState(StartTemplateIndex, StartUriIndex) then
      Exit(False);
    while ATemplateIndex <= Length(ATemplate) do
    begin
      if IsFailedState(ATemplateIndex, AUriIndex) then
      begin
        RememberFailedState(StartTemplateIndex, StartUriIndex);
        Exit(False);
      end;
      if ATemplate[ATemplateIndex] = '{' then
      begin
        CloseBrace := ATemplateIndex + 1;
        while ATemplate[CloseBrace] <> '}' do
          Inc(CloseBrace);
        MaxValueEnd := AUriIndex;
        while (MaxValueEnd <= Length(AUri)) and
          (AUri[MaxValueEnd] <> '/') do
          Inc(MaxValueEnd);
        for ValueEnd := AUriIndex + 1 to MaxValueEnd do
        begin
          CaptureIndex := Length(Captures);
          SetLength(Captures, CaptureIndex + 1);
          Captures[CaptureIndex].Name := Copy(ATemplate,
            ATemplateIndex + 1, CloseBrace - ATemplateIndex - 1);
          Captures[CaptureIndex].Value := Copy(AUri, AUriIndex,
            ValueEnd - AUriIndex);
          if MatchFrom(CloseBrace + 1, ValueEnd) then
            Exit(True);
          SetLength(Captures, CaptureIndex);
        end;
        RememberFailedVariableStates(ATemplateIndex, AUriIndex, MaxValueEnd);
        RememberFailedState(StartTemplateIndex, StartUriIndex);
        Exit(False);
      end;
      if (AUriIndex > Length(AUri)) or
        (ATemplate[ATemplateIndex] <> AUri[AUriIndex]) then
      begin
        RememberFailedState(StartTemplateIndex, StartUriIndex);
        Exit(False);
      end;
      Inc(ATemplateIndex);
      Inc(AUriIndex);
    end;
    Result := AUriIndex > Length(AUri);
    if not Result then
      RememberFailedState(StartTemplateIndex, StartUriIndex);
  end;

begin
  AVars := nil;
  if not TryValidateUriTemplate(ATemplate, ValidationError) then
    Exit(False);
  SetLength(Captures, 0);
  SetLength(FailedStates, Length(ATemplate) + 2);
  Result := MatchFrom(1, 1);
  if not Result then
    Exit;
  AVars := TJSONObject.Create;
  for I := 0 to High(Captures) do
    AVars.Add(Captures[I].Name, Captures[I].Value);
end;

end.
