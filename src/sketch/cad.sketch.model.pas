unit CAD.Sketch.Model;
{$mode objfpc}{$H+}

{ ROLE:      2D sketch data: one flat array of numbers (point x/y, circle
             radii) that the solver changes, entities (line, circle, arc)
             made of point indices, and constraints (kind, references, value).
  CALLED BY: CAD.Sketch.Constraints, CAD.Sketch.Solver, sketch features and
             the sketch editor (later), tests/sketch.
  CALLS:     Math only. No OCCT, no GL.
  THREADS:   one sketch per thread; no globals.
  SPEED:     everything is index based (no objects per point), so a solve
             iteration reads plain arrays.

  Coordinates are sketch-plane 2D, mm; angles are radians. An arc is
  counter-clockwise from Start to End around Center; its radius is
  |Start - Center| and an automatic constraint keeps |End - Center| equal.
  Points shared by two entities are the same point index (a rectangle has 4
  points); separate points are joined with a Coincident constraint. }

interface

uses
  SysUtils, Math;

type
  TCADSketchEntityKind = (sekLine, sekCircle, sekArc);

  TCADSketchPoint = record
    XParam, YParam: Integer;    { indices into Params }
  end;

  TCADSketchEntity = record
    Kind: TCADSketchEntityKind;
    P1, P2: Integer;            { line: ends; arc: start, end; circle: -1 }
    Center: Integer;            { circle, arc; line: -1 }
    RadiusParam: Integer;       { circle only; arc and line: -1 }
    Construction: Boolean;      { not part of a profile }
  end;

  TCADSketchConstraintKind = (
    sckCoincident,      { A, B points }
    sckHorizontal,      { A line }
    sckVertical,        { A line }
    sckHorizontalPts,   { A, B points: same Y }
    sckVerticalPts,     { A, B points: same X }
    sckDistance,        { A, B points; Value }
    sckDistanceX,       { A, B points; Value = xB - xA }
    sckDistanceY,       { A, B points; Value = yB - yA }
    sckLength,          { A line; Value }
    sckPointOnLine,     { A point, B line (infinite) }
    sckPointOnCircle,   { A point, B circle or arc }
    sckPointLineDist,   { A point, B line; Value (unsigned) }
    sckParallel,        { A, B lines }
    sckPerpendicular,   { A, B lines }
    sckAngle,           { A, B lines; Value = angle from A to B (CCW) }
    sckCollinear,       { A, B lines }
    sckEqualLength,     { A, B lines }
    sckEqualRadius,     { A, B circles or arcs }
    sckRadius,          { A circle or arc; Value }
    sckDiameter,        { A circle or arc; Value }
    sckTangentLine,     { A line, B circle or arc; Side = +1/-1 (which side) }
    sckTangentCircles,  { A, B circles or arcs; Side = +1 outside, -1 inside }
    sckConcentric,      { A, B circles or arcs }
    sckMidpoint,        { A point, B line }
    sckSymmetric,       { A, B points, C line (mirror axis) }
    sckArcRule          { A arc (automatic: |End - Center| = |Start - Center|) }
  );

  TCADSketchConstraint = record
    Kind: TCADSketchConstraintKind;
    A, B, C: Integer;
    Value: Double;
    Side: Double;               { tangency side, chosen from the geometry when added }
    Active: Boolean;            { False = removed (indices of the others stay) }
  end;

  TCADSketchPlane = record
    Origin, XDir, YDir, Normal: array[0..2] of Double;
  end;

  TCADSketch = class
  private
    FParams: array of Double;
    FFixed: array of Boolean;
    FParamCount: Integer;
    FPoints: array of TCADSketchPoint;
    FPointCount: Integer;
    FEntities: array of TCADSketchEntity;
    FEntityCount: Integer;
    FConstraints: array of TCADSketchConstraint;
    FConstraintCount: Integer;
    FPlane: TCADSketchPlane;
    FRevision: Cardinal;
    function NewParam(AValue: Double): Integer;
    function NewEntity(const E: TCADSketchEntity): Integer;
    function NewConstraint(AKind: TCADSketchConstraintKind; A, B, C: Integer;
      AValue: Double): Integer;
    procedure CheckPoint(AIndex: Integer);
    procedure CheckEntity(AIndex: Integer; AKinds: array of TCADSketchEntityKind);
    function GetParam(AIndex: Integer): Double;
    procedure SetParam(AIndex: Integer; AValue: Double);
    function GetFixed(AIndex: Integer): Boolean;
    function GetPoint(AIndex: Integer): TCADSketchPoint;
    function GetEntity(AIndex: Integer): TCADSketchEntity;
    function GetConstraint(AIndex: Integer): TCADSketchConstraint;
  public
    constructor Create;
    { --- geometry --- }
    function AddPoint(X, Y: Double): Integer;
    function AddLine(AP1, AP2: Integer): Integer;
    { Line with two new points. }
    function AddLineXY(X1, Y1, X2, Y2: Double): Integer;
    function AddCircle(ACenter: Integer; ARadius: Double): Integer;
    { Adds the arc rule constraint as well (AAutoRule = False: only for
      loading, where the saved constraint list already has it). }
    function AddArc(ACenter, AStart, AEnd: Integer; AAutoRule: Boolean = True): Integer;
    procedure SetConstruction(AEntity: Integer; AValue: Boolean);
    procedure FixPoint(APoint: Integer; AFixed: Boolean = True);
    procedure MovePoint(APoint: Integer; X, Y: Double);
    function PointX(APoint: Integer): Double;
    function PointY(APoint: Integer): Double;
    { Circle: its radius; arc: |Start - Center|. }
    function EntityRadius(AEntity: Integer): Double;
    { --- constraints (return the constraint index) --- }
    function Coincident(APa, APb: Integer): Integer;
    function Horizontal(ALine: Integer): Integer;
    function Vertical(ALine: Integer): Integer;
    function HorizontalPoints(APa, APb: Integer): Integer;
    function VerticalPoints(APa, APb: Integer): Integer;
    function Distance(APa, APb: Integer; AValue: Double): Integer;
    function DistanceX(APa, APb: Integer; AValue: Double): Integer;
    function DistanceY(APa, APb: Integer; AValue: Double): Integer;
    function Length(ALine: Integer; AValue: Double): Integer;
    function PointOnLine(APoint, ALine: Integer): Integer;
    function PointOnCircle(APoint, ACircle: Integer): Integer;
    function PointLineDistance(APoint, ALine: Integer; AValue: Double): Integer;
    function Parallel(ALine1, ALine2: Integer): Integer;
    function Perpendicular(ALine1, ALine2: Integer): Integer;
    function Angle(ALine1, ALine2: Integer; ARadians: Double): Integer;
    function Collinear(ALine1, ALine2: Integer): Integer;
    function EqualLength(ALine1, ALine2: Integer): Integer;
    function EqualRadius(ACircle1, ACircle2: Integer): Integer;
    function Radius(ACircle: Integer; AValue: Double): Integer;
    function Diameter(ACircle: Integer; AValue: Double): Integer;
    function Tangent(ALine, ACircle: Integer): Integer;
    function TangentCircles(ACircle1, ACircle2: Integer): Integer;
    function Concentric(ACircle1, ACircle2: Integer): Integer;
    function Midpoint(APoint, ALine: Integer): Integer;
    function Symmetric(APa, APb, AAxisLine: Integer): Integer;
    { Loading: appends a constraint as saved (kind, references, value, side,
      active), after checking that its references exist. }
    function AddConstraintRaw(const C: TCADSketchConstraint): Integer;
    procedure SetConstraintValue(AIndex: Integer; AValue: Double);
    procedure RemoveConstraint(AIndex: Integer);
    { --- plane --- }
    procedure SetPlane(const AOrigin, AXDir, ANormal: array of Double);
    { Sketch 2D -> model 3D. }
    procedure ToModel(X, Y: Double; out AX, AY, AZ: Double);
    { --- raw access for the solver --- }
    procedure SetParams(const AValues: array of Double);
    property ParamCount: Integer read FParamCount;
    property Params[AIndex: Integer]: Double read GetParam write SetParam;
    property Fixed[AIndex: Integer]: Boolean read GetFixed;
    property PointCount: Integer read FPointCount;
    property Points[AIndex: Integer]: TCADSketchPoint read GetPoint;
    property EntityCount: Integer read FEntityCount;
    property Entities[AIndex: Integer]: TCADSketchEntity read GetEntity;
    property ConstraintCount: Integer read FConstraintCount;
    property Constraints[AIndex: Integer]: TCADSketchConstraint read GetConstraint;
    property Plane: TCADSketchPlane read FPlane;
    { Bumped by every change (geometry, constraint, solve). }
    property Revision: Cardinal read FRevision;
  end;

  ECADSketch = class(Exception);

