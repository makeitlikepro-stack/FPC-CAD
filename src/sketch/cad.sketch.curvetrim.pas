unit CAD.Sketch.CurveTrim;
{$mode objfpc}{$H+}

{ ROLE: SolidWorks-style click Trim for lines, arcs and circles.
  All pairs of straight/circular entities are intersected analytically,
  then clipped against their finite geometry (arcs run CCW from P1 to P2).
  Clicking deletes only the bounded span: an arc leaves zero, one or two
  arcs, a circle with 2+ crossings leaves the complementary arc, and a
  line leaves zero, one or two lines. The edited sketch is committed only
  after trial solving; unrelated constraints/geometry remain unchanged.
  CALLS: CAD.Sketch.Model, TrimExtend, Solver and Text. No UI or OCCT. }

interface

uses
  SysUtils, Math, CAD.Sketch.Model, CAD.Sketch.TrimExtend,
  CAD.Sketch.Solver, CAD.Sketch.Text;

{ APlan.FromT and ToT follow the entity's parameter:
    line: 0..1 along P1 -> P2;
    arc: 0..1 along its CCW sweep;
    circle: angle / (2*pi), with cyclic bounds allowed outside 0..1.
  The span containing the click is the piece to REMOVE. }
function CADPlanSketchTrim(S: TCADSketch; AEntity: Integer; X, Y: Double;
  out APlan: TCADTrimPlan; out AError: string): Boolean;

{ Performs the real topological edit, or returns False without mutation. }
function CADApplySketchTrim(S: TCADSketch; const APlan: TCADTrimPlan;
  out AError: string): Boolean;

implementation

const
  GeoEpsilon = 1e-9;
  ParamEpsilon = 1e-8;

type
  TIntersection = record
    X, Y: Double;
  end;
  TIntersections = array[0..1] of TIntersection;
  TCrossing = record
    T: Double;
    Boundary: Integer;
  end;
  TCrossings = array of TCrossing;

function Cross(AX, AY, BX, BY: Double): Double; inline;
begin
  Result := AX * BY - AY * BX;
end;

function CCWDelta(AStart, AEnd: Double): Double;
begin
  Result := AEnd - AStart;
  while Result < 0 do Result := Result + 2 * Pi;
  while Result >= 2 * Pi do Result := Result - 2 * Pi;
end;

function CCWSweep(AStart, AEnd: Double): Double;
begin
  Result := CCWDelta(AStart, AEnd);
  if Result <= 1e-12 then Result := 2 * Pi;
end;

function NormalAngle(A: Double): Double;
begin
  Result := A;
  while Result < 0 do Result := Result + 2 * Pi;
  while Result >= 2 * Pi do Result := Result - 2 * Pi;
end;

procedure CenterRadius(S: TCADSketch; AEntity: Integer;
  out CX, CY, R: Double);
var
  E: TCADSketchEntity;
begin
  E := S.Entities[AEntity];
  CX := S.PointX(E.Center);
  CY := S.PointY(E.Center);
  R := S.EntityRadius(AEntity);
end;

{ The intersection may lie on the supporting infinite curve; test the
  ACTUAL segment/arc. Circles have no endpoint restriction. }
function OnEntity(S: TCADSketch; AEntity: Integer; X, Y: Double): Boolean;
var
  E: TCADSketchEntity;
  AX, AY, DX, DY, L2, T, CX, CY, R, A0, A1, AP: Double;
begin
  Result := False;
  E := S.Entities[AEntity];
  if not E.Active then Exit;
  if E.Kind = sekLine then
  begin
    AX := S.PointX(E.P1);
    AY := S.PointY(E.P1);
    DX := S.PointX(E.P2) - AX;
    DY := S.PointY(E.P2) - AY;
    L2 := DX * DX + DY * DY;
    if L2 <= 1e-20 then Exit;
    T := ((X - AX) * DX + (Y - AY) * DY) / L2;
    Result := (T >= -ParamEpsilon) and (T <= 1 + ParamEpsilon);
    Exit;
  end;
  CenterRadius(S, AEntity, CX, CY, R);
  if R <= GeoEpsilon then Exit;
  if E.Kind = sekCircle then
    Exit(True);
  A0 := ArcTan2(S.PointY(E.P1) - CY, S.PointX(E.P1) - CX);
  A1 := ArcTan2(S.PointY(E.P2) - CY, S.PointX(E.P2) - CX);
  AP := ArcTan2(Y - CY, X - CX);
  Result := CCWDelta(A0, AP) <= CCWSweep(A0, A1) + ParamEpsilon;
