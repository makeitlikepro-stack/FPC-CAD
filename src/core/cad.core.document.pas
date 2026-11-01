unit CAD.Core.Document;
{$mode objfpc}{$H+}

{ ROLE:      the model: owns features, keeps the dependency graph, and runs
             the recompute (plan -> parallel levels -> cache -> display
             pass -> report).
  CALLED BY: commands (edits), UI and tests (Recompute, Find, report).
  CALLS:     Graph, RecomputePlan, WorkerPool, ResultCache, Feature,
             DisplayPass, Config.Performance.
  THREADS:   edits and Recompute on the UI thread. Inside Recompute,
             ComputeOne runs on worker threads; it touches only its own
             feature and the thread-safe cache.
  SPEED:     Find is an array index. Recompute visits only changed features
             and their users, skips every feature whose key is unchanged or
             cached, and runs each level in parallel. Meshes are made only
             for shown results, after the levels (CAD.Core.DisplayPass). }

interface

uses
  Classes, SysUtils, CAD.Core.Ids, CAD.Core.Values, CAD.Core.Feature,
  CAD.Core.Graph, CAD.Core.RecomputePlan, CAD.Core.WorkerPool,
  CAD.Core.ResultCache, CAD.Core.DisplayPass, CAD.Config.Performance,
  CAD.Core.ObjectModel, CAD.Core.ObjectIds;

type
  TCADRecomputeReport = record
    Planned: Integer;       { dirty features in the plan }
    Computed: Integer;      { real Compute calls }
    CacheHits: Integer;     { results reused from the cache or unchanged }
    Failed: Integer;
    Blocked: Integer;
    Levels: Integer;
    Threads: Integer;       { workers + the calling thread }
    Display: TCADDisplayReport;  { meshes for shown results (all zero when
                                   Mesh.Timing <> cmtDisplayed) }
    Milliseconds: QWord;    { model + display }
  end;

  TCADDocument = class
  private
    FSlots: array of TCADFeature;     { slot = id; nil = removed, never reused }
    FSlotCount: LongInt;
    FGraph: TCADDependencyGraph;
    FPlan: TCADRecomputePlan;
    FCache: TCADResultCache;
    FObjects: TCADObjectModel;       { logical Part, Datum, Sketch and Body IDs }
    FPool: TCADWorkerPool;
    FOptions: TCADPerformanceOptions;
    FChanged: TCADIntArray;           { slots edited since the last recompute }
    FLevel: TCADIntArray;             { level being computed (worker input) }
    FComputed, FHits, FFailed, FBlocked: LongInt;   { atomic counters }
    FRevision: QWord;
    FDisplayDirty: Boolean;           { shown set or results changed since the
                                        last display pass }
    procedure MarkChanged(ASlot: LongInt);
    procedure ComputeOne(AIndex: Integer);
    procedure RunLevels(var AReport: TCADRecomputeReport);
    procedure ReleaseResult(AFeature: TCADFeature);
    procedure RebuildPool;
    function SlotOf(const AId: TCADId): LongInt;
    function GetObjectRevision: QWord;
  public
    constructor Create;
    constructor CreateWithOptions(const AOptions: TCADPerformanceOptions);
    destructor Destroy; override;

    { --- structure (use commands from the UI, so Undo works) --- }
    { Takes ownership; returns the new, never reused id. }
    function AttachFeature(AFeature: TCADFeature): TCADId;
    { Gives ownership back to the caller (an undo command). The feature must
      have no users. Returns nil when it cannot be detached. }
    function DetachFeature(const AId: TCADId): TCADFeature;
    { Puts a detached feature back under its old id. }
    function ReattachFeature(AFeature: TCADFeature): Boolean;
    function TryLink(const AUser, AInput: TCADId; out AError: string): Boolean;
    function Unlink(const AUser, AInput: TCADId): Boolean;

    { --- data --- }
    function Find(const AId: TCADId): TCADFeature;
    function SetParam(const AId: TCADId; const AName: string; const AValue: TCADValue): Boolean;
    procedure Touch(const AId: TCADId);
    function UserCount(const AId: TCADId): Integer;
    { Validate a Body tip transition against current feature graph. }
    function TrySetBodyTip(const ABody: TCADObjectRef;
      const ANewTip: TCADId; out AError: string): Boolean;
    { Show a feature mid-tree, hide it, or back to auto (end of a chain).
      Not an undo step: a view setting, like a camera. }
    function SetShowMode(const AId: TCADId; AMode: TCADShowMode): Boolean;
    { Shown in the viewport now (same rule as the display pass). }
    function IsShown(const AId: TCADId): Boolean;

    { --- recompute --- }
    function NeedsRecompute: Boolean;
    { 1. model levels (parallel)  2. display pass when Mesh.Timing =
      cmtDisplayed. Also runs when only the shown set changed. }
    function Recompute: TCADRecomputeReport;
    { Meshes every shown result that has none. Recompute calls it; call it
      yourself when Mesh.Timing = cmtManual. UI thread, not during Recompute. }
    function PrepareDisplay: TCADDisplayReport;
    property NeedsDisplay: Boolean read FDisplayDirty;

    procedure SetOptions(const AOptions: TCADPerformanceOptions);
    property Options: TCADPerformanceOptions read FOptions;
    property Cache: TCADResultCache read FCache;
    { Logical objects own no OCCT handles. Existing feature slots,
      graph, cache and display remain unchanged in this foundation gate. }
    property Objects: TCADObjectModel read FObjects;
    { Logical object metadata has its own revision; not a recompute trigger. }
    property ObjectRevision: QWord read GetObjectRevision;
    property Graph: TCADDependencyGraph read FGraph;
    property SlotCount: LongInt read FSlotCount;
    { Feature graph/parameter revision (legacy API, unchanged by object edits). }
    property Revision: QWord read FRevision;
  end;

