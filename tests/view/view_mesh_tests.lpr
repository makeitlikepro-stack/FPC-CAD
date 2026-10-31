program view_mesh_tests;
{$mode objfpc}{$H+}

{ Tests of CAD.View.MeshConvert (OCCT mesh -> engine TV3DMeshData).
  Run: bash scripts/test_view.sh
  1. Pure (no OCCT, no GL): surface copy, ids, edge joining (open, closed,
     id change, gap, zero length), error cases, speed (INFO).
  2. OCCT (when the bridge loads): box and cylinder meshes convert with the
     bridge counts, 1-based face ids, bounds, one polyline per box edge,
     closed circles on the cylinder. }

uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils, Math, CAD.Config.Performance, CAD.OCCT.Bridge, CAD.View.MeshConvert,
  OpenGL.UI.Viewport3D.Camera, OpenGL.Render.Viewport3DMeshData;

var
  Checks, Failures: Integer;

procedure Check(ACondition: Boolean; const AName: string);
begin
  Inc(Checks);
  if not ACondition then
  begin
    Inc(Failures);
    WriteLn('FAIL  ', AName);
  end;
end;

{ ---- small builders for raw arrays ---- }

var
  GPos, GNrm, GEdgePos: array of Single;
  GIdx, GFace, GEdgeIds: array of LongWord;

procedure ResetRaw;
begin
  GPos := nil; GNrm := nil; GEdgePos := nil;
  GIdx := nil; GFace := nil; GEdgeIds := nil;
end;

procedure AddV(X, Y, Z: Single; AFace: LongWord);
var
  N: Integer;
begin
  N := Length(GFace);
  SetLength(GPos, (N + 1) * 3);
  SetLength(GNrm, (N + 1) * 3);
  SetLength(GFace, N + 1);
  GPos[N * 3] := X; GPos[N * 3 + 1] := Y; GPos[N * 3 + 2] := Z;
  GNrm[N * 3] := 0; GNrm[N * 3 + 1] := 0; GNrm[N * 3 + 2] := 1;
  GFace[N] := AFace;
end;

procedure AddTri(A, B, C: LongWord);
var
  N: Integer;
begin
  N := Length(GIdx);
  SetLength(GIdx, N + 3);
  GIdx[N] := A; GIdx[N + 1] := B; GIdx[N + 2] := C;
end;

procedure AddSeg(X0, Y0, Z0, X1, Y1, Z1: Single; AId: LongWord);
var
  N: Integer;
begin
  N := Length(GEdgeIds);
  SetLength(GEdgePos, (N + 2) * 3);
  SetLength(GEdgeIds, N + 2);
  GEdgePos[N * 3] := X0; GEdgePos[N * 3 + 1] := Y0; GEdgePos[N * 3 + 2] := Z0;
  GEdgePos[N * 3 + 3] := X1; GEdgePos[N * 3 + 4] := Y1; GEdgePos[N * 3 + 5] := Z1;
  GEdgeIds[N] := AId;
  GEdgeIds[N + 1] := AId;
end;

function Raw: TCADRawMesh;
begin
  Result := Default(TCADRawMesh);
  Result.VertexCount := Length(GFace);
  Result.IndexCount := Length(GIdx);
  Result.EdgeVertexCount := Length(GEdgeIds);
  if Length(GPos) > 0 then Result.Positions := @GPos[0];
  if Length(GNrm) > 0 then Result.Normals := @GNrm[0];
  if Length(GFace) > 0 then Result.FaceIds := @GFace[0];
  if Length(GIdx) > 0 then Result.Indices := @GIdx[0];
  if Length(GEdgePos) > 0 then Result.EdgePositions := @GEdgePos[0];
  if Length(GEdgeIds) > 0 then Result.EdgeIds := @GEdgeIds[0];
end;

{ ---- pure tests ---- }

procedure TestSurface;
var
  M: TV3DMeshData;
  S: TCADMeshConvertStats;
  E: string;
  Lo, Hi: TV3Vec;
