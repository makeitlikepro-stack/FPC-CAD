unit CAD.App.SketchToolbar;
{$mode objfpc}{$H+}

{ ROLE:      SolidWorks-style sketch toolbar over the top of the viewport
             while a sketch is open: Finish, drawing tools, dimensions,
             undo / redo, view; a second row with the relations. Icon
             buttons (Tabler, assets/icons) with a hint that names the
             shortcut; the active tool is underlined.
  CALLED BY: CAD.App.MainForm (create, layout, refresh).
  CALLS:     CAD.App.SketchMode (tools, undo / redo, view), the panel
             (RunCommand: relation / dimension buttons), engine widgets.
  THREADS:   UI thread.
  SPEED:     widgets are made once; Refresh only moves the underline. }

interface

uses
  Classes, SysUtils, Math,
  OpenGL.Types, OpenGL.ECS.Widgets, OpenGL.UI.WidgetKit,
  CAD.Sketch.Editor, CAD.Sketch.Commands, CAD.App.SketchMode, CAD.App.SketchPanel;

type
  TCADToolbarAction = (ctaFinish, ctaSelect, ctaLine, ctaRect, ctaCircle, ctaArc, ctaArc3,
    ctaPoint, ctaDimension, ctaDistX, ctaDistY, ctaUndo, ctaRedo, ctaNormalView, ctaCancel);

  TCADSketchToolbar = class
  private
    FMode: TCADSketchMode;
    FPanel: TCADSketchPanel;
    FBar: TUIPanel;
    FButtons: array[TCADToolbarAction] of TUIButton;
    FRelations: array[TCADSketchCommand] of TUIButton;
    FUnderline: TUIPanel;
    FOnFinish: TNotifyEvent;
    procedure ActionClick(Sender: TObject);
    procedure RelationClick(Sender: TObject);
    function MakeButton(UI: TUIWidgetFactory; const AIcon, AHint: string; ATag: Integer): TUIButton;
  public
    constructor Create(UI: TUIWidgetFactory; AParent: TUIWidget; AMode: TCADSketchMode;
      APanel: TCADSketchPanel);
    { Places the bar over the top of the viewport area; hidden outside a sketch. }
    procedure Layout(ALeft, ATop, AWidth: Double);
    { Active tool underline. }
    procedure Refresh;
    { The same as the button (keyboard shortcuts use it). }
    procedure Run(AAction: TCADToolbarAction);
    property OnFinish: TNotifyEvent read FOnFinish write FOnFinish;
  end;

function CADIconFile(const AKey: string; ASize: Integer = 24): string;

implementation

const
  BtnSize = 34;
  Gap = 3;
  GroupGap = 14;
  RelationBase = 100;                { tag offset of relation buttons }

  ActionIcon: array[TCADToolbarAction] of string = ('finish', 'select', 'line', 'rect',
    'circle', 'arc', 'arc3', 'point', 'dimension', 'dist-x', 'dist-y', 'undo', 'redo',
    'normal-view', 'cancel');
  ActionHint: array[TCADToolbarAction] of string = ('Finish sketch (Ctrl+Enter)',
    'Select (S)', 'Line (L)', 'Rectangle (R)', 'Circle (C)', 'Centre arc (A)',
    '3-point arc (T)', 'Point (P)', 'Dimension (D)', 'Horizontal distance (X)',
    'Vertical distance (Y)', 'Undo (Ctrl+Z)', 'Redo (Ctrl+Y)', 'Normal to sketch (N)',
    'Cancel (Esc)');
  { a gap after these actions separates the groups }
  GroupEnd: set of TCADToolbarAction = [ctaFinish, ctaPoint, ctaDistY, ctaRedo];

  RelationIcon: array[TCADSketchCommand] of string = ('horizontal', 'vertical', 'coincident',
    'parallel', 'perpendicular', 'equal', 'tangent', 'concentric', 'midpoint', 'on-object',
    'symmetric', 'fix', 'dimension', 'dist-x', 'dist-y');
  RelationHint: array[TCADSketchCommand] of string = ('Horizontal (H)', 'Vertical (V)',
    'Coincident', 'Parallel', 'Perpendicular', 'Equal', 'Tangent', 'Concentric', 'Midpoint',
    'On object', 'Symmetric', 'Fix', 'Dimension (D)', 'Horizontal distance (X)',
    'Vertical distance (Y)');
  { relations shown in the second row (the dimensions are in the first) }
  RowRelations: set of TCADSketchCommand = [sccHorizontal, sccVertical, sccCoincident,
    sccParallel, sccPerpendicular, sccEqual, sccTangent, sccConcentric, sccMidpoint,
    sccOnObject, sccSymmetric, sccFix];

function CADIconFile(const AKey: string; ASize: Integer): string;
begin
  Result := ExtractFilePath(ParamStr(0)) + 'assets' + PathDelim + 'icons' + PathDelim + 'png' +
    PathDelim + IntToStr(ASize) + PathDelim + AKey + '.png';
end;

function TCADSketchToolbar.MakeButton(UI: TUIWidgetFactory; const AIcon, AHint: string;
  ATag: Integer): TUIButton;
