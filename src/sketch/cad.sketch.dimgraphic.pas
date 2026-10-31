unit CAD.Sketch.DimGraphic;
{$mode objfpc}{$H+}

{ ROLE:      the drawing of a dimension, drafting style (SolidWorks): the
             extension lines, the dimension line with an arrow at each end,
             and where its value text goes. Sizes are given in screen pixels
             and turned into sketch mm with the current zoom, so a
             dimension looks the same at every zoom.
               length / distance   parallel dimension line on the outer side
                                   (away from the sketch centre)
               distance X / Y      horizontal line above / vertical line
                                   right of the two points
               radius              leader from the centre through the circle
                                   (45 deg, an arc: its middle), arrow on it
               diameter            line across the circle, arrows both ends
               point-line distance perpendicular line, arrows both ends
             Angles keep the old text-only marker (False).
  CALLED BY: CAD.App.SketchMode (dimension layer, chip places).
  CALLS:     CAD.Sketch.Model, CAD.Sketch.Commands (CADIsDimension).
  THREADS:   any (pure).
  SPEED:     a few segments per dimension. }

interface

uses
  Math, CAD.Sketch.Model, CAD.Sketch.Commands;

type
  TCADDimSegment = record
    X1, Y1, X2, Y2: Double;
  end;

  TCADDimGraphic = record
    Segments: array of TCADDimSegment;
    TextX, TextY: Double;      { centre of the value text }
  end;

const
  CAD_DIM_OFFSET_PX = 30;      { dimension line from the geometry }
  CAD_DIM_GAP_PX = 4;          { extension line starts this far from the geometry }
  CAD_DIM_OVER_PX = 6;         { extension line passes the dimension line }
  CAD_DIM_ARROW_PX = 10;       { arrow length }
  CAD_DIM_ARROW_HALF_PX = 3.5; { arrow half width }
  CAD_DIM_TEXT_PX = 11;        { text centre from the dimension line }
  CAD_DIM_LEADER_PX = 26;      { radius / diameter leader past the circle }

{ The graphic of constraint AIndex; AMMPerPixel = sketch mm per screen pixel.
  False for constraints that are not drawn this way (angle, inactive, not a
  dimension, degenerate geometry). }
function CADDimensionGraphic(S: TCADSketch; AIndex: Integer; AMMPerPixel: Double;
  out G: TCADDimGraphic): Boolean;

implementation

procedure Seg(var G: TCADDimGraphic; X1, Y1, X2, Y2: Double);
var
  N: Integer;
begin
  N := Length(G.Segments);
  SetLength(G.Segments, N + 1);
  G.Segments[N].X1 := X1;
  G.Segments[N].Y1 := Y1;
  G.Segments[N].X2 := X2;
  G.Segments[N].Y2 := Y2;
end;

{ Arrow with its tip at (TX, TY) pointing along unit (UX, UY). }
procedure Arrow(var G: TCADDimGraphic; TX, TY, UX, UY, MM: Double);
var
  BX, BY, NX, NY: Double;
begin
  BX := TX - UX * CAD_DIM_ARROW_PX * MM;
  BY := TY - UY * CAD_DIM_ARROW_PX * MM;
  NX := -UY * CAD_DIM_ARROW_HALF_PX * MM;
  NY := UX * CAD_DIM_ARROW_HALF_PX * MM;
  Seg(G, TX, TY, BX + NX, BY + NY);
  Seg(G, TX, TY, BX - NX, BY - NY);
  Seg(G, BX + NX, BY + NY, BX - NX, BY - NY);
end;

{ Dimension line between (AX, AY) and (BX, BY), arrows pointing outwards. }
procedure DimLine(var G: TCADDimGraphic; AX, AY, BX, BY, MM: Double);
var
  L, UX, UY: Double;
begin
  L := Hypot(BX - AX, BY - AY);
  Seg(G, AX, AY, BX, BY);
  if L < 1e-12 then
    Exit;
  UX := (BX - AX) / L;
  UY := (BY - AY) / L;
  Arrow(G, BX, BY, UX, UY, MM);
  Arrow(G, AX, AY, -UX, -UY, MM);
end;

procedure SketchCentre(S: TCADSketch; out CX, CY: Double);
var
  I: Integer;
  X0, Y0, X1, Y1: Double;
