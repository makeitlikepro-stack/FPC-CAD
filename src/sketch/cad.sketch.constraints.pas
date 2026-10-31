unit CAD.Sketch.Constraints;
{$mode objfpc}{$H+}

{ ROLE:      the equations: residuals of every constraint kind (0 when the
             constraint holds) and the list of numbers each one depends on.
  CALLED BY: CAD.Sketch.Solver (Jacobian by central differences per
             constraint), tests/sketch.
  CALLS:     CAD.Sketch.Model.
  THREADS:   pure functions over a given number array; any thread.
  SPEED:     a constraint touches at most 8 numbers and gives 1-2 rows, so a
             numeric derivative costs 2 x 8 tiny evaluations; no allocation.

  Residual units: mm for distances, sin/cos/radians for directions. Every
  direction residual is normalised by the line lengths, so a long and a short
  line converge alike. }

interface

uses
  Math, CAD.Sketch.Model;

const
  CAD_SK_MAX_ROWS = 2;
  CAD_SK_MAX_PARAMS = 8;

type
  TCADSkDoubleArray = array[0..MaxInt div SizeOf(Double) - 1] of Double;
  PCADSkDoubleArray = ^TCADSkDoubleArray;

  TCADSkResidual = array[0..CAD_SK_MAX_ROWS - 1] of Double;

  TCADSkParamList = record
    Count: Integer;
    Idx: array[0..CAD_SK_MAX_PARAMS - 1] of Integer;
  end;

{ Equations (rows) of a constraint kind. }
function CADConstraintRows(AKind: TCADSketchConstraintKind): Integer;
{ Numbers (param indices) the constraint depends on, without duplicates. }
procedure CADConstraintParams(S: TCADSketch; const C: TCADSketchConstraint;
  out L: TCADSkParamList);
{ Residuals for the numbers X (X[i] = param i). Unused rows are 0. }
procedure CADConstraintResiduals(S: TCADSketch; const C: TCADSketchConstraint;
  X: PCADSkDoubleArray; out R: TCADSkResidual);

implementation

const
  TINY = 1e-12;

function CADConstraintRows(AKind: TCADSketchConstraintKind): Integer;
begin
  case AKind of
    sckCoincident, sckCollinear, sckConcentric, sckMidpoint, sckSymmetric:
      Result := 2;
  else
    Result := 1;
  end;
end;

{ ---- parameter lists ---- }

procedure AddIdx(var L: TCADSkParamList; AIdx: Integer);
var
  I: Integer;
begin
  if AIdx < 0 then
    Exit;
  for I := 0 to L.Count - 1 do
    if L.Idx[I] = AIdx then
      Exit;
  L.Idx[L.Count] := AIdx;
  Inc(L.Count);
end;

procedure AddPointIdx(S: TCADSketch; var L: TCADSkParamList; APoint: Integer);
begin
  AddIdx(L, S.Points[APoint].XParam);
  AddIdx(L, S.Points[APoint].YParam);
end;

procedure AddEntityIdx(S: TCADSketch; var L: TCADSkParamList; AEntity: Integer);
var
  E: TCADSketchEntity;
begin
  E := S.Entities[AEntity];
  case E.Kind of
    sekLine:
      begin
        AddPointIdx(S, L, E.P1);
        AddPointIdx(S, L, E.P2);
      end;
    sekCircle:
      begin
        AddPointIdx(S, L, E.Center);
        AddIdx(L, E.RadiusParam);
      end;
    sekArc:
      begin
        AddPointIdx(S, L, E.Center);
        AddPointIdx(S, L, E.P1);     { radius = |start - center| }
      end;
  end;
end;

procedure CADConstraintParams(S: TCADSketch; const C: TCADSketchConstraint;
  out L: TCADSkParamList);
