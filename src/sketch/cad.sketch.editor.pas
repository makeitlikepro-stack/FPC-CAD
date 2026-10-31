unit CAD.Sketch.Editor;
{$mode objfpc}{$H+}

{ ROLE:      drawing tools of the sketch editor, without any GUI: the app
             passes cursor positions in sketch coordinates (mm) and clicks;
             the editor snaps, adds geometry with automatic constraints,
             solves, and offers preview shapes and a prompt for the screen.
  CALLED BY: the app sketch mode (CAD.App.SketchMode), tests/sketch.
  CALLS:     CAD.Sketch.Model, CAD.Sketch.Solver.
  THREADS:   UI thread.
  SPEED:     snapping scans points and lines once per move (sketches have
             hundreds of points); a solve runs only after a commit.

  Tools: Point, Line (chain: each click starts the next line at the last
  end; clicking the first point closes the chain), Rectangle (2 corners),
  Circle (centre, radius point), Arc (centre, start, end; counter-clockwise),
  Arc3 (start, end, then a point the arc passes through: it sets the radius
  and the side).
  Snaps, in priority order: existing point, line midpoint, sketch origin; a
  line end close to the start's X or Y snaps horizontal / vertical.
  Automatic constraints: a snapped point is reused (shared), the origin is a
  fixed point at (0, 0), midpoint snap adds Midpoint, horizontal / vertical
  snap adds Horizontal / Vertical, a circle radius on a point adds
  PointOnCircle, rectangles get H, V, H, V. }

interface

uses
  SysUtils, Math, CAD.Sketch.Model, CAD.Sketch.Solver, CAD.Sketch.Commands;

type
  TCADSketchTool = (sktSelect, sktPoint, sktLine, sktRectangle, sktCircle, sktArc, sktArc3);

  TCADSnapKind = (snkNone, snkPoint, snkMidpoint, snkOrigin, snkHorizontal, snkVertical);

  TCADSnap = record
    Kind: TCADSnapKind;
    X, Y: Double;               { snapped position }
    Point: Integer;             { snkPoint: the point }
    Line: Integer;              { snkMidpoint: the line }
  end;

  TCADPreviewKind = (cpkLine, cpkCircle, cpkArc);

  TCADSketchPreview = record
    Kind: TCADPreviewKind;
    X1, Y1, X2, Y2: Double;     { line ends; arc start / end }
    CX, CY, R: Double;          { circle / arc }
  end;

  TCADSketchEditor = class
  private
    FSketch: TCADSketch;
    FTool: TCADSketchTool;
    FSnapTolerance: Double;
    FSnap: TCADSnap;
    { clicks of the shape being drawn }
    FClicks: array[0..2] of TCADSnap;
    FClickCount: Integer;
    FChainStart: Integer;       { line tool: first point of the chain, -1 = none }
    FChainLast: Integer;        { line tool: point the next line starts at }
    FPreviews: array of TCADSketchPreview;
    FPreviewCount: Integer;
    FLastSolve: TCADSketchSolveResult;
    FCursorX, FCursorY: Double;
    FDragPoint: Integer;        { -1 = no drag }
    FSelection: TCADSketchSelection;
    FHoverKind: TCADHitKind;
    FHoverIndex: Integer;
    function FindSnap(X, Y: Double; AFromPoint: Integer): TCADSnap;
    function ResolvePoint(const ASnap: TCADSnap): Integer;
    function OriginPoint: Integer;
    procedure AddPreview(AKind: TCADPreviewKind; X1, Y1, X2, Y2, CX, CY, R: Double);
    procedure BuildPreview;
    function StartPos(out X, Y: Double): Boolean;
    function CommitLine(const AEnd: TCADSnap): Boolean;
    function CommitRectangle: Boolean;
    function CommitCircle: Boolean;
    function CommitArc: Boolean;
    function CommitArc3: Boolean;
    procedure Solve;
    function GetPreview(AIndex: Integer): TCADSketchPreview;
  public
    constructor Create(ASketch: TCADSketch);
    procedure SetTool(ATool: TCADSketchTool);
    { Cursor moved (sketch mm). Updates the snap and the preview. }
    procedure Move(X, Y: Double);
    { Left click at (X, Y). True when the sketch changed. }
    function Click(X, Y: Double): Boolean;
    { Esc / right click: drop the shape being drawn, end a line chain. }
    procedure Cancel;
    function Prompt: string;
    property Sketch: TCADSketch read FSketch;
    property Tool: TCADSketchTool read FTool;
    { Snap radius in sketch mm (the app sets it from pixels and zoom). }
    property SnapTolerance: Double read FSnapTolerance write FSnapTolerance;
    property Snap: TCADSnap read FSnap;
    property PreviewCount: Integer read FPreviewCount;
    property Previews[AIndex: Integer]: TCADSketchPreview read GetPreview;
    property LastSolve: TCADSketchSolveResult read FLastSolve;
    { True while a shape has some clicks (or a line chain is open). }
    function Busy: Boolean;
    { Point dragging (any tool, when no shape is in progress): True when a
      free point is within the snap radius. DragTo moves it and solves:
      first with the point held at the cursor (the rest follows as little
      as possible); if that cannot be solved, with the point free (it stays
      as close as the constraints allow); otherwise nothing changes. }
    function BeginDrag(X, Y: Double): Boolean;
    function DragTo(X, Y: Double): Boolean;
    procedure EndDrag;
    function Dragging: Boolean;
    { Select tool: pick the point / entity under (X, Y); AAdd (Shift) toggles
      it in the selection, otherwise it replaces the selection. Empty
      space clears it. }
    procedure SelectAt(X, Y: Double; AAdd: Boolean);
    procedure ClearSelection;
    procedure SelectItem(AKind: TCADHitKind; AIndex: Integer);
    { Item under the cursor (Select tool). True when it changed. }
    function UpdateHover(X, Y: Double): Boolean;
    function IsSelected(AKind: TCADHitKind; AIndex: Integer): Boolean;
    property HoverKind: TCADHitKind read FHoverKind;
    property HoverIndex: Integer read FHoverIndex;
    { Constraint button on the selection (CAD.Sketch.Commands); clears the
      selection on success and refreshes LastSolve. }
    function Apply(ACommand: TCADSketchCommand; out AConstraint: Integer; out AError: string): Boolean;
    { Dimension value (degrees for angles); refreshes LastSolve. }
    function SetDimension(AConstraint: Integer; AValue: Double; out AError: string): Boolean;
    property Selection: TCADSketchSelection read FSelection;
    { Solve again (after a change made outside the editor) and refresh LastSolve. }
    procedure Resolve;
  end;

