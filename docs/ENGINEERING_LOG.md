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

- 2026-10-31 user run (OCCT 7.6.3, bridge builds and passes on 7.6 too): occt bridge 19/19 PASS, occt features 26/26 PASS. 8 plates x 6 holes: mesh every result (104 meshes) serial 529 / all cores 519 ms; mesh shown only (8 meshes) serial 306 / all cores 307 ms (~42% less). Parallel chains still give no gain: OCCT booleans already use all cores inside (RunParallel); to measure next: RunParallel off + parallel chains. Core test output not reported in this run. Merged to dev.

## 2026-10-31 — Stage 4 step 1: OCCT mesh -> engine viewport mesh (Candidate)
- Engine pin `engine/ENGINE_REF.txt` c43e75a -> caa157a (engine main with `TUIViewport3D`, OCCT removed).
- New `src/view/cad.view.meshconvert.pas`: `TCADRawMesh` (view on the bridge arrays), `CADConvertRawMesh` (clears + fills `TV3DMeshData`, validates counts/nil/index range, target empty on error), `CADRawMeshFromOCCT` (smooth normals, flat fallback). Face/edge ids stay OCCT 1-based map indices, so a pick element maps straight back to OCCT. Bridge edge GL_LINES pairs are joined into polylines per edge id (closed when back at the first point), so the engine stroke shader gets joins instead of caps at every tessellation node.
- Bridge Pascal: `MeshSmoothNormals` (C function existed, not bound). Without it every curved face shades faceted.
- Test `tests/view/view_mesh_tests.lpr` + `scripts/test_view.sh` (`ENGINE_DIR`, warns on a commit other than ENGINE_REF): pure part (surface copy, ids, open/closed/gap/zero-length edges, errors, 640k vertex INFO) and OCCT part (box 30x20x10: counts, faces 1..6, bounds, 12 edge polylines, edge ids 1..12; cylinder: closed circles, bounds). NOT RUN here (no FPC: apt has no fp-compiler).
- 2026-10-31 user run: `bash scripts/test_view.sh` 36/36 PASS, first compile (engine next to FPC-CAD). Convert 640k vertices / 320k triangles / 400 edge segments: 31 ms. Cylinder: 840 vertices, 280 triangles, 2 edge polylines, both closed (seam hidden). Merged to dev.

## 2026-10-31 — Stage 4 step 2: document -> viewport sync (Candidate)
- `src/view/cad.view.sync.pas`: `TCADViewTarget` (abstract: MeshFor, SetObjectVisible, Changed), `TCADMeshFiller`, `TCADViewSync.Sync` (report: Updated, Shown, Hidden, Unchanged, Failed, ms). Object id = slot + 1 (`ObjectIdOf` / `FeatureOf`). A result is converted only when the pointer or cache key differs from the last converted one; hide/show flips visibility only; a filler failure hides the object, keeps `LastError` and retries on the next Sync. UI thread, after Recompute.
- `CADFillMeshFromResult` in MeshConvert (OCCT shape result -> mesh; the only type check, in the view layer).
- `src/view/cad.view.viewporttarget.pas`: target on `TUIViewport3D` (FindObject / AddObject with the given id, starts hidden, Invalidate3D). Engine has no RemoveObject: a removed feature keeps a hidden object. Compiled only with the full engine (step 3 app); not in the tests.
- Test `tests/view/view_sync_tests.lpr` (fake target + fake results, no OCCT/GL): first sync only the chain end, no-op sync without redraw, param change, csmShow mid-tree, hide/show without converting, filler failure + retry, detach, Reset, id mapping. Added to `scripts/test_view.sh`. NOT RUN here (no FPC).
- 2026-10-31 user run: `bash scripts/test_view.sh` view mesh 36/36 PASS (640k vertices 28 ms), view sync 17/17 PASS, first compile. Merged to dev.

## 2026-10-31 — Stage 4 step 3: first FPC-CAD window with the OCCT model (Candidate)
- `app/fpc_cad.lpr` + `app/fpc_cad.lpi` (LCL + LazOpenGLContext, engine units from the sibling `../FPC-OpenGL-UI-Engine`, target `./fpc_cad` in the repo root so the bridge is found). `scripts/build_app.sh` (bridge + lazbuild, engine pin warning).
- `src/app/cad.app.demoscene.pas`: plate 60x40x10 minus a 3x2 grid of holes (6 chained cuts), `SetHoleRadius`.
- `src/app/cad.app.mainform.pas`: `TUIHostControl`, `TUIViewport3D` (edges on) fed by `TCADViewSync` + `TCADViewportTarget` + `CADFillMeshFromResult`; side panel: radius slider (SetParam x6 -> Recompute -> Sync), selection/hover as feature name + OCCT face/edge index, timing lines (recompute, computed/cache hits, meshes + ms, sync ms + converted); status line with OCCT version or the error. Destroy order: sync, target, document, host, bridge.
- First GPU use of `CAD.View.ViewportTarget`. NOT BUILT here (no FPC/Lazarus).
- 2026-10-31 user GUI run: builds and runs, OCCT 7.6.3; slider fast (recompute 0 ms on cache hits, sync 1 ms); pick shows "Cut 6, face 2". Bugs: (1) viewport drawn shifted to the lower right and panel lines in the wrong order — cause: `X/Y` are centre offsets from the parent centre (Y up), not top-left; children keep centre offsets when the parent resizes. Fix: `Layout` places every widget with Width/Height then Left/Top, parents first. (2) small breaks in edge strokes near the plate corners/silhouettes: open, compare with the engine `--viewport3d-lab` (open item 4: viewport draw artifacts on the user GPU).
- 2026-10-31 user GUI rerun: layout fixed (viewport left, panel lines in order). Edge breaks also appear in the engine `--viewport3d-lab` (silhouette edge thins/breaks where the face meets the background): engine issue, not the converter. Step 3 merged to dev; edge fix goes to the engine.
- 2026-10-31 user run on dev (after stage 3 step 3): `bash scripts/test_core.sh` 80/80 PASS; 8 x 40 ms features serial 321 ms, 4 threads 81 ms.
