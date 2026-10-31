unit CAD.App.SketchMode;
{$mode objfpc}{$H+}

{ ROLE:      sketch mode of the main window: owns the sketch being edited and
             its editor, turns viewport mouse events into editor calls, and
             keeps two viewport objects (sketch strokes, preview + snap +
             origin) up to date.
  CALLED BY: CAD.App.Controller (enter, tool buttons, finish).
  CALLS:     CAD.Sketch.Editor / Model / Text, CAD.View.SketchDraw,
             engine TUIViewport3D (objects, camera, mouse events, OnPointerDrag:
             left drags move sketch points instead of orbiting).
  THREADS:   UI thread.
  SPEED:     a mouse move rebuilds only the small preview mesh; the sketch
             mesh is rebuilt after a click that changed the sketch. }

interface

uses
  Classes, SysUtils, Math, Controls,
  OpenGL.UI.Viewport3D, OpenGL.UI.Viewport3D.Camera, OpenGL.Render.Viewport3DMeshData,
  OpenGL.Render.Viewport3DPass,
  CAD.Sketch.Model, CAD.Sketch.Editor, CAD.Sketch.Solver, CAD.Sketch.Commands,
  CAD.Sketch.Text, CAD.Sketch.TypedInput, CAD.Sketch.DimGraphic, CAD.View.SketchDraw,
  OpenGL.Render.Material, CAD.App.SketchFill, CAD.Sketch.TrimExtend,
  CAD.Sketch.CurveTrim, CAD.Sketch.Profile, CAD.Sketch.Regions,
  CAD.Sketch.ContourSelection;

const
  CAD_SKETCH_PREVIEW_ID = 900002;      { far above feature ids (slot + 1) }
  CAD_SKETCH_LAYER_ID = 900010;        { + Ord(TCADSketchLayer) }
  CAD_SKETCH_FILL_ID = 900030;         { closed regions, light fill }
  CAD_SKETCH_DIM_ID = 900031;          { drafting dimensions }
  CAD_SKETCH_SELECTED_ID = 900032;     { selected contour fill overlay }
  { every sketch-mode object id is at or above this }
  CAD_SKETCH_FIRST_ID = 900000;

