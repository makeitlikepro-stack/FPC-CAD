unit CAD.Features.OCCTBase;
{$mode objfpc}{$H+}

{ ROLE:      common base of features computed by OCCT: turns a new shape
             handle into a TOCCTShapeResult (volume + optional mesh) and an
             OCCT error into a feature error.
  CALLED BY: CAD.Features.Box, .Cylinder, .BooleanOp (their Compute).
  CALLS:     CAD.OCCT.Bridge, CAD.OCCT.ShapeResult.
  THREADS:   worker threads (inside Compute).
  SPEED:     no mesh here by default (Mesh.Timing = cmtDisplayed): the
             document's display pass meshes only shown results after the
             recompute. Only cmtEveryResult meshes here, for every result. }

interface

uses
  SysUtils, CAD.Core.Feature, CAD.Config.Performance, CAD.OCCT.Bridge,
  CAD.OCCT.ShapeResult;

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
  R: TOCCTShapeResult;
begin
  AResult := nil;
  AError := '';
  if AShape = nil then
  begin
    AError := AWhat + ': ' + OCCT.LastError;
    Exit(False);
  end;
  R := TOCCTShapeResult.Create(AShape, nil, OCCT.ShapeVolume(AShape));
  if (OCCT.Options.Mesh.Timing = cmtEveryResult) and not R.PrepareDisplay(AError) then
  begin
    AError := AWhat + ': ' + AError;
    R.Free;                              { frees the shape too }
    Exit(False);
  end;
  AResult := R;
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
