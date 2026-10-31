unit CAD.Sketch.TypedInput;
{$mode objfpc}{$H+}

{ ROLE:      typed values while drawing (SolidWorks-like): the numbers the
             user types finish the current step of the drawing tool exactly,
             and a typed size becomes a dimension so it stays.
               no shape started   x, y            first click / point
               line (chain open)  length[, angle] next end; Length (+ H/V
                                                  for 0/90/180/270 deg)
               rectangle          width, height   opposite corner; two
                                                  Lengths
               circle             radius          Radius
               centre arc         radius, then sweep angle (deg, + = CCW)
               3-point arc        chord[, angle], then radius (the short arc
                                  on the cursor side); Radius
             Without a typed angle the direction is the cursor's.
  CALLED BY: CAD.App.SketchMode (TypeValues), tests/sketch.
  CALLS:     CAD.Sketch.Editor (ClickExact, clicks, cursor), CAD.Sketch.Model.
  THREADS:   UI thread (same as the editor).
  SPEED:     one editor click + one solve. }

interface

uses
  SysUtils, Math, CAD.Sketch.Model, CAD.Sketch.Editor;

type
  TCADTypedValues = array of Double;

{ What the numbers mean now ('length, angle'); '' when the tool takes none. }
function CADTypedPrompt(AEditor: TCADSketchEditor): string;
{ Numbers separated by ',', ';' or spaces ('.' decimal); False when empty or
  not a number. }
function CADParseTypedValues(const AText: string; out AValues: TCADTypedValues): Boolean;
{ Applies the typed numbers to the current step; False with AError when they
  do not fit. }
function CADApplyTyped(AEditor: TCADSketchEditor; const AText: string;
  out AError: string): Boolean;

implementation

var
  FS: TFormatSettings;

function CADTypedPrompt(AEditor: TCADSketchEditor): string;
begin
  Result := '';
  case AEditor.Tool of
    sktSelect: Exit;
    sktPoint: Exit('x, y');
    sktLine: if AEditor.ChainLast >= 0 then Exit('length, angle');
    sktRectangle: if AEditor.ClickCount = 1 then Exit('width, height');
    sktCircle: if AEditor.ClickCount = 1 then Exit('radius');
    sktArc:
      case AEditor.ClickCount of
        1: Exit('radius');
        2: Exit('sweep angle');
      end;
    sktArc3:
      case AEditor.ClickCount of
        1: Exit('chord, angle');
        2: Exit('radius');
      end;
  end;
  Result := 'x, y';
end;

function CADParseTypedValues(const AText: string; out AValues: TCADTypedValues): Boolean;
var
  T, Part: string;
  I, N: Integer;
  V: Double;
begin
  AValues := nil;
  T := StringReplace(Trim(AText), ';', ' ', [rfReplaceAll]);
  T := StringReplace(T, ',', ' ', [rfReplaceAll]);
  N := 0;
  I := 1;
  while I <= Length(T) do
  begin
    while (I <= Length(T)) and (T[I] = ' ') do
      Inc(I);
    Part := '';
    while (I <= Length(T)) and (T[I] <> ' ') do
    begin
      Part := Part + T[I];
      Inc(I);
    end;
    if Part = '' then
      Continue;
    if not TryStrToFloat(Part, V, FS) then
      Exit(False);
    SetLength(AValues, N + 1);
    AValues[N] := V;
    Inc(N);
  end;
  Result := N > 0;
end;

{ Unit direction from (SX, SY) to the cursor; +X when they coincide. }
procedure CursorDir(AEditor: TCADSketchEditor; SX, SY: Double; out DX, DY: Double);
var
  L: Double;
begin
  DX := AEditor.CursorX - SX;
  DY := AEditor.CursorY - SY;
  L := Hypot(DX, DY);
  if L < 1e-12 then
  begin
    DX := 1;
    DY := 0;
  end
  else
  begin
    DX := DX / L;
    DY := DY / L;
  end;
end;

function SignOr1(A: Double): Double;
begin
  if A < 0 then
    Result := -1
  else
    Result := 1;
end;

{ Point at ALength from (SX, SY): typed angle (deg) or the cursor direction. }
procedure Ahead(AEditor: TCADSketchEditor; SX, SY: Double; const V: TCADTypedValues;
  out X, Y: Double);
var
  DX, DY, A: Double;
begin
  if Length(V) >= 2 then
  begin
    A := DegToRad(V[1]);
    DX := Cos(A);
    DY := Sin(A);
  end
  else
    CursorDir(AEditor, SX, SY, DX, DY);
  X := SX + V[0] * DX;
  Y := SY + V[0] * DY;
end;

{ 0 / 180 deg -> horizontal, 90 / 270 -> vertical, else none. }
procedure AxisRelation(S: TCADSketch; ALine: Integer; AAngle: Double);
var
  A: Double;
begin
  A := AAngle - 360 * Floor(AAngle / 360);
  if (Abs(A) < 1e-9) or (Abs(A - 180) < 1e-9) or (Abs(A - 360) < 1e-9) then
    S.Horizontal(ALine)
  else if (Abs(A - 90) < 1e-9) or (Abs(A - 270) < 1e-9) then
    S.Vertical(ALine);
end;

function ApplyLine(E: TCADSketchEditor; const V: TCADTypedValues; out AError: string): Boolean;
var
  S: TCADSketch;
  X, Y: Double;
  N, L: Integer;
begin
  Result := False;
  if V[0] <= 0 then
    Exit;
  S := E.Sketch;
  Ahead(E, S.PointX(E.ChainLast), S.PointY(E.ChainLast), V, X, Y);
  N := S.EntityCount;
  if not E.ClickExact(X, Y) or (S.EntityCount = N) then
    Exit;
  L := S.EntityCount - 1;
  S.Length(L, V[0]);
  if Length(V) >= 2 then
    AxisRelation(S, L, V[1]);
  AError := '';
  Result := True;
