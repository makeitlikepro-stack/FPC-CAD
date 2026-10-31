unit CAD.App.DemoScene;
{$mode objfpc}{$H+}

{ ROLE:      builds the first viewport scene: a 60 x 40 x 10 plate with a
             3 x 2 grid of through holes (6 chained cuts), and changes the
             hole radius.
  CALLED BY: CAD.App.Controller.
  CALLS:     CAD.Core.Document, CAD.Features.Box / Cylinder / BooleanOp.
  THREADS:   UI thread (no recompute here; the caller recomputes).
  SPEED:     SetHoleRadius only marks the 6 cylinders; the cache keeps the
             plate, so a recompute redoes the cylinders and the 6 cuts. }

interface

uses
  SysUtils, CAD.Core.Ids, CAD.Core.Values, CAD.Core.Feature, CAD.Core.Document,
  CAD.Features.Box, CAD.Features.Cylinder, CAD.Features.BooleanOp;

const
  CAD_DEMO_HOLES = 6;
  CAD_DEMO_MIN_RADIUS = 1.0;
  CAD_DEMO_MAX_RADIUS = 7.0;     { holes stay apart (18 x 16 mm grid) }

type
  TCADDemoScene = record
    Plate: TCADId;
    Holes: array[0..CAD_DEMO_HOLES - 1] of TCADId;
    Last: TCADId;                { end of the cut chain (the shown body) }
  end;

function BuildDemoScene(ADoc: TCADDocument; ARadius: Double;
  out AScene: TCADDemoScene; out AError: string): Boolean;
procedure SetHoleRadius(ADoc: TCADDocument; const AScene: TCADDemoScene; ARadius: Double);

implementation

function NewBox(X, Y, Z, DX, DY, DZ: Double): TCADFeature;
begin
  Result := TCADBoxFeature.Create;
  Result.Name := 'Plate';
  Result.SetParamValue('x', CADFloat(X));
  Result.SetParamValue('y', CADFloat(Y));
  Result.SetParamValue('z', CADFloat(Z));
  Result.SetParamValue('dx', CADFloat(DX));
  Result.SetParamValue('dy', CADFloat(DY));
  Result.SetParamValue('dz', CADFloat(DZ));
end;

function NewCylinder(X, Y, Z, ARadius, AHeight: Double; AIndex: Integer): TCADFeature;
begin
  Result := TCADCylinderFeature.Create;
  Result.Name := Format('Hole %d', [AIndex + 1]);
  Result.SetParamValue('x', CADFloat(X));
  Result.SetParamValue('y', CADFloat(Y));
  Result.SetParamValue('z', CADFloat(Z));
  Result.SetParamValue('radius', CADFloat(ARadius));
  Result.SetParamValue('height', CADFloat(AHeight));
end;

function BuildDemoScene(ADoc: TCADDocument; ARadius: Double;
  out AScene: TCADDemoScene; out AError: string): Boolean;
const
  HoleX: array[0..2] of Double = (12, 30, 48);
  HoleY: array[0..1] of Double = (12, 28);
var
  I: Integer;
  Cut: TCADFeature;
  CutId: TCADId;
begin
  AError := '';
  AScene.Plate := ADoc.AttachFeature(NewBox(0, 0, 0, 60, 40, 10));
  AScene.Last := AScene.Plate;
  for I := 0 to CAD_DEMO_HOLES - 1 do
  begin
    AScene.Holes[I] := ADoc.AttachFeature(
      NewCylinder(HoleX[I mod 3], HoleY[I div 3], -1, ARadius, 12, I));
    Cut := TCADBooleanFeature.Create;
    Cut.Name := Format('Cut %d', [I + 1]);
    Cut.SetParamValue('op', CADInt(CAD_BOOLEAN_CUT));
    CutId := ADoc.AttachFeature(Cut);
    if not (ADoc.TryLink(CutId, AScene.Last, AError) and
            ADoc.TryLink(CutId, AScene.Holes[I], AError)) then
      Exit(False);
    AScene.Last := CutId;
  end;
  Result := True;
end;

procedure SetHoleRadius(ADoc: TCADDocument; const AScene: TCADDemoScene; ARadius: Double);
var
  I: Integer;
begin
  for I := 0 to CAD_DEMO_HOLES - 1 do
    ADoc.SetParam(AScene.Holes[I], 'radius', CADFloat(ARadius));
end;

end.
