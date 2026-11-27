unit MCP.RequestState;

// Integrity protection for the MRTR requestState (#89). The 2026-07-28
// specification makes a client-echoed requestState attacker-controlled
// input: a server MUST protect its integrity when it affects business
// logic and MUST reject state that fails verification, and SHOULD bind
// it to a short expiry and to the originating request. Verified
// 2026-11-26 against
// https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr
//
// MCP.Server seals every requestState a handler returns and verifies
// every one a client sends back before the handler runs, so handlers
// only ever see state they minted. A sealed token is
//
//   v1.<base64url(envelope)>.<base64url(HMAC-SHA-256(key, "v1." + envelope part))>
//
// where the envelope is compact JSON:
//
//   {"v":1,"iat":<ms>,"exp":<ms>,"m":<method>,"t":<tool or prompt name>,
//    "a":<base64url SHA-256 of the canonical arguments>,"aud":<server name>,
//    "s":<the handler's state>}
//
// The version prefix sits under the tag, so a token never names its
// algorithm (RFC 8725). The first key seals and every key verifies,
// which allows rotation. The HMAC proves integrity only: the client
// can read the state, so a handler must not put secrets in it. The
// envelope carries no principal, because the library has no
// authenticated identity to bind; that stays the host's (VISION.md).

{$I MCP.inc}

interface

uses
  SysUtils,

  fpjson;

type
  TMCPRequestStateSealer = class
  private
    FAudience: string;
    FKeys: array of RawByteString;
    FTtlMs: Int64;
    function Tag(const AKey, ASigned: RawByteString): RawByteString;
  public
    // AKeys: the first seals, all verify; at least one, none empty.
    constructor Create(const AAudience: string;
      const AKeys: array of RawByteString; ATtlMs: Int64);
    // The token for AState, bound to the request (method, target name,
    // arguments; AArguments may be nil for none).
    function Seal(const AMethod, ATarget: string; AArguments: TJSONObject;
      const AState: string): string;
    // True with the handler's AState when AToken verifies for this
    // request; False with a log-only AReason otherwise.
    function Unseal(const AMethod, ATarget: string; AArguments: TJSONObject;
      const AToken: string; out AState, AReason: string): Boolean;
  end;

// JSON with object members sorted by name (byte order) and no
// insignificant whitespace, so equal values digest equally.
function CanonicalJSON(AData: TJSONData): string;

// Milliseconds since the Unix epoch, UTC.
function UnixTimeMs: Int64;

implementation

// MCP.JSONRPC installs the UTF-8 string conversion every unit that
// moves JSON strings through `string` relies on (cwstring on Unix,
// fpwidestring plus CP_UTF8 on Windows); without it a non-ASCII state
// would come back in the system code page.
uses
  DateUtils,

  jsonparser,
  jsonscanner,
  MCP.Crypto,
  MCP.JSONRPC;

const
  TOKEN_VERSION = 'v1';
  ENVELOPE_VERSION = 1;
  // Tolerated clock difference between the instances that seal and
  // verify, for the issued-at check.
  FUTURE_SKEW_MS = 60000;

function UnixTimeMs: Int64;
begin
  Result := MilliSecondsBetween(LocalTimeToUniversal(Now), UnixEpoch);
end;

type
  TNameArray = array of string;

// Merge sort by byte order (CompareStr): O(n log n) in the worst case,
// since the names come from client arguments of any width.
procedure SortNames(var ANames: TNameArray);
var
  Buffer: TNameArray;

  procedure Merge(ALow, AHigh: Integer);
  var
    Mid, I, J, K: Integer;
  begin
    if AHigh - ALow < 1 then
      Exit;
    Mid := (ALow + AHigh) div 2;
    Merge(ALow, Mid);
    Merge(Mid + 1, AHigh);
    I := ALow;
    J := Mid + 1;
    K := ALow;
    while (I <= Mid) and (J <= AHigh) do
    begin
      if CompareStr(ANames[I], ANames[J]) <= 0 then
      begin
        Buffer[K] := ANames[I];
        Inc(I);
      end
      else
      begin
        Buffer[K] := ANames[J];
        Inc(J);
      end;
      Inc(K);
    end;
    while I <= Mid do
    begin
      Buffer[K] := ANames[I];
      Inc(I);
      Inc(K);
    end;
    while J <= AHigh do
    begin
      Buffer[K] := ANames[J];
      Inc(J);
      Inc(K);
    end;
    for K := ALow to AHigh do
      ANames[K] := Buffer[K];
  end;