begin
  CX := 0;
  CY := 0;
  if S.PointCount = 0 then
    Exit;
  X0 := S.PointX(0);
  X1 := X0;
  Y0 := S.PointY(0);
  Y1 := Y0;
  for I := 1 to S.PointCount - 1 do
  begin
    X0 := Min(X0, S.PointX(I));
    X1 := Max(X1, S.PointX(I));
    Y0 := Min(Y0, S.PointY(I));
    Y1 := Max(Y1, S.PointY(I));
  end;
  CX := 0.5 * (X0 + X1);
  CY := 0.5 * (Y0 + Y1);
end;

{ Aligned dimension between two points on the side away from the centre. }
function Aligned(S: TCADSketch; PA, PB: Integer; MM: Double; var G: TCADDimGraphic): Boolean;
var
  AX, AY, BX, BY, L, NX, NY, CX, CY, Off: Double;
begin
  AX := S.PointX(PA);
  AY := S.PointY(PA);
  BX := S.PointX(PB);
  BY := S.PointY(PB);
  L := Hypot(BX - AX, BY - AY);
  Result := L > 1e-9;
  if not Result then
    Exit;
  NX := -(BY - AY) / L;
  NY := (BX - AX) / L;
  SketchCentre(S, CX, CY);
  if (0.5 * (AX + BX) - CX) * NX + (0.5 * (AY + BY) - CY) * NY < 0 then
  begin
    NX := -NX;
    NY := -NY;
  end;
  Off := CAD_DIM_OFFSET_PX * MM;
  Seg(G, AX + NX * CAD_DIM_GAP_PX * MM, AY + NY * CAD_DIM_GAP_PX * MM,
    AX + NX * (Off + CAD_DIM_OVER_PX * MM), AY + NY * (Off + CAD_DIM_OVER_PX * MM));
  Seg(G, BX + NX * CAD_DIM_GAP_PX * MM, BY + NY * CAD_DIM_GAP_PX * MM,
    BX + NX * (Off + CAD_DIM_OVER_PX * MM), BY + NY * (Off + CAD_DIM_OVER_PX * MM));
  DimLine(G, AX + NX * Off, AY + NY * Off, BX + NX * Off, BY + NY * Off, MM);
  G.TextX := 0.5 * (AX + BX) + NX * (Off + CAD_DIM_TEXT_PX * MM);
  G.TextY := 0.5 * (AY + BY) + NY * (Off + CAD_DIM_TEXT_PX * MM);
end;

{ Horizontal (AHorizontal) or vertical dimension between two points. }
function AxisDim(S: TCADSketch; PA, PB: Integer; AHorizontal: Boolean; MM: Double;
  var G: TCADDimGraphic): Boolean;
var
  AX, AY, BX, BY, Lvl, Off, Gap, Over: Double;
begin
  AX := S.PointX(PA);
  AY := S.PointY(PA);
  BX := S.PointX(PB);
  BY := S.PointY(PB);
  Off := CAD_DIM_OFFSET_PX * MM;
  Gap := CAD_DIM_GAP_PX * MM;
  Over := CAD_DIM_OVER_PX * MM;
  if AHorizontal then
  begin
    Result := Abs(BX - AX) > 1e-9;
    if not Result then
      Exit;
    Lvl := Max(AY, BY) + Off;              { above both points }
    Seg(G, AX, AY + Gap, AX, Lvl + Over);
    Seg(G, BX, BY + Gap, BX, Lvl + Over);
    DimLine(G, AX, Lvl, BX, Lvl, MM);
    G.TextX := 0.5 * (AX + BX);
    G.TextY := Lvl + CAD_DIM_TEXT_PX * MM;
  end
  else
  begin
    Result := Abs(BY - AY) > 1e-9;
    if not Result then
      Exit;
    Lvl := Max(AX, BX) + Off;              { right of both points }
    Seg(G, AX + Gap, AY, Lvl + Over, AY);
    Seg(G, BX + Gap, BY, Lvl + Over, BY);
    DimLine(G, Lvl, AY, Lvl, BY, MM);
    G.TextX := Lvl + CAD_DIM_TEXT_PX * MM * 1.6;
    G.TextY := 0.5 * (AY + BY);
  end;
end;

{ Direction of the leader: 45 deg on a circle, the middle of an arc. }
procedure LeaderDir(S: TCADSketch; AEntity: Integer; out UX, UY: Double);
var
  E: TCADSketchEntity;
  CX, CY, A1, A2, Sweep, A: Double;
