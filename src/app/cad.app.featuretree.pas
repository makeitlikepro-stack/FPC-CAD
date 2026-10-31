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
  CAD.Core.Ids, CAD.Core.Feature, CAD.Core.Document,
  CAD.Features.Sketch, CAD.Features.Extrude, CAD.App.DesignLookup;

type
  TCADFeatureEvent = procedure(Sender: TObject; const AId: TCADId) of object;

  TCADFeatureTree = class
  private
    FTree: TUITreeView;
    FIcons: TUIImageList;
    FRevision: QWord;
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
    if Input <> nil then
      AddFeature(ADoc, N, Input, ADepth + 1);
  end;
  N.Expanded := F is TCADExtrudeFeature;
end;

procedure TCADFeatureTree.Refresh(ADoc: TCADDocument; AForce: Boolean);
var
  Part, N: TUITreeNode;
  S: LongInt;
  F: TCADFeature;
begin
  if ADoc = nil then
    Exit;
  if not AForce and FHasRevision and (FRevision = ADoc.Revision) then
    Exit;
  FRevision := ADoc.Revision;
  FHasRevision := True;
  FTree.Clear;
  Part := FTree.AddRoot('Part1', 'part');
  Part.Tag := NoFeatureTag;
  N := FTree.AddChild(Part, 'History', 'history');
  N.Tag := NoFeatureTag;
  N := FTree.AddChild(Part, 'Front Plane', 'plane');
  N.Tag := NoFeatureTag;
  N := FTree.AddChild(Part, 'Top Plane', 'plane');
  N.Tag := NoFeatureTag;
  N := FTree.AddChild(Part, 'Right Plane', 'plane');
  N.Tag := NoFeatureTag;
  N := FTree.AddChild(Part, 'Origin', 'origin');
  N.Tag := NoFeatureTag;
  { top level: features nothing else consumes, in creation order }
  for S := 0 to ADoc.SlotCount - 1 do
  begin
    F := ADoc.Find(CADId(S));
    if (F <> nil) and (ADoc.UserCount(F.Id) = 0) then
      AddFeature(ADoc, Part, F, 0);
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
