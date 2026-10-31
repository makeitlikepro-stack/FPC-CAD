unit CAD.App.SketchFill;
{$mode objfpc}{$H+}

{ ROLE:      the light fill of the closed regions of the open sketch
             (SolidWorks shades what Extrude would use): the same profile
             faces the Sketch feature builds (CAD.Sketch.Profile ->
             OCCT planar faces), meshed and put into a viewport mesh,
             moved a little behind the sketch plane so the sketch lines stay
             on top. Surfaces only (no edges).
  CALLED BY: CAD.App.SketchMode (after every sketch change).
  CALLS:     CAD.Sketch.Profile, CAD.Features.Sketch (CADProfileArrays),
             CAD.OCCT.Bridge, CAD.View.MeshConvert.
  THREADS:   UI thread (OCCT calls are made here; one small sketch).
  SPEED:     one planar face build + mesh per change; nothing when the
             sketch has no closed region. }

interface

uses
  SysUtils, Math, CAD.Sketch.Model, CAD.Sketch.Profile, CAD.Features.Sketch,
  CAD.Core.Values, CAD.OCCT.Bridge, CAD.View.MeshConvert,
  OpenGL.Render.Viewport3DMeshData;

{ Fills AMesh with the closed regions of S (cleared first); ABehind = sketch
  mm behind the plane. False (AMesh empty) when there is no closed region or
  OCCT is not loaded. }
function CADBuildSketchFill(S: TCADSketch; AMesh: TV3DMeshData; ABehind: Double): Boolean;

implementation

function CADBuildSketchFill(S: TCADSketch; AMesh: TV3DMeshData; ABehind: Double): Boolean;
var
  P: TCADSketchProfile;
  Plane, Edges: TCADDoubleArray;
  LoopSizes, FaceLoops: TCADLongIntArray;
  Shape: TOCCTShapeHandle;
  Mesh: TOCCTMeshHandle;
  Raw: TCADRawMesh;
  Stats: TCADMeshConvertStats;
  Err: string;
  I: Integer;
begin
  Result := False;
  AMesh.Clear;
  if (OCCT = nil) or (S = nil) or (S.EntityCount = 0) then
    Exit;
  if not CADBuildProfile(S, P) or (Length(P.Faces) = 0) then
    Exit;
  CADProfileArrays(S, P, Plane, Edges, LoopSizes, FaceLoops);
  for I := 0 to 2 do
    Plane[I] := Plane[I] - Plane[6 + I] * ABehind;   { origin moved against the normal }
  Shape := nil;
  Mesh := nil;
  try
    try
      Shape := OCCT.MakePlanarFaces(Plane, Edges, LoopSizes, FaceLoops);
      if Shape = nil then
        Exit;
      Mesh := OCCT.MeshShape(Shape, 0);
      if Mesh = nil then
        Exit;
      Raw := CADRawMeshFromOCCT(Mesh, False);
      Raw.EdgeVertexCount := 0;                     { surfaces only }
      Result := CADConvertRawMesh(Raw, AMesh, Stats, Err);
    except
      on E: Exception do
      begin
        AMesh.Clear;
        Result := False;
      end;
    end;
  finally
    if Mesh <> nil then
      OCCT.FreeMesh(Mesh);
    if Shape <> nil then
      OCCT.FreeShape(Shape);
  end;
end;

end.
