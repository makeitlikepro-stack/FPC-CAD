unit CAD.Sketch.TrimExtend;
{$mode objfpc}{$H+}

{ ROLE: Click Trim of whole/end/middle straight-line spans and line Extend.
  Trim finds the two crossings bracketing the click and deletes that span,
  retaining left/right pieces as new geometry. Stable entity tombstones and
  a trial-sketch solve allow undo and safe rollback. Extend adjusts an
  eligible unshared endpoint. Curve trimming comes in a later stage. }

interface

uses
  SysUtils, Math, CAD.Sketch.Model, CAD.Sketch.Solver, CAD.Sketch.Text;

type
  TCADLineEditMode = (lemTrim, lemExtend);
  TCADLineEndpoint = (leStart, leEnd);

  TCADLineEditPlan = record
    TargetEntity: Integer;
    BoundaryEntity: Integer;
    Endpoint: TCADLineEndpoint;
    X, Y: Double;
    T: Double;
  end;

  { Trim deletes the interval that contains the click. }
  TCADTrimPlan = record
    TargetEntity: Integer;
    FromT, ToT: Double;
    LeftBoundary, RightBoundary: Integer;
  end;

{ Plan the operation nearest the click on ALine.
  Legacy endpoint planner used for Extend. CADPlanLineTrim below handles
  click-to-cut Trim, including middle segments.
  The caller owns validation and mutation; this function changes nothing. }
function CADPlanLineEdit(ASketch: TCADSketch; ALine: Integer; AClickX, AClickY: Double;
  AMode: TCADLineEditMode; out APlan: TCADLineEditPlan; out AError: string): Boolean;

{ Apply only a plan whose edited endpoint is unshared, unfixed and
  independent of other constraints; solve and roll back on conflict. }
function CADApplyLineEdit(ASketch: TCADSketch; const APlan: TCADLineEditPlan;
  out AError: string): Boolean;

{ Find the bounded span containing the click, including the middle. }
function CADPlanLineTrim(ASketch: TCADSketch; ALine: Integer;
  AClickX, AClickY: Double; out APlan: TCADTrimPlan; out AError: string): Boolean;

{ Split/delete on a trial sketch; copy back only if valid. }
function CADApplyLineTrim(ASketch: TCADSketch; const APlan: TCADTrimPlan;
  out AError: string): Boolean;

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
  if (not Target.Active) or (Target.Kind <> sekLine) then
  begin
    AError := 'Trim / Extend currently supports active straight lines only';
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
    if (not Boundary.Active) or (Boundary.Kind <> sekLine) then
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


{ Does the active constraint use this point as a *point* reference? }
function UsesPoint(const C: TCADSketchConstraint; APoint: Integer): Boolean;
begin
  case C.Kind of
    sckCoincident, sckHorizontalPts, sckVerticalPts, sckDistance,
    sckDistanceX, sckDistanceY, sckSymmetric:
      Result := (C.A = APoint) or (C.B = APoint);
    sckPointOnLine, sckPointOnCircle, sckPointLineDist, sckMidpoint:
      Result := C.A = APoint;
  else
    Result := False;
  end;
end;

{ Does the active constraint use this line as an *entity* reference? }
function UsesLine(const C: TCADSketchConstraint; ALine: Integer): Boolean;
begin
  case C.Kind of
    sckHorizontal, sckVertical, sckLength, sckRadius, sckDiameter, sckArcRule:
      Result := C.A = ALine;
    sckPointOnLine, sckPointOnCircle, sckPointLineDist, sckMidpoint:
      Result := C.B = ALine;
    sckSymmetric:
      Result := C.C = ALine;
    sckParallel, sckPerpendicular, sckAngle, sckCollinear,
    sckEqualLength, sckEqualRadius, sckTangentLine,
    sckTangentCircles, sckConcentric:
      Result := (C.A = ALine) or (C.B = ALine);
  else
    Result := False;
  end;
end;

function CADApplyLineEdit(ASketch: TCADSketch; const APlan: TCADLineEditPlan;
  out AError: string): Boolean;
var
  Target, E: TCADSketchEntity;
  C: TCADSketchConstraint;
  EndpointPoint, I: Integer;
  Saved: array of Double;
  SolveResult: TCADSketchSolveResult;
