unit MCP.Streams;

// Long-lived requests a transport drives (#126): a request that keeps
// writing notifications after its handler returns, such as the Events
// extension's events/stream, whose push stream lasts until the client
// cancels it (ext-events specification/beta/events/events.mdx at
// c77b843, Push-Based Delivery, verified 2026-11-27).
//
// The handler validates the request and parks a TMCPStream with the
// session's stream host (TMCPRequestContext.StreamHost, set from
// TMCPSession.StreamHost). The transport then drops the handler's
// placeholder result and steps the stream until it finishes or the
// client cancels it: Streamable HTTP in the request's own thread, stdio
// in its single-threaded loop beside the other requests. A session
// without a host, such as the in-process test client's, cannot stream.

{$I MCP.inc}

interface

uses
  SysUtils,

  fpjson,
  MCP.Protocol,
  MCP.Server;

const
  // The key every notification on a long-lived stream carries the
  // stream's request id under, in params._meta (basic/patterns/
  // subscriptions, Receiving Notifications; ext-events events.mdx, Event
  // delivery), as does the result that ends it.
  MCP_SUBSCRIPTION_ID_KEY = 'io.modelcontextprotocol/subscriptionId';

type
  // A clock in milliseconds; MCPNowMs unless a test sets another.
  TMCPClock = function: Int64;

  TMCPStream = class
  private
    FId: TJSONData; // owned: the request's id
    FFinished: Boolean;
    FClock: TMCPClock;
    FCancelProbe: TMCPCancellationProbe;
  protected
    // Set when the stream has ended (its final frame, if any, already
    // written).
    procedure Finish;
    // The stream's clock now.
    function Now: Int64;
    // Writes notification AMethod with AParams (consumed), its _meta
    // carrying the stream's id as MCP_SUBSCRIPTION_ID_KEY, through ASink:
    // False, with nothing written, once the stream is cancelled, unless
    // AForce, as for a frame Close must still send (#138 review: one
    // sender for every stream).
    function SendNotification(const AMethod: string; AParams: TJSONObject;
      ASink: TMCPLineSink; ASinkData: Pointer;
      AForce: Boolean = False): Boolean;
  public
    // ARequestId (borrowed) is copied: the request's JSON-RPC id.
    constructor Create(ARequestId: TJSONData);
    destructor Destroy; override;
    // Writes what is due through ASink, one JSON line per call, and
    // returns when it is next due on the stream's clock. A sink that
    // raises ends the stream: the transport stops stepping it.
    function Step(ASink: TMCPLineSink; ASinkData: Pointer): Int64; virtual;
      abstract;
    // The client went away or cancelled: nothing more is written.
    procedure Cancel; virtual;
    // The server ends the stream, such as when its transport stops:
    // the final frame through ASink, then Finished.
    procedure Close(ASink: TMCPLineSink; ASinkData: Pointer); virtual;
      abstract;
    // Whether the stream has ended or the transport's probe reports the
    // client gone; a True probe cancels the stream. Asked between the
    // stream's own steps, and by the checks it runs (#126 review).
    function Cancelled: Boolean;
    property Id: TJSONData read FId;
    property Finished: Boolean read FFinished;
    // MCPNowMs unless set: how a test drives the stream's time.
    property Clock: TMCPClock read FClock write FClock;
    // The transport's live check for a client that went away or a
    // cancellation that arrived while the stream steps (nil for none).
    property CancelProbe: TMCPCancellationProbe read FCancelProbe
      write FCancelProbe;
  end;

  // Where a handler parks its stream for the transport (one at a time:
  // a transport takes it as soon as HandleMessage returns).
  TMCPStreamHost = class
  private
    FParked: TMCPStream; // owned until taken
    FShutdownProbe: TMCPCancellationProbe;
  public
    // The transport is ending (stdio's end of input, HTTP's Stop): a
    // handler's own checks ask it beside the request's cancellation,
    // so one that waits returns (#126 review). Nil for never.
    property ShutdownProbe: TMCPCancellationProbe read FShutdownProbe
      write FShutdownProbe;
    function ShuttingDown: Boolean;
    destructor Destroy; override;
    // Takes ownership of AStream. A second stream before the first is
    // taken raises EMCPServer (and frees AStream).
    procedure Park(AStream: TMCPStream);
    // The parked stream (the caller's), or nil. A transport whose
    // HandleMessage produced no response (the request was cancelled)
    // cancels and frees it instead of driving it.
    function TakeParked: TMCPStream;
  end;

// A monotonic clock in milliseconds, the one streams run on.
function MCPNowMs: Int64;

var
  // The clock new streams start with, and handlers time a stream's
  // opening by (MCPStreamNow): MCPNowMs unless a test sets another.
  MCPStreamClock: TMCPClock = nil;

function MCPStreamNow: Int64;

