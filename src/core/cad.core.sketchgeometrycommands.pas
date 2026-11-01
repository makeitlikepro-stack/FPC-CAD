unit CAD.Core.SketchGeometryCommands;
{$mode objfpc}{$H+}

{ Editor commit: one Undo entry for geometry and selected contours.
  The bound Sketch evaluator parameter remains the single canonical store.
  Sketch edits are snapshots; the editor never holds a writable document ptr. }
interface

uses
  SysUtils, CAD.Core.Ids, CAD.Core.Values, CAD.Core.ObjectIds,
  CAD.Core.ObjectModel, CAD.Core.Feature, CAD.Core.Document, CAD.Core.Commands;

type
  TCADCommitSketchCommand = class(TCADCommand)
  private
    FSketch: TCADObjectRef;
    FFeature: TCADId;
    FNewGeometry, FNewContours: string;
    FOldGeometry, FOldContours: string;
    FCaptured: Boolean;
    function BoundFeature(ADoc: TCADDocument): TCADFeature;
  public
    constructor Create(const ASketch: TCADObjectRef;
      const AGeometry, AContours: string);
    function DoIt(ADoc: TCADDocument): Boolean; override;
    procedure UndoIt(ADoc: TCADDocument); override;
    function Description: string; override;
  end;

implementation

constructor TCADCommitSketchCommand.Create(const ASketch: TCADObjectRef;
  const AGeometry, AContours: string);
begin
  inherited Create;
  FSketch := ASketch;
  FFeature := CADNoId;
  FNewGeometry := AGeometry;
  FNewContours := AContours;
end;

function TCADCommitSketchCommand.BoundFeature(
  ADoc: TCADDocument): TCADFeature;
var
  O: TCADModelObject;
begin
  Result := nil;
  O := ADoc.Objects.Find(FSketch);
  if (O = nil) or (O.Kind <> cokSketch) or
     not CADIdValid(O.SketchFeatureId) then Exit;
  if FCaptured and not CADIdEqual(O.SketchFeatureId,FFeature) then Exit;
  Result := ADoc.Find(O.SketchFeatureId);
  if Result = nil then Exit;
  if (Result.TypeName <> 'Sketch') or
     not Result.HasParam('geometry') or
     not Result.HasParam('contours') or
     (Result.GetParamValue('geometry').Kind <> cvkText) or
     (Result.GetParamValue('contours').Kind <> cvkText) then Result := nil;
end;

function TCADCommitSketchCommand.DoIt(ADoc: TCADDocument): Boolean;
var
  F: TCADFeature;
  CurGeometry, CurContours: string;
begin
  Result := False;
  F := BoundFeature(ADoc);
  if F = nil then Exit;
  CurGeometry := F.GetParamValue('geometry').S;
  CurContours := F.GetParamValue('contours').S;
  if FCaptured then
  begin
    { Redo is valid only against the state produced by this command's Undo. }
    if (CurGeometry <> FOldGeometry) or (CurContours <> FOldContours) then Exit;
  end
  else
  begin
    FOldGeometry := CurGeometry;
    FOldContours := CurContours;
    FFeature := F.Id;
  end;
  if (CurGeometry = FNewGeometry) and (CurContours = FNewContours) then Exit;
  { Both parameters have been validated as text before the first mutation.
    SetParam cannot reject these values for a live evaluator feature. }
  if not ADoc.SetParam(F.Id,'geometry',CADText(FNewGeometry)) then Exit;
  if not ADoc.SetParam(F.Id,'contours',CADText(FNewContours)) then
  begin
    ADoc.SetParam(F.Id,'geometry',CADText(CurGeometry));
    Exit;
  end;
  FCaptured := True;
  Result := True;
end;

procedure TCADCommitSketchCommand.UndoIt(ADoc: TCADDocument);
var
  F: TCADFeature;
begin
  F := BoundFeature(ADoc);
  if (F = nil) or
     (F.GetParamValue('geometry').S <> FNewGeometry) or
     (F.GetParamValue('contours').S <> FNewContours) then
    raise Exception.Create('Undo Sketch commit: evaluator or geometry changed');
  if not ADoc.SetParam(F.Id,'geometry',CADText(FOldGeometry)) or
     not ADoc.SetParam(F.Id,'contours',CADText(FOldContours)) then
    raise Exception.Create('Undo Sketch commit: cannot restore snapshot');
end;

function TCADCommitSketchCommand.Description: string;
begin
  Result := 'Commit Sketch geometry';
end;

end.