implementation

const
  ToolNames: array[TCADSketchTool] of string = ('Select', 'Point', 'Line', 'Rectangle',
    'Circle', 'Arc', 'Arc (3 points)');

function NoSnap(X, Y: Double): TCADSnap;
begin
  Result.Kind := snkNone;
  Result.X := X;
  Result.Y := Y;
  Result.Point := -1;
  Result.Line := -1;
end;

constructor TCADSketchEditor.Create(ASketch: TCADSketch);
begin
  inherited Create;
  FSketch := ASketch;
  FSnapTolerance := 1.0;
  FTool := sktSelect;
  FChainStart := -1;
  FChainLast := -1;
  FSnap := NoSnap(0, 0);
  FLastSolve.DOF := -1;
  FDragPoint := -1;
  FHoverKind := chkNone;
  FHoverIndex := -1;
end;

procedure TCADSketchEditor.SetTool(ATool: TCADSketchTool);
begin
  Cancel;
  if ATool <> sktSelect then
    ClearSelection;
  FHoverKind := chkNone;
  FHoverIndex := -1;
  FTool := ATool;
end;

procedure TCADSketchEditor.Resolve;
begin
  Solve;
end;

procedure TCADSketchEditor.ClearSelection;
begin
  CADSelectionClear(FSelection);
end;

function TCADSketchEditor.UpdateHover(X, Y: Double): Boolean;
var
  K: TCADHitKind;
  I: Integer;
begin
  if (FTool = sktSelect) and (FDragPoint < 0) then
    K := CADSketchHit(FSketch, X, Y, FSnapTolerance, I)
  else
  begin
    K := chkNone;
    I := -1;
  end;
  Result := (K <> FHoverKind) or (I <> FHoverIndex);
  FHoverKind := K;
  FHoverIndex := I;
