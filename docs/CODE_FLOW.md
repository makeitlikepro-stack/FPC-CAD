# Code flow: how to trace FPC-CAD

## Folders (one kind of thing per folder)

| Folder | Holds | May use |
| --- | --- | --- |
| `src/config/` | settings records only (performance knobs) | RTL |
| `src/core/` | the model and the recompute machinery | RTL, `src/config` |
| `src/occt/` | OCCT adapter: `CAD.OCCT.Bridge` (loads the bridge, the only unit with C names), `CAD.OCCT.Options` (C record) | core, config |
| `src/sketch/` | 2D sketch: `CAD.Sketch.Model` (numbers, entities, constraints, plane), `CAD.Sketch.Constraints` (residuals), `CAD.Sketch.Solver` (LM, DOF, redundant/conflicting), `CAD.Sketch.Profile` (loops, faces, holes), `CAD.Sketch.Text` (sketch <-> text parameter), `CAD.Sketch.Editor` (drawing tools, snaps, automatic constraints, drag, selection; no GUI), `CAD.Sketch.Commands` (picking, constraint buttons, dimensions, labels) | RTL only |
| `src/features/` | one unit per feature type (`Box`, `Cylinder`, `Boolean`, `Sketch`, `Extrude`), all on `TCADOCCTFeature` | core, config, occt |
| `external/occt_bridge/` | C++ bridge on OCCT (built on the user machine) | OCCT |
| `src/view/` | display adapters to the engine viewport: `CAD.View.MeshConvert` (OCCT mesh -> `TV3DMeshData`), `CAD.View.Sync` (shown results -> viewport objects), `CAD.View.ViewportTarget` (sync target on `TUIViewport3D`), `CAD.View.SketchDraw` (pixel -> sketch ray, camera square to the plane, stroke meshes) | occt, engine `src/rendering` + `src/ui` (no GL calls) |
| `src/app/` | application: `CAD.App.Controller` (the app behind the designed main window: OCCT, document, sync, sketch UI, shortcuts, window-edge layout), `CAD.App.DemoScene` (plate + 6 holes), `CAD.App.SketchMode` (viewport mouse -> editor, sketch objects), `CAD.App.SketchPanel` (sketch tools, constraint buttons, list, dimension edit), `CAD.App.SketchDims` (dimension chips and relation glyphs in the view, in-place edit), `CAD.App.SketchToolbar` (icon toolbar over the view, shortcuts via the main form); `app/fpc_cad.lpi` builds `./fpc_cad`; `app/MainForm.fvform` + `app/umainform.pas` = main window designed in FPC Visual IDE | everything |

No unit in `src/core` uses LCL, OpenGL or OCCT.

## Working in FPC Visual IDE

- Open Project: `app/fpc_cad.lpi`. The main window opens in the designer
  (`app/MainForm.fvform`); its unit is `app/umainform.pas` (`TMainForm =
  class(TUIForm)`, one field per widget, handlers by name).
- The form unit only wires: `DesignLoaded` hands the widgets to
  `TCADAppController` (`src/app/cad.app.controller.pas`), which does the work.
  A new widget: add it in the designer, then use its field in the controller.
- No anchors in the design yet: the controller keeps the window edges
  (view fills the left, `SidePanel` keeps its designed width, `StatusLabel`
  at the bottom). Everything inside a panel stays where it was designed.
- The exe is built into the repo root (OCCT bridge next to it); the form
  finds its design in `app/` (`TMainForm.DesignFileName`).
- Still built in code (next to redesign): sketch toolbar, sketch panel,
  dimension chips.

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

## Trace 4: speed options reach OCCT

```
TCADPerformanceOptions (src/config)
  -> TOCCTLibrary.ApplyOptions                    cad.occt.bridge
       -> OCCTOptionsFromPerformance              cad.occt.options (88-byte C record)
       -> occt_bridge_set_options                 occt_bridge.cpp (size/version check, mutex copy,
                                                  OSD_ThreadPool size)
  later, per operation:
       occt_bridge_mesh_shape -> MeshParameters   (IMeshTools_Parameters)
       occt_bridge_cut_cylinder_shape -> OptionedCut -> ApplyBooleanOptions
```

## Trace 5: an OCCT feature computes (worker thread)

```
TCADDocument.ComputeOne                           cad.core.document
  -> TCADBooleanFeature.Compute                   cad.features.booleanop
       -> InputShape(inputs, 0/1)                 cad.features.occtbase (TOCCTShapeResult.Shape)
       -> OCCT.BooleanOp                          cad.occt.bridge -> occt_bridge_boolean
            (shared lock: booleans run in parallel; OptionedBoolean applies the options)
       -> WrapShape                               cad.features.occtbase
            -> OCCT.ShapeVolume                   exact B-rep volume (shared lock)
            -> TOCCTShapeResult                   cad.occt.shaperesult (owns shape, no mesh yet)
            -> PrepareDisplay (only if Mesh.Timing = cmtEveryResult)
  -> TCADResultCache.Store                        the cache owns the result; freeing it
                                                  frees the OCCT handles
```

## Trace 6: display pass - meshes for shown results only (calling thread)

```
TCADDocument.Recompute                            cad.core.document
  1. RunLevels                                    Trace 1/5 (parallel model work)
  2. PrepareDisplay   (Mesh.Timing = cmtDisplayed; cmtManual: the caller calls it)
       -> RunDisplayPass                          cad.core.displaypass
            for each feature: clean + CADIsShown? (ShowMode, or UserCount = 0)
              -> Output.DisplayReady?             yes: skip (cached result keeps its mesh)
              -> Output.PrepareDisplay            TOCCTShapeResult -> OCCT.MeshShape
                                                  (exclusive lock, InParallel inside)
              -> TCADResultCache.Remeasure        cache bytes include the new mesh
            failure -> Feature.DisplayError (model stays cfsClean)
  report: TCADRecomputeReport.Display (Shown, Prepared, Failed, ms)
```

## Trace 5: a result reaches the screen (stage 4)

```
TCADDocument.Recompute                       model levels + display pass (meshes shown results)
TCADViewSync.Sync                            cad.view.sync (UI thread, after Recompute)
  for each slot: shown and DisplayReady?
    no  -> TCADViewTarget.SetObjectVisible(False)
    same result pointer + key -> nothing (or just show again)
    new -> CADFillMeshFromResult             cad.view.meshconvert (OCCT arrays -> TV3DMeshData)
           TCADViewportTarget.MeshFor        cad.view.viewporttarget (FindObject / AddObject)
  any change -> TUIViewport3D.Invalidate3D   GPU upload when the mesh Revision changed
object id = slot + 1; pick Element = OCCT face/edge index (1-based)
```
