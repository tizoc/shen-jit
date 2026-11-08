#!/bin/sh
# Build against installed Tree-sitter >= 0.25, or an explicitly supplied runtime source directory.
set -eu
out=${1:?usage: sh lib/build-tree-sitter.sh OUTPUT}
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$(dirname -- "$out")"
if [ -n "${TREE_SITTER_SOURCE:-}" ]; then
    # A source build embeds the runtime in this optional adapter, not in Shen/JIT.
    ${CC:-cc} -std=c11 ${CFLAGS:--O2 -g} -Wall -Wextra -Werror=implicit-function-declaration -shared -fPIC \
        -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE -D_DARWIN_C_SOURCE \
        -I"$source_dir/../include" -I"$TREE_SITTER_SOURCE/lib/include" \
        -I"$TREE_SITTER_SOURCE/lib/src" "$source_dir/tree-sitter.c" \
        "$TREE_SITTER_SOURCE/lib/src/lib.c" -o "$out"
else
    if [ -z "${TREE_SITTER_CFLAGS:-}${TREE_SITTER_LIBS:-}" ]; then
        pkg-config --atleast-version=0.25 tree-sitter || {
            echo 'Tree-sitter >= 0.25 is required; set TREE_SITTER_SOURCE or install its development package' >&2
            exit 1
        }
        TREE_SITTER_CFLAGS=$(pkg-config --cflags tree-sitter)
        TREE_SITTER_LIBS=$(pkg-config --libs tree-sitter)
    fi
    ${CC:-cc} -std=c11 ${CFLAGS:--O2 -g} -Wall -Wextra -Werror=implicit-function-declaration -shared -fPIC \
        -I"$source_dir/../include" ${TREE_SITTER_CFLAGS:-} "$source_dir/tree-sitter.c" \
        ${TREE_SITTER_LIBS:--ltree-sitter} -o "$out"
fi
