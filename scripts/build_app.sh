#!/usr/bin/env bash
# Builds the OCCT bridge and the FPC-CAD application (./fpc_cad in the repo root).
#   bash scripts/build_app.sh && ./fpc_cad
# Needs: lazbuild (Lazarus with LazOpenGLContext), g++, OCCT, and the engine
# checked out next to this repo as ../FPC-OpenGL-UI-Engine at the commit in
# engine/ENGINE_REF.txt (a different commit only warns).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAZBUILD="${LAZBUILD:-$(command -v lazbuild || true)}"
[[ -n "$LAZBUILD" ]] || { echo "BLOCKED: lazbuild not found (set LAZBUILD=/path/to/lazbuild)" >&2; exit 2; }
ENGINE_DIR="$ROOT/../FPC-OpenGL-UI-Engine"
[[ -f "$ENGINE_DIR/src/ui/opengl.ui.viewport3d.pas" ]] || {
  echo "BLOCKED: engine not found at $ENGINE_DIR" >&2; exit 2; }
WANT="$(sed -n 's/^commit=//p' "$ROOT/engine/ENGINE_REF.txt")"
HAVE="$(git -C "$ENGINE_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
[[ "$HAVE" == "$WANT" ]] || echo "WARN  engine at $HAVE, ENGINE_REF wants $WANT"
bash "$ROOT/external/occt_bridge/build.sh"
LOG="${TMPDIR:-/tmp}/fpccad-app-build.log"
if ! "$LAZBUILD" -q "$ROOT/app/fpc_cad.lpi" > "$LOG" 2>&1; then
  echo "BUILD FAILED (log: $LOG)" >&2
  grep -E "Error|Fatal" "$LOG" | head -20 >&2
  exit 2
fi
echo "OK  $ROOT/fpc_cad"
