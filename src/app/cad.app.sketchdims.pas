unit CAD.App.SketchDims;
{$mode objfpc}{$H+}

{ ROLE:      dimensions on the drawing, as in CAD sketchers: every dimension
             shows its value in a small chip at its place in the view; a
             click on the chip (or a double click on a line / circle / arc)
             opens an edit box there; Enter sets the value, Esc closes.
  CALLED BY: CAD.App.Controller (create, refresh after sketch changes).
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
  TCADConstraintEvent = procedure(Sender: TObject; AConstraint: Integer) of object;

  TCADSketchDims = class
  private
    FUI: TUIWidgetFactory;
    FParent: TUIWidget;
    FView: TUIViewport3D;
    FMode: TCADSketchMode;
    FChips: array of TUIButton;
    FChipConstraint: array of Integer;
    FChipCount: Integer;
    { relation glyphs (H, V, //, T ...) next to the geometry }
    FGlyphs: array of TUIButton;
    FGlyphConstraint: array of Integer;
    FGlyphTangentIcon: array of Boolean;
    FTangentIconFile: string;
    FGlyphX, FGlyphY: array of Double;
    FGlyphCount: Integer;
    FOnConstraintClick: TCADConstraintEvent;
    FEdit: TUIEdit;
    FEditConstraint: Integer;
    FTimer: TTimer;
    FCameraKey: string;
    FOnStatus: TCADStatusText;
    FOnEdited: TNotifyEvent;
    function CameraKey: string;
    procedure Tick(Sender: TObject);
    procedure ChipClick(Sender: TObject);
    procedure GlyphClick(Sender: TObject);
    procedure PlaceGlyphs;
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
    { A relation glyph was clicked (select it in the list, Delete removes). }
    property OnConstraintClick: TCADConstraintEvent read FOnConstraintClick write FOnConstraintClick;
  end;

implementation

const
  ChipH = 22;
  GlyphH = 18;
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
  FTangentIconFile := ExtractFilePath(ExpandFileName(ParamStr(0))) +
    'assets' + PathDelim + 'icons' + PathDelim + 'svg' + PathDelim +
    'constraints' + PathDelim + 'tangent.svg';
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
  if not FMode.Active or FMode.ExtrudePreviewActive or
     (FChipCount + FGlyphCount = 0) then
    Exit;
  K := CameraKey;
  if K <> FCameraKey then
    PlaceChips;
end;

procedure TCADSketchDims.Refresh;
var
  S: TCADSketch;
  I, N: Integer;
  TangentIcon: Boolean;
begin
  if FMode.ExtrudePreviewActive then
  begin
    { A clean solid preview should not show sketch relation glyphs and
      dimension chips through the merged top face. }
    for I := 0 to High(FChips) do FChips[I].Visible := False;
    for I := 0 to High(FGlyphs) do FGlyphs[I].Visible := False;
    FEdit.Visible := False;
    Exit;
  end;
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
          FChips[N].StyleClass := 'cad-dim-chip';           { assets/styles: drafting text }
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
  N := 0;
  if FMode.Active and (FMode.Sketch <> nil) then
  begin
    S := FMode.Sketch;
    for I := 0 to S.ConstraintCount - 1 do
      if CADRelationGlyph(S, I) <> '' then
      begin
        if N >= Length(FGlyphs) then
        begin
          SetLength(FGlyphs, N + 1);
          SetLength(FGlyphConstraint, N + 1);
          SetLength(FGlyphTangentIcon, N + 1);
          FGlyphs[N] := FUI.CreateButton(FParent, 30, GlyphH);
          FGlyphTangentIcon[N] := False;
          FGlyphs[N].StyleClass := 'cad-relation-glyph';
          FGlyphs[N].OnClick := @GlyphClick;
        end;
        TangentIcon := S.Constraints[I].Kind in
          [sckTangentLine, sckTangentCircles];
        if TangentIcon <> FGlyphTangentIcon[N] then
        begin
          if TangentIcon then
          begin
            FGlyphs[N].IconSize := 18;
            FGlyphs[N].IconPosition := uipCenter;
            FGlyphs[N].LoadIconSVG(FTangentIconFile);
          end
          else
            FGlyphs[N].ClearIconImage;
          FGlyphTangentIcon[N] := TangentIcon;
        end;
        if TangentIcon then FGlyphs[N].Text := ''
        else FGlyphs[N].Text := UTF8String(CADRelationGlyph(S, I));
        FGlyphs[N].Tag := N;
        FGlyphConstraint[N] := I;
        Inc(N);
      end;
  end;
  FGlyphCount := N;
  SetLength(FGlyphX, N);
  SetLength(FGlyphY, N);
  for I := N to High(FGlyphs) do
    FGlyphs[I].Visible := False;
  PlaceChips;
end;

procedure TCADSketchDims.PlaceGlyphs;
var
  I, K, Stack: Integer;
  U, V, X, Y, W: Double;
  Ok: array of Boolean;
begin
  SetLength(Ok, FGlyphCount);
  for I := 0 to FGlyphCount - 1 do
  begin
    Ok[I] := CADRelationAnchor(FMode.Sketch, FGlyphConstraint[I], U, V) and
      FMode.SketchToScreen(U, V, X, Y);
    FGlyphX[I] := X;
    FGlyphY[I] := Y;
    if not Ok[I] then
    begin
      FGlyphs[I].Visible := False;
      Continue;
    end;
    { glyphs on the same spot line up to the right }
    Stack := 0;
    for K := 0 to I - 1 do
      if Ok[K] and (Abs(FGlyphX[K] - X) < 2) and (Abs(FGlyphY[K] - Y) < 2) then
        Inc(Stack);
    { Fixed icon width: UTF-8 byte length is not a glyph count. }
    W := 30;
    { The geometry anchor may be visible even when the glyph's default
      right-hand placement crosses the viewport border. Keep that glyph
      on screen; do not silently hide a valid constraint. }
    X := X + 8 + Stack * (W + 2);
    Y := Y + 6;
    if (FGlyphX[I] < 0) or (FGlyphX[I] >= FView.Width) or
       (FGlyphY[I] < 0) or (FGlyphY[I] >= FView.Height) then
    begin
      FGlyphs[I].Visible := False;
      Continue;
    end;
    X := EnsureRange(X, 0.0, Max(0.0, FView.Width - W));
    Y := EnsureRange(Y, 0.0, Max(0.0, FView.Height - GlyphH));
    FGlyphs[I].Width := W;
    FGlyphs[I].Height := GlyphH;
    FGlyphs[I].Left := FView.Left + X;
    FGlyphs[I].Top := FView.Top + Y;
    FGlyphs[I].Visible := True;
  end;
end;

procedure TCADSketchDims.GlyphClick(Sender: TObject);
var
  I: Integer;
begin
  I := TUIWidget(Sender).Tag;
  if (I >= 0) and (I < FGlyphCount) and Assigned(FOnConstraintClick) then
    FOnConstraintClick(Self, FGlyphConstraint[I]);
end;

procedure TCADSketchDims.PlaceChips;
var
  I: Integer;
  U, V, X, Y, W: Double;
begin
  if FMode.ExtrudePreviewActive then Exit;
  FCameraKey := CameraKey;
  { drafting dimension lines follow the zoom; the chips sit on their text }
  FMode.RefreshDimensions;
  PlaceGlyphs;
  for I := 0 to FChipCount - 1 do
  begin
    if (FChipConstraint[I] <> FEditConstraint) and       { the edit box takes its place }
       FMode.DimensionTextPos(FChipConstraint[I], U, V) and
       FMode.SketchToScreen(U, V, X, Y) and (X >= 0) and (Y >= 0) and
       (X < FView.Width) and (Y < FView.Height) then
    begin
      W := 16 + 8 * Length(string(FChips[I].Text));
      FChips[I].Width := W;
      FChips[I].Height := ChipH;
      FChips[I].Left := FView.Left + X - 0.5 * W;
      FChips[I].Top := FView.Top + Y - 0.5 * ChipH;        { centred on the text place }
      FChips[I].Visible := True;
    end
    else
      FChips[I].Visible := False;
  end;
  if FEdit.Visible and (FEditConstraint >= 0) and FMode.DimensionTextPos(FEditConstraint, U, V) and
     FMode.SketchToScreen(U, V, X, Y) then
  begin
    FEdit.Left := FView.Left + X - 0.5 * EditW;
    FEdit.Top := FView.Top + Y - 0.5 * ChipH - 2;
  end;
end;

procedure TCADSketchDims.EditDimension(AConstraint: Integer);
var
  C: TCADSketchConstraint;
begin
  if not FMode.Active or (FMode.Sketch = nil) or
     (AConstraint < 0) or (AConstraint >= FMode.Sketch.ConstraintCount) then
    Exit;
  C := FMode.Sketch.Constraints[AConstraint];
  if not (C.Active and CADIsDimension(C.Kind)) then
    Exit;
  FEditConstraint := AConstraint;
  FEdit.Text := UTF8String(FormatFloat('0.######', CADDimensionShownIn(FMode.Sketch, AConstraint), FS));
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
  if FMode.Active and (FChipCount + FGlyphCount > 0) then
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
  if Err <> '' then
  begin
    { Keep the input visible so the user can correct a rejected value. }
    Status(Err);
    FUI.FocusWidget(FEdit);
    FEdit.SelectAll;
    Exit;
  end;
  CloseEdit;
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
