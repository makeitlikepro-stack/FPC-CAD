program cad_object_model_tests;
{$mode objfpc}{$H+}
{ Headless Part/Body/Sketch/Datum ownership and command/history regression. }
uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils, CAD.Core.ObjectIds, CAD.Core.ObjectModel, CAD.Core.Document,
  CAD.Core.ObjectCommands, CAD.Core.History;

var
  Checks, Failures: Integer;

procedure Check(AOk: Boolean; const AName: string);
begin
  Inc(Checks);
  if not AOk then
  begin
    Inc(Failures);
    WriteLn('FAIL  ',AName);
  end;
end;

function Ref(AKind: TCADObjectKind; AId: TCADObjectId): TCADObjectRef;
begin
  Result := CADObjectRef(AKind,AId);
end;

procedure TestDefaultPartAndDatums;
var
  D: TCADDocument;
  M: TCADObjectModel;
  XY,XZ,YZ: TCADModelObject;
  E: string;
  R: TCADRecomputeReport;
  PendingBefore: Boolean;
begin
  D := TCADDocument.Create;
  try
    M := D.Objects;
    Check(M <> nil,'OM-001: document has logical object registry');
    Check((M.ActiveCount(cokPart)=1) and
      (M.ActiveCount(cokOrigin)=1) and
      (M.ActiveCount(cokDatumPlane)=3),
      'OM-001: default Part, Origin and three datums are real objects');
    Check((M.PartId.Value<>M.OriginId.Value) and
      (M.XYPlaneId.Value<>M.XZPlaneId.Value) and
      (M.XZPlaneId.Value<>M.YZPlaneId.Value) and
      (M.XYPlaneId.Value<>M.YZPlaneId.Value) and
      (M.NextId=6),
      'OM-001: nonzero distinct persistent IDs');
    XY := M.Find(Ref(cokDatumPlane,M.XYPlaneId));
    XZ := M.Find(Ref(cokDatumPlane,M.XZPlaneId));
    YZ := M.Find(Ref(cokDatumPlane,M.YZPlaneId));
    Check((XY<>nil) and (XZ<>nil) and (YZ<>nil),
      'OM-001: datum IDs resolve to typed objects');
    if (XY<>nil) and (XZ<>nil) and (YZ<>nil) then
      Check((XY.Frame.Normal[2]=1) and
        (XZ.Frame.Normal[1]=-1) and
        (YZ.Frame.Normal[0]=1),
        'OM-001: orthogonal reference planes retain correct normals');
    Check(not M.TryRemove(Ref(cokDatumPlane,M.XYPlaneId),E) and
      (Pos('default',E)>0),
      'OM-008: default reference datum cannot be deleted');
    Check(not M.TryRename(Ref(cokPart,M.PartId),'Else',E),
      'OM-008: default part is protected');
    PendingBefore := D.NeedsRecompute;
    R := D.Recompute;
    Check((not PendingBefore) and (R.Planned=0),
      'OM-012: logical default objects do not recompute features');
    Check(D.ObjectRevision=M.Revision,
      'OM-001: document exposes separate logical-object revision');
  finally D.Free; end;
end;

procedure TestBodyLifetimeAndNames;
var
  D: TCADDocument;
  M: TCADObjectModel;
  A,B,C: TCADObjectId;
  O: TCADModelObject;
  E: string;
  RevisionBefore, NextBefore: QWord;
begin
  D := TCADDocument.Create;
  try
    M := D.Objects;
    Check(M.TryAddBody(Ref(cokPart,M.PartId),'Body001',A,E) and
      M.TryAddBody(Ref(cokPart,M.PartId),'Body002',B,E),
      'OM-002: create two independent Bodies');
    Check((A.Value<>B.Value) and
      (M.ActiveCount(cokBody)=2),
      'OM-002: Body IDs unique and Part membership tracked');
    RevisionBefore := M.Revision;
    Check(not M.TryRename(Ref(cokBody,B),'Body002',E) and
      (M.Revision=RevisionBefore),
      'OM-007: identical rename is a no-op without revision bump');
    Check(not M.TrySetVisible(Ref(cokBody,B),True,E) and
      (M.Revision=RevisionBefore),
      'OM-007: identical visibility is a no-op without revision bump');
    Check(D.ObjectRevision=M.Revision,
      'OM-007: document object revision tracks registry changes');
    O := M.Find(Ref(cokBody,B));
    if O <> nil then
      Check(CADSameObjectId(O.PartId,M.PartId),
        'OM-002: Body belongs to default Part');
    Check(M.Find(Ref(cokSketch,A))=nil,
      'OM-004: Body ID cannot be read as Sketch');
    Check(not M.TryRename(Ref(cokSketch,A),'Wrong',E) and
      (Pos('wrong',E)>0),
      'OM-004: wrong-kind edit rejected with explicit error');
    RevisionBefore := M.Revision;
    NextBefore := M.NextId;
    Check(not M.TryAddBody(Ref(cokBody,A),'Broken',C,E) and
      (M.NextId=NextBefore) and (M.Revision=RevisionBefore),
      'OM-010: invalid parent cannot allocate or change registry');
    Check(M.TryRemove(Ref(cokBody,A),E) and
      (M.Find(Ref(cokBody,A))=nil),
      'OM-003: deleted Body becomes an invalid tombstone');
    Check(M.TryAddBody(Ref(cokPart,M.PartId),'Body003',C,E) and
      (C.Value>A.Value) and (C.Value>B.Value),
      'OM-003: deletion never reuses an ObjectId');
    Check((M.Find(Ref(cokBody,B))<>nil) and
      (M.Find(Ref(cokBody,C))<>nil),
      'OM-003: other Bodies retain their identity');
    Check(M.TryRestore(Ref(cokBody,A),E) and
      (M.Find(Ref(cokBody,A))<>nil),
      'OM-009: restore revives same ID');
    Check(not M.TryRestore(Ref(cokBody,A),E) and
      (Pos('already',E)>0),
      'OM-009: cannot restore an already active object');
    Check(not M.TryRemove(Ref(cokBody,M.PartId),E),
      'OM-004: wrong-kind PartId cannot remove a Body');
    Check(not M.TrySetVisible(Ref(cokPart,M.PartId),False,E),
      'OM-007: visibility changes are restricted to Sketch/Body');
  finally D.Free; end;
