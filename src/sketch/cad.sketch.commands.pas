unit CAD.Sketch.Commands;
{$mode objfpc}{$H+}

{ ROLE:      what the constraint buttons do: hit test for picking, a
             selection (points + entities), one command per button that
             turns the selection into a constraint (dimensions take the
             current value, so nothing jumps), solve, and undo the constraint
             when it conflicts or is already implied. Labels for the list.
  CALLED BY: CAD.Sketch.Editor (pick), the app sketch panel, tests/sketch.
  CALLS:     CAD.Sketch.Model, CAD.Sketch.Solver, CAD.Sketch.Text (names).
  THREADS:   UI thread.
  SPEED:     one solve with diagnostics per command; hit test is a scan. }

interface

uses
  SysUtils, Math, CAD.Sketch.Model, CAD.Sketch.Solver, CAD.Sketch.Text;

type
  TCADIndexArray = array of Integer;

  TCADSketchSelection = record
    Points: TCADIndexArray;
    Entities: TCADIndexArray;
  end;

  TCADSketchCommand = (sccHorizontal, sccVertical, sccCoincident, sccParallel,
    sccPerpendicular, sccEqual, sccTangent, sccConcentric, sccMidpoint, sccOnObject,
    sccSymmetric, sccFix, sccDimension, sccDistX, sccDistY);

  TCADHitKind = (chkNone, chkPoint, chkEntity);

{ Nearest point within ATol, else nearest entity within ATol. }
function CADSketchHit(S: TCADSketch; X, Y, ATol: Double; out AIndex: Integer): TCADHitKind;
{ Edit tools must pick an entity even when the cursor is near its endpoint.
  Returns -1 when no active entity is within the tolerance. }
function CADSketchEntityHit(S: TCADSketch; X, Y, ATol: Double): Integer;
{ Adds or removes (toggle) a picked item. }
procedure CADSelectionToggle(var ASel: TCADSketchSelection; AKind: TCADHitKind; AIndex: Integer);
procedure CADSelectionClear(var ASel: TCADSketchSelection);
function CADSelectionText(S: TCADSketch; const ASel: TCADSketchSelection): string;
{ Adds the constraint for the selection and solves. False + AError when the
  selection does not fit the command, or the constraint conflicts / is
  already implied (then it is removed again and the sketch is solved back). }
function CADApplyCommand(S: TCADSketch; const ASel: TCADSketchSelection;
  ACommand: TCADSketchCommand; out AConstraint: Integer; out AError: string): Boolean;
{ New value for a dimension; reverted (with AError) when it cannot be solved. }
function CADSetDimension(S: TCADSketch; AConstraint: Integer; AValue: Double;
  out AError: string): Boolean;
function CADIsDimension(AKind: TCADSketchConstraintKind): Boolean;
{ '#4 length 60' etc. Angles in degrees. }
function CADConstraintLabel(S: TCADSketch; AIndex: Integer): string;
{ Value shown and edited for a dimension (degrees for angles). }
function CADDimensionShown(const C: TCADSketchConstraint): Double;
{ The value a user sees and types for dimension AIndex. Angles: the angle
  between the two segments as drawn, 0..180 degrees, the smaller side (the
  constraint itself keeps the directed angle of the line directions). }
function CADDimensionShownIn(S: TCADSketch; AIndex: Integer): Double;
{ Crossing of the two lines of an angle constraint and the unit rays from
  it towards each segment; False for parallel lines. }
function CADAngleRays(S: TCADSketch; ALine1, ALine2: Integer;
  out VX, VY, R1X, R1Y, R2X, R2Y: Double): Boolean;
function CADCommandName(ACommand: TCADSketchCommand): string;
{ The fixed point at (0, 0); made when the sketch has none. }
function CADOriginPoint(S: TCADSketch): Integer;
{ Short text for a dimension in the view, drafting style: '60', 'R5',
  diameter sign + '10', '90' + degree sign; distance X / Y: the number. }
