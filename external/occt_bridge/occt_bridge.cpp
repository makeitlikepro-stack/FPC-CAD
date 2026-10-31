// FPC-CAD OCCT bridge. Moved from the UI engine (engine main 5982eef).
// Speed options: occt_bridge_options.h, applied in ApplyMeshOptions and
// ApplyBooleanOptions below (docs/PERFORMANCE.md section 3).
#include "occt_bridge_options.h"

#include <BRepAlgoAPI_Cut.hxx>
#include <BRepTools.hxx>
#include <IMeshTools_Parameters.hxx>
#include <OSD_Parallel.hxx>
#include <OSD_ThreadPool.hxx>
#include <TopTools_ListOfShape.hxx>
#include <mutex>
#include <shared_mutex>
#include <BRepAlgoAPI_Common.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepAlgoAPI_Common.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRep_Builder.hxx>
#include <BRepBndLib.hxx>
#include <Bnd_Box.hxx>
#include <BRepBuilderAPI_MakePolygon.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepGProp.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRep_Tool.hxx>
#include <GProp_GProps.hxx>
#include <Geom2d_Curve.hxx>
#include <Poly.hxx>
#include <Poly_Polygon3D.hxx>
#include <Poly_PolygonOnTriangulation.hxx>
#include <Poly_Triangulation.hxx>
#include <Standard_Failure.hxx>
#include <Standard_Version.hxx>
#include <TopAbs_Orientation.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopLoc_Location.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shape.hxx>
#include <TopoDS_Vertex.hxx>
#include <TopoDS_Wire.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <TopTools_ListIteratorOfListOfShape.hxx>
#include <TopTools_ListOfShape.hxx>
#include <TColgp_Array1OfPnt.hxx>
#include <TColStd_Array1OfInteger.hxx>
#include <gp_Ax2.hxx>
#include <gp_Dir.hxx>
#include <gp_Pnt.hxx>
#include <gp_Pnt2d.hxx>
#include <gp_Trsf.hxx>
#include <gp_Vec.hxx>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <exception>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace {
thread_local std::string gLastError;

void SetError(const char* msg) {
  gLastError = msg ? msg : "Unknown OCCT error";
}

// ---------------------------------------------------------------- speed options
// One global copy, changed only through occt_bridge_set_options. Operations
// take a snapshot at their start (CurrentOptions), so a change during a
// parallel recompute never mixes old and new values inside one operation.
std::mutex gOptionsLock;
occt_bridge_options gOptions = [] {
  occt_bridge_options o{};
  o.struct_size = sizeof(occt_bridge_options);
  o.version = OCCT_BRIDGE_OPTIONS_VERSION;
  o.mesh_linear_deflection = 0.001;
  o.mesh_angular_deflection_deg = 20.0;
  o.mesh_min_size = 0.0;
  o.bool_fuzzy_value = 0.0;
  o.mesh_in_parallel = 1;
  o.mesh_relative = 1;
  o.mesh_control_surface_deflection = 1;
  o.mesh_allow_quality_decrease = 1;
  o.mesh_keep_existing = 1;
  o.bool_run_parallel = 1;
  o.bool_use_obb = 1;
  o.bool_glue = 0;
  o.bool_non_destructive = 1;
  o.bool_check_inverted = 1;
  o.occt_threads = 0;
  return o;
}();

occt_bridge_options CurrentOptions() {
  std::lock_guard<std::mutex> lock(gOptionsLock);
  return gOptions;
}

// BRepMesh parameters from the options. A positive per-call deflection
// (old ABI argument) wins over the option, so existing callers keep working.
IMeshTools_Parameters MeshParameters(const occt_bridge_options& o,
                                     const double callDeflection) {
  IMeshTools_Parameters p;
  p.Deflection = callDeflection > 0.0 ? callDeflection
                                      : std::max(1.0e-7, o.mesh_linear_deflection);
  p.Angle = o.mesh_angular_deflection_deg * M_PI / 180.0;
  p.Relative = o.mesh_relative != 0;
  p.InParallel = o.mesh_in_parallel != 0;
  if (o.mesh_min_size > 0.0) {
    p.MinSize = o.mesh_min_size;
  }
  p.ControlSurfaceDeflection = o.mesh_control_surface_deflection != 0;
  p.AllowQualityDecrease = o.mesh_allow_quality_decrease != 0;
  // CleanModel = false keeps triangulations that still satisfy the
  // deflection: unchanged faces of a recomputed solid are not remeshed.
  p.CleanModel = o.mesh_keep_existing == 0;
  return p;
}

// Applied to every boolean before Build().
void ApplyBooleanOptions(BRepAlgoAPI_BooleanOperation& op,
                         const occt_bridge_options& o) {
  op.SetRunParallel(o.bool_run_parallel != 0);
  op.SetUseOBB(o.bool_use_obb != 0);
  if (o.bool_fuzzy_value > 0.0) {
    op.SetFuzzyValue(o.bool_fuzzy_value);
  }
  switch (o.bool_glue) {
    case 1: op.SetGlue(BOPAlgo_GlueShift); break;
    case 2: op.SetGlue(BOPAlgo_GlueFull); break;
    default: op.SetGlue(BOPAlgo_GlueOff); break;
  }
  op.SetNonDestructive(o.bool_non_destructive != 0);
  op.SetCheckInverted(o.bool_check_inverted != 0);
}

// ---------------------------------------------------------------- thread safety
// Meshing writes Poly_Triangulation into the TFaces of a shape, and a boolean
// result shares untouched faces with its inputs. FPC-CAD computes features on
// several threads, so: meshing takes the lock exclusively (one mesh at a time,
// each mesh itself runs on all cores via InParallel); modelling operations
// (primitives, booleans, volume) take it shared and run in parallel.
std::shared_mutex gTopologyLock;

// Boolean of any kind with the speed options (FPC-CAD feature path).
TopoDS_Shape OptionedBoolean(const int op, const TopoDS_Shape& object,
                             const TopoDS_Shape& tool) {
  const occt_bridge_options o = CurrentOptions();
  std::unique_ptr<BRepAlgoAPI_BooleanOperation> builder;
  switch (op) {
    case 0: builder = std::make_unique<BRepAlgoAPI_Cut>(); break;
    case 1: builder = std::make_unique<BRepAlgoAPI_Fuse>(); break;
    case 2: builder = std::make_unique<BRepAlgoAPI_Common>(); break;
    default: throw Standard_Failure("Boolean operation must be 0 cut, 1 fuse or 2 common");
  }
  TopTools_ListOfShape args;
  TopTools_ListOfShape tools;
  args.Append(object);
  tools.Append(tool);
  builder->SetArguments(args);
  builder->SetTools(tools);
  ApplyBooleanOptions(*builder, o);
  builder->Build();
  if (!builder->IsDone() || builder->Shape().IsNull()) {
    throw Standard_Failure("Boolean operation failed");
  }
  return builder->Shape();
}

