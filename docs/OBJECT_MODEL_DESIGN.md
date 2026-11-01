# CAD Object Model — Architecture Contract (Design Candidate)

**Status:** APPROVED DESIGN CONTRACT. First implementation candidate adds a headless logical registry; full Body-tip/Sketch geometry migration, UI and file format remain future work.
**Baseline:** `dev` / `main` at `98b91768c8dbb5a46fee6fe7ca096acd7587ea38`.
**Objective:** Give Sketch, Body, Part and Datum entities real, durable identities and explicit relationships, while keeping the existing FPC recompute engine and OCCT bridge intact.

## 1. Observed baseline: what exists

These observations were verified against the current units, not inferred from the Feature Tree.

| File | Present behavior | Architectural consequence |
| --- | --- | --- |
| `CAD.Core.Document` | Owns an array of `TCADFeature` slots. IDs are slot-based and not reused. Also owns dependency graph, recompute planner, worker pool and result cache. | Robust calculation infrastructure; **no Part/Body/Datum/Sketch-object registry yet**. |
| `CAD.Core.Feature` | `TCADFeature` has parameters, ordered feature dependencies and a cached `TCADResult`. | A computation step is being used as the only model entity. |
| `CAD.Features.Sketch` | The entire sketch is a `geometry` text parameter, and `Compute` returns OCCT planar faces. | Sketch editing data and its evaluated profile are not separate document objects. |
| `CAD.Sketch.Model` | `TCADSketch` already owns points, entities, constraints, local plane and revision. | Reuse its solver and editing geometry; do **not** rewrite it. |
| `CAD.Features.Extrude` | Takes an input shape (faces) and produces another shape (solid). | No explicit target Body, New Body / Add / Cut / Intersect mode, or stable Body identity. |
| `CAD.Features.BooleanOp` | Takes two feature result shapes. | Input ordering works, but Body ownership/target semantics are implicit. |
| `CAD.OCCT.ShapeResult` | Owns OCCT shape/mesh handles; the result cache owns result objects. | Keep these as ephemeral, immutable **evaluation results**, not document-owned Body objects. |
| `CAD.App.FeatureTree` | Synthesizes `Part1`, three planes and Origin as UI nodes; places endpoint features and dependencies under them. | Tree *resembles* a CAD document but is not a projection of real Part/Body/Datum entities. |
| `CAD.Core.History` | Command undo/redo for feature changes; detaching/reattaching a feature can preserve its slot ID. | Extend the command/transaction layer for Object changes; do not build a parallel undo system. |
| `CAD.View.Sync` | Maps visible feature slot `n` to viewport object `n+1`. | Body-based display and selection need an explicit mapping; do not change this in the first model-only patch. |
| Project persistence | `CAD.Sketch.Text` serializes the sketch parameter; no document-wide Part/Body persistence layer was found. | A new versioned file format requires separate design and migration tests. |

**Separation rule:** a Body is *the persistent design entity*, an OCCT `TopoDS_Shape` is *one evaluated geometry revision*; a Feature is *the operation that computes it*. These three must never be treated as interchangeable IDs.

## 2. Model tree and computation graph are different views

Logical CAD object hierarchy (future document-owned entities):

```text
TCADDocument
  Part001 (one Part in MVP; API permits more later)
    Origin (coordinate frame)
      XY / XZ / YZ DatumPlane
    Sketch001 (SketchId; support = XY Plane)
    Sketch002 (SketchId; support = DatumPlane004)
    Body001 (BodyId; TipFeature = Extrude001)
    Body002 (BodyId; TipFeature = Extrude002)
```

Independent chronological feature operations (document-owned, existing graph):

```text
Sketch001 evaluator -> Extrude001 -----> Fillet001 -> Body001.Tip
Sketch002 evaluator -> Extrude002 -----------------> Body002.Tip
                           |
                  explicit cross-body inputs, if needed
```

- `Part` owns **the logical object records**; `TCADDocument` owns the Part registry and the existing `TCADFeature` graph. A Part does *not* own OCCT result handles.
- `Sketch` is a first-class document object. It owns/edit-commits `TCADSketch` geometry in a versioned sketch payload; its evaluator Feature produces profiles/faces from this data. In the migration stage, the existing `geometry` parameter remains the compatibility source until one authoritative storage path is implemented.
- `Body` owns `Name`, `Id`, `PartId`, visibility, optional material and a **TipFeatureId**. It references a result, it never owns/duplicates an OCCT `TopoDS_Shape`. The same Body survives sketch dimension edits, recompute, Fillet, Cut and undo/redo.
- `DatumPlane` is a persistent reference to a coordinate frame / support (base XY/XZ/YZ or user offset). It is **not** an artificial `TCADFeature` created for display only. Driven datums may eventually depend on Features.
- `Feature history order` is an explicit ordered sequence per Part and optional Body, **not inferred solely from graph leaves or dependency nesting**. Graph dependencies retain their own independent topological order.
- The tree UI is a **read-only projection** of these registries and feature order. Tree nodes do not own, clone or define CAD objects.