end;

function TCADSketchEditor.IsSelected(AKind: TCADHitKind; AIndex: Integer): Boolean;
var
  I: Integer;
begin
  Result := False;
  if AKind = chkPoint then
  begin
    for I := 0 to High(FSelection.Points) do
      if FSelection.Points[I] = AIndex then
        Exit(True);
  end
  else if AKind = chkEntity then
    for I := 0 to High(FSelection.Entities) do
      if FSelection.Entities[I] = AIndex then
        Exit(True);
end;

procedure TCADSketchEditor.SelectItem(AKind: TCADHitKind; AIndex: Integer);
begin
  CADSelectionToggle(FSelection, AKind, AIndex);
end;

procedure TCADSketchEditor.SelectAt(X, Y: Double; AAdd: Boolean);
var
  Kind: TCADHitKind;
  Index: Integer;
begin
  Kind := CADSketchHit(FSketch, X, Y, FSnapTolerance, Index);
  if not AAdd then
    ClearSelection;
  if Kind <> chkNone then
    CADSelectionToggle(FSelection, Kind, Index);
end;

function TCADSketchEditor.Apply(ACommand: TCADSketchCommand; out AConstraint: Integer;
  out AError: string): Boolean;
begin
  Result := CADApplyCommand(FSketch, FSelection, ACommand, AConstraint, AError);
  if Result then
    ClearSelection;
  Solve;
end;

function TCADSketchEditor.SetDimension(AConstraint: Integer; AValue: Double;
  out AError: string): Boolean;
begin
  Result := CADSetDimension(FSketch, AConstraint, AValue, AError);
  Solve;
end;

procedure TCADSketchEditor.Cancel;
begin
  FClickCount := 0;
  FChainStart := -1;
  FChainLast := -1;
  FPreviewCount := 0;
end;

function TCADSketchEditor.Busy: Boolean;
begin
  Result := (FClickCount > 0) or (FChainLast >= 0);
end;

function TCADSketchEditor.GetPreview(AIndex: Integer): TCADSketchPreview;
begin
  Result := FPreviews[AIndex];
end;

function TCADSketchEditor.Prompt: string;
begin
  Result := ToolNames[FTool] + ': ';
  case FTool of
    sktSelect: Result := Result + 'pick a tool';
    sktPoint: Result := Result + 'click to place a point';
    sktLine:
      if FChainLast < 0 then
        Result := Result + 'click the start point'
      else
        Result := Result + 'click the next point (first point closes, right click ends)';
    sktRectangle:
      if FClickCount = 0 then
        Result := Result + 'click the first corner'
      else
        Result := Result + 'click the opposite corner';
    sktCircle:
      if FClickCount = 0 then
        Result := Result + 'click the centre'
      else
        Result := Result + 'click a point on the circle';
    sktArc:
      case FClickCount of
        0: Result := Result + 'click the centre';
        1: Result := Result + 'click the start point';
      else
        Result := Result + 'click the end point (counter-clockwise)';
      end;
    sktArc3:
      case FClickCount of
        0: Result := Result + 'click the start point';
        1: Result := Result + 'click the end point';
      else
        Result := Result + 'click a point on the arc (sets the radius)';
      end;
  end;
end;

{ Circle through three points. False when they are (nearly) on one line. }
function Circumcircle(X1, Y1, X2, Y2, X3, Y3: Double; out CX, CY, R: Double): Boolean;
var
  D, A, B: Double;
begin
  D := 2 * (X1 * (Y2 - Y3) + X2 * (Y3 - Y1) + X3 * (Y1 - Y2));
  Result := Abs(D) > 1e-12 * Max(1.0, Sqr(Hypot(X2 - X1, Y2 - Y1)));
  if not Result then
  begin
    CX := 0;
    CY := 0;
    R := 0;
    Exit;
  end;
  A := Sqr(X1) + Sqr(Y1);
  B := Sqr(X2) + Sqr(Y2);
  R := Sqr(X3) + Sqr(Y3);
  CX := (A * (Y2 - Y3) + B * (Y3 - Y1) + R * (Y1 - Y2)) / D;
  CY := (A * (X3 - X2) + B * (X1 - X3) + R * (X2 - X1)) / D;
  R := Hypot(X1 - CX, Y1 - CY);