begin
  SetLength(Buffer, Length(ANames));
  Merge(0, High(ANames));
end;

function CanonicalJSON(AData: TJSONData): string;
var
  Names: TNameArray;
  I: Integer;
  Obj: TJSONObject;
begin
  case AData.JSONType of
    jtObject:
      begin
        Obj := TJSONObject(AData);
        SetLength(Names, Obj.Count);
        for I := 0 to Obj.Count - 1 do
          Names[I] := Obj.Names[I];
        SortNames(Names);
        Result := '{';
        for I := 0 to High(Names) do
        begin
          if I > 0 then
            Result := Result + ',';
          Result := Result + '"' + StringToJSONString(Names[I]) + '":' +
            CanonicalJSON(Obj.Elements[Names[I]]);
        end;
        Result := Result + '}';
      end;
    jtArray:
      begin
        Result := '[';
        for I := 0 to AData.Count - 1 do
        begin
          if I > 0 then
            Result := Result + ',';
          Result := Result + CanonicalJSON(AData.Items[I]);
        end;
        Result := Result + ']';
      end;
  else
    Result := AData.AsJSON;
  end;
end;

function ArgumentsDigest(AArguments: TJSONObject): string;
begin
  if AArguments = nil then
    Result := '{}'
  else
    Result := CanonicalJSON(AArguments);
  Result := Base64UrlEncode(DigestBytes(SHA256(Result)));
end;

constructor TMCPRequestStateSealer.Create(const AAudience: string;
  const AKeys: array of RawByteString; ATtlMs: Int64);
var
  I: Integer;
begin
  inherited Create;
  if Length(AKeys) = 0 then
    raise EMCPCrypto.Create('requestState sealing needs at least one key');
  SetLength(FKeys, Length(AKeys));
  for I := 0 to High(AKeys) do
  begin
    if AKeys[I] = '' then
      raise EMCPCrypto.Create('requestState keys must not be empty');
    FKeys[I] := AKeys[I];
  end;
  FAudience := AAudience;
  FTtlMs := ATtlMs;
end;

function TMCPRequestStateSealer.Tag(const AKey,
  ASigned: RawByteString): RawByteString;
begin
  Result := Base64UrlEncode(DigestBytes(HMACSHA256(AKey, ASigned)));
end;

function TMCPRequestStateSealer.Seal(const AMethod, ATarget: string;
  AArguments: TJSONObject; const AState: string): string;
var
  Envelope: TJSONObject;
  Now: Int64;
  Signed: RawByteString;
begin
  Now := UnixTimeMs;
  Envelope := TJSONObject.Create;
  try
    Envelope.Add('v', ENVELOPE_VERSION);
    Envelope.Add('iat', Now);
    Envelope.Add('exp', Now + FTtlMs);
    Envelope.Add('m', AMethod);
    Envelope.Add('t', ATarget);
    Envelope.Add('a', ArgumentsDigest(AArguments));
    Envelope.Add('aud', FAudience);
    Envelope.Add('s', AState);
    Signed := TOKEN_VERSION + '.' + Base64UrlEncode(CanonicalJSON(Envelope));
  finally
    Envelope.Free;
  end;
  Result := Signed + '.' + Tag(FKeys[0], Signed);
end;

// Splits 'v1.<payload>.<tag>' into its signed part and tag.
function SplitToken(const AToken: string; out ASigned, ATag: string): Boolean;
var
  LastDot: Integer;
begin
  Result := False;
  if Copy(AToken, 1, Length(TOKEN_VERSION) + 1) <> TOKEN_VERSION + '.' then
    Exit;
  LastDot := LastDelimiter('.', AToken);
  if LastDot <= Length(TOKEN_VERSION) + 1 then
    Exit;
  ASigned := Copy(AToken, 1, LastDot - 1);
  ATag := Copy(AToken, LastDot + 1, MaxInt);
  Result := (ATag <> '') and
    (Pos('.', Copy(ASigned, Length(TOKEN_VERSION) + 2, MaxInt)) = 0);
