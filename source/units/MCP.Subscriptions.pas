{ MCP.Subscriptions — subscriptions/listen (#138) on the 2026-07-28
  revision: a long-lived stream of the notifications a client asks for in
  its request's notifications filter, outside any other request.
  Verified 2026-11-28 against
  https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/subscriptions
  (modelcontextprotocol/modelcontextprotocol docs at fdc75bd).

  The stream sends notifications/subscriptions/acknowledged first, with
  the part of the filter the server agreed to, then each notification as
  it is due, every one with the request's id as
  _meta["io.modelcontextprotocol/subscriptionId"]. It lasts until the
  client cancels it (notifications/cancelled on stdio, a closed connection
  on Streamable HTTP), and when Streamable HTTP's Stop ends it, it sends
  the completion result with the same id (Graceful Closure); on stdio
  the end of input ends it with nothing more sent, since the client has
  gone. The cancellation
  page says a server ending a stream MUST send notifications/cancelled,
  where the subscriptions page asks for that result; this follows the
  subscriptions page, as the TypeScript SDK's listenRouter does.

  The core's own filter fields (toolsListChanged, promptsListChanged,
  resourcesListChanged, resourceSubscriptions) are never agreed to: the
  registries are fixed once the server starts, so nothing would be sent.
  An extension offers its own notifications as a source under a filter
  key of its own, such as the Tasks extension's taskIds (MCP.Tasks).
}

unit MCP.Subscriptions;

{$I MCP.inc}

interface

uses
  SysUtils,

  fpjson,
  MCP.Protocol,
  MCP.Server;

const
  // How often a stream asks its feeds for notifications; a stream
  // without feeds is not asked at all.
  MCP_SUBSCRIPTION_POLL_MS = 100;
  // Listen streams open at once, unless set otherwise: each holds a
  // Streamable HTTP connection's thread.
  MCP_DEFAULT_MAX_LISTENERS = 64;

type
  // What one stream gets from one source, asked while the stream lasts,
  // from the thread that drives the stream.
  TMCPSubscriptionFeed = class
  public
    // Appends the notifications due now to AOut (borrowed for the call;
    // what is appended is AOut's), each an object with the method and
    // its params (an object), which the stream stamps with its
    // subscription id.
    procedure Collect(AOut: TJSONArray); virtual; abstract;
  end;

  // Notifications an extension offers on subscriptions/listen, under one
  // key of the request's notifications filter.
  TMCPSubscriptionSource = class
  public
    function FilterKey: string; virtual; abstract;
    // What of AValue (borrowed: the filter's value under FilterKey) the
    // server agrees to send (new; it goes in the acknowledgment), or nil
    // to leave the key out. Raise EMCPProtocolError to refuse the
    // request, such as -32602 for a malformed value.
    function Agree(AValue: TJSONData;
      const ACtx: TMCPRequestContext): TJSONData; virtual; abstract;
    // A feed for a new stream, for AAgreed (borrowed: what Agree
    // returned); ACtx is the listen request's, valid for the call only.
    function Open(AAgreed: TJSONData;
      const ACtx: TMCPRequestContext): TMCPSubscriptionFeed; virtual;
      abstract;
  end;

// Serves subscriptions/listen on AServer, before it starts, with
// ASource (owned) among the sources its streams read. A 2026-07-28
// request needs a notifications object whose core fields have their
// schema types and a string or integer id (-32602 otherwise), and a
// transport that can stream (-32603 where it cannot, and past
// MaxListeners streams); a classic-handshake client gets -32601. A
// second source for a key, a core filter key, a nil source, a listen
// handler another unit set, or a started server raises EMCPServer (and
// frees ASource).
procedure AddSubscriptionSource(AServer: TMCPServer;
  ASource: TMCPSubscriptionSource);

// Why AddSubscriptionSource would refuse a source for AKey, '' when it
// would add one; nothing changes, so a caller can check first.
function MCPSubscriptionSourceProblem(AServer: TMCPServer;
  const AKey: string): string;

// The most listen streams open at once (at least 1), before the server
// starts; MCP_DEFAULT_MAX_LISTENERS unless set. Raises EMCPServer
// without a source added, or after the server started.
procedure MCPSetMaxListeners(AServer: TMCPServer; AValue: Integer);

implementation

