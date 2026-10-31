unit CAD.Sketch.Regions;
{$mode objfpc}{$H+}

{ ROLE: Non-destructive 2D planar-region extraction from intersecting sketch
  lines, arcs and circles. Original sketch points, entities and constraints
  remain untouched. Splits are virtual and returned as exact profile edges
  (including circular arcs), suitable for OCCT planar-face construction.
  Open/dangling edges do not prevent bounded regions from being found.
  Overlapping/coincident curves remain an explicit unsupported case. }

interface

uses
  SysUtils, Math, CAD.Sketch.Model, CAD.Sketch.Profile,
  CAD.Sketch.CurveTrim;

{ Finds bounded faces formed by intersections, without calling RemoveEntity
  or changing the sketch. Profiles use exact line/arc edge geometry.
  Out AProfile.Faces are independently selectable closed planar regions. }
function CADBuildRegions(S: TCADSketch; out AProfile: TCADSketchProfile): Boolean;

{ Returns a face index, -1 when outside all faces or inside an empty hole.
  This is for a click in blank sketch space, not a stroke/vertex hit. }
function CADPickRegion(const AProfile: TCADSketchProfile; X, Y: Double): Integer;

{ Returns the selected subset of faces, preserving loop data; references
  remain valid for CADProfileArrays -> OCCT.MakePlanarFaces. }
function CADRegionProfileSubset(const AProfile: TCADSketchProfile;
  const AFaceIndices: array of Integer): TCADSketchProfile;

implementation

const
  ParamTol = 1e-8;
  TinyArea = 1e-10;

type
  TNode = record
    X, Y: Double;
  end;
  TNodeArray = array of TNode;
  TSplit = record
    T: Double;
    Node: Integer;
  end;
  TSplitList = array of TSplit;
  TSplitLists = array of TSplitList;
  THalfEdge = record
    A, B, Twin, Next: Integer;
    Angle: Double;               { outgoing tangent at A, radians }
    Curve: TCADProfileEdge;
    Visited: Boolean;
  end;
  THalfEdges = array of THalfEdge;

function WrapAngle(A: Double): Double;
begin
  Result := A;
  while Result < 0 do Result := Result + 2 * Pi;
  while Result >= 2 * Pi do Result := Result - 2 * Pi;
end;

function Sweep(A, B: Double): Double;
begin
  Result := WrapAngle(B-A);
  if Result <= 1e-12 then Result := 2 * Pi;
end;

procedure SketchPointAt(S: TCADSketch; I: Integer; T: Double;
  out X, Y: Double);
var
  E: TCADSketchEntity;
  CX, CY, R, A0, A1, A: Double;
begin
  E := S.Entities[I];
  if E.Kind = sekLine then
  begin
    X := S.PointX(E.P1) + T * (S.PointX(E.P2)-S.PointX(E.P1));
    Y := S.PointY(E.P1) + T * (S.PointY(E.P2)-S.PointY(E.P1));
    Exit;
  end;
  CX := S.PointX(E.Center);
  CY := S.PointY(E.Center);
  R := S.EntityRadius(I);
  if E.Kind = sekCircle then
    A := 2*Pi*T
  else
  begin
    A0 := ArcTan2(S.PointY(E.P1)-CY, S.PointX(E.P1)-CX);
    A1 := ArcTan2(S.PointY(E.P2)-CY, S.PointX(E.P2)-CX);
    A := A0 + T*Sweep(A0,A1);
  end;
  X := CX+R*Cos(A);
  Y := CY+R*Sin(A);
end;

function SketchParameter(S: TCADSketch; I: Integer; X, Y: Double): Double;
var
  E: TCADSketchEntity;
  DX, DY, L2, A0, A1, AP, CX, CY: Double;
