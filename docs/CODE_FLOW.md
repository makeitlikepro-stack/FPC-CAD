# Code flow: how to trace FPC-CAD

## Folders (one kind of thing per folder)

| Folder | Holds | May use |
| --- | --- | --- |
| `src/config/` | settings records only (performance knobs) | RTL |
| `src/core/` | the model and the recompute machinery | RTL, `src/config` |
| `src/occt/` | (stage 3) OCCT adapter through the C bridge | core, config |
| `src/app/` | (stage 4) UI on the engine, viewport, GPU compute jobs | everything |

No unit in `src/core` uses LCL, OpenGL or OCCT.

## Unit header

Every unit starts with the same block, so you can follow a call without
opening other files:

```
{ ROLE:      one sentence
  CALLED BY: who uses it
  CALLS:     what it uses
  THREADS:   which thread may call it
  SPEED:     the cost rule it keeps }
```

## Trace 1: user changes a parameter (e.g. extrude length)

```
UI / script
  -> TCADHistory.Execute(TCADSetParamCommand)        cad.core.history / cad.core.commands
       -> TCADSetParamCommand.DoIt
            -> TCADDocument.SetParam                 cad.core.document
                 -> TCADFeature.SetParamValue        cad.core.feature   (params hash changes)
                 -> TCADDocument.MarkChanged         (adds id to the changed list)
  -> TCADDocument.Recompute                          cad.core.document
       -> TCADDependencyGraph.CollectDirty           cad.core.graph     (changed + all users)
       -> TCADRecomputePlan.Build                    cad.core.recomputeplan (levels)
       -> for each level:
            TCADWorkerPool.Run(level)                cad.core.workerpool (parallel)
              -> TCADDocument.ComputeOne             (per feature, any thread)
                   -> cache key = hash(params, input keys)
                   -> TCADResultCache.Find(key)      cad.core.resultcache (hit: done)
                   -> TCADFeature.Compute            (miss: real work)
                   -> TCADResultCache.Store
       -> TCADRecomputeReport                        (numbers for the UI and tests)
```

## Trace 2: Undo

```
TCADHistory.Undo -> TCADCommand.UndoIt -> TCADDocument.SetParam(old value)
TCADDocument.Recompute -> keys equal the old keys -> cache hits, no Compute call
```

## Trace 3: add a feature

```
TCADHistory.Execute(TCADAddFeatureCommand)
  -> TCADDocument.AttachFeature (new id, never reused)
  -> TCADDocument.Link(user, input) for each input -> graph rejects cycles
```

## Naming

- Types start with `TCAD`, units with `CAD.<Folder>.`, files are lower case.
- A feature type is one unit `cad.features.<name>.pas` (stage 3) registered in
  `TCADFeatureRegistry` by its type name.
