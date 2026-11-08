#!/bin/sh
# Pure validation always runs; native checks need a shared-capable build and libcurl headers.
set -eu
SHEN=$1
dir=$(mktemp -d)
trap 'curl_test_status=$?; if [ "$curl_test_status" -ne 0 ]; then cat "$dir"/*.out 2>/dev/null; fi; rm -rf "$dir"' EXIT
if command -v cygpath > /dev/null; then dir=$(cygpath -m "$dir"); fi
"$SHEN" eval -l lib/ffi.shen -l lib/buffer.shen -l lib/io.shen -l lib/curl.shen \
  -l tests/curl_pure.shen > "$dir/pure.out" 2>&1
grep '^[0-9]* passed' "$dir/pure.out" | awk '{ print } END { exit !/ 0 failed/ }'
"$SHEN" eval -l lib/ffi.shen \
  -e '(shen-jit.library curl-probe ["libc.so.6" "libSystem.dylib" "ucrtbase.dll"])' \
  -e '(define-foreign curl-probe.abs curl-probe "abs" (int32) --> int32)' \
  -e '(output "curl shared: ~A~%"
        (trap-error (curl-probe.abs -1)
          (/. E (if (= (error-to-string E) "foreign: this static build cannot load libraries")
                    static
                    (simple-error (error-to-string E))))))' > "$dir/probe.out" 2>&1
if grep -q '^curl shared: static' "$dir/probe.out"; then
    echo 'curl: native checks skipped (a static build cannot load libraries)'
    exit 0
fi
grep -q '^curl shared: 1' "$dir/probe.out"
adapter="$dir/shen-curl.so"
if [ "${OS:-}" = Windows_NT ]; then adapter="$dir/shen-curl.dll"; fi
sh lib/build-curl.sh "$adapter"
python=python3
if ! command -v "$python" > /dev/null; then python=python; fi
"$python" tests/curl.py "$SHEN" "$adapter"