end;

procedure TestSketchSupportAndAtomicFailure;
var
  D: TCADDocument;
  M: TCADObjectModel;
  A, Bad: TCADObjectId;
  NextBefore, RevisionBefore: QWord;
  O: TCADModelObject;
  E: string;
begin
  D := TCADDocument.Create;
  try
    M := D.Objects;
    Check(M.TryAddSketch(Ref(cokPart,M.PartId),
      Ref(cokDatumPlane,M.XYPlaneId),'Sketch001',A,E),
      'OM-005: sketch references a real datum');
    O := M.Find(Ref(cokSketch,A));
    if O<>nil then
    begin
      Check(CADSameObjectId(O.SupportId,M.XYPlaneId) and
        CADSameObjectId(O.PartId,M.PartId),
        'OM-005: sketch support and Part are stable IDs');
      Check((O.Frame.XDir[0]=1) and (O.Frame.XDir[1]=0) and
        (O.Frame.Normal[0]=0) and (O.Frame.Normal[2]=1),
        'OM-005: Sketch has a valid identity frame local to support Datum');
    end;
    Check(not M.TryRemove(Ref(cokDatumPlane,M.XYPlaneId),E),
      'OM-008: a datum referenced by Sketch cannot be removed');
    NextBefore := M.NextId;
    RevisionBefore := M.Revision;
    Check(not M.TryAddSketch(Ref(cokPart,M.PartId),
      Ref(cokDatumPlane,CADObjectId(987654)),
      'Bad Sketch',Bad,E) and
      (Bad.Value=0) and (M.NextId=NextBefore) and
      (M.Revision=RevisionBefore),
      'OM-006: missing Datum fails without any partial mutation');
    Check(not M.TryAddSketch(Ref(cokPart,M.PartId),
      Ref(cokBody,A),'Bad Sketch',Bad,E) and
      (M.NextId=NextBefore) and
      (M.Revision=RevisionBefore),
      'OM-004: support reference of wrong kind is rejected');
    Check(M.TryRemove(Ref(cokSketch,A),E) and
      M.TryRestore(Ref(cokSketch,A),E),
      'OM-009: sketch deletion/revival preserves support ID');
  finally D.Free; end;
end;

procedure TestHistoryTransactions;
var
  D: TCADDocument;
  H: TCADHistory;
  M: TCADObjectModel;
  C: TCADCreateBodyCommand;
  S: TCADCreateSketchCommand;
  B,SketchId: TCADObjectId;
  E: string;
  Rev: QWord;
  R: TCADRecomputeReport;
  PendingBefore: Boolean;
