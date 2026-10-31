unit CAD.OCCT.Bridge;
{$mode objfpc}{$H+}

{ ROLE:      loads libocct_bridge (external/occt_bridge) and exposes its C
             functions as typed methods. The ONLY unit that knows the C names.
  CALLED BY: OCCT features (stage 3: box, extrude, cut), tests/occt.
  CALLS:     the bridge through dynlibs; CAD.OCCT.Options.
  THREADS:   Load/ApplyOptions on the UI thread before recomputes. Shape and
             mesh calls are thread-safe in the bridge (each works on its own
             handles; errors are thread_local), so features may call them
             from worker threads.
  SPEED:     symbols are resolved once at Load; calls are direct pointers. }

interface

uses
  SysUtils, dynlibs, CAD.Config.Performance, CAD.OCCT.Options;

type
  TOCCTShapeHandle = Pointer;     { owned by the caller: FreeShape }
  TOCCTMeshHandle = Pointer;      { owned by the caller: FreeMesh }

  TOCCTLibrary = class
  private
    FHandle: TLibHandle;
    FPath: string;
    FVersion: function: PChar; cdecl;
    FLastError: function: PChar; cdecl;
    { Pointers, not const/out records: cdecl may pass a const record by
      value, while the C side takes occt_bridge_options*. }
    FSetOptions: function(AOptions: Pointer): LongInt; cdecl;
    FGetOptions: function(AOptions: Pointer): LongInt; cdecl;
    FOptionsSize: function: LongInt; cdecl;
    FMakePrism: function(AWidth, ADepth, AHeight: Double): Pointer; cdecl;
    FCutCylinder: function(ABase: Pointer; ARadius, ACenterX, ACenterY: Double): Pointer; cdecl;
    FFreeShape: procedure(AShape: Pointer); cdecl;
    FMakeBox: function(X, Y, Z, DX, DY, DZ: Double): Pointer; cdecl;
    FMakeCylinder: function(X, Y, Z, ARadius, AHeight: Double): Pointer; cdecl;
    FBoolean: function(AOp: LongInt; AObject, ATool: Pointer): Pointer; cdecl;
    FShapeVolume: function(AShape: Pointer): Double; cdecl;
    FOptions: TCADPerformanceOptions;
    FMeshShape: function(AShape: Pointer; ALinearDeflection: Double): Pointer; cdecl;
    FFreeMesh: procedure(AMesh: Pointer); cdecl;
    FVertexCount: function(AMesh: Pointer): LongInt; cdecl;
    FIndexCount: function(AMesh: Pointer): LongInt; cdecl;
    FEdgeVertexCount: function(AMesh: Pointer): LongInt; cdecl;
    FPositions: function(AMesh: Pointer): PSingle; cdecl;
    FNormals: function(AMesh: Pointer): PSingle; cdecl;
    FIndices: function(AMesh: Pointer): PLongWord; cdecl;
    FFaceIds: function(AMesh: Pointer): PLongWord; cdecl;
    FEdgePositions: function(AMesh: Pointer): PSingle; cdecl;
    FEdgeIds: function(AMesh: Pointer): PLongWord; cdecl;
    FVolume: function(AMesh: Pointer): Double; cdecl;
    function Sym(const AName: string): Pointer;
  public
    destructor Destroy; override;
    { '' = env OCCT_BRIDGE_LIB, else external/occt_bridge next to the program
      and two folders up. Raises with the missing path or symbol name. }
    procedure Load(const APath: string = '');
    function Loaded: Boolean;
    function OcctVersion: string;
    function LastError: string;
    { Sends the OCCT part of AOptions; False + LastError on ABI mismatch. }
    function ApplyOptions(const AOptions: TCADPerformanceOptions): Boolean;
    { Sends a raw record (tests: ABI mismatch must be rejected). }
    function SetBridgeOptions(const AOptions: TOCCTBridgeOptions): Boolean;
    function ReadOptions(out AOptions: TOCCTBridgeOptions): Boolean;
    function BridgeOptionsSize: Integer;

    { The options last sent with ApplyOptions (features read MeshInRecompute). }
    property Options: TCADPerformanceOptions read FOptions;
    { Box with its minimum corner at (X, Y, Z). }
    function MakeBox(X, Y, Z, DX, DY, DZ: Double): TOCCTShapeHandle;
    { Cylinder along +Z, bottom centre at (X, Y, Z). }
    function MakeCylinder(X, Y, Z, ARadius, AHeight: Double): TOCCTShapeHandle;
    { AOp: 0 cut (object - tool), 1 fuse, 2 common. }
    function BooleanOp(AOp: Integer; AObject, ATool: TOCCTShapeHandle): TOCCTShapeHandle;
    { Exact B-rep volume, -1 on error. }
    function ShapeVolume(AShape: TOCCTShapeHandle): Double;
    function MakePrism(AWidth, ADepth, AHeight: Double): TOCCTShapeHandle;
    function CutCylinder(ABase: TOCCTShapeHandle; ARadius, ACenterX, ACenterY: Double): TOCCTShapeHandle;
    procedure FreeShape(AShape: TOCCTShapeHandle);
    { ALinearDeflection <= 0: use the deflection from the options. }
    function MeshShape(AShape: TOCCTShapeHandle; ALinearDeflection: Double = 0): TOCCTMeshHandle;
    procedure FreeMesh(AMesh: TOCCTMeshHandle);
    function MeshVertexCount(AMesh: TOCCTMeshHandle): Integer;
    function MeshIndexCount(AMesh: TOCCTMeshHandle): Integer;
    function MeshEdgeVertexCount(AMesh: TOCCTMeshHandle): Integer;
    function MeshPositions(AMesh: TOCCTMeshHandle): PSingle;
    function MeshNormals(AMesh: TOCCTMeshHandle): PSingle;
    function MeshIndices(AMesh: TOCCTMeshHandle): PLongWord;
    function MeshFaceIds(AMesh: TOCCTMeshHandle): PLongWord;
    function MeshEdgePositions(AMesh: TOCCTMeshHandle): PSingle;
    function MeshEdgeIds(AMesh: TOCCTMeshHandle): PLongWord;
    function MeshVolume(AMesh: TOCCTMeshHandle): Double;
    property Path: string read FPath;
  end;