function CADDimensionChipText(S: TCADSketch; AIndex: Integer): string;
{ Where the chip of a dimension sits (sketch mm). }
function CADDimensionAnchor(S: TCADSketch; AIndex: Integer; out U, V: Double): Boolean;
{ Active length / radius / diameter dimension on an entity, -1 = none. }
function CADFindDimension(S: TCADSketch; AEntity: Integer): Integer;
{ Relation glyph text shown next to the geometry ('' = not shown:
  dimensions, coincident, arc rule, removed). }
function CADRelationGlyph(S: TCADSketch; AIndex: Integer): string;
{ Where a relation glyph sits (sketch mm): its first entity or point. }
function CADRelationAnchor(S: TCADSketch; AIndex: Integer; out U, V: Double): Boolean;

implementation

const
  CommandNames: array[TCADSketchCommand] of string = ('Horizontal', 'Vertical', 'Coincident',
    'Parallel', 'Perpendicular', 'Equal', 'Tangent', 'Concentric', 'Midpoint', 'On object',
    'Symmetric', 'Fix', 'Dimension', 'Distance X', 'Distance Y');

function CADCommandName(ACommand: TCADSketchCommand): string;
begin
  Result := CommandNames[ACommand];
end;

{ ---------------------------------------------------------- picking }

function DistToSegment(PX, PY, AX, AY, BX, BY: Double): Double;
var
  DX, DY, T: Double;
begin
  DX := BX - AX;
  DY := BY - AY;
  T := 0;
  if DX * DX + DY * DY > 1e-24 then
    T := EnsureRange(((PX - AX) * DX + (PY - AY) * DY) / (DX * DX + DY * DY), 0.0, 1.0);
  Result := Hypot(PX - (AX + T * DX), PY - (AY + T * DY));
end;

function EntityDistance(S: TCADSketch; AEntity: Integer; X, Y: Double): Double;
var
  E: TCADSketchEntity;
  CX, CY, R, A, A1, A2, Sweep, T: Double;
begin
  E := S.Entities[AEntity];
  case E.Kind of
    sekLine:
      Result := DistToSegment(X, Y, S.PointX(E.P1), S.PointY(E.P1), S.PointX(E.P2), S.PointY(E.P2));
    sekCircle:
      Result := Abs(Hypot(X - S.PointX(E.Center), Y - S.PointY(E.Center)) - S.EntityRadius(AEntity));
  else
    begin
      CX := S.PointX(E.Center);
      CY := S.PointY(E.Center);
      R := S.EntityRadius(AEntity);
      A := ArcTan2(Y - CY, X - CX);
      A1 := ArcTan2(S.PointY(E.P1) - CY, S.PointX(E.P1) - CX);
      A2 := ArcTan2(S.PointY(E.P2) - CY, S.PointX(E.P2) - CX);
      Sweep := A2 - A1;
      while Sweep <= 0 do
        Sweep := Sweep + 2 * Pi;
      T := A - A1;
      while T < 0 do
        T := T + 2 * Pi;
      if T <= Sweep then
        Result := Abs(Hypot(X - CX, Y - CY) - R)
      else
        Result := Min(Hypot(X - S.PointX(E.P1), Y - S.PointY(E.P1)),
          Hypot(X - S.PointX(E.P2), Y - S.PointY(E.P2)));
    end;
  end;
end;

function CADSketchEntityHit(S: TCADSketch; X, Y, ATol: Double): Integer;
var
  I: Integer;
  Best, D: Double;
begin
  Result := -1;
  if S = nil then Exit;
  Best := ATol;
  for I := 0 to S.EntityCount - 1 do
  begin
    if not S.Entities[I].Active then Continue;
    D := EntityDistance(S, I, X, Y);
    if (D < Best) or
       ((Result >= 0) and (Abs(D - Best) <= 1e-9) and
        (S.Entities[I].Kind = sekLine) and
        (S.Entities[Result].Kind <> sekLine)) then
    begin
      Best := D;
      Result := I;
    end;
  end;