end;

// The envelope's member, or a failure reason.
function EnvelopeString(AEnvelope: TJSONObject; const AName: string;
  out AValue: string): Boolean;
var
  Data: TJSONData;
begin
  Data := AEnvelope.Find(AName);
  Result := (Data <> nil) and (Data.JSONType = jtString);
  if Result then
    AValue := Data.AsString;
end;

function EnvelopeInteger(AEnvelope: TJSONObject; const AName: string;
  out AValue: Int64): Boolean;
var
  Data: TJSONData;
begin
  Data := AEnvelope.Find(AName);
  Result := (Data <> nil) and (Data.JSONType = jtNumber) and
    (TJSONNumber(Data).NumberType in [ntInteger, ntInt64]);
  if Result then
    AValue := Data.AsInt64;
end;

// The payload is the UTF-8 JSON Seal wrote; parsed as bytes, the way
// MCP.Server parses schemas, so no code page conversion touches it.
function ParseEnvelope(const APayload: RawByteString): TJSONData;
var
  Parser: TJSONParser;
begin
  Parser := TJSONParser.Create(APayload, [joUTF8, joStrict]);
  try
    Result := Parser.Parse;
  finally
    Parser.Free;
  end;
end;

function TMCPRequestStateSealer.Unseal(const AMethod, ATarget: string;
  AArguments: TJSONObject; const AToken: string;
  out AState, AReason: string): Boolean;
var
  Signed, TagText, Field: string;
  Payload: RawByteString;
  Envelope: TJSONData;
  Obj: TJSONObject;
  Issued, Expires, Version, Now: Int64;
  I: Integer;
  Authentic: Boolean;
begin
  Result := False;
  AState := '';
  if not SplitToken(AToken, Signed, TagText) then
  begin
    AReason := 'malformed token';
    Exit;
  end;
  Authentic := False;
  for I := 0 to High(FKeys) do
    if ConstantTimeEqual(Tag(FKeys[I], Signed), TagText) then
      Authentic := True;
  if not Authentic then
  begin
    AReason := 'authentication tag does not verify';
    Exit;
  end;
  if not TryBase64UrlDecode(Copy(Signed, Length(TOKEN_VERSION) + 2, MaxInt),
    Payload) then
  begin
    AReason := 'malformed envelope';
    Exit;
  end;
  try
    Envelope := ParseEnvelope(Payload);
  except
    AReason := 'malformed envelope';
    Exit;
  end;
  try
    if Envelope.JSONType <> jtObject then
    begin
      AReason := 'malformed envelope';
      Exit;
    end;
    Obj := TJSONObject(Envelope);
    if not (EnvelopeInteger(Obj, 'v', Version) and
      (Version = ENVELOPE_VERSION) and EnvelopeInteger(Obj, 'iat', Issued) and
      EnvelopeInteger(Obj, 'exp', Expires) and
      EnvelopeString(Obj, 's', AState)) then
    begin
      AState := '';
      AReason := 'malformed envelope';
      Exit;
    end;
    Now := UnixTimeMs;
    if Issued > Now + FUTURE_SKEW_MS then
      AReason := 'issued in the future'
    else if Now >= Expires then
      AReason := 'expired'
    else if not (EnvelopeString(Obj, 'm', Field) and (Field = AMethod)) then
      AReason := 'bound to another method'
    else if not (EnvelopeString(Obj, 't', Field) and (Field = ATarget)) then
      AReason := 'bound to another target'
    else if not (EnvelopeString(Obj, 'a', Field) and
      (Field = ArgumentsDigest(AArguments))) then
      AReason := 'bound to other arguments'
    else if not (EnvelopeString(Obj, 'aud', Field) and (Field = FAudience)) then
      AReason := 'bound to another audience'
    else
      Result := True;
    if not Result then
      AState := '';
  finally
    Envelope.Free;
  end;
end;

end.
