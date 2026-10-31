unit CAD.App.MainForm;
{$mode objfpc}{$H+}
{$codepage utf8}

{ ROLE:      FPC-CAD main window (stage 4 step 3): engine host, 3D viewport
             fed by the document, a side panel with the hole radius slider,
             selection and timing lines.
  CALLED BY: app/fpc_cad.lpr.
  CALLS:     OCCT bridge (load + options), CAD.Core.Document (Recompute),
             CAD.View.Sync + CAD.View.ViewportTarget + MeshConvert (filler),
             CAD.App.DemoScene, engine widgets and TUIViewport3D.
  THREADS:   UI thread; Recompute uses the worker pool inside and returns
             before Sync runs.
  SPEED:     a slider change = SetParam x6 + Recompute + Sync; only the cut
             chain end is meshed and converted (see the timing line). }

interface

uses
  Classes, SysUtils, Math, Forms, Controls,
  OpenGL.Types, OpenGL.ECS.Widgets, OpenGL.UI.Host, OpenGL.UI.Viewport3D,
  OpenGL.Render.Picking3D,
  CAD.Config.Performance, CAD.Core.Ids, CAD.Core.Feature, CAD.Core.Document,
  CAD.OCCT.Bridge, CAD.View.MeshConvert, CAD.View.Sync, CAD.View.ViewportTarget,
  CAD.Core.Values, CAD.Sketch.Model, CAD.Sketch.Text, CAD.Sketch.Editor,
  CAD.Features.Sketch, CAD.Features.Extrude,
  CAD.App.DemoScene, CAD.App.SketchMode, CAD.App.SketchPanel, CAD.App.SketchDims,
  CAD.App.SketchToolbar, CAD.Sketch.Commands, LCLType;

