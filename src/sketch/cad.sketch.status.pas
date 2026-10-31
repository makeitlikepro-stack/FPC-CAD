unit CAD.Sketch.Status;
{$mode objfpc}{$H+}

{ ROLE:      state of every point and entity for the sketcher colours, as in
             SolidWorks: under-defined (blue), fully defined (black),
             conflicting (red). Construction is drawn apart by the caller.
  CALLED BY: CAD.View.SketchDraw (layer meshes), tests/sketch.
  CALLS:     CAD.Sketch.Model, CAD.Sketch.Solver (Determined, Conflicting),
             CAD.Sketch.Constraints (params of a constraint).
  THREADS:   pure, any thread.
  SPEED:     one pass over entities and conflicting constraints. }

interface

uses
  CAD.Sketch.Model, CAD.Sketch.Solver, CAD.Sketch.Constraints;

type
  TCADElementState = (cesUnder, cesDefined, cesConflict);
  TCADElementStates = array of TCADElementState;

{ AEntities[i] for entity i, APoints[i] for point i. Without diagnostics in
  R (Determined empty) everything is under-defined unless conflicting. }
procedure CADSketchStates(S: TCADSketch; const R: TCADSketchSolveResult;
  out AEntities, APoints: TCADElementStates);

implementation

procedure CADSketchStates(S: TCADSketch; const R: TCADSketchSolveResult;
  out AEntities, APoints: TCADElementStates);
var
  Bad: array of Boolean;
  KnownAll: Boolean;
  I, K: Integer;
  E: TCADSketchEntity;
  L: TCADSkParamList;

  function Det(AParam: Integer): Boolean;
  begin
    Result := KnownAll and (AParam >= 0) and R.Determined[AParam];
  end;

  function PointDet(P: Integer): Boolean;
  begin
    Result := Det(S.Points[P].XParam) and Det(S.Points[P].YParam);
  end;

  function PointBad(P: Integer): Boolean;
  begin
    Result := Bad[S.Points[P].XParam] or Bad[S.Points[P].YParam];
  end;

begin
  KnownAll := Length(R.Determined) = S.ParamCount;
  SetLength(Bad, S.ParamCount);
  for I := 0 to High(R.Conflicting) do
  begin
    CADConstraintParams(S, S.Constraints[R.Conflicting[I]], L);
    for K := 0 to L.Count - 1 do
      Bad[L.Idx[K]] := True;
  end;
  SetLength(APoints, S.PointCount);
  for I := 0 to S.PointCount - 1 do
    if PointBad(I) then
      APoints[I] := cesConflict
    else if KnownAll and PointDet(I) then
      APoints[I] := cesDefined
    else
      APoints[I] := cesUnder;
  SetLength(AEntities, S.EntityCount);
  for I := 0 to S.EntityCount - 1 do
  begin
    E := S.Entities[I];
    case E.Kind of
      sekLine:
        if PointBad(E.P1) or PointBad(E.P2) then
          AEntities[I] := cesConflict
        else if KnownAll and PointDet(E.P1) and PointDet(E.P2) then
          AEntities[I] := cesDefined
        else
          AEntities[I] := cesUnder;
      sekCircle:
        if PointBad(E.Center) or Bad[E.RadiusParam] then
          AEntities[I] := cesConflict
        else if KnownAll and PointDet(E.Center) and Det(E.RadiusParam) then
          AEntities[I] := cesDefined
        else
          AEntities[I] := cesUnder;
      sekArc:
        if PointBad(E.Center) or PointBad(E.P1) or PointBad(E.P2) then
          AEntities[I] := cesConflict
        else if KnownAll and PointDet(E.Center) and PointDet(E.P1) and PointDet(E.P2) then
          AEntities[I] := cesDefined
        else
          AEntities[I] := cesUnder;
    end;
  end;
end;

end.
