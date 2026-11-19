#!/bin/sh
set -eu
SHEN=$1
MODULE=$2
PROTOCOL=$3
WORKLOAD=$4
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
if command -v cygpath > /dev/null; then dir=$(cygpath -m "$dir"); fi

"$SHEN" build "$MODULE" -o "$dir/check"
check="$dir/check"
if [ -f "$check.exe" ]; then check="$check.exe"; fi
"$check" wire

# Same saved program, argument sizes, setup and warmup in each run. GC stress
# charges guest allocations to the collection count. The third run deliberately
# allocates one view per cycle to check that the measurement can detect it.
collections() {
    SHEN_JIT_GC_STRESS=1 SHEN_JIT_STATS=1 "$check" "$1" > "$dir/stats" 2>&1 || {
        cat "$dir/stats" >&2
        return 1
    }
    grep -qx "$PROTOCOL checks passed" "$dir/stats" || { cat "$dir/stats" >&2; return 1; }
    count=$(sed -n 's/^shen-jit: \([0-9][0-9]*\) collections,.*/\1/p' "$dir/stats")
    [ -n "$count" ] || { cat "$dir/stats" >&2; return 1; }
    printf '%s\n' "$count"
}

baseline=$(collections 0)
steady=$(collections 1)
control=$(collections 2)
if [ "$steady" -ne "$baseline" ] || [ "$control" -le "$baseline" ]; then
    echo "$PROTOCOL allocation check failed (baseline $baseline, echo $steady, control $control)" >&2
    exit 1
fi
printf '%s added 0 collections under allocation stress (control added %s)\n' \
    "$WORKLOAD" "$((control - baseline))"