function CADSketchPlaneXY: TCADSketchPlane;

implementation

function CADSketchPlaneXY: TCADSketchPlane;
begin
  Result := Default(TCADSketchPlane);
  Result.XDir[0] := 1;
  Result.YDir[1] := 1;
  Result.Normal[2] := 1;
end;

constructor TCADSketch.Create;
begin
  inherited Create;
  FPlane := CADSketchPlaneXY;
end;

function TCADSketch.NewParam(AValue: Double): Integer;
begin
  if FParamCount >= System.Length(FParams) then
  begin
    SetLength(FParams, Max(32, System.Length(FParams) * 2));
    SetLength(FFixed, System.Length(FParams));
  end;
  FParams[FParamCount] := AValue;
  FFixed[FParamCount] := False;
  Result := FParamCount;
  Inc(FParamCount);
  Inc(FRevision);
end;

function TCADSketch.NewEntity(const E: TCADSketchEntity): Integer;
begin
  if FEntityCount >= System.Length(FEntities) then
    SetLength(FEntities, Max(16, System.Length(FEntities) * 2));
  FEntities[FEntityCount] := E;
  Result := FEntityCount;
  Inc(FEntityCount);
  Inc(FRevision);
end;

function TCADSketch.NewConstraint(AKind: TCADSketchConstraintKind; A, B, C: Integer;
  AValue: Double): Integer;
