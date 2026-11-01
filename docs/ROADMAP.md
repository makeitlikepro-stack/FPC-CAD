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

## Current priority: real CAD Object Model

- **Design reviewed:** [Object model contract](OBJECT_MODEL_DESIGN.md)
  and [test plan](OBJECT_MODEL_TEST_PLAN.md).
- **Gate A candidate (this feature branch):** separate durable object IDs,
  document-owned Part/Origin/XY-XZ-YZ Datum/Body/Sketch registry,
  typed lookups, safe tombstones and existing History commands.
  Headless regression `cad_object_model_tests` is now part of
  `scripts/test_core.sh`; user FPC compilation and PASS remain pending.
- **Next gate:** connect Body tip to Feature history and dependency graph;
  preserve the feature-result cache, old Sketch payloads and undo semantics.
- **Later:** migrate Sketch data authority and tree/viewport to authoritative
  Body/Sketch identities; implement versioned document save/load and
  topological reference provenance before Fillet/Chamfer expansion.

Existing modelling tools remain functional; no new UI/OCCT features are
introduced by the foundation gate.

## Known risks

- Topological naming: references to faces/edges must survive rebuilds.
- OCCT ABI: keep the C bridge as the only boundary.
- Build verification: FPC and OCCT must be installed on the user's machine;
  the authoring environment cannot compile Pascal.
