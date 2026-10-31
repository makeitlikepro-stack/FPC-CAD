unit CAD.View.MeshConvert;
{$mode objfpc}{$H+}

{ ROLE:      copies an OCCT display mesh (flat float/uint arrays from the
             bridge) into the engine viewport mesh TV3DMeshData.
  CALLED BY: CAD.View.Sync (stage 4 step 2), tests/view.
  CALLS:     CAD.OCCT.Bridge (only in CADRawMeshFromOCCT),
             OpenGL.Render.Viewport3DMeshData (engine, no GL).
  THREADS:   any thread; the target mesh must not be drawn while it is filled
             (the viewport uploads it on the UI thread when Revision changes).
  SPEED:     one pass over the arrays, no per-vertex allocation. Edge segments
             (GL_LINES pairs from the bridge) are joined into polylines of the
             same edge id, so the stroke shader gets real joins, not caps.

  Ids: face and edge ids stay the OCCT map indices (1-based), so a viewport
  pick (Pick3DId.Element) maps straight back to the OCCT face or edge. }

interface

uses
  SysUtils, Math, CAD.OCCT.Bridge,
  OpenGL.UI.Viewport3D.Camera, OpenGL.Render.Viewport3DMeshData;

type
  { View on the bridge arrays. Positions/normals/edge positions: 3 floats per
    vertex. FaceIds: one per surface vertex. EdgeIds: one per edge vertex. }
  TCADRawMesh = record
    VertexCount: Integer;
    IndexCount: Integer;
    EdgeVertexCount: Integer;
    Positions: PSingle;
    Normals: PSingle;
    Indices: PLongWord;
    FaceIds: PLongWord;
    EdgePositions: PSingle;
    EdgeIds: PLongWord;
  end;

  TCADMeshConvertStats = record
    Vertices: Integer;
    Triangles: Integer;
    EdgeSegments: Integer;
    EdgePolylines: Integer;
    ClosedPolylines: Integer;
  end;

{ Clears ATarget and fills it. False + AError (ATarget left empty) when the
  arrays are inconsistent: nil data for a non-zero count, index out of range,
  index count not a multiple of 3, odd edge vertex count. }
function CADConvertRawMesh(const ARaw: TCADRawMesh; ATarget: TV3DMeshData;
  out AStats: TCADMeshConvertStats; out AError: string): Boolean;

{ Raw view on a bridge mesh handle. ASmooth: per-vertex surface normals
  (curved faces shade round); falls back to flat normals when missing. }
function CADRawMeshFromOCCT(AMesh: TOCCTMeshHandle; ASmooth: Boolean = True): TCADRawMesh;

implementation

type
  TSingleArr = array[0..MaxInt div SizeOf(Single) - 1] of Single;
  PSingleArr = ^TSingleArr;
  TLongWordArr = array[0..MaxInt div SizeOf(LongWord) - 1] of LongWord;
  PLongWordArr = ^TLongWordArr;

function Vec3At(P: PSingleArr; AIndex: Integer): TV3Vec;
begin
  Result := V3(P^[AIndex * 3], P^[AIndex * 3 + 1], P^[AIndex * 3 + 2]);
end;

function CheckRaw(const ARaw: TCADRawMesh; out AError: string): Boolean;
var
  I: Integer;
  Idx: PLongWordArr;
begin
  Result := False;
  if (ARaw.VertexCount < 0) or (ARaw.IndexCount < 0) or (ARaw.EdgeVertexCount < 0) then
    AError := 'negative count'
  else if (ARaw.IndexCount mod 3) <> 0 then
    AError := Format('index count %d is not a multiple of 3', [ARaw.IndexCount])
  else if (ARaw.EdgeVertexCount mod 2) <> 0 then
    AError := Format('edge vertex count %d is odd', [ARaw.EdgeVertexCount])
  else if (ARaw.VertexCount > 0) and ((ARaw.Positions = nil) or
    (ARaw.Normals = nil) or (ARaw.FaceIds = nil)) then
    AError := 'surface arrays missing'
  else if (ARaw.IndexCount > 0) and (ARaw.Indices = nil) then
    AError := 'index array missing'
  else if (ARaw.EdgeVertexCount > 0) and ((ARaw.EdgePositions = nil) or
    (ARaw.EdgeIds = nil)) then
    AError := 'edge arrays missing'
  else
  begin
    Idx := PLongWordArr(ARaw.Indices);
    for I := 0 to ARaw.IndexCount - 1 do
      if Idx^[I] >= LongWord(ARaw.VertexCount) then
      begin
        AError := Format('index %d = %d out of range (%d vertices)',
          [I, Idx^[I], ARaw.VertexCount]);
        Exit;
      end;
    AError := '';
    Result := True;
  end;
end;

{ Join tolerance: the bridge writes shared polygon nodes as the same floats,
  so this only absorbs rounding; 1e-7 of the edge extent, at least 1e-9. }
function EdgeTolerance(const ARaw: TCADRawMesh): Double;
var
  I: Integer;
  P: PSingleArr;
  Lo, Hi: array[0..2] of Double;
  K: Integer;
  V, Extent: Double;
