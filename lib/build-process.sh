#!/bin/sh
# Native spawn and pipe APIs only; no third-party dependencies.
set -eu
out=${1:?usage: sh lib/build-process.sh OUTPUT}
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$(dirname -- "$out")"
libs=-lpthread
case ${OS:-$(uname -s)} in
    Windows_NT|MINGW*|MSYS*) libs=-lbcrypt ;;
    Linux) libs='-lpthread -ldl' ;;
esac
${CC:-cc} -std=c11 ${CFLAGS:--O2 -g} -Wall -Wextra -Wno-deprecated-declarations -shared -fPIC \
    -I"$source_dir/../include" "$source_dir/process.c" $libs -o "$out"
