#!/bin/sh
set -eu
out=${1:?usage: sh build-native.sh OUTPUT}
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$(dirname -- "$out")"
# zlib is the only library: pkg-config's flags when it knows it, else the usual -lz.
if pkg-config --exists zlib 2>/dev/null; then
    deps_cflags=$(pkg-config --cflags zlib)
    deps_libs=$(pkg-config --libs zlib)
else
    deps_cflags=
    deps_libs=-lz
fi
${CC:-cc} -std=c11 ${CFLAGS:--O2 -g} -Wall -Wextra -Werror=implicit-function-declaration \
    -shared -fPIC -I"$source_dir/../../include" $deps_cflags "$source_dir/native.c" $deps_libs -o "$out"
