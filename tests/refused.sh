#!/bin/sh
# Typed programs that must not load: tests/refused.sh SHEN FIXTURE ARGUMENTS...
# Each case in FIXTURE, the lines up to one that is only \\ next, is loaded alone after
# ARGUMENTS, such as -l lib/json.shen, under (tc +). It passes only if loading stops with a
# type error; the cases call nothing, so that an error at run time cannot pass for one.
set -eu
SHEN=$1
fixture=$2
shift 2
dir=$(mktemp -d)
trap 'refused_status=$?; rm -rf "$dir"; exit $refused_status' EXIT
if command -v cygpath > /dev/null; then dir=$(cygpath -m "$dir"); fi
awk -v dir="$dir" 'BEGIN { n = 1 } /^\\\\ next$/ { n++; next } { print > (dir "/case" n ".shen") }' "$fixture"
passed=0
for case in "$dir"/case*.shen; do
  if "$SHEN" eval "$@" -e '(tc +)' -l "$case" > "$dir/out" 2>&1; then
    echo "FAIL accepted:"
    cat "$case"
    exit 1
  fi
  if ! grep -q 'type error' "$dir/out"; then
    echo "FAIL not a type error:"
    cat "$case"
    tail -3 "$dir/out"
    exit 1
  fi
  passed=$((passed + 1))
done
echo "$passed passed, 0 failed"
