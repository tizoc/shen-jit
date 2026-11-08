#!/bin/sh
set -eu
SHEN=$1
dir=$(mktemp -d)
trap 'request_test_status=$?; if [ "$request_test_status" -ne 0 ]; then cat "$dir"/*.out 2>/dev/null; fi; rm -rf "$dir"' EXIT
if command -v cygpath > /dev/null; then dir=$(cygpath -m "$dir"); fi
"$SHEN" --save "$dir/request.img" eval -l lib/buffer.shen -l lib/io.shen -l lib/grammar.shen -l lib/http-head.shen \
  -l lib/http-request.shen -l lib/http-response.shen \
  -e '(set request-image.request (hd (tl (http.parse-request (buffer.from-string "POST / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;Content-Length: 3c#13;c#10;c#13;c#10;") 3))))' \
  -e '(do (set request-image.body (http.body-reader (io.reader (io.input-buffer (buffer.from-string "abc")) []) (value request-image.request))) true)' \
  -e '(let Q (hd (tl (http.parse-request
                (buffer.from-string "POST / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;Transfer-Encoding: chunkedc#13;c#10;c#13;c#10;") 3)))
           R (io.reader (io.input-buffer (buffer.from-string "3c#13;c#10;abcc#13;c#10;0c#13;c#10;X: yesc#13;c#10;c#13;c#10;")) [])
        (do (set request-image.chunked (http.body-reader R Q)) true))' > "$dir/save.out" 2>&1
SHEN_JIT_IMAGE="$dir/request.img" "$SHEN" eval \
  -e '(let Q (hd (tl (http.read-body (value request-image.body)))) (output "saved: ~A ~A~%" (http.method Q) (buffer.string (http.body Q))))' > "$dir/load.out" 2>&1
grep -qxF 'saved: POST abc' "$dir/load.out"
SHEN_JIT_IMAGE="$dir/request.img" "$SHEN" eval \
  -e '(let Q (hd (tl (http.read-body (value request-image.chunked))))
        (output "saved chunked: ~A ~A~%" (buffer.string (http.body Q)) (= (http.trailers Q) [["x" "yes"]])))' \
  > "$dir/chunked.out" 2>&1
grep -qxF 'saved chunked: abc true' "$dir/chunked.out"
gc=0
if [ "${TEST_GC_STRESS:-}" = 1 ]; then # a collection at every allocation: make test-lib-stress
    SHEN_JIT_IMAGE="$dir/request.img" SHEN_JIT_GC_STRESS=1 "$SHEN" eval \
      -l tests/http_request_gc.shen > "$dir/gc.out" 2>&1
    grep -qxF 'request gc ok' "$dir/gc.out"
    grep -qxF 'chunked gc ok' "$dir/gc.out"
    gc=1
fi
printf '(define wrong-request {number --> string} N -> (http.method N))\n' > "$dir/wrong.shen"
if "$SHEN" eval -l lib/buffer.shen -l lib/io.shen -l lib/grammar.shen -l lib/http-head.shen -l lib/http-request.shen \
     -e '(tc +)' -l "$dir/wrong.shen" > "$dir/wrong.out" 2>&1; then
  echo 'typed request misuse was accepted'
  exit 1
fi
grep -q 'type error' "$dir/wrong.out"
echo "$((4 + gc)) passed, 0 failed"
