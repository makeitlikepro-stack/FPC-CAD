# FPC-CAD Architecture (Stage 1)

## Layers (dependency flows downward only)

0. `src/config/` settings records (all speed knobs). No dependencies.
1. `src/core/` pure model: document, features, parameters, dependency graph,
   command stack (Undo/Redo). No LCL, no OpenGL, no OCCT. Headless testable.
2. `src/occt/` adapter: wraps the OCCT C ABI bridge (`libocct_bridge`), converts
   shapes and meshes into plain data. Only layer that knows OCCT handles.
3. `src/app/` shell and viewport: uses the pinned UI engine (`engine/ENGINE_REF.txt`).
   Engine core never imports CAD code (engine rule 3).

## Rules

- One main class per unit; units target 150–400 lines (hard cap 650).
- Methods target 40–50 lines (hard cap 90).
- Features are plugins: each feature type is its own unit with `Compute()`;
  the document only calls the feature interface.
- Feature references use stable IDs, not raw topology indices, so edits do not
  silently re-point to wrong faces (topological naming is an open risk, see ROADMAP).
- Every mutation goes through a command object so Undo/Redo stays correct.
- Build resolves the pinned engine commit; never compile against a moving HEAD.
- A logical Part/Body/Sketch/Datum object has an ID independent of Feature slot
  IDs and OCCT Shape handles. `CAD.Core.ObjectModel` owns logical objects,
  while `CAD.Core.ResultCache` continues owning evaluated results.
- The new Document `Objects` registry is headless and initially separate
  from the UI Feature Tree. Body tip / operation target semantics are **not
  implemented** in this gate.
- See [OBJECT_MODEL_DESIGN.md](OBJECT_MODEL_DESIGN.md) and
  [OBJECT_MODEL_TEST_PLAN.md](OBJECT_MODEL_TEST_PLAN.md).

## Status

- Stage 1: documentation and engine pin.
- Stage 2 (Candidate): `src/core` + `src/config`, speed foundation
  (docs/PERFORMANCE.md), call flow (docs/CODE_FLOW.md), headless tests
  `bash scripts/test_core.sh`. Not compiled in the authoring environment.
