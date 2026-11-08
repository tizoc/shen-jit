#!/bin/sh
set -eu
SHEN=$1
dir=$(mktemp -d)
trap 'status=$?; if [ "$status" -ne 0 ]; then cat "$dir"/*.out 2>/dev/null; fi; rm -rf "$dir"' EXIT
if command -v cygpath > /dev/null; then dir=$(cygpath -m "$dir"); fi
"$SHEN" eval -l lib/ffi.shen -l lib/buffer.shen -l lib/tree-sitter.shen \
    -l tests/tree_sitter_helpers.shen -l tests/tree_sitter_pure.shen > "$dir/pure.out" 2>&1
grep -a '^FAIL\|^[0-9]* passed' "$dir/pure.out" | awk '{ print } END { exit !/ 0 failed/ }'
"$SHEN" eval -l lib/ffi.shen \
    -e '(shen-jit.library ts-probe ["libc.so.6" "libSystem.dylib" "ucrtbase.dll"])' \
    -e '(define-foreign ts-probe.abs ts-probe "abs" (int32) --> int32)' \
    -e '(output "treesitter shared: ~A~%"
          (trap-error (ts-probe.abs -1)
            (/. E (if (= (error-to-string E) "foreign: this static build cannot load libraries")
                      static (simple-error (error-to-string E))))))' > "$dir/probe.out" 2>&1
if grep -q '^treesitter shared: static' "$dir/probe.out"; then
    echo 'treesitter: native checks skipped (a static build cannot load libraries)'
    exit 0
fi
grep -q '^treesitter shared: 1' "$dir/probe.out"
TREE_SITTER_SOURCE=${TREE_SITTER_SOURCE:-.deps/tree-sitter}
TREE_SITTER_C_SOURCE=${TREE_SITTER_C_SOURCE:-.deps/tree-sitter-c}
export TREE_SITTER_SOURCE
if [ ! -f "$TREE_SITTER_SOURCE/lib/src/lib.c" ] || [ ! -f "$TREE_SITTER_C_SOURCE/src/parser.c" ]; then
    echo 'Run make deps-tree-sitter first, or set TREE_SITTER_SOURCE and TREE_SITTER_C_SOURCE' >&2
    exit 1
fi
extension=so
if [ "${OS:-}" = Windows_NT ]; then extension=dll; fi
adapter="$dir/shen-tree-sitter.$extension"
grammar="$dir/tree-sitter-c.$extension"
fixture="$dir/fixture.$extension"
fs_adapter="$dir/shen-fs.$extension"
process_adapter="$dir/shen-process.$extension"
sh lib/build-tree-sitter.sh "$adapter"
sh lib/build-fs.sh "$fs_adapter"
sh lib/build-process.sh "$process_adapter"
${CC:-cc} -std=c11 ${CFLAGS:--O2 -g} -Wall -Wextra -shared -fPIC \
    -I"$TREE_SITTER_C_SOURCE/src" "$TREE_SITTER_C_SOURCE/src/parser.c" -o "$grammar"
${CC:-cc} -std=c11 ${CFLAGS:--O2 -g} -Wall -Wextra -shared -fPIC tests/tree_sitter_fixture.c -o "$fixture"
oracle="$dir/oracle"
if [ "${OS:-}" = Windows_NT ]; then oracle="$oracle.exe"; fi
${CC:-cc} -std=c11 ${CFLAGS:--O2 -g} -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE -D_DARWIN_C_SOURCE \
    -I"$TREE_SITTER_SOURCE/lib/include" -I"$TREE_SITTER_SOURCE/lib/src" -I"$TREE_SITTER_C_SOURCE/src" \
    tests/tree_sitter_oracle.c "$TREE_SITTER_SOURCE/lib/src/lib.c" \
    "$TREE_SITTER_C_SOURCE/src/parser.c" -o "$oracle"
python=python3
if ! command -v "$python" > /dev/null; then python=python; fi
"$python" tests/tree_sitter.py "$SHEN" "$adapter" "$grammar" "$fixture" "$oracle" "$fs_adapter"
"$python" tests/source_context.py "$SHEN" "$adapter" "$grammar" "$fs_adapter" "$process_adapter"
