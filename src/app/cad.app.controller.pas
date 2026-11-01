unit CAD.App.Controller;
{$mode objfpc}{$H+}
{$codepage utf8}

{ ROLE:      the FPC-CAD application behind the designed main window: OCCT,
             document, viewport sync, the demo plate, sketch mode with its
             panel, ribbon page and dimension chips, the feature tree, the
             window chrome (ribbon / left tabs / view toolbar / status) and
             keyboard shortcuts. Every widget is designed in FPC Visual IDE
             (app/MainForm.fvform, window edges by anchors=) and found by id;
             only the dimension chips are made here (one per dimension).
  CALLED BY: UMainForm (app/umainform.pas): Create + Start after GPU setup,
             Layout on resize, KeyDown, RadiusChanged, Run (menu).
  CALLS:     OCCT bridge (load + options), CAD.Core.Document (Recompute),
             CAD.View.Sync + CAD.View.ViewportTarget + MeshConvert (filler),
             CAD.App.DemoScene, CAD.App.Sketch* (code-built sketch UI).
  THREADS:   UI thread; Recompute uses the worker pool inside and returns
             before Sync runs.
  SPEED:     a slider change = SetParam x6 + Recompute + Sync; only the cut
             chain end is meshed and converted (see the timing lines). }

interface

uses
  Classes, SysUtils, Math, LCLType,
  OpenGL.Types, OpenGL.ECS.Widgets, OpenGL.UI.Host, OpenGL.UI.Viewport3D,
  OpenGL.UI.WidgetKit,
  OpenGL.Render.Picking3D,
  CAD.Config.Performance, CAD.Core.Ids, CAD.Core.Feature, CAD.Core.Document,
  CAD.OCCT.Bridge, CAD.View.MeshConvert, CAD.View.Sync, CAD.View.ViewportTarget,
  CAD.Core.Values, CAD.Core.ObjectIds, CAD.Core.History,
  CAD.Core.SketchGeometryCommands, CAD.Core.ObjectCommands,
  CAD.Core.ObjectModel, CAD.Core.BodyFeatureCommands,
  CAD.Core.SketchExtrudeCommand, CAD.Sketch.Model, CAD.Sketch.Text, CAD.Sketch.Editor,
  CAD.Sketch.Commands, CAD.Sketch.Solver, CAD.Features.Sketch, CAD.Features.Extrude,
  CAD.App.DemoScene, CAD.App.SketchMode, CAD.App.SketchPanel, CAD.App.SketchDims,
  CAD.App.SketchToolbar, CAD.App.DesignLookup, CAD.App.TypedValue,
  CAD.App.FeatureTree, CAD.App.Chrome, CAD.App.SketchContext,
  CAD.Sketch.ExtrudeOptions;

type
  { Menu commands (the ribbon buttons are bound directly). }
  TCADAppCommand = (cadUndo, cadRedo, cadZoomFit, cadNormalTo, cadToggleEdges,
    cadNewSketch, cadEditSketch);

  { The widgets of app/MainForm.fvform the application uses. }
  TCADAppWidgets = record
    Root: TUIWidget;
    View: TUIViewport3D;
    RadiusLabel: TUILabel;
    Radius: TUISlider;
    Selected, Hover, Recompute, Computed, Meshes, Sync: TUILabel;
    Status, UndoTrace: TUILabel;
  end;

  TCADAppController = class
  private
    FHost: TUIHostControl;
    FLookup: TCADWidgetLookup;
    W: TCADAppWidgets;
    FOverlayOrder: Integer;
    FOverlay: TUIPanel;                   { over the view: dimension chips }
    FOCCT: TOCCTLibrary;
    FDoc: TCADDocument;
    FHistory: TCADHistory; { document-level commits; separate from in-editor strokes }
    FTarget: TCADViewportTarget;
    FSync: TCADViewSync;
    FScene: TCADDemoScene;
    FSceneOk: Boolean;
    FSketchMode: TCADSketchMode;
    FSketchPanel: TCADSketchPanel;
    FSketchDims: TCADSketchDims;
    FSketchToolbar: TCADSketchToolbar;
    FTyped: TCADTypedValueBox;            { typed values while drawing }
    FChrome: TCADChrome;
    FContext: TCADSketchContextMenu;
    FTree: TCADFeatureTree;
    FEditSketch: TCADId;                  { sketch feature being edited; CADNoId = new }
    FLastSketch: TCADId;
    FActiveBody: TCADObjectId; { logical target for next Extrude }
    FSketchCount: Integer;
    FEditExtrude: TCADId;               { linked Extrude being edited, if any }
    FExtrudePanel, FExtrudeGripBadge: TUIPanel;
    FExtrudePreviewButton, FExtrudeReverseButton, FExtrudeSymmetricButton: TUIButton;
    FExtrudeConfirmButton, FExtrudeCancelButton: TUIButton;
    FExtrudeDepthEdit, FExtrudeHandleValueEdit: TUIEdit;
    FExtrudeStatus, FExtrudeHandleUnit: TUILabel;
    FExtrudeSaved, FExtrudeDraft: TCADExtrudeOptions;
    FUpdatingExtrudeControls: Boolean;
    FExtrudeInlineInvalid: Boolean;
    procedure ExtrudePreviewClick(Sender: TObject);
    procedure ExtrudeDepthKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure ExtrudeHandleDepthKeyDown(Sender: TObject;
      var Key: Word; Shift: TShiftState);
    procedure ExtrudeHandleDepthExit(Sender: TObject);
    procedure ExtrudeGripDepthChanged(Sender: TObject; ADepth: Double);
    procedure UpdateExtrudeGripPosition;
    procedure ExtrudeReverseClick(Sender: TObject);
    procedure ExtrudeSymmetricClick(Sender: TObject);
    procedure ExtrudeConfirmClick(Sender: TObject);
    procedure ExtrudeCancelClick(Sender: TObject);
    procedure UpdateExtrudeControls;
    procedure RefreshExtrudeDraft;
    function ReadExtrudeDepth: Boolean;
    procedure NewSketch(Sender: TObject);
    procedure NewBody(Sender: TObject);
    procedure PartUndoClick(Sender: TObject);
    procedure PartRedoClick(Sender: TObject);
    procedure SelectBody(Sender: TObject; const AId: TCADObjectId);
    procedure FinishClick(Sender: TObject);
    procedure EditSketchClick(Sender: TObject);
    function SketchToEdit: TCADId;
    procedure SketchChanged(Sender: TObject);
    procedure SketchStatus(Sender: TObject; const AText: string);
    procedure RelationClick(Sender: TObject; AConstraint: Integer);
    procedure FinishSketch;
    function EnsureSketchObject(const AFeature: TCADId;
      out ASketchId: TCADObjectId; out AError: string): Boolean;
    procedure ShowDocumentObjects(AVisible: Boolean);
    procedure PickChanged(Sender: TObject);
    function LoadOCCT: string;
    procedure Rebuild(AFit: Boolean);
    function Describe(const AId: TPick3DId): string;
    procedure ModeChanged;
    procedure OpenSketchOf(const AId: TCADId);
    function LinkedExtrudeOfSketch(const AId: TCADId): TCADId;
    procedure DiscardSketch;
    procedure EditFeature(Sender: TObject; const AId: TCADId);
    procedure DiscardClick(Sender: TObject);
    procedure NormalToClick(Sender: TObject);
    function DofText: string;
    procedure SmartDimension(Sender: TObject);
    procedure ContextMenu(Sender: TObject; AX, AY: Integer);
  public
    { ARoot: the design's root; ALookup: TUIForm.Widget; AOverlayOrder: first
      paint order above the design (Design.MaxDocumentRenderOrder + 1). }
    constructor Create(AHost: TUIHostControl; ARoot: TUIWidget;
      ALookup: TCADWidgetLookup; AOverlayOrder: Integer);
    destructor Destroy; override;
    { OCCT, document, demo scene, sketch UI; once, after GPU setup. }
    procedure Start;
    { The chip overlay covers the design root (the designed widgets follow
      the window by their anchors). }
    procedure Layout;
    procedure Run(ACommand: TCADAppCommand);
    { SolidWorks-like shortcuts while a sketch is open. }
    procedure KeyDown(var Key: Word; Shift: TShiftState);
    procedure RadiusChanged;
  end;

