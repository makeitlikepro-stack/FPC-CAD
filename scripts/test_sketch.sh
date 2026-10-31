#!/usr/bin/env bash
# Runs the sketch model and solver tests (no OCCT, no engine).
#   bash scripts/test_sketch.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FPC="${FPC:-$(command -v fpc || true)}"
[[ -n "$FPC" ]] || { echo "BLOCKED: fpc not found (set FPC=/path/to/fpc)" >&2; exit 2; }
OUT="${OUTDIR:-$(mktemp -d "${TMPDIR:-/tmp}/fpccad-sketch.XXXXXX")}"
for PROG in sketch_tests trim_extend_tests region_tests extrude_options_tests; do
  if ! "$FPC" -Mobjfpc -Sa -gl -O2 "-Fu$ROOT/src/sketch" \
      "-FU$OUT" "-FE$OUT" "$ROOT/tests/sketch/$PROG.lpr" > "$OUT/build-$PROG.log" 2>&1; then
    echo "BUILD FAILED: $PROG (log: $OUT/build-$PROG.log)" >&2
    grep -E "Error|Fatal" "$OUT/build-$PROG.log" | head -20 >&2
    exit 2
  fi
  "$OUT/$PROG"
done
