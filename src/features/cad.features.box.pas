unit CAD.Features.Box;
{$mode objfpc}{$H+}

{ ROLE:      Box feature: axis-aligned box, minimum corner (x, y, z), sizes
             (dx, dy, dz). Registered as 'Box'.
  CALLED BY: TCADDocument (Compute), registry ('Box').
  CALLS:     occt_bridge_make_box through CAD.OCCT.Bridge.
  THREADS:   Compute on a worker thread.
  SPEED:     no inputs: always in recompute level 0 (parallel with every
             other primitive). }

interface

uses
  SysUtils, CAD.Core.Values, CAD.Core.Feature, CAD.Core.FeatureRegistry,
  CAD.OCCT.Bridge, CAD.Features.OCCTBase;

type
  TCADBoxFeature = class(TCADOCCTFeature)
  protected
    procedure DefineParams; override;
    function Compute(const AInputs: array of TCADResult; out AResult: TCADResult;
      out AError: string): Boolean; override;
  public
    class function TypeName: string; override;
  end;

implementation

class function TCADBoxFeature.TypeName: string;
begin
  Result := 'Box';
end;

procedure TCADBoxFeature.DefineParams;
begin
  AddParam('x', CADFloat(0));
  AddParam('y', CADFloat(0));
  AddParam('z', CADFloat(0));
  AddParam('dx', CADFloat(10));
  AddParam('dy', CADFloat(10));
  AddParam('dz', CADFloat(10));
end;

function TCADBoxFeature.Compute(const AInputs: array of TCADResult;
  out AResult: TCADResult; out AError: string): Boolean;
begin
  Result := WrapShape(OCCT.MakeBox(
    GetParamValue('x').F, GetParamValue('y').F, GetParamValue('z').F,
    GetParamValue('dx').F, GetParamValue('dy').F, GetParamValue('dz').F),
    'Box', AResult, AError);
end;

initialization
  CADFeatures.Register(TCADBoxFeature);
end.
