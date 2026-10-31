unit CAD.Core.ResultCache;
{$mode objfpc}{$H+}

{ ROLE:      owns every feature result, finds a result by its cache key and
             frees results that nobody uses once a memory limit is passed.
  CALLED BY: TCADDocument (Acquire/Store on worker threads, Release when a
             feature drops a result).
  CALLS:     CAD.Core.Feature (TCADResult), fgl map.
  THREADS:   every public method is thread-safe (one critical section).
  BYTES:     each result's size is counted once (AccountedBytes) when it is
             stored; when it grows later (mesh added by the display pass)
             the document calls Remeasure, so the totals stay exact.
  SPEED:     lookup O(log n) in a sorted map. A result that went out of use
             (old parameter value) stays until the limit, so Undo/Redo and
             dragging back to a previous value cost no recompute at all. }

interface

uses
  Classes, SysUtils, fgl, CAD.Core.Ids, CAD.Core.Feature;

type
  TCADResultMap = specialize TFPGMap<QWord, TCADResult>;

  TCADCacheStats = record
    Count: Integer;
    InUse: Integer;
    Bytes: Int64;
    Hits: Int64;
    Misses: Int64;
    Evictions: Int64;
  end;

  TCADResultCache = class
  private
    FLock: TRTLCriticalSection;
    FMap: TCADResultMap;
    FEnabled: Boolean;
    FMaxUnusedBytes: Int64;
    FBytes: Int64;
    FUnusedBytes: Int64;
    FClock: QWord;
    FHits, FMisses, FEvictions: Int64;
    procedure Touch(AResult: TCADResult);
    procedure TrimLocked;
    procedure EvictAt(AIndex: Integer);
  public
    constructor Create(AEnabled: Boolean; AMaxUnusedBytes: Int64);
    destructor Destroy; override;
    procedure Configure(AEnabled: Boolean; AMaxUnusedBytes: Int64);
    { Result with this key, use count + 1; nil when not cached. }
    function Acquire(AKey: TCADHash): TCADResult;
    { Takes ownership of AResult (its Key must be set). If the key is already
      cached, AResult is freed and the cached one is returned. Use count + 1. }
    function Store(AResult: TCADResult): TCADResult;
    { Use count - 1; may free unused results over the limit. nil is ignored. }
    procedure Release(AResult: TCADResult);
    { The result's EstimatedBytes changed (display data added): update the
      totals. Call only for a stored result. nil is ignored. }
    procedure Remeasure(AResult: TCADResult);
    procedure Clear;
    function Stats: TCADCacheStats;
  end;

implementation

constructor TCADResultCache.Create(AEnabled: Boolean; AMaxUnusedBytes: Int64);
begin
  inherited Create;
  InitCriticalSection(FLock);
  FMap := TCADResultMap.Create;
  FMap.Sorted := True;
  FMap.Duplicates := dupError;
  FEnabled := AEnabled;
  FMaxUnusedBytes := AMaxUnusedBytes;
end;

destructor TCADResultCache.Destroy;
begin
  Clear;
  FMap.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TCADResultCache.Configure(AEnabled: Boolean; AMaxUnusedBytes: Int64);
begin
  EnterCriticalSection(FLock);
  try
    FEnabled := AEnabled;
    FMaxUnusedBytes := AMaxUnusedBytes;
    TrimLocked;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TCADResultCache.Touch(AResult: TCADResult);
begin
  Inc(FClock);
  AResult.LastUse := FClock;
end;

function TCADResultCache.Acquire(AKey: TCADHash): TCADResult;
var
  I: Integer;
begin
  Result := nil;
  EnterCriticalSection(FLock);
  try
    if FMap.Find(AKey, I) then
    begin
      Result := FMap.Data[I];
      if Result.UseCount = 0 then
        Dec(FUnusedBytes, Result.AccountedBytes);
      Result.UseCount := Result.UseCount + 1;
      Touch(Result);
      Inc(FHits);
    end
    else
      Inc(FMisses);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TCADResultCache.Store(AResult: TCADResult): TCADResult;
var
  I: Integer;
begin
  EnterCriticalSection(FLock);
  try
    if FMap.Find(AResult.Key, I) then
    begin
      { Two features produced the same key in one level: keep one copy. }
      Result := FMap.Data[I];
      if Result <> AResult then
        AResult.Free;
      if Result.UseCount = 0 then
        Dec(FUnusedBytes, Result.AccountedBytes);
    end
    else
    begin
      Result := AResult;
      Result.UseCount := 0;
      Result.AccountedBytes := Result.EstimatedBytes;   { counted once, here }
      FMap.Add(Result.Key, Result);
      Inc(FBytes, Result.AccountedBytes);
    end;
    Result.UseCount := Result.UseCount + 1;
    Touch(Result);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TCADResultCache.Release(AResult: TCADResult);
begin
  if AResult = nil then
    Exit;
  EnterCriticalSection(FLock);
  try
    if AResult.UseCount > 0 then
    begin
      AResult.UseCount := AResult.UseCount - 1;
      if AResult.UseCount = 0 then
        Inc(FUnusedBytes, AResult.AccountedBytes);
    end;
    Touch(AResult);
    TrimLocked;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TCADResultCache.Remeasure(AResult: TCADResult);
var
  Delta: Int64;
begin
  if AResult = nil then
    Exit;
  EnterCriticalSection(FLock);
  try
    Delta := AResult.EstimatedBytes - AResult.AccountedBytes;
    AResult.AccountedBytes := AResult.AccountedBytes + Delta;
    Inc(FBytes, Delta);
    if AResult.UseCount = 0 then
      Inc(FUnusedBytes, Delta);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TCADResultCache.EvictAt(AIndex: Integer);
var
  R: TCADResult;
begin
  R := FMap.Data[AIndex];
  Dec(FBytes, R.AccountedBytes);
  Dec(FUnusedBytes, R.AccountedBytes);
  FMap.Delete(AIndex);
  R.Free;
  Inc(FEvictions);
end;

procedure TCADResultCache.TrimLocked;
var
  I, Oldest: Integer;
  Limit: Int64;
begin
  if FEnabled then Limit := FMaxUnusedBytes else Limit := 0;
  { O(n) per eviction is fine for thousands of results; switch to an LRU
    list if profiles show this loop. }
  while FUnusedBytes > Limit do
  begin
    Oldest := -1;
    for I := 0 to FMap.Count - 1 do
      if (FMap.Data[I].UseCount = 0) and
         ((Oldest < 0) or (FMap.Data[I].LastUse < FMap.Data[Oldest].LastUse)) then
        Oldest := I;
    if Oldest < 0 then
      Break;
    EvictAt(Oldest);
  end;
end;

procedure TCADResultCache.Clear;
var
  I: Integer;
begin
  EnterCriticalSection(FLock);
  try
    for I := 0 to FMap.Count - 1 do
      FMap.Data[I].Free;
    FMap.Clear;
    FBytes := 0;
    FUnusedBytes := 0;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TCADResultCache.Stats: TCADCacheStats;
var
  I: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Result.Count := FMap.Count;
    Result.InUse := 0;
    for I := 0 to FMap.Count - 1 do
      if FMap.Data[I].UseCount > 0 then
        Inc(Result.InUse);
    Result.Bytes := FBytes;
    Result.Hits := FHits;
    Result.Misses := FMisses;
    Result.Evictions := FEvictions;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

end.
