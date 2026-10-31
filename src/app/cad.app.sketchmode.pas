unit CAD.App.SketchMode;
{$mode objfpc}{$H+}

{ ROLE:      sketch mode of the main window: owns the sketch being edited and
             its editor, turns viewport mouse events into editor calls, and
             keeps two viewport objects (sketch strokes, preview + snap +
             origin) up to date.
  CALLED BY: CAD.App.MainForm (enter, tool buttons, finish).
  CALLS:     CAD.Sketch.Editor / Model / Text, CAD.View.SketchDraw,
             engine TUIViewport3D (objects, camera, mouse events, OnPointerDrag:
             left drags move sketch points instead of orbiting).
  THREADS:   UI thread.
  SPEED:     a mouse move rebuilds only the small preview mesh; the sketch
             mesh is rebuilt after a click that changed the sketch. }

interface

uses
  Classes, SysUtils, Math, Controls,
  OpenGL.UI.Viewport3D, OpenGL.UI.Viewport3D.Camera, OpenGL.Render.Viewport3DMeshData,
  OpenGL.Render.Viewport3DPass,
  CAD.Sketch.Model, CAD.Sketch.Editor, CAD.Sketch.Solver, CAD.Sketch.Commands,
  CAD.View.SketchDraw;

const
  CAD_SKETCH_OBJECT_ID = 900001;      { far above feature ids (slot + 1) }
  CAD_SKETCH_PREVIEW_ID = 900002;

type
  TCADEntityEvent = procedure(Sender: TObject; AEntity: Integer) of object;

  TCADSketchMode = class
  private
    FView: TUIViewport3D;
    FSketch: TCADSketch;
    FEditor: TCADSketchEditor;
    FActive: Boolean;
    FDownX, FDownY: Integer;
    FOnChanged: TNotifyEvent;
    FOnEntityDoubleClick: TCADEntityEvent;
    procedure MouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure MouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure MouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure PointerDrag(Sender: TObject; APhase: TViewport3DDragPhase; AX, AY: Integer;
      var AHandled: Boolean);
    function WorldPerPixel: Double;
    function ToSketch(X, Y: Integer; out U, V: Double): Boolean;
    function ObjectMesh(AId: Cardinal): TV3DMeshData;
    procedure RefreshSketch;
    procedure RefreshPreview;
    procedure Changed;
  public
    constructor Create(AView: TUIViewport3D);
    destructor Destroy; override;
    { Starts a new empty sketch on the plane (origin, X, normal). }
    procedure Enter(const AOrigin, AXDir, ANormal: array of Double);
    { Leaves sketch mode; the caller takes the sketch text first. }
    procedure Leave;
    procedure SetTool(ATool: TCADSketchTool);
    procedure Cancel;
    procedure NormalView;
    function StatusText: string;
    { Constraint buttons, dimension edit and delete; '' = done, else the
      message for the status line. }
    function ApplyCommand(ACommand: TCADSketchCommand; out AConstraint: Integer): string;
    function SetDimension(AConstraint: Integer; AValue: Double): string;
    { The command on one entity alone (the selection is replaced). }
    function ApplyCommandOn(AEntity: Integer; ACommand: TCADSketchCommand;
      out AConstraint: Integer): string;
    function RemoveConstraint(AConstraint: Integer): string;
    property Active: Boolean read FActive;
    property Sketch: TCADSketch read FSketch;
    property Editor: TCADSketchEditor read FEditor;
    { After every change the panel shows (prompt, DOF). }
    property OnChanged: TNotifyEvent read FOnChanged write FOnChanged;
    { Select tool: double click on a line / circle / arc (dimension it). }
    property OnEntityDoubleClick: TCADEntityEvent read FOnEntityDoubleClick write FOnEntityDoubleClick;
    { Pixel of a sketch point in the viewport (top-left origin). }
    function SketchToScreen(U, V: Double; out AX, AY: Double): Boolean;
  end;

implementation

const
  SnapPixels = 8;
  MarkerPixels = 9;
  OriginPixels = 24;
  ClickSlopPixels = 3;

constructor TCADSketchMode.Create(AView: TUIViewport3D);
begin
  inherited Create;
  FView := AView;
end;

destructor TCADSketchMode.Destroy;
begin
  FEditor.Free;
  FSketch.Free;
  inherited Destroy;
end;