begin
  Result := False;
  AError := '';
  if (ASketch = nil) or (APlan.TargetEntity < 0) then
  begin
    AError := 'no target line';
    Exit;
  end;
  if APlan.TargetEntity >= ASketch.EntityCount then
  begin
    AError := 'target line index is out of range';
    Exit;
  end;
  Target := ASketch.Entities[APlan.TargetEntity];
  if (not Target.Active) or (Target.Kind <> sekLine) then
  begin
    AError := 'Trim / Extend currently supports active straight lines only';
    Exit;
  end;

  if APlan.Endpoint = leStart then
    EndpointPoint := Target.P1
  else
    EndpointPoint := Target.P2;
  if ASketch.Fixed[ASketch.Points[EndpointPoint].XParam] or
     ASketch.Fixed[ASketch.Points[EndpointPoint].YParam] then
  begin
    AError := 'the selected endpoint is fixed';
    Exit;
  end;

  for I := 0 to ASketch.EntityCount - 1 do
  begin
    if I = APlan.TargetEntity then
      Continue;
    E := ASketch.Entities[I];
    if ((E.Kind in [sekLine, sekArc]) and
        ((E.P1 = EndpointPoint) or (E.P2 = EndpointPoint))) or
       ((E.Kind in [sekCircle, sekArc]) and (E.Center = EndpointPoint)) then
    begin
      AError := 'the endpoint is shared by another entity';
      Exit;
    end;
  end;
  for I := 0 to ASketch.ConstraintCount - 1 do
  begin
    C := ASketch.Constraints[I];
    if not C.Active then
      Continue;
    if UsesPoint(C, EndpointPoint) then
    begin
      AError := 'the endpoint is constrained';
      Exit;
    end;
    if UsesLine(C, APlan.TargetEntity) and
       not ((C.Kind in [sckHorizontal, sckVertical]) and
            (C.A = APlan.TargetEntity)) then
    begin
      AError := 'the line has constraints that need remapping';
      Exit;
    end;
  end;

  SetLength(Saved, ASketch.ParamCount);
  for I := 0 to High(Saved) do
    Saved[I] := ASketch.Params[I];
  ASketch.MovePoint(EndpointPoint, APlan.X, APlan.Y);
  SolveResult := CADSolveSketch(ASketch);
  if (SolveResult.Status <> cssSolved) or
     (Hypot(ASketch.PointX(EndpointPoint) - APlan.X,
       ASketch.PointY(EndpointPoint) - APlan.Y) > 1e-6) then
  begin
    ASketch.SetParams(Saved);
    CADSolveSketch(ASketch);
    AError := 'the edit conflicts with existing constraints; reverted';
    Exit;
  end;
  Result := True;
end;


{ Return the interval between the nearest crossings around the click.
  The boundary lines are finite segments, but the target is treated as
  one segment of a larger infinite straight line. }
function CADPlanLineTrim(ASketch: TCADSketch; ALine: Integer;
  AClickX, AClickY: Double; out APlan: TCADTrimPlan; out AError: string): Boolean;
var
  Target, Boundary: TCADSketchEntity;
  AX, AY, RX, RY, CX, CY, SX, SY, Den, T, U: Double;
  ClickT, L2, Tol: Double;
  I: Integer;
begin
  Result := False;
  AError := '';
  APlan := Default(TCADTrimPlan);
  APlan.TargetEntity := ALine;
  APlan.FromT := 0;
  APlan.ToT := 1;
  APlan.LeftBoundary := -1;
  APlan.RightBoundary := -1;
  if (ASketch = nil) or (ALine < 0) then
  begin
    AError := 'no target line';
    Exit;
  end;
  if ALine >= ASketch.EntityCount then
  begin
    AError := 'invalid target line index';
    Exit;
  end;
  Target := ASketch.Entities[ALine];
  if (not Target.Active) or (Target.Kind <> sekLine) then
  begin
    AError := 'Trim currently supports active straight lines';
    Exit;
  end;
  AX := ASketch.PointX(Target.P1);
  AY := ASketch.PointY(Target.P1);
  RX := ASketch.PointX(Target.P2) - AX;
  RY := ASketch.PointY(Target.P2) - AY;
  L2 := RX * RX + RY * RY;
  if L2 <= 1e-20 then
  begin
    AError := 'zero-length target line';
    Exit;
  end;
  ClickT := EnsureRange(((AClickX - AX) * RX + (AClickY - AY) * RY) / L2, 0.0, 1.0);
  Tol := Max(ParamEpsilon, 1e-6 / Sqrt(L2));
  for I := 0 to ASketch.EntityCount - 1 do
  begin
    if I = ALine then Continue;
    Boundary := ASketch.Entities[I];
    if (not Boundary.Active) or (Boundary.Kind <> sekLine) then Continue;
    CX := ASketch.PointX(Boundary.P1);
    CY := ASketch.PointY(Boundary.P1);
    SX := ASketch.PointX(Boundary.P2) - CX;
    SY := ASketch.PointY(Boundary.P2) - CY;
    Den := Cross(RX, RY, SX, SY);
    if Abs(Den) <= 1e-12 * Sqrt(L2 * (SX * SX + SY * SY)) then Continue;
    T := Cross(CX - AX, CY - AY, SX, SY) / Den;
    U := Cross(CX - AX, CY - AY, RX, RY) / Den;
    if (U < -ParamEpsilon) or (U > 1 + ParamEpsilon) then Continue;
    if (T <= Tol) or (T >= 1 - Tol) then Continue;
    if Abs(T - ClickT) <= Tol then
    begin
      AError := 'click inside a segment, not exactly at the intersection';
      Exit;
    end;
    if (T < ClickT) and (T > APlan.FromT) then
    begin
      APlan.FromT := T;
      APlan.LeftBoundary := I;
    end;
    if (T > ClickT) and (T < APlan.ToT) then
    begin
      APlan.ToT := T;
      APlan.RightBoundary := I;
    end;
  end;
  Result := APlan.ToT - APlan.FromT > Tol;
  if not Result then AError := 'selected piece is too short to trim';
