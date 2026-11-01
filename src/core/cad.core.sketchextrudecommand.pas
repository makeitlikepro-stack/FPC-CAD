unit CAD.Core.SketchExtrudeCommand;
{$mode objfpc}{$H+}

{ One History entry owns the complete initial Sketch -> Extrude creation.
  Logical Sketch, evaluator and Body feature keep separate identities.
  Undo removes them in reverse dependency order; Redo restores the same IDs. }
interface

uses
  SysUtils, CAD.Core.Ids, CAD.Core.Feature, CAD.Core.ObjectIds,
  CAD.Core.ObjectModel, CAD.Core.Document, CAD.Core.Commands,
  CAD.Core.BodyFeatureCommands;

type
  TCADCreateSketchExtrudeCommand = class(TCADCommand)
  private
    FBody, FPart, FSupport: TCADObjectRef;
    FSketchName: string;
    FSketchFeature: TCADFeature;
    FSketchObjectId: TCADObjectId;
    FSketchFeatureId: TCADId;
    FExtrude: TCADAddBodyFeatureCommand;
    FExtrudeFeature: TCADFeature;
    FOwnsSketch, FOwnsExtrude: Boolean;
    FCreated, FDone: Boolean;
    FLastError: string;
    function SketchRef: TCADObjectRef;
  public
    constructor Create(const ABody, APart, ASupport: TCADObjectRef;
      ASketchFeature, AExtrudeFeature: TCADFeature);
    destructor Destroy; override;
    function DoIt(ADoc: TCADDocument): Boolean; override;
    procedure UndoIt(ADoc: TCADDocument); override;
    function Description: string; override;
    property SketchObjectId: TCADObjectId read FSketchObjectId;
    property SketchFeatureId: TCADId read FSketchFeatureId;
    function ExtrudeFeatureId: TCADId;
    property LastError: string read FLastError;
  end;

implementation

constructor TCADCreateSketchExtrudeCommand.Create(
  const ABody, APart, ASupport: TCADObjectRef;
  ASketchFeature, AExtrudeFeature: TCADFeature);
begin
  inherited Create;
  FBody := ABody;
  FPart := APart;
  FSupport := ASupport;
  FSketchFeature := ASketchFeature;
  FExtrudeFeature := AExtrudeFeature;
  FOwnsSketch := True;
  FOwnsExtrude := True;
  if FSketchFeature <> nil then FSketchName := FSketchFeature.Name;
  FSketchObjectId := CADNoObjectId;
  FSketchFeatureId := CADNoId;
end;

destructor TCADCreateSketchExtrudeCommand.Destroy;
begin
  FExtrude.Free;
  if FOwnsSketch then FSketchFeature.Free;
  if FOwnsExtrude then FExtrudeFeature.Free;
  inherited Destroy;
end;

function TCADCreateSketchExtrudeCommand.SketchRef: TCADObjectRef;
begin
  Result := CADObjectRef(cokSketch,FSketchObjectId);
end;

function TCADCreateSketchExtrudeCommand.ExtrudeFeatureId: TCADId;
begin
  Result := CADNoId;
  if FExtrude <> nil then Result := FExtrude.Id;
end;

function TCADCreateSketchExtrudeCommand.DoIt(ADoc: TCADDocument): Boolean;
var
  Obj: TCADModelObject;
  E: string;
  ObjectReady, FeatureReady, Bound: Boolean;
  Detached: TCADFeature;
