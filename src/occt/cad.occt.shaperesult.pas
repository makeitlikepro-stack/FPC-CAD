unit CAD.OCCT.ShapeResult;
{$mode objfpc}{$H+}

{ ROLE:      the result of an OCCT feature: one B-rep shape handle, its exact
             volume and (optionally) its display mesh handle.
  CALLED BY: OCCT features (create it in Compute), the cache (frees it),
             the viewport (stage 4: reads the mesh).
  CALLS:     CAD.OCCT.Bridge (FreeShape, FreeMesh, MeshVertexCount).
  THREADS:   created on a worker thread, immutable afterwards, freed by the
             cache under its lock. The bridge frees handles thread-safely.
  SPEED:     EstimatedBytes follows the mesh size, so the cache limit is
             about real memory; the shape is shared, never copied. }

interface

uses
  SysUtils, CAD.Core.Feature, CAD.OCCT.Bridge;

type
  TOCCTShapeResult = class(TCADResult)
  private
    FShape: TOCCTShapeHandle;
    FMesh: TOCCTMeshHandle;
    FVolume: Double;
  public
    { Takes ownership of both handles (AMesh may be nil). }
    constructor Create(AShape: TOCCTShapeHandle; AMesh: TOCCTMeshHandle; AVolume: Double);
    destructor Destroy; override;
    function EstimatedBytes: Int64; override;
    property Shape: TOCCTShapeHandle read FShape;
    property Mesh: TOCCTMeshHandle read FMesh;
    property Volume: Double read FVolume;
  end;

implementation

constructor TOCCTShapeResult.Create(AShape: TOCCTShapeHandle; AMesh: TOCCTMeshHandle;
  AVolume: Double);
begin
  inherited Create;
  FShape := AShape;
  FMesh := AMesh;
  FVolume := AVolume;
end;

destructor TOCCTShapeResult.Destroy;
begin
  OCCT.FreeMesh(FMesh);
  OCCT.FreeShape(FShape);
  inherited Destroy;
end;

function TOCCTShapeResult.EstimatedBytes: Int64;
begin
  { B-rep: a rough constant; mesh: position + normal + face id per vertex,
    one index per corner, edge polylines. }
  Result := 16 * 1024;
  if FMesh <> nil then
    Result := Result + Int64(OCCT.MeshVertexCount(FMesh)) * 40 +
      Int64(OCCT.MeshIndexCount(FMesh)) * 4 + Int64(OCCT.MeshEdgeVertexCount(FMesh)) * 16;
end;

end.
