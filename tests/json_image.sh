#!/bin/sh
set -eu
SHEN=$1
dir=$(mktemp -d)
trap 'json_status=$?; if [ "$json_status" -ne 0 ]; then cat "$dir"/*.out 2>/dev/null; fi; rm -rf "$dir"' EXIT
if command -v cygpath > /dev/null; then dir=$(cygpath -m "$dir"); fi
# Arguments stay ASCII, as Windows passes them in its code page: c#195;c#169; is the UTF-8 of an e with an acute.
"$SHEN" --save "$dir/json.img" eval -l lib/buffer.shen -l lib/grammar.shen -l lib/json.shen \
    -e '(set json-image.value (json.parse "[1,-0,true,c#34;c#195;c#169; c#92;u0000c#34;]" []))' \
    -e '(set json-image.builder (buffer.append! (buffer.builder 16) (buffer.from-string "ab")))' \
    > "$dir/save.out" 2>&1
SHEN_JIT_IMAGE="$dir/json.img" "$SHEN" eval \
    -e '(output "json saved: ~A ~A~%" (= (json.stringify (value json-image.value) []) "[1,-0,true,c#34;c#195;c#169; c#92;u0000c#34;]") (buffer.string (buffer.finish (buffer.append! (value json-image.builder) (buffer.from-string "cd")))))' \
    > "$dir/load.out" 2>&1
grep -qxF 'json saved: true abcd' "$dir/load.out"
gc=0
if [ "${TEST_GC_STRESS:-}" = 1 ]; then # a collection at every allocation: make test-lib-stress
    SHEN_JIT_IMAGE="$dir/json.img" SHEN_JIT_GC_STRESS=1 "$SHEN" eval -l tests/json_gc.shen > "$dir/gc.out" 2>&1
    grep -qxF 'json gc ok' "$dir/gc.out"
    gc=1
fi
printf '(define wrong-json {symbol --> buffer.view} X -> (json.encode X []))\n' > "$dir/wrong.shen"
if "$SHEN" eval -l lib/buffer.shen -l lib/grammar.shen -l lib/json.shen -e '(tc +)' -l "$dir/wrong.shen" > "$dir/wrong.out" 2>&1; then
    echo 'typed JSON misuse was accepted'
    exit 1
fi
grep -q 'type error' "$dir/wrong.out"
echo "$((2 + gc)) passed, 0 failed"
