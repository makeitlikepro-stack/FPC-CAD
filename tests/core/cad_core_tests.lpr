program cad_core_tests;
{$mode objfpc}{$H+}

{ Headless tests of the FPC-CAD core (no OCCT, no OpenGL, no LCL).
  Run: bash scripts/test_core.sh
  Sections follow docs/CODE_FLOW.md: ids/values -> registry -> graph ->
  plan -> document recompute -> cache -> undo/redo -> failures -> display
  pass -> speed. }

uses
  {$ifdef unix}cthreads,{$endif}
  Classes, SysUtils, CAD.Core.Ids, CAD.Core.Values, CAD.Core.Feature,
  CAD.Core.FeatureRegistry, CAD.Core.Graph, CAD.Core.RecomputePlan,
  CAD.Core.WorkerPool, CAD.Core.ResultCache, CAD.Core.DisplayPass, CAD.Core.Document,
  CAD.Core.Commands, CAD.Core.History, CAD.Config.Performance;

var
  Checks, Failures: Integer;
  ComputeCalls: LongInt;          { all test features, atomic }
  PrepareCalls: Integer;          { TNumResult.PrepareDisplay (calling thread) }

procedure Check(ACondition: Boolean; const AName: string);
begin
  Inc(Checks);
  if not ACondition then
  begin
    Inc(Failures);
    WriteLn('FAIL  ', AName);
  end;
end;

{ ---------------------------------------------------------------- test features }

type
  { Stands in for an OCCT shape: "meshing" sets Meshed and adds 1000 bytes. }
  TNumResult = class(TCADResult)
  public
    Value: Double;
    Meshed: Boolean;
    function EstimatedBytes: Int64; override;
    function DisplayReady: Boolean; override;
    function PrepareDisplay(out AError: string): Boolean; override;
  end;

  { value }
  TConstFeature = class(TCADFeature)
  protected
    procedure DefineParams; override;
    function Compute(const AInputs: array of TCADResult; out AResult: TCADResult;
      out AError: string): Boolean; override;
  public
    class function TypeName: string; override;
  end;

  { scale * sum(inputs), optional sleep to simulate a slow OCCT call }
  TSumFeature = class(TCADFeature)
  protected
    procedure DefineParams; override;
    function Compute(const AInputs: array of TCADResult; out AResult: TCADResult;
      out AError: string): Boolean; override;
  public
    class function TypeName: string; override;
  end;

  { mode 0 = ok (value 1), 1 = returns False, 2 = raises }
  TFailFeature = class(TCADFeature)
  protected
    procedure DefineParams; override;
    function Compute(const AInputs: array of TCADResult; out AResult: TCADResult;
      out AError: string): Boolean; override;
  public
    class function TypeName: string; override;
  end;

  TOtherConst = class(TConstFeature)
  public
    class function TypeName: string; override;
  end;

function TNumResult.EstimatedBytes: Int64;
begin
  Result := InstanceSize + 1000 * Ord(Meshed);
end;

function TNumResult.DisplayReady: Boolean;
begin
  Result := Meshed;
end;

function TNumResult.PrepareDisplay(out AError: string): Boolean;
begin
  AError := '';
  Inc(PrepareCalls);
  Meshed := True;
  Result := True;
end;

class function TConstFeature.TypeName: string;
begin
  Result := 'Const';
end;

procedure TConstFeature.DefineParams;
begin
  AddParam('value', CADFloat(0));
end;

function TConstFeature.Compute(const AInputs: array of TCADResult;
  out AResult: TCADResult; out AError: string): Boolean;
var
  R: TNumResult;
begin
  InterLockedIncrement(ComputeCalls);
  AError := '';
  R := TNumResult.Create;
  R.Value := GetParamValue('value').F;
  AResult := R;
  Result := True;
end;

class function TOtherConst.TypeName: string;
begin
  Result := 'const';      { same name, different class: must be rejected }
end;

class function TSumFeature.TypeName: string;
begin
  Result := 'Sum';
end;

procedure TSumFeature.DefineParams;
begin
  AddParam('scale', CADFloat(1));
  AddParam('workMs', CADInt(0));
end;

function TSumFeature.Compute(const AInputs: array of TCADResult;
  out AResult: TCADResult; out AError: string): Boolean;
var
  R: TNumResult;
  I: Integer;
  S: Double;