end;

function CADSketchHit(S: TCADSketch; X, Y, ATol: Double; out AIndex: Integer): TCADHitKind;
var
  I: Integer;
  Best, D: Double;
begin
  Result := chkNone;
  AIndex := -1;
  Best := ATol;
  for I := 0 to S.PointCount - 1 do
  begin
    if not S.Points[I].Active then Continue;
    D := Hypot(S.PointX(I) - X, S.PointY(I) - Y);
    if D <= Best then
    begin
      Best := D;
      Result := chkPoint;
      AIndex := I;
    end;
  end;
  if Result = chkPoint then
    Exit;
  for I := 0 to S.EntityCount - 1 do
  begin
    if not S.Entities[I].Active then Continue;
    D := EntityDistance(S, I, X, Y);
    if D <= Best then
    begin
      Best := D;
      Result := chkEntity;
      AIndex := I;
    end;
  end;
end;

{ ---------------------------------------------------------- selection }

procedure CADSelectionToggle(var ASel: TCADSketchSelection; AKind: TCADHitKind; AIndex: Integer);

  procedure Flip(var A: TCADIndexArray);
  var
    I, N: Integer;
  begin
    N := Length(A);
    for I := 0 to N - 1 do
      if A[I] = AIndex then
      begin
        A[I] := A[N - 1];
        SetLength(A, N - 1);
        Exit;
      end;
    SetLength(A, N + 1);
    A[N] := AIndex;
  end;

begin
  case AKind of
    chkPoint: Flip(ASel.Points);
    chkEntity: Flip(ASel.Entities);
  end;
end;

procedure CADSelectionClear(var ASel: TCADSketchSelection);
begin
  ASel.Points := nil;
  ASel.Entities := nil;
end;

const
  EntityNames: array[TCADSketchEntityKind] of string = ('line', 'circle', 'arc');

function CADSelectionText(S: TCADSketch; const ASel: TCADSketchSelection): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(ASel.Points) do
    Result := Result + Format('point %d, ', [ASel.Points[I]]);
  for I := 0 to High(ASel.Entities) do
    Result := Result + Format('%s %d, ', [EntityNames[S.Entities[ASel.Entities[I]].Kind],
      ASel.Entities[I]]);
  if Result = '' then
    Result := 'nothing'
  else
    SetLength(Result, Length(Result) - 2);
end;

{ ---------------------------------------------------------- commands }

function CADOriginPoint(S: TCADSketch): Integer;
var
  I: Integer;
begin
  for I := 0 to S.PointCount - 1 do
    if S.Points[I].Active and S.Fixed[S.Points[I].XParam] and
       (S.PointX(I) = 0) and (S.PointY(I) = 0) then
      Exit(I);
  Result := S.AddPoint(0, 0);
  S.FixPoint(Result);
end;

function CADDimensionChipText(S: TCADSketch; AIndex: Integer): string;
var
  C: TCADSketchConstraint;
  V: string;
begin
  C := S.Constraints[AIndex];
  V := FormatFloat('0.##', CADDimensionShownIn(S, AIndex));
  case C.Kind of
    { drafting style: R5, diameter sign + 10 (UTF-8), 90 + degree sign;
      horizontal / vertical distances show the plain number (the drawn
      dimension line tells the direction) }
    sckRadius: Result := 'R' + V;
    sckDiameter: Result := #$C3#$98 + V;
    sckAngle: Result := V + #$C2#$B0;
  else
    Result := V;
  end;
end;

function CADDimensionAnchor(S: TCADSketch; AIndex: Integer; out U, V: Double): Boolean;
var
  C: TCADSketchConstraint;
  E: TCADSketchEntity;
  R, DX, DY, L, T: Double;