{ The FPC-CAD light theme (assets/styles/cad-light.css, built by
  tools/theme/build_theme.py) next to the program. }
procedure CADUseStyleSheet(AHost: TUIHostControl);

implementation

const
  StartRadius = 4.0;
  NavigationHint = 'left drag: orbit, middle/right: pan, wheel: zoom, click: select';

procedure CADUseStyleSheet(AHost: TUIHostControl);
var
  F: string;
begin
  F := ExtractFilePath(ExpandFileName(ParamStr(0))) + 'assets' + PathDelim + 'styles' +
    PathDelim + 'cad-light.css';
  if FileExists(F) then
    AHost.StyleSheetFile := F;
end;

constructor TCADAppController.Create(AHost: TUIHostControl; ARoot: TUIWidget;
  ALookup: TCADWidgetLookup; AOverlayOrder: Integer);

  function L(const AId: string): TUILabel;
  begin
    Result := TUILabel(CADDesignWidget(ALookup, AId, TUILabel));
  end;

begin
  inherited Create;
  FHost := AHost;
  FLookup := ALookup;
  FOverlayOrder := AOverlayOrder;
  W.Root := ARoot;
  W.View := TUIViewport3D(CADDesignWidget(ALookup, 'View', TUIViewport3D));
  W.RadiusLabel := L('RadiusLabel');
  W.Radius := TUISlider(CADDesignWidget(ALookup, 'RadiusSlider', TUISlider));
  W.Selected := L('SelectedLabel');
  W.Hover := L('HoverLabel');
  W.Recompute := L('RecomputeLabel');
  W.Computed := L('ComputedLabel');
  W.Meshes := L('MeshesLabel');
  W.Sync := L('SyncLabel');
  W.Status := L('StatusLabel');
  W.UndoTrace := L('UndoTraceLabel');
  FEditSketch := CADNoId;
  FEditExtrude := CADNoId;
  FExtrudeSaved := CADDefaultExtrudeOptions;
  FExtrudeDraft := FExtrudeSaved;
  FLastSketch := CADNoId;
  FActiveBody := CADNoObjectId;
end;

destructor TCADAppController.Destroy;
begin
  FreeAndNil(FContext);
  FreeAndNil(FTree);
  FreeAndNil(FChrome);
  FreeAndNil(FTyped);
  FreeAndNil(FSketchToolbar);
  FreeAndNil(FSketchDims);
  FreeAndNil(FSketchPanel);
  FreeAndNil(FSketchMode);
  { Sync and target point at the viewport; the document's cache frees OCCT
    shapes, so it goes before the bridge. Widgets belong to the form. }
  FreeAndNil(FSync);
  FreeAndNil(FTarget);
  FreeAndNil(FHistory);
  FreeAndNil(FDoc);
  if FOCCT <> nil then
  begin
    SetOCCT(nil);
    FreeAndNil(FOCCT);
  end;
  inherited Destroy;
end;

function TCADAppController.LoadOCCT: string;
begin
  Result := '';
  FOCCT := TOCCTLibrary.Create;
  try
    FOCCT.Load;
    FOCCT.ApplyOptions(DefaultPerformanceOptions);
    SetOCCT(FOCCT);
  except
    on E: Exception do
    begin
      Result := 'OCCT bridge not loaded: ' + E.Message;
      FreeAndNil(FOCCT);
    end;
  end;
end;

procedure TCADAppController.Start;
var
  UI: TUIWidgetFactory;
  Err: string;
