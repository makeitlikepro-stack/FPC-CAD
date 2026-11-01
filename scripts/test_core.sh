#!/usr/bin/env bash
# Builds and runs the headless core tests (no OCCT, OpenGL or LCL needed).
#   bash scripts/test_core.sh            uses fpc from PATH
#   FPC=/path/to/fpc bash scripts/test_core.sh
# Output: one PASS/FAIL line per failed check, then a summary line.
# Build files go to a temp folder, never into the source tree.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FPC="${FPC:-$(command -v fpc || true)}"
if [[ -z "$FPC" ]]; then
  echo "BLOCKED: fpc not found (set FPC=/path/to/fpc)" >&2
  exit 2
fi
OUT="${OUTDIR:-$(mktemp -d "${TMPDIR:-/tmp}/fpccad-core.XXXXXX")}"
mkdir -p "$OUT"
# -Sa: assertions on; -gl: line info in a crash trace; -O2 like a release build.
for PROG in cad_core_tests cad_object_model_tests cad_body_tip_tests cad_sketch_binding_tests; do
  if ! "$FPC" -Mobjfpc -Sa -gl -O2 \
      "-Fu$ROOT/src/core" "-Fu$ROOT/src/config" \
      "-FU$OUT" "-FE$OUT" "$ROOT/tests/core/$PROG.lpr" > "$OUT/build-$PROG.log" 2>&1; then
    echo "BUILD FAILED: $PROG (log: $OUT/build-$PROG.log)" >&2
    grep -E "Error|Fatal" "$OUT/build-$PROG.log" | head -20 >&2
    exit 2
  fi
  "$OUT/$PROG"
done