// Cut with options (the 2-argument BRepAlgoAPI_Cut constructor builds at
// once and cannot take options).
TopoDS_Shape OptionedCut(const TopoDS_Shape& object, const TopoDS_Shape& tool) {
  const occt_bridge_options o = CurrentOptions();
  BRepAlgoAPI_Cut op;
  TopTools_ListOfShape args;
  TopTools_ListOfShape tools;
  args.Append(object);
  tools.Append(tool);
  op.SetArguments(args);
  op.SetTools(tools);
  ApplyBooleanOptions(op, o);
  op.Build();
  if (!op.IsDone() || op.Shape().IsNull()) {
    throw Standard_Failure("BRepAlgoAPI_Cut failed");
  }
  return op.Shape();
}

struct MeshHandle {
  std::vector<float> positions;
  std::vector<float> normals;
  // Surface-aware per-vertex normals for smooth CAD shading.
  std::vector<float> smoothNormals;
  std::vector<std::uint32_t> indices;
  // One OCCT face index per shaded vertex. The tessellator duplicates
  // triangle vertices, so every triangle can carry a single flat face ID.
  std::vector<std::uint32_t> faceIds;
  // Real B-Rep edge polyline vertices. Stored as independent GL_LINES pairs
  // so the engine never exposes tessellation triangle diagonals as CAD edges.
  std::vector<float> edgePositions;
  // Outward normals of the first/second B-Rep faces adjacent to each sampled
  // edge vertex.  These are presentation metadata only: the renderer uses
  // them to lift the display stroke along the exterior dihedral bisector.
  std::vector<float> edgeNormalA;
  std::vector<float> edgeNormalB;
  std::vector<std::uint32_t> edgeFaceCounts;
  // One OCCT edge index per edge vertex (the same ID is repeated for both
  // endpoints of every emitted segment of a topological edge).
  std::vector<std::uint32_t> edgeIds;
  // Exact B-Rep topological vertices, independent from tessellation vertices.
  std::vector<float> vertexPositions;
  std::vector<std::uint32_t> vertexIds;
  int topologyEdgeCount = 0;
  int hiddenSeamEdgeCount = 0;
  double volume = 0.0;
  int affectedSectors = 0;
};

struct ShapeHandle {
  TopoDS_Shape shape;
};


TopoDS_Shape BuildStressGearBase() {
  // Performance-test gear: many topological edges, but intentionally simple
  // planar tooth geometry so Boolean timing is dominated by OCCT rather than
  // by an unnecessarily exotic profile definition.
  constexpr int kTeeth = 64;
  constexpr double kRootRadius = 2.25;
  constexpr double kTipRadius = 2.75;
  constexpr double kThickness = 0.55;
  constexpr double kHalfThickness = kThickness * 0.5;
  constexpr double kPi = 3.1415926535897932384626433832795;
  const double pitch = 2.0 * kPi / static_cast<double>(kTeeth);

  BRepBuilderAPI_MakePolygon polygon;
  for (int tooth = 0; tooth < kTeeth; ++tooth) {
    const double base = static_cast<double>(tooth) * pitch;
    const double a0 = base;
    const double a1 = base + pitch * 0.30;
    const double a2 = base + pitch * 0.70;
    polygon.Add(gp_Pnt(kRootRadius * std::cos(a0),
                       kRootRadius * std::sin(a0), -kHalfThickness));
    polygon.Add(gp_Pnt(kTipRadius * std::cos(a1),
                       kTipRadius * std::sin(a1), -kHalfThickness));
    polygon.Add(gp_Pnt(kTipRadius * std::cos(a2),
                       kTipRadius * std::sin(a2), -kHalfThickness));
  }
  polygon.Close();
  const TopoDS_Wire wire = polygon.Wire();
  const TopoDS_Shape face = BRepBuilderAPI_MakeFace(wire).Face();
  const TopoDS_Shape rawGear = BRepPrimAPI_MakePrism(
    face, gp_Vec(0.0, 0.0, kThickness)).Shape();

  // A permanent centre bore makes the stress model look and behave like a
  // real gear while keeping the moving cutter away from a trivial solid disk.
  const gp_Ax2 boreAxis(gp_Pnt(0.0, 0.0, -0.8), gp_Dir(0.0, 0.0, 1.0));
  const TopoDS_Shape bore = BRepPrimAPI_MakeCylinder(boreAxis, 0.55, 1.6).Shape();
  BRepAlgoAPI_Cut boreCut(rawGear, bore);
  boreCut.Build();
  if (!boreCut.IsDone()) {
    throw Standard_Failure("Stress gear centre bore failed");
  }
  return boreCut.Shape();
}

const TopoDS_Shape& StressGearBase() {
  static const TopoDS_Shape gear = BuildStressGearBase();
  return gear;
}

TopoDS_Shape BuildStressGearCut(const double cutterX, const double cutterY) {
  const gp_Ax2 cutterAxis(
    gp_Pnt(cutterX, cutterY, -0.8), gp_Dir(0.0, 0.0, 1.0));
  const TopoDS_Shape cutter =
    BRepPrimAPI_MakeCylinder(cutterAxis, 0.24, 1.6).Shape();

  BRepAlgoAPI_Cut cut(StressGearBase(), cutter);
  cut.Build();
  if (!cut.IsDone()) {
    throw Standard_Failure("Dynamic gear cutter Boolean failed");
  }
  return cut.Shape();
}

TopoDS_Shape BuildStressCutterBase() {
  const gp_Ax2 cutterAxis(
    gp_Pnt(0.0, 0.0, -0.8), gp_Dir(0.0, 0.0, 1.0));
  return BRepPrimAPI_MakeCylinder(cutterAxis, 0.24, 1.6).Shape();
}

constexpr int kStressSectorCount = 16;

struct StressSector {
  TopoDS_Shape shape;
  Bnd_Box bounds;
};

