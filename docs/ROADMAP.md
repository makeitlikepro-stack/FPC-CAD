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

## Known risks

- Topological naming: references to faces/edges must survive rebuilds.
- OCCT ABI: keep the C bridge as the only boundary.
- Build verification: FPC and OCCT must be installed on the user's machine;
  the authoring environment cannot compile Pascal.
