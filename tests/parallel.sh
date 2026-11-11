#!/bin/sh
set -eu
SHEN=$1
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
if command -v cygpath >/dev/null; then dir=$(cygpath -m "$dir"); fi
image="$dir/parallel-worker"
"$SHEN" eval -q -l tests/worker-api.shen -l lib/buffer.shen -l lib/parallel.shen \
  -l lib/parallel-map.shen -l tests/parallel-worker.shen -l tests/parallel-map-worker.shen \
  -e "(shen-jit.save-executable \"$image\" [])" > "$dir/save.out"
"$SHEN" eval -q -l tests/worker-api.shen -l lib/buffer.shen -l lib/parallel.shen -l lib/parallel-map.shen \
  -e "(set pt.image \"$image\")" -e '(set *hush* false)' -l tests/parallel.shen \
  -l tests/parallel-map.shen > "$dir/check.out" 2>&1 || {
  cat "$dir/check.out"; exit 1;
}
grep -a '^FAIL\|^[0-9]* passed' "$dir/check.out" | awk '{ print } END { exit !/ 0 failed/ }'
python=python3
if ! command -v "$python" >/dev/null; then python=python; fi
if command -v "$python" >/dev/null && "$python" -c 'import sys; sys.exit(sys.version_info < (3, 7))'; then
  "$python" tests/parallel_codec.py "$SHEN"
else
  echo 'parallel: independent codec fixtures skipped (Python 3 unavailable)'
fi
sh tests/refused.sh "$SHEN" tests/parallel-refused.shen \
  -q -l lib/buffer.shen -l lib/parallel.shen -l lib/parallel-map.shen