const std::array<StressSector, kStressSectorCount>& StressGearSectors() {
  // The gear is partitioned once into angular solids. Runtime localized cuts
  // only touch sectors whose cached AABB overlaps the moving cutter. The
  // sectors intentionally remain separate solids in a compound; this is a
  // benchmark of localized B-Rep recomputation, not a final feature-history
  // representation.
  static const std::array<StressSector, kStressSectorCount> sectors = [] {
    std::array<StressSector, kStressSectorCount> result;
    constexpr double kPi = 3.1415926535897932384626433832795;
    constexpr double kOuter = 3.4;
    constexpr double kZ0 = -0.7;
    constexpr double kHeight = 1.4;
    const double pitch = 2.0 * kPi / static_cast<double>(kStressSectorCount);
    const TopoDS_Shape& gear = StressGearBase();

    for (int i = 0; i < kStressSectorCount; ++i) {
      const double a0 = static_cast<double>(i) * pitch;
      const double a1 = static_cast<double>(i + 1) * pitch;
      BRepBuilderAPI_MakePolygon poly;
      poly.Add(gp_Pnt(0.0, 0.0, kZ0));
      poly.Add(gp_Pnt(kOuter * std::cos(a0), kOuter * std::sin(a0), kZ0));
      poly.Add(gp_Pnt(kOuter * std::cos(a1), kOuter * std::sin(a1), kZ0));
      poly.Close();
      const TopoDS_Shape wedge = BRepPrimAPI_MakePrism(
        BRepBuilderAPI_MakeFace(poly.Wire()).Face(),
        gp_Vec(0.0, 0.0, kHeight)).Shape();

      BRepAlgoAPI_Common common(gear, wedge);
      common.Build();
      if (!common.IsDone() || common.Shape().IsNull()) {
        throw Standard_Failure("Stress gear sector partition failed");
      }

      result[i].shape = common.Shape();
      BRepBndLib::Add(result[i].shape, result[i].bounds);
    }
    return result;
  }();
  return sectors;
}

TopoDS_Shape BuildStressGearLocalizedCut(const double cutterX,
                                         const double cutterY,
                                         int& outAffectedSectors) {
  const gp_Ax2 cutterAxis(
    gp_Pnt(cutterX, cutterY, -0.8), gp_Dir(0.0, 0.0, 1.0));
  const TopoDS_Shape cutter =
    BRepPrimAPI_MakeCylinder(cutterAxis, 0.24, 1.6).Shape();

  Bnd_Box cutterBounds;
  BRepBndLib::Add(cutter, cutterBounds);

  BRep_Builder builder;
  TopoDS_Compound compound;
  builder.MakeCompound(compound);
  outAffectedSectors = 0;

  for (const StressSector& sector : StressGearSectors()) {
    if (sector.bounds.IsOut(cutterBounds)) {
      builder.Add(compound, sector.shape);
      continue;
    }

    BRepAlgoAPI_Cut cut(sector.shape, cutter);
    cut.Build();
    if (!cut.IsDone()) {
      throw Standard_Failure("Localized gear sector Boolean failed");
    }
    builder.Add(compound, cut.Shape());
    ++outAffectedSectors;
  }

  return compound;
}

TopoDS_Shape BuildDemoShape(const int mode) {
  // Keep the test model centered around the world origin so the existing
  // orbit camera can display it directly without a CAD-specific scene layer.
  const TopoDS_Shape box = BRepPrimAPI_MakeBox(
    gp_Pnt(-1.2, -1.0, -0.8), 2.4, 2.0, 1.6).Shape();

  if (mode == 0) {
    return box;
  }

  if (mode == 1) {
    // CUT: drill a cylinder completely through the box along Z.
    const gp_Ax2 axis(gp_Pnt(0.0, 0.0, -1.2), gp_Dir(0.0, 0.0, 1.0));
    const TopoDS_Shape tool = BRepPrimAPI_MakeCylinder(axis, 0.55, 2.4).Shape();
    BRepAlgoAPI_Cut op(box, tool);
    op.Build();
    if (!op.IsDone()) {
      throw Standard_Failure("BRepAlgoAPI_Cut failed");
    }
    return op.Shape();
  }

  if (mode == 2) {
    // FUSE: overlap a cylinder with the right side of the box.  The cylinder
    // extends above/below and sideways enough to make the Boolean result easy
    // to distinguish visually from the original box.
    const gp_Ax2 axis(gp_Pnt(1.0, 0.0, -1.2), gp_Dir(0.0, 0.0, 1.0));
    const TopoDS_Shape tool = BRepPrimAPI_MakeCylinder(axis, 0.58, 2.4).Shape();
    BRepAlgoAPI_Fuse op(box, tool);
    op.Build();
    if (!op.IsDone()) {
      throw Standard_Failure("BRepAlgoAPI_Fuse failed");
    }
    return op.Shape();
  }

  if (mode == 3) {
    // FILLET: round every edge of the box.  A deliberately conservative
    // radius keeps this integration test stable while making the result
    // visually obvious.  Later CAD work can select individual edges.
    BRepFilletAPI_MakeFillet fillet(box);
    for (TopExp_Explorer exp(box, TopAbs_EDGE); exp.More(); exp.Next()) {
      fillet.Add(0.18, TopoDS::Edge(exp.Current()));
    }
    fillet.Build();
    if (!fillet.IsDone()) {
      throw Standard_Failure("BRepFilletAPI_MakeFillet failed");
    }
    return fillet.Shape();
  }

  throw Standard_Failure("Unknown OCCT demo mode");
}

struct EdgeFaceNormals {
  gp_Vec a = gp_Vec(0.0, 0.0, 1.0);
  gp_Vec b = gp_Vec(0.0, 0.0, 1.0);
  std::uint32_t count = 0;
};

bool FaceNormalAtEdgeParameter(const TopoDS_Edge& edge,
                               const TopoDS_Face& face,
                               const Standard_Real parameter,
                               gp_Vec& outNormal) {
  Standard_Real first = 0.0;
  Standard_Real last = 0.0;
  const Handle(Geom2d_Curve) pcurve =
      BRep_Tool::CurveOnSurface(edge, face, first, last);
  if (pcurve.IsNull()) {
    return false;
  }

  Standard_Real t = parameter;
  if (std::isfinite(first) && std::isfinite(last)) {
    if (first <= last) {
      t = std::max(first, std::min(last, t));
    } else {
      t = std::max(last, std::min(first, t));
    }
  }

  const gp_Pnt2d uv = pcurve->Value(t);
  BRepAdaptor_Surface surface(face);
  gp_Pnt point;
  gp_Vec du;
  gp_Vec dv;
  surface.D1(uv.X(), uv.Y(), point, du, dv);
  gp_Vec normal = du.Crossed(dv);
  if (normal.SquareMagnitude() <= 1.0e-24) {
    return false;
  }
  normal.Normalize();
  if (face.Orientation() == TopAbs_REVERSED) {
    normal.Reverse();
  }
  outNormal = normal;
  return true;
}

EdgeFaceNormals EdgeNormalsAtParameter(
    const TopoDS_Edge& edge,
    const TopTools_ListOfShape* adjacentFaces,
    const Standard_Real parameter) {
  EdgeFaceNormals result;
  if (adjacentFaces == nullptr) {
    return result;
  }

  for (TopTools_ListIteratorOfListOfShape it(*adjacentFaces);
       it.More() && result.count < 2U; it.Next()) {
    const TopoDS_Face face = TopoDS::Face(it.Value());
    gp_Vec normal;
    if (!FaceNormalAtEdgeParameter(edge, face, parameter, normal)) {
      continue;
    }
    if (result.count == 0U) {
      result.a = normal;
    } else {
      result.b = normal;
    }
    ++result.count;
  }

  if (result.count == 1U) {
    result.b = result.a;
  }
  return result;
}

