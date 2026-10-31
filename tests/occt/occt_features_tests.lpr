program occt_features_tests;
{$mode objfpc}{$H+}

{ Native tests: core document + OCCT features + bridge (needs OCCT).
  Run: bash scripts/test_occt.sh
  Covers: box/cylinder/boolean volumes, partial recompute after an edit,
  Undo served from the cache (no OCCT call), errors and blocking, display
  pass (only shown results get a mesh), 8 parallel chains (correctness +
  INFO timing: mesh every result vs mesh shown results only). }

uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils, Math, CAD.Core.Ids, CAD.Core.Values, CAD.Core.Feature,
  CAD.Core.Document, CAD.Core.Commands, CAD.Core.History,
  CAD.Config.Performance, CAD.OCCT.Bridge, CAD.OCCT.ShapeResult,
  CAD.Features.OCCTBase, CAD.Features.Box, CAD.Features.Cylinder,
  CAD.Features.BooleanOp;

var
  Checks, Failures: Integer;

procedure Check(ACondition: Boolean; const AName: string);
begin
  Inc(Checks);
  if not ACondition then
  begin
    Inc(Failures);
    WriteLn('FAIL  ', AName);
  end;
end;

function NewBox(X, Y, Z, DX, DY, DZ: Double): TCADBoxFeature;
begin
  Result := TCADBoxFeature.Create;
  Result.SetParamValue('x', CADFloat(X));
  Result.SetParamValue('y', CADFloat(Y));
  Result.SetParamValue('z', CADFloat(Z));
  Result.SetParamValue('dx', CADFloat(DX));
  Result.SetParamValue('dy', CADFloat(DY));
  Result.SetParamValue('dz', CADFloat(DZ));
end;

function NewCyl(X, Y, Z, R, H: Double): TCADCylinderFeature;
begin
  Result := TCADCylinderFeature.Create;
  Result.SetParamValue('x', CADFloat(X));
  Result.SetParamValue('y', CADFloat(Y));
  Result.SetParamValue('z', CADFloat(Z));
  Result.SetParamValue('radius', CADFloat(R));
  Result.SetParamValue('height', CADFloat(H));
end;

function NewBool(AOp: Integer): TCADBooleanFeature;
begin
  Result := TCADBooleanFeature.Create;
  Result.SetParamValue('op', CADInt(AOp));
end;

{ Relative tolerance: OCCT integrates curved faces numerically. }
function Near(A, B: Double): Boolean;
begin
  Result := Abs(A - B) <= 1e-6 * Max(1.0, Abs(B));
end;

function Vol(D: TCADDocument; const AId: TCADId): Double;
var
  F: TCADFeature;
begin
  F := D.Find(AId);
  if (F = nil) or not (F.Output is TOCCTShapeResult) then
    Exit(-1);
  Result := TOCCTShapeResult(F.Output).Volume;
end;

