unit CAD.Sketch.Outline;
{$mode objfpc}{$H+}

{ ROLE: Union adjacent selected sketch regions into clean planar outlines.
  Shared virtual edges disappear; independent islands remain separate faces;
  clockwise inner rings remain holes. No Sketch entity is modified.
  This is a 2D topology operation BEFORE OCCT face/prism construction,
  so the final B-rep has no artificial internal side walls or surface seams. }

interface

uses
  SysUtils, Math, CAD.Sketch.Profile;

{ True: combined exact line/arc profile in AOutline.
  False: unsafe junction or open boundary, AError identifies the problem.
  All input faces are interpreted as *selected* regions. }
function CADUnionSelectedOutlines(const ASelected: TCADSketchProfile;
  out AOutline: TCADSketchProfile; out AError: string): Boolean;

implementation

const
  EdgeTolerance = 1e-7;
  MinArea = 1e-10;

type
  TMarkedEdge = record
    Edge: TCADProfileEdge;
    Removed, Used: Boolean;
  end;
  TMarkedEdges = array of TMarkedEdge;

function SameXY(AX, AY, BX, BY: Double): Boolean; inline;
begin
  Result := Hypot(AX - BX, AY - BY) <= EdgeTolerance;
end;

function NormalAngle(A: Double): Double;
begin
  Result := A;
  while Result < 0 do Result := Result + 2 * Pi;
  while Result >= 2 * Pi do Result := Result - 2 * Pi;
end;

function CCWSweep(A, B: Double): Double;
begin
  Result := NormalAngle(B - A);
  if Result < 1e-12 then Result := 2 * Pi;
end;

function SignedEdgeArea(const E: TCADProfileEdge): Double;
var
  A, B, Sweep: Double;
begin
  if E.Kind = pekCircle then
  begin
    if E.CCW then Result := Pi * Sqr(E.R)
    else Result := -Pi * Sqr(E.R);
    Exit;
  end;
  Result := 0.5 * (E.X1 * E.Y2 - E.X2 * E.Y1);
  if E.Kind <> pekArc then Exit;
  A := ArcTan2(E.Y1 - E.CY, E.X1 - E.CX);
  B := ArcTan2(E.Y2 - E.CY, E.X2 - E.CX);
  if E.CCW then
  begin
    Sweep := CCWSweep(A, B);
    Result := Result + 0.5 * Sqr(E.R) * (Sweep - Sin(Sweep));
  end
  else
  begin
    Sweep := CCWSweep(B, A);
    Result := Result - 0.5 * Sqr(E.R) * (Sweep - Sin(Sweep));
  end;
end;

function ReverseMatches(const E, F: TCADProfileEdge): Boolean;
begin
  Result := False;
  if (E.Kind <> F.Kind) or
     (not SameXY(E.X1, E.Y1, F.X2, F.Y2)) or
     (not SameXY(E.X2, E.Y2, F.X1, F.Y1)) then Exit;
  if E.Kind = pekLine then Exit(True);
  Result := (E.CCW <> F.CCW) and
    SameXY(E.CX, E.CY, F.CX, F.CY) and
    (Abs(E.R - F.R) <= EdgeTolerance);
end;

function StartAngle(const E: TCADProfileEdge): Double;
var
  A: Double;
begin
  if E.Kind = pekLine then
    Exit(NormalAngle(ArcTan2(E.Y2 - E.Y1, E.X2 - E.X1)));
  A := ArcTan2(E.Y1 - E.CY, E.X1 - E.CX);
  if E.CCW then Result := NormalAngle(A + Pi / 2)
  else Result := NormalAngle(A - Pi / 2);
end;

function ReverseEndAngle(const E: TCADProfileEdge): Double;
var
  A: Double;
begin
  if E.Kind = pekLine then
    Exit(NormalAngle(ArcTan2(E.Y1 - E.Y2, E.X1 - E.X2)));
  A := ArcTan2(E.Y2 - E.CY, E.X2 - E.CX);
  if E.CCW then Result := NormalAngle(A - Pi / 2)
  else Result := NormalAngle(A + Pi / 2);