begin
  E := S.Entities[AEntity];
  UX := Sqrt(0.5);
  UY := Sqrt(0.5);
  if E.Kind <> sekArc then
    Exit;
  CX := S.PointX(E.Center);
  CY := S.PointY(E.Center);
  A1 := ArcTan2(S.PointY(E.P1) - CY, S.PointX(E.P1) - CX);
  A2 := ArcTan2(S.PointY(E.P2) - CY, S.PointX(E.P2) - CX);
  Sweep := A2 - A1;
  while Sweep <= 0 do
    Sweep := Sweep + 2 * Pi;               { arcs run counter-clockwise }
  A := A1 + 0.5 * Sweep;
  UX := Cos(A);
  UY := Sin(A);
end;

function RadialDim(S: TCADSketch; AEntity: Integer; ADiameter: Boolean; MM: Double;
  var G: TCADDimGraphic): Boolean;
var
  E: TCADSketchEntity;
  CX, CY, R, UX, UY, Lead: Double;
begin
  E := S.Entities[AEntity];
  Result := E.Kind in [sekCircle, sekArc];
  if not Result then
    Exit;
  CX := S.PointX(E.Center);
  CY := S.PointY(E.Center);
  R := S.EntityRadius(AEntity);
  Result := R > 1e-9;
  if not Result then
    Exit;
  LeaderDir(S, AEntity, UX, UY);
  Lead := CAD_DIM_LEADER_PX * MM;
  if ADiameter then
  begin
    DimLine(G, CX - UX * R, CY - UY * R, CX + UX * R, CY + UY * R, MM);
    Seg(G, CX + UX * R, CY + UY * R, CX + UX * (R + Lead), CY + UY * (R + Lead));
  end
  else
  begin
    Seg(G, CX, CY, CX + UX * (R + Lead), CY + UY * (R + Lead));
    Arrow(G, CX + UX * R, CY + UY * R, UX, UY, MM);
  end;
  G.TextX := CX + UX * (R + Lead + CAD_DIM_TEXT_PX * MM);
  G.TextY := CY + UY * (R + Lead + CAD_DIM_TEXT_PX * MM);
end;

function PointLineDim(S: TCADSketch; APoint, ALine: Integer; MM: Double;
  var G: TCADDimGraphic): Boolean;
var
  E: TCADSketchEntity;
  PX, PY, AX, AY, DX, DY, L, T, FX, FY: Double;
begin
  E := S.Entities[ALine];
  PX := S.PointX(APoint);
  PY := S.PointY(APoint);
  AX := S.PointX(E.P1);
  AY := S.PointY(E.P1);
  DX := S.PointX(E.P2) - AX;
  DY := S.PointY(E.P2) - AY;
  L := DX * DX + DY * DY;
  Result := L > 1e-18;
  if not Result then
    Exit;
  T := ((PX - AX) * DX + (PY - AY) * DY) / L;
  FX := AX + T * DX;
  FY := AY + T * DY;
  Result := Hypot(FX - PX, FY - PY) > 1e-9;
  if not Result then
    Exit;
  DimLine(G, FX, FY, PX, PY, MM);
  { text beside the middle, along the line direction }
  G.TextX := 0.5 * (PX + FX) + DX / Sqrt(L) * CAD_DIM_TEXT_PX * MM;
  G.TextY := 0.5 * (PY + FY) + DY / Sqrt(L) * CAD_DIM_TEXT_PX * MM;
end;

function CADDimensionGraphic(S: TCADSketch; AIndex: Integer; AMMPerPixel: Double;
  out G: TCADDimGraphic): Boolean;
var
  C: TCADSketchConstraint;
  E: TCADSketchEntity;
begin
  G.Segments := nil;
  G.TextX := 0;
  G.TextY := 0;
  Result := False;
  if (AIndex < 0) or (AIndex >= S.ConstraintCount) or (AMMPerPixel <= 0) then
    Exit;
  C := S.Constraints[AIndex];
  if not (C.Active and CADIsDimension(C.Kind)) then
    Exit;
  case C.Kind of
    sckLength:
      begin
        E := S.Entities[C.A];
        Result := (E.Kind = sekLine) and Aligned(S, E.P1, E.P2, AMMPerPixel, G);
      end;
    sckDistance: Result := Aligned(S, C.A, C.B, AMMPerPixel, G);
    sckDistanceX: Result := AxisDim(S, C.A, C.B, True, AMMPerPixel, G);
    sckDistanceY: Result := AxisDim(S, C.A, C.B, False, AMMPerPixel, G);
    sckRadius: Result := RadialDim(S, C.A, False, AMMPerPixel, G);
    sckDiameter: Result := RadialDim(S, C.A, True, AMMPerPixel, G);
    sckPointLineDist: Result := PointLineDim(S, C.A, C.B, AMMPerPixel, G);
  end;
  if not Result then
    G.Segments := nil;
end;

end.