{ True when the feature's result has a mesh. }
function HasMesh(D: TCADDocument; const AId: TCADId): Boolean;
var
  F: TCADFeature;
begin
  F := D.Find(AId);
  Result := (F <> nil) and (F.Output is TOCCTShapeResult) and
    (TOCCTShapeResult(F.Output).Mesh <> nil) and
    (OCCT.MeshVertexCount(TOCCTShapeResult(F.Output).Mesh) > 0);
end;

function Link2(D: TCADDocument; const AUser, A, B: TCADId): Boolean;
var
  Err: string;
begin
  Result := D.TryLink(AUser, A, Err) and D.TryLink(AUser, B, Err);
end;

procedure TestModel;
var
  D: TCADDocument;
  H: TCADHistory;
  B, C, Cut, B2, Fuse, Common: TCADId;
  R: TCADRecomputeReport;
  F: TCADFeature;
begin
  D := TCADDocument.Create;
  H := TCADHistory.Create(D);
  try
    B := D.AttachFeature(NewBox(0, 0, 0, 10, 20, 30));
    C := D.AttachFeature(NewCyl(5, 10, -5, 2, 40));          { goes through the box }
    Cut := D.AttachFeature(NewBool(CAD_BOOLEAN_CUT));
    Check(Link2(D, Cut, B, C), 'links');
    R := D.Recompute;
    Check((R.Computed = 3) and (R.Failed = 0), 'box, cylinder, cut computed');
    Check(Near(Vol(D, B), 6000), 'box volume 6000');
    Check(Near(Vol(D, Cut), (6000 - Pi * 4 * 30)), Format('cut volume %.6f', [Vol(D, Cut)]));
    Check(HasMesh(D, Cut) and (R.Display.Shown = 1) and (R.Display.Prepared = 1),
      'display pass: the cut (end of the chain) is meshed');
    Check(not HasMesh(D, B) and not HasMesh(D, C), 'inputs of the cut get no mesh');

    H.Execute(TCADSetParamCommand.Create(C, 'radius', CADFloat(3)));
    R := D.Recompute;
    Check((R.Planned = 2) and (R.Computed = 2), 'radius edit recomputes cylinder + cut only');
    Check(Near(Vol(D, Cut), (6000 - Pi * 9 * 30)), 'new cut volume');

    H.Undo;
    R := D.Recompute;
    Check((R.Computed = 0) and (R.CacheHits = 2), 'undo: no OCCT call, results from the cache');
    Check(HasMesh(D, Cut) and (R.Display.Prepared = 0), 'undo: cached result keeps its mesh (no remesh)');
    Check(Near(Vol(D, Cut), (6000 - Pi * 4 * 30)), 'undo restores the volume');

    B2 := D.AttachFeature(NewBox(5, 0, 0, 10, 20, 30));       { overlaps half of B }
    Fuse := D.AttachFeature(NewBool(CAD_BOOLEAN_FUSE));
    Common := D.AttachFeature(NewBool(CAD_BOOLEAN_COMMON));
    Link2(D, Fuse, B, B2);
    Link2(D, Common, B, B2);
    D.Recompute;
    Check(Near(Vol(D, Fuse), 9000), Format('fuse volume %.6f = 9000', [Vol(D, Fuse)]));
    Check(Near(Vol(D, Common), 3000), Format('common volume %.6f = 3000', [Vol(D, Common)]));
    Check(Near(Vol(D, B), 6000), 'inputs unchanged (non-destructive)');
    Check(HasMesh(D, Fuse) and HasMesh(D, Common) and not HasMesh(D, B2), 'new chain ends meshed, inputs not');

    { Show a feature mid-tree: only the display pass runs, no OCCT model call. }
    Check(D.SetShowMode(B, csmShow) and D.NeedsDisplay, 'show mode marks the display pass');
    R := D.Recompute;
    Check((R.Planned = 0) and (R.Display.Prepared = 1) and HasMesh(D, B),
      'csmShow: the box mid-tree gets its mesh, nothing recomputed');
    F := D.Find(Cut);
    D.SetShowMode(Cut, csmHide);
    Check(not D.IsShown(Cut) and D.IsShown(B), 'IsShown follows the show mode');
    Check(F.DisplayError = '', 'no display error');
  finally
    H.Free;
    D.Free;
  end;
end;

procedure TestErrors;
var
  D: TCADDocument;
  Bad, Good, Cut, OneInput: TCADId;
  Err: string;
begin
  D := TCADDocument.Create;
  try
    Bad := D.AttachFeature(NewBox(0, 0, 0, 0, 10, 10));        { zero size }
    Good := D.AttachFeature(NewBox(0, 0, 0, 10, 10, 10));
    Cut := D.AttachFeature(NewBool(CAD_BOOLEAN_CUT));
    Link2(D, Cut, Good, Bad);
    OneInput := D.AttachFeature(NewBool(CAD_BOOLEAN_CUT));
    D.TryLink(OneInput, Good, Err);
    D.Recompute;
    Check((D.Find(Bad).State = cfsFailed) and (Pos('positive', D.Find(Bad).LastError) > 0),
      'OCCT error text reaches the feature: ' + D.Find(Bad).LastError);
    Check(D.Find(Cut).State = cfsBlocked, 'boolean with a failed input is blocked');
    Check((D.Find(OneInput).State = cfsFailed) and (Pos('exactly 2', D.Find(OneInput).LastError) > 0),
      'boolean with one input fails clearly');
    Check(D.Find(Good).State = cfsClean, 'good input still computed');
  finally
    D.Free;
  end;
end;

{ 8 independent plates, each with 6 holes: 8 chains of 6 booleans.
  ATiming decides which results get a mesh. Returns the recompute time. }
function TimeChains(AThreads: Integer; ATiming: TCADMeshTiming;
  out AAllCorrect: Boolean; out AMeshes: Integer): QWord;
var
  O: TCADPerformanceOptions;
  D: TCADDocument;
  Cuts: array[0..7] of TCADId;
  Mid: TCADId;
  I, J: Integer;
  Cut, Last: TCADId;
  R: TCADRecomputeReport;
  Expected: Double;
begin
  O := DefaultPerformanceOptions;
  O.Threads.RecomputeThreads := AThreads;
  O.Cache.Enabled := False;
  O.Mesh.Timing := ATiming;
  OCCT.ApplyOptions(O);
  D := TCADDocument.CreateWithOptions(O);
  try
    Mid := CADNoId;
    for I := 0 to 7 do
    begin
      Last := D.AttachFeature(NewBox(I * 100, 0, 0, 80, 80, 10));
      for J := 0 to 5 do
      begin
        Cut := D.AttachFeature(NewBool(CAD_BOOLEAN_CUT));
        Link2(D, Cut, Last, D.AttachFeature(NewCyl(I * 100 + 10 + J * 12, 40, -1, 4, 12)));
        Last := Cut;
        if (I = 0) and (J = 2) then
          Mid := Cut;                    { an intermediate result }
      end;
      Cuts[I] := Last;
    end;
    R := D.Recompute;
    Result := R.Milliseconds;
    AMeshes := R.Display.Prepared;
    Expected := 80 * 80 * 10 - 6 * Pi * 16 * 10;
    AAllCorrect := R.Failed = 0;
    for I := 0 to 7 do
      if not Near(Vol(D, Cuts[I]), Expected) or not HasMesh(D, Cuts[I]) then
        AAllCorrect := False;
    { Every-result mode meshes inside Compute, so the middle has a mesh and
      the pass finds the ends ready (0 new). Shown-only: middle has none. }
    if HasMesh(D, Mid) <> (ATiming = cmtEveryResult) then
      AAllCorrect := False;
  finally
    D.Free;
  end;
end;

procedure TestParallel;
var
  EverySerial, EveryAll, ShownSerial, ShownAll: QWord;
  Ok1, Ok2, Ok3, Ok4: Boolean;
  M1, M2, M3, M4: Integer;
begin
  EverySerial := TimeChains(1, cmtEveryResult, Ok1, M1);
  EveryAll := TimeChains(0, cmtEveryResult, Ok2, M2);
  ShownSerial := TimeChains(1, cmtDisplayed, Ok3, M3);
  ShownAll := TimeChains(0, cmtDisplayed, Ok4, M4);
  WriteLn(Format('INFO  8 plates x 6 holes, mesh every result (104 meshes): serial %d ms, all cores %d ms',
    [EverySerial, EveryAll]));
  WriteLn(Format('INFO  8 plates x 6 holes, mesh shown only (%d meshes): serial %d ms, all cores %d ms',
    [M4, ShownSerial, ShownAll]));
  Check(Ok1 and Ok2 and (M1 = 0) and (M2 = 0), 'mesh every result: volumes correct, all meshed in Compute');
  Check(Ok3 and Ok4, 'mesh shown only: every volume correct, ends meshed, middle not');
  Check((M3 = 8) and (M4 = 8), Format('mesh shown only: 8 meshes (got %d, %d)', [M3, M4]));
  OCCT.ApplyOptions(DefaultPerformanceOptions);
end;

var
  L: TOCCTLibrary;
begin
  Checks := 0;
  Failures := 0;
  L := TOCCTLibrary.Create;
  try
    try
      L.Load;
    except
      on E: Exception do
      begin
        WriteLn('BLOCKED  ', E.Message);
        Halt(2);
      end;
    end;
    SetOCCT(L);
    L.ApplyOptions(DefaultPerformanceOptions);
    TestModel;
    TestErrors;
    TestParallel;
  finally
    SetOCCT(nil);                   { after every document (results) is freed }
    L.Free;
  end;
  if Failures = 0 then
    WriteLn(Format('PASS  occt features: %d checks', [Checks]))
  else
    WriteLn(Format('FAIL  occt features: %d of %d checks failed', [Failures, Checks]));
  if Failures <> 0 then
    Halt(1);
end.
