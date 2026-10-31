unit CAD.App.SketchPanel;
{$mode objfpc}{$H+}
{$codepage utf8}

{ ROLE:      the sketch part of the side panel: tool buttons, constraint
             buttons (on the selection), the constraint list, the dimension
             edit (Set) and Delete, and the DOF line.
  CALLED BY: CAD.App.MainForm (create, layout, new sketch / finish events).
  CALLS:     CAD.App.SketchMode (tools, commands, dimensions), engine widgets.
  THREADS:   UI thread.
  SPEED:     the list is rebuilt only when the sketch revision changed. }

interface

uses
  Classes, SysUtils, Math, LCLType,
  OpenGL.ECS.Widgets,
  CAD.Sketch.Model, CAD.Sketch.Editor, CAD.Sketch.Solver, CAD.Sketch.Commands,
  CAD.App.SketchMode;

type
  TCADStatusEvent = procedure(Sender: TObject; const AText: string) of object;

  TCADSketchPanel = class
  private
    FUI: TUIWidgetFactory;
    FMode: TCADSketchMode;
    FSelRevision: string;               { selection text last loaded into the edit }
    FToolLabel, FConsLabel, FInfo: TUILabel;
    FTools: array[0..10] of TUIButton;
    FCommands: array[TCADSketchCommand] of TUIButton;
    FList: TUIListBox;
    FValue: TUIEdit;
    FSet, FDelete: TUIButton;
    FListMap: array of Integer;         { list row -> constraint index }
    FListRevision: Cardinal;
    FOnNewSketch, FOnFinish: TNotifyEvent;
    FOnStatus: TCADStatusEvent;
    procedure ToolClick(Sender: TObject);
    procedure CommandClick(Sender: TObject);
    procedure ListChange(Sender: TObject);
    procedure SetClick(Sender: TObject);
    procedure DeleteClick(Sender: TObject);
    procedure ValueKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    { Selects list row of AConstraint, loads its value, focuses the edit. }
    procedure EditConstraint(AConstraint: Integer);
    procedure LoadDimensionOfSelection;
    procedure Status(const AText: string);
    function SelectedConstraint: Integer;
    procedure RebuildList;
  public
    constructor Create(UI: TUIWidgetFactory; AParent: TUIWidget; AMode: TCADSketchMode);
    { Places everything from (ALeft, ATop) in AWidth; returns the bottom.
      The constraint part is shown only while a sketch is open. }
    function Layout(ALeft, ATop, AWidth: Double): Double;
    { After any sketch change: list, DOF line. }
    procedure Refresh;
    property OnNewSketch: TNotifyEvent read FOnNewSketch write FOnNewSketch;
    property OnFinish: TNotifyEvent read FOnFinish write FOnFinish;
    property OnStatus: TCADStatusEvent read FOnStatus write FOnStatus;
  end;

implementation

const
  ToolText: array[0..10] of string = ('New sketch (XY)', 'Select', 'Line', 'Rect',
    'Circle', 'Arc', 'Arc 3pt', 'Point', 'Cancel', 'Normal view', 'Finish + Extrude 10');
  CommandText: array[TCADSketchCommand] of string = ('Horiz', 'Vert', 'Coinc', 'Parallel',
    'Perp', 'Equal', 'Tangent', 'Concentric', 'Midpoint', 'On obj', 'Symm', 'Fix', 'Dimension');
  RowH = 30;
  Gap = 6;
  ListRows = 5;
  ListItemH = 24;

var
  FS: TFormatSettings;

constructor TCADSketchPanel.Create(UI: TUIWidgetFactory; AParent: TUIWidget; AMode: TCADSketchMode);
var
  I: Integer;
  C: TCADSketchCommand;
begin
  inherited Create;
  FUI := UI;
  FMode := AMode;
  FToolLabel := UI.CreateLabel(AParent, 100, 24);
  FToolLabel.Text := 'Sketch';
  for I := 0 to High(FTools) do
  begin
    FTools[I] := UI.CreateButton(AParent, 70, RowH);
    FTools[I].Text := ToolText[I];
    FTools[I].Tag := I;
    FTools[I].OnClick := @ToolClick;
  end;
  FConsLabel := UI.CreateLabel(AParent, 100, 24);
  FConsLabel.Text := 'Constraints (Select tool, Shift adds)';
  for C := Low(TCADSketchCommand) to High(TCADSketchCommand) do
  begin
    FCommands[C] := UI.CreateButton(AParent, 70, RowH);
    FCommands[C].Text := CommandText[C];
    FCommands[C].Tag := Ord(C);
    FCommands[C].OnClick := @CommandClick;
  end;
  FList := UI.CreateListBox(AParent, 100, ListRows * ListItemH);
  FList.ItemHeight := ListItemH;
  FList.MaxVisibleItems := ListRows;        { fixed height, wheel scrolls }
  FList.OnChange := @ListChange;
  FValue := UI.CreateEdit(AParent, 100, RowH);
  FValue.Placeholder := 'value, Enter = set';
  FValue.OnKeyDown := @ValueKeyDown;
  FSet := UI.CreateButton(AParent, 60, RowH);
  FSet.Text := 'Set';
  FSet.OnClick := @SetClick;
  FDelete := UI.CreateButton(AParent, 60, RowH);
  FDelete.Text := 'Delete';
  FDelete.OnClick := @DeleteClick;
  FInfo := UI.CreateLabel(AParent, 100, 24);
  FListRevision := High(Cardinal);
