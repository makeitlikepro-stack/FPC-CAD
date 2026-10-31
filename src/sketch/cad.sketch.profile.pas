unit CAD.Sketch.Profile;
{$mode objfpc}{$H+}

{ ROLE:      turns the (solved) sketch geometry into closed loops and faces:
             each face = one outer loop (counter-clockwise) and its holes
             (clockwise), ready for an OCCT planar face and Extrude.
  CALLED BY: sketch features (Extrude, later Revolve), tests/sketch.
  CALLS:     CAD.Sketch.Model.
  THREADS:   pure, any thread.
  SPEED:     union-find for joined points, one walk per loop; nesting and
             crossing tests on sampled polylines (arcs: 3 degree steps),
             O(segments^2) - sketches stay in the thousands of segments.

  Rules: construction geometry is ignored. Ends are joined when they are the
  same point, joined by a Coincident constraint, or at the same position
  (1e-7 of the sketch size). Every joint must have exactly two edges: one =
  open profile, three or more = branch; both are errors with the point. Loops
  must not cross each other or themselves. Nesting depth decides the role:
  even depth = outer loop of a face, odd depth = hole of its parent. }

interface

uses
  SysUtils, Math, CAD.Sketch.Model;

type
  TCADDoubleArray = array of Double;

  TCADProfileEdgeKind = (pekLine, pekArc, pekCircle);

  { One edge in loop order: it runs from (X1, Y1) to (X2, Y2). Arc: CCW =
    True when the walk goes counter-clockwise around (CX, CY). Circle: the
    whole circle, CCW tells the direction. }
  TCADProfileEdge = record
    Kind: TCADProfileEdgeKind;
    Entity: Integer;
    X1, Y1, X2, Y2: Double;
    CX, CY, R: Double;
    CCW: Boolean;
  end;

  TCADProfileLoop = record
    Edges: array of TCADProfileEdge;
    Area: Double;               { signed: > 0 counter-clockwise }
    Depth: Integer;             { loops around it }
    Parent: Integer;            { innermost loop around it, -1 = none }
  end;

  TCADProfileFace = record
    Outer: Integer;             { loop index }
    Holes: array of Integer;    { loop indices }
    Area: Double;               { outer minus holes }
  end;

  TCADSketchProfile = record
    Loops: array of TCADProfileLoop;
    Faces: array of TCADProfileFace;
    Error: string;              { '' = ok }
    ErrorPoint: Integer;        { point index for open/branch errors, else -1 }
  end;

{ False with AProfile.Error when the geometry is not a set of closed,
  non-crossing loops. No profile edges at all is an error too. }
function CADBuildProfile(S: TCADSketch; out AProfile: TCADSketchProfile): Boolean;
{ Polyline of a loop (arcs and circles sampled, last point not repeated). }
procedure CADSampleLoop(const ALoop: TCADProfileLoop; out AX, AY: TCADDoubleArray;
  out ACount: Integer);

implementation

type
  TDoubles = TCADDoubleArray;

{ ---------------------------------------------------------- helpers }

function SweepCCW(const E: TCADProfileEdge): Double;
var
  A1, A2: Double;
begin
  { angle swept by the walk, always > 0 }
  A1 := ArcTan2(E.Y1 - E.CY, E.X1 - E.CX);
  A2 := ArcTan2(E.Y2 - E.CY, E.X2 - E.CX);
  if E.CCW then
    Result := A2 - A1
  else
    Result := A1 - A2;
  while Result <= 1e-12 do
    Result := Result + 2 * Pi;
end;

function EdgeArea(const E: TCADProfileEdge): Double;
var
  T: Double;
begin
  case E.Kind of
    pekCircle:
      begin
        Result := Pi * Sqr(E.R);
        if not E.CCW then
          Result := -Result;
      end;
    pekArc:
      begin
        T := SweepCCW(E);
        { chord (shoelace) + circular segment, signed by the walk direction }
        Result := 0.5 * (E.X1 * E.Y2 - E.X2 * E.Y1) + 0.5 * Sqr(E.R) * (T - Sin(T)) *
          IfThen(E.CCW, 1.0, -1.0);
      end;
  else
    Result := 0.5 * (E.X1 * E.Y2 - E.X2 * E.Y1);
  end;
end;