begin
  ResetRaw;
  AddV(0, 0, 0, 1); AddV(10, 0, 0, 1); AddV(10, 5, 0, 1);
  AddV(0, 0, 0, 2); AddV(10, 5, 0, 2); AddV(0, 5, 2, 2);
  AddTri(0, 1, 2); AddTri(3, 4, 5);
  M := TV3DMeshData.Create;
  try
    Check(CADConvertRawMesh(Raw, M, S, E), 'surface converts: ' + E);
    Check((M.VertexCount = 6) and (M.IndexCount = 6), 'vertex and index counts');
    Check((S.Vertices = 6) and (S.Triangles = 2) and (S.EdgePolylines = 0), 'stats');
    Check((M.Vertices[0].FaceId = 1) and (M.Vertices[5].FaceId = 2), 'face ids kept (OCCT 1-based)');
    Check((M.Indices[3] = 3) and (M.Indices[5] = 5), 'indices kept');
    Check((M.Vertices[2].PX = 10) and (M.Vertices[2].PY = 5) and (M.Vertices[0].NZ = 1), 'position and normal copied');
    Check(M.GetBounds(Lo, Hi) and (Hi.X = 10) and (Hi.Y = 5) and (Hi.Z = 2) and (Lo.X = 0), 'bounds');
    { a second conversion replaces, never appends }
    Check(CADConvertRawMesh(Raw, M, S, E) and (M.VertexCount = 6), 'convert twice: replaced');
  finally
    M.Free;
  end;
end;

procedure TestEdges;
var
  M: TV3DMeshData;
  S: TCADMeshConvertStats;
  E: string;
begin
  ResetRaw;
  { id 1: closed square, 4 segments }
  AddSeg(0, 0, 0, 1, 0, 0, 1); AddSeg(1, 0, 0, 1, 1, 0, 1);
  AddSeg(1, 1, 0, 0, 1, 0, 1); AddSeg(0, 1, 0, 0, 0, 0, 1);
  { id 2: open chain of 2 segments }
  AddSeg(0, 0, 5, 1, 0, 5, 2); AddSeg(1, 0, 5, 2, 0, 5, 2);
  { id 3: zero length segment between two pieces with a gap }
  AddSeg(0, 0, 9, 1, 0, 9, 3); AddSeg(1, 0, 9, 1, 0, 9, 3);
  AddSeg(5, 0, 9, 6, 0, 9, 3);
  M := TV3DMeshData.Create;
  try
    Check(CADConvertRawMesh(Raw, M, S, E), 'edges convert: ' + E);
    Check(S.EdgeSegments = 8, Format('8 real segments (zero length dropped), got %d', [S.EdgeSegments]));
    Check(S.EdgePolylines = 4, Format('4 polylines (square, chain, 2 pieces of a gap), got %d', [S.EdgePolylines]));
    Check(S.ClosedPolylines = 1, 'square is closed');
    Check(M.StrokeCount = 16, Format('2 strokes per segment = 16, got %d', [M.StrokeCount]));
    { square: closed => no caps, first stroke prev = last corner }
    Check((M.Strokes[0].Cap = 0) and (M.Strokes[7].Cap = 0), 'closed square has no caps');
    Check((M.Strokes[0].PrevX = 0) and (M.Strokes[0].PrevY = 1), 'closed square joins last -> first');
    { chain: caps at both ends only, inner joint shares the point }
    Check((M.Strokes[8].Cap = 1) and (M.Strokes[9].Cap = 0) and
          (M.Strokes[10].Cap = 0) and (M.Strokes[11].Cap = 1), 'open chain: caps at the ends only');
    Check((M.Strokes[9].NextX = 2) and (M.Strokes[10].PrevX = 0), 'open chain: joint sees neighbours');
    Check((M.Strokes[0].EdgeId = 1) and (M.Strokes[8].EdgeId = 2) and (M.Strokes[15].EdgeId = 3), 'edge ids kept');
  finally
    M.Free;
  end;
end;

procedure TestErrors;
var
  M: TV3DMeshData;
  S: TCADMeshConvertStats;
  E: string;
  R: TCADRawMesh;