begin
  InterLockedIncrement(ComputeCalls);
  AError := '';
  if GetParamValue('workMs').I > 0 then
    Sleep(GetParamValue('workMs').I);
  S := 0;
  for I := 0 to High(AInputs) do
    S := S + TNumResult(AInputs[I]).Value;
  R := TNumResult.Create;
  R.Value := S * GetParamValue('scale').F;
  AResult := R;
  Result := True;
end;

class function TFailFeature.TypeName: string;
begin
  Result := 'Fail';
end;

procedure TFailFeature.DefineParams;
begin
  AddParam('mode', CADInt(0));
end;

function TFailFeature.Compute(const AInputs: array of TCADResult;
  out AResult: TCADResult; out AError: string): Boolean;
var
  R: TNumResult;
begin
  InterLockedIncrement(ComputeCalls);
  AResult := nil;
  AError := '';
  case GetParamValue('mode').I of
    1:
      begin
        AError := 'profile is not closed';
        Exit(False);
      end;
    2:
      raise Exception.Create('kernel exception');
  end;
  R := TNumResult.Create;
  R.Value := 1;
  AResult := R;
  Result := True;
end;

{ ---------------------------------------------------------------- helpers }

function NewConst(AValue: Double): TConstFeature;
begin
  Result := TConstFeature.Create;
  Result.SetParamValue('value', CADFloat(AValue));
end;

function NewSum(AScale: Double; AWorkMs: Integer = 0): TSumFeature;
begin
  Result := TSumFeature.Create;
  Result.SetParamValue('scale', CADFloat(AScale));
  Result.SetParamValue('workMs', CADInt(AWorkMs));
end;

function Num(ADoc: TCADDocument; const AId: TCADId): Double;
var
  F: TCADFeature;
begin
  F := ADoc.Find(AId);
  if (F = nil) or (F.Output = nil) then
    Exit(-99999);
  Result := TNumResult(F.Output).Value;
end;

function Link(ADoc: TCADDocument; const AUser, AInput: TCADId): Boolean;
var
  Err: string;
begin
  Result := ADoc.TryLink(AUser, AInput, Err);
end;

function SerialOptions: TCADPerformanceOptions;
begin
  Result := DefaultPerformanceOptions;
  Result.Threads.RecomputeThreads := 1;
end;

{ ---------------------------------------------------------------- 1. ids, values }

procedure TestIdsAndValues;
var
  H1, H2: TCADHash;
begin
  Check(CADIdValid(CADId(0)) and not CADIdValid(CADNoId), 'id validity');
  H1 := CADHashString(CAD_HASH_SEED, 'Extrude');
  H2 := CADHashString(CAD_HASH_SEED, 'Extrude');
  Check(H1 = H2, 'hash is deterministic');
  Check(CADHashString(CAD_HASH_SEED, 'ab') <> CADHashString(CAD_HASH_SEED, 'ba'), 'hash depends on order');
  Check(CADHashString(CADHashString(CAD_HASH_SEED, 'ab'), 'c') <>
        CADHashString(CADHashString(CAD_HASH_SEED, 'a'), 'bc'), 'string hash includes length');
  Check(CADValueHash(CAD_HASH_SEED, CADFloat(0.0)) = CADValueHash(CAD_HASH_SEED, CADFloat(-0.0)), '-0.0 hashes like 0.0');
  Check(CADValueHash(CAD_HASH_SEED, CADInt(1)) <> CADValueHash(CAD_HASH_SEED, CADFloat(1)), 'int 1 and float 1 differ');
  Check(CADValueEqual(CADText('a'), CADText('a')) and not CADValueEqual(CADText('a'), CADInt(0)), 'value equality');
end;

{ ---------------------------------------------------------------- 2. registry }

procedure TestRegistry;
var
  F: TCADFeature;
  Raised: Boolean;
begin
  CADFeatures.Register(TConstFeature);
  CADFeatures.Register(TSumFeature);
  CADFeatures.Register(TConstFeature);          { same class again: ignored }
  Check(CADFeatures.FindClass('CONST') = TConstFeature, 'registry lookup is case-insensitive');
  Raised := False;
  try
    CADFeatures.Register(TOtherConst);
  except
    Raised := True;
  end;
  Check(Raised, 'registry rejects a second class with the same name');
  F := CADFeatures.CreateFeature('Sum');
  Check((F is TSumFeature) and F.HasParam('scale'), 'registry creates features with parameters');
  F.Free;
  Check(CADFeatures.CreateFeature('Nope') = nil, 'unknown type gives nil');
