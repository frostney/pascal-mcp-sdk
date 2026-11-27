unit MCP.Pagination;

// List cursors (#94): the opaque token a paged list hands out as
// nextCursor, and the check of one a client sends back as cursor.
// Verified 2026-11-26 against
// https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/pagination
// (cursors are opaque, stable, and an invalid one SHOULD be -32602).
// MCP.Server owns the paging itself; this unit knows nothing of the
// registries.

{$I MCP.inc}

interface

// Cursor for the page of AMethod's list starting at AOffset: opaque to
// the client (pagination#pagination-model), base64 of "method:offset".
function ListCursor(const AMethod: string; AOffset: Integer): string;

// The offset ACursor points at in AMethod's list of ACount entries
// paged APageSize at a time, or False for a cursor that is not one of
// that list's page cursors: paging off, an offset that is no page
// boundary inside the list, or any spelling other than the one
// ListCursor gives (#94 review).
function TryCursorOffset(const ACursor, AMethod: string;
  ACount, APageSize: Integer; out AOffset: Integer): Boolean;

implementation

uses
  SysUtils,

  base64;

function ListCursor(const AMethod: string; AOffset: Integer): string;
begin
  Result := EncodeStringBase64(AMethod + ':' + IntToStr(AOffset));
end;

function TryCursorOffset(const ACursor, AMethod: string;
  ACount, APageSize: Integer; out AOffset: Integer): Boolean;
var
  Decoded: string;
begin
  Result := False;
  AOffset := 0;
  if APageSize <= 0 then
    Exit;
  try
    Decoded := DecodeStringBase64(ACursor);
  except
    Exit;
  end;
  if Copy(Decoded, 1, Length(AMethod) + 1) <> AMethod + ':' then
    Exit;
  Result := TryStrToInt(Copy(Decoded, Length(AMethod) + 2, MaxInt), AOffset) and
    (AOffset > 0) and (AOffset < ACount) and (AOffset mod APageSize = 0) and
    (ListCursor(AMethod, AOffset) = ACursor);
end;

end.