end;

function CCWSweepOf(A1, A2: Double): Double;
begin
  Result := A2 - A1;
  while Result <= 0 do
    Result := Result + 2 * Pi;
  while Result > 2 * Pi do
    Result := Result - 2 * Pi;
end;

{ Arc through S (start click), E (end click) and M: True when it runs
  counter-clockwise from S to E (else from E to S). }
function ArcRunsSToE(CX, CY, SX, SY, EX, EY, MX, MY: Double): Boolean;
var
  AS_, AE, AM: Double;
begin
  AS_ := ArcTan2(SY - CY, SX - CX);
  AE := ArcTan2(EY - CY, EX - CX);
  AM := ArcTan2(MY - CY, MX - CX);
  Result := CCWSweepOf(AS_, AM) < CCWSweepOf(AS_, AE);
end;

{ ---------------------------------------------------------- snapping }

function TCADSketchEditor.FindSnap(X, Y: Double; AFromPoint: Integer): TCADSnap;
var
  I: Integer;
  Best, D, MX, MY, SX, SY: Double;
  E: TCADSketchEntity;
begin
  Result := NoSnap(X, Y);
  Best := FSnapTolerance;
  for I := 0 to FSketch.PointCount - 1 do
  begin
    D := Hypot(FSketch.PointX(I) - X, FSketch.PointY(I) - Y);
    if D <= Best then
    begin
      Best := D;
      Result.Kind := snkPoint;
      Result.Point := I;
      Result.X := FSketch.PointX(I);
      Result.Y := FSketch.PointY(I);
    end;
  end;
  if Result.Kind = snkPoint then
    Exit;
  for I := 0 to FSketch.EntityCount - 1 do
  begin
    E := FSketch.Entities[I];
    if E.Kind <> sekLine then
      Continue;
    MX := 0.5 * (FSketch.PointX(E.P1) + FSketch.PointX(E.P2));
    MY := 0.5 * (FSketch.PointY(E.P1) + FSketch.PointY(E.P2));
    D := Hypot(MX - X, MY - Y);
    if D <= Best then
    begin
      Best := D;
      Result.Kind := snkMidpoint;
      Result.Line := I;
      Result.X := MX;
      Result.Y := MY;
    end;
  end;
  if Result.Kind = snkMidpoint then
    Exit;
  if Hypot(X, Y) <= Best then
  begin
    Result.Kind := snkOrigin;
    Result.X := 0;
    Result.Y := 0;
    Exit;
  end;
  { horizontal / vertical from the start of the line being drawn }
  if AFromPoint >= 0 then
  begin
    SX := FSketch.PointX(AFromPoint);
    SY := FSketch.PointY(AFromPoint);
    if (Abs(Y - SY) <= FSnapTolerance) and (Abs(X - SX) > FSnapTolerance) then
    begin
      Result.Kind := snkHorizontal;
      Result.Y := SY;
    end
    else if (Abs(X - SX) <= FSnapTolerance) and (Abs(Y - SY) > FSnapTolerance) then
    begin
      Result.Kind := snkVertical;
      Result.X := SX;
    end;
  end;
end;

function TCADSketchEditor.OriginPoint: Integer;
begin
  Result := CADOriginPoint(FSketch);
end;

{ Point index for a snap: the snapped point, the origin, or a new point
  (with a Midpoint constraint for a midpoint snap). }
function TCADSketchEditor.ResolvePoint(const ASnap: TCADSnap): Integer;
begin
  case ASnap.Kind of
    snkPoint: Result := ASnap.Point;
    snkOrigin: Result := OriginPoint;
  else
    Result := FSketch.AddPoint(ASnap.X, ASnap.Y);
    if ASnap.Kind = snkMidpoint then
      FSketch.Midpoint(Result, ASnap.Line);
  end;
end;

{ ---------------------------------------------------------- preview }