begin
  C := S.Constraints[AIndex];
  Result := C.Active and CADIsDimension(C.Kind);
  U := 0;
  V := 0;
  if not Result then
    Exit;
  case C.Kind of
    sckDistance:
      begin
        U := 0.5 * (S.PointX(C.A) + S.PointX(C.B));
        V := 0.5 * (S.PointY(C.A) + S.PointY(C.B));
      end;
    sckDistanceX:
      begin
        U := 0.5 * (S.PointX(C.A) + S.PointX(C.B));
        V := S.PointY(C.B);
      end;
    sckDistanceY:
      begin
        U := S.PointX(C.B);
        V := 0.5 * (S.PointY(C.A) + S.PointY(C.B));
      end;
    sckLength, sckAngle:
      begin
        E := S.Entities[C.A];
        U := 0.5 * (S.PointX(E.P1) + S.PointX(E.P2));
        V := 0.5 * (S.PointY(E.P1) + S.PointY(E.P2));
      end;
    sckRadius, sckDiameter:
      begin
        E := S.Entities[C.A];
        R := S.EntityRadius(C.A);
        U := S.PointX(E.Center) + R * 0.7071;
        V := S.PointY(E.Center) + R * 0.7071;
      end;
    sckPointLineDist:
      begin
        E := S.Entities[C.B];
        DX := S.PointX(E.P2) - S.PointX(E.P1);
        DY := S.PointY(E.P2) - S.PointY(E.P1);
        L := Max(DX * DX + DY * DY, 1e-24);
        T := ((S.PointX(C.A) - S.PointX(E.P1)) * DX + (S.PointY(C.A) - S.PointY(E.P1)) * DY) / L;
        U := 0.5 * (S.PointX(C.A) + S.PointX(E.P1) + T * DX);
        V := 0.5 * (S.PointY(C.A) + S.PointY(E.P1) + T * DY);
      end;
  end;
end;

function CADFindDimension(S: TCADSketch; AEntity: Integer): Integer;
var
  I: Integer;
  C: TCADSketchConstraint;
begin
  for I := 0 to S.ConstraintCount - 1 do
  begin
    C := S.Constraints[I];
    if C.Active and (C.Kind in [sckLength, sckRadius, sckDiameter]) and (C.A = AEntity) then
      Exit(I);
  end;
  Result := -1;
end;

function CADRelationGlyph(S: TCADSketch; AIndex: Integer): string;
var
  C: TCADSketchConstraint;
begin
  C := S.Constraints[AIndex];
  Result := '';
  if not C.Active then
    Exit;
  case C.Kind of
    sckCoincident: Result := 'Coin';
    sckHorizontal, sckHorizontalPts: Result := 'H';
    sckVertical, sckVerticalPts: Result := 'V';
    sckParallel: Result := '//';
    sckPerpendicular: Result := '90';
    sckCollinear: Result := '--';
    sckEqualLength, sckEqualRadius: Result := '=';
    sckTangentLine, sckTangentCircles: Result := 'T';
    sckConcentric: Result := 'O';
    sckMidpoint: Result := 'M';
    sckPointOnLine, sckPointOnCircle: Result := 'On';
    sckSymmetric: Result := 'S';
  end;
end;

function EntityAnchor(S: TCADSketch; AEntity: Integer; out U, V: Double): Boolean;
var
  E: TCADSketchEntity;
begin
  E := S.Entities[AEntity];
  if E.Kind = sekLine then
  begin
    U := 0.5 * (S.PointX(E.P1) + S.PointX(E.P2));
    V := 0.5 * (S.PointY(E.P1) + S.PointY(E.P2));
  end
  else
  begin
    U := S.PointX(E.Center);
    V := S.PointY(E.Center) + S.EntityRadius(AEntity);    { top of the circle }
  end;
  Result := True;
end;

function CADRelationAnchor(S: TCADSketch; AIndex: Integer; out U, V: Double): Boolean;
var
  C: TCADSketchConstraint;