implementation

constructor TCADDocument.Create;
begin
  CreateWithOptions(DefaultPerformanceOptions);
end;

constructor TCADDocument.CreateWithOptions(const AOptions: TCADPerformanceOptions);
begin
  inherited Create;
  FOptions := AOptions;
  FGraph := TCADDependencyGraph.Create;
  FPlan := TCADRecomputePlan.Create;
  FCache := TCADResultCache.Create(FOptions.Cache.Enabled, FOptions.Cache.MaxBytes);
  FObjects := TCADObjectModel.Create;
  RebuildPool;
end;

destructor TCADDocument.Destroy;
var
  I: Integer;
begin
  FPool.Free;                       { stop workers first }
  for I := 0 to FSlotCount - 1 do
    FSlots[I].Free;                 { results belong to the cache }
  FObjects.Free;
  FCache.Free;
  FPlan.Free;
  FGraph.Free;
  inherited Destroy;
end;

function TCADDocument.GetObjectRevision: QWord;
begin
  Result := FObjects.Revision;
end;

procedure TCADDocument.RebuildPool;
begin
  FreeAndNil(FPool);
  FPool := TCADWorkerPool.Create(
    ResolveRecomputeThreads(FOptions.Threads, TThread.ProcessorCount));
end;

procedure TCADDocument.SetOptions(const AOptions: TCADPerformanceOptions);
var
  OldWorkers: Integer;
begin
  OldWorkers := FPool.WorkerCount;
  FOptions := AOptions;
  FCache.Configure(FOptions.Cache.Enabled, FOptions.Cache.MaxBytes);
  if ResolveRecomputeThreads(FOptions.Threads, TThread.ProcessorCount) <> OldWorkers then
    RebuildPool;
end;

function TCADDocument.SlotOf(const AId: TCADId): LongInt;
begin
  Result := AId.Slot;
  if (Result < 0) or (Result >= FSlotCount) or (FSlots[Result] = nil) then
    Result := -1;
end;

function TCADDocument.Find(const AId: TCADId): TCADFeature;
var
  S: LongInt;
begin
  S := SlotOf(AId);
  if S < 0 then
    Exit(nil);
  Result := FSlots[S];
end;

