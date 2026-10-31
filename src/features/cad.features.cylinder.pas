unit CAD.Features.Cylinder;
{$mode objfpc}{$H+}

{ ROLE:      Cylinder feature along +Z: bottom centre (x, y, z), radius,
             height. Registered as 'Cylinder'.
  CALLED BY: TCADDocument (Compute), registry ('Cylinder').
  CALLS:     occt_bridge_make_cylinder through CAD.OCCT.Bridge.
  THREADS:   Compute on a worker thread.
  SPEED:     no inputs: recompute level 0. }

interface

uses
  SysUtils, CAD.Core.Values, CAD.Core.Feature, CAD.Core.FeatureRegistry,
  CAD.OCCT.Bridge, CAD.Features.OCCTBase;

type
  TCADCylinderFeature = class(TCADOCCTFeature)
  protected
    procedure DefineParams; override;
    function Compute(const AInputs: array of TCADResult; out AResult: TCADResult;
      out AError: string): Boolean; override;
  public
    class function TypeName: string; override;
  end;

implementation

class function TCADCylinderFeature.TypeName: string;
begin
  Result := 'Cylinder';
end;

procedure TCADCylinderFeature.DefineParams;
begin
  AddParam('x', CADFloat(0));
  AddParam('y', CADFloat(0));
  AddParam('z', CADFloat(0));
  AddParam('radius', CADFloat(5));
  AddParam('height', CADFloat(10));
end;

function TCADCylinderFeature.Compute(const AInputs: array of TCADResult;
  out AResult: TCADResult; out AError: string): Boolean;
begin
  Result := WrapShape(OCCT.MakeCylinder(
    GetParamValue('x').F, GetParamValue('y').F, GetParamValue('z').F,
    GetParamValue('radius').F, GetParamValue('height').F),
    'Cylinder', AResult, AError);
end;

initialization
  CADFeatures.Register(TCADCylinderFeature);
end.
