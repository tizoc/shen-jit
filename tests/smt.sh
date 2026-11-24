#!/bin/sh
# smt (lib/smt.shen): the checks, generated formulas and a typed client.
# Usage: tests/smt.sh path/to/shen-jit [path/to/shen-jit-stlib]
set -eu
SHEN=$1
SHEN_JIT_MAX_HEAP=512M # a bug that never ends must end
export SHEN_JIT_MAX_HEAP
dir=$(mktemp -d)
trap 'smt_status=$?; if [ "$smt_status" -ne 0 ]; then cat "$dir"/*.out 2>/dev/null; fi; rm -rf "$dir"' EXIT
if command -v cygpath > /dev/null; then dir=$(cygpath -m "$dir"); fi

# The standard library defines some of the module's names.
for shen in "$SHEN" ${2:+"$2"}; do
    "$shen" eval -m smt -l tests/smt-generate.shen -l tests/smt.shen > "$dir/smt.out" 2>&1
    grep -a '^FAIL \|^[0-9]* passed' "$dir/smt.out" | awk '{ print } END { exit !/ 0 failed/ }'
done

"$SHEN" eval -m smt -e '(tc +)' -l tests/smt_typed.shen -e '(tc -)' -e '(output "~A~%" (smt-typed.main))' > "$dir/smt-typed.out" 2>&1
grep -qxF 'x 0, y 0, p1 false / true true true unsat' "$dir/smt-typed.out"
echo "1 passed, 0 failed"
