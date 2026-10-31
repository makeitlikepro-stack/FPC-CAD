#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/occt_bridge.cpp"
OUT="$SCRIPT_DIR/libocct_bridge.so"
# Override for a non-standard OCCT install (e.g. a FreeCAD bundle):
#   OCCT_INCLUDE=/path/to/include/opencascade OCCT_LIB=/path/to/lib ./build.sh
INCLUDE_DIR="${OCCT_INCLUDE:-/usr/include/opencascade}"
LIB_DIR="${OCCT_LIB:-}"
FORCE_BUILD=0

if [[ "${1:-}" == "--force" ]]; then
  FORCE_BUILD=1
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--force]" >&2
  exit 2
fi

if [[ ! -f "$INCLUDE_DIR/BRepPrimAPI_MakeBox.hxx" ]]; then
  echo "OCCT development headers were not found in $INCLUDE_DIR" >&2
  echo "Install the OCCT development packages required by this project." >&2
  exit 1
fi

needs_rebuild() {
  [[ $FORCE_BUILD -eq 1 ]] && return 0
  [[ ! -f "$OUT" ]] && return 0
  [[ "$SOURCE" -nt "$OUT" ]] && return 0
  [[ "$SCRIPT_DIR/occt_bridge_options.h" -nt "$OUT" ]] && return 0
  [[ "${BASH_SOURCE[0]}" -nt "$OUT" ]] && return 0
  return 1
}

if ! needs_rebuild; then
  echo "OCCT bridge is up to date: $OUT"
  exit 0
fi

TMP_OUT="$OUT.tmp.$$"
trap 'rm -f "$TMP_OUT"' EXIT

echo "Building OCCT bridge..."
g++ -std=c++17 -O2 -fPIC -shared \
  "$SOURCE" \
  -I"$INCLUDE_DIR" -I"$SCRIPT_DIR" ${LIB_DIR:+-L"$LIB_DIR" -Wl,-rpath,"$LIB_DIR"} \
  -o "$TMP_OUT" \
  -lTKFillet -lTKBO -lTKMesh -lTKPrim -lTKTopAlgo -lTKBRep -lTKGeomAlgo \
  -lTKG3d -lTKG2d -lTKGeomBase -lTKMath -lTKernel

mv -f "$TMP_OUT" "$OUT"
trap - EXIT

echo "Built: $OUT"
ldd "$OUT" | grep -E 'TK|not found' || true
