program sketch_tests;
{$mode objfpc}{$H+}

{ Tests of the sketch model and solver (no OCCT, no GL).
  Run: bash scripts/test_sketch.sh
  1. Rectangle: solve, DOF steps, redundant and conflicting dimensions.
  2. Slot: 2 lines + 2 arcs, tangent, radius, centre distance.
  3. Every constraint kind on a small case with a known answer.
  4. Minimum-norm move: dragging a corner moves only what it must.
  5. Plane mapping, errors, speed (INFO).
  6. Profiles: loops, faces, holes, islands, orientation, areas, errors.
  7. Editor tools: snaps, automatic constraints, previews, cancel, drag.
  8. Constraint commands: picking, selection, each button, redundant and
     conflicting constraints taken back, dimensions edited, labels. }

uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils, Math, CAD.Sketch.Model, CAD.Sketch.Constraints, CAD.Sketch.Solver,
  CAD.Sketch.Profile, CAD.Sketch.Editor, CAD.Sketch.Commands;

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
    { A tangent point is ill-conditioned along the line: |A1 - C1| = r with
      A1.y = -r gives x = sqrt(2 r dy), so a 1e-10 residual moves x by ~5e-5. }
    Check(Near(S.PointX(A1), 0, 1e-3) and Near(S.PointX(B1), 50, 1e-3),
      Format('slot: tangent points above the centres (x %.2e, %.6f)', [S.PointX(A1), S.PointX(B1)]));
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
    P := S.AddPoint(14, 4);                  { points first: argument order }
    Q := S.AddLine(P, S.AddPoint(18, 6));
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

{ ------------------------------------------------------------ profiles }

{ Rectangle of four lines through new points; AClockwise walks it the other way. }
procedure AddRect(S: TCADSketch; X0, Y0, W, H: Double; AClockwise: Boolean = False);
var
  P0, P1, P2, P3: Integer;
begin
  P0 := S.AddPoint(X0, Y0);
  if AClockwise then
  begin
    P1 := S.AddPoint(X0, Y0 + H);
    P2 := S.AddPoint(X0 + W, Y0 + H);
    P3 := S.AddPoint(X0 + W, Y0);
  end
  else
  begin
    P1 := S.AddPoint(X0 + W, Y0);
    P2 := S.AddPoint(X0 + W, Y0 + H);
    P3 := S.AddPoint(X0, Y0 + H);
  end;
  S.AddLine(P0, P1);
  S.AddLine(P1, P2);
  S.AddLine(P2, P3);
  S.AddLine(P3, P0);
end;

function Profile(S: TCADSketch; out P: TCADSketchProfile; const AName: string): Boolean;
begin
  Result := CADBuildProfile(S, P);
  Check(Result, AName + ': profile builds (' + P.Error + ')');
end;

procedure TestProfiles;
var
  S: TCADSketch;
  P: TCADSketchProfile;
  A1, B1, A2, B2, C1, C2, Q0, Q1, I, Arcs: Integer;
  Ok: Boolean;
