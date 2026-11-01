program cad_sketch_binding_tests;
{$mode objfpc}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils, CAD.Core.Ids, CAD.Core.Values, CAD.Core.Feature,
  CAD.Core.Document, CAD.Core.ObjectIds, CAD.Core.ObjectModel,
  CAD.Core.History, CAD.Core.SketchBindingCommands,
  CAD.Core.SketchGeometryCommands, CAD.Core.FeatureEditCommand;

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
  TMockExtrude = class(TSketchEvaluator)
  protected
    procedure DefineParams; override;
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

class function TMockExtrude.TypeName: string;
begin
  Result := 'Extrude';
end;

procedure TMockExtrude.DefineParams;
begin
  AddParam('length',CADFloat(10));
  AddParam('symmetric',CADBool(False));
  AddParam('reversed',CADBool(False));
end;

class function TNotSketch.TypeName: string;
begin
  Result := 'NotSketch';
end;

procedure TSketchEvaluator.DefineParams;
begin
  AddParam('geometry',CADText('FPCSKETCH 1'));
  AddParam('contours',CADText('ALL'));
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
  S1, S2, BodyId: TCADObjectId;
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
    Check(Doc.Objects.TryAddBody(
      CADObjectRef(cokPart,Doc.Objects.PartId),'Body',BodyId,E),
      'BIND-008 creates Body for exclusivity test');
    Check(not Doc.TrySetBodyTip(CADObjectRef(cokBody,BodyId),F1,E),
      'BIND-008 bound Sketch evaluator cannot become Body tip');
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
    Check((Detached<>nil) and (Doc.Find(F1)=nil),
      'BIND-018 unbound evaluator can detach');
    Detached.Free;
    Check(Doc.Objects.TryRemove(CADObjectRef(cokSketch,S1),E),
      'BIND-019 unbound Sketch can be deleted');
  finally
    History.Free;
    Doc.Free;
  end;
end;


procedure TestTreeObjectEnumeration;
var
  D: TCADDocument;
  SId, BId: TCADObjectId;
  I, Visible: Integer;
  E: string;
  O: TCADModelObject;
begin
  D := TCADDocument.Create;
  try
    Check(D.Objects.ObjectCount = 5,
      'TREE-001 defaults contain Part, Origin and three Datum planes');
    Check((D.Objects.ObjectAt(0).Kind = cokPart) and
      (D.Objects.ObjectAt(1).Kind = cokOrigin) and
      (D.Objects.ObjectAt(2).Kind = cokDatumPlane),
      'TREE-002 stable object creation order');
    Check(D.Objects.TryAddBody(
      CADObjectRef(cokPart,D.Objects.PartId),'Body001',BId,E),
      'TREE-003 create Body');
    Check(D.Objects.TryAddSketch(
      CADObjectRef(cokPart,D.Objects.PartId),
      CADObjectRef(cokDatumPlane,D.Objects.XYPlaneId),
      'Sketch001',SId,E),'TREE-004 create Sketch');
    Check((D.Objects.ObjectCount = 7) and
      (D.Objects.ObjectAt(5).Kind = cokBody) and
      (D.Objects.ObjectAt(6).Kind = cokSketch),
      'TREE-005 enumerates logical Body and Sketch');
    Check(D.Objects.TryRemove(CADObjectRef(cokBody,BId),E),
      'TREE-006 remove Body as tombstone');
    Visible := 0;
    for I := 0 to D.Objects.ObjectCount-1 do
    begin
      O := D.Objects.ObjectAt(I);
      if O.Active then Inc(Visible);
    end;
    Check((D.Objects.ObjectCount=7) and (Visible=6) and
      (not D.Objects.ObjectAt(5).Active),
      'TREE-007 enumeration retains inactive tombstones for filtering');
    Check(D.Objects.TryRestore(CADObjectRef(cokBody,BId),E) and
      D.Objects.ObjectAt(5).Active,
      'TREE-008 restore keeps Body stable index');
  finally
    D.Free;
  end;
end;

procedure TestEditorCommit;
var
  D: TCADDocument;
  H: TCADHistory;
  SketchId: TCADObjectId;
  FeatureId, Other: TCADId;
  Rev, BeforeRev: QWord;
  E: string;
begin
  D := TCADDocument.Create;
  H := TCADHistory.Create(D);
  try
    Check(D.Objects.TryAddSketch(
      CADObjectRef(cokPart,D.Objects.PartId),
      CADObjectRef(cokDatumPlane,D.Objects.XYPlaneId),
      'CommitSketch',SketchId,E),'COMMIT-001 logical Sketch created');
    FeatureId := D.AttachFeature(TSketchEvaluator.Create);
    Other := D.AttachFeature(TSketchEvaluator.Create);
    Check(D.TryBindSketchFeature(CADObjectRef(cokSketch,SketchId),
      FeatureId,E),'COMMIT-002 evaluator bound');
    D.Recompute;
    BeforeRev := D.Revision;
    Check(H.Execute(TCADCommitSketchCommand.Create(
      CADObjectRef(cokSketch,SketchId),'FPCSKETCH 2','seed:10')),
      'COMMIT-003 geometry and contours updated together');
    Check((D.Find(FeatureId).GetParamValue('geometry').S='FPCSKETCH 2') and
      (D.Find(FeatureId).GetParamValue('contours').S='seed:10'),
      'COMMIT-004 canonical values in evaluator');
    Check((D.Revision>BeforeRev) and D.NeedsRecompute,
      'COMMIT-005 downstream recompute triggered');
    Check(H.Undo and
      (D.Find(FeatureId).GetParamValue('geometry').S='FPCSKETCH 1') and
      (D.Find(FeatureId).GetParamValue('contours').S='ALL'),
      'COMMIT-006 undo restores both original values');
    Check(H.Redo and
      (D.Find(FeatureId).GetParamValue('geometry').S='FPCSKETCH 2') and
      (D.Find(FeatureId).GetParamValue('contours').S='seed:10'),
      'COMMIT-007 redo restores both edits');
    Rev := D.Revision;
    Check(not H.Execute(TCADCommitSketchCommand.Create(
      CADObjectRef(cokSketch,SketchId),'FPCSKETCH 2','seed:10')) and
      (D.Revision=Rev),
      'COMMIT-008 unchanged editor commit has no History entry');
    Check(H.Undo and H.CanRedo,'COMMIT-009 undo remains available');
    D.SetParam(FeatureId,'geometry',CADText('external edit'));
    Rev := D.Revision;
    Check(not H.Redo and H.CanRedo and (D.Revision=Rev),
      'COMMIT-010 redo rejects stale geometry without data loss');
    Check((D.Find(Other) <> nil) and
      (not CADObjectIdValid(D.Objects.SketchFeatureOwner(Other))),
      'COMMIT-011 other evaluator unaffected');
    Check(not H.Execute(TCADCommitSketchCommand.Create(
      CADObjectRef(cokSketch,CADNoObjectId),'abc','ALL')),
      'COMMIT-012 invalid Sketch object rejected');
  finally
    H.Free;
    D.Free;
  end;
