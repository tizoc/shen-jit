#!/bin/sh
# Both images must accept the same namespace clients, including after saving and reloading.
set -e
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
for shen in "$@"; do
    image="$work/$(basename "$shen").img"
    "$shen" --save "$image" eval -q \
      -l lib/native.shen -l lib/ffi.shen -l lib/buffer.shen -l lib/cursor.shen \
      -l lib/io.shen -l lib/grammar.shen -l lib/json.shen -l lib/datalog.shen -l lib/parallel.shen \
      -l tests/namespaces-client.shen -e '(tc +)' -l tests/namespaces-typed.shen -e '(tc -)' \
      -l tests/namespaces.shen > "$work/checks.log" 2>&1 || { cat "$work/checks.log"; exit 1; }
    grep '^[0-9]* passed, .* failed (library namespaces)' "$work/checks.log"
    SHEN_JIT_IMAGE="$image" "$shen" eval -q -l tests/namespaces.shen > "$work/checks.log" 2>&1 || \
      { cat "$work/checks.log"; exit 1; }
    grep '^[0-9]* passed, .* failed (library namespaces)' "$work/checks.log"
done