begin
  U := 0;
  V := 0;
  C := S.Constraints[AIndex];
  Result := CADRelationGlyph(S, AIndex) <> '';
  if not Result then
    Exit;
  case C.Kind of
    sckCoincident:
      begin
        { Both points coincide when solved; use their midpoint during
          intermediate solver updates so the indicator stays attached. }
        U := 0.5 * (S.PointX(C.A) + S.PointX(C.B));
        V := 0.5 * (S.PointY(C.A) + S.PointY(C.B));
      end;
    sckHorizontalPts, sckVerticalPts, sckMidpoint, sckPointOnLine, sckPointOnCircle:
      begin
        U := S.PointX(C.A);
        V := S.PointY(C.A);
      end;
    sckSymmetric:
      Result := EntityAnchor(S, C.C, U, V);
  else
    Result := EntityAnchor(S, C.A, U, V);
  end;
end;

function CADIsDimension(AKind: TCADSketchConstraintKind): Boolean;
begin
  Result := AKind in [sckDistance, sckDistanceX, sckDistanceY, sckLength, sckPointLineDist,
    sckAngle, sckRadius, sckDiameter];
end;

function CADDimensionShown(const C: TCADSketchConstraint): Double;
begin
  if C.Kind = sckAngle then
    Result := RadToDeg(C.Value)
  else
    Result := C.Value;
end;

function CADAngleRays(S: TCADSketch; ALine1, ALine2: Integer;
  out VX, VY, R1X, R1Y, R2X, R2Y: Double): Boolean;
var
  E1, E2: TCADSketchEntity;
  AX, AY, BX, BY, CX, CY, DX, DY, D1X, D1Y, D2X, D2Y, Den, T, L: Double;
begin
  VX := 0; VY := 0; R1X := 1; R1Y := 0; R2X := 1; R2Y := 0;
  E1 := S.Entities[ALine1];
  E2 := S.Entities[ALine2];
  Result := False;
  if (E1.Kind <> sekLine) or (E2.Kind <> sekLine) then
    Exit;
  AX := S.PointX(E1.P1); AY := S.PointY(E1.P1);
  BX := S.PointX(E1.P2); BY := S.PointY(E1.P2);
  CX := S.PointX(E2.P1); CY := S.PointY(E2.P1);
  DX := S.PointX(E2.P2); DY := S.PointY(E2.P2);
  D1X := BX - AX; D1Y := BY - AY;
  D2X := DX - CX; D2Y := DY - CY;
  Den := D1X * D2Y - D1Y * D2X;
  if Abs(Den) < 1e-12 * Max(1e-12, Hypot(D1X, D1Y) * Hypot(D2X, D2Y)) then
    Exit;                                  { parallel: no crossing }
  T := ((CX - AX) * D2Y - (CY - AY) * D2X) / Den;
  VX := AX + T * D1X;
  VY := AY + T * D1Y;
  { each ray points from the crossing to the middle of its own segment }
  L := Hypot(D1X, D1Y);
  R1X := D1X / L; R1Y := D1Y / L;
  if (0.5 * (AX + BX) - VX) * R1X + (0.5 * (AY + BY) - VY) * R1Y < 0 then
  begin
    R1X := -R1X; R1Y := -R1Y;
  end;
  L := Hypot(D2X, D2Y);
  R2X := D2X / L; R2Y := D2Y / L;
  if (0.5 * (CX + DX) - VX) * R2X + (0.5 * (CY + DY) - VY) * R2Y < 0 then
  begin
    R2X := -R2X; R2Y := -R2Y;
  end;
  Result := True;
end;

{ True when both rays run with their line directions or both against them:
  then the drawn angle is |directed angle|, else 180 - |directed angle|. }
function AngleSameSide(S: TCADSketch; const C: TCADSketchConstraint): Boolean;
var
  VX, VY, R1X, R1Y, R2X, R2Y, D1X, D1Y, D2X, D2Y: Double;
  E1, E2: TCADSketchEntity;
