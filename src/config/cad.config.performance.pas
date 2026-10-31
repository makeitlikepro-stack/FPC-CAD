unit CAD.Config.Performance;
{$mode objfpc}{$H+}

{ ROLE:      every speed knob of FPC-CAD in one record (docs/PERFORMANCE.md).
  CALLED BY: TCADDocument (threads, cache), OCCT adapter (stage 3: Mesh,
             Boolean, Threads.OcctThreads), viewport (stage 4: Gpu).
  CALLS:     nothing.
  THREADS:   read-only during a recompute; change it between recomputes.
  SPEED:     defaults favour interactive speed; each field says its trade-off. }

interface

type
  { Recompute threads (CAD core). }
  TCADThreadOptions = record
    { Threads that compute independent features of one level, INCLUDING the
      calling thread. 0 = one per core. 1 = serial (debugging). }
    RecomputeThreads: Integer;
    { Threads OCCT may use inside one operation (OSD_ThreadPool). 0 = all.
      With many parallel features, a smaller value avoids oversubscription. }
    OcctThreads: Integer;
    { Levels with fewer features than this run on the calling thread only:
      waking workers costs more than computing one or two cheap features. }
    MinFeaturesForParallel: Integer;
  end;

  { Result cache (CAD core). }
  TCADCacheOptions = record
    Enabled: Boolean;
    { Upper bound for cached results that are not in use (estimated bytes). }
    MaxBytes: Int64;
  end;

  { Triangulation (OCCT BRepMesh_IncrementalMesh / IMeshTools_Parameters). }
  TCADMeshOptions = record
    InParallel: Boolean;              { faces meshed on all cores }
    LinearDeflection: Double;         { mm, or a ratio of the size if Relative }
    Relative: Boolean;
    AngularDeflectionDeg: Double;
    MinSize: Double;                  { 0 = OCCT default }
    ControlSurfaceDeflection: Boolean; { False = faster on freeform surfaces }
    AllowQualityDecrease: Boolean;    { reuse a finer existing mesh }
    KeepExistingTriangulation: Boolean; { do not clean: unchanged faces keep their mesh }
  end;

  { Booleans and other BOPAlgo-based operations (OCCT). }
  TCADGlueMode = (cgmOff, cgmShift, cgmFull);

  TCADBooleanOptions = record
    RunParallel: Boolean;             { BOPAlgo_Options::SetRunParallel }
    UseOBB: Boolean;                  { oriented boxes for early rejection }
    FuzzyValue: Double;               { 0 = exact }
    Glue: TCADGlueMode;               { only when arguments share faces }
    NonDestructive: Boolean;          { keep inputs intact (cache reuse) }
    CheckInverted: Boolean;           { False when solids are known valid }
  end;

  { GPU compute jobs in the viewport (engine OpenGL.Compute.*, GL 4.3). }
  TCADGpuOptions = record
    UseCompute: Boolean;              { False = always the CPU path }
    MinItemsForCompute: Integer;      { below this the CPU path is faster }
  end;

  TCADPerformanceOptions = record
    Threads: TCADThreadOptions;
    Cache: TCADCacheOptions;
    Mesh: TCADMeshOptions;
    Booleans: TCADBooleanOptions;
    Gpu: TCADGpuOptions;
  end;

{ Interactive defaults. Change single fields after calling this. }
function DefaultPerformanceOptions: TCADPerformanceOptions;
{ Extra worker threads for the pool: total threads minus the calling one. }
function ResolveRecomputeThreads(const AOptions: TCADThreadOptions; ACpuCount: Integer): Integer;

implementation

function DefaultPerformanceOptions: TCADPerformanceOptions;
begin
  Result.Threads.RecomputeThreads := 0;
  Result.Threads.OcctThreads := 0;
  Result.Threads.MinFeaturesForParallel := 2;

  Result.Cache.Enabled := True;
  Result.Cache.MaxBytes := 512 * 1024 * 1024;

  Result.Mesh.InParallel := True;
  Result.Mesh.LinearDeflection := 0.001;   { relative: 0.1 % of the part size }
  Result.Mesh.Relative := True;
  Result.Mesh.AngularDeflectionDeg := 20.0;
  Result.Mesh.MinSize := 0.0;
  Result.Mesh.ControlSurfaceDeflection := True;
  Result.Mesh.AllowQualityDecrease := True;
  Result.Mesh.KeepExistingTriangulation := True;

  Result.Booleans.RunParallel := True;
  Result.Booleans.UseOBB := True;
  Result.Booleans.FuzzyValue := 0.0;
  Result.Booleans.Glue := cgmOff;
  Result.Booleans.NonDestructive := True;
  Result.Booleans.CheckInverted := True;

  Result.Gpu.UseCompute := True;
  Result.Gpu.MinItemsForCompute := 65536;
end;

function ResolveRecomputeThreads(const AOptions: TCADThreadOptions; ACpuCount: Integer): Integer;
begin
  if AOptions.RecomputeThreads > 0 then
    Result := AOptions.RecomputeThreads - 1
  else
    Result := ACpuCount - 1;           { the calling thread also works }
  if Result < 0 then
    Result := 0;
  if Result > 64 then
    Result := 64;
end;

end.
