# Session checkpoint (2026-10-31)

Read this first in a new session, then `docs/ENGINEERING_LOG.md` (last entries),
`docs/CODE_FLOW.md`, `docs/PERFORMANCE.md`.

## Repos and heads
| Repo | main | dev |
| --- | --- | --- |
| makeitlikepro-stack/FPC-CAD | 5074505 (old, needs user final acceptance) | 6bb739b |
| makeitlikepro-stack/FPC-OpenGL-UI-Engine | caa157a (Viewport3D, OCCT removed) | 7eb13fb |
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

## Open
1. Core test result after step 3 not reported yet (`bash scripts/test_core.sh`).
2. Parallel chains give no gain (306 vs 307 ms): OCCT booleans already use all
   cores (RunParallel). Next measure: RunParallel off + parallel chains.
3. Stage 4: FPC-CAD viewport on engine `TUIViewport3D` (OCCT mesh -> TV3DMeshData),
   GPU compute jobs with CPU fallback.
4. Engine viewport draw artifacts on the user's GPU; `cad_edge` shader frustum
   width bug (needs approval).
5. Later: sketches, Revolve, Fillet, STEP.
6. User cleanup on GitHub: delete merged `claude/*` branches (proxy returns 403).
   Undecided: IDE `claude/code-map` branch.