uses
  Classes,

  MCP.Errors,
  MCP.JSONRPC,
  MCP.Streams;

const
  CORE_FILTER_KEYS: array[0..3] of string = ('toolsListChanged',
    'promptsListChanged', 'resourcesListChanged', 'resourceSubscriptions');

type
  TSubscriptions = class
  private
    FServer: TMCPServer; // borrowed: the server owns this object
    FSources: TList; // TMCPSubscriptionSource, owned
    FLock: TRTLCriticalSection;
    FOpen, FMaxListeners: Integer;
    function CheckFilter(AFilter: TJSONObject): string;
  public
    constructor Create(AServer: TMCPServer);
    destructor Destroy; override;
    function Listen(AParams: TJSONObject; const ACtx: TMCPRequestContext;
      ALegacy: Boolean): TJSONObject;
    // A stream ended (any thread).
    procedure Closed;
  end;

  TListenStream = class(TMCPStream)
  private
    FOwner: TSubscriptions; // borrowed
    FAgreed: TJSONObject; // owned: the acknowledged filter
    FFeeds: TList; // TMCPSubscriptionFeed, owned
    FAcknowledged: Boolean;
    // The acknowledgment, once; written whatever the stream's state when
    // AForce, so a graceful close never comes first (#138 review).
    procedure Acknowledge(ASink: TMCPLineSink; ASinkData: Pointer;
      AForce: Boolean);
  public
    // AAgreed and the feeds in AFeeds (both owned) from here.
    constructor Create(AOwner: TSubscriptions; ARequestId: TJSONData;
      AAgreed: TJSONObject; AFeeds: TList);
    destructor Destroy; override;
    function Step(ASink: TMCPLineSink; ASinkData: Pointer): Int64; override;
    procedure Close(ASink: TMCPLineSink; ASinkData: Pointer); override;
  end;

function InvalidParams(const AWhat: string): EMCPProtocolError;
begin
  Result := EMCPProtocolError.Create(JSONRPC_INVALID_PARAMS,
    'Invalid params: ' + AWhat);
end;

{ TListenStream }

constructor TListenStream.Create(AOwner: TSubscriptions;
  ARequestId: TJSONData; AAgreed: TJSONObject; AFeeds: TList);
begin
  inherited Create(ARequestId);
  FOwner := AOwner;
  FAgreed := AAgreed;
  FFeeds := AFeeds;
end;

destructor TListenStream.Destroy;
var
  I: Integer;
begin
  if FFeeds <> nil then
    for I := 0 to FFeeds.Count - 1 do
      TMCPSubscriptionFeed(FFeeds[I]).Free;
  FFeeds.Free;
  FAgreed.Free;
  if FOwner <> nil then
    FOwner.Closed;
  inherited Destroy;
end;

procedure TListenStream.Acknowledge(ASink: TMCPLineSink; ASinkData: Pointer;
  AForce: Boolean);
begin
  // Acknowledged once it has gone out, not when it was due.
  if not FAcknowledged then
    FAcknowledged := SendNotification(
      'notifications/subscriptions/acknowledged',
      TJSONObject.Create(['notifications', FAgreed.Clone]), ASink,
      ASinkData, AForce);
end;

function TListenStream.Step(ASink: TMCPLineSink; ASinkData: Pointer): Int64;
var
  Due: TJSONArray;
  I, J: Integer;
  Item: TJSONObject;
  Params: TJSONData;
begin
  Result := High(Int64);
  if Cancelled then
    Exit;
  // The acknowledgment comes before anything else on the stream
  // (Acknowledgment).
  Acknowledge(ASink, ASinkData, False);
  // A stream without feeds has nothing more to send until it ends.
  if not FAcknowledged or (FFeeds.Count = 0) then
    Exit;
  Due := TJSONArray.Create;
  try
    for I := 0 to FFeeds.Count - 1 do
      TMCPSubscriptionFeed(FFeeds[I]).Collect(Due);
    for J := 0 to Due.Count - 1 do
    begin
      Item := TJSONObject(Due.Items[J]);
      Params := Item.Extract('params');
      if not (Params is TJSONObject) then
      begin
        Params.Free;
        Params := TJSONObject.Create;
      end;
      if not SendNotification(Item.Get('method', ''), TJSONObject(Params),
        ASink, ASinkData) then
        Exit;
    end;
  finally
    Due.Free;
  end;
  if not Cancelled then
    Result := Now + MCP_SUBSCRIPTION_POLL_MS;
