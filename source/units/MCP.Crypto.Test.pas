{ MCP.Crypto.Test — SHA-256 against the FIPS 180-4 example vectors
  (including the padding boundaries at 55, 56 and 64 bytes), HMAC-SHA-256
  against RFC 4231, base64url against RFC 4648 section 10, constant-time
  comparison, and the CSPRNG's shape. Expected digests are written out
  literally from the standards, never recomputed. }

program MCP.Crypto.Test;

{$I MCP.inc}

uses
  SysUtils,

  MCP.Crypto,
  TestingPascalLibrary;

type
  TSHA256Vectors = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestEmpty;
    procedure TestAbc;
    procedure TestTwoBlockMessage;
    procedure TestMillionA;
    procedure TestPaddingBoundaries;
    procedure TestIndependentOfCodePage;
  end;

  THMACVectors = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestCase1;
    procedure TestCase2;
    procedure TestCase3;
    procedure TestCase6LongKey;
    procedure TestCase7LongKeyAndData;
  end;

  THelpers = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestBase64UrlVectors;
    procedure TestBase64UrlAlphabet;
    procedure TestBase64UrlRejects;
    procedure TestConstantTimeEqual;
    procedure TestSecureRandomBytes;
  end;

function Hex(const ADigest: TSHA256Digest): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(ADigest) do
    Result := Result + LowerCase(IntToHex(ADigest[I], 2));
end;

function Repeated(AByte: Byte; ACount: Integer): RawByteString;
begin
  SetLength(Result, ACount);
  if ACount > 0 then
    FillChar(Result[1], ACount, AByte);
end;

{ SHA-256 }