## 3. Identity and ownership contract

**MVP design choice:** preserve current `TCADId` for feature slots and add a separate document object identifier, e.g.:

```pascal
type
  TCADObjectId = record
    Value: QWord;                // 0 = none; never reused in the document
  end;
  TCADObjectKind = (cokPart, cokBody, cokSketch, cokDatumPlane);
  TCADObjectRef = record
    Kind: TCADObjectKind;
    Id: TCADObjectId;
  end;
```

This is *contract pseudocode*, not a compiled API yet.

1. An ObjectId is allocated monotonically per document, including across Delete/Undo/Redo; deleted IDs must not silently refer to another object. Serialize the next-ID counter together with objects. Avoid using UI list positions, pointer values, OCCT `Shape` pointers or feature slots as ObjectIds.
2. A `TCADFeature.Id` stays an existing `TCADId` during migration. When an object refers to a Feature, it stores a typed **FeatureId field**, not an ObjectId. After a document save/load is implemented, feature IDs must be preserved or explicitly remapped by a documented ID table (never guessed by name).
3. Registry lookups reject missing, deleted and **wrong-kind** object references. No silent fallback to the first Body or last Sketch.
4. Document/Part own logical records; ResultCache owns `TCADResult` (and thus OCCT handles). Viewport meshes are disposable derivatives of evaluated results.
5. Object deletion is transactional. If referenced by an active object/operation, report dependants and require an explicit cascade policy; never leave a dangling Body tip or plane support.
6. Recompute must not allocate or recycle ObjectIds. Failed compute leaves the Body and its ID in place with a clear **invalid evaluation** state, not an accidental replacement geometry.

## 4. Relationship and operation contracts

| Relation / operation | Required behavior |
| --- | --- |
| Part -> Datum | Part has durable origin and three default datum planes. Repositioning Part or a support plane updates downstream sketches through a declared dependency, not a UI-only transform. |
| Part -> Sketch | Sketch belongs to exactly one Part; its support is a Datum/plane reference with an optional explicit attachment transform. Sketch can be used by more than one Feature. |
| Part -> Body | Body belongs to exactly one Part; it may be empty during construction or have one active TipFeature. Visibility and display attributes belong to the Body, not to the feature-result cache. |
| Feature -> Sketch | Evaluation takes a typed Sketch reference and produces a profile result. Migration adapter may forward the old feature `geometry` parameter; there must be **one source of truth** when adapter is removed. |
| New Body | Extrude creates a Body object plus an evaluator feature atomically. A disconnected multi-region extrude **must not silently fuse independent islands**. The legacy multi-solid result remains supported until the later explicit split-to-bodies migration gate. |
| Add / Cut / Intersect | Requires explicit target BodyId and an operand Sketch/Profile/Body. The operation updates the target Body's Tip, but does not change the BodyId or mutate its previous cached result. |
| Same-body history | A new modifier uses the previous tip Feature as the base result. Body tip advances atomically only after valid creation/linking. Undo restores the previous tip and previous visibility state. |
| Cross-body operation | Operand and target are explicit and typed. Dependency graph rejects cycles. Tool Body is not modified unless an explicit 'consume tool' operation is requested. |
| Body tip visibility | Display only a Body's active evaluated tip in ordinary modeling mode. Existing per-feature ShowMode can remain as a debugging/history-display override during migration. |
| Delete / Undo | Deleting a Body or its last modifying Feature preserves other unrelated Bodies; Undo reattaches exactly the same object IDs and Feature IDs. Redo does not allocate duplicates. |
| Recompute / cache | Only dependent features recompute; cached result reuse is legal. A Body never owns the result and cannot free a shared cached OCCT shape. |

**Connectivity policy requiring later explicit implementation:** final body semantics target one connected solid per Body. For legacy sketches that produce disconnected solids, first retain the existing OCCT compound without regression; in the multi-body operation migration, create separate Body objects per disconnected result (or require a deliberate exception) and test the behavior. Do not silently discard geometric components now.

## 5. Typing and evaluation boundaries

Proposed/core units (first foundation candidates implemented; other stages pending):

- `src/core/cad.core.objectids.pas` — implemented `TCADObjectId` and typed refs.
- `src/core/cad.core.part.pas` — Part membership and object collections.
- `src/core/cad.core.body.pas` — Body identity, visibility, target/tip and invariants.
- `src/core/cad.core.sketchobject.pas` — Sketch identity and support reference; references the existing sketch model through a small adapter, not OCCT.
- `src/core/cad.core.datum.pas` — coordinate systems, datum planes and support transforms.
- `src/core/cad.core.objectmodel.pas` — implemented basic object registry, validation, tombstone removal and restoration; **not yet an atomic multi-feature transaction engine**.
- `src/core/cad.core.objectcommands.pas` — implemented single-object create/remove/rename/visibility commands on the existing `TCADHistory`.

