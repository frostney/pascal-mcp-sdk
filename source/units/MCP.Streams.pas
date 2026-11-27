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
  MCP.Server;

type
  TMCPStream = class
  private
    FId: TJSONData; // owned: the request's id
    FFinished: Boolean;
  protected
    // Set by Step when the stream has ended (its final frame, if any,
    // already written).
    procedure Finish;
  public
    // ARequestId (borrowed) is copied: the request's JSON-RPC id.
    constructor Create(ARequestId: TJSONData);
    destructor Destroy; override;
    // Writes what is due at ANowMs (MCPNowMs) through ASink, one JSON
    // line per call, and returns when it is next due on the same clock.
    // A sink that raises ends the stream: the transport stops stepping
    // it and calls Cancel.
    function Step(ANowMs: Int64; ASink: TMCPLineSink;
      ASinkData: Pointer): Int64; virtual; abstract;
    // The client went away or cancelled: nothing more is written.
    procedure Cancel; virtual;
    // The server ends the stream, such as when its transport stops:
    // the final frame through ASink, then Finished.
    procedure Close(ASink: TMCPLineSink; ASinkData: Pointer); virtual;
      abstract;
    property Id: TJSONData read FId;
    property Finished: Boolean read FFinished;
  end;

  // Where a handler parks its stream for the transport (one at a time:
  // a transport takes it as soon as HandleMessage returns).
  TMCPStreamHost = class
  private
    FParked: TMCPStream; // owned until taken
  public
    destructor Destroy; override;
    // Takes ownership of AStream. A second stream before the first is
    // taken raises EMCPServer (and frees AStream).
    procedure Park(AStream: TMCPStream);
    // The parked stream (the caller's), or nil.
    function TakeParked: TMCPStream;
  end;

// A monotonic clock in milliseconds, the one Step is driven by.
function MCPNowMs: Int64;

implementation

uses
  MCP.Errors;

constructor TMCPStream.Create(ARequestId: TJSONData);
begin
  inherited Create;
  if ARequestId <> nil then
    FId := ARequestId.Clone
  else
    FId := TJSONNull.Create;
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

procedure TMCPStream.Cancel;
begin
  FFinished := True;
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

function TMCPStreamHost.TakeParked: TMCPStream;
begin
  Result := FParked;
  FParked := nil;
end;

function MCPNowMs: Int64;
begin
  Result := Int64(GetTickCount64);
end;

end.