end;

function ContainsPoint(const L: TCADProfileLoop; X, Y: Double): Boolean;
var
  PX, PY: TCADDoubleArray;
  N, I, Prev: Integer;
begin
  Result := False;
  CADSampleLoop(L, PX, PY, N);
  if N < 3 then Exit;
  Prev := N - 1;
  for I := 0 to N - 1 do
  begin
    if ((PY[I] > Y) <> (PY[Prev] > Y)) and
      (X < (PX[Prev] - PX[I]) * (Y - PY[I]) /
           (PY[Prev] - PY[I]) + PX[I]) then
      Result := not Result;
    Prev := I;
  end;
end;

procedure HoleTestPoint(const E: TCADProfileEdge; out X, Y: Double);
var
  A, B, AngleMid, DX, DY, D: Double;
begin
  if E.Kind = pekLine then
  begin
    X := (E.X1 + E.X2) * 0.5;
    Y := (E.Y1 + E.Y2) * 0.5;
    DX := E.X2 - E.X1;
    DY := E.Y2 - E.Y1;
  end
  else
  begin
    A := ArcTan2(E.Y1 - E.CY, E.X1 - E.CX);
    B := ArcTan2(E.Y2 - E.CY, E.X2 - E.CX);
    if E.CCW then AngleMid := A + CCWSweep(A, B) * 0.5
    else AngleMid := A - CCWSweep(B, A) * 0.5;
    X := E.CX + E.R * Cos(AngleMid);
    Y := E.CY + E.R * Sin(AngleMid);
    if E.CCW then
    begin
      DX := -Sin(AngleMid);
      DY := Cos(AngleMid);
    end
    else
    begin
      DX := Sin(AngleMid);
      DY := -Cos(AngleMid);
    end;
  end;
  D := Hypot(DX, DY);
  if D > 1e-12 then
  begin
    { The left side of a clockwise boundary lies outside the hole. }
    X := X - DY / D * EdgeTolerance * 10;
    Y := Y + DX / D * EdgeTolerance * 10;
  end;
end;

function CADUnionSelectedOutlines(const ASelected: TCADSketchProfile;
  out AOutline: TCADSketchProfile; out AError: string): Boolean;
var
  Items: TMarkedEdges;
  I, J, K, F, H, N, Total, Head, NextIndex, Count: Integer;
  NextDelta, D, PX, PY, Area, Smallest: Double;
  L: TCADProfileLoop;
  Parent: Integer;

  procedure AppendLoop(LoopIndex: Integer);
  var
    E, K: Integer;
  begin
    for K := 0 to High(ASelected.Loops[LoopIndex].Edges) do
    begin
      E := Length(Items);
      SetLength(Items, E + 1);
      Items[E].Edge := ASelected.Loops[LoopIndex].Edges[K];
      Items[E].Removed := False;
      Items[E].Used := False;
    end;
  end;