end;

procedure Place(W: TUIWidget; L, T, AW, AH: Double);
begin
  W.Width := AW;
  W.Height := AH;
  W.Left := L;
  W.Top := T;
end;

function TCADSketchPanel.Layout(ALeft, ATop, AWidth: Double): Double;
var
  Y, CW: Double;
  I, K: Integer;
  C: TCADSketchCommand;
  Show: Boolean;
begin
  CW := (AWidth - 2 * Gap) / 3;
  Y := ATop;
  Place(FToolLabel, ALeft, Y, AWidth, 24);
  Y := Y + 26;
  Place(FTools[0], ALeft, Y, AWidth, RowH);
  Y := Y + RowH + Gap;
  for I := 1 to 9 do
    Place(FTools[I], ALeft + ((I - 1) mod 3) * (CW + Gap), Y + ((I - 1) div 3) * (RowH + Gap), CW, RowH);
  Y := Y + 3 * (RowH + Gap);
  Place(FTools[10], ALeft, Y, AWidth, RowH);
  Y := Y + RowH + Gap;

  Show := FMode.Active;
  FConsLabel.Visible := Show;
  FList.Visible := Show;
  FValue.Visible := Show;
  FSet.Visible := Show;
  FDelete.Visible := Show;
  FInfo.Visible := Show;
  for C := Low(TCADSketchCommand) to High(TCADSketchCommand) do
    FCommands[C].Visible := Show;
  if not Show then
    Exit(Y);
  Y := Y + 8;
  Place(FConsLabel, ALeft, Y, AWidth, 24);
  Y := Y + 26;
  K := 0;
  for C := Low(TCADSketchCommand) to High(TCADSketchCommand) do
  begin
    Place(FCommands[C], ALeft + (K mod 3) * (CW + Gap), Y + (K div 3) * (RowH + Gap), CW, RowH);
    Inc(K);
  end;
  Y := Y + ((K + 2) div 3) * (RowH + Gap);
  FList.Width := AWidth;                    { height: rows x item height (list) }
  FList.Left := ALeft;
  FList.Top := Y;
  Y := Y + ListRows * ListItemH + Gap;
  Place(FValue, ALeft, Y, AWidth - 2 * (60 + Gap), RowH);
  Place(FSet, ALeft + AWidth - 2 * 60 - Gap, Y, 60, RowH);
  Place(FDelete, ALeft + AWidth - 60, Y, 60, RowH);
  Y := Y + RowH + Gap;
  Place(FInfo, ALeft, Y, AWidth, 24);
  Result := Y + 26;
end;

procedure TCADSketchPanel.Status(const AText: string);
begin
  if Assigned(FOnStatus) then
    FOnStatus(Self, AText);
end;

procedure TCADSketchPanel.ToolClick(Sender: TObject);
begin
  case TUIWidget(Sender).Tag of
    0: if Assigned(FOnNewSketch) then FOnNewSketch(Self);
    1: FMode.SetTool(sktSelect);
    2: FMode.SetTool(sktLine);
    3: FMode.SetTool(sktRectangle);
    4: FMode.SetTool(sktCircle);
    5: FMode.SetTool(sktArc);
    6: FMode.SetTool(sktArc3);
    7: FMode.SetTool(sktPoint);
    8: FMode.Cancel;
    9: FMode.NormalView;
    10: if FMode.Active and Assigned(FOnFinish) then FOnFinish(Self);
  end;
end;

procedure TCADSketchPanel.CommandClick(Sender: TObject);
var
  Err: string;
  C: Integer;
begin
  Err := FMode.ApplyCommand(TCADSketchCommand(TUIWidget(Sender).Tag), C);
  if Err <> '' then
    Status(Err)
  else if (C >= 0) and CADIsDimension(FMode.Sketch.Constraints[C].Kind) then
  begin
    EditConstraint(C);
    Status('Dimension added: type the new value and press Enter');
  end;
end;

procedure TCADSketchPanel.EditConstraint(AConstraint: Integer);
var
  I: Integer;
