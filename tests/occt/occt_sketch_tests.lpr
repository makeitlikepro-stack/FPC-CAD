program occt_sketch_tests;
{$mode objfpc}{$H+}

{ Native tests: sketch text, Sketch + Extrude features on OCCT.
  Run: bash scripts/test_occt.sh
  1. Text round trip (no OCCT): same text, same indices, solves alike; errors.
  2. Sketch face area (rectangle with a hole), Extrude volume, length edit
     recomputes the Extrude only, symmetric / reversed, sketch edit, slot,
     YZ plane, island (2 faces), Boolean cut on an extrusion, Undo.
  3. Errors: open profile, conflicting constraints (Extrude blocked). }

uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils, Math, CAD.Core.Ids, CAD.Core.Values, CAD.Core.Feature,
  CAD.Core.Document, CAD.Core.Commands, CAD.Core.History,
  CAD.Config.Performance, CAD.OCCT.Bridge, CAD.OCCT.ShapeResult,
  CAD.Features.OCCTBase, CAD.Features.Cylinder, CAD.Features.BooleanOp,
  CAD.Features.Sketch, CAD.Features.Extrude,
  CAD.Sketch.Model, CAD.Sketch.Text, CAD.Sketch.Solver;

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

function Near(A, B: Double): Boolean;
begin
  Result := Abs(A - B) <= 1e-6 * Max(1.0, Abs(B));
end;

function ShapeOf(D: TCADDocument; const AId: TCADId): TOCCTShapeHandle;
var
  F: TCADFeature;
begin
  Result := nil;
  F := D.Find(AId);
  if (F <> nil) and (F.Output is TOCCTShapeResult) then
    Result := TOCCTShapeResult(F.Output).Shape;
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

{ ---------------------------------------------------------------- sketches }

{ 60 x 40 rectangle at the origin, fully constrained, optional circle hole. }
function PlateSketch(AHoleRadius: Double): TCADSketch;
var
  P0, P1, P2, P3, L0, L1: Integer;
begin
  Result := TCADSketch.Create;
  P0 := Result.AddPoint(0, 0);
  P1 := Result.AddPoint(60, 0);
  P2 := Result.AddPoint(60, 40);
  P3 := Result.AddPoint(0, 40);
  L0 := Result.AddLine(P0, P1);
  L1 := Result.AddLine(P1, P2);
  Result.Horizontal(L0);
  Result.Vertical(L1);
  Result.Horizontal(Result.AddLine(P2, P3));
  Result.Vertical(Result.AddLine(P3, P0));
  Result.FixPoint(P0);
  Result.Length(L0, 60);
  Result.Length(L1, 40);
  if AHoleRadius > 0 then
    Result.Radius(Result.AddCircle(Result.AddPoint(30, 20), AHoleRadius), AHoleRadius);
end;

function SlotSketch: TCADSketch;
var
  A1, B1, A2, B2, C1, C2, Bottom, Top, ArcR, ArcL: Integer;
begin
  Result := TCADSketch.Create;
  A1 := Result.AddPoint(0, -10);
  B1 := Result.AddPoint(50, -10);
  A2 := Result.AddPoint(50, 10);
  B2 := Result.AddPoint(0, 10);
  C1 := Result.AddPoint(0, 0);
  C2 := Result.AddPoint(50, 0);
  Bottom := Result.AddLine(A1, B1);
  Top := Result.AddLine(A2, B2);
  ArcR := Result.AddArc(C2, B1, A2);
  ArcL := Result.AddArc(C1, B2, A1);
  Result.FixPoint(C1);
  Result.Horizontal(Bottom);
  Result.HorizontalPoints(C1, C2);
  Result.Radius(ArcL, 10);
  Result.Distance(C1, C2, 50);
  Result.Tangent(Bottom, ArcL);
  Result.Tangent(Bottom, ArcR);
  Result.Tangent(Top, ArcL);
  Result.Tangent(Top, ArcR);
end;

{ Parameter value of a plate sketch (the sketch is freed). }
function PlateValue(AHoleRadius: Double): TCADValue;
var
  S: TCADSketch;
begin
  S := PlateSketch(AHoleRadius);
  try
    Result := CADSketchValue(S);
  finally
    S.Free;
  end;
end;

{ Closed (or open) polyline through x, y pairs. Points are made first and
  kept in variables: FPC may evaluate call arguments right to left, so
  AddLine(AddPoint(..), AddPoint(..)) does not fix the point order. }
procedure AddPolygon(S: TCADSketch; const XY: array of Double; AClosed: Boolean = True);
var
  First, Prev, P, I: Integer;