void AppendEdgeVertex(MeshHandle& mesh, const gp_Pnt& p,
                      const EdgeFaceNormals& normals,
                      const std::uint32_t edgeId) {
  mesh.edgePositions.push_back(static_cast<float>(p.X()));
  mesh.edgePositions.push_back(static_cast<float>(p.Y()));
  mesh.edgePositions.push_back(static_cast<float>(p.Z()));
  mesh.edgeNormalA.push_back(static_cast<float>(normals.a.X()));
  mesh.edgeNormalA.push_back(static_cast<float>(normals.a.Y()));
  mesh.edgeNormalA.push_back(static_cast<float>(normals.a.Z()));
  mesh.edgeNormalB.push_back(static_cast<float>(normals.b.X()));
  mesh.edgeNormalB.push_back(static_cast<float>(normals.b.Y()));
  mesh.edgeNormalB.push_back(static_cast<float>(normals.b.Z()));
  mesh.edgeFaceCounts.push_back(normals.count);
  mesh.edgeIds.push_back(edgeId);
}

void AppendEdgeSegment(MeshHandle& mesh,
                       const gp_Pnt& p1, const EdgeFaceNormals& n1,
                       const gp_Pnt& p2, const EdgeFaceNormals& n2,
                       const std::uint32_t edgeId) {
  AppendEdgeVertex(mesh, p1, n1, edgeId);
  AppendEdgeVertex(mesh, p2, n2, edgeId);
}

void AppendShapeEdges(MeshHandle& mesh, const TopoDS_Shape& shape,
                      const TopTools_IndexedMapOfShape& edgeMap,
                      const double /*linearDeflection*/) {
  // FreeCAD ViewProviderPartExt does NOT resample face-bound B-Rep edges from
  // the analytic curve.  It obtains each displayed edge polyline from
  // BRep_Tool::PolygonOnTriangulation(edge, faceTriangulation, location), so
  // the line reuses the exact node positions of the same Poly_Triangulation
  // that is rendered as the shaded face.  This is essential at grazing camera
  // angles: an independently sampled analytic curve can project a few pixels
  // away from the tessellated face boundary even though both approximate the
  // same exact B-Rep edge.

  TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
  TopExp::MapShapesAndAncestors(shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);

  // Preserve the project's existing presentation policy that hides periodic
  // face seam edges (for example the longitudinal seam inside a cylindrical
  // hole).  This is orthogonal to the FreeCAD shared-triangulation rule.
  std::vector<bool> seamEdge(static_cast<std::size_t>(edgeMap.Extent()) + 1U,
                             false);
  for (TopExp_Explorer faceExp(shape, TopAbs_FACE); faceExp.More(); faceExp.Next()) {
    const TopoDS_Face face = TopoDS::Face(faceExp.Current());
    for (TopExp_Explorer edgeExp(face, TopAbs_EDGE); edgeExp.More(); edgeExp.Next()) {
      const TopoDS_Edge edge = TopoDS::Edge(edgeExp.Current());
      const Standard_Integer edgeIndex = edgeMap.FindIndex(edge);
      if (edgeIndex > 0 && BRep_Tool::IsClosed(edge, face)) {
        seamEdge[static_cast<std::size_t>(edgeIndex)] = true;
      }
    }
  }

  // Exactly as in FreeCAD's setupCoinGeometry(), process a topological edge
  // from the first adjacent face that provides a PolygonOnTriangulation and
  // then mark that edge as handled.  If the first face cannot provide one,
  // another adjacent face is allowed to satisfy it later.
  std::vector<bool> handled(static_cast<std::size_t>(edgeMap.Extent()) + 1U,
                            false);

  TopTools_IndexedMapOfShape faceMap;
  TopExp::MapShapes(shape, TopAbs_FACE, faceMap);
  for (Standard_Integer faceIndex = 1; faceIndex <= faceMap.Extent(); ++faceIndex) {
    const TopoDS_Face face = TopoDS::Face(faceMap(faceIndex));
    TopLoc_Location location;
    Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(face, location);
    if (tri.IsNull()) {
      continue;
    }
    if (!tri->HasNormals()) {
      Poly::ComputeNormals(tri);
    }

    const gp_Trsf trsf = location.Transformation();
    const bool transformed = trsf.Form() != gp_Identity;
    const bool reversed = face.Orientation() == TopAbs_REVERSED;

    for (TopExp_Explorer edgeExp(face, TopAbs_EDGE); edgeExp.More(); edgeExp.Next()) {
      const TopoDS_Edge edge = TopoDS::Edge(edgeExp.Current());
      const Standard_Integer edgeIndex = edgeMap.FindIndex(edge);
      if (edgeIndex <= 0 || handled[static_cast<std::size_t>(edgeIndex)] ||
          seamEdge[static_cast<std::size_t>(edgeIndex)] ||
          BRep_Tool::Degenerated(edge)) {
        continue;
      }

      Handle(Poly_PolygonOnTriangulation) poly =
          BRep_Tool::PolygonOnTriangulation(edge, tri, location);
      if (poly.IsNull() || poly->NbNodes() < 2) {
        continue;
      }

      const TColStd_Array1OfInteger& nodes = poly->Nodes();
      const TopTools_ListOfShape* adjacentFaces = nullptr;
      if (edgeFaces.Contains(edge)) {
        adjacentFaces = &edgeFaces.FindFromKey(edge);
      }
      std::uint32_t adjacentCount = 1;
      if (adjacentFaces != nullptr) {
        adjacentCount = static_cast<std::uint32_t>(adjacentFaces->Extent());
        if (adjacentCount < 1U) adjacentCount = 1U;
        if (adjacentCount > 2U) adjacentCount = 2U;
      }

      auto makeNormals = [&](Standard_Integer nodeIndex) {
        EdgeFaceNormals result;
        gp_Dir normal = tri->Normal(nodeIndex);
        if (transformed) {
          normal.Transform(trsf);
        }
        if (reversed) {
          normal.Reverse();
        }
        result.a = normal;
        result.b = normal;
        result.count = adjacentCount;
        return result;
      };

      Standard_Integer previousNode = nodes(nodes.Lower());
      gp_Pnt previous = tri->Node(previousNode);
      if (transformed) {
        previous.Transform(trsf);
      }
      EdgeFaceNormals previousNormals = makeNormals(previousNode);

      for (Standard_Integer i = nodes.Lower() + 1; i <= nodes.Upper(); ++i) {
        const Standard_Integer currentNode = nodes(i);
        gp_Pnt current = tri->Node(currentNode);
        if (transformed) {
          current.Transform(trsf);
        }
        const EdgeFaceNormals currentNormals = makeNormals(currentNode);
        AppendEdgeSegment(mesh, previous, previousNormals,
                          current, currentNormals,
                          static_cast<std::uint32_t>(edgeIndex));
        previous = current;
        previousNormals = currentNormals;
      }

      handled[static_cast<std::size_t>(edgeIndex)] = true;
    }
  }

  // Free edges have no owning face triangulation.  For those only, fall back
  // to the OCCT 3-D polygon stored on the tessellated edge.  This mirrors the
  // FreeCAD path (Part::Tools::polygonOfEdge) without reintroducing analytic
  // curve resampling for normal face boundaries.
  for (Standard_Integer edgeIndex = 1; edgeIndex <= edgeMap.Extent(); ++edgeIndex) {
    if (handled[static_cast<std::size_t>(edgeIndex)] ||
        seamEdge[static_cast<std::size_t>(edgeIndex)]) {
      if (seamEdge[static_cast<std::size_t>(edgeIndex)]) {
        ++mesh.hiddenSeamEdgeCount;
      }
      continue;
    }

    const TopoDS_Edge edge = TopoDS::Edge(edgeMap(edgeIndex));
    if (BRep_Tool::Degenerated(edge)) {
      continue;
    }

    // A face-bound edge for which OCCT produced no polygon-on-triangulation is
    // intentionally not independently resampled; doing so would recreate the
    // very face/edge mismatch this renderer is avoiding.  Only true free edges
    // may use Polygon3D here.
    if (edgeFaces.Contains(edge)) {
      continue;
    }

    TopLoc_Location location;
    Handle(Poly_Polygon3D) poly = BRep_Tool::Polygon3D(edge, location);
    if (poly.IsNull() || poly->NbNodes() < 2) {
      continue;
    }

    const gp_Trsf trsf = location.Transformation();
    const bool transformed = trsf.Form() != gp_Identity;
    const TColgp_Array1OfPnt& nodes = poly->Nodes();
    EdgeFaceNormals normals;
    normals.a = gp_Dir(0.0, 0.0, 1.0);
    normals.b = normals.a;
    normals.count = 1;

    gp_Pnt previous = nodes(nodes.Lower());
    if (transformed) previous.Transform(trsf);
    for (Standard_Integer i = nodes.Lower() + 1; i <= nodes.Upper(); ++i) {
      gp_Pnt current = nodes(i);
      if (transformed) current.Transform(trsf);
      AppendEdgeSegment(mesh, previous, normals, current, normals,
                        static_cast<std::uint32_t>(edgeIndex));
      previous = current;
    }
    handled[static_cast<std::size_t>(edgeIndex)] = true;
  }
}

