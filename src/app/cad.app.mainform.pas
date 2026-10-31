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
  CAD.App.DemoScene;

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
    FRadiusLabel, FStatus: TUILabel;
    FLines: array[0..5] of TUILabel;   { 0..1 pick, 2..5 timing (labels are one line) }
    FRadius: TUISlider;
    procedure HostSetupUI(Sender: TObject);
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
  FHost.Parent := Self;
end;

destructor TCADMainForm.Destroy;
begin
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
  Title: TUILabel;
  I: Integer;
begin
  UI := FHost.UI;
  FView := CreateViewport3D(UI, FHost.Root, 100, 100);
  FView.ShowEdges := True;
  FView.OnSelectionChanged := @PickChanged;
  FView.OnPreselectionChanged := @PickChanged;

  FPanel := UI.CreatePanel(FHost.Root, 0, 0, PanelWidth, 100, 0,
    tColor4.Create(0.16, 0.17, 0.19, 1));
  Title := UI.CreateLabel(FPanel, 12, 10, PanelWidth - 24, 26);
  Title.Text := 'Plate with 6 holes';
  FRadiusLabel := UI.CreateLabel(FPanel, 12, 44, PanelWidth - 24, 24);
  FRadius := UI.CreateSlider(FPanel, PanelWidth - 24, 28);
  FRadius.Left := 12;
  FRadius.Top := 70;
  FRadius.Minimum := CAD_DEMO_MIN_RADIUS;
  FRadius.Maximum := CAD_DEMO_MAX_RADIUS;
  FRadius.Step := 0.25;
  FRadius.Value := StartRadius;
  FRadius.OnChange := @RadiusChanged;
  for I := 0 to High(FLines) do
    FLines[I] := UI.CreateLabel(FPanel, 12, 112 + I * 24 + Ord(I >= 2) * 16,
      PanelWidth - 24, 24);
  FStatus := UI.CreateLabel(FHost.Root, 8, 0, 100, StatusHeight);
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

procedure TCADMainForm.Layout;
var
  W, H: Integer;
begin
  W := Max(1, FHost.Width);
  H := Max(1, FHost.Height);
  FPanel.Left := Max(0, W - PanelWidth);
  FPanel.Top := 0;
  FPanel.Width := Min(W, PanelWidth);
  FPanel.Height := Max(1, H - StatusHeight);
  FView.X := 0;
  FView.Y := 0;
  FView.Width := Max(1, W - PanelWidth);
  FView.Height := Max(1, H - StatusHeight);
  FStatus.Left := 8;
  FStatus.Top := H - StatusHeight;
  FStatus.Width := Max(1, W - 16);
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