procedure SampleEdge(const E: TCADProfileEdge; var AX, AY: TDoubles; var ACount: Integer);
var
  N, I: Integer;
  T, A0, Dir: Double;

  procedure Add(X, Y: Double);
  begin
    if ACount >= Length(AX) then
    begin
      SetLength(AX, Max(64, Length(AX) * 2));
      SetLength(AY, Length(AX));
    end;
    AX[ACount] := X;
    AY[ACount] := Y;
    Inc(ACount);
  end;

begin
  if E.Kind = pekLine then
  begin
    Add(E.X1, E.Y1);
    Exit;
  end;
  if E.Kind = pekCircle then
  begin
    T := 2 * Pi;
    A0 := 0;
  end
  else
  begin
    T := SweepCCW(E);
    A0 := ArcTan2(E.Y1 - E.CY, E.X1 - E.CX);
  end;
  if E.CCW then Dir := 1 else Dir := -1;
  N := Max(4, Ceil(T / DegToRad(3)));
  for I := 0 to N - 1 do
    Add(E.CX + E.R * Cos(A0 + Dir * T * I / N), E.CY + E.R * Sin(A0 + Dir * T * I / N));
end;

procedure SampleLoopRaw(const L: TCADProfileLoop; out AX, AY: TDoubles; out ACount: Integer);
var
  I: Integer;
begin
  AX := nil;
  AY := nil;
  ACount := 0;
  for I := 0 to High(L.Edges) do
    SampleEdge(L.Edges[I], AX, AY, ACount);
end;

procedure CADSampleLoop(const ALoop: TCADProfileLoop; out AX, AY: TCADDoubleArray;
  out ACount: Integer);
begin
  SampleLoopRaw(ALoop, AX, AY, ACount);
end;

function PointInPolygon(PX, PY: Double; const AX, AY: TDoubles; ACount: Integer): Boolean;
var
  I, J: Integer;
begin
  Result := False;
  J := ACount - 1;
  for I := 0 to ACount - 1 do
  begin
    if ((AY[I] > PY) <> (AY[J] > PY)) and
       (PX < (AX[J] - AX[I]) * (PY - AY[I]) / (AY[J] - AY[I]) + AX[I]) then
      Result := not Result;
    J := I;
  end;
end;

function SegmentsCross(AX1, AY1, AX2, AY2, BX1, BY1, BX2, BY2: Double): Boolean;
var
  D1, D2, D3, D4: Double;
begin
  { proper crossing only: touching ends do not count }
  D1 := (BX2 - BX1) * (AY1 - BY1) - (BY2 - BY1) * (AX1 - BX1);
  D2 := (BX2 - BX1) * (AY2 - BY1) - (BY2 - BY1) * (AX2 - BX1);
  D3 := (AX2 - AX1) * (BY1 - AY1) - (AY2 - AY1) * (BX1 - AX1);
  D4 := (AX2 - AX1) * (BY2 - AY1) - (AY2 - AY1) * (BX2 - AX1);
  Result := (D1 * D2 < 0) and (D3 * D4 < 0);
end;

procedure ReverseLoop(var L: TCADProfileLoop);
var
  I, N: Integer;
  E: TCADProfileEdge;
  T: Double;
begin
  N := Length(L.Edges);
  for I := 0 to N div 2 - 1 do
  begin
    E := L.Edges[I];
    L.Edges[I] := L.Edges[N - 1 - I];
    L.Edges[N - 1 - I] := E;
  end;
  for I := 0 to N - 1 do
  begin
    T := L.Edges[I].X1; L.Edges[I].X1 := L.Edges[I].X2; L.Edges[I].X2 := T;
    T := L.Edges[I].Y1; L.Edges[I].Y1 := L.Edges[I].Y2; L.Edges[I].Y2 := T;
    L.Edges[I].CCW := not L.Edges[I].CCW;
  end;
  L.Area := -L.Area;
end;

{ ---------------------------------------------------------- building }

type
  TBuilder = record
    S: TCADSketch;
    Root: array of Integer;          { union-find over points }
    EdgeEnt: array of Integer;       { profile entity per edge }
    EdgeA, EdgeB: array of Integer;  { root at P1 / P2 }
    EdgeCount: Integer;
    Deg: array of Integer;           { per root }
    Adj: array of array[0..1] of Integer;
  end;

