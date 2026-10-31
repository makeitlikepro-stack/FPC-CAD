program sketch_tests;
{$mode objfpc}{$H+}

{ Tests of the sketch model and solver (no OCCT, no GL).
  Run: bash scripts/test_sketch.sh
  1. Rectangle: solve, DOF steps, redundant and conflicting dimensions.
  2. Slot: 2 lines + 2 arcs, tangent, radius, centre distance.
  3. Every constraint kind on a small case with a known answer.
  4. Minimum-norm move: dragging a corner moves only what it must.
  5. Plane mapping, errors, speed (INFO). }

uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils, Math, CAD.Sketch.Model, CAD.Sketch.Constraints, CAD.Sketch.Solver;

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

function Near(A, B: Double; ATol: Double = 1e-6): Boolean;
begin
  Result := Abs(A - B) <= ATol;
end;

function Has(const A: array of Integer; AValue: Integer): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(A) do
    if A[I] = AValue then
      Exit(True);
  Result := False;
end;

function Solved(S: TCADSketch; const AName: string): TCADSketchSolveResult;
begin
  Result := CADSolveSketch(S);
  Check(Result.Status = cssSolved, Format('%s: solved (%s, max residual %.3g, %d iterations)',
    [AName, CADSolveStatusText(Result.Status), Result.MaxResidual, Result.Iterations]));
end;

{ ------------------------------------------------------------ rectangle }

procedure TestRectangle;
var
  S: TCADSketch;
  P0, P1, P2, P3, L0, L1, L2, L3, DimTop: Integer;
  R: TCADSketchSolveResult;
begin
  S := TCADSketch.Create;
  try
    P0 := S.AddPoint(0, 0);
    P1 := S.AddPoint(55, 3);
    P2 := S.AddPoint(58, 37);
    P3 := S.AddPoint(-2, 44);
    L0 := S.AddLine(P0, P1);
    L1 := S.AddLine(P1, P2);
    L2 := S.AddLine(P2, P3);
    L3 := S.AddLine(P3, P0);
    S.FixPoint(P0);
    S.Horizontal(L0);
    S.Horizontal(L2);
    S.Vertical(L1);
    S.Vertical(L3);
    R := Solved(S, 'rectangle without sizes');
    Check(R.DOF = 2, Format('rectangle without sizes: DOF 2, got %d', [R.DOF]));
    S.Length(L0, 60);
    R := Solved(S, 'rectangle + width');
    Check(R.DOF = 1, Format('rectangle + width: DOF 1, got %d', [R.DOF]));
    S.Length(L1, 40);
    R := Solved(S, 'rectangle');
    Check(R.DOF = 0, Format('rectangle: DOF 0, got %d', [R.DOF]));
    Check(Near(S.PointX(P2), 60) and Near(S.PointY(P2), 40) and Near(S.PointX(P3), 0) and
      Near(S.PointY(P3), 40) and Near(S.PointX(P0), 0), 'rectangle: corners at 60 x 40');
    Check((System.Length(R.Redundant) = 0) and (System.Length(R.Conflicting) = 0), 'rectangle: nothing redundant');

    DimTop := S.Length(L2, 60);
    R := Solved(S, 'rectangle + same top length');
    Check(Has(R.Redundant, DimTop), 'rectangle: second width is redundant');

    S.SetConstraintValue(DimTop, 50);
    R := CADSolveSketch(S);
    Check(R.Status = cssConflicting, 'rectangle: width 60 and 50 conflict (' + CADSolveStatusText(R.Status) + ')');
    Check(Has(R.Conflicting, DimTop) and Has(R.Redundant, DimTop), 'rectangle: the 50 mm dimension is reported');

    S.RemoveConstraint(DimTop);
    R := Solved(S, 'rectangle after removing the conflict');
    Check(Near(S.PointX(P2), 60) and Near(S.PointY(P2), 40), 'rectangle: back to 60 x 40');
  finally
    S.Free;
  end;
end;

{ ------------------------------------------------------------ slot }

procedure TestSlot;
var
  S: TCADSketch;
  A1, B1, A2, B2, C1, C2, Bottom, Top, ArcR, ArcL: Integer;
  R: TCADSketchSolveResult;