type
  TCADEntityEvent = procedure(Sender: TObject; AEntity: Integer) of object;
  { right click in the view (local pixels, top-left origin) }
  TCADViewPointEvent = procedure(Sender: TObject; AX, AY: Integer) of object;

  TCADSketchMode = class
  private
    FView: TUIViewport3D;
    FSketch: TCADSketch;
    FEditor: TCADSketchEditor;
    FActive: Boolean;
    FDownX, FDownY: Integer;
    FOnChanged: TNotifyEvent;
    FOnEntityDoubleClick: TCADEntityEvent;
    FSmartDim: Boolean;                  { Smart Dimension tool: clicks pick, then dimension }
    FLineEditActive: Boolean;            { active Trim (lines/arcs/circles) or Extend }
    FLineEditMode: TCADLineEditMode;
    FLineEditMessage: string;
    FContourSeeds: TCADContourSeeds;      { selected region interior points }
    FContourCount: Integer;              { last resolved selections }
    FLastFillRevision: Cardinal;
    FLastFillContours: string;           { no expensive OCCT rebuild on hover }
    FOnSmartDimension: TNotifyEvent;
    FOnContextMenu: TCADViewPointEvent;
    { sketch undo: texts of the sketch after each change }
    FUndo: array of string;
    FUndoPos: Integer;
    FRestoring: Boolean;
    procedure SmartClick(U, V: Double);
    procedure LineEditClick(U, V: Double);
    function SelectContourAt(U,V:Double; AAdd:Boolean):Boolean;
    function SmartReady: Boolean;
    procedure Restore(const AText: string);
    procedure MouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure MouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure MouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure PointerDrag(Sender: TObject; APhase: TViewport3DDragPhase; AX, AY: Integer;
      var AHandled: Boolean);
    function ToSketch(X, Y: Integer; out U, V: Double): Boolean;
    function ObjectMesh(AId: Cardinal; const AMaterial: string = ''): TV3DMeshData;
    procedure RefreshFill;
    procedure RefreshSketch;
    procedure RefreshPreview;
    procedure Changed;
  public
    constructor Create(AView: TUIViewport3D);
    destructor Destroy; override;
    { Starts a new empty sketch on the plane (origin, X, normal). }
    procedure Enter(const AOrigin, AXDir, ANormal: array of Double);
    { Sketch undo / redo (every change that altered the sketch text). }
    procedure Undo;
    procedure Redo;
    function CanUndo: Boolean;
    function CanRedo: Boolean;
    { Opens an existing sketch (takes ownership), Select tool. }
    procedure EnterSketch(ASketch: TCADSketch);
    { Leaves sketch mode; the caller takes the sketch text first. }
    procedure Leave;
    procedure SetTool(ATool: TCADSketchTool);
    procedure Cancel;
    procedure NormalView;
    function StatusText: string;
    { Constraint buttons, dimension edit and delete; '' = done, else the
      message for the status line. }
    function ApplyCommand(ACommand: TCADSketchCommand; out AConstraint: Integer): string;
    function SetDimension(AConstraint: Integer; AValue: Double): string;
    { The command on one entity alone (the selection is replaced). }
    function ApplyCommandOn(AEntity: Integer; ACommand: TCADSketchCommand;
      out AConstraint: Integer): string;
    function RemoveConstraint(AConstraint: Integer): string;
    { Typed values while drawing (CAD.Sketch.TypedInput): what the numbers
      mean now ('' = none), and applying them; '' = done, else the message. }
    function TypedPrompt: string;
    function TypeValues(const AText: string): string;
    property Active: Boolean read FActive;
    property Sketch: TCADSketch read FSketch;
    property Editor: TCADSketchEditor read FEditor;
    { After every change the panel shows (prompt, DOF). }
    property OnChanged: TNotifyEvent read FOnChanged write FOnChanged;
    { Select tool: double click on a line / circle / arc (dimension it). }
    property OnEntityDoubleClick: TCADEntityEvent read FOnEntityDoubleClick write FOnEntityDoubleClick;
    { Smart Dimension (SolidWorks): the Select tool picks; one circle / arc,
      or two items (points, lines), or a picked line / point and a click on
      empty space fire OnSmartDimension with the picked items selected. }
    procedure SetSmartDimension(AOn: Boolean);
    { Trim: click any line / arc / circle segment; Extend: line endpoints. }
    procedure SetLineEdit(AMode: TCADLineEditMode);
    { The selected regions are separate from sketch constraints and persist
      in the Sketch feature's 'contours' parameter. Empty = all regions. }
    function ContoursText: string;
    procedure LoadContours(const AText:string);
    procedure ClearContours;
    property ContourCount:Integer read FContourCount;
    property LineEditActive: Boolean read FLineEditActive;
    property LineEditMode: TCADLineEditMode read FLineEditMode;
    property SmartDimension: Boolean read FSmartDim;
    property OnSmartDimension: TNotifyEvent read FOnSmartDimension write FOnSmartDimension;
    { Right click when no shape is being drawn: the item under the cursor
      is selected (unless it already is), then this event (the menu). }
    property OnContextMenu: TCADViewPointEvent read FOnContextMenu write FOnContextMenu;
    { Construction geometry on / off for the selected entities (undo step). }
    procedure ToggleConstruction;
    { Clears the picked items (Esc in Smart Dimension, a failed dimension). }
    procedure ClearSelection;
    { Pixel of a sketch point in the viewport (top-left origin). }
    function SketchToScreen(U, V: Double; out AX, AY: Double): Boolean;
    { Sketch mm per screen pixel at the current zoom. }
    function WorldPerPixel: Double;
    { Drafting dimensions for the current zoom (the chips call it when the
      camera or the sketch changed). }
    procedure RefreshDimensions;
    { Centre of the value text of dimension AConstraint (sketch mm). }
    function DimensionTextPos(AConstraint: Integer; out U, V: Double): Boolean;
  end;

implementation

const
  SnapPixels = 8;
  MarkerPixels = 9;
  OriginPixels = 24;
  ClickSlopPixels = 3;

constructor TCADSketchMode.Create(AView: TUIViewport3D);
begin
  inherited Create;
  FView := AView;
end;

destructor TCADSketchMode.Destroy;
begin
  FEditor.Free;
  FSketch.Free;
  inherited Destroy;
end;

function TCADSketchMode.ObjectMesh(AId: Cardinal; const AMaterial: string): TV3DMeshData;
var
  O: TViewport3DObject;
begin
  O := FView.FindObject(AId);
  if O = nil then
    O := FView.AddObject(TV3DMeshData.Create, AMaterial, AId);
  O.Visible := FActive;
  Result := O.Mesh;
end;

procedure TCADSketchMode.Enter(const AOrigin, AXDir, ANormal: array of Double);
var
  S: TCADSketch;
begin
  S := TCADSketch.Create;
  S.SetPlane(AOrigin, AXDir, ANormal);
  EnterSketch(S);
  FEditor.SetTool(sktLine);
end;

procedure TCADSketchMode.EnterSketch(ASketch: TCADSketch);
begin
  FEditor.Free;
  FSketch.Free;
  FSketch := ASketch;
  FEditor := TCADSketchEditor.Create(FSketch);
  FEditor.SetTool(sktSelect);
  FLineEditActive := False;
  FLineEditMessage := '';
  FSmartDim := False;
  SetLength(FContourSeeds,0);
  FContourCount:=0;
  FLastFillRevision:=High(Cardinal);
  FLastFillContours:='';
  FEditor.Resolve;                         { states and DOF of a loaded sketch }
  SetLength(FUndo, 1);
  FUndo[0] := CADSketchToText(FSketch);
  FUndoPos := 0;
  FActive := True;
  FView.OnMouseDown := @MouseDown;
  FView.OnMouseUp := @MouseUp;
  FView.OnMouseMove := @MouseMove;
  FView.OnPointerDrag := @PointerDrag;     { left drags move points, never orbit }
  NormalView;
  RefreshSketch;
  RefreshPreview;
  Changed;
end;

function TCADSketchMode.CanUndo: Boolean;
begin
  Result := FActive and (FUndoPos > 0);
end;

function TCADSketchMode.CanRedo: Boolean;
begin
  Result := FActive and (FUndoPos < High(FUndo));
end;

procedure TCADSketchMode.Restore(const AText: string);
var
  S: TCADSketch;
  Tool: TCADSketchTool;
begin
  S := TCADSketch.Create;
  try
    CADSketchFromText(AText, S);
  except
    S.Free;
    raise;
  end;
  Tool := FEditor.Tool;
  FEditor.Free;
  FSketch.Free;
  FSketch := S;
  FEditor := TCADSketchEditor.Create(FSketch);
  FEditor.SetTool(Tool);
  FEditor.Resolve;
  FLastFillRevision:=High(Cardinal);
  RefreshSketch;
  RefreshPreview;
  FRestoring := True;
  try
    Changed;
  finally
    FRestoring := False;
  end;
end;

procedure TCADSketchMode.Undo;
begin
  if not CanUndo then
    Exit;
  Dec(FUndoPos);
  Restore(FUndo[FUndoPos]);
end;

procedure TCADSketchMode.Redo;
begin
  if not CanRedo then
    Exit;
  Inc(FUndoPos);
  Restore(FUndo[FUndoPos]);
end;

procedure TCADSketchMode.Leave;
var
  O: TViewport3DObject;
  L: TCADSketchLayer;
begin
  FActive := False;
  FSmartDim := False;
  FLineEditActive := False;
  FLineEditMessage := '';
  FView.OnMouseDown := nil;
  FView.OnMouseUp := nil;
  FView.OnMouseMove := nil;
  FView.OnPointerDrag := nil;
  for L := Low(TCADSketchLayer) to High(TCADSketchLayer) do
  begin
    O := FView.FindObject(CAD_SKETCH_LAYER_ID + Ord(L));
    if O <> nil then
      O.Visible := False;
  end;
  O := FView.FindObject(CAD_SKETCH_PREVIEW_ID);
  if O <> nil then
    O.Visible := False;
  O := FView.FindObject(CAD_SKETCH_FILL_ID);
  if O <> nil then
    O.Visible := False;
  O := FView.FindObject(CAD_SKETCH_DIM_ID);
  if O <> nil then
    O.Visible := False;
  O := FView.FindObject(CAD_SKETCH_SELECTED_ID);
  if O <> nil then
    O.Visible := False;
  FView.Invalidate3D;
  Changed;
end;

procedure TCADSketchMode.SetTool(ATool: TCADSketchTool);
begin
  if not FActive then
    Exit;
  FSmartDim := False;
  FLineEditActive := False;
  FLineEditMessage := '';
  FEditor.SetTool(ATool);
  RefreshPreview;
  Changed;
end;

procedure TCADSketchMode.Cancel;
begin
  if not FActive then
    Exit;
  FEditor.Cancel;
  RefreshPreview;
  Changed;
end;

procedure TCADSketchMode.NormalView;
begin
  if FSketch = nil then
    Exit;
  CADCameraToSketch(FView.Camera, FSketch);
  FView.Invalidate3D;
  RefreshPreview;                 { marker and cross sizes follow the zoom }
end;

function TCADSketchMode.WorldPerPixel: Double;
begin
  Result := FView.Camera.WorldPerPixel(Max(1, Round(FView.Height)));
end;

function TCADSketchMode.ToSketch(X, Y: Integer; out U, V: Double): Boolean;
begin
  Result := CADScreenToSketch(FView.Camera, FView.Width, FView.Height, X + 0.5, Y + 0.5,
    FSketch, U, V);
end;

{ SolidWorks colours: under-defined blue, fully defined black, conflicting
  red; construction grey, hover orange, selection light blue. }
const
  LayerColor: array[TCADSketchLayer] of array[0..2] of Single = (
    (0.10, 0.35, 0.95), (0.04, 0.04, 0.05), (0.90, 0.10, 0.10),
    (0.50, 0.55, 0.65), (1.00, 0.55, 0.00), (0.00, 0.70, 0.95));
  PointPixels = 5;

procedure TCADSketchMode.RefreshSketch;
var
  L: TCADSketchLayer;
  Meshes: array[TCADSketchLayer] of TV3DMeshData;
  O: TViewport3DObject;
begin
  for L := Low(TCADSketchLayer) to High(TCADSketchLayer) do
  begin
    Meshes[L] := ObjectMesh(CAD_SKETCH_LAYER_ID + Ord(L));
    O := FView.FindObject(CAD_SKETCH_LAYER_ID + Ord(L));
    O.UseEdgeColor := True;
    O.EdgeColor := Viewport3DRGBA(LayerColor[L][0], LayerColor[L][1], LayerColor[L][2], 1.0);
  end;
  CADBuildSketchLayers(FEditor, PointPixels * WorldPerPixel, Meshes);
  RefreshFill;
  RefreshDimensions;
  FView.Invalidate3D;
end;

const
  FillMaterial = 'cad-sketch-fill';
  SelectedFillMaterial = 'cad-sketch-selected-contours';
  FillColor: array[0..2] of Single = (0.82, 0.89, 0.97);      { light blue }
  SelectedFillColor: array[0..2] of Single = (0.40, 0.78, 0.55); { selected green }
  DimColor: array[0..2] of Single = (0.12, 0.31, 0.61);       { drafting blue }

{ Closed regions in a light colour, a hair behind the plane (the sketch lines
  stay on top); flat material so it is one even colour facing the camera. }
procedure TCADSketchMode.RefreshFill;
var
  M: TRenderMaterial;
  O: TViewport3DObject;
  Err: string;
  Behind: Double;
  ContoursNow: string;
begin
  ContoursNow:=CADContoursToText(FContourSeeds);
  if (FSketch<>nil) and (FLastFillRevision=FSketch.Revision) and
     (FLastFillContours=ContoursNow) then Exit;
  if FView.Materials.Find(FillMaterial) = nil then
  begin
    M := TRenderMaterial.Create(FillMaterial, msFlat);
    M.BaseColor := MaterialColor(FillColor[0], FillColor[1], FillColor[2], 1.0);
    if not FView.Materials.Register(M, Err) then
      M.Free;
  end;
  ObjectMesh(CAD_SKETCH_FILL_ID, FillMaterial);
  O := FView.FindObject(CAD_SKETCH_FILL_ID);
  O.CullBackFaces := False;
  O.UseEdgeColor := True;
  O.EdgeColor := Viewport3DRGBA(FillColor[0], FillColor[1], FillColor[2], 1.0);
  Behind := Max(1e-3, 2 * WorldPerPixel * 0.05);
  CADBuildSketchFill(FSketch, O.Mesh, Behind);

  if FView.Materials.Find(SelectedFillMaterial) = nil then
  begin
    M := TRenderMaterial.Create(SelectedFillMaterial, msFlat);
    M.BaseColor := MaterialColor(SelectedFillColor[0],
      SelectedFillColor[1], SelectedFillColor[2], 1.0);
    if not FView.Materials.Register(M, Err) then M.Free;
  end;
  ObjectMesh(CAD_SKETCH_SELECTED_ID,SelectedFillMaterial);
  O := FView.FindObject(CAD_SKETCH_SELECTED_ID);
  O.CullBackFaces := False;
  O.UseEdgeColor := True;
  O.EdgeColor := Viewport3DRGBA(SelectedFillColor[0],
    SelectedFillColor[1],SelectedFillColor[2],1.0);
  CADBuildSelectedContourFill(FSketch,FContourSeeds,O.Mesh,Behind*0.5);
  FLastFillRevision:=FSketch.Revision;
  FLastFillContours:=ContoursNow;
end;

procedure TCADSketchMode.RefreshDimensions;
var
  O: TViewport3DObject;
begin
  if not FActive or (FSketch = nil) then
    Exit;
  ObjectMesh(CAD_SKETCH_DIM_ID);
  O := FView.FindObject(CAD_SKETCH_DIM_ID);
  O.UseEdgeColor := True;
  O.EdgeColor := Viewport3DRGBA(DimColor[0], DimColor[1], DimColor[2], 1.0);
  CADBuildDimensionMesh(FSketch, WorldPerPixel, O.Mesh);
  FView.Invalidate3D;
end;

function TCADSketchMode.DimensionTextPos(AConstraint: Integer; out U, V: Double): Boolean;
var
  G: TCADDimGraphic;
begin
  if (FSketch = nil) or (AConstraint < 0) then
    Exit(False);
  if CADDimensionGraphic(FSketch, AConstraint, WorldPerPixel, G) then
  begin
    U := G.TextX;
    V := G.TextY;
    Exit(True);
  end;
  Result := CADDimensionAnchor(FSketch, AConstraint, U, V);
end;

procedure TCADSketchMode.RefreshPreview;
var
  W: Double;
begin
  if FEditor = nil then
    Exit;
  W := WorldPerPixel;
  FEditor.SnapTolerance := SnapPixels * W;
  CADBuildEditorMesh(FEditor, MarkerPixels * W, OriginPixels * W,
    ObjectMesh(CAD_SKETCH_PREVIEW_ID));
  FView.Invalidate3D;
end;

const
  UndoLimit = 200;

procedure TCADSketchMode.Changed;
var
  T: string;
  I: Integer;
begin
  if FActive and not FRestoring and (FSketch <> nil) and (Length(FUndo) > 0) then
  begin
    T := CADSketchToText(FSketch);
    if T <> FUndo[FUndoPos] then
    begin
      SetLength(FUndo, FUndoPos + 2);         { drops the redo tail }
      Inc(FUndoPos);
      FUndo[FUndoPos] := T;
      if Length(FUndo) > UndoLimit then
      begin
        for I := 0 to High(FUndo) - 1 do
          FUndo[I] := FUndo[I + 1];
        SetLength(FUndo, Length(FUndo) - 1);
        Dec(FUndoPos);
      end;
    end;
  end;
  if Assigned(FOnChanged) then
    FOnChanged(Self);
end;

procedure TCADSketchMode.MouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  U, V: Double;
  Index: Integer;
begin
  FDownX := X;
  FDownY := Y;
  if FActive and not FLineEditActive and (Button = mbLeft) and
     (ssDouble in Shift) and (FEditor.Tool = sktSelect) and
     ToSketch(X, Y, U, V) and
     (CADSketchHit(FSketch, U, V, SnapPixels * WorldPerPixel, Index) = chkEntity) and
     Assigned(FOnEntityDoubleClick) then
    FOnEntityDoubleClick(Self, Index);
end;

function TCADSketchMode.SketchToScreen(U, V: Double; out AX, AY: Double): Boolean;
begin
  Result := FActive and CADSketchToScreen(FView.Camera, FView.Width, FView.Height, FSketch, U, V, AX, AY);
end;

procedure TCADSketchMode.MouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  U, V: Double;
begin
  if not FActive or not ToSketch(X, Y, U, V) then
    Exit;
  FEditor.SnapTolerance := SnapPixels * WorldPerPixel;
  FEditor.Move(U, V);
  if FLineEditActive then
  begin
    if FEditor.UpdateEntityHover(U, V) then
      RefreshSketch;
  end
  else if FEditor.UpdateHover(U, V) then
    RefreshSketch;                       { hover colour }
  RefreshPreview;
end;

procedure TCADSketchMode.PointerDrag(Sender: TObject; APhase: TViewport3DDragPhase;
  AX, AY: Integer; var AHandled: Boolean);
var
  U, V: Double;
begin
  if not FActive then
    Exit;
  AHandled := True;                         { sketch mode: the view does not orbit }
  if FLineEditActive then
    Exit;                                    { editing is click-only, not point drag }
  if not ToSketch(AX, AY, U, V) then
    Exit;
  FEditor.SnapTolerance := SnapPixels * WorldPerPixel;
  case APhase of
    vdpBegin:
      FEditor.BeginDrag(U, V);
    vdpMove:
      if FEditor.Dragging and FEditor.DragTo(U, V) then
      begin
        RefreshSketch;
        RefreshPreview;
      end;
    vdpEnd:
      if FEditor.Dragging then
      begin
        FEditor.EndDrag;
        RefreshSketch;
        RefreshPreview;
        Changed;
      end;
  end;
end;

procedure TCADSketchMode.MouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  U, V: Double;
  K: TCADHitKind;
  Index: Integer;
begin
  if not FActive then
    Exit;
  { a drag orbits or pans the view: not a click }
  if Max(Abs(X - FDownX), Abs(Y - FDownY)) > ClickSlopPixels then
  begin
    RefreshPreview;
    Exit;
  end;
  if Button = mbRight then
  begin
    { drawing: right click ends the shape; else the context menu }
    if FEditor.Busy or not Assigned(FOnContextMenu) or not ToSketch(X, Y, U, V) then
    begin
      Cancel;
      Exit;
    end;
    FEditor.SnapTolerance := SnapPixels * WorldPerPixel;
    K := CADSketchHit(FSketch, U, V, FEditor.SnapTolerance, Index);
    if (K <> chkNone) and not FEditor.IsSelected(K, Index) then
    begin
      FEditor.ClearSelection;
      FEditor.SelectItem(K, Index);
    end;
    RefreshPreview;
    Changed;
    FOnContextMenu(Self, X, Y);
    Exit;
  end;
  if (Button <> mbLeft) or not ToSketch(X, Y, U, V) then
    Exit;
  FEditor.SnapTolerance := SnapPixels * WorldPerPixel;
  if FLineEditActive then
  begin
    LineEditClick(U, V);
    Exit;
  end;
  if FSmartDim then
    SmartClick(U, V)
  else if (FEditor.Tool = sktSelect) and
          (CADSketchHit(FSketch,U,V,FEditor.SnapTolerance,Index)=chkNone) and
          SelectContourAt(U,V,ssShift in Shift) then
  begin
    RefreshSketch;
    RefreshPreview;
    Changed;
    Exit;
  end
  else if FEditor.Tool = sktSelect then
    FEditor.SelectAt(U, V, ssShift in Shift)
  else if FEditor.Click(U, V) then
    RefreshSketch;
  RefreshPreview;
  Changed;
end;

function TCADSketchMode.ApplyCommand(ACommand: TCADSketchCommand; out AConstraint: Integer): string;
begin
  Result := '';
  AConstraint := -1;
  if not FActive then
    Exit('no sketch');
  if not FEditor.Apply(ACommand, AConstraint, Result) then
  begin
    if Result = '' then
      Result := 'not applied';
  end;
  RefreshSketch;
  RefreshPreview;
  Changed;
end;

function TCADSketchMode.ApplyCommandOn(AEntity: Integer; ACommand: TCADSketchCommand;
  out AConstraint: Integer): string;
begin
  AConstraint := -1;
  if not FActive then
    Exit('no sketch');
  FEditor.ClearSelection;
  FEditor.SelectItem(chkEntity, AEntity);
  Result := ApplyCommand(ACommand, AConstraint);
end;

function TCADSketchMode.SetDimension(AConstraint: Integer; AValue: Double): string;
begin
  Result := '';
  if not FActive then
    Exit('no sketch');
  FEditor.SetDimension(AConstraint, AValue, Result);
  RefreshSketch;
  RefreshPreview;
  Changed;
end;

function TCADSketchMode.TypedPrompt: string;
begin
  Result := '';
  if FActive and (FEditor <> nil) then
    Result := CADTypedPrompt(FEditor);
end;

function TCADSketchMode.TypeValues(const AText: string): string;
begin
  Result := '';
  if not FActive then
    Exit('no sketch');
  if not CADApplyTyped(FEditor, AText, Result) then
  begin
    RefreshPreview;
    Exit;
  end;
  RefreshSketch;
  RefreshPreview;
  Changed;
end;

function TCADSketchMode.RemoveConstraint(AConstraint: Integer): string;
begin
  Result := '';
  if not FActive then
    Exit('no sketch');
  try
    FSketch.RemoveConstraint(AConstraint);
  except
    on E: Exception do
      Result := E.Message;
  end;
  FEditor.ClearSelection;
  FEditor.Cancel;
  FEditor.Resolve;
  RefreshSketch;
  RefreshPreview;
  Changed;
end;

procedure TCADSketchMode.SetSmartDimension(AOn: Boolean);
begin
  if not FActive then
    Exit;
  FEditor.SetTool(sktSelect);
  FEditor.ClearSelection;
  FSmartDim := AOn;
  FLineEditActive := False;
  FLineEditMessage := '';
  RefreshPreview;
  Changed;
end;

{ Begin a click-only, end-segment Trim or Extend operation. }
procedure TCADSketchMode.SetLineEdit(AMode: TCADLineEditMode);
begin
  if not FActive then
    Exit;
  FEditor.SetTool(sktSelect);
  FEditor.ClearSelection;
  FSmartDim := False;
  FLineEditActive := True;
  FLineEditMode := AMode;
  FLineEditMessage := '';
  RefreshPreview;
  Changed;
end;

{ One click plans a safe line edit and applies it transactionally. }
procedure TCADSketchMode.LineEditClick(U, V: Double);
var
  Index: Integer;
  Plan: TCADLineEditPlan;
  TrimPlan: TCADTrimPlan;
  Err: string;
begin
  { Trim/Extend are entity operations. The normal hit tester prefers a
    vertex, preventing cuts close to an arc endpoint on another entity. }
  Index := CADSketchEntityHit(FSketch, U, V, FEditor.SnapTolerance);
  if Index < 0 then
    FLineEditMessage := 'Trim: click a line, arc or circle | Extend: click a line'
  else if (FLineEditMode = lemExtend) and
          (FSketch.Entities[Index].Kind <> sekLine) then
    FLineEditMessage := 'Extend currently supports straight lines only'
  else if FLineEditMode = lemTrim then
  begin
    if not CADPlanSketchTrim(FSketch, Index, U, V, TrimPlan, Err) then
      FLineEditMessage := Err
    else if not CADApplySketchTrim(FSketch, TrimPlan, Err) then
      FLineEditMessage := Err
    else
    begin
      FLineEditMessage := 'Segment removed. Click another segment or press Esc';
      FEditor.ClearSelection;
      FEditor.Resolve;
      RefreshSketch;
    end;
  end
  else if not CADPlanLineEdit(FSketch, Index, U, V, lemExtend, Plan, Err) then
    FLineEditMessage := Err
  else if not CADApplyLineEdit(FSketch, Plan, Err) then
    FLineEditMessage := Err
  else
  begin
    FLineEditMessage := 'Line endpoint extended. Click another line or press Esc';
    FEditor.ClearSelection;
    FEditor.Resolve;
    RefreshSketch;
  end;
  RefreshPreview;
  Changed;
end;

{ One interior click selects a planar face without altering the sketch.
  The boundary may contain unsplit intersections and open exterior arms. }
function TCADSketchMode.SelectContourAt(U,V:Double; AAdd:Boolean):Boolean;
var
  P:TCADSketchProfile;
  Indices:TCADRegionIndices;
begin
  Result:=False;
  if (FSketch=nil) or not CADBuildRegions(FSketch,P) then Exit;
  Result:=CADClickContour(P,U,V,AAdd,FContourSeeds);
  if Result then
  begin
    Indices:=CADContourIndices(P,FContourSeeds);
    if Length(FContourSeeds)=0 then FContourCount:=0
    else FContourCount:=Length(Indices);
    FEditor.ClearSelection;
  end;
end;

function TCADSketchMode.ContoursText:string;
begin
  Result:=CADContoursToText(FContourSeeds);
end;

procedure TCADSketchMode.LoadContours(const AText:string);
var
  P:TCADSketchProfile;
  Indices:TCADRegionIndices;
begin
  if not CADContoursFromText(AText,FContourSeeds) then
    SetLength(FContourSeeds,0);
  FContourCount:=0;
  if (Length(FContourSeeds)>0) and (FSketch<>nil) and
     CADBuildRegions(FSketch,P) then
  begin
    Indices:=CADContourIndices(P,FContourSeeds);
    FContourCount:=Length(Indices);
  end;
  if FActive then
  begin
    RefreshFill;
    Changed;
  end;
end;

procedure TCADSketchMode.ClearContours;
begin
  SetLength(FContourSeeds,0);
  FContourCount:=0;
  if FActive then
  begin
    RefreshFill;
    Changed;
  end;
end;

{ Which selections can sccDimension actually measure? }
function TCADSketchMode.SmartReady: Boolean;
var
  Sel: TCADSketchSelection;
begin
  Sel := FEditor.Selection;
  if (Length(Sel.Points) = 2) and (Length(Sel.Entities) = 0) then
    Exit(True);
  if (Length(Sel.Points) = 1) and (Length(Sel.Entities) = 1) then
    Exit(FSketch.Entities[Sel.Entities[0]].Kind = sekLine);
  if (Length(Sel.Points) = 0) and (Length(Sel.Entities) = 2) then
    Exit((FSketch.Entities[Sel.Entities[0]].Kind = sekLine) and
      (FSketch.Entities[Sel.Entities[1]].Kind = sekLine));
  Result := (Length(Sel.Points) = 0) and (Length(Sel.Entities) = 1) and
    (FSketch.Entities[Sel.Entities[0]].Kind in [sekCircle, sekArc]);
end;

procedure TCADSketchMode.SmartClick(U, V: Double);
var
  K: TCADHitKind;
  Index: Integer;
  Sel: TCADSketchSelection;
begin
  K := CADSketchHit(FSketch, U, V, FEditor.SnapTolerance, Index);
  Sel := FEditor.Selection;
  if K = chkNone then
  begin
    { A single line needs an empty-space click to dimension its length.
      A single point must wait for a second point or a line. }
    if (Length(Sel.Points) = 0) and (Length(Sel.Entities) = 1) and
       (FSketch.Entities[Sel.Entities[0]].Kind = sekLine) and
       Assigned(FOnSmartDimension) then
      FOnSmartDimension(Self);
    Exit;
  end;
  { Toggling a picked item allows correcting an unsupported selection. }
  FEditor.SelectItem(K, Index);
  if SmartReady and Assigned(FOnSmartDimension) then
    FOnSmartDimension(Self);
end;

procedure TCADSketchMode.ClearSelection;
begin
  if not FActive then
    Exit;
  FEditor.ClearSelection;
  RefreshPreview;
  Changed;
end;

procedure TCADSketchMode.ToggleConstruction;
var
  Sel: TCADSketchSelection;
  I: Integer;
  AllOn: Boolean;
begin
  if not FActive then
    Exit;
  Sel := FEditor.Selection;
  if Length(Sel.Entities) = 0 then
    Exit;
  AllOn := True;
  for I := 0 to High(Sel.Entities) do
    AllOn := AllOn and FSketch.Entities[Sel.Entities[I]].Construction;
  for I := 0 to High(Sel.Entities) do
    FSketch.SetConstruction(Sel.Entities[I], not AllOn);
  FEditor.Resolve;
  RefreshSketch;
  RefreshPreview;
  Changed;
end;

function TCADSketchMode.StatusText: string;
var
  R: TCADSketchSolveResult;
begin
  if not FActive then
    Exit('');
  if FLineEditActive then
  begin
    if FLineEditMessage <> '' then
      Exit(FLineEditMessage);
    if FLineEditMode = lemTrim then
      Exit('Trim: click the unwanted line, arc or circle segment | Esc: Select')
    else
      Exit('Extend: click near a line end to reach a boundary | Esc: Select');
  end;
  if FSmartDim then
    Exit('Smart Dimension: click a line, circle or arc (two items: distance or angle; ' +
      'a line then empty space: its length) | Esc: clear / Select');
  if Length(FContourSeeds)>0 then
    Exit(Format('Selected contours: %d | Shift+click another region to add/remove | ' +
      'Click inside a region to replace selection | Exit Sketch: Extrude selected',
      [FContourCount]));
  R := FEditor.LastSolve;
  if R.DOF < 0 then
    Result := FEditor.Prompt
  else if R.Status <> cssSolved then
    Result := FEditor.Prompt + ' | ' + CADSolveStatusText(R.Status)
  else
    Result := Format('%s | DOF %d', [FEditor.Prompt, R.DOF]);
  if (FEditor.Tool = sktSelect) and (Length(FContourSeeds)=0) then
    Result := Result + ' | Click inside a bounded region to select for Extrude; ' +
      'Shift+click to select more';
end;

end.
