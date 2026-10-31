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
  OpenGL.UI.Viewport3D.Camera, OpenGL.Render.Viewport3DMeshData;

{ Pixel (AX, AY: top-left origin) of a AWidth x AHeight viewport -> sketch
  coordinates on S's plane. False when the view ray is parallel to it. }
function CADScreenToSketch(ACamera: TViewport3DCamera; AWidth, AHeight: Double;
  AX, AY: Double; S: TCADSketch; out U, V: Double): Boolean;
{ Looks straight at the plane from the normal side, sketch X to the right
  where the camera allows it (its up axis is model Z). Keeps the distance. }
procedure CADCameraToSketch(ACamera: TViewport3DCamera; S: TCADSketch);
{ Sketch entities as strokes (construction too). Edge id = entity + 1. }
procedure CADBuildSketchMesh(S: TCADSketch; AMesh: TV3DMeshData);
{ Editor previews, the snap marker (square of AMarkerSize mm), selection
  markers (diamonds on selected points, line middles and circle centres) and
  an origin cross of AOriginSize mm. }
procedure CADBuildEditorMesh(Ed: TCADSketchEditor; AMarkerSize, AOriginSize: Double;
  AMesh: TV3DMeshData);

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
  E: TCADSketchEntity;
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
  { selection: diamonds }
  H := 0.6 * AMarkerSize;
  for I := 0 to High(Ed.Selection.Points) do
    AddDiamond(S, AMesh, S.PointX(Ed.Selection.Points[I]), S.PointY(Ed.Selection.Points[I]), H);
  for I := 0 to High(Ed.Selection.Entities) do
  begin
    E := S.Entities[Ed.Selection.Entities[I]];
    if E.Kind = sekLine then
      AddDiamond(S, AMesh, 0.5 * (S.PointX(E.P1) + S.PointX(E.P2)),
        0.5 * (S.PointY(E.P1) + S.PointY(E.P2)), H)
    else
      AddDiamond(S, AMesh, S.PointX(E.Center), S.PointY(E.Center), H);
  end;
  AddBoundsVertices(AMesh);
end;

end.
