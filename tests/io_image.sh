#!/bin/sh
# Native resources reload stale; managed read-ahead and pending output persist.
set -eu
SHEN=$1
dir=$(mktemp -d)
trap 'io_test_status=$?; if [ "$io_test_status" -ne 0 ]; then cat "$dir"/*.out 2>/dev/null; fi; rm -rf "$dir"' EXIT
if command -v cygpath > /dev/null; then dir=$(cygpath -m "$dir"); fi
printf xyz > "$dir/input"
"$SHEN" --save "$dir/io.img" eval -l lib/ffi.shen -l lib/buffer.shen -l lib/io.shen -l lib/io-file.shen \
  -e "(set io-image.path \"$dir/input\")" \
  -e '(do (set io-image.reader (io.reader (io.input-buffer (buffer.from-string "abcdef")) [[chunk-size 3]])) true)' \
  -e '(io.peek (value io-image.reader) 3)' -e '(do (io.consume (value io-image.reader) 2) true)' \
  -e '(set io-image.output (buffer.new 3))' \
  -e '(do (set io-image.endpoint (io.output-buffer (value io-image.output))) true)' \
  -e '(do (set io-image.writer (io.writer (value io-image.endpoint) [])) true)' \
  -e '(io.write (value io-image.writer) (buffer.from-string "abc"))' \
  -e '(do (set io-image.native (io.open-file (value io-image.path) read)) true)' > "$dir/save.out" 2>&1
SHEN_JIT_IMAGE="$dir/io.img" "$SHEN" eval \
  -e '(let R (value io-image.reader) A (io.position R) B (buffer.string (hd (tl (io.read-all R 4)))) _ (io.close (value io-image.endpoint)) (output "managed: ~A ~A ~A~%" A B (buffer.string (value io-image.output))))' \
  -e '(let Old (value io-image.native) Fresh (io.open-file (value io-image.path) read) (if (= (hd Old) error) (output "native unavailable~%") (let E (hd (tl Old)) _ (output "stale: ~A~%" (trap-error (do (io.read-some E (buffer.new 0) []) false) (/. X true))) _ (io.close E) New (hd (tl Fresh)) V (buffer.new 3) Read (io.read-exact New V []) _ (io.close New) (output "fresh: ~A ~A~%" Read (buffer.string V)))))' \
  > "$dir/load.out" 2>&1
grep -qxF 'managed: 2 cdef abc' "$dir/load.out"
if ! grep -qxF 'native unavailable' "$dir/load.out"; then
  grep -qxF 'stale: true' "$dir/load.out"
  grep -qxF 'fresh: [ok 3] xyz' "$dir/load.out"
fi
gc=0
if [ "${TEST_GC_STRESS:-}" = 1 ]; then # a collection at every allocation: make test-lib-stress
    SHEN_JIT_IMAGE="$dir/io.img" SHEN_JIT_GC_STRESS=1 "$SHEN" eval -l tests/io_gc.shen > "$dir/gc.out" 2>&1
    grep -qxF 'managed gc ok' "$dir/gc.out"
    grep -q '^native gc ' "$dir/gc.out"
    gc=1
fi
printf '(define wrong-reader {number --> io.chunk-result} N -> (io.read-chunk N))\n' > "$dir/wrong.shen"
if "$SHEN" eval -l lib/buffer.shen -l lib/io.shen -e '(tc +)' -l "$dir/wrong.shen" > "$dir/wrong.out" 2>&1; then
  echo 'typed I/O misuse was accepted'
  exit 1
fi
grep -q 'type error' "$dir/wrong.out"
echo "$((3 + gc)) passed, 0 failed"