begin
  if FConstraintCount >= System.Length(FConstraints) then
    SetLength(FConstraints, Max(16, System.Length(FConstraints) * 2));
  FConstraints[FConstraintCount].Kind := AKind;
  FConstraints[FConstraintCount].A := A;
  FConstraints[FConstraintCount].B := B;
  FConstraints[FConstraintCount].C := C;
  FConstraints[FConstraintCount].Value := AValue;
  FConstraints[FConstraintCount].Side := 1;
  FConstraints[FConstraintCount].Active := True;
  Result := FConstraintCount;
  Inc(FConstraintCount);
  Inc(FRevision);
end;

procedure TCADSketch.CheckPoint(AIndex: Integer);
begin
  if (AIndex < 0) or (AIndex >= FPointCount) then
    raise ECADSketch.CreateFmt('sketch: point %d does not exist', [AIndex]);
end;

procedure TCADSketch.CheckEntity(AIndex: Integer; AKinds: array of TCADSketchEntityKind);
var
  K: TCADSketchEntityKind;
begin
  if (AIndex < 0) or (AIndex >= FEntityCount) then
    raise ECADSketch.CreateFmt('sketch: entity %d does not exist', [AIndex]);
  for K in AKinds do
    if FEntities[AIndex].Kind = K then
      Exit;
  raise ECADSketch.CreateFmt('sketch: entity %d has the wrong kind', [AIndex]);
end;

function TCADSketch.GetParam(AIndex: Integer): Double;
begin
  Result := FParams[AIndex];
end;

procedure TCADSketch.SetParam(AIndex: Integer; AValue: Double);
begin
  FParams[AIndex] := AValue;
  Inc(FRevision);
end;

function TCADSketch.GetFixed(AIndex: Integer): Boolean;
begin
  Result := FFixed[AIndex];
end;

