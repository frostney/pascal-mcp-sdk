{ MCP.Subscriptions.Test — subscriptions/listen (#138): -32601 without a
  source, the request checks (-32602 for a missing filter or a fractional
  id, -32603 without a stream host, -32601 for a classic client), the
  acknowledgment first with only what was agreed, the subscription id on
  every frame (integer and string ids), the completion result that ends
  a stream, nothing after a cancellation, and the registration guards.
  Shapes verified 2026-11-28 against
  https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/subscriptions. }

program MCP.Subscriptions.Test;

{$I MCP.inc}

uses
  SysUtils,

  fpjson,
  MCP.JSONRPC,
  MCP.Protocol,
  MCP.Server,
  MCP.Streams,
  MCP.Subscriptions,
  TestingPascalLibrary;

const
  META =
    '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":{}}';
  SUB7 = '"_meta" : { "io.modelcontextprotocol/subscriptionId" : 7 }';

var
  Captured: string;

// The streams' clock in these tests: fixed, so a due time is exact.
function TestClock: Int64;
begin
  Result := 5000;
end;

type
  // Sends "ticks" notifications: as many as the filter's number, one per
  // poll, each with a non-ASCII label.
  TTickFeed = class(TMCPSubscriptionFeed)
  private
    FLeft, FSent: Integer;
  public
    procedure Collect(AOut: TJSONArray); override;
  end;

  TTickSource = class(TMCPSubscriptionSource)
  private
    FKey: string;
  public
    constructor Create(const AKey: string = 'ticks');
    function FilterKey: string; override;
    function Agree(AValue: TJSONData;
      const ACtx: TMCPRequestContext): TJSONData; override;
    function Open(AAgreed: TJSONData;
      const ACtx: TMCPRequestContext): TMCPSubscriptionFeed; override;
  end;

  TListenSuite = class(TTestSuite)
  private
    FServer: TMCPServer;
    FSession: TMCPSession;
    FHost: TMCPStreamHost;
    FStream: TMCPStream;
    function Listen(const AParams: string; const AId: string = '7'): string;
    function Step: Int64;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;
    procedure TestNoSource;
    procedure TestRequestChecks;
    procedure TestAcknowledgmentFirst;
    procedure TestNotifications;
    procedure TestStringIdAndClose;
    procedure TestCancelled;
    procedure TestNothingAgreed;
    procedure TestGuards;
    procedure TestCoreFieldTypes;
    procedure TestQuietStreamAndListenerCap;
  end;

procedure CaptureSink(const ALine: string; AUserData: Pointer);
begin
  Captured := Captured + ALine + #10;
end;

procedure TTickFeed.Collect(AOut: TJSONArray);
begin
  if FSent >= FLeft then
    Exit;
  Inc(FSent);
  AOut.Add(TJSONObject.Create(['method', 'notifications/ticks', 'params',
    TJSONObject.Create(['n', FSent, 'label', 'Gr' + #$C3#$BC + #$C3#$9F +
    'e'])]));
end;

constructor TTickSource.Create(const AKey: string);
begin
  inherited Create;
  FKey := AKey;
end;

function TTickSource.FilterKey: string;
begin
  Result := FKey;
end;

// A positive count is agreed, zero is left out, anything else refused.
function TTickSource.Agree(AValue: TJSONData;
  const ACtx: TMCPRequestContext): TJSONData;
begin
  if AValue.JSONType <> jtNumber then
    raise EMCPProtocolError.Create(JSONRPC_INVALID_PARAMS,
      'Invalid params: ticks must be a number');
  if AValue.AsInteger = 0 then
    Exit(nil);
  Result := TJSONIntegerNumber.Create(AValue.AsInteger);
end;

function TTickSource.Open(AAgreed: TJSONData;
  const ACtx: TMCPRequestContext): TMCPSubscriptionFeed;
begin
  Result := TTickFeed.Create;
  TTickFeed(Result).FLeft := AAgreed.AsInteger;
end;

procedure TListenSuite.BeforeEach;
begin
  Captured := '';
  MCPStreamClock := @TestClock;
  FServer := TMCPServer.Create('listen', '1.0');
  FSession := nil;
  FHost := TMCPStreamHost.Create;
  FStream := nil;
end;

procedure TListenSuite.AfterEach;
begin
  MCPStreamClock := nil;
  FreeAndNil(FStream);
  FreeAndNil(FSession);
  FreeAndNil(FHost);
  FreeAndNil(FServer);
end;

function TListenSuite.Listen(const AParams, AId: string): string;
begin
  if FSession = nil then
  begin
    FSession := FServer.CreateSession;
    FSession.StreamHost := FHost;
  end;
  FServer.HandleMessage(FSession, '{"jsonrpc":"2.0","id":' + AId +
    ',"method":"subscriptions/listen","params":{' + AParams + META + '}}',
    CaptureSink, nil, Result);
  FreeAndNil(FStream);
  FStream := FHost.TakeParked;
end;

function TListenSuite.Step: Int64;
begin
  Captured := '';
  Result := FStream.Step(CaptureSink, nil);
end;

procedure TListenSuite.TestNoSource;
begin
  Expect<string>(Listen('"notifications":{},')).ToBe('{ "jsonrpc" : "2.0", ' +
    '"id" : 7, "error" : { "code" : -32601, "message" : "Method not found: ' +
    'subscriptions/listen" } }');
  Expect<Boolean>(FStream = nil).ToBe(True);
end;

procedure TListenSuite.TestRequestChecks;
var
  Session: TMCPSession;
  Line: string;
begin
  AddSubscriptionSource(FServer, TTickSource.Create);
  Expect<Boolean>(Pos('"code" : -32602', Listen('')) > 0).ToBe(True);
  Expect<Boolean>(Pos('"code" : -32602', Listen('"notifications":[],')) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('"code" : -32602', Listen('"notifications":{},',
    '7.5')) > 0).ToBe(True);
  // An integral number written with a fraction is an integer id.
  Expect<Boolean>(Pos('"result"', Listen('"notifications":{},', '2.0')) > 0)
    .ToBe(True);
  Expect<Boolean>(FStream <> nil).ToBe(True);
  FreeAndNil(FStream);
  Expect<Boolean>(FStream = nil).ToBe(True);
  // A refusal from a source answers the request; no stream.
  Expect<Boolean>(Pos('"message" : "Invalid params: ticks must be a number"',
    Listen('"notifications":{"ticks":"x"},')) > 0).ToBe(True);
  Expect<Boolean>(FStream = nil).ToBe(True);
  // A session that cannot stream.
  Session := FServer.CreateSession;
  try
    FServer.HandleMessage(Session, '{"jsonrpc":"2.0","id":1,"method":' +
      '"subscriptions/listen","params":{"notifications":{},' + META + '}}',
      Line);
    Expect<string>(Line).ToBe('{ "jsonrpc" : "2.0", "id" : 1, "error" : ' +
      '{ "code" : -32603, "message" : "subscriptions/listen needs a ' +
      'transport that can stream" } }');
  finally
    Session.Free;
  end;
  // A classic client.
  Session := FServer.CreateSession;
  try
    FServer.HandleMessage(Session, '{"jsonrpc":"2.0","id":1,"method":' +
      '"initialize","params":{"protocolVersion":"2025-11-25",' +
      '"capabilities":{},"clientInfo":{"name":"c","version":"1"}}}', Line);
    FServer.HandleMessage(Session, '{"jsonrpc":"2.0","method":' +
      '"notifications/initialized"}', Line);
    FServer.HandleMessage(Session, '{"jsonrpc":"2.0","id":2,"method":' +
      '"subscriptions/listen","params":{"notifications":{}}}', Line);
    Expect<string>(Line).ToBe('{ "jsonrpc" : "2.0", "id" : 2, "error" : ' +
      '{ "code" : -32601, "message" : "Method not found: ' +
      'subscriptions/listen" } }');
  finally
    Session.Free;
  end;
end;

// The acknowledgment is the first frame, and names only what was agreed:
// not the core's list changes or resource subscriptions, nor keys no
// source serves.
procedure TListenSuite.TestAcknowledgmentFirst;
var
  Response: string;
begin
  AddSubscriptionSource(FServer, TTickSource.Create);
  Response := Listen('"notifications":{"toolsListChanged":true,' +
    '"resourceSubscriptions":["test://x"],"other":true,"ticks":2},');
  // The core answers a placeholder, which a transport drops for a
  // parked stream (MCPTakeStream).
  Expect<string>(Response).ToBe('{ "jsonrpc" : "2.0", "id" : 7, "result" : ' +
    '{ "resultType" : "complete", "_meta" : { ' +
    '"io.modelcontextprotocol/serverInfo" : { "name" : "listen", ' +
    '"version" : "1.0" } } } }');
  Expect<Boolean>(FStream <> nil).ToBe(True);
  Step;
  Expect<string>(Copy(Captured, 1, Pos(#10, Captured))).ToBe(
    '{ "jsonrpc" : "2.0", "method" : ' +
    '"notifications/subscriptions/acknowledged", "params" : { ' +
    '"notifications" : { "ticks" : 2 }, ' + SUB7 + ' } }'#10);
end;

procedure TListenSuite.TestNotifications;
begin
  AddSubscriptionSource(FServer, TTickSource.Create);
  Listen('"notifications":{"ticks":2},');
  Expect<Int64>(Step).ToBe(5000 + MCP_SUBSCRIPTION_POLL_MS);
  // The first poll after the acknowledgment, byte-exact.
  Expect<string>(Copy(Captured, Pos(#10, Captured) + 1, MaxInt)).ToBe(
    '{ "jsonrpc" : "2.0", "method" : "notifications/ticks", "params" : { ' +
    '"n" : 1, "label" : "Gr' + #$C3#$BC + #$C3#$9F + 'e", ' + SUB7 +
    ' } }'#10);
  Step;
  Expect<Boolean>(Pos('"n" : 2', Captured) > 0).ToBe(True);
  Step;
  Expect<string>(Captured).ToBe('');
end;

procedure TListenSuite.TestStringIdAndClose;
begin
  AddSubscriptionSource(FServer, TTickSource.Create);
  Listen('"notifications":{"ticks":1},', '"s-1"');
  Step;
  Expect<Boolean>(Pos('"_meta" : { "io.modelcontextprotocol/subscriptionId" ' +
    ': "s-1" }', Captured) > 0).ToBe(True);
  // The server ends the stream: the completion result, with the id.
  Captured := '';
  FStream.Close(CaptureSink, nil);
  Expect<string>(Captured).ToBe('{ "jsonrpc" : "2.0", "id" : "s-1", ' +
    '"result" : { "resultType" : "complete", "_meta" : { ' +
    '"io.modelcontextprotocol/subscriptionId" : "s-1", ' +
    '"io.modelcontextprotocol/serverInfo" : { "name" : "listen", ' +
    '"version" : "1.0" } } } }'#10);
  Expect<Boolean>(FStream.Finished).ToBe(True);
  // Closed before its first step: the acknowledgment still comes first.
  Listen('"notifications":{"ticks":1},', '8');
  Captured := '';
  FStream.Close(CaptureSink, nil);
  Expect<Boolean>(Pos('notifications/subscriptions/acknowledged',
    Copy(Captured, 1, Pos(#10, Captured))) > 0).ToBe(True);
  Expect<Boolean>(Pos('"id" : 8, "result"', Copy(Captured,
    Pos(#10, Captured) + 1, MaxInt)) > 0).ToBe(True);
end;

procedure TListenSuite.TestCancelled;
begin
  AddSubscriptionSource(FServer, TTickSource.Create);
  Listen('"notifications":{"ticks":3},');
  Step;
  FStream.Cancel;
  Expect<Int64>(Step).ToBe(High(Int64));
  Expect<string>(Captured).ToBe('');
end;

// Nothing agreed is still a stream: an empty acknowledgment, then
// nothing.
procedure TListenSuite.TestNothingAgreed;
begin
  AddSubscriptionSource(FServer, TTickSource.Create);
  Listen('"notifications":{"ticks":0,"promptsListChanged":true},');
  Step;
  Expect<string>(Captured).ToBe('{ "jsonrpc" : "2.0", "method" : ' +
    '"notifications/subscriptions/acknowledged", "params" : { ' +
    '"notifications" : {}, ' + SUB7 + ' } }'#10);
end;

procedure TListenSuite.TestGuards;
var
  Raised: Boolean;
begin
  AddSubscriptionSource(FServer, TTickSource.Create);
  Raised := False;
  try
    AddSubscriptionSource(FServer, TTickSource.Create);
  except
    on E: EMCPServer do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  Raised := False;
  try
    AddSubscriptionSource(FServer, TTickSource.Create('toolsListChanged'));
  except
    on E: EMCPServer do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  Raised := False;
  try
    AddSubscriptionSource(FServer, nil);
  except
    on E: EMCPServer do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  Listen('"notifications":{},');
  Raised := False;
  try
    AddSubscriptionSource(FServer, TTickSource.Create('late'));
  except
    on E: EMCPServer do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

// The core fields keep their schema types, though none is agreed to.
procedure TListenSuite.TestCoreFieldTypes;
begin
  AddSubscriptionSource(FServer, TTickSource.Create);
  Expect<Boolean>(Pos('"message" : "Invalid params: notifications.' +
    'toolsListChanged must be a boolean"', Listen('"notifications":' +
    '{"toolsListChanged":"yes"},')) > 0).ToBe(True);
  Expect<Boolean>(Pos('notifications.resourceSubscriptions must be an ' +
    'array of strings', Listen('"notifications":{"resourceSubscriptions":' +
    '[1]},')) > 0).ToBe(True);
  Expect<Boolean>(FStream = nil).ToBe(True);
end;

// A stream with nothing agreed asks no feed again after the
// acknowledgment; past MaxListeners, a request is refused before
// anything is acknowledged.
procedure TListenSuite.TestQuietStreamAndListenerCap;
var
  First: TMCPStream;
begin
  AddSubscriptionSource(FServer, TTickSource.Create);
  MCPSetMaxListeners(FServer, 1);
  Listen('"notifications":{},');
  Expect<Int64>(Step).ToBe(High(Int64));
  First := FStream;
  FStream := nil;
  try
    Expect<Boolean>(Pos('"message" : "Too many subscriptions are open; ' +
      'try again later"', Listen('"notifications":{},', '9')) > 0)
      .ToBe(True);
  finally
    First.Free;
  end;
  // Its place is free once it ended.
  Listen('"notifications":{},', '10');
  Expect<Boolean>(FStream <> nil).ToBe(True);
end;

procedure TListenSuite.SetupTests;
begin
  Test('without a source the method answers -32601', TestNoSource);
  Test('the filter, the id, the transport and the era are checked',
    TestRequestChecks);
  Test('the acknowledgment comes first with only what was agreed',
    TestAcknowledgmentFirst);
  Test('notifications carry the subscription id, byte-exact',
    TestNotifications);
  Test('a string id, and the completion result that ends the stream',
    TestStringIdAndClose);
  Test('nothing is sent after a cancellation', TestCancelled);
  Test('nothing agreed: an empty acknowledgment', TestNothingAgreed);
  Test('sources are guarded', TestGuards);
  Test('the core filter fields keep their types', TestCoreFieldTypes);
  Test('a quiet stream is not polled; MaxListeners caps the streams',
    TestQuietStreamAndListenerCap);
end;

begin
  TestRunnerProgram.AddSuite(TListenSuite.Create('subscriptions/listen'));
  TestRunnerProgram.Run;
end.