begin
  Result := True;
  if not CADAngleRays(S, C.A, C.B, VX, VY, R1X, R1Y, R2X, R2Y) then
    Exit;
  E1 := S.Entities[C.A];
  E2 := S.Entities[C.B];
  D1X := S.PointX(E1.P2) - S.PointX(E1.P1);
  D1Y := S.PointY(E1.P2) - S.PointY(E1.P1);
  D2X := S.PointX(E2.P2) - S.PointX(E2.P1);
  D2Y := S.PointY(E2.P2) - S.PointY(E2.P1);
  Result := ((D1X * R1X + D1Y * R1Y) > 0) = ((D2X * R2X + D2Y * R2Y) > 0);
end;

function CADDimensionShownIn(S: TCADSketch; AIndex: Integer): Double;
var
  C: TCADSketchConstraint;
begin
  C := S.Constraints[AIndex];
  Result := CADDimensionShown(C);
  if C.Kind <> sckAngle then
    Exit;
  Result := Abs(Result);
  if Result > 180 then
    Result := 360 - Result;
  if not AngleSameSide(S, C) then
    Result := 180 - Result;
end;

function CADConstraintLabel(S: TCADSketch; AIndex: Integer): string;
var
  C: TCADSketchConstraint;
begin
  C := S.Constraints[AIndex];
  Result := Format('#%d %s', [AIndex, CADConstraintKindName(C.Kind)]);
  if CADIsDimension(C.Kind) then
    Result := Result + ' ' + FormatFloat('0.###', CADDimensionShownIn(S, AIndex));
  if not C.Active then
    Result := Result + ' (removed)';
end;

function KindOf(S: TCADSketch; AEntity: Integer): TCADSketchEntityKind;
begin
  Result := S.Entities[AEntity].Kind;
end;

function IsRound(S: TCADSketch; AEntity: Integer): Boolean;
begin
  Result := KindOf(S, AEntity) in [sekCircle, sekArc];
end;

function LineAngle(S: TCADSketch; L1, L2: Integer): Double;
var
  E1, E2: TCADSketchEntity;
  D1X, D1Y, D2X, D2Y: Double;
begin
  E1 := S.Entities[L1];
  E2 := S.Entities[L2];
  D1X := S.PointX(E1.P2) - S.PointX(E1.P1);
  D1Y := S.PointY(E1.P2) - S.PointY(E1.P1);
  D2X := S.PointX(E2.P2) - S.PointX(E2.P1);
  D2Y := S.PointY(E2.P2) - S.PointY(E2.P1);
  Result := ArcTan2(D1X * D2Y - D1Y * D2X, D1X * D2X + D1Y * D2Y);
end;

function PointLineDist(S: TCADSketch; P, L: Integer): Double;
var
  E: TCADSketchEntity;
  AX, AY, DX, DY: Double;
begin
  E := S.Entities[L];
  AX := S.PointX(E.P1);
  AY := S.PointY(E.P1);
  DX := S.PointX(E.P2) - AX;
  DY := S.PointY(E.P2) - AY;
  Result := Abs(DX * (S.PointY(P) - AY) - DY * (S.PointX(P) - AX)) / Max(Hypot(DX, DY), 1e-12);
end;

{ The constraint for a selection; -1 + AError when it does not fit. }
function AddFor(S: TCADSketch; const ASel: TCADSketchSelection; ACommand: TCADSketchCommand;
  out AError: string): Integer;
var
  NP, NE: Integer;
  P0, P1, E0, E1: Integer;