end;

{ ---------------------------------------------------------------- 3. graph + plan }

procedure TestGraphAndPlan;
var
  G: TCADDependencyGraph;
  P: TCADRecomputePlan;
  Err: string;
  Dirty, Changed: TCADIntArray;
begin
  G := TCADDependencyGraph.Create;
  P := TCADRecomputePlan.Create;
  try
    G.AddNode(0); G.AddNode(1); G.AddNode(2); G.AddNode(3); G.AddNode(4);
    { diamond: 1,2 use 0; 3 uses 1,2. 4 is unrelated }
    Check(G.TryLink(1, 0, Err) and G.TryLink(2, 0, Err) and G.TryLink(3, 1, Err) and
      G.TryLink(3, 2, Err), 'graph links');
    Check(not G.TryLink(1, 0, Err) and (Pos('exists', Err) > 0), 'duplicate link rejected');
    Check(not G.TryLink(1, 1, Err), 'self link rejected');
    Check(not G.TryLink(0, 3, Err) and (Pos('cycle', Err) > 0), 'cycle rejected');
    Check(not G.RemoveNode(0), 'node with users cannot be removed');

    Changed := nil;
    CADIntAppend(Changed, 1);
    CADIntAppend(Changed, 1);
    G.CollectDirty(Changed, Dirty);
    Check((Length(Dirty) = 2) and CADIntContains(Dirty, 1) and CADIntContains(Dirty, 3), 'dirty = changed + users, once each');

    Changed := nil;
    CADIntAppend(Changed, 0);
    CADIntAppend(Changed, 4);
    G.CollectDirty(Changed, Dirty);
    P.Build(G, Dirty);
    Check(P.FeatureCount = 5, 'plan places every dirty feature');
    Check(P.LevelCount = 3, 'diamond has 3 levels');
    Check((Length(P.Levels[0]) = 2) and CADIntContains(P.Levels[0], 0) and CADIntContains(P.Levels[0], 4), 'level 0 = roots');
    Check((Length(P.Levels[1]) = 2) and CADIntContains(P.Levels[1], 1) and CADIntContains(P.Levels[1], 2), 'level 1 = parallel branch');
    Check((Length(P.Levels[2]) = 1) and (P.Levels[2][0] = 3), 'level 2 = join');

    Check(G.Unlink(3, 1) and not G.HasLink(3, 1) and (G.UserCount(1) = 0), 'unlink');
    Check(G.Unlink(3, 2) and G.RemoveNode(3) and not G.IsAlive(3), 'remove after unlink');
  finally
    P.Free;
    G.Free;
  end;
end;

{ ---------------------------------------------------------------- 4. recompute + cache }

procedure TestRecomputeAndCache;
var
  D: TCADDocument;
  A, B, C, S: TCADId;
  R: TCADRecomputeReport;
  Before: LongInt;
begin
  D := TCADDocument.CreateWithOptions(SerialOptions);
  try
    A := D.AttachFeature(NewConst(2));
    B := D.AttachFeature(NewSum(10));
    C := D.AttachFeature(NewSum(100));
    S := D.AttachFeature(NewSum(1));
    Check(Link(D, B, A) and Link(D, C, A) and Link(D, S, B) and Link(D, S, C), 'document links');
    R := D.Recompute;
    Check((R.Planned = 4) and (R.Computed = 4) and (R.Levels = 3), 'first recompute computes all');
    Check((Num(D, B) = 20) and (Num(D, C) = 200) and (Num(D, S) = 220), 'values flow through the graph');
    Check(not D.NeedsRecompute and (D.Recompute.Planned = 0), 'nothing to do when clean');

    D.SetParam(C, 'scale', CADFloat(1000));
    R := D.Recompute;
    Check((R.Planned = 2) and (R.Computed = 2), 'only the edited feature and its users recompute');
    Check(Num(D, S) = 2020, 'edited value propagates');

    D.SetParam(C, 'scale', CADFloat(1000));
    Check(not D.NeedsRecompute, 'setting the same value marks nothing');

    Before := ComputeCalls;
    D.SetParam(C, 'scale', CADFloat(100));
    R := D.Recompute;
    Check((R.Computed = 0) and (R.CacheHits = 2) and (ComputeCalls = Before), 'old value comes back from the cache');
    Check(Num(D, S) = 220, 'cached values are correct');

    D.Touch(A);
    R := D.Recompute;
    Check((R.Planned = 4) and (R.Computed = 0) and (R.CacheHits = 4), 'touch without change: all unchanged keys');
    Check(D.Cache.Stats.Hits > 0, 'cache statistics count hits');
  finally
    D.Free;
  end;