end;

// The server ends the stream (Graceful Closure): the acknowledgment if
// it has not gone out yet, then the completion result for the listen
// request, stamped as every result is, with its subscription id.
procedure TListenStream.Close(ASink: TMCPLineSink; ASinkData: Pointer);
var
  Final: TJSONObject;
begin
  Acknowledge(ASink, ASinkData, True);
  Final := TJSONObject.Create(['resultType', RESULT_TYPE_COMPLETE]);
  try
    Final.Add('_meta', TJSONObject.Create([MCP_SUBSCRIPTION_ID_KEY,
      Id.Clone]));
    StampResult(Final, FOwner.FServer.Name, FOwner.FServer.Version);
  except
    Final.Free;
    raise;
  end;
  ASink(BuildResultResponse(Id, Final), ASinkData);
  Finish;
end;

{ TSubscriptions }

constructor TSubscriptions.Create(AServer: TMCPServer);
begin
  inherited Create;
  FServer := AServer;
  FSources := TList.Create;
  FMaxListeners := MCP_DEFAULT_MAX_LISTENERS;
  InitCriticalSection(FLock);
end;

destructor TSubscriptions.Destroy;
var
  I: Integer;
begin
  for I := 0 to FSources.Count - 1 do
    TMCPSubscriptionSource(FSources[I]).Free;
  FSources.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TSubscriptions.Closed;
begin
  System.EnterCriticalSection(FLock);
  Dec(FOpen);
  System.LeaveCriticalSection(FLock);
end;

// Why a core filter field lacks its schema type (SubscriptionFilter:
// booleans, and an array of URIs), '' when none does (#138 review).
function TSubscriptions.CheckFilter(AFilter: TJSONObject): string;
var
  I, J: Integer;
  Value: TJSONData;
begin
  Result := '';
  for I := 0 to 2 do
  begin
    Value := AFilter.Find(CORE_FILTER_KEYS[I]);
    if (Value <> nil) and (Value.JSONType <> jtBoolean) then
      Exit('notifications.' + CORE_FILTER_KEYS[I] + ' must be a boolean');
  end;
  Value := AFilter.Find(CORE_FILTER_KEYS[3]);
  if Value = nil then
    Exit;
  if Value.JSONType <> jtArray then
    Exit('notifications.resourceSubscriptions must be an array of strings');
  for J := 0 to Value.Count - 1 do
    if Value.Items[J].JSONType <> jtString then
      Exit('notifications.resourceSubscriptions must be an array of ' +
        'strings');
end;