begin
  Result := -1;
  AError := '';
  NP := Length(ASel.Points);
  NE := Length(ASel.Entities);
  P0 := -1; P1 := -1; E0 := -1; E1 := -1;
  if NP > 0 then P0 := ASel.Points[0];
  if NP > 1 then P1 := ASel.Points[1];
  if NE > 0 then E0 := ASel.Entities[0];
  if NE > 1 then E1 := ASel.Entities[1];
  case ACommand of
    sccHorizontal, sccVertical:
      if (NP = 0) and (NE = 1) and (KindOf(S, E0) = sekLine) then
      begin
        if ACommand = sccHorizontal then Result := S.Horizontal(E0) else Result := S.Vertical(E0);
      end
      else if (NP = 2) and (NE = 0) then
      begin
        if ACommand = sccHorizontal then Result := S.HorizontalPoints(P0, P1)
        else Result := S.VerticalPoints(P0, P1);
      end;
    sccCoincident:
      if (NP = 2) and (NE = 0) then
        Result := S.Coincident(P0, P1);
    sccParallel, sccPerpendicular:
      if (NP = 0) and (NE = 2) and (KindOf(S, E0) = sekLine) and (KindOf(S, E1) = sekLine) then
      begin
        if ACommand = sccParallel then Result := S.Parallel(E0, E1) else Result := S.Perpendicular(E0, E1);
      end;
    sccEqual:
      if (NP = 0) and (NE = 2) then
      begin
        if (KindOf(S, E0) = sekLine) and (KindOf(S, E1) = sekLine) then
          Result := S.EqualLength(E0, E1)
        else if IsRound(S, E0) and IsRound(S, E1) then
          Result := S.EqualRadius(E0, E1);
      end;
    sccTangent:
      if (NP = 0) and (NE = 2) then
      begin
        if (KindOf(S, E0) = sekLine) and IsRound(S, E1) then
          Result := S.Tangent(E0, E1)
        else if (KindOf(S, E1) = sekLine) and IsRound(S, E0) then
          Result := S.Tangent(E1, E0)
        else if IsRound(S, E0) and IsRound(S, E1) then
          Result := S.TangentCircles(E0, E1);
      end;
    sccConcentric:
      if (NP = 0) and (NE = 2) and IsRound(S, E0) and IsRound(S, E1) then
        Result := S.Concentric(E0, E1);
    sccMidpoint:
      if (NP = 1) and (NE = 1) and (KindOf(S, E0) = sekLine) then
        Result := S.Midpoint(P0, E0);
    sccOnObject:
      if (NP = 1) and (NE = 1) then
      begin
        if KindOf(S, E0) = sekLine then Result := S.PointOnLine(P0, E0)
        else Result := S.PointOnCircle(P0, E0);
      end;
    sccSymmetric:
      if (NP = 2) and (NE = 1) and (KindOf(S, E0) = sekLine) then
        Result := S.Symmetric(P0, P1, E0);
    sccDimension:
      if (NP = 2) and (NE = 0) then
        Result := S.Distance(P0, P1, Hypot(S.PointX(P1) - S.PointX(P0), S.PointY(P1) - S.PointY(P0)))
      else if (NP = 0) and (NE = 1) then
      begin
        case KindOf(S, E0) of
          sekLine: Result := S.Length(E0, Hypot(S.PointX(S.Entities[E0].P2) - S.PointX(S.Entities[E0].P1),
            S.PointY(S.Entities[E0].P2) - S.PointY(S.Entities[E0].P1)));
          sekCircle: Result := S.Diameter(E0, 2 * S.EntityRadius(E0));
          sekArc: Result := S.Radius(E0, S.EntityRadius(E0));
        end;
      end
      else if (NP = 0) and (NE = 2) and (KindOf(S, E0) = sekLine) and (KindOf(S, E1) = sekLine) then
      begin
        { parallel lines: their distance (SolidWorks), else the angle }
        if Abs(Sin(LineAngle(S, E0, E1))) < 1e-6 then
          Result := S.PointLineDistance(S.Entities[E1].P1, E0,
            PointLineDist(S, S.Entities[E1].P1, E0))
        else
          Result := S.Angle(E0, E1, LineAngle(S, E0, E1));
      end
      else if (NP = 1) and (NE = 1) and (KindOf(S, E0) = sekLine) then
        Result := S.PointLineDistance(P0, E0, PointLineDist(S, P0, E0));
    sccDistX, sccDistY:
      if (NE = 0) and (NP in [1, 2]) then
      begin
        if NP = 1 then
        begin
          P1 := P0;                         { one point: measured from the origin }
          P0 := CADOriginPoint(S);
        end;
        if P0 <> P1 then
        begin
          if ACommand = sccDistX then
            Result := S.DistanceX(P0, P1, S.PointX(P1) - S.PointX(P0))
          else
            Result := S.DistanceY(P0, P1, S.PointY(P1) - S.PointY(P0));
        end;
      end;
  end;
  if Result < 0 then
    AError := Format('%s does not fit the selection (%s)', [CommandNames[ACommand],
      CADSelectionText(S, ASel)]);