procedure TCADDocument.MarkChanged(ASlot: LongInt);
begin
  { Duplicates are harmless: CollectDirty keeps each slot once. }
  CADIntAppend(FChanged, ASlot);
  Inc(FRevision);
end;

function TCADDocument.AttachFeature(AFeature: TCADFeature): TCADId;
begin
  if FSlotCount >= Length(FSlots) then
    SetLength(FSlots, FSlotCount * 2 + 16);
  FSlots[FSlotCount] := AFeature;
  Result := CADId(FSlotCount);
  Inc(FSlotCount);
  AFeature.SetId(Result);
  AFeature.SetInputs(nil);
  AFeature.SetState(cfsDirty, '');
  FGraph.AddNode(Result.Slot);
  MarkChanged(Result.Slot);
end;

procedure TCADDocument.ReleaseResult(AFeature: TCADFeature);
begin
  FCache.Release(AFeature.Output);
  AFeature.SetResultRef(nil);
end;

function TCADDocument.DetachFeature(const AId: TCADId): TCADFeature;
var
  S, I: LongInt;
  Ins: TCADIdArray;
begin
  Result := nil;
  S := SlotOf(AId);
  if (S < 0) or (FGraph.UserCount(S) > 0) then
    Exit;
  { Any entry in Body history remains owned, including non-tip features. }
  if CADObjectIdValid(FObjects.FeatureOwner(AId)) then Exit;
  Result := FSlots[S];
  { Keep the inputs on the feature: Reattach links them again. }
  Ins := Copy(Result.Inputs);
  for I := 0 to High(Ins) do
    FGraph.Unlink(S, Ins[I].Slot);
  FGraph.RemoveNode(S);
  ReleaseResult(Result);             { the cache may keep it for a quick undo }
  Result.SetInputs(Ins);
  Result.SetState(cfsDirty, '');
  FSlots[S] := nil;
  Inc(FRevision);
  FDisplayDirty := True;             { its inputs may be chain ends now }
end;

function TCADDocument.ReattachFeature(AFeature: TCADFeature): Boolean;
var
  S, I: LongInt;
  Ins: TCADIdArray;
  Err: string;
begin
  S := AFeature.Id.Slot;
  Result := (S >= 0) and (S < FSlotCount) and (FSlots[S] = nil);
  if not Result then
    Exit;
  FSlots[S] := AFeature;
  FGraph.AddNode(S);
  Ins := Copy(AFeature.Inputs);
  AFeature.SetInputs(nil);
  for I := 0 to High(Ins) do
    if not TryLink(AFeature.Id, Ins[I], Err) then
      raise Exception.CreateFmt('Reattach %s: %s', [AFeature.Name, Err]);
  MarkChanged(S);
end;

function TCADDocument.TryLink(const AUser, AInput: TCADId; out AError: string): Boolean;
var
  F: TCADFeature;
  Ins: TCADIdArray;
begin
  F := Find(AUser);
  if (F = nil) or (Find(AInput) = nil) then
  begin
    AError := 'link to a missing feature';
    Exit(False);
  end;
  Result := FGraph.TryLink(AUser.Slot, AInput.Slot, AError);
  if not Result then
    Exit;
  Ins := Copy(F.Inputs);
  SetLength(Ins, Length(Ins) + 1);
  Ins[High(Ins)] := AInput;
  F.SetInputs(Ins);
  MarkChanged(AUser.Slot);
end;

function TCADDocument.Unlink(const AUser, AInput: TCADId): Boolean;
var
  F: TCADFeature;
  Ins: TCADIdArray;
  I, J, K: Integer;
  O: TCADModelObject;
  OwnerId: TCADObjectId;