begin
  S := TCADSketch.Create;
  try
    { bottom line A1 -> B1, right arc B1 -> A2 (CCW), top line A2 -> B2,
      left arc B2 -> A1; start values deliberately off }
    A1 := S.AddPoint(0, -10);
    B1 := S.AddPoint(50, -9);
    A2 := S.AddPoint(52, 11);
    B2 := S.AddPoint(1, 10);
    C1 := S.AddPoint(0, 0);
    C2 := S.AddPoint(49, 1);
    Bottom := S.AddLine(A1, B1);
    Top := S.AddLine(A2, B2);
    ArcR := S.AddArc(C2, B1, A2);
    ArcL := S.AddArc(C1, B2, A1);
    S.FixPoint(C1);
    S.Horizontal(Bottom);
    S.HorizontalPoints(C1, C2);
    S.Radius(ArcL, 10);
    S.Distance(C1, C2, 50);
    S.Tangent(Bottom, ArcL);
    S.Tangent(Bottom, ArcR);
    S.Tangent(Top, ArcL);
    S.Tangent(Top, ArcR);
    R := Solved(S, 'slot');
    Check(R.DOF = 0, Format('slot: DOF 0, got %d', [R.DOF]));
    Check(Near(S.PointX(C2), 50) and Near(S.PointY(C2), 0), 'slot: centres 50 apart');
    Check(Near(S.EntityRadius(ArcR), 10) and Near(S.PointY(A1), -10) and Near(S.PointY(B2), 10),
      'slot: both radii 10, lines at y = -10 and +10');
    Check(Near(S.PointX(A1), 0) and Near(S.PointX(B1), 50), 'slot: tangent points above the centres');
  finally
    S.Free;
  end;
end;

{ ------------------------------------------------------------ each kind }

procedure TestKinds;
var
  S: TCADSketch;
  O, P, Q, L, L2, Ax, Cir, Cir2, Arc, C, E: Integer;
  R: TCADSketchSolveResult;