procedure TCADSketchEditor.AddPreview(AKind: TCADPreviewKind; X1, Y1, X2, Y2, CX, CY, R: Double);
begin
  if FPreviewCount >= Length(FPreviews) then
    SetLength(FPreviews, Max(8, Length(FPreviews) * 2));
  FPreviews[FPreviewCount].Kind := AKind;
  FPreviews[FPreviewCount].X1 := X1;
  FPreviews[FPreviewCount].Y1 := Y1;
  FPreviews[FPreviewCount].X2 := X2;
  FPreviews[FPreviewCount].Y2 := Y2;
  FPreviews[FPreviewCount].CX := CX;
  FPreviews[FPreviewCount].CY := CY;
  FPreviews[FPreviewCount].R := R;
  Inc(FPreviewCount);
end;

function TCADSketchEditor.StartPos(out X, Y: Double): Boolean;
begin
  Result := True;
  if (FTool = sktLine) and (FChainLast >= 0) then
  begin
    X := FSketch.PointX(FChainLast);
    Y := FSketch.PointY(FChainLast);
  end
  else if FClickCount > 0 then
  begin
    X := FClicks[0].X;
    Y := FClicks[0].Y;
  end
  else
    Result := False;
end;

procedure TCADSketchEditor.BuildPreview;
var
  SX, SY, CX, CY, R, A: Double;
begin
  FPreviewCount := 0;
  if not StartPos(SX, SY) then
    Exit;
  case FTool of
    sktLine:
      AddPreview(cpkLine, SX, SY, FSnap.X, FSnap.Y, 0, 0, 0);
    sktRectangle:
      begin
        AddPreview(cpkLine, SX, SY, FSnap.X, SY, 0, 0, 0);
        AddPreview(cpkLine, FSnap.X, SY, FSnap.X, FSnap.Y, 0, 0, 0);
        AddPreview(cpkLine, FSnap.X, FSnap.Y, SX, FSnap.Y, 0, 0, 0);
        AddPreview(cpkLine, SX, FSnap.Y, SX, SY, 0, 0, 0);
      end;
    sktCircle:
      AddPreview(cpkCircle, 0, 0, 0, 0, SX, SY, Hypot(FSnap.X - SX, FSnap.Y - SY));
    sktArc3:
      if FClickCount = 1 then
        AddPreview(cpkLine, SX, SY, FSnap.X, FSnap.Y, 0, 0, 0)
      else if Circumcircle(FClicks[0].X, FClicks[0].Y, FClicks[1].X, FClicks[1].Y,
        FSnap.X, FSnap.Y, CX, CY, R) then
      begin
        if ArcRunsSToE(CX, CY, FClicks[0].X, FClicks[0].Y, FClicks[1].X, FClicks[1].Y, FSnap.X, FSnap.Y) then
          AddPreview(cpkArc, FClicks[0].X, FClicks[0].Y, FClicks[1].X, FClicks[1].Y, CX, CY, R)
        else
          AddPreview(cpkArc, FClicks[1].X, FClicks[1].Y, FClicks[0].X, FClicks[0].Y, CX, CY, R);
      end
      else
        AddPreview(cpkLine, FClicks[0].X, FClicks[0].Y, FClicks[1].X, FClicks[1].Y, 0, 0, 0);
    sktArc:
      begin
        CX := FClicks[0].X;
        CY := FClicks[0].Y;
        if FClickCount = 1 then
          AddPreview(cpkLine, CX, CY, FSnap.X, FSnap.Y, 0, 0, 0)
        else
        begin
          R := Hypot(FClicks[1].X - CX, FClicks[1].Y - CY);
          A := ArcTan2(FSnap.Y - CY, FSnap.X - CX);
          AddPreview(cpkArc, FClicks[1].X, FClicks[1].Y, CX + R * Cos(A), CY + R * Sin(A), CX, CY, R);
        end;
      end;
  end;
end;

procedure TCADSketchEditor.Move(X, Y: Double);
var
  From: Integer;
begin
  FCursorX := X;
  FCursorY := Y;
  From := -1;
  if FTool = sktLine then
    From := FChainLast;
  if FTool = sktSelect then
    FSnap := NoSnap(X, Y)
  else
    FSnap := FindSnap(X, Y, From);
  BuildPreview;
end;

{ ---------------------------------------------------------- commits }

