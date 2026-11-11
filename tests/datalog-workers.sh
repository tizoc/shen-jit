#!/bin/sh
# The key-partitioned prototype's checks, without needing Souffle.
set -eu
SHEN=${1:-build/shen-jit}
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
if command -v cygpath >/dev/null; then dir=$(cygpath -m "$dir"); fi
image="$dir/datalog-worker"
"$SHEN" eval -q -l lib/native.shen -l lib/datalog.shen -l lib/buffer.shen \
  -l lib/parallel.shen -l lib/parallel-map.shen -l lib/datalog-parallel.shen \
  -e "(shen-jit.save-executable \"$image\" [])"
"$SHEN" eval -q -l lib/native.shen -l lib/datalog.shen -l lib/buffer.shen \
  -l lib/parallel.shen -l lib/parallel-map.shen -l lib/datalog-parallel.shen \
  -l tests/bench/datalog.shen -e '(set *hush* false)' \
  -e "(set dwt.image \"$image\")" -l tests/datalog-workers.shen > "$dir/checks" 2>&1
grep -a '^FAIL\|^[0-9]* checks, ' "$dir/checks" |
  awk '{ print } END { exit !/43 checks, 0 failed/ }'
