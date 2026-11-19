#!/bin/sh
# The model/reader run on static builds too; only native filesystem application checks are skipped.
set -eu
SHEN=$1
dir=$(mktemp -d)
trap 'status=$?; if [ "$status" -ne 0 ]; then cat "$dir"/*.out 2>/dev/null; fi; rm -rf "$dir"' EXIT
if command -v cygpath > /dev/null; then dir=$(cygpath -m "$dir"); fi
"$SHEN" eval -m example-apps/source-deps/source-deps.shenmod -l tests/source_deps.shen > "$dir/pure.out" 2>&1
grep -a '^FAIL\|^[0-9]* passed' "$dir/pure.out" | awk '{ print } END { exit !/ 0 failed/ }'
"$SHEN" eval -m example-apps/source-facts/source-facts.shenmod \
    -m example-apps/source-deps/source-deps.shenmod -l tests/source_output_errors.shen > "$dir/write-errors.out" 2>&1
grep -qx '2 passed, 0 failed (report write errors)' "$dir/write-errors.out"
"$SHEN" eval -m ffi \
    -e '(shen-jit.library sd-probe ["libc.so.6" "libSystem.dylib" "ucrtbase.dll"])' \
    -e '(define-foreign sd-probe.abs sd-probe "abs" (int32) --> int32)' \
    -e '(output "source-deps shared: ~A~%"
          (trap-error (sd-probe.abs -1)
            (/. E (if (= (error-to-string E) "foreign: this static build cannot load libraries")
                      static (simple-error (error-to-string E))))))' > "$dir/probe.out" 2>&1
if grep -q '^source-deps shared: static' "$dir/probe.out"; then
    echo 'source-deps: native checks skipped (a static build cannot load libraries)'
    exit 0
fi
grep -q '^source-deps shared: 1' "$dir/probe.out"
adapter="$dir/shen-fs.so"
if [ "${OS:-}" = Windows_NT ]; then adapter="$dir/shen-fs.dll"; fi
sh lib/build-fs.sh "$adapter"
python=python3
if ! command -v "$python" > /dev/null; then python=python; fi
"$python" tests/source_deps.py "$SHEN" "$adapter" "$dir"
