#!/bin/sh
set -eu
SHEN=$1
dir=$(mktemp -d)
trap 'fs_test_status=$?; if [ "$fs_test_status" -ne 0 ]; then cat "$dir"/*.out 2>/dev/null; fi; rm -rf "$dir"' EXIT
if command -v cygpath > /dev/null; then dir=$(cygpath -m "$dir"); fi
"$SHEN" eval -l lib/ffi.shen -l lib/buffer.shen -l lib/io.shen -l lib/io-file.shen -l lib/fs.shen \
  -l tests/fs_pure.shen > "$dir/pure.out" 2>&1
grep -a '^[0-9]* passed\|^FAIL' "$dir/pure.out" | awk '{ print } END { exit !/ 0 failed/ }'
"$SHEN" eval -l lib/ffi.shen \
  -e '(shen-jit.library fs-probe ["libc.so.6" "libSystem.dylib" "ucrtbase.dll"])' \
  -e '(define-foreign fs-probe.abs fs-probe "abs" (int32) --> int32)' \
  -e '(output "fs shared: ~A~%"
        (trap-error (fs-probe.abs -1)
          (/. E (if (= (error-to-string E) "foreign: this static build cannot load libraries")
                    static
                    (simple-error (error-to-string E))))))' > "$dir/probe.out" 2>&1
if grep -q '^fs shared: static' "$dir/probe.out"; then
    echo 'fs: native checks skipped (a static build cannot load libraries)'
    exit 0
fi
grep -q '^fs shared: 1' "$dir/probe.out"
adapter="$dir/shen-fs.so"
if [ "${OS:-}" = Windows_NT ]; then adapter="$dir/shen-fs.dll"; fi
sh lib/build-fs.sh "$adapter"
python=python3
if ! command -v "$python" > /dev/null; then python=python; fi
"$python" tests/fs.py "$SHEN" "$adapter"