begin
  E := S.Entities[I];
  if E.Kind = sekLine then
  begin
    DX := S.PointX(E.P2)-S.PointX(E.P1);
    DY := S.PointY(E.P2)-S.PointY(E.P1);
    L2 := Sqr(DX)+Sqr(DY);
    if L2 <= 1e-20 then Exit(0);
    Exit(EnsureRange(((X-S.PointX(E.P1))*DX +
      (Y-S.PointY(E.P1))*DY)/L2, 0.0, 1.0));
  end;
  CX := S.PointX(E.Center);
  CY := S.PointY(E.Center);
  AP := ArcTan2(Y-CY,X-CX);
  if E.Kind = sekCircle then
    Exit(WrapAngle(AP)/(2*Pi));
  A0 := ArcTan2(S.PointY(E.P1)-CY,S.PointX(E.P1)-CX);
  A1 := ArcTan2(S.PointY(E.P2)-CY,S.PointX(E.P2)-CX);
  Result := EnsureRange(WrapAngle(AP-A0)/Sweep(A0,A1),0.0,1.0);
end;

function LineOverlap(S: TCADSketch; A, B: Integer): Boolean;
var
  EA, EB: TCADSketchEntity;
  AX, AY, DX, DY, BX, BY, EX, EY, L, T1, T2: Double;
begin
  Result := False;
  EA := S.Entities[A]; EB := S.Entities[B];
  if (EA.Kind <> sekLine) or (EB.Kind <> sekLine) then Exit;
  AX := S.PointX(EA.P1); AY := S.PointY(EA.P1);
  BX := S.PointX(EB.P1); BY := S.PointY(EB.P1);
  DX := S.PointX(EA.P2)-AX; DY := S.PointY(EA.P2)-AY;
  EX := S.PointX(EB.P2)-BX; EY := S.PointY(EB.P2)-BY;
  L := Hypot(DX,DY);
  if L <= 1e-12 then Exit;
  if Abs(DX*EY-DY*EX) > 1e-9*Max(1.0,L*Hypot(EX,EY)) then Exit;
  if Abs(DX*(BY-AY)-DY*(BX-AX)) > 1e-9*Max(1.0,L) then Exit;
  { Collinear overlap beyond a single shared endpoint. }
  T1:=(DX*(BX-AX)+DY*(BY-AY))/Sqr(L);
  T2:=(DX*(BX+EX-AX)+DY*(BY+EY-AY))/Sqr(L);
  Result:=Max(0.0,Min(T1,T2)) < Min(1.0,Max(T1,T2))-ParamTol;
end;

function CoincidentCurves(S: TCADSketch; A, B: Integer): Boolean;
var
  E1,E2:TCADSketchEntity;
  CX,CY,DX,DY,R1,R2:Double;
begin
  Result:=False;
  E1:=S.Entities[A]; E2:=S.Entities[B];
  if (E1.Kind=sekLine) or (E2.Kind=sekLine) then Exit;
  CX:=S.PointX(E1.Center); CY:=S.PointY(E1.Center);
  DX:=S.PointX(E2.Center); DY:=S.PointY(E2.Center);
  R1:=S.EntityRadius(A); R2:=S.EntityRadius(B);
  { Conservative: any same-support circle/arc pair requires explicit
    coincident-edge handling before we can guarantee correct contours. }
  Result:=(Hypot(CX-DX,CY-DY)<=1e-7) and (Abs(R1-R2)<=1e-7);
end;

function ArcEdgeArea(const E: TCADProfileEdge): Double;
var
  A0,A1,T:Double;
begin
  if E.Kind=pekLine then
    Exit(0.5*(E.X1*E.Y2-E.X2*E.Y1));
  A0:=ArcTan2(E.Y1-E.CY,E.X1-E.CX);
  A1:=ArcTan2(E.Y2-E.CY,E.X2-E.CX);
  if E.CCW then T:=Sweep(A0,A1) else T:=Sweep(A1,A0);
  Result:=0.5*(E.X1*E.Y2-E.X2*E.Y1)+
          0.5*Sqr(E.R)*(T-Sin(T));
  if not E.CCW then
    Result:=0.5*(E.X1*E.Y2-E.X2*E.Y1)-
            0.5*Sqr(E.R)*(T-Sin(T));
