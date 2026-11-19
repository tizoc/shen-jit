#!/bin/sh
set -eu
SHEN=$1
dir=$(mktemp -d)
trap 'io_test_status=$?; if [ "$io_test_status" -ne 0 ]; then cat "$dir"/*.out 2>/dev/null; fi; rm -rf "$dir"' EXIT
if command -v cygpath > /dev/null; then dir=$(cygpath -m "$dir"); fi
"$SHEN" eval -m memory -m io/file \
  -e "(set io-file-test.root \"$dir\")" -l tests/io_file.shen > "$dir/file.out" 2>&1
grep '^[0-9]* passed' "$dir/file.out" | awk '{ print } END { exit !/ 0 failed/ }'
if grep -q 'a static build' "$dir/file.out"; then exit 0; fi
# Independent byte oracle catches Windows text-mode translation as well as NUL truncation.
printf '\141\000\015\012\032\377' > "$dir/expected"
cmp "$dir/expected" "$dir/binary"
cmp "$dir/expected" "$dir/foreign"
echo '2 passed, 0 failed'