void AppendTriangle(MeshHandle& mesh, gp_Pnt p1, gp_Pnt p2, gp_Pnt p3,
                    gp_Dir smooth1, gp_Dir smooth2, gp_Dir smooth3,
                    const std::uint32_t faceId) {
  const gp_Vec e1(p1, p2);
  const gp_Vec e2(p1, p3);
  gp_Vec flatNormal = e1.Crossed(e2);
  const double magnitude = flatNormal.Magnitude();
  if (magnitude > 1.0e-14) {
    flatNormal /= magnitude;
  } else {
    flatNormal = gp_Vec(0.0, 0.0, 1.0);
  }

  const std::uint32_t base = static_cast<std::uint32_t>(mesh.positions.size() / 3);
  const gp_Pnt points[3] = {p1, p2, p3};
  const gp_Dir smooth[3] = {smooth1, smooth2, smooth3};
  for (int i = 0; i < 3; ++i) {
    const gp_Pnt& p = points[i];
    mesh.positions.push_back(static_cast<float>(p.X()));
    mesh.positions.push_back(static_cast<float>(p.Y()));
    mesh.positions.push_back(static_cast<float>(p.Z()));
    mesh.normals.push_back(static_cast<float>(flatNormal.X()));
    mesh.normals.push_back(static_cast<float>(flatNormal.Y()));
    mesh.normals.push_back(static_cast<float>(flatNormal.Z()));
    mesh.smoothNormals.push_back(static_cast<float>(smooth[i].X()));
    mesh.smoothNormals.push_back(static_cast<float>(smooth[i].Y()));
    mesh.smoothNormals.push_back(static_cast<float>(smooth[i].Z()));
    mesh.faceIds.push_back(faceId);
  }

  mesh.indices.push_back(base + 0);
  mesh.indices.push_back(base + 1);
  mesh.indices.push_back(base + 2);
}

std::unique_ptr<MeshHandle> TessellateShape(const TopoDS_Shape& shape,
                                            const double linearDeflection) {
  const occt_bridge_options options = CurrentOptions();
  if (options.mesh_keep_existing == 0) {
    BRepTools::Clean(shape);             // force a full remesh
  }
  BRepMesh_IncrementalMesh mesher(shape, MeshParameters(options, linearDeflection));

  auto mesh = std::make_unique<MeshHandle>();

  TopTools_IndexedMapOfShape faceMap;
  TopTools_IndexedMapOfShape edgeMap;
  TopTools_IndexedMapOfShape vertexMap;
  TopExp::MapShapes(shape, TopAbs_FACE, faceMap);
  TopExp::MapShapes(shape, TopAbs_EDGE, edgeMap);
  TopExp::MapShapes(shape, TopAbs_VERTEX, vertexMap);
  mesh->topologyEdgeCount = edgeMap.Extent();

  GProp_GProps properties;
  BRepGProp::VolumeProperties(shape, properties);
  mesh->volume = properties.Mass();

  for (TopExp_Explorer exp(shape, TopAbs_FACE); exp.More(); exp.Next()) {
    const TopoDS_Face face = TopoDS::Face(exp.Current());
    const Standard_Integer faceIndex = faceMap.FindIndex(face);
    if (faceIndex <= 0) {
      continue;
    }
    TopLoc_Location location;
    const Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(face, location);
    if (tri.IsNull()) {
      continue;
    }

    const gp_Trsf trsf = location.Transformation();
    bool reverse = (face.Orientation() == TopAbs_REVERSED);
    if (trsf.IsNegative()) {
      reverse = !reverse;
    }

    // OCCT can compute normals on the per-face triangulation.  Because each
    // TopoDS_Face owns its triangulation, interpolation is smooth inside a
    // curved face while sharp B-Rep face boundaries remain sharp.
    if (!tri->HasNormals()) {
      Poly::ComputeNormals(tri);
    }

    for (Standard_Integer i = 1; i <= tri->NbTriangles(); ++i) {
      Standard_Integer n1 = 0, n2 = 0, n3 = 0;
      tri->Triangle(i).Get(n1, n2, n3);
      if (reverse) {
        std::swap(n2, n3);
      }

      gp_Pnt p1 = tri->Node(n1);
      gp_Pnt p2 = tri->Node(n2);
      gp_Pnt p3 = tri->Node(n3);
      gp_Dir sn1 = tri->Normal(n1);
      gp_Dir sn2 = tri->Normal(n2);
      gp_Dir sn3 = tri->Normal(n3);
      if (trsf.Form() != gp_Identity) {
        p1.Transform(trsf);
        p2.Transform(trsf);
        p3.Transform(trsf);
        sn1.Transform(trsf);
        sn2.Transform(trsf);
        sn3.Transform(trsf);
      }
      if (face.Orientation() == TopAbs_REVERSED) {
        sn1.Reverse();
        sn2.Reverse();
        sn3.Reverse();
      }
      AppendTriangle(*mesh, p1, p2, p3, sn1, sn2, sn3,
                     static_cast<std::uint32_t>(faceIndex));
    }
  }

  if (mesh->indices.empty()) {
    throw Standard_Failure("OCCT tessellation produced no triangles");
  }

  // Build display edges from the same triangulation boundary nodes used
  // above for shaded faces. This keeps shaded and edge representations aligned.
  AppendShapeEdges(*mesh, shape, edgeMap, linearDeflection);   // unused by edges
  if (mesh->edgePositions.empty()) {
    throw Standard_Failure("OCCT edge discretization produced no line segments");
  }

  for (Standard_Integer i = 1; i <= vertexMap.Extent(); ++i) {
    const TopoDS_Vertex vertex = TopoDS::Vertex(vertexMap(i));
    const gp_Pnt p = BRep_Tool::Pnt(vertex);
    mesh->vertexPositions.push_back(static_cast<float>(p.X()));
    mesh->vertexPositions.push_back(static_cast<float>(p.Y()));
    mesh->vertexPositions.push_back(static_cast<float>(p.Z()));
    mesh->vertexIds.push_back(static_cast<std::uint32_t>(i));
  }
  if (mesh->vertexPositions.empty()) {
    throw Standard_Failure("OCCT topology contains no vertices");
  }
  return mesh;
}