var
  Img: TUIImage;
begin
  Result := UI.CreateButton(FBar, BtnSize, BtnSize);
  Result.Text := '';
  Result.Tag := ATag;
  Result.Hint := UTF8String(AHint);
  Img := UI.CreateImage(Result, 24, 24);
  if FileExists(CADIconFile(AIcon)) then
    Img.LoadPNG(CADIconFile(AIcon));
  Img.InputTransparent := True;
  Img.SetBounds((BtnSize - 24) / 2, (BtnSize - 24) / 2, 24, 24);
end;

constructor TCADSketchToolbar.Create(UI: TUIWidgetFactory; AParent: TUIWidget;
  AMode: TCADSketchMode; APanel: TCADSketchPanel);
var
  A: TCADToolbarAction;
  C: TCADSketchCommand;
begin
  inherited Create;
  FMode := AMode;
  FPanel := APanel;
  FBar := UI.CreatePanel(AParent, 0, 0, 100, 2 * BtnSize + 3 * Gap, 6,
    tColor4.Create(0.93, 0.94, 0.96, 0.96));
  for A := Low(TCADToolbarAction) to High(TCADToolbarAction) do
  begin
    FButtons[A] := MakeButton(UI, ActionIcon[A], ActionHint[A], Ord(A));
    FButtons[A].OnClick := @ActionClick;
  end;
  for C := Low(TCADSketchCommand) to High(TCADSketchCommand) do
    if C in RowRelations then
    begin
      FRelations[C] := MakeButton(UI, RelationIcon[C], RelationHint[C], RelationBase + Ord(C));
      FRelations[C].OnClick := @RelationClick;
    end;
  FUnderline := UI.CreatePanel(FBar, 0, 0, BtnSize - 8, 3, 1, tColor4.Create(0.0, 0.47, 0.84, 1));
  FUnderline.InputTransparent := True;
end;

procedure TCADSketchToolbar.Layout(ALeft, ATop, AWidth: Double);
var
  A: TCADToolbarAction;
  C: TCADSketchCommand;
  X, W: Double;
begin
  FBar.Visible := FMode.Active;
  if not FMode.Active then
    Exit;
  X := Gap;
  for A := Low(TCADToolbarAction) to High(TCADToolbarAction) do
  begin
    FButtons[A].SetBounds(X, Gap, BtnSize, BtnSize);
    X := X + BtnSize + Gap;
    if A in GroupEnd then
      X := X + GroupGap;
  end;
  W := X;
  X := Gap;
  for C := Low(TCADSketchCommand) to High(TCADSketchCommand) do
    if FRelations[C] <> nil then
    begin
      FRelations[C].SetBounds(X, 2 * Gap + BtnSize, BtnSize, BtnSize);
      X := X + BtnSize + Gap;
    end;
  W := Min(Max(W, X), AWidth);
  FBar.SetBounds(ALeft + Max(0, (AWidth - W) / 2), ATop, W, 2 * BtnSize + 3 * Gap);
  Refresh;
end;

procedure TCADSketchToolbar.Refresh;
var
  A: TCADToolbarAction;
  B: TUIButton;
begin
  if not FMode.Active or (FMode.Editor = nil) then
    Exit;
  case FMode.Editor.Tool of
    sktSelect: A := ctaSelect;
    sktLine: A := ctaLine;
    sktRectangle: A := ctaRect;
    sktCircle: A := ctaCircle;
    sktArc: A := ctaArc;
    sktArc3: A := ctaArc3;
  else
    A := ctaPoint;
  end;
  B := FButtons[A];
  FUnderline.SetBounds(B.Left + 4, B.Top + BtnSize - 4, BtnSize - 8, 3);
end;

procedure TCADSketchToolbar.Run(AAction: TCADToolbarAction);
begin
  case AAction of
    ctaFinish: if Assigned(FOnFinish) then FOnFinish(Self);
    ctaSelect: FMode.SetTool(sktSelect);
    ctaLine: FMode.SetTool(sktLine);
    ctaRect: FMode.SetTool(sktRectangle);
    ctaCircle: FMode.SetTool(sktCircle);
    ctaArc: FMode.SetTool(sktArc);
    ctaArc3: FMode.SetTool(sktArc3);
    ctaPoint: FMode.SetTool(sktPoint);
    ctaDimension: FPanel.RunCommand(sccDimension);
    ctaDistX: FPanel.RunCommand(sccDistX);
    ctaDistY: FPanel.RunCommand(sccDistY);
    ctaUndo: FMode.Undo;
    ctaRedo: FMode.Redo;
    ctaNormalView: FMode.NormalView;
    ctaCancel: FMode.Cancel;
  end;
  Refresh;
end;

procedure TCADSketchToolbar.ActionClick(Sender: TObject);
begin
  Run(TCADToolbarAction(TUIWidget(Sender).Tag));
end;

procedure TCADSketchToolbar.RelationClick(Sender: TObject);
begin
  FPanel.RunCommand(TCADSketchCommand(TUIWidget(Sender).Tag - RelationBase));
end;

end.
