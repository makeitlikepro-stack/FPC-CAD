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
    View: TUIViewport3D;
    SketchToolbar: TUIPanel;
    FinishButton: TUIButton;
    SelectButton: TUIButton;
    LineButton: TUIButton;
    RectButton: TUIButton;
    CircleButton: TUIButton;
    ArcButton: TUIButton;
    Arc3Button: TUIButton;
    PointButton: TUIButton;
    DimensionButton: TUIButton;
    DistXButton: TUIButton;
    DistYButton: TUIButton;
    UndoButton: TUIButton;
    RedoButton: TUIButton;
    NormalViewButton: TUIButton;
    CancelButton: TUIButton;
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
    ActiveToolMark: TUIPanel;
    DrawValueEdit: TUIEdit;
    SidePanel: TUIPanel;
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
    NewSketchButton: TUIButton;
    EditSketchButton: TUIButton;
    RelationsLabel: TUILabel;
    ConstraintList: TUIListBox;
    ValueEdit: TUIEdit;
    SetButton: TUIButton;
    DeleteButton: TUIButton;
    DofLabel: TUILabel;
    StatusLabel: TUILabel;
    procedure FormCreate(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure RadiusSliderChange(Sender: TObject);
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
  CADUseEngineStyleSheet(Host);
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

destructor TMainForm.Destroy;
begin
  Application.RemoveAsyncCalls(Self);
  FreeAndNil(FApp);
  inherited Destroy;
end;

end.
