unit CAD.App.FeatureTree;
{$mode objfpc}{$H+}
{$codepage utf8}

{ ROLE:      Model tree from the document's logical object registry:
             real Part, Origin, Datum planes, Body histories and Sketches.
             Legacy unowned features remain visible for compatibility.
             Sketch node activation still uses its evaluator Feature ID.
  CALLED BY: CAD.App.Controller (after every rebuild).
  CALLS:     CAD.Core.Document / ObjectModel, engine TreeView.
  THREADS:   UI thread.
  SPEED:     rebuilt only when Document or ObjectModel revision changes. }

interface

uses
  Classes, SysUtils,
  OpenGL.ECS.Widgets,
  CAD.Core.Ids, CAD.Core.ObjectIds, CAD.Core.ObjectModel,
  CAD.Core.Feature, CAD.Core.Document,
  CAD.Features.Sketch, CAD.Features.Extrude, CAD.App.DesignLookup;

type
  TCADFeatureEvent = procedure(Sender: TObject; const AId: TCADId) of object;
  TCADBodyEvent = procedure(Sender: TObject; const AId: TCADObjectId) of object;

  TCADFeatureTree = class
  private
    FTree: TUITreeView;
    FIcons: TUIImageList;
    FRevision, FObjectRevision: QWord;
    FHasRevision: Boolean;
    FOnEditFeature: TCADFeatureEvent;
    FOnSelectBody: TCADBodyEvent;
    procedure Activate(Sender: TObject);
    procedure AddFeature(ADoc: TCADDocument; AParent: TUITreeNode; F: TCADFeature;
      ADepth: Integer);
  public
    constructor Create(ALookup: TCADWidgetLookup; const AIconFolder: string);
    destructor Destroy; override;
    { Rebuilds the tree when the document changed (AForce: always). }
    procedure Refresh(ADoc: TCADDocument; AForce: Boolean = False);
    property OnEditFeature: TCADFeatureEvent read FOnEditFeature write FOnEditFeature;
    property OnSelectBody: TCADBodyEvent read FOnSelectBody write FOnSelectBody;
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
  { TUITreeView.RowClicked selects the node and fires OnChange from
    SetSelectedNode. The inherited OnClick is NOT sent by row buttons.
    OnActivate remains for Enter on an already selected node. }
  FTree.OnChange := @Activate;
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
  Part, N, BodyNode, HistoryNode: TUITreeNode;
  S, I, J, K: LongInt;
  F, Input: TCADFeature;
  O, ParentObject, SketchObject: TCADModelObject;
  ReferencedSketches: array of Boolean;

  procedure AddObjectNode(AParent: TUITreeNode;
    AObject: TCADModelObject; const AIcon: string);
  var
    T: TUITreeNode;
  begin
    T := FTree.AddChild(AParent,UTF8String(AObject.Name),AIcon);
    T.Tag := NoFeatureTag;
  end;

  procedure AddSketchReference(AParent: TUITreeNode;
    ASketch: TCADModelObject);
  var
    T: TUITreeNode;
    Evaluator: TCADFeature;
  begin
    T := FTree.AddChild(AParent,UTF8String(ASketch.Name),'edit-sketch');
    Evaluator := ADoc.Find(ASketch.SketchFeatureId);
    if Evaluator <> nil then T.Tag := Evaluator.Id.Slot
    else T.Tag := NoFeatureTag;
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

  for I := 0 to ADoc.Objects.ObjectCount-1 do
  begin
    O := ADoc.Objects.ObjectAt(I);
    if (not O.Active) or
       (not CADSameObjectId(O.PartId,ParentObject.Id)) then Continue;
    if O.Kind = cokOrigin then AddObjectNode(Part,O,'origin');
  end;
  for I := 0 to ADoc.Objects.ObjectCount-1 do
  begin
    O := ADoc.Objects.ObjectAt(I);
    if (not O.Active) or
       (not CADSameObjectId(O.PartId,ParentObject.Id)) then Continue;
    if O.Kind = cokDatumPlane then AddObjectNode(Part,O,'plane');
  end;

  { This is a presentation relationship, not a change of Sketch ownership.
    Sketch evaluators stay independent, and several Bodies may depend on
    the same Sketch. A referenced Sketch appears under each consuming
    operation; only unreferenced Sketches remain directly under Part. }
  SetLength(ReferencedSketches,ADoc.Objects.ObjectCount);
  for I := 0 to ADoc.Objects.ObjectCount-1 do
  begin
    O := ADoc.Objects.ObjectAt(I);
    if (not O.Active) or (O.Kind <> cokBody) or
       (not CADSameObjectId(O.PartId,ParentObject.Id)) then Continue;
    BodyNode := FTree.AddChild(Part,UTF8String(O.Name),'part');
    BodyNode.Tag := -2 - LongInt(O.Id.Value);
    HistoryNode := FTree.AddChild(BodyNode,'History','history');
    HistoryNode.Tag := NoFeatureTag;
    for J := 0 to O.FeatureCount-1 do
    begin
      F := ADoc.Find(O.FeatureAt(J));
      if F = nil then Continue;
      N := FTree.AddChild(HistoryNode,UTF8String(F.Name),IconOf(F));
      N.Tag := F.Id.Slot;
      { Follow the actual graph edges instead of guessing by name or
        creation order. This also keeps old projects and multiple Bodies
        deterministic after Undo/Redo. }
      for K := 0 to High(F.Inputs) do
      begin
        Input := ADoc.Find(F.Inputs[K]);
        if Input = nil then Continue;
        SketchObject := ADoc.Objects.Find(CADObjectRef(cokSketch,
          ADoc.Objects.SketchFeatureOwner(Input.Id)));
        if SketchObject = nil then Continue;
        AddSketchReference(N,SketchObject);
        if (SketchObject.Id.Value >= 1) and
           (SketchObject.Id.Value <= QWord(Length(ReferencedSketches))) then
          ReferencedSketches[Integer(SketchObject.Id.Value)-1] := True;
      end;
      N.Expanded := True;
    end;
    HistoryNode.Expanded := True;
    BodyNode.Expanded := True;
  end;

  { A free Sketch belongs to Part, e.g. one created before Extrude, or a
    Sketch whose Body operation has been undone. Never duplicate it there
    if an active Body feature references it. }
  for I := 0 to ADoc.Objects.ObjectCount-1 do
  begin
    O := ADoc.Objects.ObjectAt(I);
    if (not O.Active) or (O.Kind <> cokSketch) or
       (not CADSameObjectId(O.PartId,ParentObject.Id)) then Continue;
    if ReferencedSketches[I] then Continue;
    AddSketchReference(Part,O);
  end;

  { Show only genuinely unowned feature roots. Existing legacy Extrudes
    continue to work; sketch evaluators already bound to logical Sketches
    are shown by their logical nodes, not duplicated. }
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
  if N = nil then Exit;
  if N.Tag <= -3 then
  begin
    if Assigned(FOnSelectBody) then
      FOnSelectBody(Self,CADObjectId(QWord(-2-N.Tag)));
    Exit;
  end;
  if (N.Tag >= 0) and Assigned(FOnEditFeature) then
    FOnEditFeature(Self,CADId(LongInt(N.Tag)));
end;

end.