function Find(var B: TBuilder; P: Integer): Integer;
begin
  Result := P;
  while B.Root[Result] <> Result do
    Result := B.Root[Result];
  while B.Root[P] <> Result do
  begin
    P := B.Root[P];
    B.Root[P] := Result;
  end;
end;

procedure Union(var B: TBuilder; P, Q: Integer);
begin
  P := Find(B, P);
  Q := Find(B, Q);
  if P <> Q then
    B.Root[Q] := P;
end;

function SketchSize(S: TCADSketch): Double;
var
  I: Integer;
  Lo, Hi: array[0..1] of Double;
begin
  Result := 1;
  if S.PointCount = 0 then
    Exit;
  Lo[0] := S.PointX(0); Hi[0] := Lo[0];
  Lo[1] := S.PointY(0); Hi[1] := Lo[1];
  for I := 1 to S.PointCount - 1 do
  begin
    Lo[0] := Min(Lo[0], S.PointX(I)); Hi[0] := Max(Hi[0], S.PointX(I));
    Lo[1] := Min(Lo[1], S.PointY(I)); Hi[1] := Max(Hi[1], S.PointY(I));
  end;
  Result := Max(1.0, Max(Hi[0] - Lo[0], Hi[1] - Lo[1]));
end;

procedure JoinPoints(var B: TBuilder);
var
  I, J: Integer;
  C: TCADSketchConstraint;
  Tol: Double;
  Used: array of Boolean;
  E: TCADSketchEntity;
begin
  for I := 0 to B.S.ConstraintCount - 1 do
  begin
    C := B.S.Constraints[I];
    if C.Active and (C.Kind = sckCoincident) then
      Union(B, C.A, C.B);
  end;
  { same position: only ends of profile edges }
  SetLength(Used, B.S.PointCount);
  for I := 0 to B.S.EntityCount - 1 do
  begin
    E := B.S.Entities[I];
    if E.Active and (not E.Construction) and (E.Kind <> sekCircle) then
    begin
      Used[E.P1] := True;
      Used[E.P2] := True;
    end;
  end;
  Tol := 1e-7 * SketchSize(B.S);
  for I := 0 to B.S.PointCount - 1 do
    if Used[I] then
      for J := I + 1 to B.S.PointCount - 1 do
        if Used[J] and (Abs(B.S.PointX(I) - B.S.PointX(J)) <= Tol) and
           (Abs(B.S.PointY(I) - B.S.PointY(J)) <= Tol) then
          Union(B, I, J);
end;

function MakeEdge(S: TCADSketch; AEntity: Integer; AForward: Boolean): TCADProfileEdge;
var
  E: TCADSketchEntity;
  PA, PB: Integer;
begin
  E := S.Entities[AEntity];
  Result := Default(TCADProfileEdge);
  Result.Entity := AEntity;
  if E.Kind = sekCircle then
  begin
    Result.Kind := pekCircle;
    Result.CX := S.PointX(E.Center);
    Result.CY := S.PointY(E.Center);
    Result.R := S.EntityRadius(AEntity);
    Result.X1 := Result.CX + Result.R;
    Result.Y1 := Result.CY;
    Result.X2 := Result.X1;
    Result.Y2 := Result.Y1;
    Result.CCW := True;
    Exit;
  end;
  if AForward then
  begin
    PA := E.P1;
    PB := E.P2;
  end
  else
  begin
    PA := E.P2;
    PB := E.P1;
  end;
  Result.X1 := S.PointX(PA);
  Result.Y1 := S.PointY(PA);
  Result.X2 := S.PointX(PB);
  Result.Y2 := S.PointY(PB);
  if E.Kind = sekLine then
    Result.Kind := pekLine
  else
  begin
    Result.Kind := pekArc;
    Result.CX := S.PointX(E.Center);
    Result.CY := S.PointY(E.Center);
    Result.R := S.EntityRadius(AEntity);
    Result.CCW := AForward;     { an arc runs CCW from start (P1) to end (P2) }
  end;
end;

function Fail(var AProfile: TCADSketchProfile; const AMsg: string; APoint: Integer): Boolean;
begin
  AProfile.Error := AMsg;
  AProfile.ErrorPoint := APoint;
  Result := False;
end;

function WalkLoops(var B: TBuilder; var AProfile: TCADSketchProfile): Boolean;
var
  Done: array of Boolean;
  I, E, Node, Next, NL, NE: Integer;
  Loop: TCADProfileLoop;
