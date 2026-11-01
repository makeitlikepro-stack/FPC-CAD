unit CAD.App.FeatureTree;
{$mode objfpc}{$H+}
{$codepage utf8}

{ ROLE:      the feature tree of the Model page (designed TreeView
             FeatureTree): Part1 with the origin and the three planes, then
             the document's features in creation order. A feature another
             one consumes is shown under it (SolidWorks: the sketch under
             its extrude, the boolean inputs under the boolean). Double click
             / Enter on a node asks to edit that feature (OnEditFeature).
  CALLED BY: CAD.App.Controller (after every rebuild).
  CALLS:     CAD.Core.Document, CAD.App.DesignLookup, engine TreeView.
  THREADS:   UI thread.
  SPEED:     rebuilt only when the document revision changed. }

interface

uses
  Classes, SysUtils,
  OpenGL.ECS.Widgets,
  CAD.Core.Ids, CAD.Core.ObjectIds, CAD.Core.ObjectModel,
  CAD.Core.Feature, CAD.Core.Document,
  CAD.Features.Sketch, CAD.Features.Extrude, CAD.App.DesignLookup;

type
  TCADFeatureEvent = procedure(Sender: TObject; const AId: TCADId) of object;

  TCADFeatureTree = class
  private
    FTree: TUITreeView;
    FIcons: TUIImageList;
    FRevision, FObjectRevision: QWord;
    FHasRevision: Boolean;
    FOnEditFeature: TCADFeatureEvent;
    procedure Activate(Sender: TObject);
    procedure AddFeature(ADoc: TCADDocument; AParent: TUITreeNode; F: TCADFeature;
      ADepth: Integer);
  public
    constructor Create(ALookup: TCADWidgetLookup; const AIconFolder: string);
    destructor Destroy; override;
    { Rebuilds the tree when the document changed (AForce: always). }
    procedure Refresh(ADoc: TCADDocument; AForce: Boolean = False);
    property OnEditFeature: TCADFeatureEvent read FOnEditFeature write FOnEditFeature;
  end;

implementation

const
  NoFeatureTag = -1;
  IconKeys: array[0..6] of string = ('part', 'origin', 'plane', 'edit-sketch', 'extrude',
    'cut', 'history');

constructor TCADFeatureTree.Create(ALookup: TCADWidgetLookup; const AIconFolder: string);
var
  K: string;
begin
  inherited Create;
  FTree := TUITreeView(CADDesignWidget(ALookup, 'FeatureTree', TUITreeView));
  FIcons := TUIImageList.Create;
  for K in IconKeys do
    if FileExists(AIconFolder + K + '.png') then
      FIcons.Add(K, AIconFolder + K + '.png');
  FTree.ImageList := FIcons;
  FTree.OnActivate := @Activate;
end;

destructor TCADFeatureTree.Destroy;
begin
  { the tree outlives this object (the form frees it): no dangling list }
  FTree.ImageList := nil;
  FIcons.Free;
  inherited Destroy;
end;

function IconOf(F: TCADFeature): string;
begin
  if F is TCADSketchFeature then
    Result := 'edit-sketch'
  else if F is TCADExtrudeFeature then
    Result := 'extrude'
  else if Length(F.Inputs) >= 2 then
    Result := 'cut'                        { booleans }
  else
    Result := 'part';
end;

procedure TCADFeatureTree.AddFeature(ADoc: TCADDocument; AParent: TUITreeNode;
  F: TCADFeature; ADepth: Integer);
var
  N: TUITreeNode;
  I: Integer;
  Input: TCADFeature;
begin
  if AParent = nil then
    N := FTree.AddRoot(UTF8String(F.Name), IconOf(F))
  else
    N := FTree.AddChild(AParent, UTF8String(F.Name), IconOf(F));
  N.Tag := F.Id.Slot;
  if ADepth > 32 then
    Exit;                                  { no runaway on a broken graph }
  for I := 0 to High(F.Inputs) do
  begin
    Input := ADoc.Find(F.Inputs[I]);
    if (Input <> nil) and
       (not CADObjectIdValid(ADoc.Objects.SketchFeatureOwner(Input.Id))) and
       (not CADObjectIdValid(ADoc.Objects.FeatureOwner(Input.Id))) then
      AddFeature(ADoc, N, Input, ADepth + 1);
  end;
  N.Expanded := F is TCADExtrudeFeature;
end;

