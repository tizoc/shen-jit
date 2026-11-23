#!/bin/sh
# Bignums (lib/bignum.shen): the checks, typed clients, an image, isolates, a closed program and,
# where there is Python, its integers. Needs GMP's library, and skips the rest where there is none.
# Usage: tests/bignum.sh path/to/shen-jit [path/to/shen-jit-stlib]
set -eu
SHEN=$1
dir=$(mktemp -d)
trap 'bignum_status=$?; if [ "$bignum_status" -ne 0 ]; then cat "$dir"/*.out 2>/dev/null; fi; rm -rf "$dir"' EXIT
if command -v cygpath > /dev/null; then dir=$(cygpath -m "$dir"); fi

"$SHEN" eval -m bignum -l tests/bignum.shen > "$dir/checks.out" 2>&1
grep -a '^FAIL \|^[0-9]* passed' "$dir/checks.out" | awk '{ print } END { exit !/ 0 failed/ }'
if grep -aq 'no GMP here' "$dir/checks.out"; then
    echo 'bignum: native checks skipped (no GMP library)'
    exit 0
fi

# The standard library defines some of the module's names.
if [ -n "${2:-}" ]; then
    "$2" eval -m bignum -l tests/bignum.shen > "$dir/stlib.out" 2>&1
    grep -a '^FAIL \|^[0-9]* passed' "$dir/stlib.out" | awk '{ print } END { exit !/ 0 failed/ }'
fi

line='15511210043330985984000000 470 1099511627776 true true 100000000000000000000 1024 100000000000000000009'
"$SHEN" eval -m bignum -e '(tc +)' -l tests/bignum_typed.shen -e '(bignum-typed.main)' > "$dir/typed.out" 2>&1
grep -qxF "$line" "$dir/typed.out"

# The registers are in use as the image is saved, and dead in what loads it.
"$SHEN" --save "$dir/bignum.img" eval -m bignum \
    -e '(set bignum-image.value (bignum.expt 3 100))' -e '(set bignum-image.sum (bignum.+ (value bignum-image.value) 1))' \
    -e '(define bignum-image.loop 0 -> ok N -> (let A (bignum.expt 3 (+ 40 (* 40 N))) (if (= (bignum.sqrt (bignum.* A A)) (bignum.of-string (bignum.to-string A))) (bignum-image.loop (- N 1)) bad)))' \
    > "$dir/save.out" 2>&1
SHEN_JIT_IMAGE="$dir/bignum.img" "$SHEN" eval \
    -e '(output "bignum saved: ~A ~A ~A~%" (= (value bignum-image.sum) (bignum.+ (bignum.expt 3 100) 1)) (bignum.- (value bignum-image.sum) (value bignum-image.value)) (bignum-image.loop 50))' \
    > "$dir/load.out" 2>&1
grep -qxF 'bignum saved: true 1 ok' "$dir/load.out"
passed=2
if [ "${TEST_GC_STRESS:-}" = 1 ]; then # a collection at every allocation: make test-lib-stress
    SHEN_JIT_IMAGE="$dir/bignum.img" SHEN_JIT_GC_STRESS=1 "$SHEN" eval \
        -e '(output "bignum stress: ~A~%" (bignum-image.loop 50))' > "$dir/stress.out" 2>&1
    grep -qxF 'bignum stress: ok' "$dir/stress.out"
    passed=$((passed + 1))
fi

# Each isolate has registers of its own, and an integer goes in and out of one as data.
cat > "$dir/isolates.shen" <<'END'
(define bignum-isolates.square X -> (bignum.* X X))
(output "bignum isolates: ~A~%"
  (= (parallel.map 4 bignum-isolates.square (map (/. N (bignum.expt 10 (+ 20 N))) [1 2 3 4 5 6 7 8]))
     (map (/. N (bignum.expt 10 (+ 40 (* 2 N)))) [1 2 3 4 5 6 7 8])))
END
"$SHEN" eval -m bignum -m parallel -l "$dir/isolates.shen" > "$dir/isolates.out" 2>&1
grep -qxF 'bignum isolates: true' "$dir/isolates.out"

# C functions are kept in a closed program without being named.
cp tests/bignum_typed.shen "$dir/main.shen"
echo '(shen.module (version 1) (name main) (requires bignum) (main bignum-typed.main) (sources tc+ "main.shen"))' > "$dir/main.shenmod"
"$SHEN" build "$dir/main.shenmod" --closed -o "$dir/main.exe" > "$dir/build.out" 2>&1
"$dir/main.exe" > "$dir/main.out" 2>&1
grep -qxF "$line" "$dir/main.out"
echo "$((passed + 2)) passed, 0 failed"

if command -v python3 > /dev/null; then
    python3 tests/bignum_oracle.py "$SHEN"
fi