begin
  Result := True;
  SetLength(Done, B.EdgeCount);
  NL := Length(AProfile.Loops);
  for I := 0 to B.EdgeCount - 1 do
  begin
    if Done[I] then
      Continue;
    Loop := Default(TCADProfileLoop);
    SetLength(Loop.Edges, B.EdgeCount);
    NE := 0;
    E := I;
    Node := B.EdgeA[I];
    repeat
      Done[E] := True;
      { walk forward when we enter at P1 }
      Loop.Edges[NE] := MakeEdge(B.S, B.EdgeEnt[E], B.EdgeA[E] = Node);
      Inc(NE);
      if B.EdgeA[E] = Node then
        Node := B.EdgeB[E]
      else
        Node := B.EdgeA[E];
      if B.Adj[Node][0] = E then
        Next := B.Adj[Node][1]
      else
        Next := B.Adj[Node][0];
      E := Next;
    until Done[E];
    if E <> I then
      Exit(Fail(AProfile, 'profile walk did not close', Node));
    SetLength(Loop.Edges, NE);
    SetLength(AProfile.Loops, NL + 1);
    AProfile.Loops[NL] := Loop;
    Inc(NL);
  end;
end;

function CollectEdges(var B: TBuilder; var AProfile: TCADSketchProfile): Boolean;
var
  I, N, A, Z: Integer;
  E: TCADSketchEntity;
  Loop: TCADProfileLoop;
begin
  Result := True;
  SetLength(B.EdgeEnt, B.S.EntityCount);
  SetLength(B.EdgeA, B.S.EntityCount);
  SetLength(B.EdgeB, B.S.EntityCount);
  SetLength(B.Deg, B.S.PointCount);
  SetLength(B.Adj, B.S.PointCount);
  B.EdgeCount := 0;
  for I := 0 to B.S.EntityCount - 1 do
  begin
    E := B.S.Entities[I];
    if (not E.Active) or E.Construction then
      Continue;
    if E.Kind = sekCircle then
    begin
      Loop := Default(TCADProfileLoop);
      SetLength(Loop.Edges, 1);
      Loop.Edges[0] := MakeEdge(B.S, I, True);
      N := Length(AProfile.Loops);
      SetLength(AProfile.Loops, N + 1);
      AProfile.Loops[N] := Loop;
      Continue;
    end;
    A := Find(B, E.P1);
    Z := Find(B, E.P2);
    if A = Z then
      Exit(Fail(AProfile, Format('entity %d starts and ends at the same point', [I]), E.P1));
    N := B.EdgeCount;
    B.EdgeEnt[N] := I;
    B.EdgeA[N] := A;
    B.EdgeB[N] := Z;
    if B.Deg[A] < 2 then B.Adj[A][B.Deg[A]] := N;
    if B.Deg[Z] < 2 then B.Adj[Z][B.Deg[Z]] := N;
    Inc(B.Deg[A]);
    Inc(B.Deg[Z]);
    Inc(B.EdgeCount);
  end;
  for I := 0 to B.S.PointCount - 1 do
    if (Find(B, I) = I) and (B.Deg[I] > 0) and (B.Deg[I] <> 2) then
    begin
      if B.Deg[I] = 1 then
        Exit(Fail(AProfile, Format('open profile at point %d', [I]), I))
      else
        Exit(Fail(AProfile, Format('%d edges meet at point %d (branch)', [B.Deg[I], I]), I));
    end;
end;

function CheckCrossings(var AProfile: TCADSketchProfile; const SX, SY: array of TDoubles;
  const SN: array of Integer): Boolean;
var
  LA, LB, I, J, IN1, JN1, N: Integer;
begin
  Result := True;
  for LA := 0 to High(AProfile.Loops) do
    for LB := LA to High(AProfile.Loops) do
      for I := 0 to SN[LA] - 1 do
      begin
        IN1 := (I + 1) mod SN[LA];
        for J := 0 to SN[LB] - 1 do
        begin
          if LA = LB then
          begin
            { same loop: skip itself and neighbours }
            N := SN[LA];
            if (J <= I + 1) or ((I = 0) and (J = N - 1)) then
              Continue;
          end;
          JN1 := (J + 1) mod SN[LB];
          if SegmentsCross(SX[LA][I], SY[LA][I], SX[LA][IN1], SY[LA][IN1],
                           SX[LB][J], SY[LB][J], SX[LB][JN1], SY[LB][JN1]) then
          begin
            if LA = LB then
              Exit(Fail(AProfile, Format('loop %d crosses itself', [LA]), -1))
            else
              Exit(Fail(AProfile, Format('loops %d and %d cross', [LA, LB]), -1));
          end;
        end;
      end;