function TCADSketch.GetPoint(AIndex: Integer): TCADSketchPoint;
begin
  Result := FPoints[AIndex];
end;

function TCADSketch.GetEntity(AIndex: Integer): TCADSketchEntity;
begin
  Result := FEntities[AIndex];
end;

function TCADSketch.GetConstraint(AIndex: Integer): TCADSketchConstraint;
begin
  Result := FConstraints[AIndex];
end;

function TCADSketch.AddPoint(X, Y: Double): Integer;
begin
  if FPointCount >= System.Length(FPoints) then
    SetLength(FPoints, Max(16, System.Length(FPoints) * 2));
  FPoints[FPointCount].XParam := NewParam(X);
  FPoints[FPointCount].YParam := NewParam(Y);
  Result := FPointCount;
  Inc(FPointCount);
end;

function TCADSketch.AddLine(AP1, AP2: Integer): Integer;
var
  E: TCADSketchEntity;
begin
  CheckPoint(AP1);
  CheckPoint(AP2);
  if AP1 = AP2 then
    raise ECADSketch.Create('sketch: a line needs two different points');
  E := Default(TCADSketchEntity);
  E.Kind := sekLine;
  E.P1 := AP1;
  E.P2 := AP2;
  E.Center := -1;
  E.RadiusParam := -1;
  Result := NewEntity(E);
end;

function TCADSketch.AddLineXY(X1, Y1, X2, Y2: Double): Integer;
begin
  Result := AddLine(AddPoint(X1, Y1), AddPoint(X2, Y2));
end;

function TCADSketch.AddCircle(ACenter: Integer; ARadius: Double): Integer;
var
  E: TCADSketchEntity;
begin
  CheckPoint(ACenter);
  E := Default(TCADSketchEntity);
  E.Kind := sekCircle;
  E.P1 := -1;
  E.P2 := -1;
  E.Center := ACenter;
  E.RadiusParam := NewParam(Abs(ARadius));
  Result := NewEntity(E);
end;

function TCADSketch.AddArc(ACenter, AStart, AEnd: Integer; AAutoRule: Boolean): Integer;
var
  E: TCADSketchEntity;
begin
  CheckPoint(ACenter);
  CheckPoint(AStart);
  CheckPoint(AEnd);
  E := Default(TCADSketchEntity);
  E.Kind := sekArc;
  E.P1 := AStart;
  E.P2 := AEnd;
  E.Center := ACenter;
  E.RadiusParam := -1;
  Result := NewEntity(E);
  if AAutoRule then
    NewConstraint(sckArcRule, Result, -1, -1, 0);
end;

procedure TCADSketch.SetConstruction(AEntity: Integer; AValue: Boolean);
begin
  CheckEntity(AEntity, [sekLine, sekCircle, sekArc]);
  FEntities[AEntity].Construction := AValue;
  Inc(FRevision);
end;

procedure TCADSketch.FixPoint(APoint: Integer; AFixed: Boolean);
begin
  CheckPoint(APoint);
  FFixed[FPoints[APoint].XParam] := AFixed;
  FFixed[FPoints[APoint].YParam] := AFixed;
  Inc(FRevision);
end;

procedure TCADSketch.MovePoint(APoint: Integer; X, Y: Double);
begin
  CheckPoint(APoint);
  FParams[FPoints[APoint].XParam] := X;
  FParams[FPoints[APoint].YParam] := Y;
  Inc(FRevision);
end;

function TCADSketch.PointX(APoint: Integer): Double;
begin
  Result := FParams[FPoints[APoint].XParam];
end;

function TCADSketch.PointY(APoint: Integer): Double;
begin
  Result := FParams[FPoints[APoint].YParam];
end;

function TCADSketch.EntityRadius(AEntity: Integer): Double;
var
  E: TCADSketchEntity;
begin
  E := FEntities[AEntity];
  case E.Kind of
    sekCircle: Result := FParams[E.RadiusParam];
    sekArc: Result := Hypot(PointX(E.P1) - PointX(E.Center), PointY(E.P1) - PointY(E.Center));
  else
    Result := 0;
  end;
