unit CAD.App.SketchDims;
{$mode objfpc}{$H+}

{ ROLE:      dimensions on the drawing, as in CAD sketchers: every dimension
             shows its value in a small chip at its place in the view; a
             click on the chip (or a double click on a line / circle / arc)
             opens an edit box there; Enter sets the value, Esc closes.
  CALLED BY: CAD.App.MainForm (create, refresh after sketch changes).
  CALLS:     CAD.App.SketchMode (projection, dimension commands),
             CAD.Sketch.Commands (chip text, anchor, find), engine widgets.
  THREADS:   UI thread (LCL timer).
  SPEED:     the chips follow pan / zoom through a 40 ms timer that only
             moves them when the camera or the viewport size changed. }

interface

uses
  Classes, SysUtils, Math, ExtCtrls, LCLType,
  OpenGL.ECS.Widgets, OpenGL.UI.Viewport3D,
  CAD.Sketch.Model, CAD.Sketch.Commands, CAD.App.SketchMode;

type
  TCADStatusText = procedure(Sender: TObject; const AText: string) of object;

  TCADSketchDims = class
  private
    FUI: TUIWidgetFactory;
    FParent: TUIWidget;
    FView: TUIViewport3D;
    FMode: TCADSketchMode;
    FChips: array of TUIButton;
    FChipConstraint: array of Integer;
    FChipCount: Integer;
    FEdit: TUIEdit;
    FEditConstraint: Integer;
    FTimer: TTimer;
    FCameraKey: string;
    FOnStatus: TCADStatusText;
    FOnEdited: TNotifyEvent;
    function CameraKey: string;
    procedure Tick(Sender: TObject);
    procedure ChipClick(Sender: TObject);
    procedure EditKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure EntityDoubleClick(Sender: TObject; AEntity: Integer);
    procedure PlaceChips;
    procedure Status(const AText: string);
  public
    constructor Create(UI: TUIWidgetFactory; AParent: TUIWidget; AView: TUIViewport3D;
      AMode: TCADSketchMode);
    destructor Destroy; override;
    { Rebuild the chips (after any sketch change; hides them outside a sketch). }
    procedure Refresh;
    { Opens the edit box on a dimension. }
    procedure EditDimension(AConstraint: Integer);
    procedure CloseEdit;
    property OnStatus: TCADStatusText read FOnStatus write FOnStatus;
    { After a value was set from the view (the panel list refreshes). }
    property OnEdited: TNotifyEvent read FOnEdited write FOnEdited;
  end;

implementation

const
  ChipH = 22;
  EditW = 90;

var
  FS: TFormatSettings;

constructor TCADSketchDims.Create(UI: TUIWidgetFactory; AParent: TUIWidget;
  AView: TUIViewport3D; AMode: TCADSketchMode);
begin
  inherited Create;
  FUI := UI;
  FParent := AParent;
  FView := AView;
  FMode := AMode;
  FMode.OnEntityDoubleClick := @EntityDoubleClick;
  FEdit := UI.CreateEdit(AParent, EditW, ChipH + 4);
  FEdit.Visible := False;
  FEdit.OnKeyDown := @EditKeyDown;
  FEditConstraint := -1;
  FTimer := TTimer.Create(nil);
  FTimer.Interval := 40;
  FTimer.OnTimer := @Tick;
  FTimer.Enabled := True;
end;

destructor TCADSketchDims.Destroy;
begin
  FTimer.Free;                  { widgets belong to the factory }
  inherited Destroy;
end;

procedure TCADSketchDims.Status(const AText: string);
begin
  if Assigned(FOnStatus) then
    FOnStatus(Self, AText);
end;

function TCADSketchDims.CameraKey: string;
var
  Rev: Int64;
begin
  Rev := -1;
  if FMode.Sketch <> nil then
    Rev := FMode.Sketch.Revision;
  { camera, view size and the sketch revision (a point drag moves anchors) }
  Result := Format('%g|%g|%g|%g|%g|%g|%g|%g|%g|%d', [FView.Camera.YawDeg, FView.Camera.PitchDeg,
    FView.Camera.Distance, FView.Camera.Target.X, FView.Camera.Target.Y, FView.Camera.Target.Z,
    FView.Camera.OrthoHeight, FView.Width, FView.Height, Rev]);
end;

procedure TCADSketchDims.Tick(Sender: TObject);
var
  K: string;
begin
  if not FMode.Active or (FChipCount = 0) then
    Exit;
  K := CameraKey;
  if K <> FCameraKey then
    PlaceChips;
end;

procedure TCADSketchDims.Refresh;
var
  S: TCADSketch;
  I, N: Integer;
