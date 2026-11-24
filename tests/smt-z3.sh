#!/bin/sh
# lib/smt.shen against Z3, an independent solver, on generated formulas. It needs z3, and is not part
# of any suite. An answer of unknown is counted, and is no failure. Usage: tests/smt-z3.sh SHEN_JIT [COUNT] [SEED]
SHEN=$1
COUNT=${2:-3000}
SEED=${3:-7}
if ! command -v z3 > /dev/null; then
    echo "no z3: nothing compared"
    exit 0
fi
SHEN_JIT_MAX_HEAP=512M
export SHEN_JIT_MAX_HEAP
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
"$SHEN" eval -m smt -l tests/smt-generate.shen -l tests/smt-z3.shen \
    -e "(smt-z3.generated \"$dir\" $SEED $COUNT)" > "$dir/log" 2>&1 < /dev/null || { tail -5 "$dir/log"; exit 1; }
z3 "$dir/queries.smt2" > "$dir/z3"
paste -d'|' "$dir/answers" "$dir/z3" | awk -F'|' -v n="$COUNT" '
    $1 ~ /^unknown/ { unknown[$1 ", z3 " $2]++; next }
    $1 == $2 { same[$1]++; next }
    { print "FAIL query " NR ": smt " $1 ", z3 " $2; failed++ }
    END { for (k in unknown) print unknown[k] " " k
          if (NR != n) { print "FAIL " NR " answers of " n; failed++ }
          printf "%d sat, %d unsat, %d failed\n", same["sat"], same["unsat"], failed
          exit failed > 0 }'