procedure TCADFeatureTree.Refresh(ADoc: TCADDocument; AForce: Boolean);
var
  Part, N, BodyNode, SketchNode, HistoryNode: TUITreeNode;
  S, I, J: LongInt;
  F: TCADFeature;
  O, ParentObject: TCADModelObject;

  procedure AddObjectNode(AParent: TUITreeNode;
    AObject: TCADModelObject; const AIcon: string);
  var
    T: TUITreeNode;
  begin
    T := FTree.AddChild(AParent,UTF8String(AObject.Name),AIcon);
    T.Tag := NoFeatureTag;
  end;

begin
  if ADoc = nil then Exit;
  if not AForce and FHasRevision and (FRevision = ADoc.Revision) and
     (FObjectRevision = ADoc.Objects.Revision) then Exit;
  FRevision := ADoc.Revision;
  FObjectRevision := ADoc.Objects.Revision;
  FHasRevision := True;
  FTree.Clear;

  ParentObject := ADoc.Objects.Find(
    CADObjectRef(cokPart,ADoc.Objects.PartId));
  if ParentObject = nil then Exit;
  Part := FTree.AddRoot(UTF8String(ParentObject.Name),'part');
  Part.Tag := NoFeatureTag;

  { Datum objects and their labels always come from the document registry.
    No more separate hard-coded plane nodes or fictitious Body. }
  for I := 0 to ADoc.Objects.ObjectCount-1 do
  begin
    O := ADoc.Objects.ObjectAt(I);
    if (not O.Active) or
       (not CADSameObjectId(O.PartId,ParentObject.Id)) then Continue;
    if O.Kind = cokOrigin then
    begin
      AddObjectNode(Part,O,'origin');
    end;
  end;
  for I := 0 to ADoc.Objects.ObjectCount-1 do
  begin
    O := ADoc.Objects.ObjectAt(I);
    if (not O.Active) or
       (not CADSameObjectId(O.PartId,ParentObject.Id)) then Continue;
    if O.Kind = cokDatumPlane then AddObjectNode(Part,O,'plane');
  end;


  for I := 0 to ADoc.Objects.ObjectCount-1 do
  begin
    O := ADoc.Objects.ObjectAt(I);
    if (not O.Active) or (O.Kind <> cokBody) or
       (not CADSameObjectId(O.PartId,ParentObject.Id)) then Continue;
    BodyNode := FTree.AddChild(Part,UTF8String(O.Name),'part');
    BodyNode.Tag := NoFeatureTag;
    HistoryNode := FTree.AddChild(BodyNode,'History','history');
    HistoryNode.Tag := NoFeatureTag;
    for J := 0 to O.FeatureCount-1 do
    begin
      F := ADoc.Find(O.FeatureAt(J));
      if F = nil then Continue;
      N := FTree.AddChild(BodyNode,UTF8String(F.Name),IconOf(F));
      N.Tag := F.Id.Slot;
    end;
    BodyNode.Expanded := True;
  end;

  { Sketch objects have their own identity, support and evaluator reference.
    The evaluator's feature ID is retained as the node tag so existing
    double-click / Enter opens exactly the same Sketch editor. }
  for I := 0 to ADoc.Objects.ObjectCount-1 do
  begin
    O := ADoc.Objects.ObjectAt(I);
    if (not O.Active) or (O.Kind <> cokSketch) or
       (not CADSameObjectId(O.PartId,ParentObject.Id)) then Continue;
    SketchNode := FTree.AddChild(Part,UTF8String(O.Name),'edit-sketch');
    F := ADoc.Find(O.SketchFeatureId);
    if F <> nil then SketchNode.Tag := F.Id.Slot
    else SketchNode.Tag := NoFeatureTag;
  end;

  { Compatibility: existing non-Body features (e.g. Sketch -> Extrude from
    the current editor) still appear. A logically bound Sketch is not shown
    a second time inside its Extrude input subtree. }
  for S := 0 to ADoc.SlotCount-1 do
  begin
    F := ADoc.Find(CADId(S));
    if (F = nil) or (ADoc.UserCount(F.Id) <> 0) then Continue;
    if CADObjectIdValid(ADoc.Objects.FeatureOwner(F.Id)) or
       CADObjectIdValid(ADoc.Objects.SketchFeatureOwner(F.Id)) then Continue;
    AddFeature(ADoc,Part,F,0);
  end;
  Part.Expanded := True;
  FTree.RefreshLayout;
end;

procedure TCADFeatureTree.Activate(Sender: TObject);
var
  N: TUITreeNode;
begin
  N := FTree.SelectedNode;
  if (N = nil) or (N.Tag < 0) or not Assigned(FOnEditFeature) then
    Exit;
  FOnEditFeature(Self, CADId(LongInt(N.Tag)));
end;

end.