end;

function TCADSketch.Coincident(APa, APb: Integer): Integer;
begin
  CheckPoint(APa);
  CheckPoint(APb);
  Result := NewConstraint(sckCoincident, APa, APb, -1, 0);
end;

function TCADSketch.Horizontal(ALine: Integer): Integer;
begin
  CheckEntity(ALine, [sekLine]);
  Result := NewConstraint(sckHorizontal, ALine, -1, -1, 0);
end;

function TCADSketch.Vertical(ALine: Integer): Integer;
begin
  CheckEntity(ALine, [sekLine]);
  Result := NewConstraint(sckVertical, ALine, -1, -1, 0);
end;

function TCADSketch.HorizontalPoints(APa, APb: Integer): Integer;
begin
  CheckPoint(APa);
  CheckPoint(APb);
  Result := NewConstraint(sckHorizontalPts, APa, APb, -1, 0);
end;

function TCADSketch.VerticalPoints(APa, APb: Integer): Integer;
begin
  CheckPoint(APa);
  CheckPoint(APb);
  Result := NewConstraint(sckVerticalPts, APa, APb, -1, 0);
end;

function TCADSketch.Distance(APa, APb: Integer; AValue: Double): Integer;
begin
  CheckPoint(APa);
  CheckPoint(APb);
  Result := NewConstraint(sckDistance, APa, APb, -1, AValue);
end;

function TCADSketch.DistanceX(APa, APb: Integer; AValue: Double): Integer;
begin
  CheckPoint(APa);
  CheckPoint(APb);
  Result := NewConstraint(sckDistanceX, APa, APb, -1, AValue);
end;

function TCADSketch.DistanceY(APa, APb: Integer; AValue: Double): Integer;
begin
  CheckPoint(APa);
  CheckPoint(APb);
  Result := NewConstraint(sckDistanceY, APa, APb, -1, AValue);
end;

function TCADSketch.Length(ALine: Integer; AValue: Double): Integer;
begin
  CheckEntity(ALine, [sekLine]);
  Result := NewConstraint(sckLength, ALine, -1, -1, AValue);
end;

function TCADSketch.PointOnLine(APoint, ALine: Integer): Integer;
begin
  CheckPoint(APoint);
  CheckEntity(ALine, [sekLine]);
  Result := NewConstraint(sckPointOnLine, APoint, ALine, -1, 0);
end;

function TCADSketch.PointOnCircle(APoint, ACircle: Integer): Integer;
begin
  CheckPoint(APoint);
  CheckEntity(ACircle, [sekCircle, sekArc]);
  Result := NewConstraint(sckPointOnCircle, APoint, ACircle, -1, 0);
end;

function TCADSketch.PointLineDistance(APoint, ALine: Integer; AValue: Double): Integer;
begin
  CheckPoint(APoint);
  CheckEntity(ALine, [sekLine]);
  Result := NewConstraint(sckPointLineDist, APoint, ALine, -1, AValue);
end;

function TCADSketch.Parallel(ALine1, ALine2: Integer): Integer;
begin
  CheckEntity(ALine1, [sekLine]);
  CheckEntity(ALine2, [sekLine]);
  Result := NewConstraint(sckParallel, ALine1, ALine2, -1, 0);
end;

function TCADSketch.Perpendicular(ALine1, ALine2: Integer): Integer;
begin
  CheckEntity(ALine1, [sekLine]);
  CheckEntity(ALine2, [sekLine]);
  Result := NewConstraint(sckPerpendicular, ALine1, ALine2, -1, 0);
end;

function TCADSketch.Angle(ALine1, ALine2: Integer; ARadians: Double): Integer;
begin
  CheckEntity(ALine1, [sekLine]);
  CheckEntity(ALine2, [sekLine]);
  Result := NewConstraint(sckAngle, ALine1, ALine2, -1, ARadians);
end;

function TCADSketch.Collinear(ALine1, ALine2: Integer): Integer;
begin
  CheckEntity(ALine1, [sekLine]);
  CheckEntity(ALine2, [sekLine]);
  Result := NewConstraint(sckCollinear, ALine1, ALine2, -1, 0);