begin
  UI := FHost.UI;
  W.View.OnSelectionChanged := @PickChanged;
  W.View.OnPreselectionChanged := @PickChanged;
  { Old demo-only controls remain in the designed form for compatibility,
    but must not appear or mutate a new blank document. }
  W.Radius.Visible := False;
  W.RadiusLabel.Visible := False;
  { The dimension chips are made per dimension while sketching. The
    design's widgets get paint bands when the design loads, so a widget made
    later would paint under the view: the chips live on a see-through
    overlay (host root, not the design) painted after the design; its own
    widgets get the overlay's order + 1 when they are made. }
  FOverlay := UI.CreatePanel(FHost.Root, 0, 0, 100, 100, 0, tColor4.Create(0, 0, 0, 0));
  FOverlay.InputTransparent := True;
  FOverlay.RenderOrder := FOverlayOrder;
  FSketchMode := TCADSketchMode.Create(W.View);
  FSketchMode.OnChanged := @SketchChanged;
  FSketchMode.OnExtrudeDepthChanged := @ExtrudeGripDepthChanged;
  FExtrudePanel := TUIPanel(CADDesignWidget(FLookup,
    'ExtrudeOptionsPanel', TUIPanel));
  FExtrudeGripBadge := TUIPanel(CADDesignWidget(FLookup,
    'ExtrudeGripBadge', TUIPanel));
  FExtrudePreviewButton := TUIButton(CADDesignWidget(FLookup,
    'ExtrudePreviewButton', TUIButton));
  FExtrudeDepthEdit := TUIEdit(CADDesignWidget(FLookup,
    'ExtrudeDepthEdit', TUIEdit));
  FExtrudeHandleValueEdit := TUIEdit(CADDesignWidget(FLookup,
    'ExtrudeHandleValueEdit', TUIEdit));
  FExtrudeHandleUnit := TUILabel(CADDesignWidget(FLookup,
    'ExtrudeHandleUnit', TUILabel));
  FExtrudeReverseButton := TUIButton(CADDesignWidget(FLookup,
    'ExtrudeReverseButton', TUIButton));
  FExtrudeSymmetricButton := TUIButton(CADDesignWidget(FLookup,
    'ExtrudeSymmetricButton', TUIButton));
  FExtrudeConfirmButton := TUIButton(CADDesignWidget(FLookup,
    'ExtrudeConfirmButton', TUIButton));
  FExtrudeCancelButton := TUIButton(CADDesignWidget(FLookup,
    'ExtrudeCancelButton', TUIButton));
  FExtrudeStatus := TUILabel(CADDesignWidget(FLookup,
    'ExtrudePreviewStatus', TUILabel));
  FExtrudePreviewButton.OnClick := @ExtrudePreviewClick;
  FExtrudeDepthEdit.OnKeyDown := @ExtrudeDepthKeyDown;
  FExtrudeHandleValueEdit.OnKeyDown := @ExtrudeHandleDepthKeyDown;
  FExtrudeHandleValueEdit.OnExit := @ExtrudeHandleDepthExit;
  FExtrudeReverseButton.OnClick := @ExtrudeReverseClick;
  FExtrudeSymmetricButton.OnClick := @ExtrudeSymmetricClick;
  FExtrudeConfirmButton.OnClick := @ExtrudeConfirmClick;
  FExtrudeCancelButton.OnClick := @ExtrudeCancelClick;
  FExtrudePanel.Visible := False;
  FExtrudeGripBadge.Visible := False;
  FExtrudePreviewButton.Visible := False;
  FSketchPanel := TCADSketchPanel.Create(UI, FLookup, FSketchMode);
  FSketchPanel.OnNewSketch := @NewSketch;
  FSketchPanel.OnEditSketch := @EditSketchClick;
  FSketchPanel.OnStatus := @SketchStatus;
  FSketchToolbar := TCADSketchToolbar.Create(FLookup, FSketchMode, FSketchPanel);
  FSketchToolbar.OnFinish := @FinishClick;
  FSketchDims := TCADSketchDims.Create(UI, FOverlay, W.View, FSketchMode);
  FSketchDims.OnStatus := @SketchStatus;
  FSketchDims.OnConstraintClick := @RelationClick;
  FTyped := TCADTypedValueBox.Create(UI, FLookup, FSketchMode, W.View);
  FTyped.OnStatus := @SketchStatus;
  FChrome := TCADChrome.Create(FLookup, W.View);
  FChrome.OnExtrude := @NewSketch;
  FChrome.OnNewBody := @NewBody;
  FChrome.OnExitSketch := @FinishClick;
  FChrome.OnDiscardSketch := @DiscardClick;
  FChrome.OnNormalTo := @NormalToClick;
  TUIButton(CADDesignWidget(FLookup,'PartUndoButton',TUIButton)).OnClick := @PartUndoClick;
  TUIButton(CADDesignWidget(FLookup,'PartRedoButton',TUIButton)).OnClick := @PartRedoClick;
  FTree := TCADFeatureTree.Create(FLookup, FHost, UI,
    ExtractFilePath(ExpandFileName(ParamStr(0))) +
    'assets' + PathDelim + 'icons' + PathDelim + 'png' + PathDelim + '20' + PathDelim);
  FTree.OnEditFeature := @EditFeature;
  FTree.OnSelectBody := @SelectBody;
  FContext := TCADSketchContextMenu.Create(UI, FSketchMode, FSketchPanel,
    ExtractFilePath(ExpandFileName(ParamStr(0))) + 'assets' + PathDelim + 'icons' + PathDelim +
    'png' + PathDelim + '20' + PathDelim);
  FContext.OnDimension := @SmartDimension;
  FContext.OnExitSketch := @FinishClick;
  FSketchMode.OnSmartDimension := @SmartDimension;
  FSketchMode.OnContextMenu := @ContextMenu;
  ModeChanged;
  Layout;
  Err := LoadOCCT;
  FDoc := TCADDocument.Create;
  FHistory := TCADHistory.Create(FDoc);
  FTarget := TCADViewportTarget.Create(W.View);
  FSync := TCADViewSync.Create(FDoc, FTarget, @CADFillMeshFromResult);
  { A professional CAD document starts empty: only Part, Origin and
    its three Datum planes exist. No demonstration features are attached. }
  FSceneOk := False;
  if FTree <> nil then
    FTree.Refresh(FDoc,True);
  if Err <> '' then
    W.Status.Text := Err
  else if FOCCT <> nil then
    W.Status.Text := Format('OCCT %s | %s', [FOCCT.OcctVersion, NavigationHint]);
end;

{ Engine geometry: X/Y are the centre offset from the parent centre (Y up);
  Left/Top are the top-left corner. A plain Width/Height change keeps the
  centre offsets of the children, so a widget with designed children is
  resized with ResizeWidgetKeepingChildren. }
procedure TCADAppController.Layout;
begin
  if (FOverlay = nil) or (W.Root = nil) then
    Exit;
  { The overlay covers the whole design root at its top-left, so its
    children use the root's coordinates: the chips are placed at
    View.Left + pixel (an overlay at the view's corner added the view offset
    twice: user screenshot, texts right / below their dimensions). }
  FHost.UI.ResizeWidgetKeepingChildren(FOverlay, Max(1, W.Root.Width), Max(1, W.Root.Height));
  FOverlay.Left := W.Root.Left;
  FOverlay.Top := W.Root.Top;
  UpdateExtrudeGripPosition;
end;

{ Sketch opened or closed: ribbon / left tab / corner, sketch buttons
  enabled, panel parts enabled. }
procedure TCADAppController.ModeChanged;
var
  F: TCADFeature;
  Doc: string;
begin
  Doc := 'Part1';
  if FSketchMode.Active then
  begin
    F := nil;
    if CADIdValid(FEditSketch) and (FDoc <> nil) then
      F := FDoc.Find(FEditSketch);
    if F <> nil then
      Doc := 'Editing ' + F.Name
    else
      Doc := Format('Editing Sketch %d', [FSketchCount + 1]);
  end;
  FChrome.SetSketchMode(FSketchMode.Active, Doc);
  FChrome.SetDof(DofText);
  FSketchToolbar.UpdateVisible;
  FSketchPanel.UpdateEnabled;
  FExtrudePreviewButton.Visible := FSketchMode.Active;
  if not FSketchMode.Active then FExtrudePanel.Visible := False;
  UpdateExtrudeGripPosition;
  FTyped.Hide;
end;

function TCADAppController.DofText: string;
var
  R: TCADSketchSolveResult;
begin
  Result := '';
  if not FSketchMode.Active or (FSketchMode.Editor = nil) then
    Exit;
  R := FSketchMode.Editor.LastSolve;
  if R.DOF = 0 then
    Result := 'Fully defined · DOF 0'
  else if R.DOF > 0 then
    Result := Format('Under defined · DOF %d', [R.DOF]);
end;

procedure TCADAppController.PartUndoClick(Sender: TObject);
begin
  Run(cadUndo);
end;

procedure TCADAppController.PartRedoClick(Sender: TObject);
begin
  Run(cadRedo);
end;

procedure TCADAppController.Run(ACommand: TCADAppCommand);
var
  UndoLabel: string;
begin
  if FSketchMode = nil then
    Exit;
  case ACommand of
    cadUndo:
      if FSketchMode.Active then
      begin
        FSketchToolbar.Run(ctaUndo);
        W.Status.Text := 'Undo: Sketch editor (not document History)';
        W.UndoTrace.Text := 'UNDO > Sketch editor';
      end
      else if (FHistory <> nil) and FHistory.CanUndo then
      begin
        UndoLabel := FHistory.UndoDescription;
        try
          if FHistory.Undo then
          begin
            { Clear references to features which the history has detached. }
            if FDoc.Objects.Find(CADObjectRef(cokBody,FActiveBody)) = nil then
              FActiveBody := CADNoObjectId;
            if CADIdValid(FLastSketch) and (FDoc.Find(FLastSketch) = nil) then
              FLastSketch := CADNoId;
            FTree.Refresh(FDoc,True);
            Rebuild(False);
            W.Status.Text := 'Undo: '+UndoLabel+
              Format(' | Sketch objects: %d',
                [FDoc.Objects.ActiveCount(cokSketch)]);
            W.UndoTrace.Text := Format('UNDO > %s | Sketches: %d',
              [UndoLabel,FDoc.Objects.ActiveCount(cokSketch)]);
          end;
        except
          on E: Exception do
          begin
            W.Status.Text := 'Undo FAILED ['+UndoLabel+']: '+E.Message;
            W.UndoTrace.Text := 'UNDO FAILED: '+UndoLabel;
          end;
        end;
      end
      else
      begin
        W.Status.Text := 'Undo: no document History entry available';
        W.UndoTrace.Text := 'UNDO > no document action';
      end;
    cadRedo:
      if FSketchMode.Active then FSketchToolbar.Run(ctaRedo)
      else if (FHistory <> nil) and FHistory.CanRedo then
      begin
        try
          if FHistory.Redo then
          begin
            FTree.Refresh(FDoc,True);
            Rebuild(False);
          end;
        except
          on E: Exception do W.Status.Text := 'Redo: '+E.Message;
        end;
      end;
    cadZoomFit: FChrome.ZoomFit;
    cadNormalTo: NormalToClick(nil);
    cadToggleEdges: FChrome.ToggleEdges;
    cadNewSketch: NewSketch(nil);
    cadEditSketch: EditSketchClick(nil);
  end;
end;

{ Smart Dimension: the picked items get their dimension and its value opens
  in place for typing. }
procedure TCADAppController.SmartDimension(Sender: TObject);
var
  C: Integer;
  Err: string;
  Sel: TCADSketchSelection;
begin
  if not FSketchMode.Active then
    Exit;
  Sel := FSketchMode.Editor.Selection;
  { An already dimensioned line/circle/arc should open its size edit box,
    rather than try to create a redundant constraint. }
  if (Length(Sel.Points) = 0) and (Length(Sel.Entities) = 1) then
  begin
    C := CADFindDimension(FSketchMode.Sketch, Sel.Entities[0]);
    if C >= 0 then
    begin
      FSketchMode.ClearSelection;
      FSketchDims.EditDimension(C);
      Exit;
    end;
  end;
  Err := FSketchMode.ApplyCommand(sccDimension, C);
  if (Err = '') and (C >= 0) then
  begin
    FSketchDims.EditDimension(C);
    Exit;
  end;
  FSketchMode.ClearSelection;
  if Err <> '' then
    W.Status.Text := Err;
end;

{ AX, AY: view pixels -> window pixels (the design root is at the window's
  top-left). }
procedure TCADAppController.ContextMenu(Sender: TObject; AX, AY: Integer);
begin
  FContext.ShowAt(Round(W.View.Left) + AX, Round(W.View.Top) + AY, FHost.Width, FHost.Height);
end;

procedure TCADAppController.NormalToClick(Sender: TObject);
begin
  if FSketchMode.Active then
    FSketchMode.NormalView
  else
    W.Status.Text := 'Normal To works on the open sketch';
end;

procedure TCADAppController.Rebuild(AFit: Boolean);
var
  R: TCADRecomputeReport;
  S: TCADViewSyncReport;
  F: TCADFeature;
  Err: string;
  I: Integer;
begin
  R := FDoc.Recompute;
  S := FSync.Sync;
  Err := '';
  { Errors come from actual document features, never a demo-only ID. }
  for I := 0 to FDoc.SlotCount-1 do
  begin
    F := FDoc.Find(CADId(I));
    if (F <> nil) and (F.LastError <> '') then
    begin
      Err := F.Name + ': ' + F.LastError;
      Break;
    end;
  end;
  if (Err = '') and (S.Failed > 0) then
    Err := FSync.LastError;
  W.Recompute.Text := Format('Recompute: %d ms', [R.Milliseconds]);
  W.Computed.Text := Format('  computed %d, cache hits %d', [R.Computed, R.CacheHits]);
  W.Meshes.Text := Format('  meshes %d in %d ms', [R.Display.Prepared, R.Display.Milliseconds]);
  W.Sync.Text := Format('Sync: %d ms (converted %d)', [S.Milliseconds, S.Updated]);
  if Err <> '' then
    W.Status.Text := 'Error: ' + Err;
  if AFit and (FDoc.SlotCount > 0) then
    W.View.FitAll;
  if FTree <> nil then
    FTree.Refresh(FDoc);
end;

{ Feature objects (not the sketch-mode ones) on or off. Off keeps the sketch
  readable; on goes through the sync again (it knows which are shown). }
procedure TCADAppController.ShowDocumentObjects(AVisible: Boolean);
var
  I: Integer;
  O: TViewport3DObject;
begin
  for I := 0 to W.View.ObjectCount - 1 do
  begin
    O := W.View.Objects[I];
    if O.ObjectId < CAD_SKETCH_FIRST_ID then
      O.Visible := False;
  end;
  if AVisible then
  begin
    FSync.Reset;
    FSync.Sync;
  end;
  W.View.Invalidate3D;
end;

{ Draft controls do not mutate the CAD document. Only Accept Extrude or
  Exit Sketch commits the validated values to the feature graph. }
procedure TCADAppController.UpdateExtrudeControls;
begin
  if FExtrudeDepthEdit = nil then Exit;
  FUpdatingExtrudeControls := True;
  try
    FExtrudeDepthEdit.Text := FloatToStrF(FExtrudeDraft.Depth, ffGeneral, 13, 0);
    FExtrudeHandleValueEdit.Text := FloatToStrF(FExtrudeDraft.Depth, ffGeneral, 13, 0);
    FExtrudeInlineInvalid := False;
    if FExtrudeDraft.Reversed then
      FExtrudeReverseButton.Text := 'Reverse: On'
    else
      FExtrudeReverseButton.Text := 'Reverse: Off';
    if FExtrudeDraft.Symmetric then
      FExtrudeSymmetricButton.Text := 'Symmetric: On'
    else
      FExtrudeSymmetricButton.Text := 'Symmetric: Off';
  finally
    FUpdatingExtrudeControls := False;
  end;
end;

function TCADAppController.ReadExtrudeDepth: Boolean;
var
  Depth: Double;
begin
  Result := CADParseExtrudeDepth(FExtrudeDepthEdit.Text, Depth);
  if Result then
    FExtrudeDraft.Depth := Depth
  else
  begin
    FExtrudeStatus.Text := 'Enter a positive depth (mm)';
    W.Status.Text := 'Extrude: depth must be positive and finite';
  end;
end;

procedure TCADAppController.RefreshExtrudeDraft;
var
  Err: string;
begin
  if (FExtrudePanel = nil) or not FExtrudePanel.Visible or
     (FSketchMode = nil) or not FSketchMode.Active then Exit;
  if not CADValidateExtrudeOptions(FExtrudeDraft, Err) then
  begin
    FExtrudeStatus.Text := Err;
    Exit;
  end;
  FSketchMode.SetExtrudePreview(True, FExtrudeDraft);
  if FSketchMode.ExtrudePreviewError <> '' then
    FExtrudeStatus.Text := FSketchMode.ExtrudePreviewError
  else
    FExtrudeStatus.Text := Format('OCCT preview | %.3f mm', [FExtrudeDraft.Depth]);
  UpdateExtrudeGripPosition;
end;

procedure TCADAppController.ExtrudePreviewClick(Sender: TObject);
begin
  if (FSketchMode = nil) or not FSketchMode.Active or
     FExtrudePanel.Visible then Exit;
  FExtrudeDraft := FExtrudeSaved;
  FExtrudePanel.Visible := True;
  FSketchMode.SetTool(sktSelect); { contour picking is available in Select }
  UpdateExtrudeControls;
  RefreshExtrudeDraft;
end;

procedure TCADAppController.ExtrudeDepthKeyDown(Sender: TObject;
  var Key: Word; Shift: TShiftState);
begin
  if Key <> VK_RETURN then Exit;
  Key := 0;
  if not ReadExtrudeDepth then Exit;
  UpdateExtrudeControls;
  RefreshExtrudeDraft;
end;

procedure TCADAppController.ExtrudeHandleDepthKeyDown(Sender: TObject;
  var Key: Word; Shift: TShiftState);
var
  Depth: Double;
begin
  if Key <> VK_RETURN then Exit;
  Key := 0;
  if not FExtrudePanel.Visible then Exit;
  if not CADParseExtrudeDepth(FExtrudeHandleValueEdit.Text, Depth) then
  begin
    FExtrudeInlineInvalid := True;
    FExtrudeStatus.Text := 'Invalid grip depth; enter a positive mm value';
    Exit;
  end;
  FExtrudeInlineInvalid := False;
  FExtrudeDraft.Depth := Depth;
  UpdateExtrudeControls;
  RefreshExtrudeDraft;
end;

procedure TCADAppController.ExtrudeHandleDepthExit(Sender: TObject);
var
  Depth: Double;
begin
  { Accept/another-widget click must commit a typed inline value even
    when the user did not press Enter first. Cancellation hides the panel
    before focus loss, so cancelled drafts never enter the CAD document. }
  if FUpdatingExtrudeControls or not FExtrudePanel.Visible then Exit;
  if not CADParseExtrudeDepth(FExtrudeHandleValueEdit.Text,Depth) then
  begin
    FExtrudeInlineInvalid:=True;
    FExtrudeStatus.Text:='Invalid inline depth: use a positive number in mm';
    Exit;
  end;
  FExtrudeInlineInvalid:=False;
  if Abs(Depth-FExtrudeDraft.Depth)<1e-10 then Exit;
  FExtrudeDraft.Depth:=Depth;
  UpdateExtrudeControls;
  RefreshExtrudeDraft;
end;

procedure TCADAppController.ExtrudeGripDepthChanged(Sender: TObject;
  ADepth: Double);
begin
  { The SketchMode has already regenerated the exact OCCT preview.
    Update the two number boxes without triggering another rebuild. }
  if not FExtrudePanel.Visible then Exit;
  FExtrudeDraft.Depth := ADepth;
  UpdateExtrudeControls;
  FExtrudeStatus.Text := Format('OCCT preview | %.3f mm', [ADepth]);
  UpdateExtrudeGripPosition;
end;

procedure TCADAppController.UpdateExtrudeGripPosition;
var
  AX, AY, X, Y: Double;
  Show: Boolean;
begin
  if (FExtrudeGripBadge = nil) or (FExtrudeHandleValueEdit = nil) then Exit;
  Show := (FExtrudePanel <> nil) and FExtrudePanel.Visible and
          (FSketchMode <> nil) and FSketchMode.ExtrudePreviewActive;
  if Show then
  begin
    Show := FSketchMode.ExtrudeGripScreen(AX, AY);
    if Show then
      Show := (AX >= 0) and (AY >= 0) and
              (AX < W.View.Width) and (AY < W.View.Height);
  end;
  FExtrudeGripBadge.Visible := Show;
  if not Show then Exit;
  { Move one container instead of independently placing text and units:
    the designer's relative positions can no longer overlap. }
  X := W.View.Left + EnsureRange(AX + 34, 6.0,
    Max(6.0, W.View.Width - 169.0));
  Y := W.View.Top + EnsureRange(AY - 19, 6.0,
    Max(6.0, W.View.Height - 48.0));
  FExtrudeGripBadge.SetBounds(X, Y, 162, 42);
end;

procedure TCADAppController.ExtrudeReverseClick(Sender: TObject);
begin
  if not FExtrudePanel.Visible then Exit;
  FExtrudeDraft.Reversed := not FExtrudeDraft.Reversed;
  UpdateExtrudeControls;
  RefreshExtrudeDraft;
end;

procedure TCADAppController.ExtrudeSymmetricClick(Sender: TObject);
begin
  if not FExtrudePanel.Visible then Exit;
  FExtrudeDraft.Symmetric := not FExtrudeDraft.Symmetric;
  UpdateExtrudeControls;
  RefreshExtrudeDraft;
end;

procedure TCADAppController.ExtrudeConfirmClick(Sender: TObject);
begin
  if not FExtrudePanel.Visible then Exit;
  if FExtrudeInlineInvalid then
  begin
    FExtrudeStatus.Text:='Correct the inline depth before accepting';
    Exit;
  end;
  if not ReadExtrudeDepth then Exit;
  RefreshExtrudeDraft;
  if FSketchMode.ExtrudePreviewError <> '' then Exit;
  FinishClick(Sender);
end;

procedure TCADAppController.ExtrudeCancelClick(Sender: TObject);
begin
  if not FExtrudePanel.Visible then Exit;
  FExtrudePanel.Visible := False;
  FExtrudeDraft := FExtrudeSaved;
  FSketchMode.SetExtrudePreview(False, FExtrudeSaved);
  UpdateExtrudeGripPosition;
end;

{ Legacy documents may contain evaluator features without a logical Sketch
  object. Bind them on the first edit without duplicating geometry. }
function TCADAppController.EnsureSketchObject(const AFeature: TCADId;
  out ASketchId: TCADObjectId; out AError: string): Boolean;
var
  Ref: TCADObjectRef;
begin
  ASketchId := FDoc.Objects.SketchFeatureOwner(AFeature);
  if CADObjectIdValid(ASketchId) then Exit(True);
  Result := FDoc.Objects.TryAddSketch(
    CADObjectRef(cokPart,FDoc.Objects.PartId),
    CADObjectRef(cokDatumPlane,FDoc.Objects.XYPlaneId),
    FDoc.Find(AFeature).Name,ASketchId,AError);
  if not Result then Exit;
  Ref := CADObjectRef(cokSketch,ASketchId);
  if FDoc.TryBindSketchFeature(Ref,AFeature,AError) then Exit(True);
  { No partial logical Sketch on a failed bind. }
  if not FDoc.Objects.TryRemove(Ref,AError) then
    raise Exception.Create('Sketch object rollback failed: '+AError);
  ASketchId := CADNoObjectId;
  Result := False;
end;

procedure TCADAppController.FinishSketch;
var
  SketchObjectId: TCADObjectId;
  BodyObject: TCADModelObject;
  NewOperation: TCADCreateSketchExtrudeCommand;
  SketchFeature, ExtrudeFeature, F: TCADFeature;
  Err: string;
begin
  if (FExtrudePanel <> nil) and FExtrudePanel.Visible then
  begin
    if FExtrudeInlineInvalid then
    begin
      FExtrudeStatus.Text:='Correct the inline depth before saving';
      Exit;
    end;
    { A typed value is committed even when the user clicks Exit Sketch
      directly instead of pressing Enter in the depth input. }
    if not ReadExtrudeDepth then Exit;
    FSketchMode.SetExtrudePreview(True, FExtrudeDraft);
    if FSketchMode.ExtrudePreviewError <> '' then
    begin
      FExtrudeStatus.Text := FSketchMode.ExtrudePreviewError;
      Exit;                              { do not commit an invalid solid }
    end;
    FExtrudeSaved := FExtrudeDraft;
  end;
  if CADIdValid(FEditSketch) and (FSketchMode.Sketch <> nil) then
  begin
    { Edited sketch and its existing linked extrusion retain their identity. }
    if not EnsureSketchObject(FEditSketch,SketchObjectId,Err) then
    begin
      W.Status.Text := 'Cannot bind Sketch: '+Err;
      Exit;
    end;
    if not FHistory.Execute(TCADCommitSketchCommand.Create(
      CADObjectRef(cokSketch,SketchObjectId),
      CADSketchToText(FSketchMode.Sketch),
      FSketchMode.ContoursText)) then
    begin
      { An unchanged Sketch is a successful no-op; no history entry. }
      if (FDoc.Find(FEditSketch).GetParamValue('geometry').S <>
           CADSketchToText(FSketchMode.Sketch)) or
         (FDoc.Find(FEditSketch).GetParamValue('contours').S <>
           FSketchMode.ContoursText) then
      begin
        W.Status.Text := 'Cannot commit Sketch geometry';
        Exit;
      end;
    end;
    if CADIdValid(FEditExtrude) and
       (FDoc.Find(FEditExtrude) is TCADExtrudeFeature) then
    begin
      FDoc.SetParam(FEditExtrude, 'length', CADFloat(FExtrudeSaved.Depth));
      FDoc.SetParam(FEditExtrude, 'symmetric', CADBool(FExtrudeSaved.Symmetric));
      FDoc.SetParam(FEditExtrude, 'reversed', CADBool(FExtrudeSaved.Reversed));
    end;
    FLastSketch := FEditSketch;
    FEditSketch := CADNoId;
    FEditExtrude := CADNoId;
  end
  else if (FSketchMode.Sketch <> nil) and (FSketchMode.Sketch.EntityCount > 0) then
  begin
    { Do not create unowned extrudes or replace a Body's existing solid. }
    BodyObject := FDoc.Objects.Find(CADObjectRef(cokBody,FActiveBody));
    if BodyObject = nil then
    begin
      W.Status.Text := 'Create New Body first, then finish the Sketch';
      Exit;
    end;
    if BodyObject.FeatureCount <> 0 then
    begin
      W.Status.Text := 'Active Body is not empty: use New Body for a separate Extrude';
      Exit;
    end;
    SketchFeature := TCADSketchFeature.Create;
    SketchFeature.Name := Format('Sketch %d',[FSketchCount+1]);
    SketchFeature.SetParamValue('geometry',
      CADSketchValue(FSketchMode.Sketch));
    SketchFeature.SetParamValue('contours',
      CADText(FSketchMode.ContoursText));
    ExtrudeFeature := TCADExtrudeFeature.Create;
    ExtrudeFeature.Name := Format('Extrude %d',[FSketchCount+1]);
    ExtrudeFeature.SetParamValue('length',CADFloat(FExtrudeSaved.Depth));
    ExtrudeFeature.SetParamValue('symmetric',CADBool(FExtrudeSaved.Symmetric));
    ExtrudeFeature.SetParamValue('reversed',CADBool(FExtrudeSaved.Reversed));
    NewOperation := TCADCreateSketchExtrudeCommand.Create(
      CADObjectRef(cokBody,FActiveBody),
      CADObjectRef(cokPart,FDoc.Objects.PartId),
      CADObjectRef(cokDatumPlane,FDoc.Objects.XYPlaneId),
      SketchFeature,ExtrudeFeature);
    { History owns the composite command, including both feature instances. }
    if not FHistory.Execute(NewOperation) then
    begin
      W.Status.Text := 'Cannot create Sketch and Extrude in Body';
      Exit;
    end;
    Inc(FSketchCount);
    FLastSketch := NewOperation.SketchFeatureId;
  end;
  FSketchMode.Leave;
  FExtrudePanel.Visible := False;
  UpdateExtrudeGripPosition;
  ShowDocumentObjects(True);
  Rebuild(True);
end;

procedure TCADAppController.NewBody(Sender: TObject);
var
  C: TCADCreateBodyCommand;
  N, I: Integer;
  O: TCADModelObject;
  Name: string;
begin
  if (FDoc = nil) or (FHistory = nil) or FSketchMode.Active then Exit;
  { An empty Body has no BRep. It becomes the home for later features. }
  N := 1;
  repeat
    Name := Format('Body%.3d',[N]);
    Inc(N);
    { Names are labels, but avoid collisions even after deleting a Body.
      Reusing a label never implies reusing its stable Object ID. }
    I := 0;
    while I < FDoc.Objects.ObjectCount do
    begin
      O := FDoc.Objects.ObjectAt(I);
      if O.Active and (O.Kind = cokBody) and (O.Name = Name) then
        Break;
      Inc(I);
    end;
  until I = FDoc.Objects.ObjectCount;
  C := TCADCreateBodyCommand.Create(
    CADObjectRef(cokPart,FDoc.Objects.PartId),Name);
  if FHistory.Execute(C) then
  begin
    FActiveBody := C.Id;
    FTree.Refresh(FDoc,True);
    W.Status.Text := 'Created '+Name+' (active)';
  end
  else
    W.Status.Text := 'Could not create Body';
end;

procedure TCADAppController.SelectBody(Sender: TObject;
  const AId: TCADObjectId);
var
  O: TCADModelObject;
begin
  if (FDoc = nil) or FSketchMode.Active then Exit;
  O := FDoc.Objects.Find(CADObjectRef(cokBody,AId));
  if O = nil then Exit;
  FActiveBody := AId;
  W.Status.Text := 'Active Body: '+O.Name;
end;

procedure TCADAppController.NewSketch(Sender: TObject);
begin
  if FDoc = nil then
    Exit;
  ShowDocumentObjects(False);
  FEditSketch := CADNoId;
  FEditExtrude := CADNoId;
  FExtrudeSaved := CADDefaultExtrudeOptions;
  FExtrudeDraft := FExtrudeSaved;
  FSketchMode.Enter([0, 0, 0], [1, 0, 0], [0, 0, 1]);
  ModeChanged;
end;

{ The sketch of the selected body (an Extrude's input, or a Sketch), else the
  last sketch made or edited. }
function TCADAppController.SketchToEdit: TCADId;
var
  F: TCADFeature;
begin
  Result := CADNoId;
  F := nil;
  if W.View.Selection.ObjectId <> 0 then
    F := FDoc.Find(TCADViewSync.FeatureOf(W.View.Selection.ObjectId));
  if (F is TCADExtrudeFeature) and (Length(F.Inputs) > 0) then
    F := FDoc.Find(F.Inputs[0]);
  if F is TCADSketchFeature then
    Exit(F.Id);
  F := FDoc.Find(FLastSketch);
  if F is TCADSketchFeature then
    Result := F.Id;
end;

{ Typing in an edit box keeps its keys. }
procedure TCADAppController.KeyDown(var Key: Word; Shift: TShiftState);
var
  Handled: Boolean;
begin
  if FSketchMode = nil then
    Exit;
  if (FHost.UI <> nil) and (FHost.UI.FocusedWidget is TUIEdit) then
    Exit;
  if (Key = VK_F) and (Shift * [ssCtrl, ssAlt, ssShift] = []) then
  begin
    FChrome.ZoomFit;                       { F: zoom to fit, in any mode }
    Key := 0;
    Exit;
  end;
  if not FSketchMode.Active then
  begin
    if (Key = VK_Z) and (Shift * [ssCtrl,ssAlt,ssShift] = [ssCtrl]) then
    begin
      Run(cadUndo);
      Key := 0;
      Exit;
    end;
    if (Key = VK_Y) and (Shift * [ssCtrl,ssAlt,ssShift] = [ssCtrl]) then
    begin
      Run(cadRedo);
      Key := 0;
      Exit;
    end;
    if (Key = VK_B) and (Shift * [ssCtrl, ssAlt, ssShift] = [ssCtrl]) then
    begin
      NewBody(nil);
      Key := 0;
    end;
    Exit;
  end;
  { a digit starts a typed value (its character goes into the box) }
  if FTyped.KeyStarts(Key, Shift) then
    Exit;
  Handled := True;
  if ssCtrl in Shift then
    case Key of
      VK_Z: if ssShift in Shift then FSketchToolbar.Run(ctaRedo) else FSketchToolbar.Run(ctaUndo);
      VK_Y: FSketchToolbar.Run(ctaRedo);
      VK_RETURN: FSketchToolbar.Run(ctaFinish);
    else
      Handled := False;
    end
  else
    case Key of
      VK_S: FSketchToolbar.Run(ctaSelect);
      VK_L: FSketchToolbar.Run(ctaLine);
      VK_R: FSketchToolbar.Run(ctaRect);
      VK_C: FSketchToolbar.Run(ctaCircle);
      VK_A: FSketchToolbar.Run(ctaArc);
      VK_T: FSketchToolbar.Run(ctaArc3);
      VK_P: FSketchToolbar.Run(ctaPoint);
      VK_E: ExtrudePreviewClick(nil);      { E: live Extrude preview }
      VK_D: FSketchToolbar.Run(ctaDimension);
      VK_X: FSketchToolbar.Run(ctaDistX);
      VK_Y: FSketchToolbar.Run(ctaDistY);
      VK_H: FSketchPanel.RunCommand(sccHorizontal);
      VK_V: FSketchPanel.RunCommand(sccVertical);
      VK_N: FSketchToolbar.Run(ctaNormalView);
      VK_DELETE: FSketchPanel.DeleteSelected;
      VK_ESCAPE:
        begin
          { first Esc drops the shape being drawn (Smart Dimension: the
            picked items), the next one goes to Select }
          if (FExtrudePanel <> nil) and FExtrudePanel.Visible then
            ExtrudeCancelClick(nil)
          else if FSketchMode.LineEditActive then
            FSketchToolbar.Run(ctaSelect)
          else if FSketchMode.Editor.Busy then
            FSketchToolbar.Run(ctaCancel)
          else if FSketchMode.SmartDimension and
            (Length(FSketchMode.Editor.Selection.Points) + Length(FSketchMode.Editor.Selection.Entities) > 0) then
            FSketchMode.ClearSelection
          else
            FSketchToolbar.Run(ctaSelect);
        end;
    else
      Handled := False;
    end;
  if Handled then
    Key := 0;
end;

procedure TCADAppController.EditSketchClick(Sender: TObject);
var
  Id: TCADId;
begin
  if (FDoc = nil) or FSketchMode.Active then
    Exit;
  FEditExtrude := CADNoId;
  if W.View.Selection.ObjectId <> 0 then
  begin
    { Find the selected extrusion before SketchToEdit maps it to its input. }
    if FDoc.Find(TCADViewSync.FeatureOf(W.View.Selection.ObjectId)) is TCADExtrudeFeature then
      FEditExtrude := TCADViewSync.FeatureOf(W.View.Selection.ObjectId);
  end;
  Id := SketchToEdit;
  if not CADIdValid(Id) then
  begin
    W.Status.Text := 'Select a body made from a sketch first (click it), then Edit sketch';
    Exit;
  end;
  OpenSketchOf(Id);
end;

{ Each tree feature activates its own editing tool. A Sketch opens
  the sketch editor. An Extrude loads its profile for preview but opens the
  Extrude options immediately, so the user edits Depth/Reverse/Symmetric
  rather than having to discover the preview button manually. }
procedure TCADAppController.EditFeature(Sender: TObject; const AId: TCADId);
var
  F, Profile: TCADFeature;
  ExtrudeId: TCADId;
begin
  if (FDoc = nil) or FSketchMode.Active then Exit;
  F := FDoc.Find(AId);
  if F = nil then Exit;
  FEditExtrude := CADNoId;
  if F is TCADSketchFeature then
  begin
    OpenSketchOf(F.Id);
    Exit;
  end;
  if F is TCADExtrudeFeature then
  begin
    if Length(F.Inputs) = 0 then
    begin
      W.Status.Text := F.Name + ': missing Sketch input';
      Exit;
    end;
    Profile := FDoc.Find(F.Inputs[0]);
    if not (Profile is TCADSketchFeature) then
    begin
      W.Status.Text := F.Name + ': Sketch input is unavailable';
      Exit;
    end;
    ExtrudeId := F.Id;
    FEditExtrude := ExtrudeId;
    OpenSketchOf(Profile.Id);
    if FSketchMode.Active and CADIdEqual(FEditExtrude,ExtrudeId) then
    begin
      ExtrudePreviewClick(nil);
      W.Status.Text := 'Editing '+F.Name+' (Depth / Reverse / Symmetric)';
    end;
    Exit;
  end;
  W.Status.Text := F.Name + ': no editor for this feature type yet';
end;

{ Editing an existing Sketch directly from the tree must load the settings
  of its linked extrusion too, not silently fall back to 10 mm. The slot
  array contains stable feature IDs, so search from newest to oldest. }
function TCADAppController.LinkedExtrudeOfSketch(const AId: TCADId): TCADId;
var
  I: Integer;
  F: TCADFeature;
begin
  Result := CADNoId;
  if (FDoc = nil) or not CADIdValid(AId) then Exit;
  for I := FDoc.SlotCount - 1 downto 0 do
  begin
    F := FDoc.Find(CADId(I));
    if not (F is TCADExtrudeFeature) then Continue;
    if (Length(F.Inputs) > 0) and CADIdEqual(F.Inputs[0], AId) then
      Exit(F.Id);
  end;
end;

procedure TCADAppController.OpenSketchOf(const AId: TCADId);
var
  Id: TCADId;
  S: TCADSketch;
begin
  Id := AId;
  S := TCADSketch.Create;
  try
    CADSketchFromText(FDoc.Find(Id).GetParamValue('geometry').S, S);
  except
    on E: Exception do
    begin
      S.Free;
      W.Status.Text := 'Cannot open the sketch: ' + E.Message;
      Exit;
    end;
  end;
  ShowDocumentObjects(False);
  FEditSketch := Id;
  FSketchMode.EnterSketch(S);
  FSketchMode.LoadContours(FDoc.Find(Id).GetParamValue('contours').S);
  if not CADIdValid(FEditExtrude) then
    FEditExtrude := LinkedExtrudeOfSketch(Id);
  FExtrudeSaved := CADDefaultExtrudeOptions;
  if CADIdValid(FEditExtrude) and
     (FDoc.Find(FEditExtrude) is TCADExtrudeFeature) then
  begin
    FExtrudeSaved.Depth := FDoc.Find(FEditExtrude).GetParamValue('length').F;
    FExtrudeSaved.Symmetric := FDoc.Find(FEditExtrude).GetParamValue('symmetric').B;
    FExtrudeSaved.Reversed := FDoc.Find(FEditExtrude).GetParamValue('reversed').B;
  end;
  FExtrudeDraft := FExtrudeSaved;
  ModeChanged;
end;

{ Confirmation corner X: leave the sketch, the document keeps the old one. }
procedure TCADAppController.DiscardSketch;
begin
  if not FSketchMode.Active then
    Exit;
  FSketchMode.Leave;
  FEditSketch := CADNoId;
  FEditExtrude := CADNoId;
  ShowDocumentObjects(True);
  ModeChanged;
  W.Status.Text := 'Sketch changes discarded';
end;

procedure TCADAppController.DiscardClick(Sender: TObject);
begin
  DiscardSketch;
end;

procedure TCADAppController.FinishClick(Sender: TObject);
begin
  FinishSketch;
  ModeChanged;
end;

procedure TCADAppController.RelationClick(Sender: TObject; AConstraint: Integer);
begin
  FSketchPanel.SelectConstraint(AConstraint);
end;

procedure TCADAppController.SketchStatus(Sender: TObject; const AText: string);
begin
  W.Status.Text := AText;
end;

procedure TCADAppController.SketchChanged(Sender: TObject);
begin
  if FSketchPanel <> nil then
    FSketchPanel.Refresh;
  if FSketchDims <> nil then
    FSketchDims.Refresh;
  if FSketchToolbar <> nil then
    FSketchToolbar.Refresh;
  if FTyped <> nil then
    FTyped.HideIfUnfocused;
  if FChrome <> nil then
    FChrome.SetDof(DofText);
  if FSketchMode.Active then
  begin
    W.Status.Text := FSketchMode.StatusText;
    if (FExtrudePanel <> nil) and FExtrudePanel.Visible then
    begin
      if FSketchMode.ExtrudePreviewError <> '' then
        FExtrudeStatus.Text := FSketchMode.ExtrudePreviewError
      else
        FExtrudeStatus.Text := Format('OCCT preview | %.3f mm',
          [FExtrudeDraft.Depth]);
    end;
  end
  else
    W.Status.Text := NavigationHint;
  UpdateExtrudeGripPosition;
end;

procedure TCADAppController.RadiusChanged;
begin
  { Historical designer event handler. No demo geometry is created or
    modified in a normal document. }
end;

function TCADAppController.Describe(const AId: TPick3DId): string;
const
  KindName: array[TPick3DKind] of string = ('none', 'body', 'face', 'edge', 'vertex');
var
  F: TCADFeature;
begin
  if AId.Kind = pkNone then
    Exit('-');
  F := FDoc.Find(TCADViewSync.FeatureOf(AId.ObjectId));
  if F <> nil then
    Result := F.Name
  else
    Result := Format('object %d', [AId.ObjectId]);
  if AId.Kind <> pkObject then
    Result := Format('%s, %s %d', [Result, KindName[AId.Kind], AId.Element]);
end;

procedure TCADAppController.PickChanged(Sender: TObject);
begin
  if W.View.LastError <> '' then
    W.Status.Text := 'GL error: ' + W.View.LastError;
  W.Selected.Text := 'Selected: ' + Describe(W.View.Selection);
  W.Hover.Text := 'Hover: ' + Describe(W.View.Preselection);
end;

end.
