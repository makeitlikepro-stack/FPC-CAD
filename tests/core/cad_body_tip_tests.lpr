program cad_body_tip_tests;
{$mode objfpc}{$H+}
uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils, CAD.Core.Ids, CAD.Core.Feature, CAD.Core.Document,
  CAD.Core.ObjectIds, CAD.Core.ObjectModel, CAD.Core.BodyTipCommands,
  CAD.Core.History;

type
  TSimpleFeature = class(TCADFeature)
  protected
    function Compute(const AInputs: array of TCADResult;
      out AResult: TCADResult; out AError: string): Boolean; override;
  public
    class function TypeName: string; override;
  end;

var Checks, Failed: Integer;

class function TSimpleFeature.TypeName: string;
begin
  Result := 'BodyTipTest';
end;

function TSimpleFeature.Compute(const AInputs: array of TCADResult;
  out AResult: TCADResult; out AError: string): Boolean;
begin
  AResult := TCADResult.Create;
  AError := '';
  Result := True;
end;

procedure Check(B: Boolean; const Name: string);
begin
  Inc(Checks);
  if not B then
  begin
    Inc(Failed);
    WriteLn('FAIL  ', Name);
  end;
end;

procedure TestOrderedBodyHistory;
var
  D: TCADDocument;
  H: TCADHistory;
  A, B: TCADObjectId;
  R, M, N, Other: TCADId;
  ObjA, ObjB: TCADModelObject;
  E: string;
  Rev: QWord;
begin
  D := TCADDocument.Create;
  H := TCADHistory.Create(D);
  try
    Check(D.Objects.TryAddBody(CADObjectRef(cokPart,D.Objects.PartId),
      'History A',A,E),'HIST-001: create A');
    Check(D.Objects.TryAddBody(CADObjectRef(cokPart,D.Objects.PartId),
      'History B',B,E),'HIST-001: create B');
    ObjA := D.Objects.Find(CADObjectRef(cokBody,A));
    ObjB := D.Objects.Find(CADObjectRef(cokBody,B));
    R := D.AttachFeature(TSimpleFeature.Create);
    M := D.AttachFeature(TSimpleFeature.Create);
    N := D.AttachFeature(TSimpleFeature.Create);
    Other := D.AttachFeature(TSimpleFeature.Create);
    Check(D.TryLink(M,R,E) and D.TryLink(N,M,E),
      'HIST-002: modifier graph linked');
    Check(H.Execute(TCADSetBodyTipCommand.Create(
      CADObjectRef(cokBody,A),R)),'HIST-003: append root');
    Check(H.Execute(TCADSetBodyTipCommand.Create(
      CADObjectRef(cokBody,A),M)),'HIST-003: append modifier');
    Check(H.Execute(TCADSetBodyTipCommand.Create(
      CADObjectRef(cokBody,A),N)),'HIST-003: append final');
    Check((ObjA.FeatureCount=3) and CADIdEqual(ObjA.FeatureAt(0),R) and
      CADIdEqual(ObjA.FeatureAt(1),M) and CADIdEqual(ObjA.FeatureAt(2),N),
      'HIST-004: ordered history is not inferred from graph');
    Check(CADSameObjectId(D.Objects.FeatureOwner(M),A) and
      (ObjB.FeatureCount=0),'HIST-005: feature has exactly one owner');
    Rev := D.ObjectRevision;
    Check(not D.TrySetBodyTip(CADObjectRef(cokBody,B),M,E) and
      (D.ObjectRevision=Rev) and (ObjB.FeatureCount=0),
      'HIST-006: cross-body duplicate rejected atomically');
    Check(D.DetachFeature(R)=nil and D.DetachFeature(M)=nil,
      'HIST-007: non-tip history features cannot detach');
    Check(not D.Unlink(M,R),
      'HIST-008: active history dependency cannot unlink');
    Check(not D.TrySetBodyTip(CADObjectRef(cokBody,A),R,E) and
      (ObjA.FeatureCount=3),
      'HIST-009: cannot skip two history steps');
    Check(H.Undo and (ObjA.FeatureCount=2) and
      CADIdEqual(ObjA.TipFeatureId,M),
      'HIST-010: undo removes last history entry');
    Check(H.Redo and (ObjA.FeatureCount=3) and
      CADIdEqual(ObjA.FeatureAt(2),N),
      'HIST-011: redo restores same feature ID and order');
    Check(H.Execute(TCADSetBodyTipCommand.Create(
      CADObjectRef(cokBody,B),Other)) and (ObjB.FeatureCount=1) and
      (ObjA.FeatureCount=3),
      'HIST-012: independent Body history');
    Check(H.Undo and (ObjB.FeatureCount=0) and (ObjA.FeatureCount=3),
      'HIST-013: undo B leaves A unchanged');
    Check(H.Undo and (ObjA.FeatureCount=2),
      'HIST-014: undo A truncates its own history');
    Check(H.Execute(TCADSetBodyTipCommand.Create(
      CADObjectRef(cokBody,B),N)) and
      CADSameObjectId(D.Objects.FeatureOwner(N),B),
      'HIST-015: removed history entry can move to another Body');
    Check(not H.Redo, 'HIST-016: fresh command clears redo branch');
    Check(CADIdEqual(ObjA.TipFeatureId,M) and
      CADIdEqual(ObjB.TipFeatureId,N),
      'HIST-017: independent tips remain stable');
  finally
    H.Free;
    D.Free;
  end;
