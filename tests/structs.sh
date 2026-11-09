#!/bin/sh
# Source declarations, namespace clients and schema metadata survive image save/reload.
set -eu
work=$(mktemp -d)
trap 'status=$?; if [ "$status" -ne 0 ]; then cat "$work"/*.log 2>/dev/null; fi; rm -rf "$work"' EXIT
if command -v cygpath > /dev/null; then work=$(cygpath -m "$work"); fi
for shen in "$@"; do
    image="$work/$(basename "$shen").img"
    "$shen" --save "$image" eval -q -l tests/structs-client.shen -l tests/structs.shen > "$work/checks.log" 2>&1
    grep '^[0-9]* passed, 0 failed (structs)' "$work/checks.log"
    SHEN_JIT_IMAGE="$image" "$shen" eval -q -l tests/structs.shen \
      -e '(output "restored constructor: ~A~%" (struct-test.cell.value (struct.make struct-test.cell value <- 42; key <- restored;)))' \
      > "$work/restored.log" 2>&1
    grep '^[0-9]* passed, 0 failed (structs)' "$work/restored.log"
    grep -qxF 'restored constructor: 42' "$work/restored.log"
done