begin
  N := 0;
  if FMode.Active and (FMode.Sketch <> nil) then
  begin
    S := FMode.Sketch;
    for I := 0 to S.ConstraintCount - 1 do
      if S.Constraints[I].Active and CADIsDimension(S.Constraints[I].Kind) then
      begin
        if N >= Length(FChips) then
        begin
          SetLength(FChips, N + 1);
          SetLength(FChipConstraint, N + 1);
          FChips[N] := FUI.CreateButton(FParent, 60, ChipH);
          FChips[N].OnClick := @ChipClick;
        end;
        FChips[N].Text := UTF8String(CADDimensionChipText(S, I));
        FChips[N].Tag := N;
        FChipConstraint[N] := I;
        Inc(N);
      end;
  end
  else
    CloseEdit;
  FChipCount := N;
  for I := N to High(FChips) do
    FChips[I].Visible := False;
  PlaceChips;
end;

procedure TCADSketchDims.PlaceChips;
var
  I: Integer;
  U, V, X, Y, W: Double;
begin
  FCameraKey := CameraKey;
  for I := 0 to FChipCount - 1 do
  begin
    if (FChipConstraint[I] <> FEditConstraint) and       { the edit box takes its place }
       CADDimensionAnchor(FMode.Sketch, FChipConstraint[I], U, V) and
       FMode.SketchToScreen(U, V, X, Y) and (X >= 0) and (Y >= 0) and
       (X < FView.Width) and (Y < FView.Height) then
    begin
      W := 16 + 8 * Length(string(FChips[I].Text));
      FChips[I].Width := W;
      FChips[I].Height := ChipH;
      FChips[I].Left := FView.Left + X - 0.5 * W;
      FChips[I].Top := FView.Top + Y - ChipH - 4;          { just above the anchor }
      FChips[I].Visible := True;
    end
    else
      FChips[I].Visible := False;
  end;
  if FEdit.Visible and (FEditConstraint >= 0) and CADDimensionAnchor(FMode.Sketch, FEditConstraint, U, V) and
     FMode.SketchToScreen(U, V, X, Y) then
  begin
    FEdit.Left := FView.Left + X - 0.5 * EditW;
    FEdit.Top := FView.Top + Y - ChipH - 6;
  end;
end;

procedure TCADSketchDims.EditDimension(AConstraint: Integer);
var
  C: TCADSketchConstraint;
begin
  if not FMode.Active or (AConstraint < 0) then
    Exit;
  C := FMode.Sketch.Constraints[AConstraint];
  if not (C.Active and CADIsDimension(C.Kind)) then
    Exit;
  FEditConstraint := AConstraint;
  FEdit.Text := UTF8String(FormatFloat('0.######', CADDimensionShown(C), FS));
  FEdit.Visible := True;
  PlaceChips;
  FUI.FocusWidget(FEdit);
  FEdit.SelectAll;                             { typing replaces the old value }
  Status('Type the new value: Enter sets, Esc closes');
end;

procedure TCADSketchDims.CloseEdit;
begin
  FEdit.Visible := False;
  FEditConstraint := -1;
  if FMode.Active and (FChipCount > 0) then
    PlaceChips;                                { the chip comes back }
end;

procedure TCADSketchDims.ChipClick(Sender: TObject);
var
  I: Integer;
begin
  I := TUIWidget(Sender).Tag;
  if (I >= 0) and (I < FChipCount) then
    EditDimension(FChipConstraint[I]);
end;

procedure TCADSketchDims.EditKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
var
  V: Double;
  Err: string;
begin
  if Key = VK_ESCAPE then
  begin
    CloseEdit;
    Key := 0;
    Exit;
  end;
  if Key <> VK_RETURN then
    Exit;
  Key := 0;
  if not TryStrToFloat(Trim(string(FEdit.Text)), V, FS) then
  begin
    Status('not a number: ' + string(FEdit.Text));
    Exit;
  end;
  Err := FMode.SetDimension(FEditConstraint, V);
  CloseEdit;
  if Err <> '' then
    Status(Err);
  Refresh;
  if Assigned(FOnEdited) then
    FOnEdited(Self);
end;

{ Double click on an entity: edit its dimension, or add one and edit it. }
procedure TCADSketchDims.EntityDoubleClick(Sender: TObject; AEntity: Integer);
var
  C: Integer;
  Err: string;
begin
  C := CADFindDimension(FMode.Sketch, AEntity);
  if C < 0 then
  begin
    Err := FMode.ApplyCommandOn(AEntity, sccDimension, C);
    if Err <> '' then
    begin
      Status(Err);
      Exit;
    end;
  end;
  Refresh;
  EditDimension(C);
end;

initialization
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
end.