function TSubscriptions.Listen(AParams: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
var
  Filter, Value, Agreed: TJSONData;
  Acknowledged: TJSONObject;
  Feeds: TList;
  I: Integer;
  Source: TMCPSubscriptionSource;
  Problem: string;
  Admitted: Boolean;
begin
  // The method is defined for 2026-07-28 (it replaces the classic
  // resources/subscribe).
  if ALegacy then
    raise EMCPProtocolError.Create(JSONRPC_METHOD_NOT_FOUND,
      'Method not found: subscriptions/listen');
  Filter := nil;
  if AParams <> nil then
    Filter := AParams.Find('notifications');
  if (Filter = nil) or (Filter.JSONType <> jtObject) then
    raise InvalidParams('notifications must be an object');
  Problem := CheckFilter(TJSONObject(Filter));
  if Problem <> '' then
    raise InvalidParams(Problem);
  // The request id is the subscription id, a string or an integer, an
  // integral number written as 2.0 included (#138 review).
  if (ACtx.RequestId = nil) or ((ACtx.RequestId.JSONType = jtNumber) and
    (TJSONNumber(ACtx.RequestId).NumberType = ntFloat) and
    ((Frac(ACtx.RequestId.AsFloat) <> 0) or
    (Abs(ACtx.RequestId.AsFloat) > 9007199254740991.0))) then
    raise InvalidParams('subscriptions/listen needs a string or integer ' +
      'request id');
  if not (ACtx.StreamHost is TMCPStreamHost) then
    raise EMCPProtocolError.Create(JSONRPC_INTERNAL_ERROR,
      'subscriptions/listen needs a transport that can stream');
  Acknowledged := TJSONObject.Create;
  Feeds := TList.Create;
  Admitted := False;
  try
    for I := 0 to FSources.Count - 1 do
    begin
      Source := TMCPSubscriptionSource(FSources[I]);
      Value := TJSONObject(Filter).Find(Source.FilterKey);
      if Value = nil then
        Continue;
      Agreed := Source.Agree(Value, ACtx);
      if Agreed = nil then
        Continue;
      Acknowledged.Add(Source.FilterKey, Agreed);
      Feeds.Add(Source.Open(Agreed, ACtx));
    end;
    // Each stream holds a connection's thread on Streamable HTTP: a cap
    // before anything is acknowledged (#138 review).
    System.EnterCriticalSection(FLock);
    try
      Admitted := FOpen < FMaxListeners;
      if Admitted then
        Inc(FOpen);
    finally
      System.LeaveCriticalSection(FLock);
    end;
    if not Admitted then
      raise EMCPProtocolError.Create(JSONRPC_INTERNAL_ERROR,
        'Too many subscriptions are open; try again later');
  except
    for I := 0 to Feeds.Count - 1 do
      TMCPSubscriptionFeed(Feeds[I]).Free;
    Feeds.Free;
    Acknowledged.Free;
    raise;
  end;
  TMCPStreamHost(ACtx.StreamHost).Park(TListenStream.Create(Self,
    ACtx.RequestId, Acknowledged, Feeds));
  Result := TJSONObject.Create;
end;

function MCPSubscriptionSourceProblem(AServer: TMCPServer;
  const AKey: string): string;
var
  Subscriptions: TSubscriptions;
  I: Integer;
begin
  if AServer = nil then
    Exit('AddSubscriptionSource needs a server and a source');
  Result := AServer.HookProblem([], '');
  if Result <> '' then
    Exit;
  for I := Low(CORE_FILTER_KEYS) to High(CORE_FILTER_KEYS) do
    if CORE_FILTER_KEYS[I] = AKey then
      Exit(Format('"%s" is a core filter key', [AKey]));
  if AKey = '' then
    Exit('A subscription source needs a filter key');
  Subscriptions := TSubscriptions(AServer.Adopted(TSubscriptions));
  if Subscriptions = nil then
    // The listen handler must still be free for this unit to take.
    Exit(AServer.ListenHandlerProblem);
  for I := 0 to Subscriptions.FSources.Count - 1 do
    if TMCPSubscriptionSource(Subscriptions.FSources[I]).FilterKey = AKey
    then
      Exit(Format('A subscription source for "%s" is already added',
        [AKey]));
end;

procedure AddSubscriptionSource(AServer: TMCPServer;
  ASource: TMCPSubscriptionSource);
var
  Subscriptions: TSubscriptions;
  Problem: string;
begin
  // Every check comes before the server changes.
  try
    if ASource = nil then
      raise EMCPServer.Create('AddSubscriptionSource needs a server and a ' +
        'source');
    Problem := MCPSubscriptionSourceProblem(AServer, ASource.FilterKey);
    if Problem <> '' then
      raise EMCPServer.Create(Problem);
  except
    ASource.Free;
    raise;
  end;
  Subscriptions := TSubscriptions(AServer.Adopted(TSubscriptions));
  if Subscriptions = nil then
  begin
    Subscriptions := TSubscriptions.Create(AServer);
    try
      AServer.SetListenHandler(Subscriptions.Listen);
    except
      Subscriptions.Free;
      ASource.Free;
      raise;
    end;
    AServer.Adopt(Subscriptions);
  end;
  Subscriptions.FSources.Add(ASource);
end;

procedure MCPSetMaxListeners(AServer: TMCPServer; AValue: Integer);
var
  Subscriptions: TSubscriptions;
  Problem: string;
begin
  Problem := AServer.HookProblem([], '');
  if Problem <> '' then
    raise EMCPServer.Create(Problem);
  Subscriptions := TSubscriptions(AServer.Adopted(TSubscriptions));
  if Subscriptions = nil then
    raise EMCPServer.Create('MCPSetMaxListeners: no subscription source is ' +
      'added');
  if AValue < 1 then
    raise EMCPServer.Create('MaxListeners must be at least 1');
  Subscriptions.FMaxListeners := AValue;
end;

end.
