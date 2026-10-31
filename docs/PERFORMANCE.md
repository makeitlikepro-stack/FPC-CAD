# FPC-CAD performance foundation

Speed is a design rule, not a later optimisation. This file says where speed
comes from, which knobs exist, and where each knob lives in code. All knobs are
fields of `TCADPerformanceOptions` (`src/config/cad.config.performance.pas`).

## 1. Where the time goes in a parametric CAD

| Work | Runs on | How we keep it fast |
| --- | --- | --- |
| Find a feature by id | CPU | `TCADId` is an array index: O(1), no search |
| Find what must recompute | CPU | dependency graph in arrays, visit stamps instead of clearing |
| Recompute features | CPU threads | independent features run in parallel (levels) on a persistent pool |
| Skip unchanged features | CPU | result cache: key = hash(params) + keys of inputs |
| Undo / Redo | CPU | restores parameters; results come back from the cache, no OCCT call |
| Boolean, fillet, extrude | OCCT (CPU) | OCCT parallel mode, OBB, fuzzy and glue options (section 3) |
| Triangulation | OCCT (CPU) | parallel `BRepMesh_IncrementalMesh`, deflection knobs, keep existing mesh |
| Bounds, normals, culling, picking reductions, distance queries | GPU compute | compute shader when available and the data is big enough, CPU otherwise (section 4) |
| Drawing | GPU | the engine `TUIViewport3D`: renders only when dirty |

## 2. Recompute pipeline (core)

1. An edit (always a command, see `docs/CODE_FLOW.md`) changes parameters or links.
2. `TCADDependencyGraph.CollectDirty` walks only the users of the changed
   features (O(changed subgraph), not O(document)).
3. `TCADRecomputePlan` sorts the dirty set into **levels**. A level holds features
   that do not depend on each other.
4. `TCADWorkerPool` runs one level in parallel. Threads are created once and
   reused; the calling thread also works.
5. Before computing, each feature builds its **cache key**. If the key equals the
   key of its current result, or the cache holds a result for it, nothing runs.

Rules that keep this safe:
- During a recompute the document is read-only. A feature only reads its inputs'
  results (immutable once stored) and writes its own result.
- Exceptions inside `Compute` are caught per feature; a failed feature blocks its
  users, other branches continue.

## 3. OCCT speed knobs (used by the OCCT adapter, stage 3)

| Option field | OCCT API | Effect |
| --- | --- | --- |
| `Mesh.InParallel` | `IMeshTools_Parameters::InParallel` | faces triangulated on all cores |
| `Mesh.LinearDeflection`, `Mesh.Relative` | `Deflection`, `Relative` | coarser = faster; relative scales with part size |
| `Mesh.AngularDeflectionDeg` | `Angle` | curvature detail |
| `Mesh.MinSize` | `MinSize` | stops tiny triangles on small features |
| `Mesh.ControlSurfaceDeflection` | `ControlSurfaceDeflection` | off = faster, slightly less accurate on freeform |
| `Mesh.AllowQualityDecrease` | `AllowQualityDecrease` | reuse a finer existing mesh instead of remeshing |
| `Mesh.KeepExistingTriangulation` | (skip `BRepTools::Clean`) | unchanged faces are not remeshed |
| `Booleans.RunParallel` | `BOPAlgo_Options::SetRunParallel` | parallel intersection |
| `Booleans.UseOBB` | `SetUseOBB` | oriented boxes reject non-touching pairs early |
| `Booleans.FuzzyValue` | `SetFuzzyValue` | tolerance for near-coincident input (robustness, sometimes speed) |
| `Booleans.Glue` | `SetGlue(BOPAlgo_GlueShift/GlueFull)` | big speed-up when arguments only share faces |
| `Booleans.NonDestructive` | `SetNonDestructive` | keeps inputs intact so the cache can reuse them |
| `Booleans.CheckInverted` | `SetCheckInverted` | off saves a check when solids are known valid |
| `Threads.OcctThreads` | `OSD_ThreadPool::DefaultPool(n)` | cores given to OCCT (0 = all) |

The C bridge passes these as one plain record, so the app can change them at runtime.

## 4. GPU compute (engine `OpenGL.Compute.*`, OpenGL 4.3, optional)

The base renderer needs only OpenGL 3.3. Compute is used when
`QueryComputeCapabilities.Supported` is true **and** the job is larger than
`Gpu.MinItemsForCompute` (small jobs are faster on the CPU than a GPU round trip).
Every GPU path has a CPU path with the same result (tested against each other).

Planned compute jobs (stage 4, viewport):
- bounding boxes of many meshes (parallel reduction) for fit-all and culling;
- vertex normals and edge feature angles for imported meshes (STL);
- frustum culling of large assemblies (one dispatch, indirect draw list);
- box selection: reduce the pick ID target to the set of picked ids;
- point-to-mesh distance for measurement and clash preview.

OCCT modelling itself (booleans, fillets, meshing) cannot run on the GPU.

## 5. Measuring

`TCADRecomputeReport` returns planned, computed, cache hits, failed, blocked,
levels, threads and milliseconds for every recompute. Tests assert that a
parallel level is faster than the serial run on a multi-core machine.
