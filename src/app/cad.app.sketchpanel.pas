unit CAD.App.SketchPanel;
{$mode objfpc}{$H+}
{$codepage utf8}

{ ROLE:      the Sketch group of the side panel, designed in FPC Visual IDE
             (app/MainForm.fvform: SketchGroup): New / Edit sketch, the
             relation list, the dimension edit (Set), Delete and the DOF
             line. Binds the designed widgets by id; enables the sketch part
             only while a sketch is open. Relation and dimension commands
             come from the toolbar and the keys (RunCommand).
  CALLED BY: CAD.App.Controller (create, enable, new sketch / finish events).
  CALLS:     CAD.App.SketchMode (commands, dimensions), CAD.App.DesignLookup.
  THREADS:   UI thread.
  SPEED:     the list is rebuilt only when the sketch revision changed. }

interface

uses
  Classes, SysUtils, Math, LCLType,
  OpenGL.ECS.Widgets,
  CAD.Sketch.Model, CAD.Sketch.Editor, CAD.Sketch.Solver, CAD.Sketch.Commands,
  CAD.App.SketchMode, CAD.App.DesignLookup;

type
  TCADStatusEvent = procedure(Sender: TObject; const AText: string) of object;

  TCADSketchPanel = class
  private
    FUI: TUIWidgetFactory;
    FMode: TCADSketchMode;
    FSelRevision: string;               { selection text last loaded into the edit }
    FInfo: TUILabel;
    FNewSketch, FEditSketch: TUIButton;
    FList: TUIListBox;
    FValue: TUIEdit;
    FSet, FDelete: TUIButton;
    FListMap: array of Integer;         { list row -> constraint index }
    FListRevision: Cardinal;
    FListSketch: TObject;               { the list belongs to this sketch object }
    FOnNewSketch, FOnFinish, FOnEditSketch: TNotifyEvent;
    FOnStatus: TCADStatusEvent;
    procedure NewSketchClick(Sender: TObject);
    procedure EditSketchClick(Sender: TObject);
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
    constructor Create(UI: TUIWidgetFactory; ALookup: TCADWidgetLookup;
      AMode: TCADSketchMode);
    { New / Edit sketch outside a sketch, the relation part inside one. }
    procedure UpdateEnabled;
    { After any sketch change: list, DOF line. }
    procedure Refresh;
    { Relation / dimension on the selection (toolbar, keys); a new dimension
      opens its value for editing. }
    procedure RunCommand(ACommand: TCADSketchCommand);
    { Removes the constraint selected in the list (Delete key). }
    procedure DeleteSelected;
    { Selects a constraint in the list (a relation glyph was clicked). }
    procedure SelectConstraint(AConstraint: Integer);
    property OnNewSketch: TNotifyEvent read FOnNewSketch write FOnNewSketch;
    property OnFinish: TNotifyEvent read FOnFinish write FOnFinish;
    { Edit the sketch of the selected body (or the last one). }
    property OnEditSketch: TNotifyEvent read FOnEditSketch write FOnEditSketch;
    property OnStatus: TCADStatusEvent read FOnStatus write FOnStatus;
  end;

implementation

const
  ListItemH = 24;

var
  FS: TFormatSettings;

constructor TCADSketchPanel.Create(UI: TUIWidgetFactory; ALookup: TCADWidgetLookup;
  AMode: TCADSketchMode);
begin
  inherited Create;
  FUI := UI;
  FMode := AMode;
  FNewSketch := TUIButton(CADDesignWidget(ALookup, 'NewSketchButton', TUIButton));
  FEditSketch := TUIButton(CADDesignWidget(ALookup, 'EditSketchButton', TUIButton));
  FList := TUIListBox(CADDesignWidget(ALookup, 'ConstraintList', TUIListBox));
  FValue := TUIEdit(CADDesignWidget(ALookup, 'ValueEdit', TUIEdit));
  FSet := TUIButton(CADDesignWidget(ALookup, 'SetButton', TUIButton));
  FDelete := TUIButton(CADDesignWidget(ALookup, 'DeleteButton', TUIButton));
  FInfo := TUILabel(CADDesignWidget(ALookup, 'DofLabel', TUILabel));
  FNewSketch.OnClick := @NewSketchClick;
  FEditSketch.OnClick := @EditSketchClick;
  { the designed height decides the rows; the wheel scrolls the rest }
  FList.ItemHeight := ListItemH;
  FList.MaxVisibleItems := Max(1, Trunc(FList.Height / ListItemH));
  FList.OnChange := @ListChange;
  FValue.OnKeyDown := @ValueKeyDown;
  FSet.OnClick := @SetClick;
  FDelete.OnClick := @DeleteClick;
  FListRevision := High(Cardinal);
  UpdateEnabled;
end;

procedure TCADSketchPanel.UpdateEnabled;
var
  Sketching: Boolean;
begin
  Sketching := FMode.Active;
  FNewSketch.Enabled := not Sketching;
  FEditSketch.Enabled := not Sketching;
  FList.Enabled := Sketching;
  FValue.Enabled := Sketching;
  FSet.Enabled := Sketching;
  FDelete.Enabled := Sketching;
  if not Sketching then
  begin
    FList.ClearItems;
    SetLength(FListMap, 0);
    FListRevision := High(Cardinal);
    FListSketch := nil;
    FValue.Text := '';
    FInfo.Text := 'No sketch open';
  end;
end;

procedure TCADSketchPanel.Status(const AText: string);
begin
  if Assigned(FOnStatus) then
    FOnStatus(Self, AText);
end;

procedure TCADSketchPanel.NewSketchClick(Sender: TObject);
begin
  if Assigned(FOnNewSketch) then
    FOnNewSketch(Self);
end;

procedure TCADSketchPanel.EditSketchClick(Sender: TObject);
begin
  if Assigned(FOnEditSketch) then
    FOnEditSketch(Self);
end;

procedure TCADSketchPanel.RunCommand(ACommand: TCADSketchCommand);
var
  Err: string;
  C: Integer;
begin
  Err := FMode.ApplyCommand(ACommand, C);
  if Err <> '' then
    Status(Err)
  else if (C >= 0) and CADIsDimension(FMode.Sketch.Constraints[C].Kind) then
  begin
    EditConstraint(C);
    Status('Dimension added: type the new value and press Enter');
  end;
end;

procedure TCADSketchPanel.SelectConstraint(AConstraint: Integer);
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
  Status(CADConstraintLabel(FMode.Sketch, AConstraint) + ' selected: Delete removes it');
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
  FValue.SelectAll;
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

procedure TCADSketchPanel.DeleteSelected;
begin
  DeleteClick(nil);
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
  FListSketch := S;
end;

procedure TCADSketchPanel.Refresh;
var
  R: TCADSketchSolveResult;
begin
  if not FMode.Active or (FMode.Sketch = nil) then
    Exit;
  if (FMode.Sketch.Revision <> FListRevision) or (FMode.Sketch <> FListSketch) then
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