end;

function OutgoingAngle(const E: TCADProfileEdge): Double;
var
  A:Double;
begin
  if E.Kind=pekLine then
    Exit(WrapAngle(ArcTan2(E.Y2-E.Y1,E.X2-E.X1)));
  A:=ArcTan2(E.Y1-E.CY,E.X1-E.CX);
  if E.CCW then Result:=WrapAngle(A+Pi/2)
  else Result:=WrapAngle(A-Pi/2);
end;

function ReverseEdge(const E:TCADProfileEdge):TCADProfileEdge;
begin
  Result:=E;
  Result.X1:=E.X2; Result.Y1:=E.Y2;
  Result.X2:=E.X1; Result.Y2:=E.Y1;
  Result.CCW:=not E.CCW;
end;

function CADBuildRegions(S: TCADSketch; out AProfile: TCADSketchProfile): Boolean;
var
  Nodes:TNodeArray;
  Splits:TSplitLists;
  Halves:THalfEdges;
  I,J,K,T,N,NodeA,NodeB,HalfCount,StartH,CurrentH,NWalk:Integer;
  X,Y,U,V,NodeTol,Area,Delta,BestDelta,Scale:Double;
  IP:TCADCurveIntersections;
  IX,Ind,Tmp,KeepCount,LoopIndex,FaceCount,HoleCount,Parent:Integer;
  IDs:array of Integer;
  HasChanged:Boolean;
  Cycle:TCADProfileLoop;
  PosLoop:array of Integer;
  LeftPX,LeftPY,MinArea:Double;
  ExteriorSample:array of TNode;
  NewEdge:TCADProfileEdge;
  TempSplit:TSplit;

  function NodeFor(AX,AY:Double):Integer;
  var Q:Integer;
  begin
    for Q:=0 to High(Nodes) do
      if Hypot(Nodes[Q].X-AX,Nodes[Q].Y-AY)<=NodeTol then Exit(Q);
    Result:=Length(Nodes);
    SetLength(Nodes,Result+1);
    Nodes[Result].X:=AX;
    Nodes[Result].Y:=AY;
  end;

  procedure SplitAt(AEntity:Integer; AT:Double);
  var Q,Idx:Integer;
      PX,PY:Double;
  begin
    AT:=EnsureRange(AT,0.0,1.0);
    SketchPointAt(S,AEntity,AT,PX,PY);
    Idx:=NodeFor(PX,PY);
    for Q:=0 to High(Splits[AEntity]) do
      if Abs(Splits[AEntity][Q].T-AT)<=ParamTol then Exit;
    Q:=Length(Splits[AEntity]);
    SetLength(Splits[AEntity],Q+1);
    Splits[AEntity][Q].T:=AT;
    Splits[AEntity][Q].Node:=Idx;
  end;

  procedure AddPart(AEntity,A,B:Integer; P0,P1:Double);
  var E:TCADSketchEntity;
      F:TCADProfileEdge;
      Q:Integer;
  begin
    if (A=B) or (P1-P0<=ParamTol) then Exit;
    E:=S.Entities[AEntity];
    F:=Default(TCADProfileEdge);
    F.Entity:=AEntity;
    if E.Kind=sekLine then F.Kind:=pekLine else F.Kind:=pekArc;
    F.X1:=Nodes[A].X; F.Y1:=Nodes[A].Y;
    F.X2:=Nodes[B].X; F.Y2:=Nodes[B].Y;
    F.CCW:=True;
    if E.Kind<>sekLine then
    begin
      F.CX:=S.PointX(E.Center);
      F.CY:=S.PointY(E.Center);
      F.R:=S.EntityRadius(AEntity);
    end;
    Q:=Length(Halves);
    SetLength(Halves,Q+2);
    Halves[Q].A:=A;
    Halves[Q].B:=B;
    Halves[Q].Twin:=Q+1;
    Halves[Q].Next:=-1;
    Halves[Q].Curve:=F;
    Halves[Q].Angle:=OutgoingAngle(F);
    Halves[Q].Visited:=False;
    Halves[Q+1].A:=B;
    Halves[Q+1].B:=A;
    Halves[Q+1].Twin:=Q;
    Halves[Q+1].Next:=-1;
    Halves[Q+1].Curve:=ReverseEdge(F);
    Halves[Q+1].Angle:=OutgoingAngle(Halves[Q+1].Curve);
    Halves[Q+1].Visited:=False;
  end;

  function InBoundary(ALoop:Integer; PX,PY:Double):Boolean;
  var XX,YY:TCADDoubleArray;
      M,Z,L:Integer;
  begin
    Result:=False;
    CADSampleLoop(AProfile.Loops[ALoop],XX,YY,M);
    if M<3 then Exit;
    L:=M-1;
    for Z:=0 to M-1 do
    begin
      if ((YY[Z]>PY)<>(YY[L]>PY)) and
         (PX<(XX[L]-XX[Z])*(PY-YY[Z])/(YY[L]-YY[Z])+XX[Z]) then
        Result:=not Result;
      L:=Z;
    end;
  end;

  procedure LeftSample(const E:TCADProfileEdge; out PX,PY:Double);
  var DX,DY,Len,Angle0,Angle1,AngleM,R:Double;
  begin
    if E.Kind=pekLine then
    begin
      PX:=(E.X1+E.X2)*0.5;
      PY:=(E.Y1+E.Y2)*0.5;
      DX:=E.X2-E.X1;
      DY:=E.Y2-E.Y1;
    end
    else
    begin
      Angle0:=ArcTan2(E.Y1-E.CY,E.X1-E.CX);
      Angle1:=ArcTan2(E.Y2-E.CY,E.X2-E.CX);
      if E.CCW then AngleM:=Angle0+Sweep(Angle0,Angle1)*0.5
      else AngleM:=Angle0-Sweep(Angle1,Angle0)*0.5;
      R:=E.R;
      PX:=E.CX+R*Cos(AngleM);
      PY:=E.CY+R*Sin(AngleM);
      if E.CCW then
      begin
        DX:=-Sin(AngleM); DY:=Cos(AngleM);
      end
      else
      begin
        DX:=Sin(AngleM); DY:=-Cos(AngleM);
      end;
    end;
    Len:=Hypot(DX,DY);
    if Len<=1e-12 then Exit;
    { Samples should be inside the actual bounded face, not exactly on the
      rim, where point-in-polygon parity becomes ambiguous. }
    PX:=PX-DY/Len*Max(NodeTol*10,Scale*0.001);
    PY:=PY+DX/Len*Max(NodeTol*10,Scale*0.001);
  end;

