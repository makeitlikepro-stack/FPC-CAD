unit CAD.App.SketchContext;
{$mode objfpc}{$H+}
{$codepage utf8}

{ ROLE:      the right-click menu of the sketch (SolidWorks context menu):
             the relations that fit the selection (tested on a copy of the
             sketch, so only working ones are offered), Smart Dimension,
             construction geometry on / off, Select, Exit Sketch.
  CALLED BY: CAD.App.Controller (sketch mode OnContextMenu).
  CALLS:     CAD.Sketch.Commands (CADApplyCommand on a copy), CAD.Sketch.Text
             (the copy), CAD.App.SketchMode, CAD.App.SketchPanel (RunCommand),
             engine TUIContextMenu.
  THREADS:   UI thread.
  SPEED:     one trial per relation on a copy of the sketch when the menu
             opens (small sketches: a few ms). }

interface

uses
  Classes, SysUtils,
  OpenGL.ECS.Widgets,
  CAD.Sketch.Model, CAD.Sketch.Text, CAD.Sketch.Commands, CAD.Sketch.Editor,
  CAD.App.SketchMode, CAD.App.SketchPanel;

type
  TCADMenuAction = (cmaRelation, cmaDimension, cmaConstruction, cmaSelect, cmaExit);

  TCADMenuItem = record
    Action: TCADMenuAction;
    Command: TCADSketchCommand;
  end;

  TCADSketchContextMenu = class
  private
    FUI: TUIWidgetFactory;
    FMode: TCADSketchMode;
    FPanel: TCADSketchPanel;
    FMenu: TUIContextMenu;
    FItems: array of TCADMenuItem;
    FIconFolder: string;
    FOnDimension, FOnExit: TNotifyEvent;
    procedure Add(const AText, AIcon: string; AAction: TCADMenuAction;
      ACommand: TCADSketchCommand = sccHorizontal);
    procedure ItemClick(Sender: TObject);
    function Fits(ACommand: TCADSketchCommand): Boolean;
  public
    constructor Create(UI: TUIWidgetFactory; AMode: TCADSketchMode; APanel: TCADSketchPanel;
      const AIconFolder: string);
    { Opens at a pixel of the window (AWidth x AHeight host). }
    procedure ShowAt(AX, AY, AWidth, AHeight: Integer);
    property OnDimension: TNotifyEvent read FOnDimension write FOnDimension;
    property OnExitSketch: TNotifyEvent read FOnExit write FOnExit;
  end;

implementation

const
  RelationIcon: array[TCADSketchCommand] of string = ('horizontal', 'vertical', 'coincident',
    'parallel', 'perpendicular', 'equal', 'tangent', 'concentric', 'midpoint', 'on-object',
    'symmetric', 'fix', 'smart-dim', 'dist-x', 'dist-y');
  Relations: set of TCADSketchCommand = [sccHorizontal, sccVertical, sccCoincident,
    sccParallel, sccPerpendicular, sccEqual, sccTangent, sccConcentric, sccMidpoint,
    sccOnObject, sccSymmetric, sccFix];

constructor TCADSketchContextMenu.Create(UI: TUIWidgetFactory; AMode: TCADSketchMode;
  APanel: TCADSketchPanel; const AIconFolder: string);
begin
  inherited Create;
  FUI := UI;
  FMode := AMode;
  FPanel := APanel;
  FIconFolder := AIconFolder;
  FMenu := UI.CreateContextMenu(220, 30);
end;

procedure TCADSketchContextMenu.Add(const AText, AIcon: string; AAction: TCADMenuAction;
  ACommand: TCADSketchCommand);
var
  N: Integer;
  F: string;
begin
  F := FIconFolder + AIcon + '.png';
  if (AIcon <> '') and FileExists(F) then
    FMenu.AddItemPNG(UTF8String(AText), UTF8String(F))
  else
    FMenu.AddItem(UTF8String(AText));
  N := Length(FItems);
  SetLength(FItems, N + 1);
  FItems[N].Action := AAction;
  FItems[N].Command := ACommand;
  FMenu.ItemCommand[N] := @ItemClick;
end;

{ The command applied to a copy of the sketch with the same selection. }
function TCADSketchContextMenu.Fits(ACommand: TCADSketchCommand): Boolean;
var
  Trial: TCADSketch;
  C: Integer;
  Err: string;
begin
  Result := False;
  Trial := TCADSketch.Create;
  try
    try
      CADSketchFromText(CADSketchToText(FMode.Sketch), Trial);
      Result := CADApplyCommand(Trial, FMode.Editor.Selection, ACommand, C, Err);
    except
      Result := False;
    end;
  finally
    Trial.Free;
  end;
end;

procedure TCADSketchContextMenu.ShowAt(AX, AY, AWidth, AHeight: Integer);
var
  C: TCADSketchCommand;
  Sel: TCADSketchSelection;
  Picked: Boolean;
begin
  if not FMode.Active then
    Exit;
  FMenu.ClearItems;
  FItems := nil;
  Sel := FMode.Editor.Selection;
  Picked := Length(Sel.Points) + Length(Sel.Entities) > 0;
  if Picked then
  begin
    for C := Low(TCADSketchCommand) to High(TCADSketchCommand) do
      if (C in Relations) and Fits(C) then
        Add(CADCommandName(C), RelationIcon[C], cmaRelation, C);
    if Fits(sccDimension) then
      Add('Smart Dimension', 'smart-dim', cmaDimension);
    if Length(Sel.Entities) > 0 then
      Add('Construction geometry', 'line', cmaConstruction);
  end
  else
    Add('Smart Dimension', 'smart-dim', cmaDimension);
  Add('Select', 'select', cmaSelect);
  Add('Exit Sketch', 'exit-sketch', cmaExit);
  FMenu.OpenAtScreen(AX, AY, AWidth, AHeight);
end;

procedure TCADSketchContextMenu.ItemClick(Sender: TObject);
var
  I: Integer;
begin
  { Engine closes the menu before calling ItemCommand. Close resets
    SelectedIndex to -1, but Sender is the activated row widget. }
  I := FMenu.IndexOfItemButton(Sender);
  if (I < 0) or (I > High(FItems)) then
    Exit;
  case FItems[I].Action of
    cmaRelation: FPanel.RunCommand(FItems[I].Command);
    cmaDimension:
      if Length(FMode.Editor.Selection.Points) + Length(FMode.Editor.Selection.Entities) > 0 then
      begin
        if Assigned(FOnDimension) then
          FOnDimension(Self);
      end
      else
        FMode.SetSmartDimension(True);
    cmaConstruction: FMode.ToggleConstruction;
    cmaSelect: FMode.SetTool(sktSelect);
    cmaExit: if Assigned(FOnExit) then FOnExit(Self);
  end;
end;

end.
