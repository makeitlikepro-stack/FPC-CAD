unit CAD.App.Chrome;
{$mode objfpc}{$H+}
{$codepage utf8}

{ ROLE:      the window around the view, designed in FPC Visual IDE
             (app/MainForm.fvform): ribbon tabs (Features / Sketch / View),
             left tabs (Model / Properties), the view toolbar, the sketch
             confirmation corner and the status bar fields. Switches them
             between part mode and sketch mode, runs the view buttons on the
             viewport, and passes the part / sketch buttons on as events.
  CALLED BY: CAD.App.Controller (create, SetSketchMode, SetDof, events).
  CALLS:     CAD.App.DesignLookup, engine widgets, TUIViewport3D.
  THREADS:   UI thread.
  SPEED:     nothing per frame. }

interface

uses
  Classes, SysUtils,
  OpenGL.ECS.Widgets, OpenGL.UI.Viewport3D,
  CAD.App.DesignLookup;

type
  TCADChrome = class
  private
    FView: TUIViewport3D;
    FRibbon, FLeftTabs: TUITabs;
    FCorner: TUIPanel;
    FModeLabel, FDofLabel: TUILabel;
    FOnExtrude, FOnExitSketch, FOnDiscardSketch, FOnNormalTo: TNotifyEvent;
    procedure ZoomFitClick(Sender: TObject);
    procedure NormalToClick(Sender: TObject);
    procedure EdgesClick(Sender: TObject);
    procedure ExtrudeClick(Sender: TObject);
    procedure ExitClick(Sender: TObject);
    procedure DiscardClick(Sender: TObject);
    procedure Bind(ALookup: TCADWidgetLookup; const AId: string; AHandler: TNotifyEvent);
  public
    constructor Create(ALookup: TCADWidgetLookup; AView: TUIViewport3D);
    { Ribbon tab, left tab, confirmation corner and mode text. }
    procedure SetSketchMode(ASketching: Boolean; const ADocumentText: string);
    { Status bar: 'Fully defined · DOF 0' or ''. }
    procedure SetDof(const AText: string);
    procedure ZoomFit;
    procedure ToggleEdges;
    property OnExtrude: TNotifyEvent read FOnExtrude write FOnExtrude;
    property OnExitSketch: TNotifyEvent read FOnExitSketch write FOnExitSketch;
    property OnDiscardSketch: TNotifyEvent read FOnDiscardSketch write FOnDiscardSketch;
    property OnNormalTo: TNotifyEvent read FOnNormalTo write FOnNormalTo;
  end;

implementation

const
  { tab order in the design }
  RibbonFeatures = 0;
  RibbonSketch = 1;
  LeftModel = 0;
  LeftProperties = 1;

procedure TCADChrome.Bind(ALookup: TCADWidgetLookup; const AId: string; AHandler: TNotifyEvent);
begin
  TUIButton(CADDesignWidget(ALookup, AId, TUIButton)).OnClick := AHandler;
end;

constructor TCADChrome.Create(ALookup: TCADWidgetLookup; AView: TUIViewport3D);
begin
  inherited Create;
  FView := AView;
  FRibbon := TUITabs(CADDesignWidget(ALookup, 'Ribbon', TUITabs));
  FLeftTabs := TUITabs(CADDesignWidget(ALookup, 'LeftTabs', TUITabs));
  FCorner := TUIPanel(CADDesignWidget(ALookup, 'ConfirmCorner', TUIPanel));
  FModeLabel := TUILabel(CADDesignWidget(ALookup, 'ModeLabel', TUILabel));
  FDofLabel := TUILabel(CADDesignWidget(ALookup, 'DofStatusLabel', TUILabel));
  Bind(ALookup, 'ZoomFitButton', @ZoomFitClick);
  Bind(ALookup, 'VtZoomFitButton', @ZoomFitClick);
  Bind(ALookup, 'NormalToButton', @NormalToClick);
  Bind(ALookup, 'VtNormalButton', @NormalToClick);
  Bind(ALookup, 'EdgesButton', @EdgesClick);
  Bind(ALookup, 'VtEdgesButton', @EdgesClick);
  Bind(ALookup, 'ExtrudeButton', @ExtrudeClick);
  Bind(ALookup, 'ExitSketchCornerButton', @ExitClick);
  Bind(ALookup, 'DiscardSketchButton', @DiscardClick);
  SetSketchMode(False, 'Part1');
end;

procedure TCADChrome.SetSketchMode(ASketching: Boolean; const ADocumentText: string);
begin
  FCorner.Visible := ASketching;
  if ASketching then
  begin
    FRibbon.SelectedIndex := RibbonSketch;
    FLeftTabs.SelectedIndex := LeftProperties;
  end
  else
  begin
    FRibbon.SelectedIndex := RibbonFeatures;
    FLeftTabs.SelectedIndex := LeftModel;
    FDofLabel.Text := '';
  end;
  FModeLabel.Text := UTF8String(ADocumentText);
end;

procedure TCADChrome.SetDof(const AText: string);
begin
  FDofLabel.Text := UTF8String(AText);
end;

procedure TCADChrome.ZoomFit;
begin
  FView.FitAll;
end;

procedure TCADChrome.ToggleEdges;
begin
  FView.ShowEdges := not FView.ShowEdges;
  FView.Invalidate3D;
end;

procedure TCADChrome.ZoomFitClick(Sender: TObject);
begin
  ZoomFit;
end;

procedure TCADChrome.NormalToClick(Sender: TObject);
begin
  if Assigned(FOnNormalTo) then
    FOnNormalTo(Self);
end;

procedure TCADChrome.EdgesClick(Sender: TObject);
begin
  ToggleEdges;
end;

procedure TCADChrome.ExtrudeClick(Sender: TObject);
begin
  if Assigned(FOnExtrude) then
    FOnExtrude(Self);
end;

procedure TCADChrome.ExitClick(Sender: TObject);
begin
  if Assigned(FOnExitSketch) then
    FOnExitSketch(Self);
end;

procedure TCADChrome.DiscardClick(Sender: TObject);
begin
  if Assigned(FOnDiscardSketch) then
    FOnDiscardSketch(Self);
end;

end.