end;

{ Trim must not silently reattach length/angle constraints to a different
  segment. Only horizontal/vertical are copied to each survivor. }
function CADApplyLineTrim(ASketch: TCADSketch; const APlan: TCADTrimPlan;
  out AError: string): Boolean;
var
  Trial: TCADSketch;
  Target: TCADSketchEntity;
  C: TCADSketchConstraint;
  I, L, P: Integer;
  AX, AY, DX, DY: Double;
  Horizontal, Vertical: Boolean;
  SolveResult: TCADSketchSolveResult;

  procedure AddPiece(P1, P2: Integer);
  begin
    L := Trial.AddLine(P1, P2);
    Trial.SetConstruction(L, Target.Construction);
    if Horizontal then Trial.Horizontal(L);
    if Vertical then Trial.Vertical(L);
  end;

begin
  Result := False;
  AError := '';
  if (ASketch = nil) or (APlan.TargetEntity < 0) then
  begin
    AError := 'no sketch or trim target';
    Exit;
  end;
  if APlan.TargetEntity >= ASketch.EntityCount then
  begin
    AError := 'invalid target line index';
    Exit;
  end;
  Target := ASketch.Entities[APlan.TargetEntity];
  if (not Target.Active) or (Target.Kind <> sekLine) then
  begin
    AError := 'the target is not an active line';
    Exit;
  end;
  if (APlan.FromT < 0) or (APlan.ToT > 1) or
     (APlan.ToT - APlan.FromT < ParamEpsilon) then
  begin
    AError := 'invalid trim interval';
    Exit;
  end;
  Horizontal := False;
  Vertical := False;
  for I := 0 to ASketch.ConstraintCount - 1 do
  begin
    C := ASketch.Constraints[I];
    if not C.Active or not UsesLine(C, APlan.TargetEntity) then Continue;
    case C.Kind of
      sckHorizontal: Horizontal := True;
      sckVertical: Vertical := True;
    else
      begin
        AError := 'cannot trim a line with dimensions or relations that require remapping';
        Exit;
      end;
    end;
  end;

  Trial := TCADSketch.Create;
  try
    CADSketchFromText(CADSketchToText(ASketch), Trial);
    Target := Trial.Entities[APlan.TargetEntity];
    AX := Trial.PointX(Target.P1);
    AY := Trial.PointY(Target.P1);
    DX := Trial.PointX(Target.P2) - AX;
    DY := Trial.PointY(Target.P2) - AY;
    { Keep original end point indices on the survivors. If the click is
      between two crossings, two pieces are retained, with a real gap. }
    if APlan.FromT > ParamEpsilon then
    begin
      P := Trial.AddPoint(AX + APlan.FromT * DX, AY + APlan.FromT * DY);
      AddPiece(Target.P1, P);
    end;
    if APlan.ToT < 1 - ParamEpsilon then
    begin
      P := Trial.AddPoint(AX + APlan.ToT * DX, AY + APlan.ToT * DY);
      AddPiece(P, Target.P2);
    end;
    Trial.RemoveEntity(APlan.TargetEntity);
    SolveResult := CADSolveSketch(Trial);
    if SolveResult.Status <> cssSolved then
    begin
      AError := 'trim conflicts with remaining constraints; nothing changed';
      Exit;
    end;
    ASketch.AssignFrom(Trial);
    Result := True;
  finally
    Trial.Free;
  end;
end;

end.
