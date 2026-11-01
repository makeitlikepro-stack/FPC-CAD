unit CAD.Core.FeatureEditCommand;
{$mode objfpc}{$H+}

{ One editor commit for Sketch geometry/contours and optional linked
  Extrude depth/direction. The document keeps owning both features. }
interface

uses
  SysUtils, Math, CAD.Core.Ids, CAD.Core.Values, CAD.Core.Feature,
  CAD.Core.ObjectIds, CAD.Core.ObjectModel, CAD.Core.Document,
  CAD.Core.Commands;

type
  TCADFeatureEditSnapshot = record
    Geometry, Contours: string;
    Depth: Double;
    Symmetric, Reversed: Boolean;
  end;

  TCADFeatureEditCommand = class(TCADCommand)
  private
    FSketch: TCADObjectRef;
    FSketchId, FExtrudeId: TCADId;
    FOld, FNew: TCADFeatureEditSnapshot;
    FHasExtrude, FCaptured: Boolean;
    function Resolve(ADoc: TCADDocument; out ASketch,
      AExtrude: TCADFeature): Boolean;
    function ReadSnapshot(ADoc: TCADDocument;
      out AValue: TCADFeatureEditSnapshot): Boolean;
    function EqualSnapshots(const A, B: TCADFeatureEditSnapshot): Boolean;
    procedure ApplySnapshot(ADoc: TCADDocument;
      const AValue: TCADFeatureEditSnapshot);
  public
    constructor Create(const ASketch: TCADObjectRef;
      const AExtrudeId: TCADId; const AGeometry, AContours: string;
      ADepth: Double; ASymmetric, AReversed: Boolean);
    function DoIt(ADoc: TCADDocument): Boolean; override;
    procedure UndoIt(ADoc: TCADDocument); override;
    function Description: string; override;
  end;

implementation

constructor TCADFeatureEditCommand.Create(const ASketch: TCADObjectRef;
  const AExtrudeId: TCADId; const AGeometry, AContours: string;
  ADepth: Double; ASymmetric, AReversed: Boolean);
begin
  inherited Create;
  FSketch := ASketch;
  FSketchId := CADNoId;
  FExtrudeId := AExtrudeId;
  FHasExtrude := CADIdValid(AExtrudeId);
  FNew.Geometry := AGeometry;
  FNew.Contours := AContours;
  FNew.Depth := ADepth;
  FNew.Symmetric := ASymmetric;
  FNew.Reversed := AReversed;
end;

function TCADFeatureEditCommand.Resolve(ADoc: TCADDocument;
  out ASketch, AExtrude: TCADFeature): Boolean;
var
  O: TCADModelObject;
  I: Integer;
  Found: Boolean;
begin
  ASketch := nil;
  AExtrude := nil;
  Result := False;
  if ADoc = nil then Exit;
  O := ADoc.Objects.Find(FSketch);
  if (O = nil) or (O.Kind <> cokSketch) or
     not CADIdValid(O.SketchFeatureId) then Exit;
  if FCaptured and not CADIdEqual(O.SketchFeatureId,FSketchId) then Exit;
  ASketch := ADoc.Find(O.SketchFeatureId);
  if (ASketch = nil) or (ASketch.TypeName <> 'Sketch') or
     not ASketch.HasParam('geometry') or
     not ASketch.HasParam('contours') or
     (ASketch.GetParamValue('geometry').Kind <> cvkText) or
     (ASketch.GetParamValue('contours').Kind <> cvkText) then Exit;
  if FHasExtrude then
  begin
    AExtrude := ADoc.Find(FExtrudeId);
    if (AExtrude = nil) or (AExtrude.TypeName <> 'Extrude') or
       not AExtrude.HasParam('length') or
       not AExtrude.HasParam('symmetric') or
       not AExtrude.HasParam('reversed') or
       (AExtrude.GetParamValue('length').Kind <> cvkFloat) or
       (AExtrude.GetParamValue('symmetric').Kind <> cvkBool) or
       (AExtrude.GetParamValue('reversed').Kind <> cvkBool) then Exit;
    Found := False;
    for I := 0 to High(AExtrude.Inputs) do
      if CADIdEqual(AExtrude.Inputs[I],ASketch.Id) then Found := True;
    if not Found then Exit;
  end;
  Result := True;