end;

procedure TestCacheLimit;
var
  C: TCADResultCache;
  R1, R2, R3: TCADResult;
begin
  C := TCADResultCache.Create(True, 0);           { keep nothing unused }
  try
    R1 := TNumResult.Create; R1.Key := 1;
    R1 := C.Store(R1);
    R2 := TNumResult.Create; R2.Key := 1;
    R2 := C.Store(R2);
    Check((R1 = R2) and (R1.UseCount = 2) and (C.Stats.Count = 1), 'same key stored once, shared');
    C.Release(R1);
    C.Release(R2);
    Check((C.Stats.Count = 0) and (C.Stats.Evictions = 1), 'unused result evicted at limit 0');
    R3 := TNumResult.Create; R3.Key := 7;
    R3 := C.Store(R3);
    C.Configure(True, 1024 * 1024);
    C.Release(R3);
    Check((C.Stats.Count = 1) and (C.Acquire(7) = R3), 'unused result kept under the limit');
    C.Release(R3);
  finally
    C.Free;
  end;
end;

{ ---------------------------------------------------------------- 5. undo / redo }

procedure TestHistory;
var
  D: TCADDocument;
  H: TCADHistory;
  A, B, X: TCADId;
  Add: TCADAddFeatureCommand;
  I: Integer;
  R: TCADRecomputeReport;
begin
  D := TCADDocument.CreateWithOptions(SerialOptions);
  H := TCADHistory.Create(D);
  try
    Add := TCADAddFeatureCommand.Create(NewConst(3), []);
    Check(H.Execute(Add), 'add command');
    A := Add.Id;
    Add := TCADAddFeatureCommand.Create(NewSum(2), [A]);
    Check(H.Execute(Add), 'add command with input');
    B := Add.Id;
    D.Recompute;
    Check(Num(D, B) = 6, 'added features compute');

    for I := 1 to 100 do
      H.Execute(TCADSetParamCommand.Create(A, 'value', CADFloat(3 + I)), True);
    D.Recompute;
    Check(Num(D, B) = 206, 'merged drag reaches the last value');
    Check(H.Undo, 'undo merged drag');
    R := D.Recompute;
    Check((Num(D, B) = 6) and (R.Computed = 0), 'one undo step restores the start, from the cache');
    Check(H.Redo and (D.Recompute.Computed = 0) and (Num(D, B) = 206), 'redo from the cache');

    Check(not H.Execute(TCADRemoveFeatureCommand.Create(A)), 'cannot remove a used feature');
    Check(H.Execute(TCADRemoveFeatureCommand.Create(B)) and (D.Find(B) = nil), 'remove unused feature');
    Check(H.Undo and (D.Find(B) <> nil) and CADIdEqual(D.Find(B).Id, B), 'undo remove keeps the id');
    D.Recompute;
    Check(Num(D, B) = 206, 'restored feature is linked again');

    H.Undo;                                  { redo stack: remove }
    H.Undo;                                  { add B undone }
    Check(D.Find(B) = nil, 'undo add detaches the feature');
    Check(H.Redo and CADIdEqual(D.Find(B).Id, B), 'redo add brings back the same id');
    D.Recompute;
    Check(Num(D, B) = 6, 'redone feature computes with its old input');

    Add := TCADAddFeatureCommand.Create(NewSum(1), [B]);
    H.Execute(Add);
    X := Add.Id;
    Check(not H.Execute(TCADLinkCommand.Create(B, X)), 'link command rejects a cycle');
    Check(not H.CanRedo, 'a new edit clears redo');
  finally
    H.Free;                                  { before the document }
    D.Free;
  end;
end;

{ ---------------------------------------------------------------- 6. failures }