begin
  P := PSingleArr(ARaw.EdgePositions);
  for K := 0 to 2 do
  begin
    Lo[K] := P^[K];
    Hi[K] := P^[K];
  end;
  for I := 1 to ARaw.EdgeVertexCount - 1 do
    for K := 0 to 2 do
    begin
      V := P^[I * 3 + K];
      if V < Lo[K] then Lo[K] := V;
      if V > Hi[K] then Hi[K] := V;
    end;
  Extent := 0;
  for K := 0 to 2 do
    if Hi[K] - Lo[K] > Extent then
      Extent := Hi[K] - Lo[K];
  Result := 1e-7 * Extent;
  if Result < 1e-9 then
    Result := 1e-9;
end;

function SamePoint(const A, B: TV3Vec; ATol: Double): Boolean;
begin
  Result := (Abs(A.X - B.X) <= ATol) and (Abs(A.Y - B.Y) <= ATol) and
    (Abs(A.Z - B.Z) <= ATol);
end;

procedure ConvertEdges(const ARaw: TCADRawMesh; ATarget: TV3DMeshData;
  var AStats: TCADMeshConvertStats);
var
  P: PSingleArr;
  Ids: PLongWordArr;
  Line: array of TV3Vec;
  N, S, SegCount: Integer;
  Id: LongWord;
  Tol: Double;
  A, B: TV3Vec;

  procedure Push(const V: TV3Vec);
  begin
    if N >= Length(Line) then
      SetLength(Line, Max(16, Length(Line) * 2));
    Line[N] := V;
    Inc(N);
  end;

  procedure Flush;
  var
    Closed: Boolean;
  begin
    if N >= 2 then
    begin
      { A loop comes back to its first point: drop the repeat, mark closed. }
      Closed := (N >= 4) and SamePoint(Line[0], Line[N - 1], Tol);
      if Closed then
      begin
        Dec(N);
        Inc(AStats.ClosedPolylines);
      end;
      ATarget.AddPolylineEdge(Copy(Line, 0, N), Closed, Id);
      Inc(AStats.EdgePolylines);
    end;
    N := 0;
  end;

begin
  SegCount := ARaw.EdgeVertexCount div 2;
  if SegCount = 0 then
    Exit;
  P := PSingleArr(ARaw.EdgePositions);
  Ids := PLongWordArr(ARaw.EdgeIds);
  Tol := EdgeTolerance(ARaw);
  N := 0;
  Id := 0;
  for S := 0 to SegCount - 1 do
  begin
    A := Vec3At(P, S * 2);
    B := Vec3At(P, S * 2 + 1);
    if SamePoint(A, B, Tol) then
      Continue;                      { zero length: no stroke }
    Inc(AStats.EdgeSegments);
    if (N > 0) and ((Ids^[S * 2] <> Id) or not SamePoint(Line[N - 1], A, Tol)) then
      Flush;
    if N = 0 then
    begin
      Id := Ids^[S * 2];
      Push(A);
    end;
    Push(B);
  end;
  Flush;
end;

function CADConvertRawMesh(const ARaw: TCADRawMesh; ATarget: TV3DMeshData;
  out AStats: TCADMeshConvertStats; out AError: string): Boolean;
var
  I: Integer;
  Pos, Nrm: PSingleArr;
  Faces, Idx: PLongWordArr;
begin
  AStats := Default(TCADMeshConvertStats);
  ATarget.Clear;
  Result := CheckRaw(ARaw, AError);
  if not Result then
    Exit;
  Pos := PSingleArr(ARaw.Positions);
  Nrm := PSingleArr(ARaw.Normals);
  Faces := PLongWordArr(ARaw.FaceIds);
  Idx := PLongWordArr(ARaw.Indices);
  for I := 0 to ARaw.VertexCount - 1 do
    ATarget.AddVertex(Vec3At(Pos, I), Vec3At(Nrm, I), Faces^[I]);
  I := 0;
  while I < ARaw.IndexCount do
  begin
    ATarget.AddTriangle(Idx^[I], Idx^[I + 1], Idx^[I + 2]);
    Inc(I, 3);
  end;
  AStats.Vertices := ARaw.VertexCount;
  AStats.Triangles := ARaw.IndexCount div 3;
  ConvertEdges(ARaw, ATarget, AStats);
end;

function CADRawMeshFromOCCT(AMesh: TOCCTMeshHandle; ASmooth: Boolean): TCADRawMesh;
begin
  Result := Default(TCADRawMesh);
  if AMesh = nil then
    Exit;
  Result.VertexCount := OCCT.MeshVertexCount(AMesh);
  Result.IndexCount := OCCT.MeshIndexCount(AMesh);
  Result.EdgeVertexCount := OCCT.MeshEdgeVertexCount(AMesh);
  Result.Positions := OCCT.MeshPositions(AMesh);
  Result.Normals := nil;
  if ASmooth then
    Result.Normals := OCCT.MeshSmoothNormals(AMesh);
  if Result.Normals = nil then
    Result.Normals := OCCT.MeshNormals(AMesh);
  Result.Indices := OCCT.MeshIndices(AMesh);
  Result.FaceIds := OCCT.MeshFaceIds(AMesh);
  Result.EdgePositions := OCCT.MeshEdgePositions(AMesh);
  Result.EdgeIds := OCCT.MeshEdgeIds(AMesh);
end;

end.
