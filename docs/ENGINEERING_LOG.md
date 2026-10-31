# Engineering log (append only)

## 2026-10-31 — Stage 2: speed-first core (Candidate)
- User request: base everything on speed; use compute shaders where they help; expose OCCT speed options; clear comments, clear folders, traceable flow.
- `src/config/cad.config.performance.pas`: all knobs (recompute threads, cache, OCCT mesh + boolean options, GPU compute thresholds).
- `src/core`: ids (array slots, never reused), values + FNV-1a hash, feature base + result base, registry, dependency graph (arrays, visit stamps), recompute plan (Kahn levels on the dirty subgraph), worker pool (persistent threads, atomic work index), result cache (key = params hash + input keys, LRU of unused results), document (recompute + report), commands (set param with merge, add, remove, link), history (undo/redo, depth limit).
- Docs: PERFORMANCE.md (where speed comes from, OCCT API per knob, honest GPU scope: OCCT modelling stays on the CPU), CODE_FLOW.md (folders, unit header, traces), CODE_MAP.md.
- Tests: `tests/core/cad_core_tests.lpr` (ids/hash, registry, graph/plan, recompute + cache, cache limit, undo/redo incl. merged drag and stable ids, failures and blocking, parallel speed 8 x 40 ms, 50 x 200 thread stress, options). NOT RUN here (no FPC in the authoring environment); user runs `bash scripts/test_core.sh`.