procedure TCADSketchEditor.Solve;
begin
  FLastSolve := CADSolveSketch(FSketch);
end;

function TCADSketchEditor.CommitLine(const AEnd: TCADSnap): Boolean;
var
  P2, L: Integer;
begin
  Result := False;
  if (AEnd.Kind = snkPoint) and (AEnd.Point = FChainLast) then
    Exit;                                   { zero length }
  if Hypot(AEnd.X - FSketch.PointX(FChainLast), AEnd.Y - FSketch.PointY(FChainLast)) < 1e-9 then
    Exit;
  P2 := ResolvePoint(AEnd);
  L := FSketch.AddLine(FChainLast, P2);
  if AEnd.Kind = snkHorizontal then
    FSketch.Horizontal(L)
  else if AEnd.Kind = snkVertical then
    FSketch.Vertical(L);
  Result := True;
  if P2 = FChainStart then
  begin
    FChainStart := -1;                      { closed: the chain ends }
    FChainLast := -1;
  end
  else
    FChainLast := P2;
end;

function TCADSketchEditor.CommitRectangle: Boolean;
var
  P0, P1, P2, P3: Integer;
  X0, Y0, X1, Y1: Double;
begin
  X0 := FClicks[0].X;
  Y0 := FClicks[0].Y;
  X1 := FClicks[1].X;
  Y1 := FClicks[1].Y;
  Result := (Abs(X1 - X0) > 1e-9) and (Abs(Y1 - Y0) > 1e-9);
  if not Result then
    Exit;
  P0 := ResolvePoint(FClicks[0]);
  P1 := FSketch.AddPoint(X1, Y0);
  P2 := ResolvePoint(FClicks[1]);
  P3 := FSketch.AddPoint(X0, Y1);
  FSketch.Horizontal(FSketch.AddLine(P0, P1));
  FSketch.Vertical(FSketch.AddLine(P1, P2));
  FSketch.Horizontal(FSketch.AddLine(P2, P3));
  FSketch.Vertical(FSketch.AddLine(P3, P0));
end;

function TCADSketchEditor.CommitCircle: Boolean;
var
  C, Circle: Integer;
  R: Double;
begin
  R := Hypot(FClicks[1].X - FClicks[0].X, FClicks[1].Y - FClicks[0].Y);
  Result := R > 1e-9;
  if not Result then
    Exit;
  C := ResolvePoint(FClicks[0]);
  Circle := FSketch.AddCircle(C, R);
  if FClicks[1].Kind = snkPoint then
    FSketch.PointOnCircle(FClicks[1].Point, Circle);
end;

function TCADSketchEditor.CommitArc: Boolean;
var
  C, S, E: Integer;
  R, A: Double;
  EndSnap: TCADSnap;
begin
  R := Hypot(FClicks[1].X - FClicks[0].X, FClicks[1].Y - FClicks[0].Y);
  Result := R > 1e-9;
  if not Result then
    Exit;
  C := ResolvePoint(FClicks[0]);
  S := ResolvePoint(FClicks[1]);
  EndSnap := FClicks[2];
  if EndSnap.Kind = snkPoint then
    E := EndSnap.Point                       { the arc rule pulls it onto the radius }
  else
  begin
    A := ArcTan2(EndSnap.Y - FClicks[0].Y, EndSnap.X - FClicks[0].X);
    E := FSketch.AddPoint(FClicks[0].X + R * Cos(A), FClicks[0].Y + R * Sin(A));
  end;
  if (E = S) or (Hypot(FSketch.PointX(E) - FSketch.PointX(S), FSketch.PointY(E) - FSketch.PointY(S)) < 1e-9) then
    Exit(False);
  FSketch.AddArc(C, S, E);
end;

function TCADSketchEditor.CommitArc3: Boolean;
var
  CX, CY, R: Double;
  C, S, E: Integer;
