#!/bin/sh
set -eu
SHEN=$1
dir=$(mktemp -d)
trap 'listener_status=$?; if [ "$listener_status" -ne 0 ]; then cat "$dir"/*.out 2>/dev/null; fi; rm -rf "$dir"' EXIT
if command -v cygpath > /dev/null; then dir=$(cygpath -m "$dir"); fi
set --
for name in ffi socket sqlite buffer io grammar json deadline clock io-socket http-head http-request http-response http-server http-listener; do
    set -- "$@" -l "lib/$name.shen"
done
if ! "$SHEN" eval "$@" -e '(clock.monotonic)' > "$dir/probe.out" 2>&1; then
    if grep -qFx 'shen-jit: uncaught error: foreign: this static build cannot load libraries' "$dir/probe.out"; then
        echo '0 passed, 0 failed (static build: native listener unavailable)'
        exit 0
    fi
    exit 1
fi
run_case() {
    "$@" > "$dir/test.out" 2>&1
    grep '^[0-9]* passed' "$dir/test.out" | awk '{ print } END { exit !/ 0 failed/ }'
}
run_case "$SHEN" eval "$@" -l tests/http_listener.shen
run_case "$SHEN" eval "$@" -l tests/http_connection.shen
run_case "$SHEN" eval "$@" -e '(tc +)' -l tests/http_listener_typed.shen
sh tests/refused.sh "$SHEN" tests/http_listener_refused.shen "$@" > "$dir/refused.out" 2>&1 || { cat "$dir/refused.out"; exit 1; }
run_case "$SHEN" eval "$@" -l example-apps/sqlite-http/main.shen \
    -s counter-test.path "\"$dir/counters.db\"" -l tests/sqlite_http.shen
run_case "$SHEN" eval "$@" -l example-apps/sqlite-http/main.shen \
    -s export-test.path "\"$dir/exports.db\"" -l tests/http_export.shen
"$SHEN" --save "$dir/listener.img" eval "$@" -l example-apps/sqlite-http/main.shen \
    -e '(set listener-image.server (http.listen "127.0.0.1" 0 (/. Q (http.response 200 [] (buffer.new 0))) []))' \
    -e '(http.stop (value listener-image.server))' \
    -e '(http.wait (value listener-image.server) 2000)' > "$dir/save.out" 2>&1
SHEN_JIT_IMAGE="$dir/listener.img" "$SHEN" eval \
    -e '(output "saved: ~A~%" (trap-error (http.stop (value listener-image.server)) (/. X (error-to-string X))))' \
    > "$dir/load.out" 2>&1
grep -qxF 'saved: http: saved servers must be recreated' "$dir/load.out"
gc=0
if [ "${TEST_GC_STRESS:-}" = 1 ]; then # a collection at every allocation: make test-lib-stress
    SHEN_JIT_IMAGE="$dir/listener.img" SHEN_JIT_GC_STRESS=1 "$SHEN" eval \
        -l tests/http_listener_gc.shen > "$dir/gc.out" 2>&1
    grep -qxF 'listener gc ok' "$dir/gc.out"
    SHEN_JIT_IMAGE="$dir/listener.img" SHEN_JIT_GC_STRESS=1 "$SHEN" eval \
        -s export-gc.path "\"$dir/export-gc.db\"" -l tests/http_export_gc.shen > "$dir/export-gc.out" 2>&1
    grep -qxF 'export gc ok' "$dir/export-gc.out"
    gc=2
fi
echo "$((1 + gc)) passed, 0 failed"