begin
  { clockwise rectangle -> one face, outer loop turned counter-clockwise }
  S := TCADSketch.Create;
  try
    AddRect(S, 0, 0, 60, 40, True);
    if Profile(S, P, 'rectangle') then
    begin
      Check((Length(P.Loops) = 1) and (Length(P.Faces) = 1) and (Length(P.Loops[0].Edges) = 4),
        'rectangle: 1 loop, 1 face, 4 edges');
      Check(Near(P.Loops[0].Area, 2400) and Near(P.Faces[0].Area, 2400), 'rectangle: area 2400, counter-clockwise');
      Ok := True;
      for I := 0 to 3 do
        Ok := Ok and Near(P.Loops[0].Edges[I].X2, P.Loops[0].Edges[(I + 1) mod 4].X1) and
          Near(P.Loops[0].Edges[I].Y2, P.Loops[0].Edges[(I + 1) mod 4].Y1);
      Check(Ok, 'rectangle: edges run end to start');
    end;
    { construction diagonal is ignored }
    S.SetConstruction(S.AddLine(0, 2), True);
    Check(Profile(S, P, 'rectangle + construction') and (Length(P.Faces) = 1), 'construction line ignored');
    { a circle hole }
    S.AddCircle(S.AddPoint(30, 20), 5);
    if Profile(S, P, 'rectangle with hole') then
    begin
      Check((Length(P.Faces) = 1) and (Length(P.Faces[0].Holes) = 1), 'hole: 1 face with 1 hole');
      Check(Near(P.Faces[0].Area, 2400 - 25 * Pi) and (P.Loops[P.Faces[0].Holes[0]].Area < 0),
        'hole: face area 2400 - 25 pi, hole clockwise');
    end;
    { an open profile }
    S.AddLine(S.AddPoint(100, 0), S.AddPoint(120, 0));
    Check(not CADBuildProfile(S, P) and (Pos('open', P.Error) > 0) and (P.ErrorPoint >= 0),
      'open line is an error with its point: ' + P.Error);
  finally
    S.Free;
  end;

  { slot: lines + arcs }
  S := TCADSketch.Create;
  try
    A1 := S.AddPoint(0, -10);
    B1 := S.AddPoint(50, -10);
    A2 := S.AddPoint(50, 10);
    B2 := S.AddPoint(0, 10);
    C1 := S.AddPoint(0, 0);
    C2 := S.AddPoint(50, 0);
    S.AddLine(A1, B1);
    S.AddArc(C2, B1, A2);
    S.AddLine(A2, B2);
    S.AddArc(C1, B2, A1);
    if Profile(S, P, 'slot') then
    begin
      Arcs := 0;
      for I := 0 to High(P.Loops[0].Edges) do
        if P.Loops[0].Edges[I].Kind = pekArc then
          Inc(Arcs);
      Check((Length(P.Faces) = 1) and (Arcs = 2), 'slot: one face, 2 arcs');
      Check(Near(P.Faces[0].Area, 1000 + 100 * Pi, 1e-9), Format('slot: area 1000 + 100 pi, got %.6f', [P.Faces[0].Area]));
    end;
  finally
    S.Free;
  end;

  { D shape: a line and an arc between the same two points }
  S := TCADSketch.Create;
  try
    Q0 := S.AddPoint(10, 0);
    Q1 := S.AddPoint(-10, 0);
    S.AddArc(S.AddPoint(0, 0), Q0, Q1);
    S.AddLine(Q1, Q0);
    Check(Profile(S, P, 'D shape') and Near(P.Faces[0].Area, 50 * Pi, 1e-9), 'D shape: half circle area');
  finally
    S.Free;
  end;

  { nesting: square, square hole, island; plus a separate square }
  S := TCADSketch.Create;
  try
    AddRect(S, 0, 0, 100, 100);
    AddRect(S, 20, 20, 60, 60, True);
    AddRect(S, 40, 40, 20, 20);
    AddRect(S, 200, 0, 10, 10);
    if Profile(S, P, 'nested') then
    begin
      Check(Length(P.Faces) = 3, Format('nested: 3 faces (outer, island, separate), got %d', [Length(P.Faces)]));
      Ok := False;
      for I := 0 to High(P.Faces) do
        if Near(P.Faces[I].Area, 10000 - 3600) and (Length(P.Faces[I].Holes) = 1) then
          Ok := True;
      Check(Ok, 'nested: outer face 10000 - 3600 with one hole');
      Ok := False;
      for I := 0 to High(P.Faces) do
        if Near(P.Faces[I].Area, 400) and (P.Loops[P.Faces[I].Outer].Depth = 2) then
          Ok := True;
      Check(Ok, 'nested: island 400 at depth 2');
    end;
  finally
    S.Free;
  end;

  { ends joined by Coincident and by position }
  S := TCADSketch.Create;
  try
    A1 := S.AddLineXY(0, 0, 10, 0);
    B1 := S.AddLineXY(10, 0.5, 10, 10);
    C1 := S.AddLineXY(10, 10, 0, 10);       { joined to B1 by position }
    C2 := S.AddLineXY(0, 10, 0, 0);
    S.Coincident(S.Entities[A1].P2, S.Entities[B1].P1);
    S.FixPoint(S.Entities[A1].P2);            { the solve moves B1's start onto it }
    CADSolveSketch(S);
    Check(Profile(S, P, 'joined ends') and Near(P.Faces[0].Area, 100, 1e-6), 'joined ends: one 10 x 10 face');
  finally
    S.Free;
  end;

  { errors }
  S := TCADSketch.Create;
  try
    Check(not CADBuildProfile(S, P) and (P.Error <> ''), 'empty sketch is an error');
    AddRect(S, 0, 0, 10, 10);
    S.AddLine(0, S.AddPoint(-5, -5));
    Check(not CADBuildProfile(S, P) and (Pos('branch', P.Error) > 0), 'branch is an error: ' + P.Error);
  finally
    S.Free;
  end;
  S := TCADSketch.Create;
  try
    AddRect(S, 0, 0, 10, 10);
    AddRect(S, 5, 5, 10, 10);
    Check(not CADBuildProfile(S, P) and (Pos('cross', P.Error) > 0), 'crossing loops are an error: ' + P.Error);
  finally
    S.Free;
  end;
end;

{ ------------------------------------------------------------ editor }

function CountKind(S: TCADSketch; AKind: TCADSketchConstraintKind): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to S.ConstraintCount - 1 do
    if S.Constraints[I].Active and (S.Constraints[I].Kind = AKind) then
      Inc(Result);
end;

procedure TestEditor;
var
  S: TCADSketch;
  Ed: TCADSketchEditor;
  P: TCADSketchProfile;
  Ents, I, Mid: Integer;
  Pv: TCADSketchPreview;
begin
  S := TCADSketch.Create;
  Ed := TCADSketchEditor.Create(S);
  try
    Ed.SnapTolerance := 0.5;
    Check(Ed.Prompt <> '', 'editor: prompt');

    { closed line chain: origin, horizontal, vertical, horizontal, back to the start }
    Ed.SetTool(sktLine);
    Ed.Move(0.2, 0.1);
    Check(Ed.Snap.Kind = snkOrigin, 'line: snaps to the origin');
    Check(Ed.Click(0.2, 0.1), 'line: first click makes the origin point');
    Check((S.PointCount = 1) and S.Fixed[S.Points[0].XParam] and Ed.Busy, 'line: origin is a fixed point, chain open');
    Ed.Move(20, 0.3);
    Check((Ed.Snap.Kind = snkHorizontal) and (Ed.Snap.Y = 0), 'line: horizontal snap');
    Check((Ed.PreviewCount = 1) and (Ed.Previews[0].Kind = cpkLine) and (Ed.Previews[0].X2 = 20),
      'line: rubber band preview');
    Ed.Click(20, 0.3);
    Ed.Click(20.2, 15);
    Ed.Click(0.3, 15.2);
    Check(Ed.Click(0.1, 0.2), 'line: closing click');
    Check(not Ed.Busy and (S.EntityCount = 4) and (S.PointCount = 4), 'line: chain closed on its first point');
    Check((CountKind(S, sckHorizontal) = 2) and (CountKind(S, sckVertical) = 1), 'line: automatic H, V, H');
    Check(Near(S.PointY(1), 0) and Near(S.PointX(2), 20) and Near(S.PointY(3), 15), 'line: snapped coordinates');
    Check(CADBuildProfile(S, P) and Near(P.Faces[0].Area, 15 * (20 + 19.7) / 2),
      'line: closed chain is a face (' + P.Error + ')');
    Check((Ed.LastSolve.Status = cssSolved) and (Ed.LastSolve.DOF = 3), Format('line: solved, DOF 3, got %d', [Ed.LastSolve.DOF]));

    { midpoint snap and a vertical line, ended with Cancel }
    Ed.Move(10, 0.1);
    Check(Ed.Snap.Kind = snkMidpoint, 'midpoint: snap on the bottom line');
    Ed.Click(10, 0.1);
    Ed.Click(10.2, 8);
    Ed.Cancel;
    Check(not Ed.Busy and (CountKind(S, sckMidpoint) = 1) and (CountKind(S, sckVertical) = 2),
      'midpoint: Midpoint + vertical line, chain ended by Cancel');
    Mid := S.PointCount - 2;
    Check(Near(S.PointX(Mid), 10) and Near(S.PointY(Mid), 0), 'midpoint: the point sits at (10, 0)');

    { zero-length line is ignored }
    Ents := S.EntityCount;
    Ed.Click(40, 40);
    Ed.Click(40, 40);
    Check(S.EntityCount = Ents, 'line: zero-length click ignored');
    Ed.Cancel;

    { rectangle }
    Ed.SetTool(sktRectangle);
    Ents := S.EntityCount;
    Ed.Click(30, 30);
    Ed.Move(50, 40);
    Check(Ed.PreviewCount = 4, 'rectangle: 4 preview lines');
    Check(Ed.Click(50, 40) and (S.EntityCount = Ents + 4), 'rectangle: 4 lines');
    Check((CountKind(S, sckHorizontal) = 4) and (CountKind(S, sckVertical) = 4), 'rectangle: H, V, H, V');

    { cancel half way }
    Ents := S.EntityCount;
    Ed.Click(60, 60);
    Check(Ed.Busy, 'rectangle: one corner pending');
    Ed.Cancel;
    Ed.Click(70, 70);
    Check((S.EntityCount = Ents) and Ed.Busy, 'cancel: the next click starts again');
    Ed.Cancel;

    { circle }
    Ed.SetTool(sktCircle);
    Ed.Click(70, 5);
    Ed.Move(75, 5);
    Pv := Ed.Previews[0];
    Check((Ed.PreviewCount = 1) and (Pv.Kind = cpkCircle) and Near(Pv.R, 5), 'circle: preview radius 5');
    Check(Ed.Click(75, 5), 'circle: made');
    Check(Near(S.EntityRadius(S.EntityCount - 1), 5), 'circle: radius 5');

    { arc: centre, start, end projected onto the radius }
    Ed.SetTool(sktArc);
    Ed.Click(100, 0);
    Ed.Click(110, 0);
    Ed.Move(100, 20);
    Check((Ed.PreviewCount = 1) and (Ed.Previews[0].Kind = cpkArc) and Near(Ed.Previews[0].Y2, 10),
      'arc: preview end on the radius');
    Check(Ed.Click(100, 20), 'arc: made');
    I := S.EntityCount - 1;
    Check((S.Entities[I].Kind = sekArc) and Near(S.EntityRadius(I), 10) and
      Near(S.PointY(S.Entities[I].P2), 10), 'arc: radius 10, end at (100, 10)');

    { 3-point arc: ends first, then a point on the arc }
    Ed.SetTool(sktArc3);
    Ed.Click(200, 0);
    Ed.Click(220, 0);
    Ed.Move(210, 10);
    Check((Ed.PreviewCount = 1) and (Ed.Previews[0].Kind = cpkArc) and Near(Ed.Previews[0].R, 10) and
      Near(Ed.Previews[0].X1, 220), 'arc3: preview radius 10, runs from (220, 0) over the top');
    Check(Ed.Click(210, 10), 'arc3: made');
    I := S.EntityCount - 1;
    Check((S.Entities[I].Kind = sekArc) and Near(S.EntityRadius(I), 10) and
      Near(S.PointX(S.Entities[I].Center), 210) and Near(S.PointY(S.Entities[I].Center), 0),
      'arc3: centre (210, 0), radius 10');
    Check(Near(S.PointX(S.Entities[I].P1), 220) and Near(S.PointX(S.Entities[I].P2), 200),
      'arc3: through a point above -> counter-clockwise from the end click');
    Ed.Click(300, 0);
    Ed.Click(310, 0);
    Check(Ed.Click(305, -1), 'arc3: shallow arc below');
    I := S.EntityCount - 1;
    Check(Near(S.PointX(S.Entities[I].P1), 300) and Near(S.EntityRadius(I), 13),
      'arc3: through (305, -1): radius 13, counter-clockwise from the start click');
    Ents := S.EntityCount;
    Ed.Click(400, 0);
    Ed.Click(410, 0);
    Check(not Ed.Click(420, 0) and (S.EntityCount = Ents), 'arc3: three points on a line make no arc');

    { point tool }
    Ed.SetTool(sktPoint);
    Ents := S.PointCount;
    Check(not Ed.Click(110, 0.1) and (S.PointCount = Ents), 'point: none on an existing point');
    Check(Ed.Click(200, 200) and (S.PointCount = Ents + 1), 'point: new point');
  finally
    Ed.Free;
    S.Free;
  end;
end;

procedure TestEditorDrag;
var
  S: TCADSketch;
  Ed: TCADSketchEditor;
  P2, P3: Integer;
begin
  S := TCADSketch.Create;
  Ed := TCADSketchEditor.Create(S);
  try
    Ed.SnapTolerance := 0.5;
    Ed.SetTool(sktRectangle);
    Ed.Click(0.1, 0.1);                        { origin: fixed corner }
    Ed.Click(40, 20);
    P2 := 2;                                   { origin 0, (40,0) 1, (40,20) 2, (0,20) 3 }
    P3 := 3;
    Check(Near(S.PointX(P2), 40) and Near(S.PointY(P2), 20), 'drag: rectangle corner at (40, 20)');
    Ed.SetTool(sktSelect);
    Check(not Ed.BeginDrag(0, 0), 'drag: the fixed origin cannot be dragged');
    Check(Ed.BeginDrag(40.2, 19.9) and Ed.Dragging, 'drag: picks the free corner');
    Check(Ed.DragTo(50, 30), 'drag: moved');
    Check(Near(S.PointX(P2), 50) and Near(S.PointY(P2), 30) and Near(S.PointX(1), 50) and
      Near(S.PointY(1), 0) and Near(S.PointX(P3), 0) and Near(S.PointY(P3), 30),
      'drag: the rectangle stays a rectangle, the origin corner stays');
    Ed.EndDrag;
    Check(not Ed.Dragging and (Ed.LastSolve.Status = cssSolved) and (Ed.LastSolve.DOF = 2),
      Format('drag: end solves with diagnostics, DOF 2, got %d', [Ed.LastSolve.DOF]));
    { fully constrained: the drag cannot move it }
    S.Distance(0, 1, 50);
    S.Distance(1, P2, 30);
    CADSolveSketch(S);
    Check(Ed.BeginDrag(50, 30), 'drag: pick the constrained corner');
    Ed.DragTo(70, 45);
    Ed.EndDrag;
    Check(Near(S.PointX(P2), 50) and Near(S.PointY(P2), 30), 'drag: a fully constrained point stays put');
    { no drag while a shape is being drawn }
    Ed.SetTool(sktLine);
    Ed.Click(100, 100);
    Check(not Ed.BeginDrag(50, 30), 'drag: not while a line chain is open');
  finally
    Ed.Free;
    S.Free;
  end;
end;

function Sel(const APoints, AEntities: array of Integer): TCADSketchSelection;
var
  I: Integer;
begin
  Result := Default(TCADSketchSelection);
  SetLength(Result.Points, Length(APoints));
  for I := 0 to High(APoints) do
    Result.Points[I] := APoints[I];
  SetLength(Result.Entities, Length(AEntities));
  for I := 0 to High(AEntities) do
    Result.Entities[I] := AEntities[I];
end;

procedure TestCommands;
var
  S: TCADSketch;
  P0, P1, P2, P3, L0, L1, L2, L3, Cir, C, Idx: Integer;
  Err: string;
  Sl: TCADSketchSelection;
  X1: Double;
  R: TCADSketchSolveResult;
begin
  S := TCADSketch.Create;
  try
    P0 := S.AddPoint(0, 0);
    P1 := S.AddPoint(40, 1);
    P2 := S.AddPoint(41, 21);
    P3 := S.AddPoint(-1, 20);
    L0 := S.AddLine(P0, P1);
    L1 := S.AddLine(P1, P2);
    L2 := S.AddLine(P2, P3);
    L3 := S.AddLine(P3, P0);
    Cir := S.AddCircle(S.AddPoint(100, 0), 5);

    { picking }
    Check((CADSketchHit(S, 40.3, 1.2, 1, Idx) = chkPoint) and (Idx = P1), 'hit: corner point');
    Check((CADSketchHit(S, 20, 0.8, 1, Idx) = chkEntity) and (Idx = L0), 'hit: bottom line');
    Check((CADSketchHit(S, 104.8, 0, 1, Idx) = chkEntity) and (Idx = Cir), 'hit: circle rim');
    Check(CADSketchHit(S, 60, 60, 1, Idx) = chkNone, 'hit: empty space');
    Sl := Default(TCADSketchSelection);
    CADSelectionToggle(Sl, chkEntity, L0);
    CADSelectionToggle(Sl, chkPoint, P2);
    CADSelectionToggle(Sl, chkEntity, L0);
    Check((Length(Sl.Entities) = 0) and (Length(Sl.Points) = 1), 'selection: toggle adds and removes');

    { buttons }
    Check(CADApplyCommand(S, Sel([P0], []), sccFix, C, Err), 'fix the origin corner');
    Check(CADApplyCommand(S, Sel([], [L0]), sccHorizontal, C, Err) and (C >= 0), 'horizontal: ' + Err);
    Check(not CADApplyCommand(S, Sel([], [L0]), sccHorizontal, C, Err) and (Pos('implied', Err) > 0) and
      not S.Constraints[S.ConstraintCount - 1].Active, 'second horizontal is implied: taken back');
    Check(CADApplyCommand(S, Sel([], [L0, L1]), sccPerpendicular, C, Err), 'perpendicular: ' + Err);
    Check(CADApplyCommand(S, Sel([], [L2, L0]), sccParallel, C, Err), 'parallel: ' + Err);
    Check(CADApplyCommand(S, Sel([], [L3]), sccVertical, C, Err), 'vertical: ' + Err);
    Check(not CADApplyCommand(S, Sel([], [L0, L1]), sccTangent, C, Err) and (Pos('does not fit', Err) > 0),
      'tangent on two lines does not fit');

    X1 := S.PointX(P1);
    Check(CADApplyCommand(S, Sel([], [L0]), sccDimension, C, Err) and
      (S.Constraints[C].Kind = sckLength) and Near(S.PointX(P1), X1), 'dimension: current length, nothing moves');
    Check(CADSetDimension(S, C, 50, Err) and Near(S.PointX(P1), 50), 'set the length to 50');
    Check(Pos('length 50', CADConstraintLabel(S, C)) > 0, 'label shows the length: ' + CADConstraintLabel(S, C));
    Check(not CADSetDimension(S, C, -5, Err) and (Pos('positive', Err) > 0) and Near(S.PointX(P1), 50),
      'negative size refused');
    Check(not CADApplyCommand(S, Sel([], [L2]), sccDimension, C, Err) and (Pos('implied', Err) > 0),
      'top length is implied by the rectangle: taken back');
    Check(CADApplyCommand(S, Sel([], [L0, L1]), sccEqual, C, Err) and Near(S.PointY(P2), 50), 'equal: square 50');
    R := CADSolveSketch(S);
    Check((R.Status = cssSolved) and (R.DOF = 0), Format('square is fully constrained, DOF %d', [R.DOF]));

    { conflicting: a diagonal dimension that the square cannot take }
    Check(CADApplyCommand(S, Sel([P0, P2], []), sccDimension, C, Err) = False, 'diagonal of a fixed square is implied');
    Check(Near(S.PointX(P2), 50) and Near(S.PointY(P2), 50), 'taken back: the square did not move');

    { circle: diameter dimension, tangent to the extended top line }
    Check(CADApplyCommand(S, Sel([], [Cir]), sccDimension, C, Err) and (S.Constraints[C].Kind = sckDiameter) and
      Near(S.Constraints[C].Value, 10), 'circle dimension is its diameter');
    Check(CADApplyCommand(S, Sel([], [L2, Cir]), sccTangent, C, Err) and
      Near(Abs(S.PointY(S.Entities[Cir].Center) - 50), 5), 'tangent: circle touches the top line');
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
  TestProfiles;
  TestEditor;
  TestEditorDrag;
  TestCommands;
  if Failures = 0 then
    WriteLn(Format('PASS  sketch: %d checks', [Checks]))
  else
    WriteLn(Format('FAIL  sketch: %d of %d checks failed', [Failures, Checks]));
  if Failures <> 0 then
    Halt(1);
end.