begin
  D := TCADDocument.Create;
  H := TCADHistory.Create(D);
  try
    M := D.Objects;
    C := TCADCreateBodyCommand.Create(Ref(cokPart,M.PartId),'BodyUndo');
    Check(H.Execute(C),'OM-009: create Body via existing command history');
    B := C.Id;
    Check(H.Execute(TCADRenameObjectCommand.Create(
      Ref(cokBody,B),'BodyRenamed')) and
      (M.Find(Ref(cokBody,B)).Name='BodyRenamed'),
      'OM-009: rename through history');
    Check(H.Execute(TCADShowObjectCommand.Create(
      Ref(cokBody,B),False)) and
      (not M.Find(Ref(cokBody,B)).Visible),
      'OM-009: visibility through history');
    Check(H.Undo and M.Find(Ref(cokBody,B)).Visible,
      'OM-009: undo visibility');
    Check(H.Undo and (M.Find(Ref(cokBody,B)).Name='BodyUndo'),
      'OM-009: undo rename');
    Check(H.Undo and (M.Find(Ref(cokBody,B))=nil),
      'OM-009: undo creation, remove same Body ID');
    Check(H.Redo and (M.Find(Ref(cokBody,B))<>nil),
      'OM-009: redo creation, restore same Body ID');
    Check(H.Redo and (M.Find(Ref(cokBody,B)).Name='BodyRenamed'),
      'OM-009: redo rename');
    Check(H.Redo and (not M.Find(Ref(cokBody,B)).Visible),
      'OM-009: redo visibility');
    Check(H.Execute(TCADRemoveObjectCommand.Create(Ref(cokBody,B))) and
      (M.Find(Ref(cokBody,B))=nil),
      'OM-009: remove through existing command history');
    Check(H.Undo and (M.Find(Ref(cokBody,B))<>nil),
      'OM-009: undo remove preserves ID');
    Check(H.Redo and (M.Find(Ref(cokBody,B))=nil),
      'OM-009: redo remove preserves tombstone');
    S := TCADCreateSketchCommand.Create(Ref(cokPart,M.PartId),
      Ref(cokDatumPlane,M.XYPlaneId),'SketchUndo');
    Check(H.Execute(S),'OM-009: create Sketch through command history');
    SketchId := S.Id;
    Check(H.Undo and (M.Find(Ref(cokSketch,SketchId))=nil),
      'OM-009: undo Sketch create');
    Check(H.Redo and (M.Find(Ref(cokSketch,SketchId))<>nil),
      'OM-009: redo Sketch create with same support and ID');
    PendingBefore := D.NeedsRecompute;
    R := D.Recompute;
    Check((not PendingBefore) and (R.Planned=0),
      'OM-007: object metadata/undo does not run feature computation');
  finally
    H.Free;
    D.Free;
  end;

  D := TCADDocument.Create;
  H := TCADHistory.Create(D);
  try
    M := D.Objects;
    Rev := M.Revision;
    Check(not H.Execute(TCADCreateSketchCommand.Create(
      Ref(cokPart,M.PartId),
      Ref(cokDatumPlane,CADObjectId(900000)),'Invalid')),
      'OM-010: invalid object creation is not committed to Undo');
    Check(not H.CanUndo and (M.Revision=Rev),
      'OM-010: failed command does not dirty model or history');
    Check(not M.TryRemove(Ref(cokPart,M.PartId),E),
      'OM-008: cannot remove default Part');
  finally
    H.Free;
    D.Free;
  end;
end;

procedure TestStressAndIndependentBodies;
var
  D: TCADDocument;
  M: TCADObjectModel;
  Ids: array[0..999] of TCADObjectId;
  More: TCADObjectId;
  I: Integer;
  E: string;
  NextBefore: QWord;
begin
  D := TCADDocument.Create;
  try
    M := D.Objects;
    for I := 0 to High(Ids) do
      if not M.TryAddBody(Ref(cokPart,M.PartId),
        'Body'+IntToStr(I),Ids[I],E) then
      begin
        Check(False,'OM-011: bulk create failed: '+E);
        Exit;
      end;
    Check(M.ActiveCount(cokBody)=1000,
      'OM-011: 1000 Bodies tracked without indexing collisions');
    for I:=0 to High(Ids) do
      if (I mod 2)=0 then
        if not M.TryRemove(Ref(cokBody,Ids[I]),E) then
        begin
          Check(False,'OM-011: bulk removal failed: '+E);
          Exit;
        end;
    Check(M.ActiveCount(cokBody)=500,
      'OM-011: half of the Bodies are still independent');
    NextBefore := M.NextId;
    for I := 0 to 99 do
      if not M.TryAddBody(Ref(cokPart,M.PartId),
        'New'+IntToStr(I),More,E) then
      begin
        Check(False,'OM-011: bulk append failed: '+E);
        Exit;
      end;
    Check((M.ActiveCount(cokBody)=600) and
      (M.NextId=NextBefore+100),
      'OM-011: next 100 IDs advance strictly without reuse');
    for I:=0 to High(Ids) do
      if (I mod 2)=0 then
      begin
        if M.Find(Ref(cokBody,Ids[I]))<>nil then
        begin
          Check(False,'OM-011: stale deleted ID resolved');
          Exit;
        end;
      end
      else if M.Find(Ref(cokBody,Ids[I]))=nil then
      begin
        Check(False,'OM-011: unrelated Body disappeared');
        Exit;
      end;
    Check(True,'OM-003/011: no deleted ID reused, all other Bodies intact');
  finally D.Free; end;
end;

begin
  Checks:=0; Failures:=0;
  TestDefaultPartAndDatums;
  TestBodyLifetimeAndNames;
  TestSketchSupportAndAtomicFailure;
  TestHistoryTransactions;
  TestStressAndIndependentBodies;
  if Failures=0 then
    WriteLn(Format('PASS: CAD object model foundation (%d checks)',[Checks]))
  else
    WriteLn(Format('FAIL: CAD object model foundation (%d/%d)',[Failures,Checks]));
  if Failures>0 then Halt(1);
end.