end;

function TCADSketch.EqualLength(ALine1, ALine2: Integer): Integer;
begin
  CheckEntity(ALine1, [sekLine]);
  CheckEntity(ALine2, [sekLine]);
  Result := NewConstraint(sckEqualLength, ALine1, ALine2, -1, 0);
end;

function TCADSketch.EqualRadius(ACircle1, ACircle2: Integer): Integer;
begin
  CheckEntity(ACircle1, [sekCircle, sekArc]);
  CheckEntity(ACircle2, [sekCircle, sekArc]);
  Result := NewConstraint(sckEqualRadius, ACircle1, ACircle2, -1, 0);
end;

function TCADSketch.Radius(ACircle: Integer; AValue: Double): Integer;
begin
  CheckEntity(ACircle, [sekCircle, sekArc]);
  Result := NewConstraint(sckRadius, ACircle, -1, -1, AValue);
end;

function TCADSketch.Diameter(ACircle: Integer; AValue: Double): Integer;
begin
  CheckEntity(ACircle, [sekCircle, sekArc]);
  Result := NewConstraint(sckDiameter, ACircle, -1, -1, AValue);
end;

function TCADSketch.Tangent(ALine, ACircle: Integer): Integer;
var
  E: TCADSketchEntity;
  AX, AY, DX, DY, CX, CY: Double;
begin
  CheckEntity(ALine, [sekLine]);
  CheckEntity(ACircle, [sekCircle, sekArc]);
  Result := NewConstraint(sckTangentLine, ALine, ACircle, -1, 0);
  { Keep the side the circle is on now (no flip through the line). }
  E := FEntities[ALine];
  AX := PointX(E.P1);
  AY := PointY(E.P1);
  DX := PointX(E.P2) - AX;
  DY := PointY(E.P2) - AY;
  CX := PointX(FEntities[ACircle].Center) - AX;
  CY := PointY(FEntities[ACircle].Center) - AY;
  if DX * CY - DY * CX < 0 then
    FConstraints[Result].Side := -1;
end;

function TCADSketch.TangentCircles(ACircle1, ACircle2: Integer): Integer;
var
  D, R1, R2: Double;
  C1, C2: Integer;
begin
  CheckEntity(ACircle1, [sekCircle, sekArc]);
  CheckEntity(ACircle2, [sekCircle, sekArc]);
  Result := NewConstraint(sckTangentCircles, ACircle1, ACircle2, -1, 0);
  { Outside (d = r1 + r2) or inside (d = |r1 - r2|): the nearer one now. }
  C1 := FEntities[ACircle1].Center;
  C2 := FEntities[ACircle2].Center;
  D := Hypot(PointX(C2) - PointX(C1), PointY(C2) - PointY(C1));
  R1 := EntityRadius(ACircle1);
  R2 := EntityRadius(ACircle2);
  if Abs(D - Abs(R1 - R2)) < Abs(D - (R1 + R2)) then
    FConstraints[Result].Side := -1;
end;

function TCADSketch.Concentric(ACircle1, ACircle2: Integer): Integer;
begin
  CheckEntity(ACircle1, [sekCircle, sekArc]);
  CheckEntity(ACircle2, [sekCircle, sekArc]);
  Result := NewConstraint(sckConcentric, ACircle1, ACircle2, -1, 0);
end;

function TCADSketch.Midpoint(APoint, ALine: Integer): Integer;
begin
  CheckPoint(APoint);
  CheckEntity(ALine, [sekLine]);
  Result := NewConstraint(sckMidpoint, APoint, ALine, -1, 0);
end;

function TCADSketch.Symmetric(APa, APb, AAxisLine: Integer): Integer;
begin
  CheckPoint(APa);
  CheckPoint(APb);
  CheckEntity(AAxisLine, [sekLine]);
  Result := NewConstraint(sckSymmetric, APa, APb, AAxisLine, 0);
end;

