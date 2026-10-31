# Session checkpoint (2026-10-31)

Read this first in a new session, then `docs/ENGINEERING_LOG.md` (last entries),
`docs/CODE_FLOW.md`, `docs/PERFORMANCE.md`.

## Repos and heads
| Repo | main | dev |
| --- | --- | --- |
| makeitlikepro-stack/FPC-CAD | 5074505 (old, needs user final acceptance) | fad413b (stage 4 steps 1-3) |
| makeitlikepro-stack/FPC-OpenGL-UI-Engine | caa157a (Viewport3D, OCCT removed; FPC-CAD pin) | 7eb13fb (parked: `claude/edge-depth-bias` 4ec6764) |
| FPC-Visual-IDE | cb7d74d (Viewport3D in palette) | 660a8bc |

User paths: FPC-CAD at `/home/mehdi/Documents/lazarus projects/FPC-CAD` (latest run;
earlier `/home/mehdi/Documents/Projects/lazarus/All_projects_that_I_need/FPC-CAD`).
System OCCT 7.6.3 (bridge also checked against 7.8.1 headers).

## Workflow rules (user)
- Reply in Persian, short. Work on `claude/<topic>`, merge to `dev` after user PASS,
  `main` only after final acceptance. No CI. User compiles/tests: give exact terminal
  commands. Candidate until tested, never fake PASS. One commit per step.
- No FPC/OCCT in the authoring container: never build OCCT here; header-only
  `g++ -fsyntax-only` checks are fine.
- Engine: no CAD/OCCT in the UI core, no type-specific branches. IDE: units
  150-400 lines (max 650), methods < 90 lines, Tabler icons via tools/icons.

## Done (FPC-CAD)
- Stage 2 core: ids, graph, Kahn levels, worker pool, result cache, commands,
  undo/redo, performance options. Core tests 69/69 PASS (before step 3).
- Stage 3: OCCT bridge in `external/occt_bridge` (options struct, shared_mutex:
  mesh exclusive, modelling shared), Box/Cylinder/Boolean features.
- Step 3 display pass (`CAD.Core.DisplayPass`, `Mesh.Timing`, ShowMode,
  cache Remeasure): occt bridge 19/19, occt features 26/26 PASS.
  8x6 holes: 529 ms -> 306 ms. Commands:
  `bash scripts/test_core.sh` and `bash scripts/test_occt.sh`.

- Stage 4 steps 1-3: `src/view` (MeshConvert: OCCT mesh -> TV3DMeshData, edge
  polylines joined, smooth normals; Sync: shown results -> viewport objects,
  id = slot + 1; ViewportTarget), `src/app` + `app/fpc_cad.lpi` (plate with 6
  holes, radius slider, pick shows OCCT face/edge index, timings).
  `bash scripts/test_view.sh`: view mesh 36/36, view sync 17/17 PASS; GUI runs
  (`bash scripts/build_app.sh && ./fpc_cad`). Engine widgets: place with
  Left/Top (X/Y are centre offsets, Y up).

- Stage 5 steps 1-3 (sketcher): `src/sketch` (model, 25 constraint kinds,
  LM minimum-norm solver with DOF/redundant/conflict, profiles with holes,
  text format), `Sketch` + `Extrude` features, bridge planar faces / extrude /
  area. Tests: `bash scripts/test_sketch.sh` 75/75, `bash scripts/test_occt.sh`
  (bridge 19, features 26, sketch 20) PASS. FPC may evaluate call arguments
  right to left: never rely on nested AddPoint order.

## Open
1. (done) Core tests after step 3: 80/80 PASS.
2. Parallel chains give no gain (306 vs 307 ms): OCCT booleans already use all
   cores (RunParallel). Next measure: RunParallel off + parallel chains.
3. Stage 4 step 4: GPU compute jobs with CPU fallback.
4. Viewport3D edge breaks on the user's GPU (silhouettes/grazing): edge depth
   bias tried (engine `claude/edge-depth-bias`, Mesa PASS) - did not fix it on
   the user GPU; parked by the user, not merged. `cad_edge` frustum width bug.
5. Next: interactive sketch editor in the app (stage 5 step 4); later
   Revolve, Fillet, STEP; sketch on a model face.
6. User cleanup on GitHub: delete merged `claude/*` branches (proxy returns 403).
   Undecided: IDE `claude/code-map` branch.
