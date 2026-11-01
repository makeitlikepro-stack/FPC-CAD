# Object Model — Headless Acceptance Matrix

**Status:** Gate A headless registry tests added in `tests/core/cad_object_model_tests.lpr`, not yet compiled/run by the authoring environment. The deeper cross-Part/compound-transaction/OCCT scenarios are pending.
**Target runtime:** FPC 3.2.2, Lazarus 3.4 (GUI only in later gates). No GitHub Actions.
**Baseline gate:** run `bash scripts/test_core.sh`, `bash scripts/test_sketch.sh`, `bash scripts/test_occt.sh`, `bash scripts/test_view.sh` before and after each migration step. Keep all existing tests PASS.

## A. Model registry — FIRST IMPLEMENTATION GATE

This foundation branch adds the new registry, object IDs and headless tests **without changing** Sketch, Extrude, OCCT ABI, UI or serialization.

| ID | Scenario | Required assertion |
| --- | --- | --- |
| OM-001 | Create a Document and default Part | Exactly one Part, one Origin frame and XY/XZ/YZ immutable base Datum planes; all distinct nonzero ObjectIds. |
| OM-002 | Create two Bodies in the same Part | IDs are distinct; Part membership and lookup by typed ID are correct. |
| OM-003 | Delete Body A, then create Body C | C never reuses A's ID. A stale reference fails; B remains unchanged. |
| OM-004 | Lookup BodyId as Sketch/Datum | Reject with explicit wrong-kind error; never return any arbitrary object. |
| OM-005 | Create Sketch attached to XY Datum | Sketch retains its own ObjectId, support DatumId, PartId, and local plane transform without OCCT. |
| OM-006 | Attempt Sketch support from other Part, or missing/deleted Datum | Mutation fails atomically with an exact reason; previous membership remains. MVP rejects cross-Part supports. |
| OM-007 | Rename Body and change visibility | No new ObjectId or OCCT shape allocation; unrelated objects unchanged. |
| OM-008 | Remove referenced Datum, Body or Sketch | No dangling reference; either reject or use an explicit, audited cascade transaction. Never silently delete downstream work. |
| OM-009 | Undo Create/Delete/Rename/Visibility; then Redo | All identities, parent membership, ordered object lists, names and flags return exactly. Redo does not allocate new ObjectIds. |
| OM-010 | Repeat atomic edit with invalid reference mid-operation | Registry and feature graph snapshots before/after are identical; Undo stack is not polluted. |
| OM-011 | Create 1000 objects, delete every other, then create 100 more | IDs are unique/nonzero; dead slots never resolve to another object, and lookups are deterministic. |
| OM-012 | Create Part/Body/Datum core model without OCCT/LCL/OpenGL loaded | Compilation and all tests succeed on headless FPC (pure core boundary). |

Gate A release threshold: all **applicable** OM-001..012 assertions and the existing core suite PASS; code remains OCCT/LCL/GL-free. OM-006 cross-Part validation is deferred because the MVP deliberately creates one Part per document. OM-010 currently covers an atomic single-object failure; multi-feature transactional rollback is a separate gate. Do not claim these as tested before a real local FPC run.

## B. Body tip, graph and recompute — SECOND GATE

| ID | Scenario | Required assertion |
| --- | --- | --- |
| OM-101 | Body001 has Tip Extrude001; new Fillet001 added | BodyId unchanged, tip changes to Fillet001, earlier output stays cache-owned. |
| OM-102 | Edit Sketch001 used by Body001 | Only affected Feature dependants recompute; Body002 with no relationship unchanged. |
| OM-103 | Undo Fillet001 then Redo | Tip restores to Extrude001 then Fillet001 with the *same* BodyId/FeatureIds. |
| OM-104 | Failed Fillet/Extrude validation or OCCT compute | Body survives, error state visible, no accidental replacement or leaked cached handle. |
| OM-105 | Cross-Body boolean | Target Body tip changes, tool Body ID/tip remain untouched; graph cycle check is enforced. |
| OM-106 | Delete Body referenced by another active operation | Reject with dependant summary, or explicitly confirmed cascade; no partial graph remains. |
| OM-107 | Change Body visibility | View dirty only; no model geometry recompute or fresh OCCT shape; independent Bodies remain visible. |
| OM-108 | Features with same cached immutable result in two Bodies | Undo/deleting one Body cannot free the result needed by the other; cache use counts stay consistent. |
| OM-109 | Feature graph input order vs chronological Part history | The two sequences are independently queryable and correct. The GUI must not infer history by graph leaves. |
| OM-110 | Old model feature graph constructed without Bodies | Legacy tests still pass; migration adapter creates logical Bodies only where explicit semantics exist. |