end;

procedure Nest(var AProfile: TCADSketchProfile; const SX, SY: array of TDoubles;
  const SN: array of Integer);
var
  I, J, NF, NH, K: Integer;
begin
  for I := 0 to High(AProfile.Loops) do
  begin
    AProfile.Loops[I].Depth := 0;
    AProfile.Loops[I].Parent := -1;
    for J := 0 to High(AProfile.Loops) do
      if (J <> I) and PointInPolygon(SX[I][0], SY[I][0], SX[J], SY[J], SN[J]) then
      begin
        Inc(AProfile.Loops[I].Depth);
        K := AProfile.Loops[I].Parent;
        if (K < 0) or (Abs(AProfile.Loops[J].Area) < Abs(AProfile.Loops[K].Area)) then
          AProfile.Loops[I].Parent := J;
      end;
  end;
  { orientation: outer CCW, hole CW }
  for I := 0 to High(AProfile.Loops) do
    if Odd(AProfile.Loops[I].Depth) = (AProfile.Loops[I].Area > 0) then
      ReverseLoop(AProfile.Loops[I]);
  NF := 0;
  SetLength(AProfile.Faces, Length(AProfile.Loops));
  for I := 0 to High(AProfile.Loops) do
    if not Odd(AProfile.Loops[I].Depth) then
    begin
      AProfile.Faces[NF].Outer := I;
      AProfile.Faces[NF].Area := AProfile.Loops[I].Area;
      NH := 0;
      SetLength(AProfile.Faces[NF].Holes, Length(AProfile.Loops));
      for J := 0 to High(AProfile.Loops) do
        if (AProfile.Loops[J].Parent = I) and Odd(AProfile.Loops[J].Depth) then
        begin
          AProfile.Faces[NF].Holes[NH] := J;
          AProfile.Faces[NF].Area := AProfile.Faces[NF].Area + AProfile.Loops[J].Area;
          Inc(NH);
        end;
      SetLength(AProfile.Faces[NF].Holes, NH);
      Inc(NF);
    end;
  SetLength(AProfile.Faces, NF);
end;

function CADBuildProfile(S: TCADSketch; out AProfile: TCADSketchProfile): Boolean;
var
  B: TBuilder;
  I, J: Integer;
  SX, SY: array of TDoubles;
  SN: array of Integer;
begin
  AProfile := Default(TCADSketchProfile);
  AProfile.ErrorPoint := -1;
  B := Default(TBuilder);
  B.S := S;
  SetLength(B.Root, S.PointCount);
  for I := 0 to S.PointCount - 1 do
    B.Root[I] := I;
  JoinPoints(B);
  if not CollectEdges(B, AProfile) then
    Exit(False);
  if not WalkLoops(B, AProfile) then
    Exit(False);
  if Length(AProfile.Loops) = 0 then
    Exit(Fail(AProfile, 'no profile geometry (only construction or nothing)', -1));
  SetLength(SX, Length(AProfile.Loops));
  SetLength(SY, Length(AProfile.Loops));
  SetLength(SN, Length(AProfile.Loops));
  for I := 0 to High(AProfile.Loops) do
  begin
    AProfile.Loops[I].Area := 0;
    for J := 0 to High(AProfile.Loops[I].Edges) do
      AProfile.Loops[I].Area := AProfile.Loops[I].Area + EdgeArea(AProfile.Loops[I].Edges[J]);
    SampleLoopRaw(AProfile.Loops[I], SX[I], SY[I], SN[I]);
    if Abs(AProfile.Loops[I].Area) < 1e-12 then
      Exit(Fail(AProfile, Format('loop %d has no area', [I]), -1));
  end;
  if not CheckCrossings(AProfile, SX, SY, SN) then
    Exit(False);
  Nest(AProfile, SX, SY, SN);
  Result := True;
end;

end.
