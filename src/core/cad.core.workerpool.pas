unit CAD.Core.WorkerPool;
{$mode objfpc}{$H+}

{ ROLE:      runs N independent work items on a fixed set of threads and
             returns when all are done (one recompute level).
  CALLED BY: TCADDocument.Recompute, once per level.
  CALLS:     RTL threads and events (programs must use cthreads on Unix).
  THREADS:   Run is called from one thread at a time (the UI thread); the
             item procedure runs on the workers AND on the calling thread.
  SPEED:     threads are created once and sleep on an event between levels.
             Items are taken with one atomic increment each, so a slow item
             never holds up the others (no fixed split per thread). }

interface

uses
  Classes, SysUtils;

type
  TCADWorkItemProc = procedure(AIndex: Integer) of object;

  TCADWorkerPool = class;

  TCADWorkerThread = class(TThread)
  private
    FPool: TCADWorkerPool;
    FStart: PRTLEvent;
  protected
    procedure Execute; override;
  public
    constructor CreateWorker(APool: TCADWorkerPool);
    destructor Destroy; override;
  end;

  TCADWorkerPool = class
  private
    FWorkers: array of TCADWorkerThread;
    FDone: PRTLEvent;
    FProc: TCADWorkItemProc;
    FCount: LongInt;
    FNext: LongInt;             { next item index, taken atomically }
    FActive: LongInt;           { workers still inside the current batch }
    FTerminating: Boolean;
    FItemErrors: LongInt;       { items whose procedure raised (should be 0) }
    procedure WorkLoop;
  public
    { AWorkerCount extra threads; 0 = everything runs on the calling thread. }
    constructor Create(AWorkerCount: Integer);
    destructor Destroy; override;
    { Calls AProc(0..ACount-1), each index exactly once, and waits for all. }
    procedure Run(ACount: Integer; AProc: TCADWorkItemProc);
    function WorkerCount: Integer;
    property ItemErrors: LongInt read FItemErrors;
  end;

implementation

{ TCADWorkerThread }

constructor TCADWorkerThread.CreateWorker(APool: TCADWorkerPool);
begin
  FPool := APool;
  FStart := RTLEventCreate;
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TCADWorkerThread.Destroy;
begin
  RTLEventDestroy(FStart);
  inherited Destroy;
end;

procedure TCADWorkerThread.Execute;
begin
  while True do
  begin
    RTLEventWaitFor(FStart);            { sleeps here between levels }
    if FPool.FTerminating then
      Exit;
    FPool.WorkLoop;
    if InterLockedDecrement(FPool.FActive) = 0 then
      RTLEventSetEvent(FPool.FDone);
  end;
end;

{ TCADWorkerPool }

constructor TCADWorkerPool.Create(AWorkerCount: Integer);
var
  I: Integer;
begin
  inherited Create;
  FDone := RTLEventCreate;
  if AWorkerCount < 0 then
    AWorkerCount := 0;
  SetLength(FWorkers, AWorkerCount);
  for I := 0 to AWorkerCount - 1 do
    FWorkers[I] := TCADWorkerThread.CreateWorker(Self);
end;

destructor TCADWorkerPool.Destroy;
var
  I: Integer;
begin
  FTerminating := True;
  for I := 0 to High(FWorkers) do
    RTLEventSetEvent(FWorkers[I].FStart);
  for I := 0 to High(FWorkers) do
  begin
    FWorkers[I].WaitFor;
    FWorkers[I].Free;
  end;
  RTLEventDestroy(FDone);
  inherited Destroy;
end;

function TCADWorkerPool.WorkerCount: Integer;
begin
  Result := Length(FWorkers);
end;

procedure TCADWorkerPool.WorkLoop;
var
  I: LongInt;
begin
  while True do
  begin
    I := InterLockedIncrement(FNext) - 1;
    if I >= FCount then
      Exit;
    try
      FProc(I);
    except
      { Item procedures handle their own errors; this only keeps the
        thread alive if one does not. }
      InterLockedIncrement(FItemErrors);
    end;
  end;
end;

procedure TCADWorkerPool.Run(ACount: Integer; AProc: TCADWorkItemProc);
var
  I: Integer;
begin
  if ACount <= 0 then
    Exit;
  FProc := AProc;
  FCount := ACount;
  FNext := 0;
  if (Length(FWorkers) = 0) or (ACount = 1) then
  begin
    WorkLoop;                           { no thread wake-up for one item }
    Exit;
  end;
  FActive := Length(FWorkers);
  RTLEventResetEvent(FDone);
  { The atomic operations and events below publish FProc/FCount/FNext to
    the workers before they read them. }
  for I := 0 to High(FWorkers) do
    RTLEventSetEvent(FWorkers[I].FStart);
  WorkLoop;                             { the calling thread works too }
  RTLEventWaitFor(FDone);
end;

end.
