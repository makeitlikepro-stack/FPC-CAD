unit CAD.Sketch.Text;
{$mode objfpc}{$H+}

{ ROLE:      sketch <-> text. The sketch feature keeps its sketch as one
             text parameter, so the cache key, Undo/Redo (SetParam commands)
             and later file saving work without a sketch-specific path.
  CALLED BY: CAD.Features.Sketch, the sketch editor (later), tests.
  CALLS:     CAD.Sketch.Model.
  THREADS:   pure, any thread (each call uses its own sketch).
  SPEED:     one line per item, numbers with 17 significant digits (exact
             round trip), '.' decimal point whatever the locale.

  Format (one item per line, fields separated by one space):
    FPCSKETCH 1
    plane ox oy oz xx xy xz nx ny nz
    P x y fixed                       point (fixed 0/1)
    L p1 p2 construction              line
    C center radius construction      circle
    A center start end construction   arc (its arc rule is a K line)
    K kind a b c value side active    constraint, kind by name
  Points come first, then entities, then constraints, each in index order,
  so every index is the same after loading. }

interface

uses
  Classes, SysUtils, CAD.Sketch.Model;

function CADSketchToText(S: TCADSketch): string;
{ Loads into an empty sketch. Raises ECADSketch with the line number. }
procedure CADSketchFromText(const AText: string; S: TCADSketch);
function CADConstraintKindName(AKind: TCADSketchConstraintKind): string;

implementation

const
  KindNames: array[TCADSketchConstraintKind] of string = (
    'coincident', 'horizontal', 'vertical', 'horizontal_pts', 'vertical_pts',
    'distance', 'distance_x', 'distance_y', 'length', 'point_on_line',
    'point_on_circle', 'point_line_distance', 'parallel', 'perpendicular',
    'angle', 'collinear', 'equal_length', 'equal_radius', 'radius', 'diameter',
    'tangent_line', 'tangent_circles', 'concentric', 'midpoint', 'symmetric',
    'arc_rule');

var
  FS: TFormatSettings;

function CADConstraintKindName(AKind: TCADSketchConstraintKind): string;
begin
  Result := KindNames[AKind];
end;

function Num(V: Double): string;
begin
  Result := Format('%.17g', [V], FS);
end;

function Flag(V: Boolean): string;
begin
  if V then Result := '1' else Result := '0';
end;

function CADSketchToText(S: TCADSketch): string;
var
  L: TStringList;
  I: Integer;
  E: TCADSketchEntity;
  C: TCADSketchConstraint;
  P: TCADSketchPlane;
  HasDeleted: Boolean;
begin
  HasDeleted := False;
  for I := 0 to S.EntityCount - 1 do
    if not S.Entities[I].Active then
      HasDeleted := True;
  for I := 0 to S.PointCount - 1 do
    if not S.Points[I].Active then
      HasDeleted := True;
  L := TStringList.Create;
  try
    { New editors read both versions. Old editors must not silently
      resurrect deleted geometry by ignoring optional Active fields. }
    if HasDeleted then L.Add('FPCSKETCH 2')
    else L.Add('FPCSKETCH 1');
    P := S.Plane;
    L.Add(Format('plane %s %s %s %s %s %s %s %s %s', [Num(P.Origin[0]), Num(P.Origin[1]),
      Num(P.Origin[2]), Num(P.XDir[0]), Num(P.XDir[1]), Num(P.XDir[2]), Num(P.Normal[0]),
      Num(P.Normal[1]), Num(P.Normal[2])]));
    for I := 0 to S.PointCount - 1 do
      L.Add(Format('P %s %s %s %s', [Num(S.PointX(I)), Num(S.PointY(I)),
        Flag(S.Fixed[S.Points[I].XParam]), Flag(S.Points[I].Active)]));
    for I := 0 to S.EntityCount - 1 do
    begin
      E := S.Entities[I];
      case E.Kind of
        sekLine: L.Add(Format('L %d %d %s %s', [E.P1, E.P2, Flag(E.Construction), Flag(E.Active)]));
        sekCircle: L.Add(Format('C %d %s %s %s', [E.Center, Num(S.Params[E.RadiusParam]),
          Flag(E.Construction), Flag(E.Active)]));
        sekArc: L.Add(Format('A %d %d %d %s %s', [E.Center, E.P1, E.P2, Flag(E.Construction), Flag(E.Active)]));
      end;
    end;
    for I := 0 to S.ConstraintCount - 1 do
    begin
      C := S.Constraints[I];
      L.Add(Format('K %s %d %d %d %s %s %s', [KindNames[C.Kind], C.A, C.B, C.C,
        Num(C.Value), Num(C.Side), Flag(C.Active)]));
    end;
    L.LineBreak := #10;
    Result := L.Text;
  finally
    L.Free;
  end;