begin
  F := Find(AUser);
  { The chain between consecutive Body history entries is structural.
    Do not silently break it with a general-purpose Unlink command. }
  OwnerId := FObjects.FeatureOwner(AUser);
  if CADObjectIdValid(OwnerId) and
     CADSameObjectId(OwnerId,FObjects.FeatureOwner(AInput)) then
  begin
    O := FObjects.Find(CADObjectRef(cokBody,OwnerId));
    if O <> nil then
      for K := 1 to O.FeatureCount-1 do
        if CADIdEqual(O.FeatureAt(K),AUser) and
           CADIdEqual(O.FeatureAt(K-1),AInput) then Exit(False);
  end;
  Result := (F <> nil) and FGraph.Unlink(AUser.Slot, AInput.Slot);
  if not Result then
    Exit;
  SetLength(Ins, Length(F.Inputs));
  J := 0;
  for I := 0 to High(F.Inputs) do
    if not CADIdEqual(F.Inputs[I], AInput) then
    begin
      Ins[J] := F.Inputs[I];
      Inc(J);
    end;
  SetLength(Ins, J);
  F.SetInputs(Ins);
  MarkChanged(AUser.Slot);
end;

function TCADDocument.SetParam(const AId: TCADId; const AName: string;
  const AValue: TCADValue): Boolean;
var
  F: TCADFeature;
  OldHash: TCADHash;
begin
  F := Find(AId);
  Result := (F <> nil) and F.HasParam(AName) and (F.GetParamValue(AName).Kind = AValue.Kind);
  if not Result then
    Exit;
  OldHash := F.ParamsHash;
  F.SetParamValue(AName, AValue);
  if F.ParamsHash <> OldHash then
    MarkChanged(AId.Slot);           { same value again: nothing to do }
end;

procedure TCADDocument.Touch(const AId: TCADId);
begin
  if SlotOf(AId) >= 0 then
    MarkChanged(AId.Slot);
end;

function TCADDocument.UserCount(const AId: TCADId): Integer;
begin
  if SlotOf(AId) < 0 then
    Exit(0);
  Result := FGraph.UserCount(AId.Slot);
end;

function TCADDocument.TrySetBodyTip(const ABody: TCADObjectRef;
  const ANewTip: TCADId; out AError: string): Boolean;
var
  O: TCADModelObject;
  OldTip: TCADId;
begin
  AError := '';
  O := FObjects.Find(ABody);
  if (O = nil) or (O.Kind <> cokBody) then
  begin
    AError := 'missing Body or incorrect object kind';
    Exit(False);
  end;
  OldTip := O.TipFeatureId;
  if CADIdEqual(OldTip, ANewTip) then
  begin
    AError := 'tip unchanged';
    Exit(False);
  end;
  if CADIdValid(ANewTip) and (Find(ANewTip) = nil) then
  begin
    AError := 'target feature does not exist';
    Exit(False);
  end;
  { A forward transition must consume the old tip. A backward transition
    is allowed for Undo when the old tip consumes the target feature. }
  if CADIdValid(OldTip) and CADIdValid(ANewTip) then
  begin
    { The registry only accepts a one-step pop or append. For an append
      the new feature must use the old tip, never the reverse. }
    if (O.FeatureCount > 1) and
       CADIdEqual(ANewTip,O.FeatureAt(O.FeatureCount-2)) then
    begin
      if not FGraph.HasLink(OldTip.Slot,ANewTip.Slot) then
      begin
        AError := 'previous Body history dependency is missing';
        Exit(False);
      end;
    end
    else if not FGraph.HasLink(ANewTip.Slot,OldTip.Slot) then
    begin
      AError := 'new Body tip must depend on the current tip';
      Exit(False);
    end;
  end;
  Result := FObjects.TryAssignBodyTip(ABody, ANewTip, AError);
end;

function TCADDocument.SetShowMode(const AId: TCADId; AMode: TCADShowMode): Boolean;
var
  F: TCADFeature;
begin
  F := Find(AId);
  Result := F <> nil;
  if (not Result) or (F.ShowMode = AMode) then
    Exit;
  F.SetShowMode(AMode);
  Inc(FRevision);
  FDisplayDirty := True;
end;

function TCADDocument.IsShown(const AId: TCADId): Boolean;
var
  F: TCADFeature;
begin
  F := Find(AId);
  Result := (F <> nil) and CADIsShown(F, FGraph.UserCount(AId.Slot));
end;

function TCADDocument.NeedsRecompute: Boolean;
begin
  Result := Length(FChanged) > 0;
