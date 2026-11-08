#!/bin/sh
set -eu
SHEN=$1
dir=$(mktemp -d)
trap 'socket_test_status=$?; if [ "$socket_test_status" -ne 0 ]; then cat "$dir"/*.out 2>/dev/null; fi; rm -rf "$dir"' EXIT
if command -v cygpath > /dev/null; then dir=$(cygpath -m "$dir"); fi
"$SHEN" --save "$dir/socket.img" eval -l lib/ffi.shen -l lib/socket.shen \
  -l lib/buffer.shen -l lib/io.shen -l lib/io-socket.shen -l lib/frame.shen \
  -l tests/io_socket_image.shen -e '(io-socket-image.save)' > "$dir/save.out" 2>&1
SHEN_JIT_IMAGE="$dir/socket.img" "$SHEN" eval -e '(io-socket-image.reload)' > "$dir/load.out" 2>&1
grep -qxE 'socket image (ok|unavailable)' "$dir/load.out"
gc=0
if [ "${TEST_GC_STRESS:-}" = 1 ]; then # a collection at every allocation: make test-lib-stress
    SHEN_JIT_IMAGE="$dir/socket.img" SHEN_JIT_GC_STRESS=1 "$SHEN" eval \
      -e '(io-socket-image.gc)' > "$dir/gc.out" 2>&1
    grep -qxE 'socket gc (ok|unavailable)' "$dir/gc.out"
    gc=1
fi
echo "$((1 + gc)) passed, 0 failed"