Gate B: document invariants plus `scripts/test_core.sh` and relevant OCCT feature tests; benchmark cache hits/recompute unchanged for existing simple models.

## C. Sketch object, document format and UI — LATER GATES

| ID | Scenario | Required assertion |
| --- | --- | --- |
| OM-201 | Sketch references XY, then user-offset Datum | Re-evaluation respects the correct local-to-world transform, without changing Sketch identity. |
| OM-202 | Two Extrude features refer to one Sketch object | Both recompute from the same geometry revision; no duplicate geometry source diverges. |
| OM-203 | Edit a Sketch while its feature is shared | Geometry change is atomic; both dependants are dirtied; undo restores exact old constraints and profile. |
| OM-204 | Legacy `FPCSKETCH 1` / `2` data | Load into migration adapter without losing inactive entities, constraints or plane; round-trip and solver tests PASS. |
| OM-205 | Versioned project file save/load | Preserve ObjectIds, FeatureIds or explicit remapping, Part tree, Body tips, supports, feature parameters and history. |
| OM-206 | Save/load/recompute with empty Body and failed Feature | Registry persists, invalid evaluation is reported; file still loads. |
| OM-207 | Three Body solids in Viewport | Selection maps `ViewObjectId -> BodyId`; no ambiguity with feature-slot IDs or old hidden feature meshes. |
| OM-208 | Multi-body independent solids | One Body per connected solid at final migration; earlier compound/legacy shape remains readable until migration is accepted. |
| OM-209 | Select Face for Fillet, edit upstream Sketch | Subshape reference is either correctly remapped by topology provenance or marked ambiguous; never silently picks a different face. |
| OM-210 | Feature Tree expand/collapse and reorder | UI navigation does not mutate model identity or dependency graph; logical Part/Body/Sketch/Datum objects have stable Tree tags. |
| OM-211 | Mixed operations with Undo/Redo and Save/Load | No orphan features, duplicate Body IDs, stale Datum supports, wrong tips or result handle double frees. |

### Exact initial regression fixture

```text
Document
  Part001
    XY Datum (id: D1)
    Sketch001 (id: S1, support: D1)
    Body001 (id: B1, tip: Extrude001)
    Body002 (id: B2, tip: Extrude002)
  Feature graph
    Sketch001Evaluator -> Extrude001
    Sketch002Evaluator -> Extrude002

Operations:
  change Sketch001 -> recompute Body001 only
  add Fillet001 on Body001 -> tip = Fillet001, B1 still B1
  undo -> tip = Extrude001
  redo -> tip = Fillet001
  remove Body001 -> must not modify Body002
```

### Engineering acceptance protocol

1. Each feature branch starts from updated `dev`, implements **one gate** and adds headless tests before altering the GUI.
2. Report exact test command, PASS/FAIL counts, FPC compile errors, regression fixtures and the GitHub commit.
3. User tests on local Ubuntu / OCCT; only after user PASS fast-forward `dev` then `main`. No force push; feature branch deletion only after user approval.
4. If a gate needs a nontrivial schema change, document an explicit compatibility adapter and migration test first.
5. Never rely on screenshots alone to validate object ownership, cache lifetime or undo correctness.

## Not covered by this foundation implementation

The new logical-object Pascal units and headless tests are present, but are **not yet confirmed compiled/executed with FPC 3.2.2**. There is still no project loader/saver, geometry ownership migration, feature-tip link, UI tree rework, or OCCT/GUI change. No GitHub Actions workflow is to be introduced. The next gate is local compilation, regression testing and user acceptance before merging.