**Dependency direction:** `core` stays headless and OCCT/GUI-free. Do not introduce a core -> app/view/OCCT dependency to make the Feature Tree convenient. Keep 650-line unit and 90-line routine architecture gates; prefer small, meaningful units and descriptive Pascal names.

### Distinct states

- **Model identity:** object exists, deleted, invalid reference, ownership Part.
- **Feature state:** dirty, clean, failed, blocked (already present).
- **Body evaluation:** empty, up-to-date, stale, failed/blocked, without replacing the Body object on failure.
- **Presentation state:** visible/hidden/selected/hovered — never authoritative for CAD ownership.

## 6. Transactions, history and concurrency

All structural edits are UI-thread commands routed through the existing `TCADHistory` family. The new object-model mutation facade should own transaction validation and rollback:

1. Validate all referenced objects, kinds, Part ownership, Body tip and feature graph links *before* publication.
2. Stage object/feature changes; if any link or validation fails, restore **every** affected object registry, feature graph edge, tip and visibility field.
3. Mark dirty features only when a valid edit is committed; then recompute via existing planner. Keep the worker pool/cache unchanged.
4. On Undo/Redo, restore the same object IDs/feature IDs, member ordering, tip pointers and visibility.
5. Read-only Feature compute may use immutable input results on workers; no document object mutation, ID allocation or UI widget access during compute.

The current `TCADAddFeatureCommand` shows how to rollback a failed link, but **compound operations need a stronger transaction** than several independent commands.

## 7. Scene, display and selection architecture

The future viewport's primary displayed object should be **BodyId**, with a separate internal mapping `BodyId -> active TipFeatureId -> TOCCTShapeResult -> ViewObjectId`. Reuse `CAD.View.Sync` while migrating, then replace the current `feature slot + 1` viewport mapping behind an adapter. The renderer/OCCT mesh should never become the source of truth for Body identity.

Selection must distinguish:
- `BodyId` (logical target);
- FeatureId (history step);
- `Face/Edge/Vertex` reference (subshape of an evaluated Body, **not** an integer offset into a temporary mesh).

Topology naming is **not solved by stable Body IDs**: subshape references need provenance + geometric matching/OCCT history with explicit ambiguity reporting. No claim of persistent face naming until separately tested against topology-changing edits.

## 8. Persistence and backwards compatibility

A full project file does not exist yet. Future serialization must be versioned and preserve:
- Document/Part/Body/Sketch/Datum IDs and next-ID allocator;
- Feature IDs, types, parameters, ordered dependencies and explicit operation history;
- Body tips, support-plane references, appearance and visibility;
- Existing `FPCSKETCH 1/2` geometry and constraints, with migration round-trips.

**Do not serialize** raw OCCT pointers, GPU objects, cached meshes, worker threads or live UI objects. Recompute after load.

Migrate incrementally:
1. Add the object registry beside existing Feature slots; **no UI tree changes**; tests only.
2. Materialize Part/Origin/base Datum and Bodies with explicit tips; keep all old Features working.
3. Promote Sketch to a logical object through a compatibility adapter; ensure there is one authoritative geometry payload.
4. Add Body-targeted operation semantics and a true history tree.
5. Introduce versioned document save/load and persistent subshape references with explicit regressions.

Never rewrite/remove a working Sketch/OCCT feature as an untested side effect of defining Body.

## 9. Acceptance gates and unresolved decisions

The detailed executable scenarios appear in `docs/OBJECT_MODEL_TEST_PLAN.md`.

**Gate A (this stage, design):** verify actual code seams, ratify ownership/ID/tip contracts, and define acceptance tests. No runtime implementation or new user-visible feature.

**Gate B (current feature branch):** a headless Part/Datum/Body/Sketch identity registry, stable IDs and single-object commands with Undo/Redo. Local `scripts/test_core.sh` and user acceptance are still required before PASS. No GUI changes.

**Gate C:** Body tip/history management with graph integration and unrelated-Body isolation, then the Sketch object adapter.

**Gate D:** GUI tree + viewport maps authoritative objects and a versioned file format; OCCT tests and real GUI tests pass before release.

Questions to resolve before Gate C: (1) single solid vs temporary compound policy for legacy multi-region Extrude; (2) how cross-Part references work when assemblies are introduced; (3) whether project file IDs are global across imported documents. For Gate B, the simple one-Part/per-document and monotonically allocated 64-bit object-ID contract is sufficient.