function TCADSketchMode.ObjectMesh(AId: Cardinal): TV3DMeshData;
var
  O: TViewport3DObject;
begin
  O := FView.FindObject(AId);
  if O = nil then
    O := FView.AddObject(TV3DMeshData.Create, '', AId);
  O.Visible := FActive;
  Result := O.Mesh;
end;

procedure TCADSketchMode.Enter(const AOrigin, AXDir, ANormal: array of Double);
begin
  FEditor.Free;
  FSketch.Free;
  FSketch := TCADSketch.Create;
  FSketch.SetPlane(AOrigin, AXDir, ANormal);
  FEditor := TCADSketchEditor.Create(FSketch);
  FEditor.SetTool(sktLine);
  FActive := True;
  FView.OnMouseDown := @MouseDown;
  FView.OnMouseUp := @MouseUp;
  FView.OnMouseMove := @MouseMove;
  FView.OnPointerDrag := @PointerDrag;     { left drags move points, never orbit }
  NormalView;
  RefreshSketch;
  RefreshPreview;
  Changed;
end;

procedure TCADSketchMode.Leave;
var
  O: TViewport3DObject;
begin
  FActive := False;
  FView.OnMouseDown := nil;
  FView.OnMouseUp := nil;
  FView.OnMouseMove := nil;
  FView.OnPointerDrag := nil;
  O := FView.FindObject(CAD_SKETCH_OBJECT_ID);
  if O <> nil then
    O.Visible := False;
  O := FView.FindObject(CAD_SKETCH_PREVIEW_ID);
  if O <> nil then
    O.Visible := False;
  FView.Pass.EdgeColor := Viewport3DRGBA(0.08, 0.09, 0.11, 1.0);
  FView.Invalidate3D;
  Changed;
end;

procedure TCADSketchMode.SetTool(ATool: TCADSketchTool);
begin
  if not FActive then
    Exit;
  FEditor.SetTool(ATool);
  RefreshPreview;
  Changed;
end;

procedure TCADSketchMode.Cancel;
begin
  if not FActive then
    Exit;
  FEditor.Cancel;
  RefreshPreview;
  Changed;
end;

procedure TCADSketchMode.NormalView;
begin
  if FSketch = nil then
    Exit;
  CADCameraToSketch(FView.Camera, FSketch);
  FView.Invalidate3D;
  RefreshPreview;                 { marker and cross sizes follow the zoom }
end;

function TCADSketchMode.WorldPerPixel: Double;
begin
  Result := FView.Camera.WorldPerPixel(Max(1, Round(FView.Height)));
end;

function TCADSketchMode.ToSketch(X, Y: Integer; out U, V: Double): Boolean;
begin
  Result := CADScreenToSketch(FView.Camera, FView.Width, FView.Height, X + 0.5, Y + 0.5,
    FSketch, U, V);
end;

procedure TCADSketchMode.RefreshSketch;
begin
  CADBuildSketchMesh(FSketch, ObjectMesh(CAD_SKETCH_OBJECT_ID));
  { fully constrained sketch: green strokes }
  if FActive and (FEditor.LastSolve.Status = cssSolved) and (FEditor.LastSolve.DOF = 0) then
    FView.Pass.EdgeColor := Viewport3DRGBA(0.05, 0.55, 0.2, 1.0)
  else
    FView.Pass.EdgeColor := Viewport3DRGBA(0.08, 0.09, 0.11, 1.0);
  FView.Invalidate3D;
end;

procedure TCADSketchMode.RefreshPreview;
var
  W: Double;
begin
  if FEditor = nil then
    Exit;
  W := WorldPerPixel;
  FEditor.SnapTolerance := SnapPixels * W;
  CADBuildEditorMesh(FEditor, MarkerPixels * W, OriginPixels * W,
    ObjectMesh(CAD_SKETCH_PREVIEW_ID));
  FView.Invalidate3D;
end;

procedure TCADSketchMode.Changed;
begin
  if Assigned(FOnChanged) then
    FOnChanged(Self);
end;

procedure TCADSketchMode.MouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  U, V: Double;
  Index: Integer;
begin
  FDownX := X;
  FDownY := Y;
  if FActive and (Button = mbLeft) and (ssDouble in Shift) and (FEditor.Tool = sktSelect) and
     ToSketch(X, Y, U, V) and
     (CADSketchHit(FSketch, U, V, SnapPixels * WorldPerPixel, Index) = chkEntity) and
     Assigned(FOnEntityDoubleClick) then
    FOnEntityDoubleClick(Self, Index);
