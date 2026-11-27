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
    // arguments; AArguments is borrowed and may be nil for none).
    function Seal(const AMethod, ATarget: string; AArguments: TJSONObject;
      const AState: string): string;
    // True with the handler's AState when AToken verifies for this
    // request; False with a log-only AReason otherwise. AArguments is
    // borrowed and may be nil.
    function Unseal(const AMethod, ATarget: string; AArguments: TJSONObject;
      const AToken: string; out AState, AReason: string): Boolean;
  end;

// JSON with object members sorted by name (UTF-8 byte order), no
// insignificant whitespace, strings as their UTF-8 bytes and equal
// numbers spelled alike, so equal values digest equally on any host
// code page. AData is borrowed.
function CanonicalJSON(AData: TJSONData): UTF8String;

// Milliseconds since the Unix epoch, UTC.
function UnixTimeMs: Int64;

implementation

// MCP.JSONRPC installs the UTF-8 string conversion every unit that
// moves JSON strings through `string` relies on (cwstring on Unix,
// fpwidestring plus CP_UTF8 on Windows); without it a non-ASCII state
// would come back in the system code page.
uses
  DateUtils,
  Math,

  jsonparser,
  jsonscanner,
  MCP.Crypto,
  MCP.JSONRPC,
  MCP.Schema;

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
  TIndexArray = array of Integer;

// Byte order of two UTF-8 strings, without any code page conversion
// (CompareStr would convert to the system code page first).
function CompareBytes(const A, B: UTF8String): Integer;
var
  I, Count: Integer;
begin
  Count := Length(A);
  if Length(B) < Count then
    Count := Length(B);
  for I := 1 to Count do
    if A[I] <> B[I] then
      Exit(Ord(A[I]) - Ord(B[I]));
  Result := Length(A) - Length(B);
end;

// Member indices of AObject ordered by name bytes. Merge sort: O(n log
// n) in the worst case, since the names come from client arguments of
// any width.
function SortedMembers(AObject: TJSONObject): TIndexArray;
var
  Names: array of UTF8String;
  Buffer: TIndexArray;

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
    while (I <= Mid) or (J <= AHigh) do
    begin
      if (J > AHigh) or ((I <= Mid) and
        (CompareBytes(Names[Result[I]], Names[Result[J]]) <= 0)) then
      begin
        Buffer[K] := Result[I];
        Inc(I);
      end
      else
      begin
        Buffer[K] := Result[J];
        Inc(J);
      end;
      Inc(K);
    end;
    for K := ALow to AHigh do
      Result[K] := Buffer[K];
  end;

var
  I: Integer;
begin
  SetLength(Names, AObject.Count);
  SetLength(Result, AObject.Count);
  SetLength(Buffer, AObject.Count);
  for I := 0 to AObject.Count - 1 do
  begin
    Names[I] := AObject.Names[I];
    Result[I] := I;
  end;
  Merge(0, AObject.Count - 1);
end;

// A JSON string literal of the UTF-8 bytes in AValue: quote, backslash
// and control characters escaped, every other byte as it is. Explicit,
// so neither the system code page nor fpjson's process-wide escaping
// settings change a digest.
function QuotedUTF8(const AValue: UTF8String): UTF8String;
const
  HEX: array[0..15] of AnsiChar = '0123456789abcdef';
var
  I: Integer;
  C: AnsiChar;
begin
  Result := '"';
  for I := 1 to Length(AValue) do
  begin
    C := AValue[I];
    if C = '"' then
      Result := Result + '\"'
    else if C = '\' then
      Result := Result + '\\'
    else if Ord(C) < $20 then
      Result := Result + '\u00' + HEX[Ord(C) shr 4] + HEX[Ord(C) and 15]
    else
      Result := Result + C;
  end;
  Result := Result + '"';
end;

// The decimal digits of an integral double of magnitude below 2^64,
// read from its bits: no float-to-integer conversion, which can trap
// on AArch64. False when the magnitude is 2^64 or more.
function IntegralDoubleDigits(AValue: Double; out ADigits: UTF8String): Boolean;
var
  Bits, Mantissa, Magnitude: QWord;
  Exponent: Integer;
begin
  Move(AValue, Bits, SizeOf(Bits));
  Exponent := Integer((Bits shr 52) and $7FF) - 1075;
  Mantissa := (Bits and $FFFFFFFFFFFFF) or (QWord(1) shl 52);
  if (Bits and $7FFFFFFFFFFFFFFF) = 0 then
    Magnitude := 0
  else if Exponent >= 0 then
  begin
    if Exponent > 11 then
      Exit(False);
    Magnitude := Mantissa shl Exponent;
  end
  else
    Magnitude := Mantissa shr (-Exponent);
  ADigits := UTF8String(IntToStr(Magnitude));
  if (Magnitude <> 0) and (AValue < 0) then
    ADigits := '-' + ADigits;
  Result := True;
end;

// Equal numbers spell the same: an integral value as its exact
// integer digits (2, 2.0 and 2e0 alike, and 1e16 as the integer
// 10000000000000000), any other as JavaScript writes it (MCPWireNumber).
function CanonicalNumber(AValue: TJSONData): UTF8String;
var
  F: Double;
  Wire: TJSONData;
begin
  case TJSONNumber(AValue).NumberType of
    ntInteger, ntInt64:
      Exit(UTF8String(IntToStr(AValue.AsInt64)));
    ntQWord:
      Exit(UTF8String(IntToStr(AValue.AsQWord)));
  end;
  F := AValue.AsFloat;
  if not IsNan(F) and not IsInfinite(F) and
    ((Abs(F) >= 4503599627370496.0) or (Frac(F) = 0)) and
    IntegralDoubleDigits(F, Result) then
    Exit;
  Wire := MCPWireNumber(F);
  try
    Result := UTF8String(Wire.AsJSON);
  finally
    Wire.Free;
  end;
end;

function CanonicalJSON(AData: TJSONData): UTF8String;
var
  Order: TIndexArray;
  I: Integer;
  Obj: TJSONObject;
begin
  case AData.JSONType of
    jtObject:
      begin
        Obj := TJSONObject(AData);
        Order := SortedMembers(Obj);
        Result := '{';
        for I := 0 to High(Order) do
        begin
          if I > 0 then
            Result := Result + ',';
          Result := Result + QuotedUTF8(Obj.Names[Order[I]]) + ':' +
            CanonicalJSON(Obj.Items[Order[I]]);
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
    jtString:
      Result := QuotedUTF8(TJSONString(AData).AsString);
    jtNumber:
      Result := CanonicalNumber(AData);
  else
    Result := UTF8String(AData.AsJSON);
  end;
end;

// The canonical bytes go straight to SHA-256, never through a `string`
// in the system code page. The result is base64url, plain ASCII.
function ArgumentsDigest(AArguments: TJSONObject): string;
var
  Canonical: UTF8String;
begin
  if AArguments = nil then
    Canonical := '{}'
  else
    Canonical := CanonicalJSON(AArguments);
  Result := Base64UrlEncode(DigestBytes(SHA256(Canonical)));
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
