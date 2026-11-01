program cad_sketch_binding_tests;
{$mode objfpc}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils, CAD.Core.Ids, CAD.Core.Values, CAD.Core.Feature,
  CAD.Core.Document, CAD.Core.ObjectIds, CAD.Core.ObjectModel,
  CAD.Core.History, CAD.Core.SketchBindingCommands;

type
  { Headless stand-in for CAD.Features.Sketch, avoiding OCCT in core tests. }
  TSketchEvaluator = class(TCADFeature)
  protected
    procedure DefineParams; override;
    function Compute(const AInputs: array of TCADResult;
      out AResult: TCADResult; out AError: string): Boolean; override;
  public
    class function TypeName: string; override;
  end;
  TNotSketch = class(TSketchEvaluator)
  public
    class function TypeName: string; override;
  end;

var
  Checks, Failures: Integer;

procedure Check(Condition: Boolean; const Name: string);
begin
  Inc(Checks);
  if not Condition then
  begin
    Inc(Failures);
    WriteLn('FAIL  ',Name);
  end;
end;

class function TSketchEvaluator.TypeName: string;
begin
  Result := 'Sketch';
end;

class function TNotSketch.TypeName: string;
begin
  Result := 'NotSketch';
end;

procedure TSketchEvaluator.DefineParams;
begin
  AddParam('geometry',CADText('FPCSKETCH 1'));
end;

function TSketchEvaluator.Compute(const AInputs: array of TCADResult;
  out AResult: TCADResult; out AError: string): Boolean;
begin
  AResult := TCADResult.Create;
  AError := '';
  Result := True;
end;

procedure TestBindings;
var
  Doc: TCADDocument;
  History: TCADHistory;
  S1, S2: TCADObjectId;
  F1, F2, Other: TCADId;
  E: string;
  O1, O2: TCADModelObject;
  R: QWord;
  Command: TCADBindSketchFeatureCommand;
  Detached: TCADFeature;
begin
  Doc := TCADDocument.Create;
  History := TCADHistory.Create(Doc);
  try
    Check(Doc.Objects.TryAddSketch(
      CADObjectRef(cokPart,Doc.Objects.PartId),
      CADObjectRef(cokDatumPlane,Doc.Objects.XYPlaneId),
      'Sketch001',S1,E),'BIND-001 create Sketch 1');
    Check(Doc.Objects.TryAddSketch(
      CADObjectRef(cokPart,Doc.Objects.PartId),
      CADObjectRef(cokDatumPlane,Doc.Objects.XZPlaneId),
      'Sketch002',S2,E),'BIND-002 create Sketch 2');
    O1 := Doc.Objects.Find(CADObjectRef(cokSketch,S1));
    O2 := Doc.Objects.Find(CADObjectRef(cokSketch,S2));
    Check(not CADIdValid(O1.SketchFeatureId) and
      (O1.Kind=cokSketch),'BIND-003 unbound Sketch has no evaluator');
    F1 := Doc.AttachFeature(TSketchEvaluator.Create);
    F2 := Doc.AttachFeature(TSketchEvaluator.Create);
    Other := Doc.AttachFeature(TNotSketch.Create);
    Check(not Doc.TryBindSketchFeature(CADObjectRef(cokSketch,S1),Other,E),
      'BIND-004 rejects non-Sketch evaluator');
    Command := TCADBindSketchFeatureCommand.Create(
      CADObjectRef(cokSketch,S1),F1);
    Check(History.Execute(Command) and
      CADIdEqual(O1.SketchFeatureId,F1),'BIND-005 bind through History');
    Check(CADSameObjectId(Doc.Objects.SketchFeatureOwner(F1),S1),
      'BIND-006 reverse binding lookup');
    R := Doc.ObjectRevision;
    Check(not Doc.TryBindSketchFeature(CADObjectRef(cokSketch,S2),F1,E) and
      (Doc.ObjectRevision=R),'BIND-007 reject duplicate evaluator without edits');
    Check(not Doc.TrySetBodyTip(
      CADObjectRef(cokBody,CADNoObjectId),F1,E),
      'BIND-008 invalid Body rejected');
    Check(Doc.DetachFeature(F1)=nil,
      'BIND-008 attached evaluator cannot detach');
    Check(not Doc.Objects.TryRemove(CADObjectRef(cokSketch,S1),E),
      'BIND-009 bound Sketch cannot be deleted');
    Check(History.Undo and not CADIdValid(O1.SketchFeatureId),
      'BIND-010 undo clears binding');
    Check(History.Redo and CADIdEqual(O1.SketchFeatureId,F1),
      'BIND-011 redo preserves feature ID');
    Check(Doc.SetParam(F1,'geometry',CADText('FPCSKETCH 2')),
      'BIND-012 edit canonical geometry through feature');
    Check(Doc.Find(O1.SketchFeatureId).GetParamValue('geometry').S=
      'FPCSKETCH 2','BIND-013 sketch object resolves same geometry');
    Check(History.Execute(TCADBindSketchFeatureCommand.Create(
      CADObjectRef(cokSketch,S2),F2)),
      'BIND-014 independent second binding');
    Check(CADIdEqual(O1.SketchFeatureId,F1) and
      CADIdEqual(O2.SketchFeatureId,F2),'BIND-015 isolation');
    Check(History.Undo and not CADIdValid(O2.SketchFeatureId) and
      CADIdEqual(O1.SketchFeatureId,F1),'BIND-016 undo isolation');
    Check(History.Undo and not CADIdValid(O1.SketchFeatureId),
      'BIND-017 undo first Sketch binding');
    Detached := Doc.DetachFeature(F1);
    Check(Detached<>nil and (Doc.Find(F1)=nil),
      'BIND-018 unbound evaluator can detach');
    Detached.Free;
    Check(Doc.Objects.TryRemove(CADObjectRef(cokSketch,S1),E),
      'BIND-019 unbound Sketch can be deleted');
  finally
    History.Free;
    Doc.Free;
  end;
end;

begin
  TestBindings;
  if Failures=0 then
    WriteLn('PASS: CAD Sketch binding (',Checks,' checks)')
  else
    WriteLn('FAIL: CAD Sketch binding (',Failures,'/',Checks,')');
  if Failures<>0 then Halt(1);
end.