end;

function TCADSketchMode.SketchToScreen(U, V: Double; out AX, AY: Double): Boolean;
begin
  Result := FActive and CADSketchToScreen(FView.Camera, FView.Width, FView.Height, FSketch, U, V, AX, AY);
end;

procedure TCADSketchMode.MouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  U, V: Double;
begin
  if not FActive or not ToSketch(X, Y, U, V) then
    Exit;
  FEditor.SnapTolerance := SnapPixels * WorldPerPixel;
  FEditor.Move(U, V);
  RefreshPreview;
end;

procedure TCADSketchMode.PointerDrag(Sender: TObject; APhase: TViewport3DDragPhase;
  AX, AY: Integer; var AHandled: Boolean);
var
  U, V: Double;
begin
  if not FActive then
    Exit;
  AHandled := True;                         { sketch mode: the view does not orbit }
  if not ToSketch(AX, AY, U, V) then
    Exit;
  FEditor.SnapTolerance := SnapPixels * WorldPerPixel;
  case APhase of
    vdpBegin:
      FEditor.BeginDrag(U, V);
    vdpMove:
      if FEditor.Dragging and FEditor.DragTo(U, V) then
      begin
        RefreshSketch;
        RefreshPreview;
      end;
    vdpEnd:
      if FEditor.Dragging then
      begin
        FEditor.EndDrag;
        RefreshSketch;
        RefreshPreview;
        Changed;
      end;
  end;
end;

procedure TCADSketchMode.MouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  U, V: Double;
begin
  if not FActive then
    Exit;
  { a drag orbits or pans the view: not a click }
  if Max(Abs(X - FDownX), Abs(Y - FDownY)) > ClickSlopPixels then
  begin
    RefreshPreview;
    Exit;
  end;
  if Button = mbRight then
  begin
    Cancel;
    Exit;
  end;
  if (Button <> mbLeft) or not ToSketch(X, Y, U, V) then
    Exit;
  FEditor.SnapTolerance := SnapPixels * WorldPerPixel;
  if FEditor.Tool = sktSelect then
    FEditor.SelectAt(U, V, ssShift in Shift)
  else if FEditor.Click(U, V) then
    RefreshSketch;
  RefreshPreview;
  Changed;
end;

function TCADSketchMode.ApplyCommand(ACommand: TCADSketchCommand; out AConstraint: Integer): string;
begin
  Result := '';
  AConstraint := -1;
  if not FActive then
    Exit('no sketch');
  if not FEditor.Apply(ACommand, AConstraint, Result) then
  begin
    if Result = '' then
      Result := 'not applied';
  end;
  RefreshSketch;
  RefreshPreview;
  Changed;
end;

function TCADSketchMode.ApplyCommandOn(AEntity: Integer; ACommand: TCADSketchCommand;
  out AConstraint: Integer): string;
begin
  AConstraint := -1;
  if not FActive then
    Exit('no sketch');
  FEditor.ClearSelection;
  FEditor.SelectItem(chkEntity, AEntity);
  Result := ApplyCommand(ACommand, AConstraint);
end;

function TCADSketchMode.SetDimension(AConstraint: Integer; AValue: Double): string;
begin
  Result := '';
  if not FActive then
    Exit('no sketch');
  FEditor.SetDimension(AConstraint, AValue, Result);
  RefreshSketch;
  RefreshPreview;
  Changed;
end;

function TCADSketchMode.RemoveConstraint(AConstraint: Integer): string;
begin
  Result := '';
  if not FActive then
    Exit('no sketch');
  try
    FSketch.RemoveConstraint(AConstraint);
  except
    on E: Exception do
      Result := E.Message;
  end;
  FEditor.ClearSelection;
  FEditor.Cancel;
  FEditor.Resolve;
  RefreshSketch;
  RefreshPreview;
  Changed;
end;

function TCADSketchMode.StatusText: string;
var
  R: TCADSketchSolveResult;
begin
  if not FActive then
    Exit('');
  R := FEditor.LastSolve;
  if R.DOF < 0 then
    Result := FEditor.Prompt
  else if R.Status <> cssSolved then
    Result := FEditor.Prompt + ' | ' + CADSolveStatusText(R.Status)
  else
    Result := Format('%s | DOF %d', [FEditor.Prompt, R.DOF]);
end;

end.
