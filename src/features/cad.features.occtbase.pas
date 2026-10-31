unit CAD.Features.OCCTBase;
{$mode objfpc}{$H+}

{ ROLE:      common base of features computed by OCCT: turns a new shape
             handle into a TOCCTShapeResult (volume + optional mesh) and an
             OCCT error into a feature error.
  CALLED BY: CAD.Features.Box, .Cylinder, .BooleanOp (their Compute).
  CALLS:     CAD.OCCT.Bridge, CAD.OCCT.ShapeResult.
  THREADS:   worker threads (inside Compute).
  SPEED:     meshing happens here, inside the parallel recompute, when
             Options.Mesh.MeshInRecompute is on (the bridge serialises meshes
             but each mesh uses all cores). }

interface

uses
  SysUtils, CAD.Core.Feature, CAD.OCCT.Bridge, CAD.OCCT.ShapeResult;

type
  TCADOCCTFeature = class(TCADFeature)
  protected
    { Owns AShape from here on. nil AShape = OCCT failed: AError gets the
      bridge message prefixed with AWhat. }
    function WrapShape(AShape: TOCCTShapeHandle; const AWhat: string;
      out AResult: TCADResult; out AError: string): Boolean;
    { Shape of input AIndex, or nil (with AError) when it is not an OCCT shape. }
    function InputShape(const AInputs: array of TCADResult; AIndex: Integer;
      out AError: string): TOCCTShapeHandle;
  end;

implementation

function TCADOCCTFeature.WrapShape(AShape: TOCCTShapeHandle; const AWhat: string;
  out AResult: TCADResult; out AError: string): Boolean;
var
  Mesh: TOCCTMeshHandle;
  Volume: Double;
begin
  AResult := nil;
  AError := '';
  if AShape = nil then
  begin
    AError := AWhat + ': ' + OCCT.LastError;
    Exit(False);
  end;
  Volume := OCCT.ShapeVolume(AShape);
  Mesh := nil;
  if OCCT.Options.Mesh.MeshInRecompute then
  begin
    Mesh := OCCT.MeshShape(AShape, 0);         { 0 = deflection from the options }
    if Mesh = nil then
    begin
      AError := AWhat + ': mesh: ' + OCCT.LastError;
      OCCT.FreeShape(AShape);
      Exit(False);
    end;
  end;
  AResult := TOCCTShapeResult.Create(AShape, Mesh, Volume);
  Result := True;
end;

function TCADOCCTFeature.InputShape(const AInputs: array of TCADResult; AIndex: Integer;
  out AError: string): TOCCTShapeHandle;
begin
  AError := '';
  Result := nil;
  if (AIndex < 0) or (AIndex > High(AInputs)) then
    AError := Format('%s needs input %d', [TypeName, AIndex + 1])
  else if not (AInputs[AIndex] is TOCCTShapeResult) then
    AError := Format('%s: input %d is not a solid', [TypeName, AIndex + 1])
  else
    Result := TOCCTShapeResult(AInputs[AIndex]).Shape;
end;

end.
