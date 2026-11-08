#!/bin/sh
# Pure checks always run. Native subprocesses require a shared-capable executable.
set -eu
SHEN=$1
dir=$(mktemp -d)
trap 'process_status=$?; if [ "$process_status" -ne 0 ]; then cat "$dir"/*.out 2>/dev/null; fi; rm -rf "$dir"' EXIT
if command -v cygpath > /dev/null; then dir=$(cygpath -m "$dir"); fi
"$SHEN" eval -l lib/ffi.shen -l lib/buffer.shen -l lib/io.shen -l lib/io-file.shen \
  -l lib/deadline.shen -l lib/clock.shen -l lib/process.shen -l lib/process-io.shen \
  -l tests/process_pure.shen > "$dir/pure.out" 2>&1
grep -a '^[0-9]* passed\|^FAIL' "$dir/pure.out" | awk '{ print } END { exit !/ 0 failed/ }'
"$SHEN" eval -l lib/ffi.shen \
  -e '(shen-jit.library process-probe ["libc.so.6" "libSystem.dylib" "ucrtbase.dll"])' \
  -e '(define-foreign process-probe.abs process-probe "abs" (int32) --> int32)' \
  -e '(output "process shared: ~A~%"
        (trap-error (process-probe.abs -1)
          (/. E (if (= (error-to-string E) "foreign: this static build cannot load libraries")
                    static (simple-error (error-to-string E))))))' > "$dir/probe.out" 2>&1
if grep -q '^process shared: static' "$dir/probe.out"; then
    echo 'process: native checks skipped (a static build cannot load libraries)'
    exit 0
fi
grep -q '^process shared: 1' "$dir/probe.out"
adapter="$dir/shen-process.so"
helper="$dir/process-child"
helper_flags=
if [ "${OS:-}" = Windows_NT ]; then
    adapter="$dir/shen-process.dll"
    helper="$helper.exe"
    helper_flags=-municode
fi
sh lib/build-process.sh "$adapter"
fs_adapter="$dir/shen-fs.so"
if [ "${OS:-}" = Windows_NT ]; then fs_adapter="$dir/shen-fs.dll"; fi
sh lib/build-fs.sh "$fs_adapter"
${CC:-cc} -std=c11 ${CFLAGS:--O2 -g} -Wall -Wextra $helper_flags tests/process_child.c -o "$helper"
python=python3
if ! command -v "$python" > /dev/null; then python=python; fi
"$python" tests/process.py "$SHEN" "$adapter" "$helper" "$fs_adapter"