end;

procedure CADSketchFromText(const AText: string; S: TCADSketch);
var
  Lines, F: TStringList;
  I, N: Integer;
  C: TCADSketchConstraint;
  K: TCADSketchConstraintKind;
  Found: Boolean;
  Pl: array[0..8] of Double;

  procedure Bad(const AMsg: string);
  begin
    raise ECADSketch.CreateFmt('sketch text line %d: %s', [I + 1, AMsg]);
  end;

  function D(AField: Integer): Double;
  begin
    if AField >= F.Count then
      Bad('missing field');
    if not TryStrToFloat(F[AField], Result, FS) then
      Bad('not a number: ' + F[AField]);
  end;

  function Int(AField: Integer): Integer;
  begin
    if AField >= F.Count then
      Bad('missing field');
    if not TryStrToInt(F[AField], Result) then
      Bad('not an integer: ' + F[AField]);
  end;

begin
  if (S.PointCount > 0) or (S.EntityCount > 0) or (S.ConstraintCount > 0) then
    raise ECADSketch.Create('sketch text: load into an empty sketch');
  Lines := TStringList.Create;
  F := TStringList.Create;
  try
    Lines.Text := AText;
    F.Delimiter := ' ';
    F.StrictDelimiter := True;
    I := 0;
    if (Lines.Count = 0) or
       ((Trim(Lines[0]) <> 'FPCSKETCH 1') and
        (Trim(Lines[0]) <> 'FPCSKETCH 2')) then
      Bad('expected "FPCSKETCH 1" or "FPCSKETCH 2"');
    for I := 1 to Lines.Count - 1 do
    begin
      if Trim(Lines[I]) = '' then
        Continue;
      F.DelimitedText := Trim(Lines[I]);
      try
        if F[0] = 'plane' then
        begin
          for N := 0 to 8 do
            Pl[N] := D(N + 1);
          S.SetPlane([Pl[0], Pl[1], Pl[2]], [Pl[3], Pl[4], Pl[5]], [Pl[6], Pl[7], Pl[8]]);
        end
        else if F[0] = 'P' then
        begin
          N := S.AddPoint(D(1), D(2));
          if Int(3) <> 0 then
            S.FixPoint(N);
          { Older FPCSKETCH 1 files have no active field: they stay valid. }
          if (F.Count > 4) and (Int(4) = 0) then
            S.SetPointActive(N, False);
        end
        else if F[0] = 'L' then
        begin
          N := S.AddLine(Int(1), Int(2));
          S.SetConstruction(N, Int(3) <> 0);
          if (F.Count > 4) and (Int(4) = 0) then
            S.SetEntityActive(N, False);
        end
        else if F[0] = 'C' then
        begin
          N := S.AddCircle(Int(1), D(2));
          S.SetConstruction(N, Int(3) <> 0);
          if (F.Count > 4) and (Int(4) = 0) then
            S.SetEntityActive(N, False);
        end
        else if F[0] = 'A' then
        begin
          N := S.AddArc(Int(1), Int(2), Int(3), False);
          S.SetConstruction(N, Int(4) <> 0);
          if (F.Count > 5) and (Int(5) = 0) then
            S.SetEntityActive(N, False);
        end
        else if F[0] = 'K' then
        begin
          if F.Count < 2 then
            Bad('missing kind');
          Found := False;
          for K := Low(TCADSketchConstraintKind) to High(TCADSketchConstraintKind) do
            if KindNames[K] = F[1] then
            begin
              C.Kind := K;
              Found := True;
            end;
          if not Found then
            Bad('unknown constraint kind ' + F[1]);
          C.A := Int(2);
          C.B := Int(3);
          C.C := Int(4);
          C.Value := D(5);
          C.Side := D(6);
          C.Active := Int(7) <> 0;
          S.AddConstraintRaw(C);
        end
        else
          Bad('unknown item ' + F[0]);
      except
        on E: ECADSketch do
          if Pos('sketch text line', E.Message) = 1 then
            raise
          else
            Bad(E.Message);
      end;
    end;
  finally
    F.Free;
    Lines.Free;
  end;
end;

initialization
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := #0;
end.
