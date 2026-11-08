#!/bin/sh
# Only the public C header and the platform's filesystem APIs are needed.
set -eu
out=${1:?usage: sh lib/build-fs.sh OUTPUT}
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$(dirname -- "$out")"
${CC:-cc} -std=c11 ${CFLAGS:--O2 -g} -Wall -Wextra -shared -fPIC \
    -I"$source_dir/../include" "$source_dir/fs.c" -o "$out"
