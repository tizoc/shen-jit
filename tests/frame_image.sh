#!/bin/sh
set -eu
SHEN=$1
dir=$(mktemp -d)
trap 'frame_test_status=$?; if [ "$frame_test_status" -ne 0 ]; then cat "$dir"/*.out 2>/dev/null; fi; rm -rf "$dir"' EXIT
if command -v cygpath > /dev/null; then dir=$(cygpath -m "$dir"); fi
"$SHEN" --save "$dir/frame.img" eval -l lib/buffer.shen -l lib/io.shen -l lib/frame.shen \
  -e '(do (set frame-image.reader (let A (frame.encode 1 (buffer.from-string "a") 8) B (frame.encode 2 (buffer.from-string "bc") 8) Wire (buffer.new 15) _ (buffer.copy! Wire 0 A 0 7) _ (buffer.copy! Wire 7 B 0 8) (frame.reader (io.reader (io.input-buffer Wire) []) 8))) true)' \
  -e '(frame.next (value frame-image.reader))' > "$dir/save.out" 2>&1
SHEN_JIT_IMAGE="$dir/frame.img" "$SHEN" eval \
  -e '(let F (value frame-image.reader) Result (frame.next F) (output "saved: ~A ~A ~A ~A~%" (hd (tl Result)) (buffer.string (hd (tl (tl Result)))) (frame.position F) (frame.next F)))' > "$dir/load.out" 2>&1
grep -qxF 'saved: 2 bc 15 [eof]' "$dir/load.out"
gc=0
if [ "${TEST_GC_STRESS:-}" = 1 ]; then # a collection at every allocation: make test-lib-stress
    SHEN_JIT_IMAGE="$dir/frame.img" SHEN_JIT_GC_STRESS=1 "$SHEN" eval -l tests/frame_gc.shen > "$dir/gc.out" 2>&1
    grep -qxF 'frame gc ok' "$dir/gc.out"
    gc=1
fi
printf '(define wrong-frame {number --> frame.result} N -> (frame.next N))\n' > "$dir/wrong.shen"
if "$SHEN" eval -l lib/buffer.shen -l lib/io.shen -l lib/frame.shen -e '(tc +)' -l "$dir/wrong.shen" > "$dir/wrong.out" 2>&1; then
  echo 'typed framing misuse was accepted'
  exit 1
fi
grep -q 'type error' "$dir/wrong.out"
echo "$((2 + gc)) passed, 0 failed"
