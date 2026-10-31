unit CAD.App.Controller;
{$mode objfpc}{$H+}
{$codepage utf8}

{ ROLE:      the FPC-CAD application behind the designed main window: OCCT,
             document, viewport sync, the demo plate, sketch mode with its
             panel, toolbar and dimension chips, keyboard shortcuts, and the
             window-edge layout (the design has no anchors yet). Every widget
             is designed in FPC Visual IDE (app/MainForm.fvform) and found by
             id; only the dimension chips are made here (one per dimension).
  CALLED BY: UMainForm (app/umainform.pas): Create + Start after GPU setup,
             Layout on resize, KeyDown, RadiusChanged.
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
  OpenGL.Render.Picking3D,
  CAD.Config.Performance, CAD.Core.Ids, CAD.Core.Feature, CAD.Core.Document,
  CAD.OCCT.Bridge, CAD.View.MeshConvert, CAD.View.Sync, CAD.View.ViewportTarget,
  CAD.Core.Values, CAD.Sketch.Model, CAD.Sketch.Text, CAD.Sketch.Editor,
  CAD.Sketch.Commands, CAD.Features.Sketch, CAD.Features.Extrude,
  CAD.App.DemoScene, CAD.App.SketchMode, CAD.App.SketchPanel, CAD.App.SketchDims,
  CAD.App.SketchToolbar, CAD.App.DesignLookup, CAD.App.TypedValue;

type
  { The widgets of app/MainForm.fvform the application uses. }
  TCADAppWidgets = record
    Root: TUIWidget;
    View: TUIViewport3D;
    SidePanel: TUIPanel;
    RadiusLabel: TUILabel;
    Radius: TUISlider;
    Selected, Hover, Recompute, Computed, Meshes, Sync: TUILabel;
    Status: TUILabel;
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
    FTarget: TCADViewportTarget;
    FSync: TCADViewSync;
    FScene: TCADDemoScene;
    FSceneOk: Boolean;
    FSketchMode: TCADSketchMode;
    FSketchPanel: TCADSketchPanel;
    FSketchDims: TCADSketchDims;
    FSketchToolbar: TCADSketchToolbar;
    FTyped: TCADTypedValueBox;            { typed values while drawing }
    FEditSketch: TCADId;                  { sketch feature being edited; CADNoId = new }
    FLastSketch: TCADId;
    FSketchCount: Integer;
    procedure NewSketch(Sender: TObject);
    procedure FinishClick(Sender: TObject);
    procedure EditSketchClick(Sender: TObject);
    function SketchToEdit: TCADId;
    procedure SketchChanged(Sender: TObject);
    procedure SketchStatus(Sender: TObject; const AText: string);
    procedure RelationClick(Sender: TObject; AConstraint: Integer);
    procedure FinishSketch;
    procedure ShowDocumentObjects(AVisible: Boolean);
    procedure PickChanged(Sender: TObject);
    function LoadOCCT: string;
    procedure Rebuild(AFit: Boolean);
    function Describe(const AId: TPick3DId): string;
    procedure ModeChanged;
  public
    { ARoot: the design's root; ALookup: TUIForm.Widget; AOverlayOrder: first
      paint order above the design (Design.MaxDocumentRenderOrder + 1). }
    constructor Create(AHost: TUIHostControl; ARoot: TUIWidget;
      ALookup: TCADWidgetLookup; AOverlayOrder: Integer);
    destructor Destroy; override;
    { OCCT, document, demo scene, sketch UI; once, after GPU setup. }
    procedure Start;
    { Window edges: view fills the left, side panel keeps its designed width
      on the right, status line at the bottom. Everything inside keeps its
      designed place. }
    procedure Layout;
    { SolidWorks-like shortcuts while a sketch is open. }
    procedure KeyDown(var Key: Word; Shift: TShiftState);
    procedure RadiusChanged;
  end;

{ The engine demo style sheet when FPC_OPENGL_UI_ENGINE names the engine. }
procedure CADUseEngineStyleSheet(AHost: TUIHostControl);

implementation

const
  StartRadius = 4.0;
  NavigationHint = 'left drag: orbit, middle/right: pan, wheel: zoom, click: select';

procedure CADUseEngineStyleSheet(AHost: TUIHostControl);
var
  EngineDir: string;
begin
  EngineDir := GetEnvironmentVariable('FPC_OPENGL_UI_ENGINE');
  if EngineDir <> '' then
    AHost.StyleSheetFile := IncludeTrailingPathDelimiter(EngineDir) + 'demo/styles/ui.css';
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
  W.SidePanel := TUIPanel(CADDesignWidget(ALookup, 'SidePanel', TUIPanel));
  W.RadiusLabel := L('RadiusLabel');
  W.Radius := TUISlider(CADDesignWidget(ALookup, 'RadiusSlider', TUISlider));
  W.Selected := L('SelectedLabel');
  W.Hover := L('HoverLabel');
  W.Recompute := L('RecomputeLabel');
  W.Computed := L('ComputedLabel');
  W.Meshes := L('MeshesLabel');
  W.Sync := L('SyncLabel');
  W.Status := L('StatusLabel');
  FEditSketch := CADNoId;
  FLastSketch := CADNoId;
end;

destructor TCADAppController.Destroy;
begin
  FreeAndNil(FTyped);
  FreeAndNil(FSketchToolbar);
  FreeAndNil(FSketchDims);
  FreeAndNil(FSketchPanel);
  FreeAndNil(FSketchMode);
  { Sync and target point at the viewport; the document's cache frees OCCT
    shapes, so it goes before the bridge. Widgets belong to the form. }
  FreeAndNil(FSync);
  FreeAndNil(FTarget);
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
  W.Radius.Minimum := CAD_DEMO_MIN_RADIUS;
  W.Radius.Maximum := CAD_DEMO_MAX_RADIUS;
  W.Radius.Step := 0.25;
  W.Radius.Value := StartRadius;
  W.RadiusLabel.Text := Format('Hole radius: %.2f mm', [StartRadius]);
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
  Layout;
  Err := LoadOCCT;
  FDoc := TCADDocument.Create;
  FTarget := TCADViewportTarget.Create(W.View);
  FSync := TCADViewSync.Create(FDoc, FTarget, @CADFillMeshFromResult);
  if Err = '' then
  begin
    FSceneOk := BuildDemoScene(FDoc, StartRadius, FScene, Err);
    if FSceneOk then
      Rebuild(True);
  end;
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
var
  RW, RH, PW, SH, VW, VH: Double;
begin
  if (FSketchPanel = nil) or (W.Root = nil) then
    Exit;
  RW := Max(1, W.Root.Width);
  RH := Max(1, W.Root.Height);
  PW := W.SidePanel.Width;
  SH := W.Status.Height;
  VW := Max(1, RW - PW);
  VH := Max(1, RH - SH);
  W.View.Width := VW;
  W.View.Height := VH;
  W.View.Left := 0;
  W.View.Top := 0;
  FHost.UI.ResizeWidgetKeepingChildren(FOverlay, VW, VH);
  FOverlay.Left := 0;
  FOverlay.Top := 0;
  FHost.UI.ResizeWidgetKeepingChildren(W.SidePanel, PW, VH);
  W.SidePanel.Left := VW;
  W.SidePanel.Top := 0;
  W.Status.Width := Max(1, RW - 2 * W.Status.Left);
  W.Status.Top := VH;
end;

{ Sketch opened or closed: toolbar shown / hidden, panel parts enabled. }
procedure TCADAppController.ModeChanged;
begin
  FSketchToolbar.UpdateVisible;
  FSketchPanel.UpdateEnabled;
  FTyped.Hide;
end;

procedure TCADAppController.Rebuild(AFit: Boolean);
var
  R: TCADRecomputeReport;
  S: TCADViewSyncReport;
  F: TCADFeature;
  Err: string;
begin
  R := FDoc.Recompute;
  S := FSync.Sync;
  Err := '';
  F := FDoc.Find(FScene.Last);
  if (F <> nil) and (F.LastError <> '') then
    Err := F.Name + ': ' + F.LastError
  else if S.Failed > 0 then
    Err := FSync.LastError;
  W.Recompute.Text := Format('Recompute: %d ms', [R.Milliseconds]);
  W.Computed.Text := Format('  computed %d, cache hits %d', [R.Computed, R.CacheHits]);
  W.Meshes.Text := Format('  meshes %d in %d ms', [R.Display.Prepared, R.Display.Milliseconds]);
  W.Sync.Text := Format('Sync: %d ms (converted %d)', [S.Milliseconds, S.Updated]);
  if Err <> '' then
    W.Status.Text := 'Error: ' + Err;
  if AFit then
    W.View.FitAll;
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

procedure TCADAppController.FinishSketch;
var
  Sk, Ex: TCADId;
  F: TCADFeature;
  Err: string;
begin
  if CADIdValid(FEditSketch) and (FSketchMode.Sketch <> nil) then
  begin
    { an edited sketch: its feature gets the new text; the extrude follows }
    FDoc.SetParam(FEditSketch, 'geometry', CADSketchValue(FSketchMode.Sketch));
    FLastSketch := FEditSketch;
    FEditSketch := CADNoId;
  end
  else if (FSketchMode.Sketch <> nil) and (FSketchMode.Sketch.EntityCount > 0) then
  begin
    Inc(FSketchCount);
    F := TCADSketchFeature.Create;
    F.Name := Format('Sketch %d', [FSketchCount]);
    F.SetParamValue('geometry', CADSketchValue(FSketchMode.Sketch));
    Sk := FDoc.AttachFeature(F);
    FLastSketch := Sk;
    F := TCADExtrudeFeature.Create;
    F.Name := Format('Extrude %d', [FSketchCount]);
    F.SetParamValue('length', CADFloat(10));
    Ex := FDoc.AttachFeature(F);
    FDoc.TryLink(Ex, Sk, Err);
  end;
  FSketchMode.Leave;
  ShowDocumentObjects(True);
  Rebuild(True);
end;

procedure TCADAppController.NewSketch(Sender: TObject);
begin
  if FDoc = nil then
    Exit;
  ShowDocumentObjects(False);
  FEditSketch := CADNoId;
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
  if (FSketchMode = nil) or not FSketchMode.Active then
    Exit;
  if (FHost.UI <> nil) and (FHost.UI.FocusedWidget is TUIEdit) then
    Exit;
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
      VK_D: FSketchToolbar.Run(ctaDimension);
      VK_X: FSketchToolbar.Run(ctaDistX);
      VK_Y: FSketchToolbar.Run(ctaDistY);
      VK_H: FSketchPanel.RunCommand(sccHorizontal);
      VK_V: FSketchPanel.RunCommand(sccVertical);
      VK_N: FSketchToolbar.Run(ctaNormalView);
      VK_DELETE: FSketchPanel.DeleteSelected;
      VK_ESCAPE:
        begin
          { first Esc drops the shape being drawn, the next one goes to Select }
          if FSketchMode.Editor.Busy then
            FSketchToolbar.Run(ctaCancel)
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
  S: TCADSketch;
begin
  if (FDoc = nil) or FSketchMode.Active then
    Exit;
  Id := SketchToEdit;
  if not CADIdValid(Id) then
  begin
    W.Status.Text := 'Select a body made from a sketch first (click it), then Edit sketch';
    Exit;
  end;
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
  ModeChanged;
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
  if FSketchMode.Active then
    W.Status.Text := FSketchMode.StatusText
  else
    W.Status.Text := NavigationHint;
end;

procedure TCADAppController.RadiusChanged;
begin
  W.RadiusLabel.Text := Format('Hole radius: %.2f mm', [W.Radius.Value]);
  if not FSceneOk then
    Exit;
  SetHoleRadius(FDoc, FScene, W.Radius.Value);
  Rebuild(False);
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
