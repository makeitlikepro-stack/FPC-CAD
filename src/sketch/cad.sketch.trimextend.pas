unit CAD.Sketch.TrimExtend;
{$mode objfpc}{$H+}

{ ROLE: Pure planning of line Trim and Extend, in sketch millimetres.
  Line/line intersections use the target line's infinite support and the
  boundary line's finite segment. Planning does not mutate the sketch.
  A later editing step must validate constraints and commit one undo step.
  Currently: endpoint trim/extend for straight lines; trimming between two
  crossings requires splitting the entity and is deliberately rejected. }

interface

uses
  SysUtils, Math, CAD.Sketch.Model;

type
  TCADLineEditMode = (lemTrim, lemExtend);
  TCADLineEndpoint = (leStart, leEnd);

  TCADLineEditPlan = record
    TargetEntity: Integer;
    BoundaryEntity: Integer;
    Endpoint: TCADLineEndpoint;
    X, Y: Double;
    T: Double;          { point A + T * (B - A); Trim: 0..1 }
  end;

{ Plan the operation nearest the click on ALine.
  Returns False with AError when no suitable boundary exists, the selection
  is invalid, or trimming would require splitting a middle segment.
  The caller owns validation and mutation; this function changes nothing. }
function CADPlanLineEdit(ASketch: TCADSketch; ALine: Integer; AClickX, AClickY: Double;
  AMode: TCADLineEditMode; out APlan: TCADLineEditPlan; out AError: string): Boolean;

implementation

const
  ParamEpsilon = 1e-8;

function Cross(AX, AY, BX, BY: Double): Double; inline;
begin
  Result := AX * BY - AY * BX;
end;

function CADPlanLineEdit(ASketch: TCADSketch; ALine: Integer; AClickX, AClickY: Double;
  AMode: TCADLineEditMode; out APlan: TCADLineEditPlan; out AError: string): Boolean;
var
  Target, Boundary: TCADSketchEntity;
  AX, AY, RX, RY, CX, CY, SX, SY, Den, T, U: Double;
  ClickT, MinT, MaxT, BestT, LengthSquared: Double;
  I, MinBoundary, MaxBoundary, BestBoundary: Integer;
  HaveCrossing, ExtendStart: Boolean;
begin
  APlan := Default(TCADLineEditPlan);
  APlan.TargetEntity := ALine;
  APlan.BoundaryEntity := -1;
  AError := '';
  Result := False;
  if (ASketch = nil) or (ALine < 0) then
  begin
    AError := 'no sketch or target line';
    Exit;
  end;
  if ALine >= ASketch.EntityCount then
  begin
    AError := 'target line index is out of range';
    Exit;
  end;
  Target := ASketch.Entities[ALine];
  if Target.Kind <> sekLine then
  begin
    AError := 'Trim / Extend currently supports straight lines only';
    Exit;
  end;
  AX := ASketch.PointX(Target.P1);
  AY := ASketch.PointY(Target.P1);
  RX := ASketch.PointX(Target.P2) - AX;
  RY := ASketch.PointY(Target.P2) - AY;
  LengthSquared := RX * RX + RY * RY;
  if LengthSquared <= 1e-20 then
  begin
    AError := 'the target line has zero length';
    Exit;
  end;
  ClickT := ((AClickX - AX) * RX + (AClickY - AY) * RY) / LengthSquared;
  ExtendStart := ClickT < 0.5;
  HaveCrossing := False;
  MinT := 1e100;
  MaxT := -1e100;
  MinBoundary := -1;
  MaxBoundary := -1;
  BestBoundary := -1;
  if ExtendStart then
    BestT := -1e100
  else
    BestT := 1e100;

  for I := 0 to ASketch.EntityCount - 1 do
  begin
    if I = ALine then
      Continue;
    Boundary := ASketch.Entities[I];
    if Boundary.Kind <> sekLine then
      Continue;
    CX := ASketch.PointX(Boundary.P1);
    CY := ASketch.PointY(Boundary.P1);
    SX := ASketch.PointX(Boundary.P2) - CX;
    SY := ASketch.PointY(Boundary.P2) - CY;
    Den := Cross(RX, RY, SX, SY);
    if Abs(Den) <= 1e-12 * Sqrt(LengthSquared * (SX * SX + SY * SY)) then
      Continue;                               { parallel or degenerate }
    T := Cross(CX - AX, CY - AY, SX, SY) / Den;
    U := Cross(CX - AX, CY - AY, RX, RY) / Den;
    if (U < -ParamEpsilon) or (U > 1 + ParamEpsilon) then
      Continue;                               { boundary is a finite segment }

    if AMode = lemTrim then
    begin
      if (T <= ParamEpsilon) or (T >= 1 - ParamEpsilon) then
        Continue;                             { interior crossings only }
      HaveCrossing := True;
      if T < MinT then
      begin
        MinT := T;
        MinBoundary := I;
      end;
      if T > MaxT then
      begin
        MaxT := T;
        MaxBoundary := I;
      end;
    end
    else if ExtendStart then
    begin
      if (T < -ParamEpsilon) and (T > BestT) then
      begin
        BestT := T;
        BestBoundary := I;
        HaveCrossing := True;
      end;
    end
    else if (T > 1 + ParamEpsilon) and (T < BestT) then
    begin
      BestT := T;
      BestBoundary := I;
      HaveCrossing := True;
    end;
  end;

  if not HaveCrossing then
  begin
    AError := 'no intersecting boundary segment in the required direction';
    Exit;
  end;
  if AMode = lemTrim then
  begin
    if ClickT < MinT - ParamEpsilon then
    begin
      BestT := MinT;
      BestBoundary := MinBoundary;
      APlan.Endpoint := leStart;
    end
    else if ClickT > MaxT + ParamEpsilon then
    begin
      BestT := MaxT;
      BestBoundary := MaxBoundary;
      APlan.Endpoint := leEnd;
    end
    else
    begin
      AError := 'trimming the middle between crossings needs an entity split';
      Exit;
    end;
  end
  else if ExtendStart then
    APlan.Endpoint := leStart
  else
    APlan.Endpoint := leEnd;

  APlan.BoundaryEntity := BestBoundary;
  APlan.T := BestT;
  APlan.X := AX + BestT * RX;
  APlan.Y := AY + BestT * RY;
  Result := True;
end;

end.