std::unique_ptr<ShapeHandle> MakeRectanglePrismShape(
    const double width, const double depth, const double height) {
  if (width <= 0.0 || depth <= 0.0 || height <= 0.0) {
    throw Standard_Failure("Rectangle prism dimensions must be positive");
  }

  const double hx = width * 0.5;
  const double hy = depth * 0.5;
  const double z0 = -height * 0.5;
  BRepBuilderAPI_MakePolygon polygon;
  polygon.Add(gp_Pnt(-hx, -hy, z0));
  polygon.Add(gp_Pnt( hx, -hy, z0));
  polygon.Add(gp_Pnt( hx,  hy, z0));
  polygon.Add(gp_Pnt(-hx,  hy, z0));
  polygon.Close();
  const TopoDS_Shape face = BRepBuilderAPI_MakeFace(polygon.Wire()).Face();
  auto result = std::make_unique<ShapeHandle>();
  result->shape = BRepPrimAPI_MakePrism(face, gp_Vec(0.0, 0.0, height)).Shape();
  if (result->shape.IsNull()) {
    throw Standard_Failure("Rectangle prism creation returned a null shape");
  }
  return result;
}

std::unique_ptr<ShapeHandle> CutCylinderFromShape(
    const ShapeHandle* base, const double radius,
    const double centerX, const double centerY) {
  if (base == nullptr || base->shape.IsNull()) {
    throw Standard_Failure("Boolean cut requires a valid base shape");
  }
  if (radius <= 0.0) {
    throw Standard_Failure("Boolean cutter radius must be positive");
  }

  Bnd_Box bounds;
  BRepBndLib::Add(base->shape, bounds);
  double xmin = 0.0, ymin = 0.0, zmin = -1.0;
  double xmax = 0.0, ymax = 0.0, zmax = 1.0;
  bounds.Get(xmin, ymin, zmin, xmax, ymax, zmax);
  const double span = std::max(1.0, zmax - zmin);
  const double margin = span + 1.0;
  const gp_Ax2 axis(
      gp_Pnt(centerX, centerY, zmin - margin), gp_Dir(0.0, 0.0, 1.0));
  const TopoDS_Shape cutter = BRepPrimAPI_MakeCylinder(
      axis, radius, (zmax - zmin) + 2.0 * margin).Shape();

  auto result = std::make_unique<ShapeHandle>();
  result->shape = OptionedCut(base->shape, cutter);   // speed options applied
  return result;
}
}  // namespace