begin
  AProfile:=Default(TCADSketchProfile);
  AProfile.ErrorPoint:=-1;
  Result:=False;
  if S=nil then
  begin
    AProfile.Error:='nil sketch';
    Exit;
  end;
  Scale:=1;
  for I:=0 to S.PointCount-1 do
    if S.Points[I].Active then
      Scale:=Max(Scale,Max(Abs(S.PointX(I)),Abs(S.PointY(I))));
  NodeTol:=Max(1e-8,Scale*1e-9);
  SetLength(Splits,S.EntityCount);
  for I:=0 to S.EntityCount-1 do
  begin
    if not S.Entities[I].Active or S.Entities[I].Construction then Continue;
    SplitAt(I,0);
    SplitAt(I,1);
    if S.Entities[I].Kind=sekCircle then SplitAt(I,0.5);
    for J:=0 to I-1 do
    begin
      if not S.Entities[J].Active or S.Entities[J].Construction then Continue;
      if LineOverlap(S,I,J) or CoincidentCurves(S,I,J) then
      begin
        AProfile.Error:='overlapping sketch geometry is not supported for regions';
        Exit;
      end;
      N:=CADSketchIntersections(S,I,J,IP);
      for K:=0 to N-1 do
      begin
        SplitAt(I,SketchParameter(S,I,IP[K].X,IP[K].Y));
        SplitAt(J,SketchParameter(S,J,IP[K].X,IP[K].Y));
      end;
    end;
  end;
  { Sort each entity's virtual vertices along its parameter. }
  for I:=0 to S.EntityCount-1 do
  begin
    for J:=1 to High(Splits[I]) do
    begin
      T:=J;
      while (T>0) and (Splits[I][T-1].T>Splits[I][T].T) do
      begin
        TempSplit:=Splits[I][T-1];
        Splits[I][T-1]:=Splits[I][T];
        Splits[I][T]:=TempSplit;
        Dec(T);
      end;
    end;
    for J:=1 to High(Splits[I]) do
      AddPart(I,Splits[I][J-1].Node,Splits[I][J].Node,
        Splits[I][J-1].T,Splits[I][J].T);
  end;

  HalfCount:=Length(Halves);
  { The next edge around the LEFT face is the first outgoing edge
    clockwise from the incoming edge's twin at the destination node. }
  for I:=0 to HalfCount-1 do
  begin
    BestDelta:=1e100;
    Halves[I].Next:=Halves[I].Twin;
    for J:=0 to HalfCount-1 do
      if Halves[J].A=Halves[I].B then
      begin
        Delta:=WrapAngle(Halves[Halves[I].Twin].Angle-Halves[J].Angle);
        if J=Halves[I].Twin then Delta:=2*Pi;
        if Delta<BestDelta then
        begin
          BestDelta:=Delta;
          Halves[I].Next:=J;
        end;
      end;
  end;

  { Walk closed left-face boundaries. An open spur traces an edge and its
    twin consecutively; remove that zero-area backtrack from the contour. }
  for I:=0 to HalfCount-1 do
  begin
    if Halves[I].Visited then Continue;
    SetLength(IDs,0);
    CurrentH:=I;
    NWalk:=0;
    repeat
      if Halves[CurrentH].Visited then Break;
      Halves[CurrentH].Visited:=True;
      J:=Length(IDs);
      SetLength(IDs,J+1);
      IDs[J]:=CurrentH;
      CurrentH:=Halves[CurrentH].Next;
      Inc(NWalk);
    until (CurrentH=I) or (NWalk>HalfCount);
    if CurrentH<>I then Continue;
    HasChanged:=True;
    while HasChanged and (Length(IDs)>=2) do
    begin
      HasChanged:=False;
      for J:=0 to High(IDs) do
      begin
        K:=(J+1) mod Length(IDs);
        if Halves[IDs[J]].Twin=IDs[K] then
        begin
          if K=0 then
          begin
            for T:=0 to Length(IDs)-2 do IDs[T]:=IDs[T+1];
            SetLength(IDs,Length(IDs)-1);
            SetLength(IDs,Length(IDs)-1);
          end
          else
          begin
            for T:=K+1 to High(IDs) do IDs[T-2]:=IDs[T];
            SetLength(IDs,Length(IDs)-2);
          end;
          HasChanged:=True;
          Break;
        end;
      end;
    end;
    if Length(IDs)<2 then Continue;
    Cycle:=Default(TCADProfileLoop);
    SetLength(Cycle.Edges,Length(IDs));
    Area:=0;
    for J:=0 to High(IDs) do
    begin
      NewEdge:=Halves[IDs[J]].Curve;
      Cycle.Edges[J]:=NewEdge;
      Area:=Area+ArcEdgeArea(NewEdge);
    end;
    if Abs(Area)<TinyArea then Continue;
    Cycle.Area:=Area;
    Cycle.Parent:=-1;
    J:=Length(AProfile.Loops);
    SetLength(AProfile.Loops,J+1);
    AProfile.Loops[J]:=Cycle;
  end;

  { Each CCW boundary encloses one bounded planar face. A CW boundary
    is either the outside face or a hole inside another bounded face. }
  FaceCount:=0;
  for I:=0 to High(AProfile.Loops) do
    if AProfile.Loops[I].Area>TinyArea then
    begin
      SetLength(AProfile.Faces,FaceCount+1);
      AProfile.Faces[FaceCount].Outer:=I;
      AProfile.Faces[FaceCount].Area:=AProfile.Loops[I].Area;
      Inc(FaceCount);
    end;
  for I:=0 to High(AProfile.Loops) do
  begin
    if AProfile.Loops[I].Area>=-TinyArea then Continue;
    LeftSample(AProfile.Loops[I].Edges[0],LeftPX,LeftPY);
    Parent:=-1;
    MinArea:=1e100;
    for J:=0 to High(AProfile.Faces) do
    begin
      K:=AProfile.Faces[J].Outer;
      if (AProfile.Loops[K].Area<Abs(AProfile.Loops[I].Area)+TinyArea) then Continue;
      if (AProfile.Loops[K].Area<MinArea) and InBoundary(K,LeftPX,LeftPY) then
      begin
        Parent:=J;
        MinArea:=AProfile.Loops[K].Area;
      end;
    end;
    if Parent>=0 then
    begin
      HoleCount:=Length(AProfile.Faces[Parent].Holes);
      SetLength(AProfile.Faces[Parent].Holes,HoleCount+1);
      AProfile.Faces[Parent].Holes[HoleCount]:=I;
      AProfile.Faces[Parent].Area:=AProfile.Faces[Parent].Area +
        AProfile.Loops[I].Area;
      AProfile.Loops[I].Parent:=AProfile.Faces[Parent].Outer;
    end;
  end;
  Result:=Length(AProfile.Faces)>0;
  if not Result then AProfile.Error:='no bounded sketch regions';
end;

function CADPickRegion(const AProfile: TCADSketchProfile; X, Y: Double): Integer;
var
  I,J,H,L,Count,K:Integer;
  XX,YY:TCADDoubleArray;
  Inside:Boolean;
  Best:Double;

  function Contains(ALoop:Integer):Boolean;
  var Q,Prev:Integer;
  begin
    Result:=False;
    CADSampleLoop(AProfile.Loops[ALoop],XX,YY,Count);
    if Count<3 then Exit;
    Prev:=Count-1;
    for Q:=0 to Count-1 do
    begin
      if ((YY[Q]>Y)<>(YY[Prev]>Y)) and
         (X<(XX[Prev]-XX[Q])*(Y-YY[Q])/(YY[Prev]-YY[Q])+XX[Q]) then
        Result:=not Result;
      Prev:=Q;
    end;
  end;

begin
  Result:=-1;
  Best:=1e100;
  for I:=0 to High(AProfile.Faces) do
  begin
    L:=AProfile.Faces[I].Outer;
    if AProfile.Faces[I].Area>=Best then Continue;
    if not Contains(L) then Continue;
    Inside:=True;
    for J:=0 to High(AProfile.Faces[I].Holes) do
      if Contains(AProfile.Faces[I].Holes[J]) then
      begin
        Inside:=False; Break;
      end;
    if Inside then
    begin
      Best:=AProfile.Faces[I].Area;
      Result:=I;
    end;
  end;
end;

function CADRegionProfileSubset(const AProfile: TCADSketchProfile;
  const AFaceIndices: array of Integer): TCADSketchProfile;
var
  I,N,J:Integer;
  Duplicate:Boolean;
begin
  Result:=Default(TCADSketchProfile);
  Result.Loops:=Copy(AProfile.Loops,0,Length(AProfile.Loops));
  for I:=Low(AFaceIndices) to High(AFaceIndices) do
  begin
    J:=AFaceIndices[I];
    if (J<0) or (J>=Length(AProfile.Faces)) then Continue;
    Duplicate:=False;
    for N:=0 to High(Result.Faces) do
      if Result.Faces[N].Outer=AProfile.Faces[J].Outer then
        Duplicate:=True;
    if Duplicate then Continue;
    N:=Length(Result.Faces);
    SetLength(Result.Faces,N+1);
    Result.Faces[N]:=AProfile.Faces[J];
  end;
end;

end.
