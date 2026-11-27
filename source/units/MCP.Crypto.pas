unit MCP.Crypto;

// The small set of cryptographic primitives the library needs to
// integrity-protect requestState (#89), carried in-tree because FPC
// 3.2.2 ships no SHA-256: its `hash` package has HMAC with MD5 and
// SHA-1 only, and is not on the ADR-0003 list.
//
//   - SHA-256 (FIPS 180-4) and HMAC-SHA-256 (RFC 2104), checked against
//     the NIST example vectors and RFC 4231 in MCP.Crypto.Test;
//   - a constant-time comparison for authentication tags;
//   - cryptographically secure random bytes from the operating system
//     (/dev/urandom on Unix, RtlGenRandom on Windows);
//   - unpadded base64url (RFC 4648 section 5) for tokens on the wire.
//
// Strings here are byte strings: a character is one byte, and nothing
// is converted between code pages.

{$I MCP.inc}

interface

uses
  SysUtils;

type
  TSHA256Digest = array[0..31] of Byte;

  EMCPCrypto = class(Exception);

function SHA256(const AData: RawByteString): TSHA256Digest;
function HMACSHA256(const AKey, AData: RawByteString): TSHA256Digest;

// The digest's 32 bytes as a byte string.
function DigestBytes(const ADigest: TSHA256Digest): RawByteString;

// True when both byte strings are equal; the time taken depends only
// on their lengths, not on where they differ.
function ConstantTimeEqual(const A, B: RawByteString): Boolean;

// ACount bytes from the operating system's CSPRNG. Raises EMCPCrypto
// when the source is unavailable; callers fail closed.
function SecureRandomBytes(ACount: Integer): RawByteString;

function Base64UrlEncode(const AData: RawByteString): RawByteString;
// False when AText is not unpadded base64url.
function TryBase64UrlDecode(const AText: RawByteString;
  out AData: RawByteString): Boolean;

implementation

{$IFDEF WINDOWS}
uses
  Windows;

// advapi32's RtlGenRandom, exported as SystemFunction036.
function RtlGenRandom(RandomBuffer: Pointer;
  RandomBufferLength: ULONG): BOOLEAN; stdcall;
  external 'advapi32.dll' name 'SystemFunction036';
{$ENDIF}

const
  K: array[0..63] of Cardinal = (
    $428a2f98, $71374491, $b5c0fbcf, $e9b5dba5, $3956c25b, $59f111f1,
    $923f82a4, $ab1c5ed5, $d807aa98, $12835b01, $243185be, $550c7dc3,
    $72be5d74, $80deb1fe, $9bdc06a7, $c19bf174, $e49b69c1, $efbe4786,
    $0fc19dc6, $240ca1cc, $2de92c6f, $4a7484aa, $5cb0a9dc, $76f988da,
    $983e5152, $a831c66d, $b00327c8, $bf597fc7, $c6e00bf3, $d5a79147,
    $06ca6351, $14292967, $27b70a85, $2e1b2138, $4d2c6dfc, $53380d13,
    $650a7354, $766a0abb, $81c2c92e, $92722c85, $a2bfe8a1, $a81a664b,
    $c24b8b70, $c76c51a3, $d192e819, $d6990624, $f40e3585, $106aa070,
    $19a4c116, $1e376c08, $2748774c, $34b0bcb5, $391c0cb3, $4ed8aa4a,
    $5b9cca4f, $682e6ff3, $748f82ee, $78a5636f, $84c87814, $8cc70208,
    $90befffa, $a4506ceb, $bef9a3f7, $c67178f2);

  BASE64URL_ALPHABET =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

type
  TSHA256State = array[0..7] of Cardinal;

// SHA-256 adds modulo 2^32. The sums are taken in 64 bits and masked,
// so the compiler's overflow and range checks stay on (MCP.inc) and
// still catch an unintended overflow anywhere else.
function Add32(A, B: Cardinal): Cardinal; overload; inline;
begin
  Result := Cardinal((QWord(A) + QWord(B)) and $FFFFFFFF);
end;

function Add32(A, B, C, D, E: Cardinal): Cardinal; overload; inline;
begin
  Result := Cardinal((QWord(A) + QWord(B) + QWord(C) + QWord(D) +
    QWord(E)) and $FFFFFFFF);
end;

function RotR(AValue: Cardinal; ABits: Byte): Cardinal; inline;
begin
  // Shifts drop the bits past 32 by definition; the mask keeps the
  // left shift inside Cardinal for the range check.
  Result := (AValue shr ABits) or
    Cardinal((QWord(AValue) shl (32 - ABits)) and $FFFFFFFF);