// The stream a request parked with AHost, for the transport to drive,
// or nil. One rule for every transport (#126 review): only a request
// whose response AResponse (AProduced) is a result hands its stream
// over; one the core answered with an error, such as a handler that
// parked and then raised, or answered nothing for, being cancelled,
// has its stream cancelled and freed, and the transport sends the
// response as usual.
function MCPTakeStream(AHost: TMCPStreamHost; AProduced: Boolean;
  const AResponse: string): TMCPStream;

implementation

uses
  MCP.Errors,
  MCP.JSONRPC;

{$IFDEF DARWIN}
// FPC's Unix GetTickCount64 reads CLOCK_MONOTONIC only on Linux and
// FreeBSD and falls back to wall time on the other Unixes, macOS among
// them, where a clock stepped back would hold every stream's timer for
// as long (#134). The Mach clock is monotonic, exists on every macOS,
// and like Linux's CLOCK_MONOTONIC stops while the machine sleeps.
type
  TMachTimebaseInfo = record
    Numer, Denom: Cardinal;
  end;

function mach_absolute_time: QWord; cdecl;
  external 'c' name 'mach_absolute_time';
function mach_timebase_info(var AInfo: TMachTimebaseInfo): LongInt; cdecl;
  external 'c' name 'mach_timebase_info';

var
  // Set once, at unit initialization.
  MachTimebase: TMachTimebaseInfo;

function MCPNowMs: Int64;
var
  Ticks: QWord;
begin
  Ticks := mach_absolute_time;
  // Ticks times Numer / Denom is nanoseconds; dividing first keeps the
  // product in range for centuries of uptime.
  Result := Int64((Ticks div MachTimebase.Denom * MachTimebase.Numer +
    Ticks mod MachTimebase.Denom * MachTimebase.Numer div
    MachTimebase.Denom) div 1000000);
end;
{$ELSE}
function MCPNowMs: Int64;
begin
  Result := Int64(GetTickCount64);
end;
{$ENDIF}

function MCPStreamNow: Int64;
begin
  if Assigned(MCPStreamClock) then
    Result := MCPStreamClock()
  else
    Result := MCPNowMs;
end;

constructor TMCPStream.Create(ARequestId: TJSONData);
begin
  inherited Create;
  if ARequestId <> nil then
    FId := ARequestId.Clone
  else
    FId := TJSONNull.Create;
  if Assigned(MCPStreamClock) then
    FClock := MCPStreamClock
  else
    FClock := @MCPNowMs;
end;

destructor TMCPStream.Destroy;
begin
  FId.Free;
  inherited Destroy;
end;

procedure TMCPStream.Finish;
begin
  FFinished := True;
end;

function TMCPStream.Now: Int64;
begin
  Result := FClock();
end;

function TMCPStream.SendNotification(const AMethod: string;
  AParams: TJSONObject; ASink: TMCPLineSink; ASinkData: Pointer;
  AForce: Boolean): Boolean;
var
  Meta: TJSONData;
begin
  try
    if not AForce and Cancelled then
    begin
      AParams.Free;
      Exit(False);
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
  Result := True;
end;

procedure TMCPStream.Cancel;
begin
  FFinished := True;
end;

function TMCPStream.Cancelled: Boolean;
begin
  if not FFinished and Assigned(FCancelProbe) and FCancelProbe() then
    Cancel;
  Result := FFinished;
end;

destructor TMCPStreamHost.Destroy;
begin
  FParked.Free;
  inherited Destroy;
end;

procedure TMCPStreamHost.Park(AStream: TMCPStream);
begin
  if FParked <> nil then
  begin
    AStream.Free;
    raise EMCPServer.Create('A stream is already parked for this request');
  end;
  FParked := AStream;
end;

function TMCPStreamHost.ShuttingDown: Boolean;
begin
  Result := Assigned(FShutdownProbe) and FShutdownProbe();
end;

function TMCPStreamHost.TakeParked: TMCPStream;
begin
  Result := FParked;
  FParked := nil;
end;

function MCPTakeStream(AHost: TMCPStreamHost; AProduced: Boolean;
  const AResponse: string): TMCPStream;
var
  Response: TJSONData;
  IsResult: Boolean;
begin
  Result := nil;
  if AHost = nil then
    Exit;
  Result := AHost.TakeParked;
  if Result = nil then
    Exit;
  IsResult := False;
  if AProduced then
  begin
    Response := nil;
    try
      Response := MCPParseJSON(AResponse);
      IsResult := (Response is TJSONObject) and
        (TJSONObject(Response).Find('result') <> nil);
    except
      // A response the core built is JSON; an unreadable one is no
      // result.
      on Exception do
        IsResult := False;
    end;
    Response.Free;
  end;
  if not IsResult then
  begin
    Result.Cancel;
    FreeAndNil(Result);
  end;
end;

{$IFDEF DARWIN}
initialization
  if (mach_timebase_info(MachTimebase) <> 0) or (MachTimebase.Denom = 0) then
  begin
    // Never on a supported macOS; nanosecond ticks, as on Intel.
    MachTimebase.Numer := 1;
    MachTimebase.Denom := 1;
  end;
{$ENDIF}
end.
