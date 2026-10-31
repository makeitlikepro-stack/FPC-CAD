# FPC-CAD Architecture (Stage 1)

## Layers (dependency flows downward only)

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

## Status

Stage 1 is documentation and project pin only. No compiled code yet; FPC and
OCCT builds have not been run (Candidate).