begin
  if FMode.Sketch.Revision <> FListRevision then
    RebuildList;
  for I := 0 to High(FListMap) do
    if FListMap[I] = AConstraint then
    begin
      FList.SelectedIndex := I;
      FList.EnsureItemVisible(I);
      Break;
    end;
  ListChange(nil);
  FUI.FocusWidget(FValue);
end;

{ One entity (or two points) selected that carries a dimension: load it. }
procedure TCADSketchPanel.LoadDimensionOfSelection;
var
  S: TCADSketch;
  Sel: TCADSketchSelection;
  I: Integer;
  C: TCADSketchConstraint;
  Key: string;
begin
  S := FMode.Sketch;
  Sel := FMode.Editor.Selection;
  Key := CADSelectionText(S, Sel);
  if Key = FSelRevision then
    Exit;
  FSelRevision := Key;
  for I := 0 to S.ConstraintCount - 1 do
  begin
    C := S.Constraints[I];
    if not (C.Active and CADIsDimension(C.Kind)) then
      Continue;
    if (Length(Sel.Entities) = 1) and (Length(Sel.Points) = 0) and
       (C.Kind in [sckLength, sckRadius, sckDiameter]) and (C.A = Sel.Entities[0]) then
    begin
      EditConstraint(I);
      Exit;
    end;
    if (Length(Sel.Points) = 2) and (Length(Sel.Entities) = 0) and (C.Kind = sckDistance) and
       (((C.A = Sel.Points[0]) and (C.B = Sel.Points[1])) or
        ((C.A = Sel.Points[1]) and (C.B = Sel.Points[0]))) then
    begin
      EditConstraint(I);
      Exit;
    end;
  end;
end;

procedure TCADSketchPanel.ValueKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_RETURN then
  begin
    SetClick(Sender);
    Key := 0;
  end;
end;

function TCADSketchPanel.SelectedConstraint: Integer;
var
  I: Integer;
begin
  Result := -1;
  I := FList.SelectedIndex;
  if (I >= 0) and (I <= High(FListMap)) then
    Result := FListMap[I];
end;

procedure TCADSketchPanel.ListChange(Sender: TObject);
var
  C: Integer;
  K: TCADSketchConstraint;
begin
  C := SelectedConstraint;
  if (C < 0) or (FMode.Sketch = nil) then
    Exit;
  K := FMode.Sketch.Constraints[C];
  if CADIsDimension(K.Kind) then
    FValue.Text := FormatFloat('0.######', CADDimensionShown(K), FS)
  else
    FValue.Text := '';
end;

procedure TCADSketchPanel.SetClick(Sender: TObject);
var
  C: Integer;
  V: Double;
  Err: string;
begin
  C := SelectedConstraint;
  if C < 0 then
  begin
    Status('pick a dimension in the list first');
    Exit;
  end;
  if not TryStrToFloat(Trim(string(FValue.Text)), V, FS) then
  begin
    Status('not a number: ' + string(FValue.Text));
    Exit;
  end;
  Err := FMode.SetDimension(C, V);
  if Err <> '' then
    Status(Err);
end;

procedure TCADSketchPanel.DeleteClick(Sender: TObject);
var
  C: Integer;
  Err: string;
begin
  C := SelectedConstraint;
  if C < 0 then
  begin
    Status('pick a constraint in the list first');
    Exit;
  end;
  Err := FMode.RemoveConstraint(C);
  if Err <> '' then
    Status(Err);
end;

procedure TCADSketchPanel.RebuildList;
var
  S: TCADSketch;
  I, N, Keep: Integer;
begin
  S := FMode.Sketch;
  Keep := SelectedConstraint;
  FList.ClearItems;
  SetLength(FListMap, S.ConstraintCount);
  N := 0;
  for I := 0 to S.ConstraintCount - 1 do
    if S.Constraints[I].Active and (S.Constraints[I].Kind <> sckArcRule) then
    begin
      FList.AddItem(UTF8String(CADConstraintLabel(S, I)));
      FListMap[N] := I;
      if I = Keep then
        FList.SelectedIndex := N;
      Inc(N);
    end;
  SetLength(FListMap, N);
  FListRevision := S.Revision;
end;

procedure TCADSketchPanel.Refresh;
var
  R: TCADSketchSolveResult;
begin
  if not FMode.Active or (FMode.Sketch = nil) then
    Exit;
  if FMode.Sketch.Revision <> FListRevision then
    RebuildList;
  LoadDimensionOfSelection;
  R := FMode.Editor.LastSolve;
  if R.DOF < 0 then
    FInfo.Text := 'Selected: ' + CADSelectionText(FMode.Sketch, FMode.Editor.Selection)
  else if R.DOF = 0 then
    FInfo.Text := 'Fully constrained (DOF 0)'
  else
    FInfo.Text := Format('DOF %d | %s', [R.DOF, CADSelectionText(FMode.Sketch, FMode.Editor.Selection)]);
end;

initialization
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
end.