end;

function ApplyRectangle(E: TCADSketchEditor; const V: TCADTypedValues; out AError: string): Boolean;
var
  S: TCADSketch;
  X0, Y0, W, H: Double;
  N: Integer;
begin
  Result := False;
  if Length(V) < 2 then
  begin
    AError := 'type width, height';
    Exit;
  end;
  W := Abs(V[0]);
  H := Abs(V[1]);
  if (W < 1e-9) or (H < 1e-9) then
    Exit;
  S := E.Sketch;
  E.ClickPos(0, X0, Y0);
  N := S.EntityCount;
  { the corner goes to the cursor's side }
  if not E.ClickExact(X0 + SignOr1(E.CursorX - X0) * W, Y0 + SignOr1(E.CursorY - Y0) * H) or
     (S.EntityCount < N + 4) then
    Exit;
  S.Length(N, W);                          { first side: horizontal }
  S.Length(N + 1, H);                      { second side: vertical }
  Result := True;
end;

function ApplyCircle(E: TCADSketchEditor; const V: TCADTypedValues; out AError: string): Boolean;
var
  S: TCADSketch;
  CX, CY, DX, DY: Double;
  N: Integer;
begin
  Result := False;
  if V[0] <= 0 then
    Exit;
  S := E.Sketch;
  E.ClickPos(0, CX, CY);
  CursorDir(E, CX, CY, DX, DY);
  N := S.EntityCount;
  if not E.ClickExact(CX + V[0] * DX, CY + V[0] * DY) or (S.EntityCount = N) then
    Exit;
  S.Radius(S.EntityCount - 1, V[0]);
  Result := True;
end;

function ApplyArc(E: TCADSketchEditor; const V: TCADTypedValues; out AError: string): Boolean;
var
  CX, CY, SX, SY, DX, DY, R, A: Double;
begin
  Result := False;
  E.ClickPos(0, CX, CY);
  if E.ClickCount = 1 then
  begin
    if V[0] <= 0 then
      Exit;
    CursorDir(E, CX, CY, DX, DY);
    E.ClickExact(CX + V[0] * DX, CY + V[0] * DY);
    Exit(True);
  end;
  if (Abs(V[0]) < 1e-9) or (Abs(V[0]) >= 360) then
  begin
    AError := 'sweep angle between -360 and 360, not 0';
    Exit;
  end;
  E.ClickPos(1, SX, SY);
  R := Hypot(SX - CX, SY - CY);
  A := ArcTan2(SY - CY, SX - CX) + DegToRad(V[0]);
  Result := E.ClickExact(CX + R * Cos(A), CY + R * Sin(A));
end;

function ApplyArc3(E: TCADSketchEditor; const V: TCADTypedValues; out AError: string): Boolean;
var
  S: TCADSketch;
  X0, Y0, X1, Y1, MX, MY, NX, NY, C, D, R, X, Y: Double;
  N: Integer;
begin
  Result := False;
  if E.ClickCount = 1 then
  begin
    if V[0] <= 0 then
      Exit;
    E.ClickPos(0, X0, Y0);
    Ahead(E, X0, Y0, V, X, Y);
    E.ClickExact(X, Y);
    Exit(True);
  end;
  S := E.Sketch;
  R := V[0];
  E.ClickPos(0, X0, Y0);
  E.ClickPos(1, X1, Y1);
  C := Hypot(X1 - X0, Y1 - Y0);
  if R < C / 2 - 1e-9 then
  begin
    AError := Format('radius at least half the chord (%.4g)', [C / 2]);
    Exit;
  end;
  MX := (X0 + X1) / 2;
  MY := (Y0 + Y1) / 2;
  NX := -(Y1 - Y0) / C;                    { chord normal ... }
  NY := (X1 - X0) / C;
  if (E.CursorX - MX) * NX + (E.CursorY - MY) * NY < 0 then
  begin
    NX := -NX;                             { ... towards the cursor }
    NY := -NY;
  end;
  D := Sqrt(Max(0, R * R - C * C / 4));
  N := S.EntityCount;
  { the middle of the short arc on the cursor side }
  if not E.ClickExact(MX + NX * (R - D), MY + NY * (R - D)) or (S.EntityCount = N) then
    Exit;
  S.Radius(S.EntityCount - 1, R);
  Result := True;
end;

function CADApplyTyped(AEditor: TCADSketchEditor; const AText: string;
  out AError: string): Boolean;
var
  V: TCADTypedValues;
  Prompt: string;
begin
  Result := False;
  AError := '';
  Prompt := CADTypedPrompt(AEditor);
  if Prompt = '' then
  begin
    AError := 'pick a drawing tool first';
    Exit;
  end;
  if not CADParseTypedValues(AText, V) then
  begin
    AError := 'type ' + Prompt;
    Exit;
  end;
  if Prompt = 'x, y' then
  begin
    if Length(V) < 2 then
      AError := 'type x, y'
    else
      Result := AEditor.ClickExact(V[0], V[1]) or (AEditor.ClickCount > 0) or
        (AEditor.ChainLast >= 0);
  end
  else
    case AEditor.Tool of
      sktLine: Result := ApplyLine(AEditor, V, AError);
      sktRectangle: Result := ApplyRectangle(AEditor, V, AError);
      sktCircle: Result := ApplyCircle(AEditor, V, AError);
      sktArc: Result := ApplyArc(AEditor, V, AError);
      sktArc3: Result := ApplyArc3(AEditor, V, AError);
    end;
  if Result then
    AEditor.Resolve
  else if AError = '' then
    AError := 'not possible here: type ' + Prompt;
end;

initialization
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
end.
