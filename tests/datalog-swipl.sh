#!/bin/sh
# lib/datalog.shen against SWI-Prolog's tabling, an independent engine, on generated programs. It
# needs swipl, and is not part of any suite. Usage: tests/datalog-swipl.sh SHEN_JIT [COUNT]
SHEN=$1
COUNT=${2:-300}
if ! command -v swipl > /dev/null; then
    echo "no swipl: nothing compared"
    exit 0
fi
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
"$SHEN" eval -m datalog -l tests/datalog-generate.shen -l tests/datalog-swipl.shen \
    -e "(swi.generated \"$dir\" $COUNT)" > "$dir/log" 2>&1 < /dev/null
if [ ! -f "$dir/p1.out" ]; then
    tail -5 "$dir/log"
    exit 1
fi
failed=0
compared=0
tuples=0
for pl in "$dir"/p*.pl; do
    base=${pl%.pl}
    if ! swipl -q -g main -t halt "$pl" > "$base.swi" 2> "$base.err"; then
        echo "swipl failed on $pl:"
        cat "$base.err"
        failed=$((failed + 1))
        continue
    fi
    sort "$base.swi" > "$base.a"
    sort "$base.out" > "$base.b"
    compared=$((compared + 1))
    tuples=$((tuples + $(wc -l < "$base.a")))
    if ! cmp -s "$base.a" "$base.b"; then
        echo "FAIL $(basename "$base"):"
        cat "$pl"
        diff "$base.a" "$base.b" | head -10
        failed=$((failed + 1))
    fi
done
echo "$compared programs, $tuples tuples, $failed failed"
[ "$failed" = 0 ]