begin
  L.Count := 0;
  case C.Kind of
    sckCoincident, sckHorizontalPts, sckVerticalPts, sckDistance,
    sckDistanceX, sckDistanceY:
      begin
        AddPointIdx(S, L, C.A);
        AddPointIdx(S, L, C.B);
      end;
    sckHorizontal, sckVertical, sckLength, sckRadius, sckDiameter:
      AddEntityIdx(S, L, C.A);
    sckPointOnLine, sckPointOnCircle, sckPointLineDist, sckMidpoint:
      begin
        AddPointIdx(S, L, C.A);
        AddEntityIdx(S, L, C.B);
      end;
    sckParallel, sckPerpendicular, sckAngle, sckCollinear, sckEqualLength,
    sckEqualRadius, sckTangentLine, sckTangentCircles, sckConcentric:
      begin
        AddEntityIdx(S, L, C.A);
        AddEntityIdx(S, L, C.B);
      end;
    sckSymmetric:
      begin
        AddPointIdx(S, L, C.A);
        AddPointIdx(S, L, C.B);
        AddEntityIdx(S, L, C.C);
      end;
    sckArcRule:
      begin
        AddEntityIdx(S, L, C.A);
        AddPointIdx(S, L, S.Entities[C.A].P2);
      end;
  end;
end;

{ ---- geometry helpers on the number array ---- }

type
  TV2 = record
    X, Y: Double;
  end;

function Pt(S: TCADSketch; X: PCADSkDoubleArray; APoint: Integer): TV2;
var
  P: TCADSketchPoint;
begin
  P := S.Points[APoint];
  Result.X := X^[P.XParam];
  Result.Y := X^[P.YParam];
end;

function Sub(const A, B: TV2): TV2;
begin
  Result.X := A.X - B.X;
  Result.Y := A.Y - B.Y;
end;

function Len(const A: TV2): Double;
begin
  Result := Sqrt(A.X * A.X + A.Y * A.Y);
end;

function Cross(const A, B: TV2): Double;
begin
  Result := A.X * B.Y - A.Y * B.X;
end;

function Dot(const A, B: TV2): Double;
begin
  Result := A.X * B.X + A.Y * B.Y;
end;

procedure LineOf(S: TCADSketch; X: PCADSkDoubleArray; ALine: Integer; out A, D: TV2);
var
  E: TCADSketchEntity;
begin
  E := S.Entities[ALine];
  A := Pt(S, X, E.P1);
  D := Sub(Pt(S, X, E.P2), A);
end;

function CenterOf(S: TCADSketch; X: PCADSkDoubleArray; AEntity: Integer): TV2;
begin
  Result := Pt(S, X, S.Entities[AEntity].Center);
end;

function RadiusOf(S: TCADSketch; X: PCADSkDoubleArray; AEntity: Integer): Double;
var
  E: TCADSketchEntity;
begin
  E := S.Entities[AEntity];
  if E.Kind = sekCircle then
    Result := X^[E.RadiusParam]
  else
    Result := Len(Sub(Pt(S, X, E.P1), Pt(S, X, E.Center)));
end;

function SafeLen(const A: TV2): Double;
begin
  Result := Max(Len(A), TINY);
end;

function WrapPi(A: Double): Double;
begin
  Result := A - 2 * Pi * Floor((A + Pi) / (2 * Pi));
end;

{ ---- residuals ---- }

procedure CADConstraintResiduals(S: TCADSketch; const C: TCADSketchConstraint;
  X: PCADSkDoubleArray; out R: TCADSkResidual);
var
  PA, PB, A1, D1, A2, D2, M: TV2;
  R1, R2: Double;
  E: TCADSketchEntity;