procedure TestFailures;
var
  D: TCADDocument;
  Bad, Raise1, Ok1, User1, User2, Other: TCADId;
  F: TCADFeature;
  R: TCADRecomputeReport;
begin
  D := TCADDocument.Create;
  try
    F := TFailFeature.Create;
    F.SetParamValue('mode', CADInt(1));
    Bad := D.AttachFeature(F);
    F := TFailFeature.Create;
    F.SetParamValue('mode', CADInt(2));
    Raise1 := D.AttachFeature(F);
    Ok1 := D.AttachFeature(TFailFeature.Create);
    User1 := D.AttachFeature(NewSum(1));
    User2 := D.AttachFeature(NewSum(1));
    Other := D.AttachFeature(NewSum(1));
    Link(D, User1, Bad);
    Link(D, User2, User1);
    Link(D, Other, Ok1);
    R := D.Recompute;
    Check((R.Failed = 2) and (R.Blocked = 2), 'two failed, their users blocked');
    Check((D.Find(Bad).State = cfsFailed) and (Pos('not closed', D.Find(Bad).LastError) > 0), 'failure keeps the message');
    Check((D.Find(Raise1).State = cfsFailed) and (Pos('kernel exception', D.Find(Raise1).LastError) > 0), 'exception becomes a failure');
    Check(D.Find(User2).State = cfsBlocked, 'block goes down the chain');
    Check((D.Find(Other).State = cfsClean) and (Num(D, Other) = 1), 'independent branch still computes');
    D.SetParam(Bad, 'mode', CADInt(0));
    D.Recompute;
    Check((D.Find(User2).State = cfsClean) and (Num(D, User2) = 1), 'fixing the input unblocks the users');
  finally
    D.Free;
  end;
end;

{ ---------------------------------------------------------------- 7. speed + threads }

function TimeLevel(AThreads: Integer): QWord;
var
  O: TCADPerformanceOptions;
  D: TCADDocument;
  Root: TCADId;
  I: Integer;
  R: TCADRecomputeReport;
begin
  O := DefaultPerformanceOptions;
  O.Threads.RecomputeThreads := AThreads;
  O.Cache.Enabled := False;
  D := TCADDocument.CreateWithOptions(O);
  try
    Root := D.AttachFeature(NewConst(1));
    for I := 1 to 8 do
      Link(D, D.AttachFeature(NewSum(I, 40)), Root);   { 8 independent 40 ms features }
    R := D.Recompute;
    Check((R.Computed = 9) and (R.Levels = 2), Format('timing doc computes (threads %d)', [AThreads]));
    Result := R.Milliseconds;
  finally
    D.Free;
  end;
end;

procedure TestParallelSpeed;
var
  Serial, Parallel: QWord;
begin
  Serial := TimeLevel(1);
  Parallel := TimeLevel(4);
  WriteLn(Format('INFO  8 x 40 ms features: serial %d ms, 4 threads %d ms', [Serial, Parallel]));
  Check(Serial >= 300, 'serial run takes the sum of the work');
  Check(Parallel * 2 < Serial, 'a level on 4 threads is at least 2x faster');
end;

procedure TestThreadStress;
var
  O: TCADPerformanceOptions;
  D: TCADDocument;
  Root: TCADId;
  Ids: array[0..199] of TCADId;
  I, Round, Wrong: Integer;
begin
  O := DefaultPerformanceOptions;
  O.Threads.RecomputeThreads := 8;
  D := TCADDocument.CreateWithOptions(O);
  try
    Root := D.AttachFeature(NewConst(1));
    for I := 0 to High(Ids) do
    begin
      Ids[I] := D.AttachFeature(NewSum(I));
      Link(D, Ids[I], Root);
    end;
    Wrong := 0;
    for Round := 1 to 50 do
    begin
      D.SetParam(Root, 'value', CADFloat(Round));
      D.Recompute;
      for I := 0 to High(Ids) do
        if Num(D, Ids[I]) <> Round * I then
          Inc(Wrong);
    end;
    Check(Wrong = 0, 'parallel recompute: 50 rounds x 200 features all correct');
  finally
    D.Free;
  end;
end;

{ ---------------------------------------------------------------- 7. display pass }

function IsMeshed(ADoc: TCADDocument; const AId: TCADId): Boolean;
begin
  Result := TNumResult(ADoc.Find(AId).Output).Meshed;
end;