end;

{ Runs on a worker thread (or the calling thread). Reads only inputs that are
  in earlier levels, writes only this feature, uses the thread-safe cache. }
procedure TCADDocument.ComputeOne(AIndex: Integer);
var
  F, Inp: TCADFeature;
  Inputs: TCADResultArray;
  I: Integer;
  Key: TCADHash;
  R: TCADResult;
  Err: string;
begin
  F := FSlots[FLevel[AIndex]];
  SetLength(Inputs, Length(F.Inputs));
  for I := 0 to High(F.Inputs) do
  begin
    Inp := FSlots[F.Inputs[I].Slot];
    if (Inp.State <> cfsClean) or (Inp.Output = nil) then
    begin
      ReleaseResult(F);
      F.SetState(cfsBlocked, 'input "' + Inp.Name + '" has no valid result');
      InterLockedIncrement(FBlocked);
      Exit;
    end;
    Inputs[I] := Inp.Output;
  end;
  Key := F.BuildKey(Inputs);
  { 1. Unchanged: same parameters and same input results as last time. }
  if (F.Output <> nil) and (F.Output.Key = Key) then
  begin
    F.SetState(cfsClean, '');
    InterLockedIncrement(FHits);
    Exit;
  end;
  { 2. Seen before (undo, drag back, same feature twice): from the cache. }
  R := FCache.Acquire(Key);
  if R = nil then
  begin
    { 3. Real work. }
    if not F.RunCompute(Inputs, R, Err) then
    begin
      ReleaseResult(F);
      F.SetState(cfsFailed, Err);
      InterLockedIncrement(FFailed);
      Exit;
    end;
    R.Key := Key;
    R := FCache.Store(R);
    InterLockedIncrement(FComputed);
  end
  else
    InterLockedIncrement(FHits);
  ReleaseResult(F);
  F.SetResultRef(R);
  F.SetState(cfsClean, '');
end;

{ Step 1 of Recompute: dirty set -> plan -> levels (each level parallel). }
procedure TCADDocument.RunLevels(var AReport: TCADRecomputeReport);
var
  Dirty: TCADIntArray;
  L, I: Integer;
begin
  FGraph.CollectDirty(FChanged, Dirty);
  FChanged := nil;
  FPlan.Build(FGraph, Dirty);
  for I := 0 to High(Dirty) do
    FSlots[Dirty[I]].SetState(cfsDirty, '');
  FComputed := 0; FHits := 0; FFailed := 0; FBlocked := 0;
  for L := 0 to FPlan.LevelCount - 1 do
  begin
    FLevel := FPlan.Levels[L];
    if Length(FLevel) < FOptions.Threads.MinFeaturesForParallel then
      for I := 0 to High(FLevel) do
        ComputeOne(I)                { not worth waking the workers }
    else
      FPool.Run(Length(FLevel), @ComputeOne);
  end;
  FLevel := nil;
  AReport.Planned := FPlan.FeatureCount;
  AReport.Levels := FPlan.LevelCount;
  AReport.Computed := FComputed;
  AReport.CacheHits := FHits;
  AReport.Failed := FFailed;
  AReport.Blocked := FBlocked;
  FDisplayDirty := True;             { new results may need meshes }
end;

function TCADDocument.Recompute: TCADRecomputeReport;
var
  T0: QWord;
begin
  T0 := GetTickCount64;
  FillChar(Result, SizeOf(Result), 0);
  Result.Threads := FPool.WorkerCount + 1;
  if Length(FChanged) > 0 then
    RunLevels(Result);                                  { 1. model }
  if FDisplayDirty and (FOptions.Mesh.Timing = cmtDisplayed) then
    Result.Display := PrepareDisplay;                   { 2. meshes, shown only }
  Result.Milliseconds := GetTickCount64 - T0;
end;

function TCADDocument.PrepareDisplay: TCADDisplayReport;
begin
  Result := RunDisplayPass(FSlots, FSlotCount, FGraph, FCache);
  FDisplayDirty := False;
end;

end.