extern "C" {

// Returns 1 on success, 0 when the struct size or version does not match
// (Pascal and C disagree on the layout: rebuild both from the same header).
int occt_bridge_set_options(const occt_bridge_options* options) {
  gLastError.clear();
  if (options == nullptr || options->struct_size != static_cast<int32_t>(sizeof(occt_bridge_options)) ||
      options->version != OCCT_BRIDGE_OPTIONS_VERSION) {
    SetError("occt_bridge_set_options: struct size or version mismatch");
    return 0;
  }
  {
    std::lock_guard<std::mutex> lock(gOptionsLock);
    gOptions = *options;
  }
  try {
    // Threads OCCT uses inside one operation (meshing, booleans).
    OSD_Parallel::SetUseOcctThreads(true);
    const int threads = options->occt_threads > 0 ? options->occt_threads
                                                  : OSD_Parallel::NbLogicalProcessors();
    OSD_ThreadPool::DefaultPool()->Init(threads);
  } catch (const Standard_Failure& failure) {
    SetError(failure.GetMessageString());
    return 0;
  }
  return 1;
}

int occt_bridge_get_options(occt_bridge_options* options) {
  if (options == nullptr) {
    return 0;
  }
  *options = CurrentOptions();
  return 1;
}

int occt_bridge_options_size() {
  return static_cast<int>(sizeof(occt_bridge_options));
}

const char* occt_bridge_occt_version() {
  return OCC_VERSION_COMPLETE;
}

const char* occt_bridge_last_error() {
  return gLastError.c_str();
}

int occt_bridge_box_volume(double dx, double dy, double dz, double* outVolume) {
  gLastError.clear();

  if (outVolume == nullptr) {
    SetError("outVolume is null");
    return 0;
  }

  try {
    const TopoDS_Shape shape = BRepPrimAPI_MakeBox(dx, dy, dz).Shape();
    GProp_GProps properties;
    BRepGProp::VolumeProperties(shape, properties);
    *outVolume = properties.Mass();
    return 1;
  }
  catch (const Standard_Failure& ex) {
    SetError(ex.GetMessageString());
    return 0;
  }
  catch (const std::exception& ex) {
    SetError(ex.what());
    return 0;
  }
  catch (...) {
    SetError("Unknown C++ exception");
    return 0;
  }
}

void* occt_bridge_create_demo_mesh(int mode, double linearDeflection) {
  gLastError.clear();
  try {
    const TopoDS_Shape shape = BuildDemoShape(mode);
    return TessellateShape(shape, linearDeflection).release();
  }
  catch (const Standard_Failure& ex) {
    SetError(ex.GetMessageString());
    return nullptr;
  }
  catch (const std::exception& ex) {
    SetError(ex.what());
    return nullptr;
  }
  catch (...) {
    SetError("Unknown C++ exception");
    return nullptr;
  }
}

void* occt_bridge_create_gear_base_mesh(double linearDeflection) {
  gLastError.clear();
  try {
    return TessellateShape(StressGearBase(), linearDeflection).release();
  }
  catch (const Standard_Failure& ex) { SetError(ex.GetMessageString()); return nullptr; }
  catch (const std::exception& ex) { SetError(ex.what()); return nullptr; }
  catch (...) { SetError("Unknown C++ exception"); return nullptr; }
}

void* occt_bridge_create_gear_cutter_mesh(double linearDeflection) {
  gLastError.clear();
  try {
    return TessellateShape(BuildStressCutterBase(), linearDeflection).release();
  }
  catch (const Standard_Failure& ex) { SetError(ex.GetMessageString()); return nullptr; }
  catch (const std::exception& ex) { SetError(ex.what()); return nullptr; }
  catch (...) { SetError("Unknown C++ exception"); return nullptr; }
}

void* occt_bridge_create_gear_stress_mesh(double cutterX, double cutterY,
                                          double linearDeflection) {
  gLastError.clear();
  try {
    const TopoDS_Shape shape = BuildStressGearCut(cutterX, cutterY);
    return TessellateShape(shape, linearDeflection).release();
  }
  catch (const Standard_Failure& ex) {
    SetError(ex.GetMessageString());
    return nullptr;
  }
  catch (const std::exception& ex) {
    SetError(ex.what());
    return nullptr;
  }
  catch (...) {
    SetError("Unknown C++ exception");
    return nullptr;
  }
}

void* occt_bridge_create_gear_local_stress_mesh(double cutterX, double cutterY,
                                                double linearDeflection) {
  gLastError.clear();
  try {
    int affected = 0;
    const TopoDS_Shape shape =
      BuildStressGearLocalizedCut(cutterX, cutterY, affected);
    std::unique_ptr<MeshHandle> mesh = TessellateShape(shape, linearDeflection);
    mesh->affectedSectors = affected;
    return mesh.release();
  }
  catch (const Standard_Failure& ex) {
    SetError(ex.GetMessageString());
    return nullptr;
  }
  catch (const std::exception& ex) {
    SetError(ex.what());
    return nullptr;
  }
  catch (...) {
    SetError("Unknown C++ exception");
    return nullptr;
  }
}

void* occt_bridge_create_rectangle_prism_shape(
    double width, double depth, double height) {
  gLastError.clear();
  try {
    std::shared_lock<std::shared_mutex> shared(gTopologyLock);
    return MakeRectanglePrismShape(width, depth, height).release();
  } catch (const Standard_Failure& failure) {
    SetError(failure.GetMessageString());
  } catch (const std::exception& ex) {
    SetError(ex.what());
  } catch (...) {
    SetError("Unknown rectangle prism creation failure");
  }
  return nullptr;
}

void* occt_bridge_cut_cylinder_shape(void* baseHandle, double radius,
                                     double centerX, double centerY) {
  gLastError.clear();
  try {
    std::shared_lock<std::shared_mutex> shared(gTopologyLock);
    return CutCylinderFromShape(
        static_cast<const ShapeHandle*>(baseHandle), radius, centerX, centerY)
        .release();
  } catch (const Standard_Failure& failure) {
    SetError(failure.GetMessageString());
  } catch (const std::exception& ex) {
    SetError(ex.what());
  } catch (...) {
    SetError("Unknown Boolean cut failure");
  }
  return nullptr;
}

// ---------------------------------------------------------------- FPC-CAD features
// All return a new shape handle owned by the caller (occt_bridge_free_shape),
// or nullptr with occt_bridge_last_error().

#define OCCT_BRIDGE_TRY(failureText)                                        \
  catch (const Standard_Failure& failure) { SetError(failure.GetMessageString()); } \
  catch (const std::exception& ex) { SetError(ex.what()); }                 \
  catch (...) { SetError(failureText); }

// Axis-aligned box with its minimum corner at (x, y, z).
void* occt_bridge_make_box(double x, double y, double z,
                           double dx, double dy, double dz) {
  gLastError.clear();
  try {
    std::shared_lock<std::shared_mutex> shared(gTopologyLock);
    if (dx <= 0.0 || dy <= 0.0 || dz <= 0.0) {
      throw Standard_Failure("Box sizes must be positive");
    }
    auto result = std::make_unique<ShapeHandle>();
    result->shape = BRepPrimAPI_MakeBox(gp_Pnt(x, y, z), dx, dy, dz).Shape();
    return result.release();
  } OCCT_BRIDGE_TRY("Unknown box failure")
  return nullptr;
}

// Cylinder along +Z with its bottom centre at (x, y, z).
void* occt_bridge_make_cylinder(double x, double y, double z,
                                double radius, double height) {
  gLastError.clear();
  try {
    std::shared_lock<std::shared_mutex> shared(gTopologyLock);
    if (radius <= 0.0 || height <= 0.0) {
      throw Standard_Failure("Cylinder radius and height must be positive");
    }
    auto result = std::make_unique<ShapeHandle>();
    result->shape = BRepPrimAPI_MakeCylinder(
        gp_Ax2(gp_Pnt(x, y, z), gp_Dir(0.0, 0.0, 1.0)), radius, height).Shape();
    return result.release();
  } OCCT_BRIDGE_TRY("Unknown cylinder failure")
  return nullptr;
}

// op: 0 cut (object - tool), 1 fuse, 2 common. Inputs are not modified
// when the NonDestructive option is on (default).
void* occt_bridge_boolean(int op, void* objectHandle, void* toolHandle) {
  gLastError.clear();
  try {
    std::shared_lock<std::shared_mutex> shared(gTopologyLock);
    const ShapeHandle* object = static_cast<const ShapeHandle*>(objectHandle);
    const ShapeHandle* tool = static_cast<const ShapeHandle*>(toolHandle);
    if (object == nullptr || tool == nullptr || object->shape.IsNull() || tool->shape.IsNull()) {
      throw Standard_Failure("Boolean needs two valid shapes");
    }
    auto result = std::make_unique<ShapeHandle>();
    result->shape = OptionedBoolean(op, object->shape, tool->shape);
    return result.release();
  } OCCT_BRIDGE_TRY("Unknown boolean failure")
  return nullptr;
}

// Exact B-rep volume (no meshing needed). Returns -1 on error.
double occt_bridge_shape_volume(void* shapeHandle) {
  gLastError.clear();
  try {
    std::shared_lock<std::shared_mutex> shared(gTopologyLock);
    const ShapeHandle* shape = static_cast<const ShapeHandle*>(shapeHandle);
    if (shape == nullptr || shape->shape.IsNull()) {
      throw Standard_Failure("Volume needs a valid shape");
    }
    GProp_GProps properties;
    BRepGProp::VolumeProperties(shape->shape, properties);
    return properties.Mass();
  } OCCT_BRIDGE_TRY("Unknown volume failure")
  return -1.0;
}

void occt_bridge_free_shape(void* handle) {
  delete static_cast<ShapeHandle*>(handle);
}

void* occt_bridge_mesh_shape(void* shapeHandle, double linearDeflection) {
  gLastError.clear();
  try {
    std::unique_lock<std::shared_mutex> exclusive(gTopologyLock);
    const ShapeHandle* shape = static_cast<const ShapeHandle*>(shapeHandle);
    if (shape == nullptr || shape->shape.IsNull()) {
      throw Standard_Failure("Tessellation requires a valid shape handle");
    }
    return TessellateShape(shape->shape, linearDeflection).release();
  } catch (const Standard_Failure& failure) {
    SetError(failure.GetMessageString());
  } catch (const std::exception& ex) {
    SetError(ex.what());
  } catch (...) {
    SetError("Unknown shape tessellation failure");
  }
  return nullptr;
}

void occt_bridge_free_demo_mesh(void* handle) {
  delete static_cast<MeshHandle*>(handle);
}

int occt_bridge_mesh_vertex_count(void* handle) {
  const MeshHandle* mesh = static_cast<const MeshHandle*>(handle);
  return mesh ? static_cast<int>(mesh->positions.size() / 3) : 0;
}

int occt_bridge_mesh_index_count(void* handle) {
  const MeshHandle* mesh = static_cast<const MeshHandle*>(handle);
  return mesh ? static_cast<int>(mesh->indices.size()) : 0;
}

const float* occt_bridge_mesh_positions(void* handle) {
  const MeshHandle* mesh = static_cast<const MeshHandle*>(handle);
  return (mesh && !mesh->positions.empty()) ? mesh->positions.data() : nullptr;
}

const float* occt_bridge_mesh_normals(void* handle) {
  const MeshHandle* mesh = static_cast<const MeshHandle*>(handle);
  return (mesh && !mesh->normals.empty()) ? mesh->normals.data() : nullptr;
}

const float* occt_bridge_mesh_smooth_normals(void* handle) {
  const MeshHandle* mesh = static_cast<const MeshHandle*>(handle);
  return (mesh && !mesh->smoothNormals.empty())
             ? mesh->smoothNormals.data()
             : nullptr;
}

const std::uint32_t* occt_bridge_mesh_indices(void* handle) {
  const MeshHandle* mesh = static_cast<const MeshHandle*>(handle);
  return (mesh && !mesh->indices.empty()) ? mesh->indices.data() : nullptr;
}

const std::uint32_t* occt_bridge_mesh_face_ids(void* handle) {
  const MeshHandle* mesh = static_cast<const MeshHandle*>(handle);
  return (mesh && !mesh->faceIds.empty()) ? mesh->faceIds.data() : nullptr;
}

int occt_bridge_mesh_edge_vertex_count(void* handle) {
  const MeshHandle* mesh = static_cast<const MeshHandle*>(handle);
  return mesh ? static_cast<int>(mesh->edgePositions.size() / 3) : 0;
}

const float* occt_bridge_mesh_edge_positions(void* handle) {
  const MeshHandle* mesh = static_cast<const MeshHandle*>(handle);
  return (mesh && !mesh->edgePositions.empty()) ? mesh->edgePositions.data() : nullptr;
}

const float* occt_bridge_mesh_edge_normal_a(void* handle) {
  const MeshHandle* mesh = static_cast<const MeshHandle*>(handle);
  return (mesh && !mesh->edgeNormalA.empty()) ? mesh->edgeNormalA.data() : nullptr;
}

const float* occt_bridge_mesh_edge_normal_b(void* handle) {
  const MeshHandle* mesh = static_cast<const MeshHandle*>(handle);
  return (mesh && !mesh->edgeNormalB.empty()) ? mesh->edgeNormalB.data() : nullptr;
}

const std::uint32_t* occt_bridge_mesh_edge_face_counts(void* handle) {
  const MeshHandle* mesh = static_cast<const MeshHandle*>(handle);
  return (mesh && !mesh->edgeFaceCounts.empty()) ? mesh->edgeFaceCounts.data() : nullptr;
}

const std::uint32_t* occt_bridge_mesh_edge_ids(void* handle) {
  const MeshHandle* mesh = static_cast<const MeshHandle*>(handle);
  return (mesh && !mesh->edgeIds.empty()) ? mesh->edgeIds.data() : nullptr;
}

int occt_bridge_mesh_topology_edge_count(void* handle) {
  const MeshHandle* mesh = static_cast<const MeshHandle*>(handle);
  return mesh ? mesh->topologyEdgeCount : 0;
}

int occt_bridge_mesh_hidden_seam_edge_count(void* handle) {
  const MeshHandle* mesh = static_cast<const MeshHandle*>(handle);
  return mesh ? mesh->hiddenSeamEdgeCount : 0;
}

int occt_bridge_mesh_topology_vertex_count(void* handle) {
  const MeshHandle* mesh = static_cast<const MeshHandle*>(handle);
  return mesh ? static_cast<int>(mesh->vertexPositions.size() / 3) : 0;
}

const float* occt_bridge_mesh_topology_vertex_positions(void* handle) {
  const MeshHandle* mesh = static_cast<const MeshHandle*>(handle);
  return (mesh && !mesh->vertexPositions.empty())
             ? mesh->vertexPositions.data()
             : nullptr;
}

const std::uint32_t* occt_bridge_mesh_topology_vertex_ids(void* handle) {
  const MeshHandle* mesh = static_cast<const MeshHandle*>(handle);
  return (mesh && !mesh->vertexIds.empty()) ? mesh->vertexIds.data() : nullptr;
}

double occt_bridge_mesh_volume(void* handle) {
  const MeshHandle* mesh = static_cast<const MeshHandle*>(handle);
  return mesh ? mesh->volume : 0.0;
}

int occt_bridge_mesh_affected_sector_count(void* handle) {
  const MeshHandle* mesh = static_cast<const MeshHandle*>(handle);
  return mesh ? mesh->affectedSectors : 0;
}

}  // extern "C"