{ Platform file name: libocct_bridge.so / occt_bridge.dll / libocct_bridge.dylib }
function OCCTBridgeFileName: string;

{ The process-wide bridge used by the OCCT features. The application creates,
  loads and frees it (SetOCCT before the first recompute, SetOCCT(nil) after
  the last document is freed). }
function OCCT: TOCCTLibrary;
procedure SetOCCT(ALibrary: TOCCTLibrary);

implementation

var
  GOCCT: TOCCTLibrary = nil;

function OCCT: TOCCTLibrary;
begin
  if GOCCT = nil then
    raise Exception.Create('OCCT bridge not set: call SetOCCT after TOCCTLibrary.Load');
  Result := GOCCT;
end;

procedure SetOCCT(ALibrary: TOCCTLibrary);
begin
  GOCCT := ALibrary;
end;

function OCCTBridgeFileName: string;
begin
  {$if defined(windows)}
  Result := 'occt_bridge.dll';
  {$elseif defined(darwin)}
  Result := 'libocct_bridge.dylib';
  {$else}
  Result := 'libocct_bridge.so';
  {$endif}
end;

function DefaultBridgePath: string;
var
  Base, Candidate: string;
  Up: Integer;
begin
  Result := GetEnvironmentVariable('OCCT_BRIDGE_LIB');
  if Result <> '' then
    Exit;
  Base := ExtractFilePath(ExpandFileName(ParamStr(0)));
  for Up := 0 to 3 do
  begin
    Candidate := Base + 'external' + PathDelim + 'occt_bridge' + PathDelim + OCCTBridgeFileName;
    if FileExists(Candidate) then
      Exit(Candidate);
    Candidate := Base + OCCTBridgeFileName;
    if FileExists(Candidate) then
      Exit(Candidate);
    Base := ExtractFilePath(ExcludeTrailingPathDelimiter(Base));
  end;
  Result := OCCTBridgeFileName;            { let the loader search }