end;

procedure TestTipHistory;
var
  D: TCADDocument;
  H: TCADHistory;
  BodyA, BodyB: TCADObjectId;
  RootA, ModifierA, RootB, Detached: TCADId;
  E: string;
begin
  D := TCADDocument.Create;
  H := TCADHistory.Create(D);
  try
    Check(D.Objects.TryAddBody(CADObjectRef(cokPart,D.Objects.PartId),
      'Body A',BodyA,E), 'TIP-001: create Body A');
    Check(D.Objects.TryAddBody(CADObjectRef(cokPart,D.Objects.PartId),
      'Body B',BodyB,E), 'TIP-001: create Body B');
    RootA := D.AttachFeature(TSimpleFeature.Create);
    ModifierA := D.AttachFeature(TSimpleFeature.Create);
    RootB := D.AttachFeature(TSimpleFeature.Create);
    Check(D.TryLink(ModifierA,RootA,E), 'TIP-002: modifier uses root');
    Check(H.Execute(TCADSetBodyTipCommand.Create(
      CADObjectRef(cokBody,BodyA),RootA)), 'TIP-003: set first tip');
    Check(H.Execute(TCADSetBodyTipCommand.Create(
      CADObjectRef(cokBody,BodyB),RootB)), 'TIP-003: independent second Body');
    Check(not D.TrySetBodyTip(CADObjectRef(cokBody,BodyA),RootB,E),
      'TIP-004: unrelated transition rejected');
    Check(H.Execute(TCADSetBodyTipCommand.Create(
      CADObjectRef(cokBody,BodyA),ModifierA)),
      'TIP-005: advance Body A tip');
    Check(CADIdEqual(D.Objects.Find(CADObjectRef(cokBody,BodyB)).TipFeatureId,RootB),
      'TIP-006: Body B unchanged');
    Check(D.DetachFeature(ModifierA)=nil,
      'TIP-007: cannot detach active tip');
    Check(not D.Objects.TryRemove(CADObjectRef(cokBody,BodyA),E),
      'TIP-008: cannot delete Body with active tip');
    Check(H.Undo and CADIdEqual(
      D.Objects.Find(CADObjectRef(cokBody,BodyA)).TipFeatureId,RootA),
      'TIP-009: undo restores previous tip');
    Check(H.Redo and CADIdEqual(
      D.Objects.Find(CADObjectRef(cokBody,BodyA)).TipFeatureId,ModifierA),
      'TIP-010: redo restores modifier tip');
    D.Recompute;
    Check(not D.NeedsRecompute and (D.SlotCount=3),
      'TIP-011: tip metadata adds no recompute or feature slots');
    Check(H.Undo,'TIP-012: restore root before clearing tip');
    Check(H.Undo,'TIP-012: undo Body B first tip');
    Check(H.Undo and not CADIdValid(
      D.Objects.Find(CADObjectRef(cokBody,BodyA)).TipFeatureId),
      'TIP-012: undo initial tip to empty');
    Detached := CADNoId;
    Check(D.TrySetBodyTip(CADObjectRef(cokBody,BodyA),Detached,E)=False,
      'TIP-013: no-op tip transition rejected');
  finally
    H.Free;
    D.Free;
  end;
end;

begin
  TestTipHistory;
  TestOrderedBodyHistory;
  if Failed=0 then
    WriteLn('PASS: CAD body tip ('+IntToStr(Checks)+' checks)')
  else
    WriteLn('FAIL: CAD body tip ('+IntToStr(Failed)+'/'+IntToStr(Checks)+')');
  if Failed<>0 then Halt(1);
end.