end;

function Contains(const A: array of Integer; AValue: Integer): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(A) do
    if A[I] = AValue then
      Exit(True);
  Result := False;
end;

function CADApplyCommand(S: TCADSketch; const ASel: TCADSketchSelection;
  ACommand: TCADSketchCommand; out AConstraint: Integer; out AError: string): Boolean;
var
  R: TCADSketchSolveResult;
  Saved: array of Double;
  I: Integer;
begin
  AConstraint := -1;
  if ACommand = sccFix then
  begin
    Result := (Length(ASel.Points) > 0) and (Length(ASel.Entities) = 0);
    if not Result then
    begin
      AError := 'Fix needs points only';
      Exit;
    end;
    for I := 0 to High(ASel.Points) do
      S.FixPoint(ASel.Points[I]);
    AError := '';
    Exit;
  end;
  SetLength(Saved, S.ParamCount);
  for I := 0 to High(Saved) do
    Saved[I] := S.Params[I];
  AConstraint := AddFor(S, ASel, ACommand, AError);
  if AConstraint < 0 then
    Exit(False);
  R := CADSolveSketch(S);
  if R.Status <> cssSolved then
    AError := Format('%s conflicts with other constraints: removed', [CommandNames[ACommand]])
  else if Contains(R.Redundant, AConstraint) then
    AError := Format('%s is already implied by other constraints: removed', [CommandNames[ACommand]]);
  Result := AError = '';
  if not Result then
  begin
    S.RemoveConstraint(AConstraint);
    S.SetParams(Saved);
    AConstraint := -1;
  end;
end;

function CADSetDimension(S: TCADSketch; AConstraint: Integer; AValue: Double;
  out AError: string): Boolean;
var
  C: TCADSketchConstraint;
  Saved: array of Double;
  I: Integer;
  Old: Double;
  R: TCADSketchSolveResult;
begin
  AError := '';
  C := S.Constraints[AConstraint];
  Result := CADIsDimension(C.Kind) and C.Active;
  if not Result then
  begin
    AError := 'not a dimension';
    Exit;
  end;
  if (C.Kind <> sckAngle) and (AValue <= 0) then
  begin
    AError := 'a size must be positive';
    Exit(False);
  end;
  if (C.Kind = sckAngle) and ((AValue <= 0) or (AValue >= 180)) then
  begin
    AError := 'an angle between the two sides: more than 0, less than 180';
    Exit(False);
  end;
  SetLength(Saved, S.ParamCount);
  for I := 0 to High(Saved) do
    Saved[I] := S.Params[I];
  Old := C.Value;
  if C.Kind = sckAngle then
  begin
    { the typed value is the angle between the sides; the constraint keeps
      the directed angle of the line directions (same turn direction) }
    if not AngleSameSide(S, C) then
      AValue := 180 - AValue;
    if C.Value < 0 then
      AValue := -AValue;
    S.SetConstraintValue(AConstraint, DegToRad(AValue));
  end
  else
    S.SetConstraintValue(AConstraint, AValue);
  R := CADSolveSketch(S);
  Result := R.Status = cssSolved;
  if not Result then
  begin
    AError := 'the sketch cannot take that value: reverted';
    S.SetConstraintValue(AConstraint, Old);
    S.SetParams(Saved);
  end;
end;

end.
