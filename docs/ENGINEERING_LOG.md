# Engineering log (append only)

## 2026-10-31 — Stage 2: speed-first core (Candidate)
- User request: base everything on speed; use compute shaders where they help; expose OCCT speed options; clear comments, clear folders, traceable flow.
- `src/config/cad.config.performance.pas`: all knobs (recompute threads, cache, OCCT mesh + boolean options, GPU compute thresholds).
- `src/core`: ids (array slots, never reused), values + FNV-1a hash, feature base + result base, registry, dependency graph (arrays, visit stamps), recompute plan (Kahn levels on the dirty subgraph), worker pool (persistent threads, atomic work index), result cache (key = params hash + input keys, LRU of unused results), document (recompute + report), commands (set param with merge, add, remove, link), history (undo/redo, depth limit).
- Docs: PERFORMANCE.md (where speed comes from, OCCT API per knob, honest GPU scope: OCCT modelling stays on the CPU), CODE_FLOW.md (folders, unit header, traces), CODE_MAP.md.
- Tests: `tests/core/cad_core_tests.lpr` (ids/hash, registry, graph/plan, recompute + cache, cache limit, undo/redo incl. merged drag and stable ids, failures and blocking, parallel speed 8 x 40 ms, 50 x 200 thread stress, options). NOT RUN here (no FPC in the authoring environment); user runs `bash scripts/test_core.sh`.
- 2026-10-31 user native run: `bash scripts/test_core.sh` 69/69 PASS, first compile. Parallel level: serial 321 ms, 4 threads 81 ms (8 x 40 ms features, ~4x). Merged to dev.

## 2026-10-31 — Stage 3 step 1: OCCT bridge moved here + speed options (Candidate)
- User decision: the OCCT bridge belongs to FPC-CAD. Copied unchanged from engine main 5982eef (first commit), then changed. Removing it from the engine is a separate engine step (engine src/cad OCCT units and tools depend on it).
- `occt_bridge_options.h` (88-byte C struct, doubles then int32, size + version check) + set/get/size functions; options applied to BRepMesh (IMeshTools_Parameters) and to the parametric cut (BRepAlgoAPI options); OCCT thread pool size. The old per-call deflection argument still wins when > 0.
- Pascal: `src/occt/cad.occt.options.pas`, `cad.occt.bridge.pas` (dynlibs; option records passed by pointer, not const record, because cdecl may pass const records by value).
- Checks here: `g++ -fsyntax-only -Wall` of occt_bridge.cpp against OCCT 7.8.1 headers (from the OCCT GitHub tag; headers only, nothing built): 0 errors, 0 warnings, after fixing one real error (`deflection` still used in TessellateShape). C struct measured with gcc: 88 bytes, doubles at 8..32, ints at 40..84.
- Native test `tests/occt/occt_bridge_tests.lpr` + `scripts/test_occt.sh`: ABI offsets, mapping, round trip, mismatch rejected, prism volume 6000, cut volume 6000 - pi*4*30, non-destructive cut, INFO meshing time InParallel off/on. NOT RUN here (no FPC, no OCCT libraries).
- 2026-10-31 user run: bridge built with system OCCT 7.8 (libTK*.so.7.8). Pascal: `Fatal: identifier expected but LIBRARY found` — `Library` is a reserved word, not allowed as a unit name part. Renamed CAD.OCCT.Library -> CAD.OCCT.Bridge.
- 2026-10-31 user run: `bash scripts/test_occt.sh` 19/19 PASS, OCCT 7.8.1. Fine mesh x5: InParallel off 156 ms, on 63 ms (~2.5x). Merged to dev.

## 2026-10-31 — Stage 3 step 2: OCCT features on the core (Candidate)
- Engine side done: bridge + OCCT units removed from the engine (engine main caa157a, user build PASS).
- Bridge: `occt_bridge_make_box`, `_make_cylinder`, `_boolean` (cut/fuse/common with all speed options), `_shape_volume`. Thread safety: one `std::shared_mutex` — meshing exclusive (it writes Poly_Triangulation into TFaces shared with boolean inputs), modelling shared. `g++ -fsyntax-only -Wall` vs OCCT 7.8.1 headers: 0 errors, 0 warnings.
- Pascal: `CAD.OCCT.ShapeResult` (result owns shape + mesh handles, size estimate from the mesh), `src/features/` (`CAD.Features.OCCTBase`, `.Box`, `.Cylinder`, `.BooleanOp`), global `OCCT` accessor, `Mesh.MeshInRecompute` option (default on). Unit names scanned for reserved words.
- Test `tests/occt/occt_features_tests.lpr` (run by `scripts/test_occt.sh`): volumes (cut, fuse 9000, common 3000), partial recompute, undo from the cache (0 OCCT calls), error text and blocking, 8 chains x 6 booleans serial vs all cores (INFO) with correct volumes. NOT RUN here.
- 2026-10-31 user run: occt bridge 19/19 PASS, occt features 17/17 PASS (OCCT 7.8.1). Parallel chains: serial 650 ms, all cores 633 ms — little gain: OCCT ops already run parallel inside (RunParallel, InParallel) and every intermediate boolean result is meshed under the exclusive mesh lock. Next: mesh only results that are displayed (leaf features). Merged to dev.

## 2026-10-31 — Stage 3 step 3: mesh only shown results (Candidate)
- Cause: 8 chains x 6 booleans gained little from parallel recompute (650 vs 633 ms); every intermediate result was meshed under the exclusive mesh lock (104 meshes, 8 shown).
- New `CAD.Core.DisplayPass`: after the levels, meshes only shown results (end of a chain, or `ShowMode = csmShow`; `csmHide` never). Serial on the calling thread (exclusive mesh lock, InParallel inside). Cached results keep their mesh.
- `TCADResult`: `DisplayReady` / `PrepareDisplay` (virtual, default no-op), `AccountedBytes`; cache counts bytes once and `Remeasure` updates totals when a mesh is added (before, `EstimatedBytes` changed after store and totals could drift).
- `TCADFeature.ShowMode`, `DisplayError`; document `SetShowMode`, `IsShown`, `PrepareDisplay`, `NeedsDisplay`; report `Display` (Shown, Prepared, Failed, ms). Detach marks the display pass (inputs become chain ends).
- Option `Mesh.MeshInRecompute` replaced by `Mesh.Timing` (`cmtDisplayed` default, `cmtEveryResult` old behaviour, `cmtManual`).
- Tests: core `TestDisplayPass` (chain end only, csmShow mid-tree, attach/detach end, manual mode, cache bytes +2000); OCCT features: inputs of a cut not meshed, undo keeps the mesh, csmShow without model recompute, chains INFO every result vs shown only (8 meshes). NOT RUN here (no FPC).

