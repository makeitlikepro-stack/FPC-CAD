unit CAD.App.ExtrudePreview;
{$mode objfpc}{$H+}

{ ROLE: Build a real OCCT extruded preview from the same planar profiles
  and depth/direction settings as the final document feature. The preview
  owns no persistent OCCT result; temporary face/prism/mesh handles are
  always freed. It never mutates the Sketch or the document. }

interface

uses
  SysUtils, CAD.Sketch.Model, CAD.Sketch.Profile, CAD.Sketch.Regions,
  CAD.Sketch.ContourSelection, CAD.Sketch.ExtrudeOptions,
  CAD.Features.Sketch, CAD.OCCT.Bridge, CAD.View.MeshConvert,
  OpenGL.Render.Viewport3DMeshData;

function CADBuildExtrudePreview(S: TCADSketch; const Seeds: TCADContourSeeds;
  const Options: TCADExtrudeOptions; AMesh: TV3DMeshData;
  out AError: string): Boolean;

implementation

function CADBuildExtrudePreview(S: TCADSketch; const Seeds: TCADContourSeeds;
  const Options: TCADExtrudeOptions; AMesh: TV3DMeshData;
  out AError: string): Boolean;
var
  Profile: TCADSketchProfile;
  Plane, Edges: TCADDoubleArray;
  LoopSizes, FaceLoops: TCADLongIntArray;
  Selected: TCADRegionIndices;
  Faces, Solid: TOCCTShapeHandle;
  M: TOCCTMeshHandle;
  Raw: TCADRawMesh;
  Stats: TCADMeshConvertStats;
begin
  Result := False;
  AError := '';
  if AMesh = nil then
  begin
    AError := 'Preview mesh is missing';
    Exit;
  end;
  AMesh.Clear;
  if not CADValidateExtrudeOptions(Options, AError) then Exit;
  if S = nil then
  begin
    AError := 'No Sketch is active';
    Exit;
  end;
  if Length(Seeds) = 0 then
  begin
    { Exactly the same legacy-with-holes fallback as the Sketch feature. }
    if not CADBuildProfile(S, Profile) then
      if not CADBuildRegions(S, Profile) then
      begin
        AError := Profile.Error;
        Exit;
      end;
  end
  else
  begin
    if not CADBuildRegions(S, Profile) then
    begin
      AError := Profile.Error;
      Exit;
    end;
    Selected := CADContourIndices(Profile, Seeds);
    if Length(Selected) = 0 then
    begin
      AError := 'The selected contour no longer exists';
      Exit;
    end;
    Profile := CADRegionProfileSubset(Profile, Selected);
  end;
  if Length(Profile.Faces) = 0 then
  begin
    AError := 'No closed contour to extrude';
    Exit;
  end;
  CADProfileArrays(S, Profile, Plane, Edges, LoopSizes, FaceLoops);

  Faces := nil;
  Solid := nil;
  M := nil;
  try
    try
      Faces := OCCT.MakePlanarFaces(Plane, Edges, LoopSizes, FaceLoops);
      if Faces = nil then
      begin
        AError := 'OCCT could not create planar sketch faces: ' + OCCT.LastError;
        Exit;
      end;
      Solid := OCCT.Extrude(Faces, Options.Depth, Options.Symmetric,
        Options.Reversed);
      if Solid = nil then
      begin
        AError := 'OCCT Extrude preview failed: ' + OCCT.LastError;
        Exit;
      end;
      M := OCCT.MeshShape(Solid, 0);
      if M = nil then
      begin
        AError := 'OCCT preview tessellation failed: ' + OCCT.LastError;
        Exit;
      end;
      Raw := CADRawMeshFromOCCT(M, True);
      Result := CADConvertRawMesh(Raw, AMesh, Stats, AError);
    except
      on E: Exception do
      begin
        AError := 'Extrude preview: ' + E.Message;
        AMesh.Clear;
        Result := False;
      end;
    end;
  finally
    if M <> nil then OCCT.FreeMesh(M);
    if Solid <> nil then OCCT.FreeShape(Solid);
    if Faces <> nil then OCCT.FreeShape(Faces);
  end;
end;

end.
