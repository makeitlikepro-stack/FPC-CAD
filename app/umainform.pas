unit UMainForm;

{$mode objfpc}{$H+}
{$codepage utf8}

{ ROLE:      FPC-CAD main window, designed in FPC Visual IDE
             (app/MainForm.fvform). The IDE keeps one field per widget in
             the first section of the class and adds event handlers there
             (double-click a widget). Only the wiring lives here; the
             application itself is CAD.App.Controller.
  CALLED BY: app/fpc_cad.lpr (Application.CreateForm).
  CALLS:     CAD.App.Controller.
  THREADS:   UI thread.
  SPEED:     nothing here; see the controller. }

interface

uses
  Classes, SysUtils, Forms, OpenGL.ECS.Widgets, OpenGL.UI.Form,
  OpenGL.UI.Viewport3D, CAD.App.Controller;

type
  TMainForm = class(TUIForm)
    TitleBar: TUIPanel;
    AppNameLabel: TUILabel;
    MainMenu: TUIMenuBar;
    DocLabel: TUILabel;
    Ribbon: TUITabs;
    FeaturesPage: TUIPanel;
    NewSketchButton: TUIButton;
    EditSketchButton: TUIButton;
    FeatSketchGroupLabel: TUILabel;
    FeatSketchGroupLabelLine: TUIPanel;
    ExtrudeButton: TUIButton;
    RevolveButton: TUIButton;
    CutButton: TUIButton;
    FilletButton: TUIButton;
    ChamferButton: TUIButton;
    PatternButton: TUIButton;
    MirrorButton: TUIButton;
    HoleButton: TUIButton;
    FeatGroupLabel: TUILabel;
    FeatGroupLabelLine: TUIPanel;
    PlaneButton: TUIButton;
    AxisButton: TUIButton;
    FeatRefGroupLabel: TUILabel;
    SketchPage: TUIPanel;
    FinishButton: TUIButton;
    DimensionButton: TUIButton;
    DistXButton: TUIButton;
    DistYButton: TUIButton;
    SkSketchGroupLabel: TUILabel;
    SkSketchGroupLabelLine: TUIPanel;
    SelectButton: TUIButton;
    LineButton: TUIButton;
    RectButton: TUIButton;
    CircleButton: TUIButton;
    ArcButton: TUIButton;
    Arc3Button: TUIButton;
    PointButton: TUIButton;
    SlotButton: TUIButton;
    PolygonButton: TUIButton;
    SkDrawGroupLabel: TUILabel;
    SkDrawGroupLabelLine: TUIPanel;
    TrimButton: TUIButton;
    ExtendButton: TUIButton;
    OffsetButton: TUIButton;
    SketchMirrorButton: TUIButton;
    SketchFilletButton: TUIButton;
    SkModifyGroupLabel: TUILabel;
    SkModifyGroupLabelLine: TUIPanel;
    HorizontalButton: TUIButton;
    VerticalButton: TUIButton;
    CoincidentButton: TUIButton;
    ParallelButton: TUIButton;
    PerpendicularButton: TUIButton;
    EqualButton: TUIButton;
    TangentButton: TUIButton;
    ConcentricButton: TUIButton;
    MidpointButton: TUIButton;
    OnObjectButton: TUIButton;
    SymmetricButton: TUIButton;
    FixButton: TUIButton;
    SkRelGroupLabel: TUILabel;
    SkRelGroupLabelLine: TUIPanel;
    UndoButton: TUIButton;
    RedoButton: TUIButton;
    CancelButton: TUIButton;
    NormalViewButton: TUIButton;
    SkEditGroupLabel: TUILabel;
    ActiveToolMark: TUIPanel;
    ViewPage: TUIPanel;
    ZoomFitButton: TUIButton;
    NormalToButton: TUIButton;
    EdgesButton: TUIButton;
    ViewGroupLabel: TUILabel;
    LeftTabs: TUITabs;
    ModelPage: TUIPanel;
    FeatureTree: TUITreeView;
    PropertiesPage: TUIPanel;
    PartGroup: TUIGroupBox;
    TitleLabel: TUILabel;
    RadiusLabel: TUILabel;
    RadiusSlider: TUISlider;
    SelectedLabel: TUILabel;
    HoverLabel: TUILabel;
    RecomputeLabel: TUILabel;
    ComputedLabel: TUILabel;
    MeshesLabel: TUILabel;
    SyncLabel: TUILabel;
    SketchGroup: TUIGroupBox;
    RelationsLabel: TUILabel;
    ConstraintList: TUIListBox;
    ValueEdit: TUIEdit;
    SetButton: TUIButton;
    DeleteButton: TUIButton;
    DofLabel: TUILabel;
    View: TUIViewport3D;
    ViewToolbar: TUIPanel;
    VtZoomFitButton: TUIButton;
    VtNormalButton: TUIButton;
    VtEdgesButton: TUIButton;
    ConfirmCorner: TUIPanel;
    ExitSketchCornerButton: TUIButton;
    DiscardSketchButton: TUIButton;
    DrawValueEdit: TUIEdit;
    StatusBar: TUIPanel;
    StatusLabel: TUILabel;
    ModeLabel: TUILabel;
    DofStatusLabel: TUILabel;
    UnitsLabel: TUILabel;
    procedure FormCreate(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure RadiusSliderChange(Sender: TObject);
    procedure MenuExitClick(Sender: TObject);
    procedure MenuUndoClick(Sender: TObject);
    procedure MenuRedoClick(Sender: TObject);
    procedure MenuZoomFitClick(Sender: TObject);
    procedure MenuNormalToClick(Sender: TObject);
    procedure MenuEdgesClick(Sender: TObject);
    procedure MenuSketchClick(Sender: TObject);
    procedure MenuEditSketchClick(Sender: TObject);
  private
    FApp: TCADAppController;
    procedure LayoutLater(Data: PtrInt);
  protected
    { The program is built into the repo root; the design stays in app/. }
    function DesignFileName: string; override;
    procedure DesignLoaded; override;
    procedure DoOnResize; override;
  public
    destructor Destroy; override;
  end;

var
  MainForm: TMainForm;

implementation

function TMainForm.DesignFileName: string;
begin
  Result := inherited DesignFileName;
  if not FileExists(Result) then
    Result := ExtractFilePath(Result) + 'app' + PathDelim + ExtractFileName(Result);
end;

procedure TMainForm.FormCreate(Sender: TObject);
begin
  CADUseStyleSheet(Host);
end;

{ After GPU setup: the widgets of the design exist and are bound; the
  controller finds the ones it uses by id. }
procedure TMainForm.DesignLoaded;
begin
  FApp := TCADAppController.Create(Host, Design.Root, @Widget,
    Design.MaxDocumentRenderOrder + 1);
  FApp.Start;
end;

procedure TMainForm.DoOnResize;
begin
  inherited DoOnResize;
  if FApp = nil then
    Exit;
  FApp.Layout;
  { once more after TUIForm's own queued root fit }
  Application.QueueAsyncCall(@LayoutLater, 0);
end;

procedure TMainForm.LayoutLater(Data: PtrInt);
begin
  if FApp <> nil then
    FApp.Layout;
end;

procedure TMainForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if FApp <> nil then
    FApp.KeyDown(Key, Shift);
end;

procedure TMainForm.RadiusSliderChange(Sender: TObject);
begin
  if FApp <> nil then
    FApp.RadiusChanged;
end;

procedure TMainForm.MenuExitClick(Sender: TObject);
begin
  Close;
end;

procedure TMainForm.MenuUndoClick(Sender: TObject);
begin
  if FApp <> nil then
    FApp.Run(cadUndo);
end;

procedure TMainForm.MenuRedoClick(Sender: TObject);
begin
  if FApp <> nil then
    FApp.Run(cadRedo);
end;

procedure TMainForm.MenuZoomFitClick(Sender: TObject);
begin
  if FApp <> nil then
    FApp.Run(cadZoomFit);
end;

procedure TMainForm.MenuNormalToClick(Sender: TObject);
begin
  if FApp <> nil then
    FApp.Run(cadNormalTo);
end;

procedure TMainForm.MenuEdgesClick(Sender: TObject);
begin
  if FApp <> nil then
    FApp.Run(cadToggleEdges);
end;

procedure TMainForm.MenuSketchClick(Sender: TObject);
begin
  if FApp <> nil then
    FApp.Run(cadNewSketch);
end;

procedure TMainForm.MenuEditSketchClick(Sender: TObject);
begin
  if FApp <> nil then
    FApp.Run(cadEditSketch);
end;

destructor TMainForm.Destroy;
begin
  Application.RemoveAsyncCalls(Self);
  FreeAndNil(FApp);
  inherited Destroy;
end;

end.