end;

destructor TOCCTLibrary.Destroy;
begin
  if FHandle <> NilHandle then
    UnloadLibrary(FHandle);
  inherited Destroy;
end;

function TOCCTLibrary.Sym(const AName: string): Pointer;
begin
  Result := GetProcedureAddress(FHandle, AName);
  if Result = nil then
    raise Exception.CreateFmt('OCCT bridge %s: missing symbol %s (rebuild external/occt_bridge)',
      [FPath, AName]);
end;

procedure TOCCTLibrary.Load(const APath: string);
begin
  if FHandle <> NilHandle then
    Exit;
  if APath <> '' then FPath := APath else FPath := DefaultBridgePath;
  FOptions := DefaultPerformanceOptions;
  FHandle := LoadLibrary(FPath);
  if FHandle = NilHandle then
    raise Exception.CreateFmt('Cannot load OCCT bridge "%s": %s', [FPath, GetLoadErrorStr]);
  Pointer(FVersion) := Sym('occt_bridge_occt_version');
  Pointer(FLastError) := Sym('occt_bridge_last_error');
  Pointer(FSetOptions) := Sym('occt_bridge_set_options');
  Pointer(FGetOptions) := Sym('occt_bridge_get_options');
  Pointer(FOptionsSize) := Sym('occt_bridge_options_size');
  Pointer(FMakePrism) := Sym('occt_bridge_create_rectangle_prism_shape');
  Pointer(FCutCylinder) := Sym('occt_bridge_cut_cylinder_shape');
  Pointer(FFreeShape) := Sym('occt_bridge_free_shape');
  Pointer(FMakeBox) := Sym('occt_bridge_make_box');
  Pointer(FMakeCylinder) := Sym('occt_bridge_make_cylinder');
  Pointer(FBoolean) := Sym('occt_bridge_boolean');
  Pointer(FShapeVolume) := Sym('occt_bridge_shape_volume');
  Pointer(FMeshShape) := Sym('occt_bridge_mesh_shape');
  Pointer(FFreeMesh) := Sym('occt_bridge_free_demo_mesh');
  Pointer(FVertexCount) := Sym('occt_bridge_mesh_vertex_count');
  Pointer(FIndexCount) := Sym('occt_bridge_mesh_index_count');
  Pointer(FEdgeVertexCount) := Sym('occt_bridge_mesh_edge_vertex_count');
  Pointer(FPositions) := Sym('occt_bridge_mesh_positions');
  Pointer(FNormals) := Sym('occt_bridge_mesh_normals');
  Pointer(FIndices) := Sym('occt_bridge_mesh_indices');
  Pointer(FFaceIds) := Sym('occt_bridge_mesh_face_ids');
  Pointer(FEdgePositions) := Sym('occt_bridge_mesh_edge_positions');
  Pointer(FEdgeIds) := Sym('occt_bridge_mesh_edge_ids');
  Pointer(FVolume) := Sym('occt_bridge_mesh_volume');
end;

function TOCCTLibrary.Loaded: Boolean;
begin
  Result := FHandle <> NilHandle;
end;

function TOCCTLibrary.OcctVersion: string;
begin
  Result := string(FVersion());
end;

function TOCCTLibrary.LastError: string;
begin
  Result := string(FLastError());
end;

function TOCCTLibrary.BridgeOptionsSize: Integer;
begin
  Result := FOptionsSize();
end;

function TOCCTLibrary.ApplyOptions(const AOptions: TCADPerformanceOptions): Boolean;
begin
  Result := SetBridgeOptions(OCCTOptionsFromPerformance(AOptions));
  if Result then
    FOptions := AOptions;
end;