begin
  First := S.AddPoint(XY[0], XY[1]);
  Prev := First;
  for I := 1 to Length(XY) div 2 - 1 do
  begin
    P := S.AddPoint(XY[2 * I], XY[2 * I + 1]);
    S.AddLine(Prev, P);
    Prev := P;
  end;
  if AClosed then
    S.AddLine(Prev, First);
end;

function NewSketch(S: TCADSketch): TCADFeature;
begin
  Result := TCADSketchFeature.Create;
  Result.Name := 'Sketch';
  Result.SetParamValue('geometry', CADSketchValue(S));
  S.Free;
end;

function NewExtrude(ALength: Double): TCADFeature;
begin
  Result := TCADExtrudeFeature.Create;
  Result.Name := 'Extrude';
  Result.SetParamValue('length', CADFloat(ALength));
end;

function Link(D: TCADDocument; const AUser, AInput: TCADId): Boolean;
var
  Err: string;
begin
  Result := D.TryLink(AUser, AInput, Err);
end;

{ ---------------------------------------------------------------- text }

procedure TestText;
var
  S, S2: TCADSketch;
  T1, T2: string;
  R1, R2: TCADSketchSolveResult;
  Raised: Boolean;
begin
  S := SlotSketch;
  S2 := TCADSketch.Create;
  try
    S.SetPlane([1, 2, 3], [0, 1, 0], [1, 0, 0]);
    S.SetConstruction(S.AddLine(4, 5), True);
    S.RemoveConstraint(S.Length(S.AddLineXY(0, 30, 10, 30), 10));   { inactive one too }
    T1 := CADSketchToText(S);
    CADSketchFromText(T1, S2);
    T2 := CADSketchToText(S2);
    Check(T1 = T2, 'text round trip is exact');
    Check((S2.PointCount = S.PointCount) and (S2.EntityCount = S.EntityCount) and
      (S2.ConstraintCount = S.ConstraintCount), 'same counts and indices after loading');
    Check(S2.Entities[S2.EntityCount - 2].Construction and not S2.Constraints[S2.ConstraintCount - 1].Active,
      'construction flag and inactive constraint kept');
    R1 := CADSolveSketch(S);
    R2 := CADSolveSketch(S2);
    Check((R1.Status = cssSolved) and (R2.Status = cssSolved) and (R1.DOF = R2.DOF) and
      Near(S.PointX(1), S2.PointX(1)), 'both solve alike');
  finally
    S.Free;
    S2.Free;
  end;
  S := TCADSketch.Create;
  try
    Raised := False;
    try
      CADSketchFromText('FPCSKETCH 1'#10'P 1 2 0'#10'L 0 7 0', S);
    except
      on E: ECADSketch do Raised := Pos('line 3', E.Message) > 0;
    end;
    Check(Raised, 'bad reference reports its line number');
  finally
    S.Free;
  end;
end;

{ ---------------------------------------------------------------- model }

procedure TestModel;
var
  D: TCADDocument;
  H: TCADHistory;
  Sk, Ex, Cyl, Cut: TCADId;
  R: TCADRecomputeReport;
  Area, V: Double;
  S: TCADSketch;
begin
  D := TCADDocument.Create;
  H := TCADHistory.Create(D);
  try
    Sk := D.AttachFeature(NewSketch(PlateSketch(5)));
    D.Recompute;
    Area := OCCT.ShapeArea(ShapeOf(D, Sk));
    Check(Near(Area, 2400 - 25 * Pi), Format('sketch face area %.6f = 2400 - 25 pi', [Area]));

    Ex := D.AttachFeature(NewExtrude(10));
    Check(Link(D, Ex, Sk), 'extrude linked to the sketch');
    R := D.Recompute;
    Check((R.Failed = 0) and Near(Vol(D, Ex), 10 * (2400 - 25 * Pi)),
      Format('extrude volume %.4f = 10 x face', [Vol(D, Ex)]));

    H.Execute(TCADSetParamCommand.Create(Ex, 'length', CADFloat(20)));
    R := D.Recompute;
    Check((R.Computed = 1) and Near(Vol(D, Ex), 20 * (2400 - 25 * Pi)),
      'length 20: only the extrude recomputes, volume doubles');
    H.Undo;
    R := D.Recompute;
    Check((R.Computed = 0) and Near(Vol(D, Ex), 10 * (2400 - 25 * Pi)), 'undo from the cache');

    D.SetParam(Ex, 'symmetric', CADBool(True));
    D.Recompute;
    V := Vol(D, Ex);
    D.SetParam(Ex, 'symmetric', CADBool(False));
    D.SetParam(Ex, 'reversed', CADBool(True));
    D.Recompute;
    Check(Near(V, 10 * (2400 - 25 * Pi)) and Near(Vol(D, Ex), V), 'symmetric and reversed keep the volume');
    D.SetParam(Ex, 'reversed', CADBool(False));

    { the sketch changes: hole radius 8 }
    D.SetParam(Sk, 'geometry', PlateValue(8));
    R := D.Recompute;
    Check((R.Computed = 2) and Near(Vol(D, Ex), 10 * (2400 - 64 * Pi)), 'sketch edit: sketch + extrude recompute');

    { a cylinder cut through the extrusion }
    Cyl := D.AttachFeature(TCADCylinderFeature.Create);
    D.SetParam(Cyl, 'x', CADFloat(10));
    D.SetParam(Cyl, 'y', CADFloat(10));
    D.SetParam(Cyl, 'z', CADFloat(-1));
    D.SetParam(Cyl, 'radius', CADFloat(3));
    D.SetParam(Cyl, 'height', CADFloat(12));
    Cut := D.AttachFeature(TCADBooleanFeature.Create);
    Check(Link(D, Cut, Ex) and Link(D, Cut, Cyl), 'cut linked');
    D.Recompute;
    Check(Near(Vol(D, Cut), 10 * (2400 - 64 * Pi) - 10 * 9 * Pi), 'cut through the extrusion');
  finally
    H.Free;
    D.Free;
  end;

  D := TCADDocument.Create;
  try
    S := SlotSketch;
    Sk := D.AttachFeature(NewSketch(S));
    Ex := D.AttachFeature(NewExtrude(5));
    Link(D, Ex, Sk);
    D.Recompute;
    Check(Near(Vol(D, Ex), 5 * (1000 + 100 * Pi)), Format('slot extrude %.4f = 5 (1000 + 100 pi)', [Vol(D, Ex)]));

    { YZ plane, rectangle 20 x 10, extruded 4 along +X }
    S := TCADSketch.Create;
    S.SetPlane([5, 0, 0], [0, 1, 0], [1, 0, 0]);
    AddPolygon(S, [0, 0, 20, 0, 20, 10, 0, 10]);
    Sk := D.AttachFeature(NewSketch(S));
    Ex := D.AttachFeature(NewExtrude(4));
    Link(D, Ex, Sk);
    D.Recompute;
    Check(Near(Vol(D, Ex), 800), 'YZ plane extrude 20 x 10 x 4');

    { island: square 100 with a 60 hole and a 20 island -> 2 faces }
    S := TCADSketch.Create;
    AddPolygon(S, [0, 0, 100, 0, 100, 100, 0, 100]);
    AddPolygon(S, [20, 20, 20, 80, 80, 80, 80, 20]);
    AddPolygon(S, [40, 40, 60, 40, 60, 60, 40, 60]);
    Sk := D.AttachFeature(NewSketch(S));
    Ex := D.AttachFeature(NewExtrude(2));
    Link(D, Ex, Sk);
    D.Recompute;
    Check(Near(Vol(D, Ex), 2 * (10000 - 3600 + 400)), Format('island extrude %.4f = 2 x 6800', [Vol(D, Ex)]));
  finally
    D.Free;
  end;
end;

procedure TestErrors;
var
  D: TCADDocument;
  Sk, Ex: TCADId;
  S: TCADSketch;
  F: TCADFeature;
begin
  D := TCADDocument.Create;
  try
    S := TCADSketch.Create;
    AddPolygon(S, [0, 0, 10, 0, 10, 10], False);
    Sk := D.AttachFeature(NewSketch(S));
    Ex := D.AttachFeature(NewExtrude(5));
    Link(D, Ex, Sk);
    D.Recompute;
    F := D.Find(Sk);
    Check((F.State = cfsFailed) and (Pos('open profile', F.LastError) > 0), 'open profile fails: ' + F.LastError);
    Check(D.Find(Ex).State = cfsBlocked, 'extrude of a failed sketch is blocked');

    S := PlateSketch(0);
    S.Length(S.AddLine(2, 3), 50);              { top side 50 against width 60 }
    D.SetParam(Sk, 'geometry', CADSketchValue(S));
    S.Free;
    D.Recompute;
    F := D.Find(Sk);
    Check((F.State = cfsFailed) and (Pos('conflicting', F.LastError) > 0), 'conflict fails: ' + F.LastError);
  finally
    D.Free;
  end;
end;

var
  L: TOCCTLibrary;
begin
  Checks := 0;
  Failures := 0;
  TestText;
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
  finally
    SetOCCT(nil);
    L.Free;
  end;
  if Failures = 0 then
    WriteLn(Format('PASS  occt sketch: %d checks', [Checks]))
  else
    WriteLn(Format('FAIL  occt sketch: %d of %d checks failed', [Failures, Checks]));
  if Failures <> 0 then
    Halt(1);
end.
