unit CAD.View.SketchDraw;
{$mode objfpc}{$H+}

{ ROLE:      viewport side of sketch editing without GL calls: screen pixel
             -> sketch coordinates (ray / plane), camera square to the sketch
             plane, and stroke meshes for the sketch, the editor preview, the
             snap marker and the origin cross.
  CALLED BY: CAD.App.SketchMode.
  CALLS:     CAD.Sketch.Model, CAD.Sketch.Editor, engine camera and
             TV3DMeshData (no GL).
  THREADS:   UI thread.
  SPEED:     meshes are rebuilt from scratch per change; a sketch has
             hundreds of strokes, arcs and circles are sampled every 5
             degrees (at least 12 segments). }

interface

uses
  SysUtils, Math, CAD.Sketch.Model, CAD.Sketch.Editor, CAD.Sketch.Commands,
  CAD.Sketch.Status, CAD.Sketch.DimGraphic,
  OpenGL.UI.Viewport3D.Camera, OpenGL.Render.Viewport3DMeshData;

{ Pixel (AX, AY: top-left origin) of a AWidth x AHeight viewport -> sketch
  coordinates on S's plane. False when the view ray is parallel to it. }
function CADScreenToSketch(ACamera: TViewport3DCamera; AWidth, AHeight: Double;
  AX, AY: Double; S: TCADSketch; out U, V: Double): Boolean;
{ Sketch point -> pixel of a AWidth x AHeight viewport (top-left origin).
  False when it is behind the camera. }
function CADSketchToScreen(ACamera: TViewport3DCamera; AWidth, AHeight: Double;
  S: TCADSketch; U, V: Double; out AX, AY: Double): Boolean;
{ Looks straight at the plane from the normal side, sketch X to the right
  where the camera allows it (its up axis is model Z). Keeps the distance. }
procedure CADCameraToSketch(ACamera: TViewport3DCamera; S: TCADSketch);
type
  { One viewport object per layer, each with its own edge colour. }
  TCADSketchLayer = (sklUnder, sklDefined, sklConflict, sklConstruction, sklHover, sklSelected);

{ Sketch entities as strokes (construction too). Edge id = entity + 1. }
procedure CADBuildSketchMesh(S: TCADSketch; AMesh: TV3DMeshData);
{ Entities and points split by layer: selection, then hover, then
  construction, then the state from the last solve (under-defined, defined,
  conflicting). Points are small squares of APointSize mm.
  AMeshes[Ord(layer)] are cleared and filled. }
procedure CADBuildSketchLayers(Ed: TCADSketchEditor; APointSize: Double;
  const AMeshes: array of TV3DMeshData);
{ Editor previews, the snap marker (square of AMarkerSize mm) and an origin
  cross of AOriginSize mm. }
procedure CADBuildEditorMesh(Ed: TCADSketchEditor; AMarkerSize, AOriginSize: Double;
  AMesh: TV3DMeshData);
{ Drafting dimensions of every active dimension (CAD.Sketch.DimGraphic):
  extension lines, dimension lines and arrows; AMMPerPixel = current zoom.
  AMesh is cleared and filled. }
procedure CADBuildDimensionMesh(S: TCADSketch; AMMPerPixel: Double; AMesh: TV3DMeshData);

implementation

{ The viewport takes its scene bounds (camera near / far) from surface
  vertices only. Stroke-only meshes get two vertices at the corners of their
  strokes' box and no triangles: nothing is drawn, but the clip range keeps
  the sketch inside it at every zoom. }
procedure AddBoundsVertices(AMesh: TV3DMeshData);
var
  I: Integer;
  V: TV3DStrokeVertex;
  Lo, Hi: TV3Vec;
begin
  if AMesh.StrokeCount = 0 then
    Exit;
  V := AMesh.Strokes[0];
  Lo := V3(V.PX, V.PY, V.PZ);
  Hi := Lo;
  for I := 1 to AMesh.StrokeCount - 1 do
  begin
    V := AMesh.Strokes[I];
    Lo := V3(Min(Lo.X, V.PX), Min(Lo.Y, V.PY), Min(Lo.Z, V.PZ));
    Hi := V3(Max(Hi.X, V.PX), Max(Hi.Y, V.PY), Max(Hi.Z, V.PZ));
  end;
  AMesh.AddVertex(Lo, V3(0, 0, 1), 0);
  AMesh.AddVertex(Hi, V3(0, 0, 1), 0);
end;

function P3(S: TCADSketch; U, V: Double): TV3Vec;
var
  X, Y, Z: Double;
begin
  S.ToModel(U, V, X, Y, Z);
  Result := V3(X, Y, Z);
end;

function PlaneVec(const A: array of Double): TV3Vec;
begin
  Result := V3(A[0], A[1], A[2]);
end;

function CADScreenToSketch(ACamera: TViewport3DCamera; AWidth, AHeight: Double;
  AX, AY: Double; S: TCADSketch; out U, V: Double): Boolean;
var
  NX, NY, Aspect, TanH, Den, T: Double;
  O, D, F, R, Up, N, PO, Hit: TV3Vec;
begin
  U := 0;
  V := 0;
  Result := False;
  if (AWidth <= 0) or (AHeight <= 0) then
    Exit;
  NX := 2 * AX / AWidth - 1;
  NY := 1 - 2 * AY / AHeight;
  Aspect := AWidth / AHeight;
  F := ACamera.ForwardDir;
  R := ACamera.RightDir;
  Up := ACamera.UpDir;
  if ACamera.Projection = vpPerspective then
  begin
    TanH := Tan(DegToRad(ACamera.FovYDeg) * 0.5);
    O := ACamera.Eye;
    D := V3Normalize(V3Add(F, V3Add(V3Scale(R, NX * TanH * Aspect), V3Scale(Up, NY * TanH))));
  end
  else
  begin
    O := V3Add(ACamera.Eye, V3Add(V3Scale(R, NX * 0.5 * ACamera.OrthoHeight * Aspect),
      V3Scale(Up, NY * 0.5 * ACamera.OrthoHeight)));
    D := F;
  end;
  N := PlaneVec(S.Plane.Normal);
  PO := PlaneVec(S.Plane.Origin);
  Den := V3Dot(D, N);
  if Abs(Den) < 1e-12 then
    Exit;
  T := V3Dot(V3Sub(PO, O), N) / Den;
  Hit := V3Sub(V3Add(O, V3Scale(D, T)), PO);
  U := V3Dot(Hit, PlaneVec(S.Plane.XDir));
  V := V3Dot(Hit, PlaneVec(S.Plane.YDir));
  Result := True;
end;

function CADSketchToScreen(ACamera: TViewport3DCamera; AWidth, AHeight: Double;
  S: TCADSketch; U, V: Double; out AX, AY: Double): Boolean;
var
  M, P: TV3Mat4;
  W: TV3Vec;
  VX, VY, VZ, VW, CX, CY, CW: Double;
begin
  AX := 0;
  AY := 0;
  Result := False;
  if (AWidth <= 0) or (AHeight <= 0) then
    Exit;
  W := P3(S, U, V);
  M := ACamera.ViewMatrix;                      { column-major: M[col * 4 + row] }
  P := ACamera.ProjectionMatrix(AWidth / AHeight);
  VX := M[0] * W.X + M[4] * W.Y + M[8] * W.Z + M[12];
  VY := M[1] * W.X + M[5] * W.Y + M[9] * W.Z + M[13];
  VZ := M[2] * W.X + M[6] * W.Y + M[10] * W.Z + M[14];
  VW := M[3] * W.X + M[7] * W.Y + M[11] * W.Z + M[15];
  CX := P[0] * VX + P[4] * VY + P[8] * VZ + P[12] * VW;
  CY := P[1] * VX + P[5] * VY + P[9] * VZ + P[13] * VW;
  CW := P[3] * VX + P[7] * VY + P[11] * VZ + P[15] * VW;
  if CW <= 1e-12 then
    Exit;
  AX := (CX / CW * 0.5 + 0.5) * AWidth;
  AY := (1 - (CY / CW * 0.5 + 0.5)) * AHeight;
  Result := True;
end;

procedure CADCameraToSketch(ACamera: TViewport3DCamera; S: TCADSketch);
var
  N, X: TV3Vec;
begin
  N := PlaneVec(S.Plane.Normal);
  X := PlaneVec(S.Plane.XDir);
  ACamera.Target := PlaneVec(S.Plane.Origin);
  ACamera.PitchDeg := RadToDeg(ArcSin(EnsureRange(N.Z, -1.0, 1.0)));
  if Abs(N.Z) > 0.99 then
  begin
    { looking along Z: camera right = (-sin yaw, cos yaw) * sign }
    if N.Z > 0 then
      ACamera.YawDeg := RadToDeg(ArcTan2(-X.X, X.Y))
    else
      ACamera.YawDeg := RadToDeg(ArcTan2(X.X, -X.Y));
  end
  else
    ACamera.YawDeg := RadToDeg(ArcTan2(N.Y, N.X));
end;

procedure AddArcStrokes(S: TCADSketch; AMesh: TV3DMeshData; CX, CY, R, A0, Sweep: Double;
  AClosed: Boolean; AEdgeId: Cardinal);
var
  N, I: Integer;
  Pts: array of TV3Vec;
begin
  if R <= 0 then
    Exit;
  N := Max(12, Ceil(Abs(Sweep) / DegToRad(5)));
  if AClosed then
    SetLength(Pts, N)
  else
    SetLength(Pts, N + 1);
  for I := 0 to High(Pts) do
    Pts[I] := P3(S, CX + R * Cos(A0 + Sweep * I / N), CY + R * Sin(A0 + Sweep * I / N));
  AMesh.AddPolylineEdge(Pts, AClosed, AEdgeId);
end;

function CCWSweep(A1, A2: Double): Double;
begin
  Result := A2 - A1;
  while Result <= 1e-12 do
    Result := Result + 2 * Pi;
end;

procedure CADBuildSketchMesh(S: TCADSketch; AMesh: TV3DMeshData);
var
  I: Integer;
  E: TCADSketchEntity;
  CX, CY, A1, A2: Double;
begin
  AMesh.Clear;
  for I := 0 to S.EntityCount - 1 do
  begin
    E := S.Entities[I];
    if not E.Active then Continue;
    case E.Kind of
      sekLine:
        AMesh.AddPolylineEdge([P3(S, S.PointX(E.P1), S.PointY(E.P1)),
          P3(S, S.PointX(E.P2), S.PointY(E.P2))], False, I + 1);
      sekCircle:
        AddArcStrokes(S, AMesh, S.PointX(E.Center), S.PointY(E.Center), S.EntityRadius(I),
          0, 2 * Pi, True, I + 1);
      sekArc:
        begin
          CX := S.PointX(E.Center);
          CY := S.PointY(E.Center);
          A1 := ArcTan2(S.PointY(E.P1) - CY, S.PointX(E.P1) - CX);
          A2 := ArcTan2(S.PointY(E.P2) - CY, S.PointX(E.P2) - CX);
          AddArcStrokes(S, AMesh, CX, CY, S.EntityRadius(I), A1, CCWSweep(A1, A2), False, I + 1);
        end;
    end;
  end;
  AddBoundsVertices(AMesh);
end;

procedure AddEntityStrokes(S: TCADSketch; AEntity: Integer; AMesh: TV3DMeshData);
var
  E: TCADSketchEntity;
  CX, CY, A1, A2: Double;
begin
  E := S.Entities[AEntity];
  if not E.Active then Exit;
  case E.Kind of
    sekLine:
      AMesh.AddPolylineEdge([P3(S, S.PointX(E.P1), S.PointY(E.P1)),
        P3(S, S.PointX(E.P2), S.PointY(E.P2))], False, AEntity + 1);
    sekCircle:
      AddArcStrokes(S, AMesh, S.PointX(E.Center), S.PointY(E.Center), S.EntityRadius(AEntity),
        0, 2 * Pi, True, AEntity + 1);
    sekArc:
      begin
        CX := S.PointX(E.Center);
        CY := S.PointY(E.Center);
        A1 := ArcTan2(S.PointY(E.P1) - CY, S.PointX(E.P1) - CX);
        A2 := ArcTan2(S.PointY(E.P2) - CY, S.PointX(E.P2) - CX);
        AddArcStrokes(S, AMesh, CX, CY, S.EntityRadius(AEntity), A1, CCWSweep(A1, A2), False, AEntity + 1);
      end;
  end;
end;

procedure CADBuildSketchLayers(Ed: TCADSketchEditor; APointSize: Double;
  const AMeshes: array of TV3DMeshData);
var
  S: TCADSketch;
  EStates, PStates: TCADElementStates;
  I: Integer;
  L: TCADSketchLayer;
  H, X, Y: Double;

  function StateLayer(AState: TCADElementState): TCADSketchLayer;
  begin
    case AState of
      cesDefined: Result := sklDefined;
      cesConflict: Result := sklConflict;
    else
      Result := sklUnder;
    end;
  end;

begin
  S := Ed.Sketch;
  for L := Low(TCADSketchLayer) to High(TCADSketchLayer) do
    AMeshes[Ord(L)].Clear;
  CADSketchStates(S, Ed.LastSolve, EStates, PStates);
  for I := 0 to S.EntityCount - 1 do
  begin
    if not S.Entities[I].Active then Continue;
    if Ed.IsSelected(chkEntity, I) then
      L := sklSelected
    else if (Ed.HoverKind = chkEntity) and (Ed.HoverIndex = I) then
      L := sklHover
    else if S.Entities[I].Construction then
      L := sklConstruction
    else
      L := StateLayer(EStates[I]);
    AddEntityStrokes(S, I, AMeshes[Ord(L)]);
  end;
  H := 0.5 * APointSize;
  for I := 0 to S.PointCount - 1 do
  begin
    if not S.Points[I].Active then Continue;
    if Ed.IsSelected(chkPoint, I) then
      L := sklSelected
    else if (Ed.HoverKind = chkPoint) and (Ed.HoverIndex = I) then
      L := sklHover
    else
      L := StateLayer(PStates[I]);
    X := S.PointX(I);
    Y := S.PointY(I);
    AMeshes[Ord(L)].AddPolylineEdge([P3(S, X - H, Y - H), P3(S, X + H, Y - H),
      P3(S, X + H, Y + H), P3(S, X - H, Y + H)], True, 100000 + I);
  end;
  for L := Low(TCADSketchLayer) to High(TCADSketchLayer) do
    AddBoundsVertices(AMeshes[Ord(L)]);
end;

procedure AddDiamond(S: TCADSketch; AMesh: TV3DMeshData; X, Y, H: Double);
begin
  AMesh.AddPolylineEdge([P3(S, X - H, Y), P3(S, X, Y - H), P3(S, X + H, Y), P3(S, X, Y + H)], True, 4);
end;

procedure CADBuildEditorMesh(Ed: TCADSketchEditor; AMarkerSize, AOriginSize: Double;
  AMesh: TV3DMeshData);
var
  S: TCADSketch;
  I: Integer;
  Pv: TCADSketchPreview;
  A1, A2, H, X, Y: Double;
begin
  S := Ed.Sketch;
  AMesh.Clear;
  { origin cross }
  AMesh.AddPolylineEdge([P3(S, -AOriginSize, 0), P3(S, AOriginSize, 0)], False, 1);
  AMesh.AddPolylineEdge([P3(S, 0, -AOriginSize), P3(S, 0, AOriginSize)], False, 1);
  for I := 0 to Ed.PreviewCount - 1 do
  begin
    Pv := Ed.Previews[I];
    case Pv.Kind of
      cpkLine:
        if Hypot(Pv.X2 - Pv.X1, Pv.Y2 - Pv.Y1) > 1e-9 then
          AMesh.AddPolylineEdge([P3(S, Pv.X1, Pv.Y1), P3(S, Pv.X2, Pv.Y2)], False, 2);
      cpkCircle:
        AddArcStrokes(S, AMesh, Pv.CX, Pv.CY, Pv.R, 0, 2 * Pi, True, 2);
      cpkArc:
        begin
          A1 := ArcTan2(Pv.Y1 - Pv.CY, Pv.X1 - Pv.CX);
          A2 := ArcTan2(Pv.Y2 - Pv.CY, Pv.X2 - Pv.CX);
          AddArcStrokes(S, AMesh, Pv.CX, Pv.CY, Pv.R, A1, CCWSweep(A1, A2), False, 2);
        end;
    end;
  end;
  if (Ed.Tool <> sktSelect) and (Ed.Snap.Kind <> snkNone) then
  begin
    H := 0.5 * AMarkerSize;
    X := Ed.Snap.X;
    Y := Ed.Snap.Y;
    AMesh.AddPolylineEdge([P3(S, X - H, Y - H), P3(S, X + H, Y - H), P3(S, X + H, Y + H),
      P3(S, X - H, Y + H)], True, 3);
  end;
  AddBoundsVertices(AMesh);
end;

procedure CADBuildDimensionMesh(S: TCADSketch; AMMPerPixel: Double; AMesh: TV3DMeshData);
var
  I, K: Integer;
  G: TCADDimGraphic;
begin
  AMesh.Clear;
  if S = nil then
    Exit;
  for I := 0 to S.ConstraintCount - 1 do
    if CADDimensionGraphic(S, I, AMMPerPixel, G) then
      for K := 0 to High(G.Segments) do
        AMesh.AddPolylineEdge([P3(S, G.Segments[K].X1, G.Segments[K].Y1),
          P3(S, G.Segments[K].X2, G.Segments[K].Y2)], False, Cardinal(I + 1));
  AddBoundsVertices(AMesh);
end;

end.
