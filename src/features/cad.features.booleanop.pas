unit CAD.Features.BooleanOp;
{$mode objfpc}{$H+}

{ ROLE:      Boolean feature on two input solids: op 0 = cut (input 1 minus
             input 2), 1 = fuse, 2 = common. Registered as 'Boolean'.
  CALLED BY: TCADDocument (Compute), registry ('Boolean').
  CALLS:     occt_bridge_boolean through CAD.OCCT.Bridge (speed options:
             parallel, OBB, fuzzy, glue, non-destructive, check inverted).
  THREADS:   Compute on a worker thread; inputs are shared read-only.
  SPEED:     non-destructive by default, so the inputs' cached results stay
             valid for Undo and for other features using the same inputs. }

interface

uses
  SysUtils, CAD.Core.Values, CAD.Core.Feature, CAD.Core.FeatureRegistry,
  CAD.OCCT.Bridge, CAD.Features.OCCTBase;

const
  CAD_BOOLEAN_CUT = 0;
  CAD_BOOLEAN_FUSE = 1;
  CAD_BOOLEAN_COMMON = 2;

type
  TCADBooleanFeature = class(TCADOCCTFeature)
  protected
    procedure DefineParams; override;
    function Compute(const AInputs: array of TCADResult; out AResult: TCADResult;
      out AError: string): Boolean; override;
  public
    class function TypeName: string; override;
  end;

implementation

class function TCADBooleanFeature.TypeName: string;
begin
  Result := 'Boolean';
end;

procedure TCADBooleanFeature.DefineParams;
begin
  AddParam('op', CADInt(CAD_BOOLEAN_CUT));
end;

function TCADBooleanFeature.Compute(const AInputs: array of TCADResult;
  out AResult: TCADResult; out AError: string): Boolean;
var
  ObjectShape, ToolShape: TOCCTShapeHandle;
  Op: Int64;
begin
  AResult := nil;
  if Length(AInputs) <> 2 then
  begin
    AError := Format('Boolean needs exactly 2 inputs, has %d', [Length(AInputs)]);
    Exit(False);
  end;
  Op := GetParamValue('op').I;
  if (Op < CAD_BOOLEAN_CUT) or (Op > CAD_BOOLEAN_COMMON) then
  begin
    AError := Format('Boolean op must be 0 cut, 1 fuse or 2 common, is %d', [Op]);
    Exit(False);
  end;
  ObjectShape := InputShape(AInputs, 0, AError);
  if ObjectShape = nil then
    Exit(False);
  ToolShape := InputShape(AInputs, 1, AError);
  if ToolShape = nil then
    Exit(False);
  Result := WrapShape(OCCT.BooleanOp(Op, ObjectShape, ToolShape), 'Boolean', AResult, AError);
end;

initialization
  CADFeatures.Register(TCADBooleanFeature);
end.