procedure TestDisplayPass;
var
  D: TCADDocument;
  O: TCADPerformanceOptions;
  A, B, C, E: TCADId;
  R: TCADRecomputeReport;
  Dp: TCADDisplayReport;
  Detached: TCADFeature;
  Bytes0: Int64;
begin
  D := TCADDocument.CreateWithOptions(SerialOptions);
  try
    { A -> B -> C: only C (end of the chain) is shown and meshed. }
    A := D.AttachFeature(NewConst(1));
    B := D.AttachFeature(NewSum(1));
    C := D.AttachFeature(NewSum(1));
    Link(D, B, A);
    Link(D, C, B);
    PrepareCalls := 0;
    R := D.Recompute;
    Check((R.Display.Shown = 1) and (R.Display.Prepared = 1) and (PrepareCalls = 1),
      'display pass: one shown result, one mesh');
    Check(IsMeshed(D, C) and not IsMeshed(D, A) and not IsMeshed(D, B), 'only the chain end is meshed');
    R := D.Recompute;
    Check((R.Planned = 0) and (R.Display.Prepared = 0) and not D.NeedsDisplay, 'clean: no display work');

    Check(D.SetShowMode(A, csmShow) and D.NeedsDisplay, 'csmShow marks the display pass');
    R := D.Recompute;
    Check((R.Planned = 0) and (R.Display.Prepared = 1) and IsMeshed(D, A), 'csmShow meshes a feature mid-tree');

    E := D.AttachFeature(NewSum(1));
    Link(D, E, C);
    R := D.Recompute;
    Check((R.Display.Prepared = 1) and IsMeshed(D, E) and not D.IsShown(C), 'new chain end meshed, old end hidden');
    Detached := D.DetachFeature(E);
    R := D.Recompute;
    Check((Detached <> nil) and D.IsShown(C) and (R.Display.Shown = 2) and (R.Display.Prepared = 0),
      'removing the end shows C again, its mesh is reused');
    Detached.Free;

    { cmtManual: the recompute makes no mesh; the caller asks for it. }
    O := SerialOptions;
    O.Mesh.Timing := cmtManual;
    D.SetOptions(O);
    D.SetParam(A, 'value', CADFloat(5));
    R := D.Recompute;
    Check((R.Computed = 3) and (R.Display.Prepared = 0) and D.NeedsDisplay, 'manual: recompute makes no mesh');
    Bytes0 := D.Cache.Stats.Bytes;
    Dp := D.PrepareDisplay;
    Check((Dp.Prepared = 2) and IsMeshed(D, A) and IsMeshed(D, C) and not IsMeshed(D, B),
      'manual PrepareDisplay meshes the shown results (A shown, C end)');
    Check(D.Cache.Stats.Bytes = Bytes0 + 2000, 'cache bytes grow by the mesh size (Remeasure)');
  finally
    D.Free;
  end;
end;

procedure TestOptions;
var
  O: TCADPerformanceOptions;
begin
  O := DefaultPerformanceOptions;
  Check(O.Mesh.InParallel and O.Booleans.RunParallel and O.Booleans.UseOBB, 'OCCT parallel options on by default');
  Check(O.Cache.Enabled and (O.Cache.MaxBytes > 0), 'cache on by default');
  Check(O.Mesh.Timing = cmtDisplayed, 'mesh only shown results by default');
  O.Threads.RecomputeThreads := 1;
  Check(ResolveRecomputeThreads(O.Threads, 16) = 0, '1 thread = no workers (serial)');
  O.Threads.RecomputeThreads := 0;
  Check(ResolveRecomputeThreads(O.Threads, 8) = 7, 'auto = cores - 1 workers + caller');
end;

begin
  Checks := 0;
  Failures := 0;
  ComputeCalls := 0;
  TestIdsAndValues;
  TestRegistry;
  TestGraphAndPlan;
  TestRecomputeAndCache;
  TestCacheLimit;
  TestHistory;
  TestFailures;
  TestDisplayPass;
  TestParallelSpeed;
  TestThreadStress;
  TestOptions;
  if Failures = 0 then
    WriteLn(Format('PASS  cad core: %d checks', [Checks]))
  else
    WriteLn(Format('FAIL  cad core: %d of %d checks failed', [Failures, Checks]));
  if Failures <> 0 then
    Halt(1);
end.
