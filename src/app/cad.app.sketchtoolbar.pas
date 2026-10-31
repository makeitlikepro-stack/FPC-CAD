unit CAD.App.SketchToolbar;
{$mode objfpc}{$H+}

{ ROLE:      the Sketch page of the ribbon (SolidWorks CommandManager),
             designed in FPC Visual IDE (app/MainForm.fvform: SketchPage with
             its icon buttons and the ActiveToolMark bar); this class binds
             the buttons by id to the actions, enables them only while a
             sketch is open and moves the mark under the active tool.
  CALLED BY: CAD.App.Controller (create, show / hide, refresh, shortcuts).
  CALLS:     CAD.App.SketchMode (tools, undo / redo, view), the panel
             (RunCommand: relation / dimension buttons).
  THREADS:   UI thread.
  SPEED:     binding once; Refresh only moves the mark. }

interface

uses
  Classes, SysUtils,
  OpenGL.ECS.Widgets,
  CAD.Sketch.Editor, CAD.Sketch.Commands, CAD.Sketch.TrimExtend,
  CAD.App.SketchMode, CAD.App.SketchPanel,
  CAD.App.DesignLookup;

type
  TCADToolbarAction = (ctaFinish, ctaSelect, ctaLine, ctaRect, ctaCircle, ctaArc, ctaArc3,
    ctaPoint, ctaDimension, ctaDistX, ctaDistY, ctaUndo, ctaRedo, ctaNormalView, ctaCancel,
    ctaTrim, ctaExtend);

  TCADSketchToolbar = class
  private
    FMode: TCADSketchMode;
    FPanel: TCADSketchPanel;
    FMark: TUIPanel;
    FButtons: array[TCADToolbarAction] of TUIButton;
    FRelations: array of TUIButton;
    FOnFinish: TNotifyEvent;
    procedure ActionClick(Sender: TObject);
    procedure RelationClick(Sender: TObject);
  public
    constructor Create(ALookup: TCADWidgetLookup; AMode: TCADSketchMode;
      APanel: TCADSketchPanel);
    { Buttons enabled and the mark shown only while a sketch is open. }
    procedure UpdateVisible;
    { Active tool mark. }
    procedure Refresh;
    { The same as the button (keyboard shortcuts use it). }
    procedure Run(AAction: TCADToolbarAction);
    property OnFinish: TNotifyEvent read FOnFinish write FOnFinish;
  end;

implementation

const
  RelationBase = 100;                { tag offset of relation buttons }

  { widget ids in app/MainForm.fvform }
  ActionId: array[TCADToolbarAction] of string = ('FinishButton', 'SelectButton',
    'LineButton', 'RectButton', 'CircleButton', 'ArcButton', 'Arc3Button', 'PointButton',
    'DimensionButton', 'DistXButton', 'DistYButton', 'UndoButton', 'RedoButton',
    'NormalViewButton', 'CancelButton', 'TrimButton', 'ExtendButton');
  RelationId: array[TCADSketchCommand] of string = ('HorizontalButton', 'VerticalButton',
    'CoincidentButton', 'ParallelButton', 'PerpendicularButton', 'EqualButton',
    'TangentButton', 'ConcentricButton', 'MidpointButton', 'OnObjectButton',
    'SymmetricButton', 'FixButton', '', '', '');   { dimensions are actions }

constructor TCADSketchToolbar.Create(ALookup: TCADWidgetLookup; AMode: TCADSketchMode;
  APanel: TCADSketchPanel);
var
  A: TCADToolbarAction;
  C: TCADSketchCommand;
  B: TUIButton;
begin
  inherited Create;
  FMode := AMode;
  FPanel := APanel;
  FMark := TUIPanel(CADDesignWidget(ALookup, 'ActiveToolMark', TUIPanel));
  FMark.InputTransparent := True;
  for A := Low(TCADToolbarAction) to High(TCADToolbarAction) do
  begin
    FButtons[A] := TUIButton(CADDesignWidget(ALookup, ActionId[A], TUIButton));
    FButtons[A].Tag := Ord(A);
    FButtons[A].OnClick := @ActionClick;
  end;
  for C := Low(TCADSketchCommand) to High(TCADSketchCommand) do
    if RelationId[C] <> '' then
    begin
      B := TUIButton(CADDesignWidget(ALookup, RelationId[C], TUIButton));
      B.Tag := RelationBase + Ord(C);
      B.OnClick := @RelationClick;
      SetLength(FRelations, Length(FRelations) + 1);
      FRelations[High(FRelations)] := B;
    end;
  UpdateVisible;
end;

procedure TCADSketchToolbar.UpdateVisible;
var
  A: TCADToolbarAction;
  I: Integer;
begin
  for A := Low(TCADToolbarAction) to High(TCADToolbarAction) do
    FButtons[A].Enabled := FMode.Active;
  for I := 0 to High(FRelations) do
    FRelations[I].Enabled := FMode.Active;
  FMark.Visible := FMode.Active;
  if FMode.Active then
    Refresh;
end;

procedure TCADSketchToolbar.Refresh;
var
  A: TCADToolbarAction;
  B: TUIButton;
begin
  if not FMode.Active or (FMode.Editor = nil) then
    Exit;
  if FMode.LineEditActive then
  begin
    if FMode.LineEditMode = lemTrim then A := ctaTrim else A := ctaExtend;
  end
  else
  case FMode.Editor.Tool of
    sktSelect: if FMode.SmartDimension then A := ctaDimension else A := ctaSelect;
    sktLine: A := ctaLine;
    sktRectangle: A := ctaRect;
    sktCircle: A := ctaCircle;
    sktArc: A := ctaArc;
    sktArc3: A := ctaArc3;
  else
    A := ctaPoint;
  end;
  { the mark keeps its designed size; it sits on the bottom edge of the tool }
  B := FButtons[A];
  FMark.Left := B.Left + (B.Width - FMark.Width) / 2;
  FMark.Top := B.Top + B.Height - FMark.Height - 1;
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
    ctaDimension:
      { a selection that fits: dimension it now; else the Smart Dimension tool }
      if (Length(FMode.Editor.Selection.Points) + Length(FMode.Editor.Selection.Entities) > 0) and
         not FMode.SmartDimension then
      begin
        { Same in-place value editor as picking a dimension in the view. }
        if Assigned(FMode.OnSmartDimension) then
          FMode.OnSmartDimension(Self)
        else
          FPanel.RunCommand(sccDimension);
      end
      else
        FMode.SetSmartDimension(True);
    ctaDistX: FPanel.RunCommand(sccDistX);
    ctaDistY: FPanel.RunCommand(sccDistY);
    ctaUndo: FMode.Undo;
    ctaRedo: FMode.Redo;
    ctaNormalView: FMode.NormalView;
    ctaCancel: FMode.Cancel;
    ctaTrim: FMode.SetLineEdit(lemTrim);
    ctaExtend: FMode.SetLineEdit(lemExtend);
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
