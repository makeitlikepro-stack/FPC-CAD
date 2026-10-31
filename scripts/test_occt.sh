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
export OCCT_BRIDGE_LIB="$ROOT/external/occt_bridge/libocct_bridge.so"
RC=0
for PROG in occt_bridge_tests occt_features_tests occt_sketch_tests; do
  if ! "$FPC" -Mobjfpc -Sa -gl -O2 \
      "-Fu$ROOT/src/core" "-Fu$ROOT/src/config" "-Fu$ROOT/src/occt" "-Fu$ROOT/src/features" "-Fu$ROOT/src/sketch" \
      "-FU$OUT" "-FE$OUT" "$ROOT/tests/occt/$PROG.lpr" > "$OUT/build-$PROG.log" 2>&1; then
    echo "BUILD FAILED: $PROG (log: $OUT/build-$PROG.log)" >&2
    grep -E "Error|Fatal" "$OUT/build-$PROG.log" | head -20 >&2
    exit 2
  fi
  "$OUT/$PROG" || RC=$?
done
exit $RC
