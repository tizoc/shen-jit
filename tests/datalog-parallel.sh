#!/bin/sh
set -eu
SHEN=${1:-build/shen-jit}
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
if command -v cygpath >/dev/null; then dir=$(cygpath -m "$dir"); fi
libraries='-l lib/native.shen -l lib/datalog.shen -l lib/buffer.shen -l lib/parallel.shen -l lib/parallel-map.shen -l lib/datalog-parallel.shen'
"$SHEN" eval -q $libraries -e "(shen-jit.save-executable \"$dir/worker\" [])"
"$SHEN" eval -q $libraries \
  -e '(define datalog.parallel.worker Request -> (error "deliberate worker failure"))' \
  -e "(shen-jit.save-executable \"$dir/bad-worker\" [])"
"$SHEN" eval -q $libraries -e '(set *hush* false)' \
  -e "(set dpt.image \"$dir/worker\")" -e "(set dpt.bad-image \"$dir/bad-worker\")" \
  -l tests/datalog-parallel.shen \
  -e "(shen-jit.save-executable \"$dir/saved-db\" [])" > "$dir/checks" 2>&1 || {
  cat "$dir/checks"; exit 1;
}
grep -a '^FAIL\|^[0-9]* checks, ' "$dir/checks" |
  awk '{ print } END { exit !/ 0 failed \(parallel Datalog\)/ }'
"$dir/saved-db" eval -q -e '(shen-jit.collect)' \
  -e '(if (= (datalog.sorted (value dpt.saved) path) [[-3 2] [9 12] [99 100]]) true (error "saved parallel database differs"))'