begin
  Result := False;
  AOutline := Default(TCADSketchProfile);
  AOutline.ErrorPoint := -1;
  AError := '';
  Items := nil;

  { Include only loops belonging to the chosen faces; inactive/unselected
    region loops are not part of the Boolean union. }
  for F := 0 to High(ASelected.Faces) do
  begin
    AppendLoop(ASelected.Faces[F].Outer);
    for H := 0 to High(ASelected.Faces[F].Holes) do
      AppendLoop(ASelected.Faces[F].Holes[H]);
  end;
  if Length(Items) = 0 then
  begin
    AError := 'no selected contour edges';
    Exit;
  end;

  { Each interior edge appears twice with opposite orientation. Remove both
    instead of sending a compound of adjacent faces to OCCT. }
  for I := 0 to High(Items) do
  begin
    if Items[I].Removed then Continue;
    for J := I + 1 to High(Items) do
      if not Items[J].Removed and
         ReverseMatches(Items[I].Edge, Items[J].Edge) then
      begin
        Items[I].Removed := True;
        Items[J].Removed := True;
        Break;
      end;
  end;

  { Walk remaining directed edges using the smallest clockwise turn from
    the incoming reverse tangent. This resolves four-way vertices without
    joining two regions that touch only at a point. }
  for I := 0 to High(Items) do
  begin
    if Items[I].Removed or Items[I].Used then Continue;
    L := Default(TCADProfileLoop);
    L.Parent := -1;
    Head := I;
    J := I;
    Total := 0;
    repeat
      if Items[J].Used then
      begin
        AError := 'selected contours have an ambiguous boundary junction';
        Exit;
      end;
      Items[J].Used := True;
      N := Length(L.Edges);
      SetLength(L.Edges, N + 1);
      L.Edges[N] := Items[J].Edge;
      L.Area := L.Area + SignedEdgeArea(Items[J].Edge);
      Inc(Total);
      if SameXY(Items[J].Edge.X2, Items[J].Edge.Y2,
                Items[Head].Edge.X1, Items[Head].Edge.Y1) then Break;
      NextIndex := -1;
      NextDelta := 1e100;
      for K := 0 to High(Items) do
      begin
        if Items[K].Removed or Items[K].Used then Continue;
        if not SameXY(Items[J].Edge.X2, Items[J].Edge.Y2,
                      Items[K].Edge.X1, Items[K].Edge.Y1) then Continue;
        D := NormalAngle(ReverseEndAngle(Items[J].Edge) -
                         StartAngle(Items[K].Edge));
        if D < NextDelta then
        begin
          NextDelta := D;
          NextIndex := K;
        end;
      end;
      if NextIndex < 0 then
      begin
        AError := 'selected contour union produced an open boundary';
        Exit;
      end;
      J := NextIndex;
      if Total > Length(Items) then
      begin
        AError := 'selected contour union did not close';
        Exit;
      end;
    until False;

    if Abs(L.Area) <= MinArea then
    begin
      AError := 'selected contour union produced a degenerate ring';
      Exit;
    end;
    N := Length(AOutline.Loops);
    SetLength(AOutline.Loops, N + 1);
    AOutline.Loops[N] := L;
  end;

  { One positive ring per connected island; negative rings are holes.
    A hole is owned by the smallest positive ring containing a point just
    outside its boundary. }
  for I := 0 to High(AOutline.Loops) do
    if AOutline.Loops[I].Area > MinArea then
    begin
      F := Length(AOutline.Faces);
      SetLength(AOutline.Faces, F + 1);
      AOutline.Faces[F].Outer := I;
      AOutline.Faces[F].Area := AOutline.Loops[I].Area;
    end;

  for I := 0 to High(AOutline.Loops) do
  begin
    if AOutline.Loops[I].Area >= -MinArea then Continue;
    HoleTestPoint(AOutline.Loops[I].Edges[0], PX, PY);
    Parent := -1;
    Smallest := 1e100;
    for F := 0 to High(AOutline.Faces) do
    begin
      J := AOutline.Faces[F].Outer;
      if (AOutline.Loops[J].Area > Abs(AOutline.Loops[I].Area) + MinArea) and
         (AOutline.Loops[J].Area < Smallest) and
         ContainsPoint(AOutline.Loops[J], PX, PY) then
      begin
        Parent := F;
        Smallest := AOutline.Loops[J].Area;
      end;
    end;
    if Parent < 0 then
    begin
      AError := 'selected contours have an uncontained hole';
      Exit;
    end;
    H := Length(AOutline.Faces[Parent].Holes);
    SetLength(AOutline.Faces[Parent].Holes, H + 1);
    AOutline.Faces[Parent].Holes[H] := I;
    AOutline.Faces[Parent].Area :=
      AOutline.Faces[Parent].Area + AOutline.Loops[I].Area;
    AOutline.Loops[I].Parent := AOutline.Faces[Parent].Outer;
  end;
  Result := Length(AOutline.Faces) > 0;
  if not Result then AError := 'selected contours have no bounded outline';
end;

end.