procedure TSHA256Vectors.TestEmpty;
begin
  Expect<string>(Hex(SHA256(''))).ToBe(
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
end;

procedure TSHA256Vectors.TestAbc;
begin
  Expect<string>(Hex(SHA256('abc'))).ToBe(
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
end;

procedure TSHA256Vectors.TestTwoBlockMessage;
begin
  Expect<string>(Hex(SHA256(
    'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'))).ToBe(
    '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
end;

procedure TSHA256Vectors.TestMillionA;
begin
  Expect<string>(Hex(SHA256(Repeated(Ord('a'), 1000000)))).ToBe(
    'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0');
end;

procedure TSHA256Vectors.TestPaddingBoundaries;
begin
  // 55 bytes fit the length in one block; 56 and 64 need a second.
  Expect<string>(Hex(SHA256(Repeated(Ord('a'), 55)))).ToBe(
    '9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318');
  Expect<string>(Hex(SHA256(Repeated(Ord('a'), 56)))).ToBe(
    'b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a');
  Expect<string>(Hex(SHA256(Repeated(Ord('a'), 64)))).ToBe(
    'ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb');
end;

// Known answers (FIPS 180-4, RFC 4231) with UTF8String input while the
// system code page is US-ASCII. The process-locale case (#89 review:
// under LC_ALL=C the padding was transcoded) is not reproducible in
// process; mcpsmoke checks a sealed digest, and CI runs it under
// LC_ALL=C.
procedure TSHA256Vectors.TestIndependentOfCodePage;
var
  Saved: TSystemCodePage;
  Braces, Abc, HiThere: UTF8String;
  EmptyObject, AbcDigest, HmacDigest: string;
begin
  Braces := '{}';
  Abc := 'abc';
  HiThere := 'Hi There';
  Saved := DefaultSystemCodePage;
  try
    DefaultSystemCodePage := 20127; // US-ASCII, as under LC_ALL=C
    EmptyObject := Hex(SHA256(Braces));
    AbcDigest := Hex(SHA256(Abc));
    HmacDigest := Hex(HMACSHA256(Repeated($0B, 20), HiThere));
  finally
    DefaultSystemCodePage := Saved;
  end;
  Expect<string>(EmptyObject).ToBe(
    '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a');
  Expect<string>(AbcDigest).ToBe(
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  Expect<string>(HmacDigest).ToBe(
    'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7');
end;

procedure TSHA256Vectors.SetupTests;
begin
  Test('empty message', TestEmpty);
  Test('"abc"', TestAbc);
  Test('448-bit two-block message', TestTwoBlockMessage);
  Test('one million "a"', TestMillionA);
  Test('padding boundaries at 55, 56 and 64 bytes', TestPaddingBoundaries);
  Test('the same digests under a US-ASCII system code page',
    TestIndependentOfCodePage);
end;

{ HMAC-SHA-256, RFC 4231 section 4 }

procedure THMACVectors.TestCase1;
begin
  Expect<string>(Hex(HMACSHA256(Repeated($0B, 20), 'Hi There'))).ToBe(
    'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7');
end;

procedure THMACVectors.TestCase2;
begin
  Expect<string>(Hex(HMACSHA256('Jefe', 'what do ya want for nothing?')))
    .ToBe('5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843');
end;

procedure THMACVectors.TestCase3;
begin
  Expect<string>(Hex(HMACSHA256(Repeated($AA, 20), Repeated($DD, 50))))
    .ToBe('773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe');
end;

procedure THMACVectors.TestCase6LongKey;
begin
  Expect<string>(Hex(HMACSHA256(Repeated($AA, 131),
    'Test Using Larger Than Block-Size Key - Hash Key First'))).ToBe(
    '60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54');
end;

procedure THMACVectors.TestCase7LongKeyAndData;
begin
  Expect<string>(Hex(HMACSHA256(Repeated($AA, 131),
    'This is a test using a larger than block-size key and a larger ' +
    'than block-size data. The key needs to be hashed before being ' +
    'used by the HMAC algorithm.'))).ToBe(
    '9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2');
end;

procedure THMACVectors.SetupTests;
begin
  Test('RFC 4231 test case 1', TestCase1);
  Test('RFC 4231 test case 2', TestCase2);
  Test('RFC 4231 test case 3', TestCase3);
  Test('RFC 4231 test case 6 (key longer than a block)', TestCase6LongKey);
  Test('RFC 4231 test case 7 (long key and data)', TestCase7LongKeyAndData);
end;

{ helpers }

procedure THelpers.TestBase64UrlVectors;
const
  PLAIN: array[0..6] of string = ('', 'f', 'fo', 'foo', 'foob', 'fooba', 'foobar');
  ENCODED: array[0..6] of string =
    ('', 'Zg', 'Zm8', 'Zm9v', 'Zm9vYg', 'Zm9vYmE', 'Zm9vYmFy');
var
  I: Integer;
  Decoded: RawByteString;
begin
  for I := 0 to High(PLAIN) do
  begin
    Expect<string>(Base64UrlEncode(PLAIN[I])).ToBe(ENCODED[I]);
    Expect<Boolean>(TryBase64UrlDecode(ENCODED[I], Decoded)).ToBe(True);
    Expect<string>(Decoded).ToBe(PLAIN[I]);
  end;
end;

procedure THelpers.TestBase64UrlAlphabet;
var
  Decoded: RawByteString;
begin
  // 0xFB 0xFF is "+/8=" in standard base64; base64url uses - and _
  // and drops the padding.
  Expect<string>(Base64UrlEncode(#$FB#$FF)).ToBe('-_8');
  Expect<Boolean>(TryBase64UrlDecode('-_8', Decoded)).ToBe(True);
  Expect<string>(Decoded).ToBe(#$FB#$FF);
end;

procedure THelpers.TestBase64UrlRejects;
var
  Decoded: RawByteString;
begin
  Expect<Boolean>(TryBase64UrlDecode('Zg==', Decoded)).ToBe(False);
  Expect<Boolean>(TryBase64UrlDecode('Zm9v+', Decoded)).ToBe(False);
  Expect<Boolean>(TryBase64UrlDecode('Z', Decoded)).ToBe(False);
  // Non-zero leftover bits: a second spelling of "f".
  Expect<Boolean>(TryBase64UrlDecode('Zh', Decoded)).ToBe(False);
end;

procedure THelpers.TestConstantTimeEqual;
begin
  Expect<Boolean>(ConstantTimeEqual('', '')).ToBe(True);
  Expect<Boolean>(ConstantTimeEqual('abc', 'abc')).ToBe(True);
  Expect<Boolean>(ConstantTimeEqual('abc', 'abd')).ToBe(False);
  Expect<Boolean>(ConstantTimeEqual('abc', 'ab')).ToBe(False);
  Expect<Boolean>(ConstantTimeEqual(#$80#0, #$80#1)).ToBe(False);
end;

procedure THelpers.TestSecureRandomBytes;
var
  A, B: RawByteString;
begin
  A := SecureRandomBytes(32);
  B := SecureRandomBytes(32);
  Expect<Integer>(Length(A)).ToBe(32);
  Expect<Integer>(Length(B)).ToBe(32);
  // 2^-256 chance of a false failure.
  Expect<Boolean>(A = B).ToBe(False);
  Expect<string>(SecureRandomBytes(0)).ToBe('');
end;

procedure THelpers.SetupTests;
begin
  Test('base64url: RFC 4648 section 10 vectors', TestBase64UrlVectors);
  Test('base64url: URL-safe alphabet, no padding', TestBase64UrlAlphabet);
  Test('base64url: padding, foreign characters and stray bits rejected',
    TestBase64UrlRejects);
  Test('constant-time comparison', TestConstantTimeEqual);
  Test('secure random bytes: length and distinct draws',
    TestSecureRandomBytes);
end;

begin
  TestRunnerProgram.AddSuite(TSHA256Vectors.Create('Crypto: SHA-256'));
  TestRunnerProgram.AddSuite(THMACVectors.Create('Crypto: HMAC-SHA-256'));
  TestRunnerProgram.AddSuite(THelpers.Create('Crypto: helpers'));
  TestRunnerProgram.Run;
end.