end;

procedure Compress(var AState: TSHA256State; ABlock: PByte);
var
  W: array[0..63] of Cardinal;
  A, B, C, D, E, F, G, H, S0, S1, T1, T2: Cardinal;
  I: Integer;
begin
  for I := 0 to 15 do
    W[I] := (Cardinal(ABlock[I * 4]) shl 24) or
      (Cardinal(ABlock[I * 4 + 1]) shl 16) or
      (Cardinal(ABlock[I * 4 + 2]) shl 8) or Cardinal(ABlock[I * 4 + 3]);
  for I := 16 to 63 do
  begin
    S0 := RotR(W[I - 15], 7) xor RotR(W[I - 15], 18) xor (W[I - 15] shr 3);
    S1 := RotR(W[I - 2], 17) xor RotR(W[I - 2], 19) xor (W[I - 2] shr 10);
    W[I] := Add32(Add32(W[I - 16], S0), Add32(W[I - 7], S1));
  end;
  A := AState[0]; B := AState[1]; C := AState[2]; D := AState[3];
  E := AState[4]; F := AState[5]; G := AState[6]; H := AState[7];
  for I := 0 to 63 do
  begin
    S1 := RotR(E, 6) xor RotR(E, 11) xor RotR(E, 25);
    T1 := Add32(H, S1, (E and F) xor ((not E) and G), K[I], W[I]);
    S0 := RotR(A, 2) xor RotR(A, 13) xor RotR(A, 22);
    T2 := Add32(S0, (A and B) xor (A and C) xor (B and C));
    H := G; G := F; F := E; E := Add32(D, T1);
    D := C; C := B; B := A; A := Add32(T1, T2);
  end;
  AState[0] := Add32(AState[0], A); AState[1] := Add32(AState[1], B);
  AState[2] := Add32(AState[2], C); AState[3] := Add32(AState[3], D);
  AState[4] := Add32(AState[4], E); AState[5] := Add32(AState[5], F);
  AState[6] := Add32(AState[6], G); AState[7] := Add32(AState[7], H);
end;

function SHA256(const AData: RawByteString): TSHA256Digest;
const
  INITIAL: TSHA256State = ($6a09e667, $bb67ae85, $3c6ef372, $a54ff53a,
    $510e527f, $9b05688c, $1f83d9ab, $5be0cd19);
var
  State: TSHA256State;
  Padded: RawByteString;
  BitLength: QWord;
  Offset, I: Integer;
begin
  State := INITIAL;
  // Message, a 0x80 byte, zeros up to 56 mod 64, then the 64-bit
  // big-endian bit length.
  // Built by byte writes: string concatenation would let FPC
  // transcode the bytes to the system code page (#89 review).
  BitLength := QWord(Length(AData)) * 8;
  SetLength(Padded, ((Length(AData) + 8) div 64 + 1) * 64);
  FillChar(Padded[1], Length(Padded), 0);
  if Length(AData) > 0 then
    Move(AData[1], Padded[1], Length(AData));
  Padded[Length(AData) + 1] := AnsiChar($80);
  for I := 0 to 7 do
    Padded[Length(Padded) - I] := AnsiChar(Byte(BitLength shr (I * 8)));
  Offset := 1;
  while Offset <= Length(Padded) do
  begin
    Compress(State, PByte(@Padded[Offset]));
    Inc(Offset, 64);
  end;
  for I := 0 to 7 do
  begin
    Result[I * 4] := Byte(State[I] shr 24);
    Result[I * 4 + 1] := Byte(State[I] shr 16);
    Result[I * 4 + 2] := Byte(State[I] shr 8);
    Result[I * 4 + 3] := Byte(State[I]);
  end;
end;

function DigestBytes(const ADigest: TSHA256Digest): RawByteString;
begin
  SetLength(Result, SizeOf(ADigest));
  Move(ADigest[0], Result[1], SizeOf(ADigest));
end;

// A followed by B as bytes, without any code page conversion.
function JoinBytes(const A, B: RawByteString): RawByteString;
begin
  SetLength(Result, Length(A) + Length(B));
  if Length(A) > 0 then
    Move(A[1], Result[1], Length(A));
  if Length(B) > 0 then
    Move(B[1], Result[Length(A) + 1], Length(B));
end;

function HMACSHA256(const AKey, AData: RawByteString): TSHA256Digest;
const
  BLOCK_SIZE = 64;
var
  Key, InnerPad, OuterPad: RawByteString;
  I: Integer;
