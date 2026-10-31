/* OCCT speed options passed from Pascal (CAD.OCCT.Options) to the bridge.
 *
 * ROLE:      one plain C struct = the OCCT part of TCADPerformanceOptions
 *            (src/config/cad.config.performance.pas, docs/PERFORMANCE.md).
 * CALLED BY: occt_bridge_set_options / occt_bridge_get_options.
 * THREADS:   the bridge copies the struct under a mutex; every operation
 *            reads one consistent copy at its start.
 * ABI RULE:  doubles first, then 32-bit ints, no other types, so the C and
 *            the Pascal ({$PACKRECORDS C}) layouts are identical. The Pascal
 *            side passes struct_size; the bridge rejects a different size.
 *            Append new fields at the end of their group and bump version. */
#ifndef OCCT_BRIDGE_OPTIONS_H
#define OCCT_BRIDGE_OPTIONS_H

#include <stdint.h>

#define OCCT_BRIDGE_OPTIONS_VERSION 1

typedef struct occt_bridge_options {
  int32_t struct_size;               /* sizeof(occt_bridge_options) */
  int32_t version;                   /* OCCT_BRIDGE_OPTIONS_VERSION */

  /* --- doubles --- */
  double mesh_linear_deflection;     /* mm, or a size ratio when mesh_relative */
  double mesh_angular_deflection_deg;
  double mesh_min_size;              /* 0 = OCCT default */
  double bool_fuzzy_value;           /* 0 = exact */

  /* --- 32-bit ints (booleans are 0/1) --- */
  int32_t mesh_in_parallel;          /* IMeshTools_Parameters::InParallel */
  int32_t mesh_relative;             /* ::Relative */
  int32_t mesh_control_surface_deflection; /* ::ControlSurfaceDeflection */
  int32_t mesh_allow_quality_decrease;     /* ::AllowQualityDecrease */
  int32_t mesh_keep_existing;        /* 1 = do not clean an existing mesh */
  int32_t bool_run_parallel;         /* BOPAlgo_Options::SetRunParallel */
  int32_t bool_use_obb;              /* ::SetUseOBB */
  int32_t bool_glue;                 /* 0 off, 1 shift, 2 full (BOPAlgo_GlueEnum) */
  int32_t bool_non_destructive;      /* ::SetNonDestructive */
  int32_t bool_check_inverted;       /* BRepAlgoAPI_BuilderAlgo::SetCheckInverted */
  int32_t occt_threads;              /* OSD_ThreadPool size, 0 = all cores */
  int32_t reserved;                  /* keeps the size a multiple of 8 */
} occt_bridge_options;

#endif