begin
  { circle tangent to two lines (corner fillet) }
  S := TCADSketch.Create;
  try
    O := S.AddPoint(0, 0);
    S.FixPoint(O);
    L := S.AddLine(O, S.AddPoint(30, 0));
    L2 := S.AddLine(O, S.AddPoint(0, 30));
    S.Horizontal(L);
    S.Vertical(L2);
    C := S.AddPoint(6, 4);
    Cir := S.AddCircle(C, 3);
    S.Radius(Cir, 5);
    S.Tangent(L, Cir);
    S.Tangent(L2, Cir);
    Solved(S, 'circle tangent to two lines');
    Check(Near(S.PointX(C), 5) and Near(S.PointY(C), 5), 'circle tangent to x and y axes at (5, 5)');
  finally
    S.Free;
  end;

  { angle, length, distance X/Y, point on line, point-line distance }
  S := TCADSketch.Create;
  try
    O := S.AddPoint(0, 0);
    S.FixPoint(O);
    Ax := S.AddLine(O, S.AddPoint(20, 0));
    S.Horizontal(Ax);
    S.Length(Ax, 20);
    P := S.AddPoint(7, 6);
    L := S.AddLine(O, P);
    S.Angle(Ax, L, DegToRad(30));
    S.Length(L, 10);
    Q := S.AddPoint(3, 3);
    S.PointOnLine(Q, L);
    S.DistanceX(O, Q, 4);
    E := S.AddPoint(11, 2);
    S.PointLineDistance(E, Ax, 3);
    S.DistanceX(O, E, 12);
    Solved(S, 'angle and distances');
    Check(Near(S.PointX(P), 10 * Cos(Pi / 6)) and Near(S.PointY(P), 5), 'angle 30 deg, length 10');
    Check(Near(S.PointX(Q), 4) and Near(S.PointY(Q), 4 * Tan(Pi / 6)), 'point on line at x = 4');
    Check(Near(S.PointY(E), 3) and Near(S.PointX(E), 12), 'point 3 mm from the axis line');
  finally
    S.Free;
  end;

  { parallel, perpendicular, equal length, collinear, distance Y, vertical points }
  S := TCADSketch.Create;
  try
    O := S.AddPoint(0, 0);
    S.FixPoint(O);
    Ax := S.AddLine(O, S.AddPoint(10, 1));
    S.Horizontal(Ax);
    S.Length(Ax, 10);
    L := S.AddLineXY(1, 5, 9, 7);
    S.Parallel(Ax, L);
    S.EqualLength(Ax, L);
    S.VerticalPoints(O, S.Entities[L].P1);
    S.DistanceY(O, S.Entities[L].P1, 5);
    L2 := S.AddLineXY(12, 1, 13, 6);
    S.Perpendicular(Ax, L2);
    S.Length(L2, 4);
    S.Coincident(S.Entities[L2].P1, S.Entities[Ax].P2);
    Q := S.AddLine(S.AddPoint(14, 4), S.AddPoint(18, 6));
    S.Collinear(L, Q);
    S.Length(Q, 3);
    S.DistanceX(O, S.Entities[Q].P1, 15);
    Solved(S, 'parallel, perpendicular, equal, collinear');
    Check(Near(S.PointX(S.Entities[L].P2), 10) and Near(S.PointY(S.Entities[L].P2), 5),
      'parallel + equal length line at y = 5');
    Check(Near(S.PointX(S.Entities[L2].P2), 10) and Near(Abs(S.PointY(S.Entities[L2].P2)), 4),
      'perpendicular line from the end of the axis');
    Check(Near(S.PointY(S.Entities[Q].P1), 5) and Near(S.PointY(S.Entities[Q].P2), 5) and
      Near(S.PointX(S.Entities[Q].P2), 18), 'collinear line on y = 5');
  finally
    S.Free;
  end;

  { circles: concentric, diameter, equal radius, point on circle, tangent circles }
  S := TCADSketch.Create;
  try
    O := S.AddPoint(0, 0);
    S.FixPoint(O);
    Cir := S.AddCircle(O, 8);
    S.Diameter(Cir, 20);
    C := S.AddPoint(1, 1);
    Cir2 := S.AddCircle(C, 4);
    S.Concentric(Cir, Cir2);
    S.Radius(Cir2, 4);
    P := S.AddPoint(9, 2);
    S.PointOnCircle(P, Cir);
    S.HorizontalPoints(O, P);
    Q := S.AddPoint(20, 1);
    E := S.AddCircle(Q, 2);
    S.EqualRadius(Cir2, E);
    S.TangentCircles(Cir, E);
    S.HorizontalPoints(O, Q);
    Solved(S, 'circles');
    Check(Near(S.EntityRadius(Cir), 10) and Near(S.PointX(C), 0) and Near(S.PointY(C), 0),
      'diameter 20, concentric centre');
    Check(Near(S.PointX(P), 10) and Near(S.PointY(P), 0), 'point on the circle at (10, 0)');
    Check(Near(S.EntityRadius(E), 4) and Near(S.PointX(Q), 14), 'equal radius 4, outside tangent at x = 14');
  finally
    S.Free;
  end;

  { midpoint, symmetric, arc radius from its points }
  S := TCADSketch.Create;
  try
    O := S.AddPoint(0, 0);
    S.FixPoint(O);
    Ax := S.AddLine(O, S.AddPoint(0, 10));
    S.Vertical(Ax);
    S.Length(Ax, 10);
    P := S.AddPoint(4, 3);
    Q := S.AddPoint(-5, 2);
    S.Symmetric(P, Q, Ax);
    S.DistanceX(O, P, 6);
    S.DistanceY(O, P, 2);
    L := S.AddLine(P, Q);
    E := S.AddPoint(1, 1);
    S.Midpoint(E, L);
    C := S.AddPoint(0, 20);
    S.FixPoint(C);
    Arc := S.AddArc(C, S.AddPoint(5, 20), S.AddPoint(0, 26));
    S.Radius(Arc, 6);
    S.HorizontalPoints(C, S.Entities[Arc].P1);
    S.VerticalPoints(C, S.Entities[Arc].P2);
    Solved(S, 'midpoint, symmetric, arc');
    Check(Near(S.PointX(Q), -6) and Near(S.PointY(Q), 2), 'symmetric about x = 0');
    Check(Near(S.PointX(E), 0) and Near(S.PointY(E), 2), 'midpoint of the symmetric pair');
    Check(Near(S.PointX(S.Entities[Arc].P1), 6) and Near(S.PointY(S.Entities[Arc].P1), 20),
      'arc start at (6, 20)');
    Check(Near(S.PointY(S.Entities[Arc].P2), 26) and Near(S.EntityRadius(Arc), 6), 'arc end on the same radius');
  finally
    S.Free;
  end;
end;

{ ------------------------------------------------------------ minimum norm }

procedure TestDrag;
var
  S: TCADSketch;
  P0, P1, P2, P3: Integer;
  R: TCADSketchSolveResult;
