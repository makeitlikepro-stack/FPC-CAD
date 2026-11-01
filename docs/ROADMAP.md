# FPC-CAD Roadmap

Each stage ends with a headless test and an acceptance note. `main` is updated
only after the user accepts a stage.

- **Stage 1 (done):** architecture, engine pin, repository layout.
- **Stage 2 (user PASS 69/69):** `src/core` document model, feature interface, command
  stack (Undo/Redo), dependency graph, parallel recompute levels, result cache,
  performance options (OCCT, threads, GPU). Headless unit tests.
- **Stage 3:** OCCT adapter: box, cylinder, extrude of a rectangle profile,
  boolean cut. Mesh export to the engine's vertex format.
- **Stage 4:** viewport on the engine `TUIViewport3D`: shaded view, pick faces and
  edges; GPU compute jobs (bounds, culling, box select) with CPU fallback.
- **Stage 5:** sketch with constraints (2D solver), Revolve, Fillet, Chamfer.
- **Stage 6:** STEP import and export, feature tree editing with rebuild.

## Current priority: CAD object model foundation (design candidate)

After the user-approved Sketch/Trim/Selected-Contours/Extrude development and
the Viewport3D color-filter fix, **pause new modelling features** until the
Document has first-class logical entities.

1. **Design gate (this branch):** `OBJECT_MODEL_DESIGN.md` and
   `OBJECT_MODEL_TEST_PLAN.md`: ownership, IDs, Body tips, typed Sketch and
   Datum references, migration and regression gates. Documentation only.
2. **Core registry gate:** pure FPC `Part`, `Body`, `SketchObject`,
   `DatumPlane` and nonreused `ObjectId`; command-driven atomic mutations;
   headless tests OM-001..012. No GUI or OCCT modification.
3. **Evaluation gate:** Body tip management, Feature graph isolation and
   atomic history, then the Sketch compatibility adapter. Existing feature
   and cache tests must remain PASS.
4. **Presentation and persistence gate:** proper Feature Tree, Body-based
   viewport identity and versioned project Save/Load. Preserve legacy
   `FPCSKETCH 1/2` payloads.
5. **Topology references gate:** persistent Face/Edge selection semantics
   and ambiguity reporting before advanced Fillet/Chamfer parametrization.

The existing Stage 5/6 ideas (Revolve, Fillet, Chamfer, STEP, etc.) remain
backlog, **not architectural prerequisites**. Do not implement them to work
around missing Body ownership.

## Known risks

- Topological naming: references to faces/edges must survive rebuilds.
- OCCT ABI: keep the C bridge as the only boundary.
- Build verification: FPC and OCCT must be installed on the user's machine;
  the authoring environment cannot compile Pascal.