begin
  M := TV3DMeshData.Create;
  try
    ResetRaw;
    Check(CADConvertRawMesh(Raw, M, S, E) and (M.VertexCount = 0), 'empty mesh is fine');

    AddV(0, 0, 0, 1); AddV(1, 0, 0, 1); AddV(0, 1, 0, 1);
    AddTri(0, 1, 3);
    Check(not CADConvertRawMesh(Raw, M, S, E) and (Pos('out of range', E) > 0), 'index out of range rejected');
    Check((M.VertexCount = 0) and (M.IndexCount = 0), 'target left empty on error');

    R := Raw;
    R.IndexCount := 2;
    Check(not CADConvertRawMesh(R, M, S, E) and (Pos('multiple of 3', E) > 0), 'index count not x3 rejected');

    ResetRaw;
    AddV(0, 0, 0, 1);
    R := Raw;
    R.Normals := nil;
    Check(not CADConvertRawMesh(R, M, S, E) and (Pos('missing', E) > 0), 'nil normals rejected');

    ResetRaw;
    AddSeg(0, 0, 0, 1, 0, 0, 1);
    R := Raw;
    R.EdgeVertexCount := 1;
    Check(not CADConvertRawMesh(R, M, S, E) and (Pos('odd', E) > 0), 'odd edge vertex count rejected');
  finally
    M.Free;
  end;
end;

procedure TestSpeed;
const
  GRID = 400;                       { 400 x 400 quads = 640k vertices, 320k triangles }
  CX: array[0..3] of Single = (0, 1, 1, 0);
  CY: array[0..3] of Single = (0, 0, 1, 1);
var
  M: TV3DMeshData;
  S: TCADMeshConvertStats;
  E: string;
  X, Y, Q, K: Integer;
  T0, T1: QWord;
begin
  ResetRaw;
  SetLength(GPos, GRID * GRID * 4 * 3);
  SetLength(GNrm, GRID * GRID * 4 * 3);
  SetLength(GFace, GRID * GRID * 4);
  SetLength(GIdx, GRID * GRID * 6);
  for Y := 0 to GRID - 1 do
    for X := 0 to GRID - 1 do
    begin
      Q := Y * GRID + X;
      for K := 0 to 3 do
      begin
        GPos[(Q * 4 + K) * 3] := X + CX[K];
        GPos[(Q * 4 + K) * 3 + 1] := Y + CY[K];
        GPos[(Q * 4 + K) * 3 + 2] := 0;
        GNrm[(Q * 4 + K) * 3] := 0;
        GNrm[(Q * 4 + K) * 3 + 1] := 0;
        GNrm[(Q * 4 + K) * 3 + 2] := 1;
        GFace[Q * 4 + K] := 1;
      end;
      GIdx[Q * 6] := Q * 4;     GIdx[Q * 6 + 1] := Q * 4 + 1; GIdx[Q * 6 + 2] := Q * 4 + 2;
      GIdx[Q * 6 + 3] := Q * 4; GIdx[Q * 6 + 4] := Q * 4 + 2; GIdx[Q * 6 + 5] := Q * 4 + 3;
    end;
  SetLength(GEdgePos, GRID * 2 * 3);
  SetLength(GEdgeIds, GRID * 2);
  for X := 0 to GRID - 1 do
  begin
    GEdgePos[X * 6] := X;     GEdgePos[X * 6 + 1] := 0; GEdgePos[X * 6 + 2] := 0;
    GEdgePos[X * 6 + 3] := X + 1; GEdgePos[X * 6 + 4] := 0; GEdgePos[X * 6 + 5] := 0;
    GEdgeIds[X * 2] := 1;
    GEdgeIds[X * 2 + 1] := 1;
  end;
  M := TV3DMeshData.Create;
  try
    T0 := GetTickCount64;
    Check(CADConvertRawMesh(Raw, M, S, E), 'big mesh converts: ' + E);
    T1 := GetTickCount64;
    Check((S.EdgePolylines = 1) and (M.StrokeCount = GRID * 2), 'grid border edge joined into one polyline');
    WriteLn(Format('INFO  convert %d vertices, %d triangles, %d edge segments: %d ms',
      [S.Vertices, S.Triangles, S.EdgeSegments, T1 - T0]));
  finally
    M.Free;
  end;
  ResetRaw;
end;

{ ---- OCCT tests ---- }

procedure ConvertShape(AShape: TOCCTShapeHandle; M: TV3DMeshData;
  out S: TCADMeshConvertStats; out AVerts, AIdx: Integer; out AOk: Boolean);
var
  H: TOCCTMeshHandle;
  E: string;