function TCADSketch.AddConstraintRaw(const C: TCADSketchConstraint): Integer;

  procedure Ref(AIndex: Integer; APoint: Boolean);
  begin
    if APoint then
      CheckPoint(AIndex)
    else
      CheckEntity(AIndex, [sekLine, sekCircle, sekArc]);
  end;

begin
  case C.Kind of
    sckCoincident, sckHorizontalPts, sckVerticalPts, sckDistance, sckDistanceX, sckDistanceY:
      begin
        Ref(C.A, True);
        Ref(C.B, True);
      end;
    sckHorizontal, sckVertical, sckLength, sckRadius, sckDiameter, sckArcRule:
      Ref(C.A, False);
    sckPointOnLine, sckPointOnCircle, sckPointLineDist, sckMidpoint:
      begin
        Ref(C.A, True);
        Ref(C.B, False);
      end;
    sckSymmetric:
      begin
        Ref(C.A, True);
        Ref(C.B, True);
        Ref(C.C, False);
      end;
  else
    begin
      Ref(C.A, False);
      Ref(C.B, False);
    end;
  end;
  Result := NewConstraint(C.Kind, C.A, C.B, C.C, C.Value);
  FConstraints[Result].Side := C.Side;
  FConstraints[Result].Active := C.Active;
end;

procedure TCADSketch.SetConstraintValue(AIndex: Integer; AValue: Double);
begin
  FConstraints[AIndex].Value := AValue;
  Inc(FRevision);
end;

procedure TCADSketch.RemoveConstraint(AIndex: Integer);
begin
  if FConstraints[AIndex].Kind = sckArcRule then
    raise ECADSketch.Create('sketch: the arc rule belongs to its arc');
  FConstraints[AIndex].Active := False;
  Inc(FRevision);
end;

procedure TCADSketch.SetPlane(const AOrigin, AXDir, ANormal: array of Double);
var
  N, X, Y: array[0..2] of Double;
  L, D: Double;
  I: Integer;
begin
  for I := 0 to 2 do
  begin
    N[I] := ANormal[I];
    X[I] := AXDir[I];
  end;
  L := Sqrt(Sqr(N[0]) + Sqr(N[1]) + Sqr(N[2]));
  if L < 1e-12 then
    raise ECADSketch.Create('sketch: plane normal is zero');
  for I := 0 to 2 do
    N[I] := N[I] / L;
  { X is made perpendicular to N; Y = N x X (right handed). }
  D := X[0] * N[0] + X[1] * N[1] + X[2] * N[2];
  for I := 0 to 2 do
    X[I] := X[I] - D * N[I];
  L := Sqrt(Sqr(X[0]) + Sqr(X[1]) + Sqr(X[2]));
  if L < 1e-12 then
    raise ECADSketch.Create('sketch: plane X direction is parallel to the normal');
  for I := 0 to 2 do
    X[I] := X[I] / L;
  Y[0] := N[1] * X[2] - N[2] * X[1];
  Y[1] := N[2] * X[0] - N[0] * X[2];
  Y[2] := N[0] * X[1] - N[1] * X[0];
  for I := 0 to 2 do
  begin
    FPlane.Origin[I] := AOrigin[I];
    FPlane.XDir[I] := X[I];
    FPlane.YDir[I] := Y[I];
    FPlane.Normal[I] := N[I];
  end;
  Inc(FRevision);
end;

procedure TCADSketch.ToModel(X, Y: Double; out AX, AY, AZ: Double);
begin
  AX := FPlane.Origin[0] + X * FPlane.XDir[0] + Y * FPlane.YDir[0];
  AY := FPlane.Origin[1] + X * FPlane.XDir[1] + Y * FPlane.YDir[1];
  AZ := FPlane.Origin[2] + X * FPlane.XDir[2] + Y * FPlane.YDir[2];
end;

procedure TCADSketch.SetParams(const AValues: array of Double);
var
  I: Integer;
begin
  for I := 0 to Min(High(AValues), FParamCount - 1) do
    FParams[I] := AValues[I];
  Inc(FRevision);
end;

end.