begin
  // RFC 2104: a key longer than the block is hashed first, a shorter
  // one is zero-padded to the block.
  if Length(AKey) > BLOCK_SIZE then
    Key := DigestBytes(SHA256(AKey))
  else
    Key := AKey;
  SetLength(InnerPad, BLOCK_SIZE);
  SetLength(OuterPad, BLOCK_SIZE);
  for I := 1 to BLOCK_SIZE do
  begin
    if I <= Length(Key) then
    begin
      InnerPad[I] := AnsiChar(Byte(Key[I]) xor $36);
      OuterPad[I] := AnsiChar(Byte(Key[I]) xor $5C);
    end
    else
    begin
      InnerPad[I] := AnsiChar($36);
      OuterPad[I] := AnsiChar($5C);
    end;
  end;
  Result := SHA256(JoinBytes(OuterPad,
    DigestBytes(SHA256(JoinBytes(InnerPad, AData)))));
end;

function ConstantTimeEqual(const A, B: RawByteString): Boolean;
var
  Diff: Byte;
  I: Integer;
begin
  if Length(A) <> Length(B) then
    Exit(False);
  Diff := 0;
  for I := 1 to Length(A) do
    Diff := Diff or (Byte(A[I]) xor Byte(B[I]));
  Result := Diff = 0;
end;

function SecureRandomBytes(ACount: Integer): RawByteString;
{$IFNDEF WINDOWS}
var
  Source: THandle;
  Got, Total: LongInt;
{$ENDIF}
begin
  Result := '';
  if ACount <= 0 then
    Exit;
  SetLength(Result, ACount);
  {$IFDEF WINDOWS}
  if not RtlGenRandom(@Result[1], ACount) then
    raise EMCPCrypto.Create('RtlGenRandom failed');
  {$ELSE}
  Source := FileOpen('/dev/urandom', fmOpenRead or fmShareDenyNone);
  if Source = THandle(-1) then
    raise EMCPCrypto.Create('cannot open /dev/urandom');
  try
    Total := 0;
    while Total < ACount do
    begin
      Got := FileRead(Source, Result[Total + 1], ACount - Total);
      if Got <= 0 then
        raise EMCPCrypto.Create('cannot read /dev/urandom');
      Inc(Total, Got);
    end;
  finally
    FileClose(Source);
  end;
  {$ENDIF}
end;

function Base64UrlEncode(const AData: RawByteString): RawByteString;
var
  I, Remaining: Integer;
  Triple: Cardinal;
begin
  Result := '';
  I := 1;
  while I <= Length(AData) do
  begin
    Remaining := Length(AData) - I + 1;
    Triple := Cardinal(Byte(AData[I])) shl 16;
    if Remaining > 1 then
      Triple := Triple or (Cardinal(Byte(AData[I + 1])) shl 8);
    if Remaining > 2 then
      Triple := Triple or Cardinal(Byte(AData[I + 2]));
    Result := Result + BASE64URL_ALPHABET[(Triple shr 18) and 63 + 1] +
      BASE64URL_ALPHABET[(Triple shr 12) and 63 + 1];
    if Remaining > 1 then
      Result := Result + BASE64URL_ALPHABET[(Triple shr 6) and 63 + 1];
    if Remaining > 2 then
      Result := Result + BASE64URL_ALPHABET[Triple and 63 + 1];
    Inc(I, 3);
  end;
end;

function Base64UrlValue(ACharacter: AnsiChar): Integer;
begin
  case ACharacter of
    'A'..'Z': Result := Ord(ACharacter) - Ord('A');
    'a'..'z': Result := Ord(ACharacter) - Ord('a') + 26;
    '0'..'9': Result := Ord(ACharacter) - Ord('0') + 52;
    '-': Result := 62;
    '_': Result := 63;
  else
    Result := -1;
  end;
end;

function TryBase64UrlDecode(const AText: RawByteString;
  out AData: RawByteString): Boolean;
var
  I, Value, Bits, Buffer: Integer;
begin
  AData := '';
  // A single leftover character carries fewer than 8 bits.
  if Length(AText) mod 4 = 1 then
    Exit(False);
  Bits := 0;
  Buffer := 0;
  for I := 1 to Length(AText) do
  begin
    Value := Base64UrlValue(AText[I]);
    if Value < 0 then
      Exit(False);
    Buffer := ((Buffer shl 6) or Value) and $FFFFFF;
    Inc(Bits, 6);
    if Bits >= 8 then
    begin
      Dec(Bits, 8);
      AData := AData + AnsiChar(Byte(Buffer shr Bits));
    end;
  end;
  // Leftover bits must be zero, so each byte string has one encoding.
  Result := (Buffer and ((1 shl Bits) - 1)) = 0;
end;

end.
