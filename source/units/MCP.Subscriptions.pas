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
  // How often a stream asks its feeds for notifications.
  MCP_SUBSCRIPTION_POLL_MS = 100;

type
  // What one stream gets from one source, asked while the stream lasts,
  // from the thread that drives the stream.
  TMCPSubscriptionFeed = class
  public
    // Appends the notifications due now to AOut, each an object with the
    // method and its params (an object), which the stream stamps with
    // its subscription id.
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
    // returned).
    function Open(AAgreed: TJSONData): TMCPSubscriptionFeed; virtual;
      abstract;
  end;

// Serves subscriptions/listen on AServer, before it starts, with
// ASource (owned) among the sources its streams read. A 2026-07-28
// request needs a notifications object and a string or integer id
// (-32602 otherwise), and a transport that can stream (-32603 where it
// cannot); a classic-handshake client gets -32601. A second source for a
// key, a core filter key, a nil source or a started server raises
// EMCPServer (and frees ASource).
procedure AddSubscriptionSource(AServer: TMCPServer;
  ASource: TMCPSubscriptionSource);

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
    FSources: TList; // TMCPSubscriptionSource, owned
  public
    constructor Create;
    destructor Destroy; override;
    function Listen(AParams: TJSONObject; const ACtx: TMCPRequestContext;
      ALegacy: Boolean): TJSONObject;
  end;

  TListenStream = class(TMCPStream)
  private
    FAgreed: TJSONObject; // owned: the acknowledged filter
    FFeeds: TList; // TMCPSubscriptionFeed, owned
    FAcknowledged: Boolean;
    procedure Send(const AMethod: string; AParams: TJSONObject;
      ASink: TMCPLineSink; ASinkData: Pointer);
  public
    // AAgreed and the feeds in AFeeds (both owned) from here.
    constructor Create(ARequestId: TJSONData; AAgreed: TJSONObject;
      AFeeds: TList);
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

constructor TListenStream.Create(ARequestId: TJSONData; AAgreed: TJSONObject;
  AFeeds: TList);
begin
  inherited Create(ARequestId);
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
  inherited Destroy;
end;

// Every notification on the stream carries its subscription id
// (Receiving Notifications).
procedure TListenStream.Send(const AMethod: string; AParams: TJSONObject;
  ASink: TMCPLineSink; ASinkData: Pointer);
var
  Meta: TJSONData;
begin
  try
    if Cancelled then
    begin
      AParams.Free;
      Exit;
    end;
    Meta := AParams.Find('_meta');
    if (Meta = nil) or (Meta.JSONType <> jtObject) then
    begin
      AParams.Delete('_meta');
      Meta := TJSONObject.Create;
      AParams.Add('_meta', Meta);
    end;
    TJSONObject(Meta).Delete(MCP_SUBSCRIPTION_ID_KEY);
    TJSONObject(Meta).Add(MCP_SUBSCRIPTION_ID_KEY, Id.Clone);
  except
    AParams.Free;
    raise;
  end;
  ASink(BuildNotification(AMethod, AParams), ASinkData);
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
  if not FAcknowledged then
  begin
    FAcknowledged := True;
    Send('notifications/subscriptions/acknowledged',
      TJSONObject.Create(['notifications', FAgreed.Clone]), ASink, ASinkData);
  end;
  Due := TJSONArray.Create;
  try
    for I := 0 to FFeeds.Count - 1 do
      TMCPSubscriptionFeed(FFeeds[I]).Collect(Due);
    for J := 0 to Due.Count - 1 do
    begin
      if Cancelled then
        Exit;
      Item := TJSONObject(Due.Items[J]);
      Params := Item.Extract('params');
      if not (Params is TJSONObject) then
      begin
        Params.Free;
        Params := TJSONObject.Create;
      end;
      Send(Item.Get('method', ''), TJSONObject(Params), ASink, ASinkData);
    end;
  finally
    Due.Free;
  end;
  if not Cancelled then
    Result := Now + MCP_SUBSCRIPTION_POLL_MS;