begin
  Result := False;
  FLastError := '';
  if FDone or (ADoc = nil) or (FSketchFeature = nil) then Exit;
  Obj := ADoc.Objects.Find(FBody);
  if (Obj = nil) or (Obj.Kind <> cokBody) or (Obj.FeatureCount <> 0) then
  begin
    FLastError := 'target Body is missing or not empty';
    Exit;
  end;
  if (FPart.Kind <> cokPart) or (FSupport.Kind <> cokDatumPlane) or
     (ADoc.Objects.Find(FPart) = nil) or
     (ADoc.Objects.Find(FSupport) = nil) then
  begin
    FLastError := 'invalid Sketch Part or Datum support';
    Exit;
  end;

  ObjectReady := False;
  FeatureReady := False;
  Bound := False;
  try
    if not FCreated then
    begin
      if not ADoc.Objects.TryAddSketch(FPart,FSupport,FSketchName,
        FSketchObjectId,E) then
        raise Exception.Create('Create Sketch object: '+E);
    end
    else if not ADoc.Objects.TryRestore(SketchRef,E) then
      raise Exception.Create('Restore Sketch object: '+E);
    ObjectReady := True;

    if not FCreated then
      FSketchFeatureId := ADoc.AttachFeature(FSketchFeature)
    else if not ADoc.ReattachFeature(FSketchFeature) then
      raise Exception.Create('Reattach Sketch evaluator failed');
    FOwnsSketch := False;
    FeatureReady := True;

    if not ADoc.TryBindSketchFeature(SketchRef,FSketchFeatureId,E) then
      raise Exception.Create('Bind Sketch evaluator: '+E);
    Bound := True;

    if FExtrude = nil then
    begin
      FExtrude := TCADAddBodyFeatureCommand.Create(FBody,
        FExtrudeFeature,[FSketchFeatureId]);
      FOwnsExtrude := False;
    end;
    if not FExtrude.DoIt(ADoc) then
      raise Exception.Create('Add Extrude to Body history failed');
    FCreated := True;
    FDone := True;
    Exit(True);
  except
    on X: Exception do FLastError := X.Message;
  end;

  { Roll back without publishing a History entry. If cleanup fails,
    raise instead of pretending the document is consistent. }
  if Bound and not ADoc.TryBindSketchFeature(SketchRef,CADNoId,E) then
    raise Exception.Create('Atomic creation rollback (unbind): '+E);
  if FeatureReady then
  begin
    Detached := ADoc.DetachFeature(FSketchFeatureId);
    if Detached <> FSketchFeature then
      raise Exception.Create('Atomic creation rollback (detach evaluator)');
    FOwnsSketch := True;
  end;
  if ObjectReady and not ADoc.Objects.TryRemove(SketchRef,E) then
    raise Exception.Create('Atomic creation rollback (remove Sketch): '+E);
  { The new logical object's tombstone ID is retained for deterministic
    retry/Redo after a later successful execution. }
  if ObjectReady then FCreated := True;
end;

procedure TCADCreateSketchExtrudeCommand.UndoIt(ADoc: TCADDocument);
var
  E: string;
  Detached: TCADFeature;
begin
  if not FDone then
    raise Exception.Create('Sketch Extrude command is not active');
  if (ADoc.Find(FSketchFeatureId) <> FSketchFeature) or
     (ADoc.UserCount(FSketchFeatureId) <> 1) or
     (ADoc.Objects.Find(SketchRef) = nil) then
    raise Exception.Create('Cannot undo Sketch Extrude: dependencies changed');

  FExtrude.UndoIt(ADoc);
  if not ADoc.TryBindSketchFeature(SketchRef,CADNoId,E) then
  begin
    if not FExtrude.DoIt(ADoc) then
      raise Exception.Create('Undo rollback failed after Sketch unbind: '+E);
    raise Exception.Create('Cannot unbind Sketch during Undo: '+E);
  end;
  Detached := ADoc.DetachFeature(FSketchFeatureId);
  if Detached <> FSketchFeature then
    raise Exception.Create('Cannot detach Sketch evaluator during Undo');
  FOwnsSketch := True;
  if not ADoc.Objects.TryRemove(SketchRef,E) then
    raise Exception.Create('Cannot remove Sketch object during Undo: '+E);
  FDone := False;
end;

function TCADCreateSketchExtrudeCommand.Description: string;
begin
  Result := 'Create Sketch and Extrude in Body';
end;

end.