begin
  AOk := False;
  AVerts := 0;
  AIdx := 0;
  S := Default(TCADMeshConvertStats);
  H := OCCT.MeshShape(AShape, 0);
  if H = nil then
  begin
    Check(False, 'mesh: ' + OCCT.LastError);
    Exit;
  end;
  AVerts := OCCT.MeshVertexCount(H);
  AIdx := OCCT.MeshIndexCount(H);
  AOk := CADConvertRawMesh(CADRawMeshFromOCCT(H, True), M, S, E);
  Check(AOk, 'OCCT mesh converts: ' + E);
  OCCT.FreeMesh(H);           { the target owns copies: freeing is safe }
end;

procedure TestOCCT;
var
  L: TOCCTLibrary;
  Box, Cyl: TOCCTShapeHandle;
  M: TV3DMeshData;
  S: TCADMeshConvertStats;
  NV, NI, I: Integer;
  Ok, IdsOk: Boolean;
  MinFace, MaxFace: Cardinal;
  Lo, Hi: TV3Vec;
begin
  L := TOCCTLibrary.Create;
  try
    L.Load;
  except
    on Ex: Exception do
    begin
      WriteLn('INFO  OCCT part skipped (bridge not loaded): ', Ex.Message);
      L.Free;
      Exit;
    end;
  end;
  SetOCCT(L);
  M := TV3DMeshData.Create;
  try
    L.ApplyOptions(DefaultPerformanceOptions);
    Box := L.MakeBox(0, 0, 0, 30, 20, 10);
    ConvertShape(Box, M, S, NV, NI, Ok);
    if Ok then
    begin
      Check((M.VertexCount = NV) and (M.IndexCount = NI), 'box: counts equal the bridge mesh');
      MinFace := High(Cardinal);
      MaxFace := 0;
      for I := 0 to M.VertexCount - 1 do
      begin
        if M.Vertices[I].FaceId < MinFace then MinFace := M.Vertices[I].FaceId;
        if M.Vertices[I].FaceId > MaxFace then MaxFace := M.Vertices[I].FaceId;
      end;
      Check((MinFace = 1) and (MaxFace = 6), Format('box: face ids 1..6, got %d..%d', [MinFace, MaxFace]));
      Check(M.GetBounds(Lo, Hi) and SameValue(Hi.X - Lo.X, 30, 1e-4) and
        SameValue(Hi.Y - Lo.Y, 20, 1e-4) and SameValue(Hi.Z - Lo.Z, 10, 1e-4), 'box: bounds 30 x 20 x 10');
      Check(S.EdgePolylines = 12, Format('box: 12 edge polylines, got %d', [S.EdgePolylines]));
      IdsOk := True;
      for I := 0 to M.StrokeCount - 1 do
        IdsOk := IdsOk and (M.Strokes[I].EdgeId >= 1) and (M.Strokes[I].EdgeId <= 12);
      Check(IdsOk, 'box: edge ids 1..12');
    end;
    L.FreeShape(Box);

    Cyl := L.MakeCylinder(0, 0, 0, 5, 20);
    ConvertShape(Cyl, M, S, NV, NI, Ok);
    if Ok then
    begin
      Check(M.IndexCount = NI, 'cylinder: index count equals the bridge mesh');
      Check(S.ClosedPolylines >= 2, Format('cylinder: top and bottom circles closed, got %d', [S.ClosedPolylines]));
      Check(M.GetBounds(Lo, Hi) and SameValue(Hi.Z - Lo.Z, 20, 1e-4) and
        (Abs(Hi.X - Lo.X - 10) < 0.1), 'cylinder: bounds');
      WriteLn(Format('INFO  cylinder: %d vertices, %d triangles, %d edge polylines (%d closed)',
        [S.Vertices, S.Triangles, S.EdgePolylines, S.ClosedPolylines]));
    end;
    L.FreeShape(Cyl);
  finally
    M.Free;
    SetOCCT(nil);
    L.Free;
  end;
end;

begin
  Checks := 0;
  Failures := 0;
  TestSurface;
  TestEdges;
  TestErrors;
  TestSpeed;
  TestOCCT;
  if Failures = 0 then
    WriteLn(Format('PASS  view mesh: %d checks', [Checks]))
  else
    WriteLn(Format('FAIL  view mesh: %d of %d checks failed', [Failures, Checks]));
  if Failures <> 0 then
    Halt(1);
end.
