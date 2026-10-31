#!/usr/bin/env bash
# Builds the OCCT bridge (if needed) and runs the native bridge tests.
#   bash scripts/test_occt.sh
#   OCCT_INCLUDE=/path/include/opencascade OCCT_LIB=/path/lib bash scripts/test_occt.sh
# Needs: g++, OCCT development headers and libraries, fpc.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FPC="${FPC:-$(command -v fpc || true)}"
[[ -n "$FPC" ]] || { echo "BLOCKED: fpc not found (set FPC=/path/to/fpc)" >&2; exit 2; }
bash "$ROOT/external/occt_bridge/build.sh"
OUT="${OUTDIR:-$(mktemp -d "${TMPDIR:-/tmp}/fpccad-occt.XXXXXX")}"
if ! "$FPC" -Mobjfpc -Sa -gl -O2 \
    "-Fu$ROOT/src/core" "-Fu$ROOT/src/config" "-Fu$ROOT/src/occt" \
    "-FU$OUT" "-FE$OUT" "$ROOT/tests/occt/occt_bridge_tests.lpr" > "$OUT/build.log" 2>&1; then
  echo "BUILD FAILED (log: $OUT/build.log)" >&2
  grep -E "Error|Fatal" "$OUT/build.log" | head -20 >&2
  exit 2
fi
OCCT_BRIDGE_LIB="$ROOT/external/occt_bridge/libocct_bridge.so" "$OUT/occt_bridge_tests"
