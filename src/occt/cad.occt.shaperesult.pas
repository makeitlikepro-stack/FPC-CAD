unit CAD.OCCT.ShapeResult;
{$mode objfpc}{$H+}

{ ROLE:      the result of an OCCT feature: one B-rep shape handle, its exact
             volume and (optionally) its display mesh handle.
  CALLED BY: OCCT features (create it in Compute), the display pass
             (PrepareDisplay = make the mesh), the cache (frees it), the
             viewport (stage 4: reads the mesh).
  CALLS:     CAD.OCCT.Bridge (FreeShape, FreeMesh, MeshVertexCount).
  THREADS:   created on a worker thread; the shape is immutable afterwards.
             The mesh is added once, by PrepareDisplay (display pass, calling
             thread, no recompute running) or inside Compute when
             Mesh.Timing = cmtEveryResult. Freed by the cache under its lock.
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
    { Display = the triangle mesh (OCCT BRepMesh, options from the bridge). }
    function DisplayReady: Boolean; override;
    function PrepareDisplay(out AError: string): Boolean; override;
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

function TOCCTShapeResult.DisplayReady: Boolean;
begin
  Result := FMesh <> nil;
end;

function TOCCTShapeResult.PrepareDisplay(out AError: string): Boolean;
begin
  AError := '';
  if FMesh = nil then
    FMesh := OCCT.MeshShape(FShape, 0);     { 0 = deflection from the options }
  Result := FMesh <> nil;
  if not Result then
    AError := 'mesh: ' + OCCT.LastError;
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
