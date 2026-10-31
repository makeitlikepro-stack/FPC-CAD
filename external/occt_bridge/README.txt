OCCT C ABI bridge (FPC-CAD)
===========================

Moved from the UI engine (engine main 5982eef, external/occt_bridge) on
2026-10-31: OCCT belongs to the CAD project. Pascal side: src/occt
(CAD.OCCT.Library = the only unit with the C names, CAD.OCCT.Options).

Speed options (since FPC-CAD stage 3)
-------------------------------------
occt_bridge_options.h is the C mirror of the OCCT part of
TCADPerformanceOptions (src/config/cad.config.performance.pas):
  occt_bridge_set_options(const occt_bridge_options*)  1 = ok, 0 = size/version mismatch
  occt_bridge_get_options(occt_bridge_options*)
  occt_bridge_options_size()                           ABI check from Pascal
Applied in MeshParameters (IMeshTools_Parameters: InParallel, Relative,
Deflection, Angle, MinSize, ControlSurfaceDeflection, AllowQualityDecrease,
CleanModel) and ApplyBooleanOptions (SetRunParallel, SetUseOBB,
SetFuzzyValue, SetGlue, SetNonDestructive, SetCheckInverted). The thread
pool size goes to OSD_ThreadPool::DefaultPool()->Init.
A positive linearDeflection argument of occt_bridge_mesh_shape still wins over
the option (old callers keep working); pass 0 to use the option.

Build: bash external/occt_bridge/build.sh   (incremental; --force to rebuild)
Other OCCT location: OCCT_INCLUDE=... OCCT_LIB=... bash external/occt_bridge/build.sh
Test:  bash scripts/test_occt.sh

----- history from the engine -----
OCCT C ABI bridge
=================

Purpose
-------
Keep OpenCASCADE C++ ABI details out of FPC/Lazarus. The Pascal side loads this
small shared library through a stable C ABI.

Automatic Lazarus build
-----------------------
The project now runs this bridge build automatically through the Lazarus
"Execute before" compiler command:

  /bin/bash ./external/occt_bridge/build.sh

The script is incremental. If libocct_bridge.so is newer than both
occt_bridge.cpp and build.sh, it reports that the bridge is up to date and exits
without invoking g++.

If bridge compilation fails, Lazarus stops before compiling the Pascal project,
so the C++/OCCT error is visible at the correct stage.

Manual build
------------
You can still build it manually:

  ./build.sh

Force a rebuild:

  ./build.sh --force

Output
------
  libocct_bridge.so

Runtime location
----------------
The demo expects the library beside the project executable at:

  external/occt_bridge/libocct_bridge.so

Notes
-----
- The current bridge targets the OCCT 7.8 API used on the tested system.
- The bridge currently exposes the smoke test plus BOX/CUT/FUSE/FILLET visual
  mesh operations.
- Each visual mesh also exposes real unique B-Rep edges as polyline segments.
  These are generated from TopoDS_Edge curves, not triangle tessellation edges,
  so the engine can render CAD-style shaded surfaces with analytical edges.
- OpenCASCADE remains outside the core ECS/UI/text subsystems.

v3.95 PARAMETRIC SHAPE ABI
--------------------------
The bridge now also exposes opaque B-Rep shape handles for the engine's
parametric CAD document layer:

  occt_bridge_create_rectangle_prism_shape(width, depth, height)
  occt_bridge_cut_cylinder_shape(base, radius, centerX, centerY)
  occt_bridge_mesh_shape(shape, linearDeflection)
  occt_bridge_free_shape(shape)

Ownership rule: every returned shape handle is owned by the caller and must be
released with occt_bridge_free_shape. Mesh handles returned by mesh_shape use
the existing mesh ABI and are released by occt_bridge_free_demo_mesh.

The Pascal CAD document remains kernel-agnostic. OpenGL.CAD.OCCT.Features owns
opaque bridge handles inside TOCCTShapeResult and frees them transactionally
when a newer successful feature result replaces the old one.


Subshape selection ABI (v4.03):
- occt_bridge_mesh_face_ids(mesh): uint32 per shaded vertex
- occt_bridge_mesh_edge_ids(mesh): uint32 per B-Rep edge vertex
- occt_bridge_mesh_topology_vertex_count(mesh)
- occt_bridge_mesh_topology_vertex_positions(mesh)
- occt_bridge_mesh_topology_vertex_ids(mesh)
IDs are 1-based TopTools_IndexedMapOfShape indices for the current shape result.
They are revision-scoped selection identities, not persistent topological names across recompute.

CAD edge adjacent-face metadata ABI (v4.07):
- occt_bridge_mesh_edge_normal_a(mesh): outward OCCT face normal per edge vertex
- occt_bridge_mesh_edge_normal_b(mesh): second adjacent outward face normal
- occt_bridge_mesh_edge_face_counts(mesh): 1 or 2 adjacent faces per visible edge vertex
The renderer uses this metadata only for presentation. It does not modify the
TopoDS_Edge or the owning B-Rep shape.
