unit CAD.Features.Extrude;
{$mode objfpc}{$H+}

{ ROLE:      Extrude feature: input 1 = planar faces (a Sketch), parameters
             length (mm), symmetric (half to each side), reversed (against
             the sketch normal). Registered as 'Extrude'.
  CALLED BY: TCADDocument (Compute), registry, the app and tests.
  CALLS:     CAD.OCCT.Bridge (Extrude = BRepPrimAPI_MakePrism),
             CAD.Features.OCCTBase.
  THREADS:   Compute on a worker thread; the input face is shared read-only.
  SPEED:     a length change recomputes only this feature: the sketch result
             comes from the cache. }

interface

uses
  SysUtils, CAD.Core.Values, CAD.Core.Feature, CAD.Core.FeatureRegistry,
  CAD.OCCT.Bridge, CAD.Features.OCCTBase;

type
  TCADExtrudeFeature = class(TCADOCCTFeature)
  protected
    procedure DefineParams; override;
    function Compute(const AInputs: array of TCADResult; out AResult: TCADResult;
      out AError: string): Boolean; override;
  public
    class function TypeName: string; override;
  end;

implementation

class function TCADExtrudeFeature.TypeName: string;
begin
  Result := 'Extrude';
end;

procedure TCADExtrudeFeature.DefineParams;
begin
  AddParam('length', CADFloat(10));
  AddParam('symmetric', CADBool(False));
  AddParam('reversed', CADBool(False));
end;

function TCADExtrudeFeature.Compute(const AInputs: array of TCADResult;
  out AResult: TCADResult; out AError: string): Boolean;
var
  Profile: TOCCTShapeHandle;
begin
  AResult := nil;
  Profile := InputShape(AInputs, 0, AError);
  if Profile = nil then
    Exit(False);
  Result := WrapShape(OCCT.Extrude(Profile, GetParamValue('length').F,
    GetParamValue('symmetric').B, GetParamValue('reversed').B), 'Extrude', AResult, AError);
end;

initialization
  CADFeatures.Register(TCADExtrudeFeature);
end.