end;

// The server ends the stream (Graceful Closure): the completion result
// for the listen request, with its subscription id.
procedure TListenStream.Close(ASink: TMCPLineSink; ASinkData: Pointer);
var
  Final: TJSONObject;
begin
  Final := TJSONObject.Create(['resultType', RESULT_TYPE_COMPLETE]);
  Final.Add('_meta', TJSONObject.Create([MCP_SUBSCRIPTION_ID_KEY,
    Id.Clone]));
  ASink(BuildResultResponse(Id, Final), ASinkData);
  Finish;
end;

{ TSubscriptions }

constructor TSubscriptions.Create;
begin
  inherited Create;
  FSources := TList.Create;
end;

destructor TSubscriptions.Destroy;
var
  I: Integer;
begin
  for I := 0 to FSources.Count - 1 do
    TMCPSubscriptionSource(FSources[I]).Free;
  FSources.Free;
  inherited Destroy;
end;

function TSubscriptions.Listen(AParams: TJSONObject;
  const ACtx: TMCPRequestContext; ALegacy: Boolean): TJSONObject;
var
  Filter, Value, Agreed: TJSONData;
  Acknowledged: TJSONObject;
  Feeds: TList;
  I: Integer;
  Source: TMCPSubscriptionSource;
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
  // The request id is the subscription id, a string or an integer.
  if (ACtx.RequestId = nil) or ((ACtx.RequestId.JSONType = jtNumber) and
    (TJSONNumber(ACtx.RequestId).NumberType = ntFloat)) then
    raise InvalidParams('subscriptions/listen needs a string or integer ' +
      'request id');
  if not (ACtx.StreamHost is TMCPStreamHost) then
    raise EMCPProtocolError.Create(JSONRPC_INTERNAL_ERROR,
      'subscriptions/listen needs a transport that can stream');
  Acknowledged := TJSONObject.Create;
  Feeds := TList.Create;
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
      Feeds.Add(Source.Open(Agreed));
    end;
  except
    for I := 0 to Feeds.Count - 1 do
      TMCPSubscriptionFeed(Feeds[I]).Free;
    Feeds.Free;
    Acknowledged.Free;
    raise;
  end;
  TMCPStreamHost(ACtx.StreamHost).Park(TListenStream.Create(ACtx.RequestId,
    Acknowledged, Feeds));
  Result := TJSONObject.Create;
end;

procedure AddSubscriptionSource(AServer: TMCPServer;
  ASource: TMCPSubscriptionSource);
var
  Subscriptions: TSubscriptions;
  Fresh: Boolean;
  Problem, Key: string;
  I: Integer;
begin
  // Every check comes before the server changes.
  try
    if (AServer = nil) or (ASource = nil) then
      raise EMCPServer.Create('AddSubscriptionSource needs a server and a ' +
        'source');
    Problem := AServer.HookProblem([], '');
    if Problem <> '' then
      raise EMCPServer.Create(Problem);
    Key := ASource.FilterKey;
    for I := Low(CORE_FILTER_KEYS) to High(CORE_FILTER_KEYS) do
      if CORE_FILTER_KEYS[I] = Key then
        raise EMCPServer.CreateFmt('"%s" is a core filter key', [Key]);
    if Key = '' then
      raise EMCPServer.Create('A subscription source needs a filter key');
    Subscriptions := TSubscriptions(AServer.Adopted(TSubscriptions));
    Fresh := Subscriptions = nil;
    if not Fresh then
      for I := 0 to Subscriptions.FSources.Count - 1 do
        if TMCPSubscriptionSource(Subscriptions.FSources[I]).FilterKey =
          Key then
          raise EMCPServer.CreateFmt('A subscription source for "%s" is ' +
            'already added', [Key]);
  except
    ASource.Free;
    raise;
  end;
  if Fresh then
  begin
    Subscriptions := TSubscriptions.Create;
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

end.
