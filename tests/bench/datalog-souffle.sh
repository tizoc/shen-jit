#!/bin/sh
# lib/datalog.shen against Soufflé, on the same rules and facts: results first, then time. It needs
# souffle and a C++ compiler, and is not part of any suite. Times are milliseconds, best of three: of
# datalog.run with facts as a list, and of Soufflé's process, reading facts and printing sizes, less the
# same process with no facts, which is its startup. Homebrew's bottle has no OpenMP, so one thread.
# PARALLEL=N adds datalog.run-parallel in N isolates, as column pN.
# Usage: tests/bench/datalog-souffle.sh SHEN_JIT [CASE ...]
SHEN=$1
shift
if ! command -v souffle > /dev/null; then
    echo "no souffle: nothing compared"
    exit 0
fi
# KEEP names a directory to leave the programs and facts in.
if [ -n "$KEEP" ]; then base=$KEEP; mkdir -p "$base"; else base=$(mktemp -d); trap 'rm -rf "$base"' EXIT; fi
# Soufflé generates the C++, and it is compiled here with the flags of its own souffle-compile.py,
# whose include paths in Homebrew's bottle fail: one misses its headers, another clashes with Xcode's.
# SOUFFLE, SOUFFLE_FLAGS and SOUFFLE_LIBS name another build, such as one with OpenMP.
SOUFFLE=${SOUFFLE:-souffle}
INCLUDE=$(dirname "$(dirname "$(command -v "$SOUFFLE")")")/include/souffle
SOUFFLE_FLAGS=${SOUFFLE_FLAGS:--DRAM_DOMAIN_SIZE=64 -I$INCLUDE}
SOUFFLE_LIBS=${SOUFFLE_LIBS:-}
# Parallel code is generated only when asked for then, with SOUFFLE_GENERATE="-j auto".
SOUFFLE_GENERATE=${SOUFFLE_GENERATE:-}
build_cpp() { # program, name
    "$SOUFFLE" $SOUFFLE_GENERATE -F "$(dirname "$1")" -g "$2.cpp" "$1" &&
    c++ -std=c++17 -O3 -w -DUSE_NCURSES -DUSE_LIBZ -DUSE_SQLITE $SOUFFLE_FLAGS "$2.cpp" -o "$2" -lz -lsqlite3 -lncurses $SOUFFLE_LIBS
}
# THREADS lists the thread counts to time compiled programs at; the interpreter runs on one.
THREADS=${THREADS:-1}
LIMIT=${LIMIT:-60}
CASES=${*:-closure-sparse closure-dense nonlinear same-generation mutual triangles skewed-join call-graph points-to-small-a points-to-small-b points-to-small-c points-to-large-a points-to-large-b points-to-large-c}
for c in closure-sparse closure-dense nonlinear same-generation mutual triangles skewed-join call-graph points-to-small-a points-to-small-b points-to-small-c points-to-large-a points-to-large-b points-to-large-c; do
    mkdir -p "$base/$c"
done
"$SHEN" eval -l lib/native.shen -l lib/datalog.shen -l tests/bench/datalog.shen -l tests/bench/datalog-orders.shen \
    -l tests/bench/datalog-souffle.shen -e "(set sf.*parallel* ${PARALLEL:-0})" -e "(sf.main \"$base\")" > "$base/ours.log" 2>&1 < /dev/null
if ! grep -aq '^OURS points-to-large-c' "$base/ours.log"; then
    tail -8 "$base/ours.log" | cut -c1-160
    exit 1
fi

now() { python3 -c 'import time; print(time.time())'; }

# Milliseconds of a command, best of three, or "over" if it passes the limit.
best() {
    b=""
    for i in 1 2 3; do
        s=$(now)
        if ! timeout -s KILL "$LIMIT" "$@" > /dev/null 2>&1; then
            echo over
            return
        fi
        e=$(now)
        b=$(python3 -c "t=($e-$s)*1000; b='$b'; print('%.1f' % (min(t,float(b)) if b else t))")
    done
    echo "$b"
}

printf '%-20s %9s' case ours
[ -n "$PARALLEL" ] && printf ' %9s' "p$PARALLEL"
for j in $THREADS; do printf ' %9s' "j$j"; done
printf ' %9s %9s %9s %s\n' interpreted start build-ms results
for c in $CASES; do
    d=$base/$c
    ours=$(grep -a "^OURS $c " "$base/ours.log" | awk '{print $3}')
    mkdir -p "$d/out" "$d/empty"
    for f in "$d"/*.facts; do : > "$d/empty/$(basename "$f")"; done
    s=$(now)
    build_cpp "$d/time.dl" "$d/prog" > "$d/build.log" 2>&1
    e=$(now)
    build=$(python3 -c "print('%.0f' % (($e-$s)*1000))")
    build_cpp "$d/check.dl" "$d/check" > /dev/null 2>&1
    results=unchecked
    if timeout -s KILL "$LIMIT" "$d/check" -F "$d" -D "$d/out" > /dev/null 2>&1; then
        results=same
        for f in "$d"/*.ours; do
            r=$(basename "$f" .ours)
            sort "$f" > "$d/a"
            sort "$d/out/$r.csv" > "$d/b"
            cmp -s "$d/a" "$d/b" || results="DIFFER:$r"
        done
    fi
    start=$(best "$d/prog" -F "$d/empty")
    printf '%-20s %9s' "$c" "$ours"
    if [ -n "$PARALLEL" ]; then
        printf ' %9s' "$(grep -a "^PARALLEL $c " "$base/ours.log" | awk '{print ($4 == "same") ? $3 : "DIFFER"}')"
    fi
    for j in $THREADS; do
        t=$(best "$d/prog" -F "$d" -j "$j")
        printf ' %9s' "$(python3 -c "print('over' if '$t'=='over' else '%.1f' % ($t-$start))")"
    done
    if [ -n "$NO_INTERPRETER" ]; then
        neti=-
    else
        i0=$(best "$SOUFFLE" -F "$d/empty" "$d/time.dl")
        interpreted=$(best "$SOUFFLE" -F "$d" "$d/time.dl")
        neti=$(python3 -c "print('over' if '$interpreted'=='over' else '%.1f' % ($interpreted-$i0))")
    fi
    printf ' %9s %9s %9s %s\n' "$neti" "$start" "$build" "$results"
done