type
  TCADMainForm = class(TForm)
  private
    FHost: TUIHostControl;
    FOCCT: TOCCTLibrary;
    FDoc: TCADDocument;
    FTarget: TCADViewportTarget;
    FSync: TCADViewSync;
    FScene: TCADDemoScene;
    FSceneOk: Boolean;
    FView: TUIViewport3D;
    FPanel: TUIPanel;
    FTitle, FRadiusLabel, FStatus: TUILabel;
    FLines: array[0..5] of TUILabel;   { 0..1 pick, 2..5 timing (labels are one line) }
    FRadius: TUISlider;
    FSketchMode: TCADSketchMode;
    FSketchPanel: TCADSketchPanel;
    FSketchDims: TCADSketchDims;
    FSketchToolbar: TCADSketchToolbar;
    FEditSketch: TCADId;                  { sketch feature being edited; CADNoId = new }
    FLastSketch: TCADId;
    FSketchCount: Integer;
    procedure HostSetupUI(Sender: TObject);
    procedure NewSketch(Sender: TObject);
    procedure FinishClick(Sender: TObject);
    procedure EditSketchClick(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    function SketchToEdit: TCADId;
    procedure SketchChanged(Sender: TObject);
    procedure SketchStatus(Sender: TObject; const AText: string);
    procedure RelationClick(Sender: TObject; AConstraint: Integer);
    procedure FinishSketch;
    procedure ShowDocumentObjects(AVisible: Boolean);
    procedure HostResize(Sender: TObject);
    procedure RadiusChanged(Sender: TObject);
    procedure PickChanged(Sender: TObject);
    function LoadOCCT: string;
    procedure BuildUI;
    procedure Layout;
    procedure Rebuild(AFit: Boolean);
    function Describe(const AId: TPick3DId): string;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  CADMainForm: TCADMainForm;

implementation

const
  PanelWidth = 260;
  StatusHeight = 26;
  StartRadius = 4.0;

constructor TCADMainForm.Create(AOwner: TComponent);
var
  EngineDir: string;
begin
  inherited CreateNew(AOwner);
  FEditSketch := CADNoId;
  FLastSketch := CADNoId;
  Caption := 'FPC-CAD';
  Width := 1200;
  Height := 760;
  Position := poScreenCenter;
  FHost := TUIHostControl.Create(Self);
  EngineDir := GetEnvironmentVariable('FPC_OPENGL_UI_ENGINE');
  if EngineDir <> '' then
    FHost.StyleSheetFile := IncludeTrailingPathDelimiter(EngineDir) + 'demo/styles/ui.css';
  FHost.Align := alClient;
  FHost.OnSetupUI := @HostSetupUI;
  FHost.OnResize := @HostResize;
  KeyPreview := True;                    { sketch shortcuts reach the form first }
  OnKeyDown := @FormKeyDown;
  FHost.Parent := Self;
end;

destructor TCADMainForm.Destroy;
begin
  FreeAndNil(FSketchToolbar);
  FreeAndNil(FSketchDims);
  FreeAndNil(FSketchPanel);
  FreeAndNil(FSketchMode);
  { Sync and target point at the viewport; the document's cache frees OCCT
    shapes, so it goes before the bridge. Widgets belong to the host. }
  FreeAndNil(FSync);
  FreeAndNil(FTarget);
  FreeAndNil(FDoc);
  inherited Destroy;
  if FOCCT <> nil then
  begin
    SetOCCT(nil);
    FreeAndNil(FOCCT);
  end;
end;

function TCADMainForm.LoadOCCT: string;
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

procedure TCADMainForm.BuildUI;
var
  UI: TUIWidgetFactory;
  I: Integer;
begin
  UI := FHost.UI;
  FView := CreateViewport3D(UI, FHost.Root, 100, 100);
  FView.ShowEdges := True;
  FView.EdgeWidthPx := 1.2;              { user: 2.8 px default looked too thick }
  FView.OnSelectionChanged := @PickChanged;
  FView.OnPreselectionChanged := @PickChanged;

  FPanel := UI.CreatePanel(FHost.Root, 0, 0, PanelWidth, 100, 0,
    tColor4.Create(0.16, 0.17, 0.19, 1));
  FTitle := UI.CreateLabel(FPanel, PanelWidth - 24, 26);
  FTitle.Text := 'Plate with 6 holes';
  FRadiusLabel := UI.CreateLabel(FPanel, PanelWidth - 24, 24);
  FRadius := UI.CreateSlider(FPanel, PanelWidth - 24, 28);
  FRadius.Minimum := CAD_DEMO_MIN_RADIUS;
  FRadius.Maximum := CAD_DEMO_MAX_RADIUS;
  FRadius.Step := 0.25;
  FRadius.Value := StartRadius;
  FRadius.OnChange := @RadiusChanged;
  for I := 0 to High(FLines) do
    FLines[I] := UI.CreateLabel(FPanel, PanelWidth - 24, 24);
  FSketchMode := TCADSketchMode.Create(FView);
  FSketchMode.OnChanged := @SketchChanged;
  FSketchPanel := TCADSketchPanel.Create(UI, FPanel, FSketchMode);
  FSketchPanel.OnNewSketch := @NewSketch;
  FSketchPanel.OnFinish := @FinishClick;
  FSketchPanel.OnEditSketch := @EditSketchClick;
  FSketchPanel.OnStatus := @SketchStatus;
  FSketchToolbar := TCADSketchToolbar.Create(UI, FHost.Root, FSketchMode, FSketchPanel);
  FSketchToolbar.OnFinish := @FinishClick;
  FSketchDims := TCADSketchDims.Create(UI, FHost.Root, FView, FSketchMode);
  FSketchDims.OnStatus := @SketchStatus;
  FSketchDims.OnConstraintClick := @RelationClick;
  FStatus := UI.CreateLabel(FHost.Root, 100, StatusHeight);
  FStatus.TextColor := tColor4.Create(0.85, 0.87, 0.9, 1);
  FRadiusLabel.Text := Format('Hole radius: %.2f mm', [StartRadius]);
  FLines[0].Text := 'Selected: -';
end;

procedure TCADMainForm.HostSetupUI(Sender: TObject);
var
  Err: string;
begin
  BuildUI;
  Layout;
  Err := LoadOCCT;
  FDoc := TCADDocument.Create;
  FTarget := TCADViewportTarget.Create(FView);
  FSync := TCADViewSync.Create(FDoc, FTarget, @CADFillMeshFromResult);
  if Err = '' then
  begin
    FSceneOk := BuildDemoScene(FDoc, StartRadius, FScene, Err);
    if FSceneOk then
      Rebuild(True);
  end;
  if Err <> '' then
    FStatus.Text := Err
  else if FOCCT <> nil then
    FStatus.Text := Format('OCCT %s | left drag: orbit, middle/right: pan, wheel: zoom, click: select',
      [FOCCT.OcctVersion]);
end;

{ Engine geometry: X/Y are the centre offset from the parent centre (Y up);
  Left/Top are the top-left corner in the parent. A parent resize keeps the
  centre offsets, so every child is placed again here, after its parent. }
procedure TCADMainForm.Layout;
var
  W, H, VW, VH, I, Y: Integer;
  Demo: Boolean;

  procedure Place(AWidget: TUIWidget; ALeft, ATop, AWidth, AHeight: Double);
  begin
    AWidget.Width := AWidth;
    AWidget.Height := AHeight;
    AWidget.Left := ALeft;
    AWidget.Top := ATop;
  end;

begin
  W := Max(1, FHost.Width);
  H := Max(1, FHost.Height);
  VW := Max(1, W - PanelWidth);
  VH := Max(1, H - StatusHeight);
  Place(FView, 0, 0, VW, VH);
  Place(FPanel, VW, 0, Max(1, W - VW), VH);
  Place(FStatus, 8, VH, Max(1, W - 16), StatusHeight);
  { the demo part gives its room to the sketch panel while sketching }
  Demo := not FSketchMode.Active;
  FTitle.Visible := Demo;
  FRadiusLabel.Visible := Demo;
  FRadius.Visible := Demo;
  for I := 0 to High(FLines) do
    FLines[I].Visible := Demo;
  Y := 10;
  if Demo then
  begin
    Place(FTitle, 12, 10, PanelWidth - 24, 26);
    Place(FRadiusLabel, 12, 44, PanelWidth - 24, 24);
    Place(FRadius, 12, 70, PanelWidth - 24, 28);
    Y := 112;
    for I := 0 to High(FLines) do
    begin
      if I = 2 then
        Inc(Y, 16);
      Place(FLines[I], 12, Y, PanelWidth - 24, 24);
      Inc(Y, 24);
    end;
    Inc(Y, 16);
  end;
  FSketchPanel.Layout(12, Y, PanelWidth - 24);
  FSketchToolbar.Layout(0, 6, VW);
end;

procedure TCADMainForm.HostResize(Sender: TObject);
begin
  if FHost.Ready and (FView <> nil) then
    Layout;
end;

procedure TCADMainForm.Rebuild(AFit: Boolean);
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
  FLines[2].Text := Format('Recompute: %d ms', [R.Milliseconds]);
  FLines[3].Text := Format('  computed %d, cache hits %d', [R.Computed, R.CacheHits]);
  FLines[4].Text := Format('  meshes %d in %d ms', [R.Display.Prepared, R.Display.Milliseconds]);
  FLines[5].Text := Format('Sync: %d ms (converted %d)', [S.Milliseconds, S.Updated]);
  if Err <> '' then
    FStatus.Text := 'Error: ' + Err;
  if AFit then
    FView.FitAll;
end;

{ Feature objects (not the sketch-mode ones) on or off. Off keeps the sketch
  readable; on goes through the sync again (it knows which are shown). }
procedure TCADMainForm.ShowDocumentObjects(AVisible: Boolean);
var
  I: Integer;
  O: TViewport3DObject;
begin
  for I := 0 to FView.ObjectCount - 1 do
  begin
    O := FView.Objects[I];
    if O.ObjectId < CAD_SKETCH_FIRST_ID then
      O.Visible := False;
  end;
  if AVisible then
  begin
    FSync.Reset;
    FSync.Sync;
  end;
  FView.Invalidate3D;
end;

procedure TCADMainForm.FinishSketch;
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

procedure TCADMainForm.NewSketch(Sender: TObject);
begin
  if FDoc = nil then
    Exit;
  ShowDocumentObjects(False);
  FEditSketch := CADNoId;
  FSketchMode.Enter([0, 0, 0], [1, 0, 0], [0, 0, 1]);
  Layout;
end;

{ The sketch of the selected body (an Extrude's input, or a Sketch), else the
  last sketch made or edited. }
function TCADMainForm.SketchToEdit: TCADId;
var
  F: TCADFeature;
begin
  Result := CADNoId;
  F := nil;
  if FView.Selection.ObjectId <> 0 then
    F := FDoc.Find(TCADViewSync.FeatureOf(FView.Selection.ObjectId));
  if (F is TCADExtrudeFeature) and (Length(F.Inputs) > 0) then
    F := FDoc.Find(F.Inputs[0]);
  if F is TCADSketchFeature then
    Exit(F.Id);
  F := FDoc.Find(FLastSketch);
  if F is TCADSketchFeature then
    Result := F.Id;
end;

{ SolidWorks-like shortcuts while a sketch is open; typing in an edit box
  keeps its keys. }
procedure TCADMainForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
var
  Handled: Boolean;
begin
  if (FSketchMode = nil) or not FSketchMode.Active then
    Exit;
  if (FHost.UI <> nil) and (FHost.UI.FocusedWidget is TUIEdit) then
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

procedure TCADMainForm.EditSketchClick(Sender: TObject);
var
  Id: TCADId;
  S: TCADSketch;
begin
  if (FDoc = nil) or FSketchMode.Active then
    Exit;
  Id := SketchToEdit;
  if not CADIdValid(Id) then
  begin
    FStatus.Text := 'Select a body made from a sketch first (click it), then Edit sketch';
    Exit;
  end;
  S := TCADSketch.Create;
  try
    CADSketchFromText(FDoc.Find(Id).GetParamValue('geometry').S, S);
  except
    on E: Exception do
    begin
      S.Free;
      FStatus.Text := 'Cannot open the sketch: ' + E.Message;
      Exit;
    end;
  end;
  ShowDocumentObjects(False);
  FEditSketch := Id;
  FSketchMode.EnterSketch(S);
  Layout;
end;

procedure TCADMainForm.FinishClick(Sender: TObject);
begin
  FinishSketch;
  Layout;
end;

procedure TCADMainForm.RelationClick(Sender: TObject; AConstraint: Integer);
begin
  FSketchPanel.SelectConstraint(AConstraint);
end;

procedure TCADMainForm.SketchStatus(Sender: TObject; const AText: string);
begin
  FStatus.Text := AText;
end;

procedure TCADMainForm.SketchChanged(Sender: TObject);
begin
  if FSketchPanel <> nil then
    FSketchPanel.Refresh;
  if FSketchDims <> nil then
    FSketchDims.Refresh;
  if FSketchToolbar <> nil then
    FSketchToolbar.Refresh;
  if FSketchMode.Active then
    FStatus.Text := FSketchMode.StatusText
  else
    FStatus.Text := 'left drag: orbit, middle/right: pan, wheel: zoom, click: select';
end;

procedure TCADMainForm.RadiusChanged(Sender: TObject);
begin
  FRadiusLabel.Text := Format('Hole radius: %.2f mm', [FRadius.Value]);
  if not FSceneOk then
    Exit;
  SetHoleRadius(FDoc, FScene, FRadius.Value);
  Rebuild(False);
end;

function TCADMainForm.Describe(const AId: TPick3DId): string;
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

procedure TCADMainForm.PickChanged(Sender: TObject);
begin
  if FView.LastError <> '' then
    FStatus.Text := 'GL error: ' + FView.LastError;
  FLines[0].Text := 'Selected: ' + Describe(FView.Selection);
  FLines[1].Text := 'Hover: ' + Describe(FView.Preselection);
end;

end.
