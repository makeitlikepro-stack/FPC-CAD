unit CAD.App.TypedValue;
{$mode objfpc}{$H+}
{$codepage utf8}

{ ROLE:      the typed-value box while drawing: a digit, '-' or '.' typed in
             the view opens the designed edit DrawValueEdit next to the
             cursor (its placeholder says what the numbers mean: 'length,
             angle'); Enter applies them (CAD.App.SketchMode.TypeValues),
             Esc closes. The box is designed in FPC Visual IDE
             (app/MainForm.fvform); this class only shows, moves and reads it.
  CALLED BY: CAD.App.Controller (key down, sketch changes).
  CALLS:     CAD.App.SketchMode, CAD.App.DesignLookup.
  THREADS:   UI thread.
  SPEED:     nothing per frame. }

interface

uses
  Classes, SysUtils, LCLType,
  OpenGL.ECS.Widgets,
  CAD.App.SketchMode, CAD.App.DesignLookup;

type
  TCADTypedStatusEvent = procedure(Sender: TObject; const AText: string) of object;

  TCADTypedValueBox = class
  private
    FUI: TUIWidgetFactory;
    FMode: TCADSketchMode;
    FEdit: TUIEdit;
    FView: TUIWidget;
    FOnStatus: TCADTypedStatusEvent;
    procedure EditKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure Status(const AText: string);
  public
    constructor Create(UI: TUIWidgetFactory; ALookup: TCADWidgetLookup;
      AMode: TCADSketchMode; AView: TUIWidget);
    { A key in the view: opens the box when it starts a number and the tool
      takes one. The key is left alone, so its character reaches the box. }
    function KeyStarts(Key: Word; Shift: TShiftState): Boolean;
    procedure Hide;
    { After a click in the view: the box closes when it lost the focus. }
    procedure HideIfUnfocused;
    function Visible: Boolean;
    property OnStatus: TCADTypedStatusEvent read FOnStatus write FOnStatus;
  end;

implementation

const
  CursorGap = 18;                      { box below right of the cursor (px) }

constructor TCADTypedValueBox.Create(UI: TUIWidgetFactory; ALookup: TCADWidgetLookup;
  AMode: TCADSketchMode; AView: TUIWidget);
begin
  inherited Create;
  FUI := UI;
  FMode := AMode;
  FView := AView;
  FEdit := TUIEdit(CADDesignWidget(ALookup, 'DrawValueEdit', TUIEdit));
  FEdit.OnKeyDown := @EditKeyDown;
  FEdit.Visible := False;
end;

function NumberKey(Key: Word): Boolean;
begin
  Result := (Key in [VK_0..VK_9, VK_NUMPAD0..VK_NUMPAD9, VK_SUBTRACT, VK_DECIMAL]) or
    (Key = VK_OEM_MINUS) or (Key = VK_OEM_PERIOD);
end;

function TCADTypedValueBox.KeyStarts(Key: Word; Shift: TShiftState): Boolean;
var
  Prompt: string;
  X, Y: Double;
begin
  Result := False;
  if (Shift * [ssCtrl, ssAlt] <> []) or not NumberKey(Key) then
    Exit;
  Prompt := FMode.TypedPrompt;
  if Prompt = '' then
    Exit;
  if not FMode.SketchToScreen(FMode.Editor.CursorX, FMode.Editor.CursorY, X, Y) then
  begin
    X := FView.Width / 2;
    Y := FView.Height / 2;
  end;
  { inside the view, next to the cursor }
  X := FView.Left + X + CursorGap;
  Y := FView.Top + Y + CursorGap;
  if X + FEdit.Width > FView.Left + FView.Width then
    X := FView.Left + FView.Width - FEdit.Width;
  if Y + FEdit.Height > FView.Top + FView.Height then
    Y := FView.Top + FView.Height - FEdit.Height;
  FEdit.Left := X;
  FEdit.Top := Y;
  FEdit.Placeholder := UTF8String(Prompt + ', Enter');
  FEdit.Text := '';
  FEdit.Visible := True;
  FUI.FocusWidget(FEdit);
  Status('type ' + Prompt + ' and press Enter (Esc closes)');
  Result := True;
end;

procedure TCADTypedValueBox.Hide;
begin
  if not FEdit.Visible then
    Exit;
  FEdit.Visible := False;
  if FUI.FocusedWidget = FEdit then
    FUI.FocusWidget(nil);
end;

procedure TCADTypedValueBox.HideIfUnfocused;
begin
  if FEdit.Visible and (FUI.FocusedWidget <> FEdit) then
    Hide;
end;

function TCADTypedValueBox.Visible: Boolean;
begin
  Result := FEdit.Visible;
end;

procedure TCADTypedValueBox.Status(const AText: string);
begin
  if Assigned(FOnStatus) then
    FOnStatus(Self, AText);
end;

procedure TCADTypedValueBox.EditKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
var
  Err: string;
begin
  case Key of
    VK_RETURN:
      begin
        Key := 0;
        Err := FMode.TypeValues(string(FEdit.Text));
        if Err <> '' then
        begin
          Status(Err);
          FEdit.SelectAll;
        end
        else
          Hide;                        { the next digit opens it for the next step }
      end;
    VK_ESCAPE:
      begin
        Key := 0;
        Hide;
      end;
  end;
end;

end.