end;

{ Compute up to two geometrical intersections, keeping only those that
  lie on BOTH finite entities. Tangent roots are counted once. }
function EntityIntersections(S: TCADSketch; A, B: Integer;
  out Points: TIntersections): Integer;
var
  EA, EB, EL: TCADSketchEntity;
  LineIndex, CurveIndex: Integer;
  AX, AY, DX, DY, BX, BY, EX, EY: Double;
  C1X, C1Y, R1, C2X, C2Y, R2: Double;
  D2, D, Den, T, Disc, BB, CC, H2, H, U, BaseX, BaseY, VX, VY: Double;

  procedure Add(X, Y: Double);
  begin
    if not OnEntity(S, A, X, Y) or not OnEntity(S, B, X, Y) then Exit;
    if (Result > 0) and
       (Hypot(Points[0].X - X, Points[0].Y - Y) <= 1e-7) then Exit;
    if Result >= 2 then Exit;
    Points[Result].X := X;
    Points[Result].Y := Y;
    Inc(Result);
  end;

begin
  Result := 0;
  EA := S.Entities[A];
  EB := S.Entities[B];
  if (not EA.Active) or (not EB.Active) then Exit;

  if (EA.Kind = sekLine) and (EB.Kind = sekLine) then
  begin
    AX := S.PointX(EA.P1);
    AY := S.PointY(EA.P1);
    DX := S.PointX(EA.P2) - AX;
    DY := S.PointY(EA.P2) - AY;
    BX := S.PointX(EB.P1);
    BY := S.PointY(EB.P1);
    EX := S.PointX(EB.P2) - BX;
    EY := S.PointY(EB.P2) - BY;
    Den := Cross(DX, DY, EX, EY);
    if Abs(Den) <= 1e-12 * Hypot(DX, DY) * Hypot(EX, EY) then Exit;
    T := Cross(BX - AX, BY - AY, EX, EY) / Den;
    Add(AX + T * DX, AY + T * DY);
    Exit;
  end;

  if (EA.Kind = sekLine) or (EB.Kind = sekLine) then
  begin
    if EA.Kind = sekLine then
    begin
      LineIndex := A;
      CurveIndex := B;
    end
    else
    begin
      LineIndex := B;
      CurveIndex := A;
    end;
    EL := S.Entities[LineIndex];
    AX := S.PointX(EL.P1);
    AY := S.PointY(EL.P1);
    DX := S.PointX(EL.P2) - AX;
    DY := S.PointY(EL.P2) - AY;
    D2 := DX * DX + DY * DY;
    if D2 <= 1e-20 then Exit;
    CenterRadius(S, CurveIndex, C1X, C1Y, R1);
    if R1 <= GeoEpsilon then Exit;
    BX := AX - C1X;
    BY := AY - C1Y;
    BB := 2 * (BX * DX + BY * DY);
    CC := BX * BX + BY * BY - R1 * R1;
    Disc := BB * BB - 4 * D2 * CC;
    if Disc < -1e-10 * Max(1.0, Sqr(D2 + Abs(CC))) then Exit;
    Disc := Max(0.0, Disc);
    T := (-BB - Sqrt(Disc)) / (2 * D2);
    Add(AX + T * DX, AY + T * DY);
    if Disc > 0 then
    begin
      T := (-BB + Sqrt(Disc)) / (2 * D2);
      Add(AX + T * DX, AY + T * DY);
    end;
    Exit;
  end;

  { Circle/circle also applies to an arc's supporting circle. }
  CenterRadius(S, A, C1X, C1Y, R1);
  CenterRadius(S, B, C2X, C2Y, R2);
  if (R1 <= GeoEpsilon) or (R2 <= GeoEpsilon) then Exit;
  DX := C2X - C1X;
  DY := C2Y - C1Y;
  D := Hypot(DX, DY);
  if D <= GeoEpsilon then Exit;              { coincident, or concentric }
  if (D > R1 + R2 + GeoEpsilon) or
     (D < Abs(R1 - R2) - GeoEpsilon) then Exit;
  U := (R1 * R1 - R2 * R2 + D * D) / (2 * D);
  H2 := R1 * R1 - U * U;
  if H2 < -GeoEpsilon then Exit;
  H := Sqrt(Max(0.0, H2));
  BaseX := C1X + U * DX / D;
  BaseY := C1Y + U * DY / D;
  VX := -DY * H / D;
  VY := DX * H / D;
  Add(BaseX + VX, BaseY + VY);
  if H > GeoEpsilon then Add(BaseX - VX, BaseY - VY);
end;

function EntityParameter(S: TCADSketch; AEntity: Integer;
  X, Y: Double): Double;
var
  E: TCADSketchEntity;
  AX, AY, DX, DY, D2, CX, CY, R, A0, A1, AP: Double;
begin
  E := S.Entities[AEntity];
  if E.Kind = sekLine then
  begin
    AX := S.PointX(E.P1);
    AY := S.PointY(E.P1);
    DX := S.PointX(E.P2) - AX;
    DY := S.PointY(E.P2) - AY;
    D2 := DX * DX + DY * DY;
    if D2 <= 1e-20 then Exit(0);
    Exit(EnsureRange(((X - AX) * DX + (Y - AY) * DY) / D2, 0.0, 1.0));
  end;
  CenterRadius(S, AEntity, CX, CY, R);
  AP := ArcTan2(Y - CY, X - CX);
  if E.Kind = sekCircle then
    Exit(NormalAngle(AP) / (2 * Pi));
  A0 := ArcTan2(S.PointY(E.P1) - CY, S.PointX(E.P1) - CX);
  A1 := ArcTan2(S.PointY(E.P2) - CY, S.PointX(E.P2) - CX);
  Result := EnsureRange(CCWDelta(A0, AP) / CCWSweep(A0, A1), 0.0, 1.0);
end;

function CADPlanSketchTrim(S: TCADSketch; AEntity: Integer; X, Y: Double;
  out APlan: TCADTrimPlan; out AError: string): Boolean;
var
  E: TCADSketchEntity;
  Hits: TCrossings;
  Pair: TIntersections;
  ClickT, T, Tol, LeftT, RightT: Double;
  I, J, K, Count, Num, LeftId, RightId: Integer;
  Duplicate: Boolean;
begin
  Result := False;
  AError := '';
  APlan := Default(TCADTrimPlan);
  APlan.TargetEntity := AEntity;
  APlan.FromT := 0;
  APlan.ToT := 1;
  APlan.LeftBoundary := -1;
  APlan.RightBoundary := -1;
  if (S = nil) or (AEntity < 0) then
  begin
    AError := 'no sketch or trim target';
    Exit;
  end;
  if AEntity >= S.EntityCount then
  begin
    AError := 'trim target index is out of range';
    Exit;
  end;
  E := S.Entities[AEntity];
  if not E.Active then
  begin
    AError := 'the selected entity was already removed';
    Exit;
  end;

  ClickT := EntityParameter(S, AEntity, X, Y);
  Tol := ParamEpsilon;
  Count := 0;
  Hits := nil;
  for I := 0 to S.EntityCount - 1 do
  begin
    if I = AEntity then Continue;
    Num := EntityIntersections(S, AEntity, I, Pair);
    for J := 0 to Num - 1 do
    begin
      T := EntityParameter(S, AEntity, Pair[J].X, Pair[J].Y);
      if E.Kind <> sekCircle then
      begin
        if (T <= Tol) or (T >= 1 - Tol) then Continue;
      end
      else if T >= 1 - Tol then
        T := 0;
      if (Abs(T - ClickT) <= Tol) or
         ((E.Kind = sekCircle) and
          (Abs(Abs(T - ClickT) - 1) <= Tol)) then
      begin
        AError := 'click on the curve between crossings, not at a crossing';
        Exit;
      end;
      Duplicate := False;
      for K := 0 to Count - 1 do
        if (Abs(Hits[K].T - T) <= Tol) or
           ((E.Kind = sekCircle) and
             (Abs(Abs(Hits[K].T - T) - 1) <= Tol)) then
        begin
          Duplicate := True;
          Break;
        end;
      if Duplicate then Continue;
      SetLength(Hits, Count + 1);
      Hits[Count].T := T;
      Hits[Count].Boundary := I;
      Inc(Count);
    end;
  end;

  if E.Kind = sekCircle then
  begin
    if Count = 1 then
    begin
      AError := 'a circle needs at least two distinct crossings to trim a portion';
      Exit;
    end;
    if Count = 0 then
      Exit(True);                             { remove the entire circle }
    LeftT := -1e100;
    RightT := 1e100;
    LeftId := -1;
    RightId := -1;
    for I := 0 to Count - 1 do
    begin
      T := Hits[I].T;
      if T >= ClickT then T := T - 1;
      if T > LeftT then
      begin
        LeftT := T;
        LeftId := Hits[I].Boundary;
      end;
      T := Hits[I].T;
      if T <= ClickT then T := T + 1;
      if T < RightT then
      begin
        RightT := T;
        RightId := Hits[I].Boundary;
      end;
    end;
    APlan.FromT := LeftT;
    APlan.ToT := RightT;
    APlan.LeftBoundary := LeftId;
    APlan.RightBoundary := RightId;
  end
  else
  begin
    for I := 0 to Count - 1 do
    begin
      T := Hits[I].T;
      if (T < ClickT) and (T > APlan.FromT) then
      begin
        APlan.FromT := T;
        APlan.LeftBoundary := Hits[I].Boundary;
      end;
      if (T > ClickT) and (T < APlan.ToT) then
      begin
        APlan.ToT := T;
        APlan.RightBoundary := Hits[I].Boundary;
      end;
    end;
  end;
  Result := (APlan.ToT - APlan.FromT > ParamEpsilon) and
            (APlan.ToT - APlan.FromT <= 1 + ParamEpsilon);
  if not Result then AError := 'cannot determine the clicked trim span';
end;

{ A dimension/relationship on the source curve needs to be reattached to
  the remaining arcs; only radius and diameter can safely be duplicated.
  The arc's automatic radius-equality rule is generated by AddArc. }
function UsesCurve(const C: TCADSketchConstraint; ACurve: Integer): Boolean;
begin
  case C.Kind of
    sckHorizontal, sckVertical, sckLength, sckRadius, sckDiameter, sckArcRule:
      Result := C.A = ACurve;
    sckPointOnLine, sckPointOnCircle, sckPointLineDist, sckMidpoint:
      Result := C.B = ACurve;
    sckSymmetric:
      Result := C.C = ACurve;
    sckParallel, sckPerpendicular, sckAngle, sckCollinear, sckEqualLength,
    sckEqualRadius, sckTangentLine, sckTangentCircles, sckConcentric:
      Result := (C.A = ACurve) or (C.B = ACurve);
  else
    Result := False;
  end;
end;

function CADApplySketchTrim(S: TCADSketch; const APlan: TCADTrimPlan;
  out AError: string): Boolean;
var
  Trial: TCADSketch;
  E: TCADSketchEntity;
  C: TCADSketchConstraint;
  I, TargetIndex, P, L: Integer;
  CX, CY, R, AStart, AEnd, Sweep, FromT, ToT: Double;
  HasSurvivors: Boolean;
  SolveResult: TCADSketchSolveResult;

  procedure AddArcPiece(AFirst, ALast: Integer);
  var
    K: Integer;
    Dim: TCADSketchConstraint;
  begin
    L := Trial.AddArc(E.Center, AFirst, ALast);
    Trial.SetConstruction(L, E.Construction);
    for K := 0 to S.ConstraintCount - 1 do
    begin
      Dim := S.Constraints[K];
      if not Dim.Active or not UsesCurve(Dim, TargetIndex) then Continue;
      case Dim.Kind of
        sckRadius: Trial.Radius(L, Dim.Value);
        sckDiameter: Trial.Diameter(L, Dim.Value);
      end;
    end;
  end;

  function NewAnglePoint(Angle: Double): Integer;
  begin
    Result := Trial.AddPoint(CX + R * Cos(Angle), CY + R * Sin(Angle));
  end;

begin
  Result := False;
  AError := '';
  TargetIndex := APlan.TargetEntity;
  if (S = nil) or (TargetIndex < 0) then
  begin
    AError := 'no sketch or trim target';
    Exit;
  end;
  if TargetIndex >= S.EntityCount then
  begin
    AError := 'invalid trim target index';
    Exit;
  end;
  E := S.Entities[TargetIndex];
  if (not E.Active) or (APlan.ToT - APlan.FromT <= ParamEpsilon) or
     (APlan.ToT - APlan.FromT > 1 + ParamEpsilon) then
  begin
    AError := 'invalid or retired trim span';
    Exit;
  end;
  if E.Kind = sekLine then
    Exit(CADApplyLineTrim(S, APlan, AError));
  if (E.Kind = sekArc) and
     ((APlan.FromT < 0) or (APlan.ToT > 1)) then
  begin
    AError := 'the arc trim span is out of range';
    Exit;
  end;

  FromT := APlan.FromT;
  ToT := APlan.ToT;
  HasSurvivors := (E.Kind = sekCircle) and
                  (ToT - FromT < 1 - ParamEpsilon);
  if E.Kind = sekArc then
    HasSurvivors := (FromT > ParamEpsilon) or
                    (ToT < 1 - ParamEpsilon);

  { Never reassign a tangent/concentric/equal-radius relationship to an
    arbitrary survivor. It requires an explicit constraint-migration rule. }
  if HasSurvivors then
    for I := 0 to S.ConstraintCount - 1 do
    begin
      C := S.Constraints[I];
      if C.Active and UsesCurve(C, TargetIndex) and not
         (C.Kind in [sckArcRule, sckRadius, sckDiameter]) then
      begin
        AError := 'curve has relations that need explicit remapping; trim refused';
        Exit;
      end;
    end;

  Trial := TCADSketch.Create;
  try
    try
      CADSketchFromText(CADSketchToText(S), Trial);
      E := Trial.Entities[TargetIndex];
      CenterRadius(Trial, TargetIndex, CX, CY, R);
      if R <= GeoEpsilon then
      begin
        AError := 'cannot trim a curve with zero radius';
        Exit;
      end;
      if E.Kind = sekCircle then
      begin
        if HasSurvivors then
        begin
          { Complement of the deleted CCW interval: To -> From + 1. }
          P := NewAnglePoint(ToT * 2 * Pi);
          L := NewAnglePoint(FromT * 2 * Pi);
          AddArcPiece(P, L);
        end;
      end
      else
      begin
        AStart := ArcTan2(Trial.PointY(E.P1) - CY,
                         Trial.PointX(E.P1) - CX);
        AEnd := ArcTan2(Trial.PointY(E.P2) - CY,
                       Trial.PointX(E.P2) - CX);
        Sweep := CCWSweep(AStart, AEnd);
        if FromT > ParamEpsilon then
        begin
          P := NewAnglePoint(AStart + FromT * Sweep);
          AddArcPiece(E.P1, P);
        end;
        if ToT < 1 - ParamEpsilon then
        begin
          P := NewAnglePoint(AStart + ToT * Sweep);
          AddArcPiece(P, E.P2);
        end;
      end;
      Trial.RemoveEntity(TargetIndex);
      SolveResult := CADSolveSketch(Trial);
      if SolveResult.Status <> cssSolved then
      begin
        AError := 'trim conflicts with remaining sketch constraints; nothing changed';
        Exit;
      end;
      S.AssignFrom(Trial);
      Result := True;
    except
      on Ex: Exception do
      begin
        AError := 'curve trim failed: ' + Ex.Message;
        Result := False;
      end;
    end;
  finally
    Trial.Free;
  end;
end;

end.
