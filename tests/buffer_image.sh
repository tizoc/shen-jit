#!/bin/sh
# Managed values persist; native owners reload dead; typed misuse is refused.
set -eu
SHEN=$1
dir=$(mktemp -d)
trap 'buffer_test_status=$?; if [ "$buffer_test_status" -ne 0 ]; then cat "$dir"/*.out 2>/dev/null; fi; rm -rf "$dir"' EXIT
if command -v cygpath > /dev/null; then dir=$(cygpath -m "$dir"); fi

"$SHEN" --save "$dir/managed.img" eval -l lib/buffer.shen -l lib/cursor.shen \
  -e '(set buffer-saved.cursor (cursor.skip (cursor.new (buffer.from-string "abcdef")) 2))' \
  > "$dir/save.out" 2>&1
SHEN_JIT_IMAGE="$dir/managed.img" "$SHEN" eval \
  -e '(output "saved: ~A ~A ~A~%" (cursor.position (value buffer-saved.cursor)) (cursor.read (value buffer-saved.cursor)) (buffer.string (cursor.buffer (value buffer-saved.cursor))))' \
  > "$dir/load.out" 2>&1
grep -qxF 'saved: 2 99 abcdef' "$dir/load.out" || { cat "$dir/load.out"; exit 1; }

gc=0
if [ "${TEST_GC_STRESS:-}" = 1 ]; then # a collection at every allocation: make test-lib-stress
    SHEN_JIT_IMAGE="$dir/managed.img" SHEN_JIT_GC_STRESS=1 "$SHEN" eval \
      -l tests/buffer_gc.shen > "$dir/gc.out" 2>&1
    grep -qxF 'gc ok' "$dir/gc.out" || { cat "$dir/gc.out"; exit 1; }
    gc=1
fi

"$SHEN" --save "$dir/foreign.img" eval -l lib/ffi.shen -l lib/memory.shen -l lib/buffer.shen \
  -e '(set buffer-saved.foreign (trap-error (buffer.wrap (memory.alloc 8)) (/. E (if (= (error-to-string E) "foreign: this static build cannot load libraries") [] (simple-error (error-to-string E))))))' \
  > "$dir/foreign-save.out" 2>&1
SHEN_JIT_IMAGE="$dir/foreign.img" "$SHEN" eval \
  -e '(output "foreign: ~A~%" (if (empty? (value buffer-saved.foreign)) unavailable (trap-error (buffer.length (value buffer-saved.foreign)) (/. E (error-to-string E)))))' \
  > "$dir/foreign-load.out" 2>&1
if ! grep -qxF 'foreign: buffer: storage is closed' "$dir/foreign-load.out"; then
  grep -qxF 'foreign: unavailable' "$dir/foreign-load.out" || { cat "$dir/foreign-load.out"; exit 1; }
fi

# A grammar's loop saved before its first call compiles in the loaded image.
printf '(defgrammar <saved.digit> B where (saved.digit? B);)\n(defgrammar <saved.digits> (+ <saved.digit>);)\n(define saved.digit? B -> (and (>= B 48) (<= B 57)))\n' > "$dir/grammar.shen"
"$SHEN" --save "$dir/grammar.img" eval -l lib/buffer.shen -l lib/grammar.shen -l "$dir/grammar.shen" \
  > "$dir/grammar-save.out" 2>&1
SHEN_JIT_IMAGE="$dir/grammar.img" "$SHEN" eval \
  -e '(output "grammar: ~A ~A~%" (grammar.match? <saved.digits> (buffer.from-string "2026")) (grammar.match? <saved.digits> (buffer.from-string "20x")))' \
  > "$dir/grammar-load.out" 2>&1
grep -qxF 'grammar: true false' "$dir/grammar-load.out" || { cat "$dir/grammar-load.out"; exit 1; }

printf '(define wrong-cursor {number --> number} N -> (cursor.peek N))\n' > "$dir/wrong.shen"
if "$SHEN" eval -l lib/buffer.shen -l lib/cursor.shen -e '(tc +)' -l "$dir/wrong.shen" \
     > "$dir/wrong.out" 2>&1; then
  echo 'typed cursor misuse was accepted'
  exit 1
fi
grep -q 'type error' "$dir/wrong.out" || { cat "$dir/wrong.out"; exit 1; }
echo "$((4 + gc)) passed, 0 failed"
