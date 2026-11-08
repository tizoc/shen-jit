#!/bin/sh
set -eu
SHEN=$1
dir=$(mktemp -d)
trap 'http_test_status=$?; if [ "$http_test_status" -ne 0 ]; then cat "$dir"/*.out 2>/dev/null; fi; rm -rf "$dir"' EXIT
if command -v cygpath > /dev/null; then dir=$(cygpath -m "$dir"); fi
"$SHEN" --save "$dir/http.img" eval -l lib/buffer.shen -l lib/io.shen \
  -l lib/deadline.shen -l lib/http-head.shen \
  -e '(do (set http-image.reader (io.reader (io.input-buffer (buffer.from-string "xc#13;c#10;c#13;c#10;body")) [])) true)' \
  -e '(do (set http-image.head (http.head-reader (value http-image.reader) 8)) true)' \
  -e '(do (set http-image.deadline (deadline.after (freeze 0) 100)) true)' > "$dir/save.out" 2>&1
SHEN_JIT_IMAGE="$dir/http.img" "$SHEN" eval \
  -e '(output "budget stale: ~A~%" (trap-error (do (deadline.remaining (value http-image.deadline)) false) (/. X true)))' \
  -e '(let H (http.read-head (value http-image.head)) B (io.read-all (value http-image.reader) 4) (output "saved: ~A ~A~%" (buffer.length (hd (tl H))) (buffer.string (hd (tl B)))))' > "$dir/load.out" 2>&1
grep -qxF 'budget stale: true' "$dir/load.out"
grep -qxF 'saved: 5 body' "$dir/load.out"
gc=0
if [ "${TEST_GC_STRESS:-}" = 1 ]; then # a collection at every allocation: make test-lib-stress
    SHEN_JIT_IMAGE="$dir/http.img" SHEN_JIT_GC_STRESS=1 "$SHEN" eval -l tests/http_gc.shen > "$dir/gc.out" 2>&1
    grep -qxF 'http gc ok' "$dir/gc.out"
    gc=1
fi
printf '(define wrong-head {number --> http.head-result} N -> (http.read-head N))\n' > "$dir/wrong.shen"
if "$SHEN" eval -l lib/buffer.shen -l lib/io.shen -l lib/http-head.shen \
     -e '(tc +)' -l "$dir/wrong.shen" > "$dir/wrong.out" 2>&1; then
  echo 'typed HTTP framer misuse was accepted'
  exit 1
fi
grep -q 'type error' "$dir/wrong.out"
echo "$((2 + gc)) passed, 0 failed"