begin
  R[0] := 0;
  R[1] := 0;
  case C.Kind of
    sckCoincident:
      begin
        PA := Pt(S, X, C.A);
        PB := Pt(S, X, C.B);
        R[0] := PA.X - PB.X;
        R[1] := PA.Y - PB.Y;
      end;
    sckHorizontal:
      begin
        LineOf(S, X, C.A, A1, D1);
        R[0] := D1.Y;
      end;
    sckVertical:
      begin
        LineOf(S, X, C.A, A1, D1);
        R[0] := D1.X;
      end;
    sckHorizontalPts:
      R[0] := Pt(S, X, C.B).Y - Pt(S, X, C.A).Y;
    sckVerticalPts:
      R[0] := Pt(S, X, C.B).X - Pt(S, X, C.A).X;
    sckDistance:
      R[0] := Len(Sub(Pt(S, X, C.B), Pt(S, X, C.A))) - C.Value;
    sckDistanceX:
      R[0] := Pt(S, X, C.B).X - Pt(S, X, C.A).X - C.Value;
    sckDistanceY:
      R[0] := Pt(S, X, C.B).Y - Pt(S, X, C.A).Y - C.Value;
    sckLength:
      begin
        LineOf(S, X, C.A, A1, D1);
        R[0] := Len(D1) - C.Value;
      end;
    sckPointOnLine:
      begin
        LineOf(S, X, C.B, A1, D1);
        R[0] := Cross(D1, Sub(Pt(S, X, C.A), A1)) / SafeLen(D1);
      end;
    sckPointOnCircle:
      R[0] := Len(Sub(Pt(S, X, C.A), CenterOf(S, X, C.B))) - RadiusOf(S, X, C.B);
    sckPointLineDist:
      begin
        LineOf(S, X, C.B, A1, D1);
        R[0] := Abs(Cross(D1, Sub(Pt(S, X, C.A), A1))) / SafeLen(D1) - C.Value;
      end;
    sckParallel, sckPerpendicular, sckAngle, sckCollinear:
      begin
        LineOf(S, X, C.A, A1, D1);
        LineOf(S, X, C.B, A2, D2);
        R1 := SafeLen(D1) * SafeLen(D2);
        case C.Kind of
          sckParallel: R[0] := Cross(D1, D2) / R1;
          sckPerpendicular: R[0] := Dot(D1, D2) / R1;
          sckAngle: R[0] := WrapPi(ArcTan2(Cross(D1, D2), Dot(D1, D2)) - C.Value);
          sckCollinear:
            begin
              R[0] := Cross(D1, D2) / R1;
              R[1] := Cross(D1, Sub(A2, A1)) / SafeLen(D1);
            end;
        end;
      end;
    sckEqualLength:
      begin
        LineOf(S, X, C.A, A1, D1);
        LineOf(S, X, C.B, A2, D2);
        R[0] := Len(D1) - Len(D2);
      end;
    sckEqualRadius:
      R[0] := RadiusOf(S, X, C.A) - RadiusOf(S, X, C.B);
    sckRadius:
      R[0] := RadiusOf(S, X, C.A) - C.Value;
    sckDiameter:
      R[0] := 2 * RadiusOf(S, X, C.A) - C.Value;
    sckTangentLine:
      begin
        LineOf(S, X, C.A, A1, D1);
        R[0] := Cross(D1, Sub(CenterOf(S, X, C.B), A1)) / SafeLen(D1) -
          C.Side * RadiusOf(S, X, C.B);
      end;
    sckTangentCircles:
      begin
        R1 := RadiusOf(S, X, C.A);
        R2 := RadiusOf(S, X, C.B);
        M := Sub(CenterOf(S, X, C.B), CenterOf(S, X, C.A));
        if C.Side > 0 then
          R[0] := Len(M) - (R1 + R2)
        else
          R[0] := Len(M) - Abs(R1 - R2);
      end;
    sckConcentric:
      begin
        M := Sub(CenterOf(S, X, C.A), CenterOf(S, X, C.B));
        R[0] := M.X;
        R[1] := M.Y;
      end;
    sckMidpoint:
      begin
        LineOf(S, X, C.B, A1, D1);
        PA := Pt(S, X, C.A);
        R[0] := PA.X - (A1.X + 0.5 * D1.X);
        R[1] := PA.Y - (A1.Y + 0.5 * D1.Y);
      end;
    sckSymmetric:
      begin
        LineOf(S, X, C.C, A1, D1);
        PA := Pt(S, X, C.A);
        PB := Pt(S, X, C.B);
        M.X := 0.5 * (PA.X + PB.X);
        M.Y := 0.5 * (PA.Y + PB.Y);
        R[0] := Cross(D1, Sub(M, A1)) / SafeLen(D1);      { midpoint on the axis }
        R[1] := Dot(D1, Sub(PB, PA)) / SafeLen(D1);       { A-B across the axis }
      end;
    sckArcRule:
      begin
        E := S.Entities[C.A];
        M := CenterOf(S, X, C.A);
        R[0] := Len(Sub(Pt(S, X, E.P2), M)) - Len(Sub(Pt(S, X, E.P1), M));
      end;
  end;
end;

end.