end;

function TCADFeatureEditCommand.ReadSnapshot(ADoc: TCADDocument;
  out AValue: TCADFeatureEditSnapshot): Boolean;
var
  S, X: TCADFeature;
begin
  Result := Resolve(ADoc,S,X);
  if not Result then Exit;
  AValue.Geometry := S.GetParamValue('geometry').S;
  AValue.Contours := S.GetParamValue('contours').S;
  if FHasExtrude then
  begin
    AValue.Depth := X.GetParamValue('length').F;
    AValue.Symmetric := X.GetParamValue('symmetric').B;
    AValue.Reversed := X.GetParamValue('reversed').B;
  end
  else
  begin
    AValue.Depth := FNew.Depth;
    AValue.Symmetric := FNew.Symmetric;
    AValue.Reversed := FNew.Reversed;
  end;
end;

function TCADFeatureEditCommand.EqualSnapshots(
  const A, B: TCADFeatureEditSnapshot): Boolean;
begin
  Result := (A.Geometry = B.Geometry) and
    (A.Contours = B.Contours) and
    ((not FHasExtrude) or
     ((A.Depth = B.Depth) and (A.Symmetric = B.Symmetric) and
      (A.Reversed = B.Reversed)));
end;

procedure TCADFeatureEditCommand.ApplySnapshot(ADoc: TCADDocument;
  const AValue: TCADFeatureEditSnapshot);
var
  S, X: TCADFeature;
begin
  if not Resolve(ADoc,S,X) then
    raise Exception.Create('Feature edit target or dependency changed');
  if not ADoc.SetParam(S.Id,'geometry',CADText(AValue.Geometry)) or
     not ADoc.SetParam(S.Id,'contours',CADText(AValue.Contours)) then
    raise Exception.Create('Feature edit: cannot set Sketch');
  if FHasExtrude then
    if not ADoc.SetParam(X.Id,'length',CADFloat(AValue.Depth)) or
       not ADoc.SetParam(X.Id,'symmetric',CADBool(AValue.Symmetric)) or
       not ADoc.SetParam(X.Id,'reversed',CADBool(AValue.Reversed)) then
      raise Exception.Create('Feature edit: cannot set Extrude');
end;

function TCADFeatureEditCommand.DoIt(ADoc: TCADDocument): Boolean;
var
  Current, Target: TCADFeatureEditSnapshot;
  S, X: TCADFeature;
begin
  Result := False;
  if FHasExtrude and (IsNan(FNew.Depth) or IsInfinite(FNew.Depth) or
     (FNew.Depth <= 0)) then Exit;
  if not ReadSnapshot(ADoc,Current) then Exit;
  if FCaptured and not EqualSnapshots(Current,FOld) then Exit;
  if EqualSnapshots(Current,FNew) then Exit;
  if not FCaptured then
  begin
    if not Resolve(ADoc,S,X) then Exit;
    FSketchId := S.Id;
  end;
  Target := Current;
  try
    ApplySnapshot(ADoc,FNew);
  except
    try
      ApplySnapshot(ADoc,Target);
    except
      on E: Exception do
        raise Exception.Create('Feature edit rollback failed: '+E.Message);
    end;
    Exit(False);
  end;
  if not FCaptured then FOld := Current;
  FCaptured := True;
  Result := True;
end;

procedure TCADFeatureEditCommand.UndoIt(ADoc: TCADDocument);
var
  Current: TCADFeatureEditSnapshot;
begin
  if not FCaptured or not ReadSnapshot(ADoc,Current) or
     not EqualSnapshots(Current,FNew) then
    raise Exception.Create('Undo Feature edit: target was changed');
  try
    ApplySnapshot(ADoc,FOld);
  except
    try
      ApplySnapshot(ADoc,Current);
    except
      on E: Exception do
        raise Exception.Create('Undo Feature edit rollback failed: '+E.Message);
    end;
    raise Exception.Create('Cannot undo Feature edit');
  end;
end;

function TCADFeatureEditCommand.Description: string;
begin
  Result := 'Edit Sketch and Extrude';
end;

end.