begin
  S := TCADSketch.Create;
  try
    P0 := S.AddPoint(0, 0);
    P1 := S.AddPoint(60, 0);
    P2 := S.AddPoint(60, 40);
    P3 := S.AddPoint(0, 40);
    S.Horizontal(S.AddLine(P0, P1));
    S.Vertical(S.AddLine(P1, P2));
    S.Horizontal(S.AddLine(P2, P3));
    S.Vertical(S.AddLine(P3, P0));
    { drag: move P2 to (70, 50) and hold it there for this solve }
    S.MovePoint(P2, 70, 50);
    S.FixPoint(P2);
    R := Solved(S, 'drag a corner');
    S.FixPoint(P2, False);
    Check(Near(S.PointX(P0), 0) and Near(S.PointY(P0), 0), 'drag: the opposite corner stays');
    Check(Near(S.PointX(P1), 70) and Near(S.PointY(P1), 0) and Near(S.PointX(P3), 0) and
      Near(S.PointY(P3), 50), 'drag: the neighbours follow along one axis only');
    { free: P0, P1, P3 (6 numbers), 4 independent equations }
    Check(R.DOF = 2, Format('drag: 2 DOF left with one corner held, got %d', [R.DOF]));

    { a free point with no constraint never moves }
    P0 := S.AddPoint(123, 45);
    Solved(S, 'free point');
    Check(Near(S.PointX(P0), 123) and Near(S.PointY(P0), 45), 'free point stays');
  finally
    S.Free;
  end;
end;

{ ------------------------------------------------------------ misc }

procedure TestPlaneAndErrors;
var
  S: TCADSketch;
  X, Y, Z: Double;
  Raised: Boolean;
begin
  S := TCADSketch.Create;
  try
    S.SetPlane([0, 0, 10], [1, 0, 0], [0, 0, 1]);
    S.ToModel(1, 2, X, Y, Z);
    Check(Near(X, 1) and Near(Y, 2) and Near(Z, 10), 'plane XY at z = 10');
    S.SetPlane([0, 0, 0], [0, 1, 0], [1, 0, 0]);
    S.ToModel(1, 2, X, Y, Z);
    Check(Near(X, 0) and Near(Y, 1) and Near(Z, 2), 'plane YZ: x -> Y, y -> Z');
    S.SetPlane([0, 0, 0], [1, 0, 1], [0, 0, 2]);
    Check(Near(S.Plane.XDir[0], 1) and Near(S.Plane.XDir[2], 0) and Near(S.Plane.Normal[2], 1),
      'plane: X made perpendicular to the normal, both unit');
    Raised := False;
    try
      S.AddLine(0, 1);
    except
      on ECADSketch do Raised := True;
    end;
    Check(Raised, 'line on missing points raises');
    Raised := False;
    S.AddPoint(0, 0);
    try
      S.Radius(0, 3);
    except
      on ECADSketch do Raised := True;
    end;
    Check(Raised, 'radius on a missing entity raises');
  finally
    S.Free;
  end;
end;

procedure TestSpeed;
const
  N = 50;
var
  S: TCADSketch;
  I, P0, P1, P2, P3, L0, L1: Integer;
  R: TCADSketchSolveResult;
begin
  S := TCADSketch.Create;
  try
    for I := 0 to N - 1 do
    begin
      P0 := S.AddPoint(I * 100, 0);
      P1 := S.AddPoint(I * 100 + 55, 3);
      P2 := S.AddPoint(I * 100 + 58, 37);
      P3 := S.AddPoint(I * 100 - 2, 44);
      L0 := S.AddLine(P0, P1);
      L1 := S.AddLine(P1, P2);
      S.Horizontal(L0);
      S.Horizontal(S.AddLine(P2, P3));
      S.Vertical(L1);
      S.Vertical(S.AddLine(P3, P0));
      S.FixPoint(P0);
      S.Length(L0, 60);
      S.Length(L1, 40);
    end;
    R := Solved(S, Format('%d rectangles', [N]));
    Check(R.DOF = 0, Format('%d rectangles: DOF 0, got %d', [N, R.DOF]));
    WriteLn(Format('INFO  %d rectangles: %d free numbers, %d rows, %d iterations, %d ms (with diagnostics)',
      [N, R.FreeParams, R.Rows, R.Iterations, R.Milliseconds]));
  finally
    S.Free;
  end;
end;

begin
  Checks := 0;
  Failures := 0;
  TestRectangle;
  TestSlot;
  TestKinds;
  TestDrag;
  TestPlaneAndErrors;
  TestSpeed;
  if Failures = 0 then
    WriteLn(Format('PASS  sketch: %d checks', [Checks]))
  else
    WriteLn(Format('FAIL  sketch: %d of %d checks failed', [Failures, Checks]));
  if Failures <> 0 then
    Halt(1);
end.
