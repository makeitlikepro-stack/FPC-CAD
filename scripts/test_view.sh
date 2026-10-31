#!/usr/bin/env bash
# Builds the OCCT bridge and runs the viewport mesh tests (OCCT mesh -> engine).
#   ENGINE_DIR=/path/to/FPC-OpenGL-UI-Engine bash scripts/test_view.sh
# ENGINE_DIR defaults to ../FPC-OpenGL-UI-Engine next to this repo. It should be
# at the commit in engine/ENGINE_REF.txt (a different commit only warns).
# Needs: fpc; for the OCCT part also g++ and OCCT (else that part is skipped).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FPC="${FPC:-$(command -v fpc || true)}"
[[ -n "$FPC" ]] || { echo "BLOCKED: fpc not found (set FPC=/path/to/fpc)" >&2; exit 2; }
ENGINE_DIR="${ENGINE_DIR:-$ROOT/../FPC-OpenGL-UI-Engine}"
[[ -f "$ENGINE_DIR/src/rendering/opengl.render.viewport3dmeshdata.pas" ]] || {
  echo "BLOCKED: engine not found at $ENGINE_DIR (set ENGINE_DIR)" >&2; exit 2; }
WANT="$(sed -n 's/^commit=//p' "$ROOT/engine/ENGINE_REF.txt")"
HAVE="$(git -C "$ENGINE_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
[[ "$HAVE" == "$WANT" ]] || echo "WARN  engine at $HAVE, ENGINE_REF wants $WANT"
if bash "$ROOT/external/occt_bridge/build.sh"; then
  export OCCT_BRIDGE_LIB="$ROOT/external/occt_bridge/libocct_bridge.so"
else
  echo "INFO  bridge build failed: OCCT part will be skipped"
fi
OUT="${OUTDIR:-$(mktemp -d "${TMPDIR:-/tmp}/fpccad-view.XXXXXX")}"
PROG=view_mesh_tests
if ! "$FPC" -Mobjfpc -Sa -gl -O2 \
    "-Fu$ROOT/src/core" "-Fu$ROOT/src/config" "-Fu$ROOT/src/occt" "-Fu$ROOT/src/view" \
    "-Fu$ENGINE_DIR/src/rendering" "-Fu$ENGINE_DIR/src/ui" \
    "-FU$OUT" "-FE$OUT" "$ROOT/tests/view/$PROG.lpr" > "$OUT/build-$PROG.log" 2>&1; then
  echo "BUILD FAILED: $PROG (log: $OUT/build-$PROG.log)" >&2
  grep -E "Error|Fatal" "$OUT/build-$PROG.log" | head -20 >&2
  exit 2
fi
"$OUT/$PROG"
