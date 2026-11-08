#!/bin/sh
# The dependency analyser, built as an executable and run on a fixture whose answers are written by
# hand, and on the kernel's KL, whose functions, by name, it must all find. Usage: test.sh SHEN_JIT [KLAMBDA_DIR]
SHEN=$1
KLAMBDA=$2
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
here=$(dirname "$0")
"$SHEN" eval -q -l lib/native.shen -l lib/datalog.shen -l lib/ffi.shen -l lib/buffer.shen \
    -l lib/io.shen -l lib/io-file.shen -l "$here/main.shen" \
    -e "(shen-jit.save-executable \"$dir/depends\" depends.main)" < /dev/null > "$dir/build.log" 2>&1
if [ ! -x "$dir/depends" ]; then
    tail -5 "$dir/build.log"
    exit 1
fi
failed=0
check() { # label, expected, actual
    if [ "$2" != "$3" ]; then
        echo "FAIL depends $1:"
        echo "$3" | diff - "$2" | head -20
        failed=$((failed + 1))
    fi
}
cd "$here/fixture"
check report "3 files, 8 functions, 16 calls, 7 to 6 external functions
3 file dependencies, 2 files in cycles
  cycle: b.shen, c.kl
4 recursive functions
most called: b.step (2), b.stop (2), helper (2), c.alone (1), c.back (1)
from main: 6 live, 2 dead, 1 deepest at 3 calls
  dead: c.alone
  dead: unused" "$("$dir/depends" --root main a.shen b.shen c.kl)"
check reach "run reaches 6 functions
  -
  =
  >
  b.step
  b.stop
  c.back" "$("$dir/depends" --reach run a.shen b.shen c.kl)"
check why "main reaches b.stop, as
  main calls run
  run reaches b.stop, as
    run calls b.stop" "$("$dir/depends" --why main b.stop a.shen b.shen c.kl)"
check "why not" "c.alone does not reach main" "$("$dir/depends" --why c.alone main a.shen b.shen c.kl)"
"$dir/depends" --root main --out "$dir" a.shen b.shen c.kl > "$dir/out.log" 2>&1
if ! grep -q 'this static build cannot load libraries' "$dir/out.log"; then # files need the FFI
    check out "c.alone
unused" "$(sort "$dir/dead.tsv")"
    check "file uses" "a.shen	b.shen
b.shen	c.kl
c.kl	b.shen" "$(sort "$dir/file-uses.tsv")"
    check "out failure" "2 depends: cannot write /nowhere/at/all/defines.tsv" \
        "$("$dir/depends" --out /nowhere/at/all a.shen > "$dir/err" 2>&1; echo $? $(cut -d: -f1,2 "$dir/err"))"
fi
"$dir/depends" --nope a.shen > "$dir/err" 2>&1
status=$?
check "bad option" "2 depends: unknown option --nope; usage: depends [--root F]... [--why F G] [--reach F] [--out DIR] FILE..." "$status $(cat "$dir/err")"
cd - > /dev/null
if [ -n "$KLAMBDA" ] && [ -d "$KLAMBDA" ]; then
    defuns=$(cat "$KLAMBDA"/*.kl | grep -o '(defun [^ ]*' | sort -u | wc -l | tr -d ' ')
    line=$("$dir/depends" "$KLAMBDA"/*.kl | head -1)
    case "$line" in
        *" files, $defuns functions,"*) ;;
        *) echo "FAIL depends kernel: $line, where the files have $defuns defuns"; failed=$((failed + 1)) ;;
    esac
fi
echo "depends: $failed failed"
[ "$failed" = 0 ]