function TOCCTLibrary.SetBridgeOptions(const AOptions: TOCCTBridgeOptions): Boolean;
var
  O: TOCCTBridgeOptions;
begin
  O := AOptions;                     { local copy: a stable address for C }
  Result := FSetOptions(@O) = 1;
end;

function TOCCTLibrary.ReadOptions(out AOptions: TOCCTBridgeOptions): Boolean;
begin
  FillChar(AOptions, SizeOf(AOptions), 0);
  Result := FGetOptions(@AOptions) = 1;
end;

function TOCCTLibrary.MakeBox(X, Y, Z, DX, DY, DZ: Double): TOCCTShapeHandle;
begin
  Result := FMakeBox(X, Y, Z, DX, DY, DZ);
end;

function TOCCTLibrary.MakeCylinder(X, Y, Z, ARadius, AHeight: Double): TOCCTShapeHandle;
begin
  Result := FMakeCylinder(X, Y, Z, ARadius, AHeight);
end;

function TOCCTLibrary.BooleanOp(AOp: Integer; AObject, ATool: TOCCTShapeHandle): TOCCTShapeHandle;
begin
  Result := FBoolean(AOp, AObject, ATool);
end;

function TOCCTLibrary.ShapeVolume(AShape: TOCCTShapeHandle): Double;
begin
  Result := FShapeVolume(AShape);
end;

function TOCCTLibrary.MakePrism(AWidth, ADepth, AHeight: Double): TOCCTShapeHandle;
begin
  Result := FMakePrism(AWidth, ADepth, AHeight);
end;

function TOCCTLibrary.CutCylinder(ABase: TOCCTShapeHandle; ARadius, ACenterX,
  ACenterY: Double): TOCCTShapeHandle;
begin
  Result := FCutCylinder(ABase, ARadius, ACenterX, ACenterY);
end;

procedure TOCCTLibrary.FreeShape(AShape: TOCCTShapeHandle);
begin
  if AShape <> nil then
    FFreeShape(AShape);
end;

function TOCCTLibrary.MeshShape(AShape: TOCCTShapeHandle; ALinearDeflection: Double): TOCCTMeshHandle;
begin
  Result := FMeshShape(AShape, ALinearDeflection);
end;

procedure TOCCTLibrary.FreeMesh(AMesh: TOCCTMeshHandle);
begin
  if AMesh <> nil then
    FFreeMesh(AMesh);
end;

function TOCCTLibrary.MeshVertexCount(AMesh: TOCCTMeshHandle): Integer;
begin
  Result := FVertexCount(AMesh);
end;

function TOCCTLibrary.MeshIndexCount(AMesh: TOCCTMeshHandle): Integer;
begin
  Result := FIndexCount(AMesh);
end;

function TOCCTLibrary.MeshEdgeVertexCount(AMesh: TOCCTMeshHandle): Integer;
begin
  Result := FEdgeVertexCount(AMesh);
end;

function TOCCTLibrary.MeshPositions(AMesh: TOCCTMeshHandle): PSingle;
begin
  Result := FPositions(AMesh);
end;

function TOCCTLibrary.MeshNormals(AMesh: TOCCTMeshHandle): PSingle;
begin
  Result := FNormals(AMesh);
end;

function TOCCTLibrary.MeshIndices(AMesh: TOCCTMeshHandle): PLongWord;
begin
  Result := FIndices(AMesh);
end;

function TOCCTLibrary.MeshFaceIds(AMesh: TOCCTMeshHandle): PLongWord;
begin
  Result := FFaceIds(AMesh);
end;

function TOCCTLibrary.MeshEdgePositions(AMesh: TOCCTMeshHandle): PSingle;
begin
  Result := FEdgePositions(AMesh);
end;

function TOCCTLibrary.MeshEdgeIds(AMesh: TOCCTMeshHandle): PLongWord;
begin
  Result := FEdgeIds(AMesh);
end;

function TOCCTLibrary.MeshVolume(AMesh: TOCCTMeshHandle): Double;
begin
  Result := FVolume(AMesh);
end;

end.