end;

procedure TestAtomicFeatureEdit;
var
  D: TCADDocument;
  H: TCADHistory;
  SId: TCADObjectId;
  S, X: TCADId;
  E: string;
  Rev: QWord;
begin
  D := TCADDocument.Create;
  H := TCADHistory.Create(D);
  try
    Check(D.Objects.TryAddSketch(CADObjectRef(cokPart,D.Objects.PartId),
      CADObjectRef(cokDatumPlane,D.Objects.XYPlaneId),
      'EditableSketch',SId,E),'EDIT-001 logical Sketch');
    S := D.AttachFeature(TSketchEvaluator.Create);
    Check(D.TryBindSketchFeature(CADObjectRef(cokSketch,SId),S,E),
      'EDIT-002 evaluator bound');
    X := D.AttachFeature(TMockExtrude.Create);
    Check(D.TryLink(X,S,E),'EDIT-003 Extrude input linked');
    Check(H.Execute(TCADFeatureEditCommand.Create(
      CADObjectRef(cokSketch,SId),X,'changed geometry','1,2,3',
      25,True,True)),'EDIT-004 combined edit one History entry');
    Check((D.Find(S).GetParamValue('geometry').S='changed geometry') and
      (D.Find(S).GetParamValue('contours').S='1,2,3') and
      (D.Find(X).GetParamValue('length').F=25) and
      D.Find(X).GetParamValue('symmetric').B and
      D.Find(X).GetParamValue('reversed').B,
      'EDIT-005 all five parameters updated');
    Check(H.Undo,'EDIT-006 single Undo');
    Check((D.Find(S).GetParamValue('geometry').S='FPCSKETCH 1') and
      (D.Find(S).GetParamValue('contours').S='ALL') and
      (D.Find(X).GetParamValue('length').F=10) and
      (not D.Find(X).GetParamValue('symmetric').B) and
      (not D.Find(X).GetParamValue('reversed').B),
      'EDIT-007 entire snapshot restored');
    Check(H.Redo,'EDIT-008 single Redo');
    Check((D.Find(S).GetParamValue('geometry').S='changed geometry') and
      (D.Find(X).GetParamValue('length').F=25),
      'EDIT-009 combined edit reapplied');
    Rev := D.Revision;
    Check(not H.Execute(TCADFeatureEditCommand.Create(
      CADObjectRef(cokSketch,SId),X,'changed geometry','1,2,3',
      25,True,True)) and (D.Revision=Rev),
      'EDIT-010 no-op does not make History entry');
    Check(H.Execute(TCADFeatureEditCommand.Create(
      CADObjectRef(cokSketch,SId),X,'changed geometry','1,2,3',
      30,True,True)),'EDIT-011 depth-only edit tracked');
    Check(H.Undo and (D.Find(X).GetParamValue('length').F=25),
      'EDIT-012 depth-only Undo');
    Check(H.Redo and (D.Find(X).GetParamValue('length').F=30),
      'EDIT-013 depth-only Redo');
    Rev := D.Revision;
    Check(not H.Execute(TCADFeatureEditCommand.Create(
      CADObjectRef(cokSketch,SId),X,'other geometry','ALL',
      -5,True,True)) and (D.Revision=Rev),
      'EDIT-014 invalid depth rejected before mutation');
    Check(not H.Execute(TCADFeatureEditCommand.Create(
      CADObjectRef(cokSketch,SId),CADId(99999),'other geometry','ALL',
      25,True,True)) and (D.Revision=Rev),
      'EDIT-015 missing Extrude rejected before mutation');
    Check(H.Undo and H.CanRedo,'EDIT-016 Undo creates redo entry');
    Check(D.SetParam(S,'geometry',CADText('external modification')),
      'EDIT-017 external geometry modification');
    Rev := D.Revision;
    Check(not H.Redo and H.CanRedo and (D.Revision=Rev),
      'EDIT-018 stale Redo refused without mutation');
  finally
    H.Free;
    D.Free;
  end;
end;

begin
  TestBindings;
  TestEditorCommit;
  TestAtomicFeatureEdit;
  TestTreeObjectEnumeration;
  if Failures=0 then
    WriteLn('PASS: CAD Sketch binding (',Checks,' checks)')
  else
    WriteLn('FAIL: CAD Sketch binding (',Failures,'/',Checks,')');
  if Failures<>0 then Halt(1);
end.