begin
  Result := Circumcircle(FClicks[0].X, FClicks[0].Y, FClicks[1].X, FClicks[1].Y,
    FClicks[2].X, FClicks[2].Y, CX, CY, R) and
    (Hypot(FClicks[1].X - FClicks[0].X, FClicks[1].Y - FClicks[0].Y) > 1e-9);
  if not Result then
    Exit;
  S := ResolvePoint(FClicks[0]);
  E := ResolvePoint(FClicks[1]);
  if S = E then
    Exit(False);
  C := FSketch.AddPoint(CX, CY);
  if ArcRunsSToE(CX, CY, FClicks[0].X, FClicks[0].Y, FClicks[1].X, FClicks[1].Y,
    FClicks[2].X, FClicks[2].Y) then
    FSketch.AddArc(C, S, E)
  else
    FSketch.AddArc(C, E, S);
end;

function TCADSketchEditor.Dragging: Boolean;
begin
  Result := FDragPoint >= 0;
end;

function TCADSketchEditor.BeginDrag(X, Y: Double): Boolean;
var
  I: Integer;
  Best, D: Double;
begin
  FDragPoint := -1;
  if Busy then
    Exit(False);
  Best := FSnapTolerance;
  for I := 0 to FSketch.PointCount - 1 do
  begin
    if FSketch.Fixed[FSketch.Points[I].XParam] then
      Continue;
    D := Hypot(FSketch.PointX(I) - X, FSketch.PointY(I) - Y);
    if D <= Best then
    begin
      Best := D;
      FDragPoint := I;
    end;
  end;
  Result := FDragPoint >= 0;
end;

function TCADSketchEditor.DragTo(X, Y: Double): Boolean;
var
  Saved: array of Double;
  I: Integer;
  Opt: TCADSketchSolveOptions;
  R: TCADSketchSolveResult;
begin
  Result := False;
  if FDragPoint < 0 then
    Exit;
  SetLength(Saved, FSketch.ParamCount);
  for I := 0 to High(Saved) do
    Saved[I] := FSketch.Params[I];
  Opt := CADDefaultSolveOptions;
  Opt.Diagnose := False;                     { fast while moving; EndDrag reports }
  Opt.MaxIterations := 30;
  FSketch.MovePoint(FDragPoint, X, Y);
  FSketch.FixPoint(FDragPoint);
  R := CADSolveSketch(FSketch, Opt);
  FSketch.FixPoint(FDragPoint, False);
  if R.Status <> cssSolved then
  begin
    FSketch.SetParams(Saved);
    FSketch.MovePoint(FDragPoint, X, Y);
    R := CADSolveSketch(FSketch, Opt);
  end;
  if R.Status <> cssSolved then
    FSketch.SetParams(Saved)
  else
    Result := True;
  FCursorX := X;
  FCursorY := Y;
end;

procedure TCADSketchEditor.EndDrag;
begin
  if FDragPoint < 0 then
    Exit;
  FDragPoint := -1;
  Solve;                                     { full report: DOF, redundant }
  Move(FCursorX, FCursorY);
end;

function TCADSketchEditor.Click(X, Y: Double): Boolean;
var
  P: Integer;
  Rev0: Cardinal;
  Committed: Boolean;
begin
  Rev0 := FSketch.Revision;
  Committed := False;
  Move(X, Y);
  case FTool of
    sktPoint:
      if FSnap.Kind <> snkPoint then             { no second point on a point }
      begin
        ResolvePoint(FSnap);
        Committed := True;
      end;
    sktLine:
      if FChainLast < 0 then
      begin
        P := ResolvePoint(FSnap);
        FChainStart := P;
        FChainLast := P;
      end
      else
        Committed := CommitLine(FSnap);
    sktRectangle, sktCircle, sktArc, sktArc3:
      begin
        FClicks[FClickCount] := FSnap;
        Inc(FClickCount);
        if (FTool in [sktArc, sktArc3]) and (FClickCount = 3) then
        begin
          if FTool = sktArc then
            Committed := CommitArc
          else
            Committed := CommitArc3;
          FClickCount := 0;
        end
        else if (FTool in [sktRectangle, sktCircle]) and (FClickCount = 2) then
        begin
          if FTool = sktRectangle then
            Committed := CommitRectangle
          else
            Committed := CommitCircle;
          FClickCount := 0;
        end;
      end;
  end;
  if Committed then
    Solve;
  Move(FCursorX, FCursorY);                  { new points are snap targets now }
  Result := FSketch.Revision <> Rev0;
end;

end.
