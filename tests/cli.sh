#!/bin/sh
# Command-line tests: what the REPL, eval and script print. Each check looks
# for a line in the output. Usage: tests/cli.sh path/to/shen-jit
SHEN=$1
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
# A native Windows program knows C:/..., not MSYS2's /tmp.
# Its kill ends a native program instead of interrupting it: a console is
# needed to send one a Ctrl-C, so tests/ctrlc_windows.py does that. There is
# no profiler there either.
posix=yes
if command -v cygpath > /dev/null; then dir=$(cygpath -m "$dir"); posix=no; fi
pass=0
fail=0

check() { # name, file with the output, the expected line
    if grep -qxF -- "$3" "$2"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL $1: no line \"$3\" in:"
        sed 's/^/    /' "$2"
    fi
}

followed() { # name, file, a line, and what the next line must not start with
    if awk -v line="$3" -v next_="$4" 'found { exit index($0, next_) == 1 ? 0 : 1 } $0 == line { found = 1 } END { if (!found) exit 0 }' "$2"; then
        fail=$((fail + 1))
        echo "FAIL $1: \"$3\" missing, or followed by \"$4\""
    else
        pass=$((pass + 1))
    fi
}

contains() { # name, file, text that some line must contain
    if grep -qF -- "$3" "$2"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL $1: no \"$3\" in:"
        sed 's/^/    /' "$2"
    fi
}

absent() { # name, file, a line that must not be there
    if grep -qF -- "$3" "$2"; then
        fail=$((fail + 1))
        echo "FAIL $1: unexpected \"$3\" in:"
        sed 's/^/    /' "$2"
    else
        pass=$((pass + 1))
    fi
}

# Count operands accept 255. Oversized values report the relevant limit.
cat > "$dir/counts.shen" <<'SHEN'
(define load-code Arity Instructions ->
  (output "~A~%" (trap-error (do (shen-jit.install [code f Arity 258 [] Instructions []]) loaded)
                              (/. E (error-to-string E)))))
(load-code 255 [[tail-call 0 f 255]])
(load-code 256 [[return 2]])
(load-code 0 [[tail-call 0 f 256]])
(load-code 0 [[entry 256 0] [label 0] [return 2]])
(load-code 0 [[capture 2 256] [return 2]])
SHEN
"$SHEN" script "$dir/counts.shen" > "$dir/counts.out" 2>&1
check count-255 "$dir/counts.out" "loaded"
check function-arity-limit "$dir/counts.out" "function has more than 255 parameters"
check call-argument-limit "$dir/counts.out" "call has more than 255 arguments"
check entry-arity-limit "$dir/counts.out" "entry has more than 255 parameters"
check capture-index-limit "$dir/counts.out" "capture index exceeds 255"

# Backtraces at the REPL: the frames of an error that reaches the top level,
# innermost first, a run of one name on one line, and none for an error the
# program catches.
cat > "$dir/repl.in" <<'EOF'
(define f X -> (+ 1 (g X)))
(define g X -> (+ (hd X) 1))
(f 5)
(define r 0 -> (hd 0) N -> (+ 1 (r (- N 1))))
(r 50)
(trap-error (f 5) (/. E caught))
(define again X -> (trap-error (hd X) (/. E (simple-error (cn "again: " (error-to-string E))))))
(define outer X -> (+ 1 (again X)))
(outer 5)
(define ma 0 -> (hd 0) N -> (+ 1 (mb (- N 1))))
(define mb N -> (+ 1 (ma N)))
(ma 40)
(define k -> (shen-jit.backtrace))
(define kk -> [(k)])
(kk)
EOF
"$SHEN" < "$dir/repl.in" > "$dir/repl.out" 2>&1
check repl-chain "$dir/repl.out" "  in g"
check repl-chain-outer "$dir/repl.out" "  in f"
check repl-run "$dir/repl.out" "  in r (51 times)"
followed repl-caught "$dir/repl.out" "(5-) caught" "  in"
check repl-reraise "$dir/repl.out" "  in again"
check repl-reraise-outer "$dir/repl.out" "  in outer"
check repl-limit "$dir/repl.out" "  ... 57 more"
check repl-backtrace "$dir/repl.out" "(14-) [[k kk]]"
absent repl-machinery "$dir/repl.out" "in shen.loop"

# With typechecking on, the kernel runs the input inside its own handlers
# and raises errors again: the trace is still that of the running code, and
# a type error, which no running code raised, has none. An error raised in a
# kernel function shows its frame.
cat > "$dir/tc.in" <<'EOF'
(tc +)
(define g {number --> number} X -> (+ X (/ 1 0)))
(define f {number --> number} X -> (+ 1 (g X)))
(f 5)
(f a)
(tc -)
(define u X -> (+ 1 (nth X [1 2])))
(u 10)
EOF
"$SHEN" < "$dir/tc.in" > "$dir/tc.out" 2>&1
check tc-chain "$dir/tc.out" "  in g"
check tc-chain-outer "$dir/tc.out" "  in f"
followed tc-type-error "$dir/tc.out" "(4+) type error" "  in"
check kernel-frame "$dir/tc.out" "  in nth"
check kernel-frame-caller "$dir/tc.out" "  in u"

# Uncaught errors in eval and script: the trace follows the message on
# stderr, and the exit status is 1.
"$SHEN" eval -e '(define g X -> (+ (hd X) 1))' -e '(define f X -> (+ 1 (g X)))' -e '(f 5)' \
    > "$dir/eval.out" 2>&1
echo "status $?" >> "$dir/eval.out"
check eval-message "$dir/eval.out" "shen-jit: uncaught error: hd: 5 is not a pair"
check eval-chain "$dir/eval.out" "  in g"
check eval-chain-outer "$dir/eval.out" "  in f"
check eval-status "$dir/eval.out" "status 1"
"$SHEN" --seal eval -e '(define g X -> (+ (hd X) 1))' -e '(define f X -> (+ 1 (g X)))' -e '(f 5)' \
    > "$dir/sealed.out" 2>&1
check sealed-chain "$dir/sealed.out" "  in g"
check sealed-chain-outer "$dir/sealed.out" "  in f"

# Functions the kernel did not know when compiling a call, such as one
# defined later at the top level, are called through fn: by name when the
# arity matches, with currying and fn's error otherwise.
"$SHEN" eval -e '(define fa X -> (fb X))' -e '(define fb X -> (+ X 1))' -e '(fa 1)' \
    -e '(define fc X -> (fd X))' -e '(define fd X Y -> [X Y])' -e '((fc 1) 2)' \
    -e '(define fe X -> (fk X 2))' -e '(define fk X -> (/. Y [k X Y]))' -e '(fe 1)' \
    -e '(define fx X -> (fundef X))' -e '(trap-error (fx 1) (/. E (error-to-string E)))' \
    -e '(define fb X Y -> [b X Y])' -e '((fa 1) 2)' > "$dir/fn.out" 2>&1
check fn-forward "$dir/fn.out" "2"
check fn-partial "$dir/fn.out" "[1 2]"
check fn-over "$dir/fn.out" "[k 1 2]"
check fn-undefined "$dir/fn.out" "fn: fundef is undefined"
check fn-redefined "$dir/fn.out" "[b 1 2]"
# A message that ends with a newline, as some of the kernel's do, has its
# trace on the next line.
"$SHEN" eval -e '(ps map)' > "$dir/eval-nl.out" 2>&1
sed -n '/^shen-jit: uncaught error: map not found\.$/{n;p;}' "$dir/eval-nl.out" > "$dir/eval-nl.next"
check eval-newline "$dir/eval-nl.next" "  in ps"

printf '(define g X -> (+ (hd X) 1))\n(define f X -> (+ 1 (g X)))\n(f 5)\n' > "$dir/script.shen"
"$SHEN" script "$dir/script.shen" > "$dir/script.out" 2>&1
echo "status $?" >> "$dir/script.out"
check script-chain "$dir/script.out" "  in g"
check script-status "$dir/script.out" "status 1"

# Errors name the value they are about.
cat > "$dir/msg.in" <<'EOF'
(define test X Y -> (+ X Y))
(test 1 "A")
(test 1 [a b])
(define u X -> (undefined-u X))
(u 1)
EOF
"$SHEN" < "$dir/msg.in" > "$dir/msg.out" 2>&1
check msg-string "$dir/msg.out" '(1-) "A" is not a number'
check msg-list "$dir/msg.out" "(2-) [a b] is not a number"
check msg-undefined "$dir/msg.out" "(4-) fn: undefined-u is undefined"

# A cons run lowered into one slot, in a loop whose argument is computed in
# place from its own slot, across collections, and a long literal.
cat > "$dir/run.shen" <<'SHEN'
(define grow 0 Y -> Y N Y -> (grow (- N 1) (cons a (cons b Y))))
(define mixed 0 Y -> Y N Y -> (mixed (- N 1) (cons a (cons (length Y) Y))))
(define keep Y -> (let X (cons a (cons b Y)) [X Y]))
(output "~A ~A ~A ~A~%" (length (grow 200000 [])) (hd (tl (grow 2 [q]))) (hd (tl (mixed 2 [q]))) (keep [q]))
SHEN
"$SHEN" script "$dir/run.shen" > "$dir/run.out" 2>&1
check cons-run-one-slot "$dir/run.out" "400000 b 3 [[a b q] [q]]"
awk 'BEGIN { printf "(define big -> ["; for (i = 1; i <= 5000; i++) printf "%d ", i; print "])"
    print "(define total [] -> 0 [X | Xs] -> (+ X (total Xs)))"
    print "(output \"~A ~A ~A~%\" (hd (big)) (length (big)) (total (big)))" }' > "$dir/literal.shen"
"$SHEN" script "$dir/literal.shen" > "$dir/literal.out" 2>&1
check long-literal "$dir/literal.out" "1 5000 12502500"

# A c#N; escape past a byte is UTF-8, in source and from a string. Compare
# byte values as ASCII so the check does not depend on grep's text encoding.
cat > "$dir/escape.shen" <<'SHEN'
(output "~A~%" (shen.str->bytes "c#955;c#128512;"))
(let Quoted (cn (n->string 34) (cn "c#233;c#955;" (n->string 34)))
  (output "~A~%" (shen.str->bytes (hd (read-from-string Quoted)))))
SHEN
"$SHEN" script "$dir/escape.shen" > "$dir/escape.out" 2>&1
check escape-source "$dir/escape.out" "[206 187 240 159 152 128]"
check escape-read-from-string "$dir/escape.out" "[233 206 187]"

# Deep non-tail recursion grows the stack many times; the first argument,
# passed in a register as well as in its slot, must survive each growth.
printf '(define mk 0 Acc -> Acc N Acc -> (mk (- N 1) [N | Acc]))\n(define deep [] -> 0 [_ | Xs] -> (+ 1 (deep Xs)))\n(output "~A ~A~%%" (deep (mk 300000 [])) (length (append (mk 300000 []) [a])))\n' \
    > "$dir/deep.shen"
"$SHEN" script "$dir/deep.shen" > "$dir/deep.out" 2>&1
check deep-recursion "$dir/deep.out" "300000 300001"

# A literal past the fixnum range is the nearest real, which adding up its digits in
# doubles is not, and the largest fixnum and 1e18 stay integers.
cat > "$dir/big.shen" <<'EOF'
(output "~A ~A ~A~%" 2305843009213693951 2305843009213693952 -2305843009213693952)
(output "~A ~A~%" 123456789012345678901234567890 1e18)
(output "~A ~A ~A ~A~%" 1e100 1e308 1.5e300 1.7976931348623157e308)
(output "~A ~A~%" 1e309 -1e300)
(output "~A~%" (= -2305843009213693952 (- -2305843009213693951 1)))
EOF
"$SHEN" script "$dir/big.shen" > "$dir/big.out" 2>&1 < /dev/null
check literal-past-fixnum "$dir/big.out" "2305843009213693951 2.305843009213694e18 -2.305843009213694e18"
check literal-many-digits "$dir/big.out" "1.2345678901234568e29 1000000000000000000"
check literal-exponent "$dir/big.out" "1e100 1e308 1.5e300 1.7976931348623157e308"
check literal-infinite "$dir/big.out" "+inf.0 -1e300"
check literal-smallest-fixnum "$dir/big.out" "true"

if [ "$posix" = yes ]; then
# Ctrl-C at the REPL stops a loop that
# makes no calls, even one inside the program's own trap-error, and the REPL
# goes on; sealed, the loop jumps straight to its own body. The REPL installs
# its handler when it starts, so the signal waits for the first prompt's
# output.
printf '(define spin N -> (spin (+ N 1)))\n(trap-error (spin 0) (/. E caught))\n(+ 1 2)\n' > "$dir/int.in"
for seal in "" --seal; do
    "$SHEN" $seal < "$dir/int.in" > "$dir/int.out" 2>&1 &
    pid=$!
    n=0
    while ! grep -q "(fn spin)" "$dir/int.out" && [ $n -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
    sleep 0.25
    n=0
    while kill -0 $pid 2>/dev/null && ! grep -q interrupted "$dir/int.out" && [ $n -lt 40 ]; do
        kill -INT $pid 2>/dev/null
        sleep 0.25
        n=$((n + 1))
    done
    n=0
    while kill -0 $pid 2>/dev/null && [ $n -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
    kill -9 $pid 2>/dev/null
    wait $pid 2>/dev/null
    check "interrupt$seal" "$dir/int.out" "(1-) interrupted"
    check "interrupt-continues$seal" "$dir/int.out" "(2-) 3"
done
# Two functions that call each other in tail position and nothing else,
# each too large to inline into the other, see the interrupt at their entry
# checks. Loaded from a file, both calls are direct: ping does not call
# pong through fn, as it would if it were defined at the REPL before it.
printf '(define ping N -> (if (= N -1) (ping 0) (pong (+ N 1))))\n(define pong N -> (if (= N -1) (pong 0) (ping (+ N 1))))\n' > "$dir/pingpong.shen"
printf '(load "%s")\n(trap-error (ping 0) (/. E caught))\n(+ 1 2)\n' "$dir/pingpong.shen" > "$dir/int2.in"
for seal in "" --seal; do
    "$SHEN" $seal < "$dir/int2.in" > "$dir/int2.out" 2>&1 &
    pid=$!
    n=0
    while ! grep -q "loaded" "$dir/int2.out" && [ $n -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
    sleep 0.25
    n=0
    while kill -0 $pid 2>/dev/null && ! grep -q interrupted "$dir/int2.out" && [ $n -lt 40 ]; do
        kill -INT $pid 2>/dev/null
        sleep 0.25
        n=$((n + 1))
    done
    n=0
    while kill -0 $pid 2>/dev/null && [ $n -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
    kill -9 $pid 2>/dev/null
    wait $pid 2>/dev/null
    check "interrupt-tail-calls$seal" "$dir/int2.out" "(1-) interrupted"
    check "interrupt-tail-calls-continue$seal" "$dir/int2.out" "(2-) 3"
done
fi
# A sealed loop that tests its argument against a number.
"$SHEN" --seal eval -e '(define sum-to 0 A -> A N A -> (sum-to (- N 1) (+ A N)))' -e '(sum-to 100000 0)' \
    > "$dir/sealed-loop.out" 2>&1
check sealed-loop "$dir/sealed-loop.out" "5000050000"

# Saving an image: what eval defines
# loads with the kernel, an image saved from a saved image keeps both, and
# sealed definitions stay sealed.
"$SHEN" --save "$dir/app.img" eval -e '(define triple X -> (* 3 X))' > /dev/null 2>&1
SHEN_JIT_IMAGE="$dir/app.img" "$SHEN" eval -e '(output "~A~%" (triple 14))' > "$dir/save.out" 2>&1
check save-load "$dir/save.out" "42"
SHEN_JIT_IMAGE="$dir/app.img" "$SHEN" --seal --save "$dir/app2.img" \
    eval -e '(define quad X -> (* 4 (triple X)))' > /dev/null 2>&1
SHEN_JIT_IMAGE="$dir/app2.img" "$SHEN" eval -e '(output "~A ~A~%" (triple 2) (quad 2))' > "$dir/save2.out" 2>&1
check save-again "$dir/save2.out" "6 24"
SHEN_JIT_IMAGE="$dir/app2.img" "$SHEN" eval -e '(define quad X -> X)' > "$dir/save3.out" 2>&1
check save-sealed "$dir/save3.out" "shen-jit: uncaught error: quad is sealed and cannot be redefined"

# Large objects live apart from the semispaces and are not copied
#: one survives collections under GC stress, and
# a saved image holds it like any other object.
"$SHEN" --save "$dir/large.img" eval -e '(set big (address-> (absvector 100000) 99999 last))' \
    -e '(do (absvector 60000) (cn (n->string 65) (str (<-address (value big) 99999))))' > "$dir/large.out" 2>&1
check large "$dir/large.out" "Alast"
SHEN_JIT_IMAGE="$dir/large.img" "$SHEN" eval -e '(<-address (value big) 99999)' > "$dir/large2.out" 2>&1
check large-image "$dir/large2.out" "last"

# The executable carries its image: it
# runs from PATH, the runtime alone has none, and a saved image appended to
# the runtime makes an application. Saving under -q does not hush the image.
bin=$(dirname "$SHEN")
(cd "$dir" && PATH="$bin:$PATH" "$(basename "$SHEN")" eval -e '(+ 1 2)') > "$dir/path.out" 2>&1
check path "$dir/path.out" "3"
"$bin/runtime" eval -e 1 > "$dir/bare.out" 2>&1
contains bare-runtime "$dir/bare.out" "cannot load an image from"
"$SHEN" --save "$dir/app3.img" eval -q -e '(define triple X -> (* 3 X))' > /dev/null 2>&1
cat "$bin/runtime" "$dir/app3.img" > "$dir/app" && chmod +x "$dir/app"
"$dir/app" eval -e '(triple 14)' > "$dir/app.out" 2>&1
check application "$dir/app.out" "42"

# (shen-jit.exit N) ends the process with status N; a script whose first
# line is #! runs directly, and loads with load.
"$SHEN" eval -e '(shen-jit.exit 3)' > /dev/null 2>&1
echo "status $?" > "$dir/exit.out"
check exit-status "$dir/exit.out" "status 3"
printf '#!%s script\n(define twice X -> (* 2 X))\n(output "~A ~A~%%" (twice 21) (tl (value *argv*)))\n' "$SHEN" \
    > "$dir/run.shen"
chmod +x "$dir/run.shen"
"$dir/run.shen" a b > "$dir/shebang.out" 2>&1
check shebang-script "$dir/shebang.out" "42 [a b]"
printf '#!%s script\n(output "~A~%%" (* 3 5))\n' "$SHEN" > "$dir/lib.shen"
"$SHEN" eval -e "(load \"$dir/lib.shen\")" > "$dir/shebang-load.out" 2>&1
check shebang-load "$dir/shebang-load.out" "15"

# Files are read whole in C, as
# bytes or as a string, and a missing file is reported as open reports it.
# Definitions go on shen.*userdefs* once, redefinitions included.
printf 'ab\nc' > "$dir/three.txt"
"$SHEN" eval -e "(read-file-as-bytelist \"$dir/three.txt\")" -e "(read-file-as-string \"$dir/three.txt\")" \
    -e '(trap-error (read-file-as-string "no such file") (/. E (error-to-string E)))' \
    -e '(define f1 X -> X)' -e '(define f2 X -> X)' -e '(define f1 X -> 1)' -e '(value shen.*userdefs*)' \
    > "$dir/files.out" 2>&1
check read-bytes "$dir/files.out" "[97 98 10 99]"
followed read-string "$dir/files.out" "ab" "[97"
check read-missing "$dir/files.out" 'open: cannot open "no such file"'
check userdefs "$dir/files.out" "[f2 f1]"

# Empty files are successful reads, and repeated EOF reads still return -1.
: > "$dir/empty.txt"
"$SHEN" eval -e "(output \"empty-string: ~A~%\" (= (read-file-as-string \"$dir/empty.txt\") \"\"))" \
    -e "(output \"empty-bytes: ~A~%\" (= (read-file-as-bytelist \"$dir/empty.txt\") []))" \
    -e "(let S (open \"$dir/empty.txt\" in) A (read-byte S) B (read-byte S) _ (close S) [A B])" \
    > "$dir/empty.out" 2>&1
check read-empty-string "$dir/empty.out" "empty-string: true"
check read-empty-bytes "$dir/empty.out" "empty-bytes: true"
check read-empty-stream "$dir/empty.out" "[-1 -1]"

# A directory opens on POSIX, but the read fails. Check the read's message,
# so an open failure or a silently empty result cannot pass.
if [ "$posix" = yes ]; then
    "$SHEN" eval \
        -e "(output \"string: ~A~%\" (trap-error (read-file-as-string \"$dir\") (/. E (error-to-string E))))" \
        -e "(output \"bytes: ~A~%\" (trap-error (read-file-as-bytelist \"$dir\") (/. E (error-to-string E))))" \
        -e "(let S (open \"$dir\" in)
              (do (output \"byte: ~A~%\" (trap-error (read-byte S) (/. E (error-to-string E))))
                  (output \"byte-again: ~A~%\" (trap-error (read-byte S) (/. E (error-to-string E))))
                  (close S)))" > "$dir/read-error.out" 2>&1
    contains read-error-string "$dir/read-error.out" "string: read-file: "
    contains read-error-bytes "$dir/read-error.out" "bytes: read-file: "
    contains read-error-byte "$dir/read-error.out" "byte: read-byte: "
    contains read-error-byte-again "$dir/read-error.out" "byte-again: read-byte: "
fi

# Lambda forms are made when fn first asks for them (docs/overrides.md):
# fn on loaded definitions, after a change of arity, and gensym numbered as
# when every form was made on reading.
printf '(define lz2 X Y -> (+ X Y))\n(define lz1 X -> [X])\n' > "$dir/lazy.shen"
"$SHEN" eval -l "$dir/lazy.shen" -e '(let G lz2 F (fn G) ((F 1) 2))' -e '(let G lz1 (map (fn G) [a b]))' \
    -e '(define lz2 X Y Z -> (+ X (+ Y Z)))' -e '(let G lz2 F (fn G) (F 1 2 3))' -e '(gensym g)' \
    > "$dir/lazy.out" 2>&1
check lazy-form "$dir/lazy.out" "3"
check lazy-map "$dir/lazy.out" "[[a] [b]]"
check lazy-arity "$dir/lazy.out" "6"
gensyms=$("$SHEN" eval -e '(gensym g)' < /dev/null | grep '^g[0-9]*$' | tail -1 | cut -c2-)
check lazy-gensym "$dir/lazy.out" "g$((gensyms + 12))"

# SHEN_JIT_MAX_HEAP: live data past the
# limit raises a catchable "out of memory", and the heap is usable after.
# Without GC stress, which would make building 64 MB of live data slow.
printf '(define mk N Acc -> (if (= N 0) Acc (mk (- N 1) [N | Acc])))\n(trap-error (length (mk 10000000 [])) (/. E (error-to-string E)))\n(length (mk 100000 []))\n' \
    > "$dir/heap.in"
SHEN_JIT_GC_STRESS= SHEN_JIT_MAX_HEAP=64M "$SHEN" < "$dir/heap.in" > "$dir/heap.out" 2>&1
check heap-limit "$dir/heap.out" '(1-) "out of memory"'
check heap-after "$dir/heap.out" "(2-) 100000"
# So does a single vector too large for the limit, with an exception for the handler to read.
printf '(trap-error (absvector 100000000) (/. E (error-to-string E)))\n' > "$dir/big.in"
SHEN_JIT_GC_STRESS= SHEN_JIT_MAX_HEAP=64M "$SHEN" < "$dir/big.in" > "$dir/big.out" 2>&1
check heap-limit-vector "$dir/big.out" '(0-) "out of memory"'
# The limit is on what the heap holds, not on what it has room for: semispaces grown by a list
# since dropped leave room for a large object. Large objects and small ones share the limit,
# and each raises at it, with the heap usable after.
cat > "$dir/limit.shen" <<'EOF'
(define mk N Acc -> (if (= N 0) Acc (mk (- N 1) [N | Acc])))
(define large -> (absvector 65539))
(define try F -> (trap-error (do (thaw F) ok) (/. E (error-to-string E))))
(define hold Acc -> (let V (trap-error (large) (/. E false))
                      (if (= V false) Acc (hold [V | Acc]))))
(output "list dropped, large: ~A~%" (do (length (mk 1500000 [])) (try (freeze (large)))))
(let Held (hold [])
  (do (output "large at the limit: ~A~%" (try (freeze (large))))
      (output "small at the limit: ~A~%" (try (freeze (length (mk 1000000 [])))))
      (output "holding some: ~A~%" (> (length Held) 50))))
(output "large after: ~A~%" (try (freeze (large))))
(output "small after: ~A~%" (try (freeze (length (mk 100000 [])))))
(let List (mk 3000000 [])
  (do (output "large beside a list: ~A~%" (try (freeze (hold []))))
      (output "kept: ~A~%" (length List))))
EOF
SHEN_JIT_GC_STRESS= SHEN_JIT_MAX_HEAP=64M "$SHEN" script "$dir/limit.shen" > "$dir/limit.out" 2>&1
check limit-list-dropped "$dir/limit.out" "list dropped, large: ok"
check limit-large "$dir/limit.out" "large at the limit: out of memory"
check limit-small "$dir/limit.out" "small at the limit: out of memory"
check limit-held "$dir/limit.out" "holding some: true"
check limit-large-after "$dir/limit.out" "large after: ok"
check limit-small-after "$dir/limit.out" "small after: ok"
check limit-beside-list "$dir/limit.out" "large beside a list: ok"
check limit-kept "$dir/limit.out" "kept: 3000000"
# Small objects made after a large one share the limit with it: the room a collection left them
# shrinks by the large object's words. With the semispace at the limit from the start, a list of
# 3.5 million pairs beside a 4-million-word vector fitted under 64 MB.
cat > "$dir/beside.shen" <<'EOF'
(set beside.n 0)
(define beside.grow Acc -> (do (set beside.n (+ 1 (value beside.n))) (beside.grow [0 | Acc])))
(define beside.try -> (let V (absvector 4000000) (do (trap-error (beside.grow []) (/. E skip)) (<-address V 0))))
(shen-jit.collect)
(beside.try)
(output "within the limit: ~A~%" (<= (+ 4000000 (* 2 (value beside.n))) 8000000))
EOF
SHEN_JIT_GC_STRESS= SHEN_JIT_SEMISPACE=64M SHEN_JIT_MAX_HEAP=64M "$SHEN" script "$dir/beside.shen" > "$dir/beside.out" 2>&1
check limit-small-after-large "$dir/beside.out" "within the limit: true"
# Reals and strings that primitives make at the limit raise "out of memory", which a handler takes
# like any other error, after an earlier one was caught.
cat > "$dir/made.shen" <<'EOF'
(trap-error (simple-error "earlier") (/. E skip))
(define made.reals V I -> (do (address-> V I (* 1.5 I)) (made.reals V (+ I 1))))
(define made.strings V I -> (do (address-> V I (str I)) (made.strings V (+ I 1))))
(output "reals: ~A~%" (trap-error (made.reals (absvector 4000000) 0) (/. E (error-to-string E))))
(output "strings: ~A~%" (trap-error (made.strings (absvector 4000000) 0) (/. E (error-to-string E))))
EOF
SHEN_JIT_GC_STRESS= SHEN_JIT_MAX_HEAP=64M "$SHEN" script "$dir/made.shen" > "$dir/made.out" 2>&1
check limit-real "$dir/made.out" "reals: out of memory"
check limit-string "$dir/made.out" "strings: out of memory"
# A large string from compiled tlstr is a large object, which the limit refuses when the heap is full,
# though the reserve a caught "out of memory" leaves the area has room for it.
cat > "$dir/tail.shen" <<'EOF'
(define tail.fill X -> (do (set tail.held X) (tail.fill [0 | X])))
(define tail.try S -> (let Why (trap-error (tail.fill []) (/. E (error-to-string E)))
                           R (trap-error (do (tlstr S) allocated) (/. E (error-to-string E)))
                        (do (set tail.held []) (output "~A, then ~A~%" Why R))))
(tail.try (shen-jit.bytes->string (shen-jit.bytes 524288) 0 524288))
EOF
SHEN_JIT_GC_STRESS= SHEN_JIT_MAX_HEAP=64M "$SHEN" script "$dir/tail.shen" > "$dir/tail.out" 2>&1
check limit-large-tlstr "$dir/tail.out" "out of memory, then out of memory"
# A failed shen-jit.install gives back the constant slots it took, so that what they held can go: 100
# failures with a 400 KB constant each fit under 8 MB.
cat > "$dir/failed-load.shen" <<'EOF'
(define failed-load
  -> (trap-error (shen-jit.install [code broken 0 2 [(absvector 50000)] [[not-an-op]] []])
                 (/. E (error-to-string E))))
(define retry-load
  0 -> done
  N -> (let R (failed-load) (if (= R "unknown instruction") (retry-load (- N 1)) R)))
(output "~A~%" (retry-load 100))
EOF
SHEN_JIT_GC_STRESS= SHEN_JIT_MAX_HEAP=8M "$SHEN" script "$dir/failed-load.shen" > "$dir/failed-load.out" 2>&1
check failed-install-gives-back-constants "$dir/failed-load.out" "done"
# Size settings: less than a word is a word, not no limit, and what is not a size is refused.
SHEN_JIT_GC_STRESS= SHEN_JIT_MAX_HEAP=1 "$SHEN" eval -e '(trap-error (do (absvector 100000) allocated) (/. E (error-to-string E)))' \
    > "$dir/size.out" 2>&1
check size-below-a-word "$dir/size.out" "out of memory"
for setting in garbage -1 8MBogus 17179869184G; do
    SHEN_JIT_MAX_HEAP="$setting" "$SHEN" eval -e '1' > "$dir/size.out" 2>&1
    echo "status $?" >> "$dir/size.out"
    check "size-refused-$setting" "$dir/size.out" "status 1"
done
# A write that fails raises, from write-byte once the buffer fills and from close for what is left.
# Only Linux has it: MSYS2's shell shows one on Windows, which a native program cannot open.
if [ "$(uname -s)" = Linux ] && [ -w /dev/full ]; then
    cat > "$dir/full.shen" <<'SHEN'
(define fill S 0 -> ok S N -> (do (write-byte 65 S) (fill S (- N 1))))
(output "~A~%" (trap-error (fill (open "/dev/full" out) 100000) (/. E (error-to-string E))))
(let S (open "/dev/full" out)
  (do (write-byte 65 S)
      (output "~A~%" (trap-error (close S) (/. E (error-to-string E))))
      (output "~A~%" (close S))))
SHEN
    "$SHEN" script "$dir/full.shen" > "$dir/full.out" 2>&1
    contains write-failed "$dir/full.out" "write-byte: No space left on device"
    contains close-failed "$dir/full.out" "close: No space left on device"
fi
# A Datalog program in a saved image, with what it compiled and what it compiles there.
cat > "$dir/dl.shen" <<'EOF'
(defdatalog dl.kept
  (relation e [symbol symbol])
  (relation t [symbol symbol])
  (rule (t X Y) <-- (e X Y))
  (rule (t X Z) <-- (t X Y) (e Y Z)))
(defdatalog dl.later
  (relation e [symbol])
  (rule (e b) <-- (e a)))
(output "compiled ~R~%" (datalog.sorted (datalog.run dl.kept [[e a b] [e b c]]) t))
EOF
SHEN_JIT_GC_STRESS= "$SHEN" --save "$dir/dl.img" eval -l lib/native.shen -l lib/datalog.shen -l "$dir/dl.shen" > "$dir/dl.out" 2>&1 < /dev/null
check datalog-before-saving "$dir/dl.out" "compiled ((a b) (a c) (b c))"
SHEN_JIT_GC_STRESS= SHEN_JIT_IMAGE="$dir/dl.img" "$SHEN" eval \
    -e '(output "saved ~R~%" (datalog.sorted (datalog.run dl.kept [[e x y] [e y z]]) t))' \
    -e '(output "later ~R~%" (datalog.sorted (datalog.run dl.later [[e a]]) e))' > "$dir/dl2.out" 2>&1 < /dev/null
check datalog-saved "$dir/dl2.out" "saved ((x y) (x z) (y z))"
check datalog-compiled-after-saving "$dir/dl2.out" "later ((a) (b))"
# A write to a pipe that nobody reads raises, where SIGPIPE would end the process. Windows has no such signal.
if [ "$posix" = yes ]; then
    cat > "$dir/pipe.shen" <<EOF
(define fill N -> (do (pr "xxxxxxxxxxxxxxxx" (stoutput)) (fill (+ N 1))))
(let R (trap-error (fill 0) (/. E (error-to-string E)))
     S (open "$dir/pipe.out" out)
  (do (pr R S) (close S)))
EOF
    "$SHEN" script "$dir/pipe.shen" 2> /dev/null | true
    contains pipe-raises "$dir/pipe.out" "Broken pipe"
fi
# SHEN_JIT_SEMISPACE: where each semispace starts, or what the image needs if
# that is more. It still grows, and SHEN_JIT_MAX_HEAP can now be below 32 MB.
SHEN_JIT_GC_STRESS= SHEN_JIT_STATS=1 SHEN_JIT_SEMISPACE=8M "$SHEN" eval -e '(+ 1 2)' > "$dir/semi.out" 2>&1
contains semispace-set "$dir/semi.out" "semispace 8192 KB"
SHEN_JIT_GC_STRESS= SHEN_JIT_STATS=1 SHEN_JIT_SEMISPACE=0 "$SHEN" eval -e '(+ 1 2)' > "$dir/semi.out" 2>&1
contains semispace-zero "$dir/semi.out" "semispace 32768 KB"
SHEN_JIT_GC_STRESS= SHEN_JIT_SEMISPACE=1K "$SHEN" eval -e '(+ 1 2)' > "$dir/semi.out" 2>&1
contains semispace-tiny "$dir/semi.out" "3"
SHEN_JIT_GC_STRESS= SHEN_JIT_STATS=1 SHEN_JIT_SEMISPACE=3000000 "$SHEN" < "$dir/heap.in" > "$dir/semi.out" 2>&1
contains semispace-grows "$dir/semi.out" "(1-) 10000000"
SHEN_JIT_GC_STRESS= SHEN_JIT_SEMISPACE=2M SHEN_JIT_MAX_HEAP=8M "$SHEN" < "$dir/heap.in" > "$dir/semi.out" 2>&1
check semispace-limit "$dir/semi.out" '(1-) "out of memory"'
# Saving at SHEN_JIT_MAX_HEAP: a large object made since loading counts once, so its 500000 words
# and the rest fit a semispace of a million.
SHEN_JIT_GC_STRESS= SHEN_JIT_SEMISPACE=8000000 SHEN_JIT_MAX_HEAP=8000000 "$SHEN" --save "$dir/large.img" eval \
    -e '(shen-jit.collect)' -e '(do (set big (vector 499998)) ok)' > "$dir/large.out" 2>&1 < /dev/null
SHEN_JIT_GC_STRESS= SHEN_JIT_IMAGE="$dir/large.img" "$SHEN" eval -e '(limit (value big))' > "$dir/large.out" 2>&1 < /dev/null
check save-large-at-limit "$dir/large.out" "499998"
# The symbol table, which grows past half full and which a collection shrinks below a quarter. The
# collection that growing it can start may shrink it, when most of its symbols died since the last
# one: here they die by stores, which allocate nothing. The counts take it to 16384 slots and then
# past 8192 symbols, and a stress below the new table's size makes that growth always collect.
cat > "$dir/shrink.shen" <<'EOF'
(define names
  0 _ Acc -> Acc
  N Prefix Acc -> (names (- N 1) Prefix [(cn Prefix (str N)) | Acc]))
(define intern-into
  _ _ [] -> done
  V I [S | Ss] -> (do (address-> V I (intern S)) (intern-into V (+ I 1) Ss)))
(define drop-all
  V I N -> (if (= I N) done (do (address-> V I 0) (drop-all V (+ I 1) N))))
(define intern-each
  [] -> done
  [S | Ss] -> (do (intern S) (intern-each Ss)))
(define repro
  -> (let Held (names 5000 "held-" [])
          Fresh (names 6000 "fresh-" [])
          V (absvector 5000)
       (do (intern-into V 0 Held)
           (shen-jit.collect)
           (drop-all V 0 5000)
           (intern-each Fresh)
           (= (intern "append") append))))
(output "interned after a shrink: ~A~%" (repro))
EOF
SHEN_JIT_GC_STRESS=32768 "$SHEN" script "$dir/shrink.shen" > "$dir/shrink.out" 2>&1
check symbols-shrunk-while-growing "$dir/shrink.out" "interned after a shrink: true"
# And the first collection after it grows to 32768 slots, with every symbol kept and the heap full of
# live pairs: the new table needs the room the old one leaves.
cat > "$dir/table.shen" <<'EOF'
(define names
  0 _ Acc -> Acc
  N Prefix Acc -> (names (- N 1) Prefix [(cn Prefix (str N)) | Acc]))
(define intern-list
  [] Acc -> Acc
  [S | Ss] Acc -> (intern-list Ss [(intern S) | Acc]))
(define fill
  0 Acc -> Acc
  N Acc -> (fill (- N 1) [N | Acc]))
(define repro
  -> (let Before (names 3000 "before-" [])
          After (names 4500 "after-" [])
          Kept (intern-list Before [])
       (do (shen-jit.collect)
           (let More (intern-list After Kept)
                List (fill 1000000 [])
             [(length More) (length List)]))))
(output "kept beside a grown table: ~A~%" (repro))
EOF
SHEN_JIT_GC_STRESS= SHEN_JIT_SEMISPACE=8M "$SHEN" script "$dir/table.shen" > "$dir/table.out" 2>&1
check symbols-grown-in-full-heap "$dir/table.out" "kept beside a grown table: [7500 1000000]"
# With little address space it reserves less for the heap, and still runs.
(ulimit -v 2000000 2> /dev/null; "$SHEN" eval -e '(+ 1 2)') > "$dir/limited.out" 2>&1
check limited-address-space "$dir/limited.out" "3"

# The kernel's track works on open definitions and is refused on sealed
# ones; shen-jit.code shows a function's bytecode; SHEN_JIT_STATS ends
# with the live heap by type.
printf '(define fact 0 -> 1 N -> (* N (fact (- N 1))))\n(track fact)\n(fact 2)\n(shen-jit.code fact)\n' > "$dir/debug.in"
"$SHEN" < "$dir/debug.in" > "$dir/debug.out" 2>&1
contains track "$dir/debug.out" "<1> Inputs to fact"
contains code "$dir/debug.out" "(3-) [defun fact [code fact 1 "
"$SHEN" --seal < "$dir/debug.in" > "$dir/debug-sealed.out" 2>&1
check track-sealed "$dir/debug-sealed.out" "(1-) fact is sealed and cannot be redefined"
SHEN_JIT_STATS=1 "$SHEN" eval -e '(+ 1 2)' > "$dir/stats.out" 2>&1
contains heap-census "$dir/stats.out" "shen-jit: live heap "

# Redefining a function frees its old code's constant slots for the next
# definition, so 2000 redefinitions leave the
# number of constant slots where it started.
printf '(define redefine 0 -> done N -> (do (eval [define f X -> [X a "b" (/. Y [Y c])]]) (redefine (- N 1))))\n(redefine 2000)\n' \
    > "$dir/redefine.shen"
slots() { sed -n 's/.* \([0-9]*\) constant slots$/\1/p' "$1"; }
SHEN_JIT_STATS=1 "$SHEN" eval -e 1 > "$dir/slots-start.out" 2>&1
SHEN_JIT_STATS=1 "$SHEN" script "$dir/redefine.shen" > "$dir/slots-end.out" 2>&1
if [ "$(slots "$dir/slots-end.out")" -le "$(( $(slots "$dir/slots-start.out") + 100 ))" ]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL constant-reuse: $(slots "$dir/slots-start.out") slots at start, $(slots "$dir/slots-end.out") after"
fi
# The native code of code objects that died goes back to the JIT
#: redefining a function 2000
# times and calling each version once compiles 2000 of them, and a few
# hundred at most stay.
printf '(define new 0 -> done N -> (do (eval [define g (protect X) -> [+ (protect X) N]]) (do (g 1) (new (- N 1)))))\n(new 2000)\n' \
    > "$dir/new.shen"
SHEN_JIT_STATS=1 SHEN_JIT_GC_STRESS=100000 "$SHEN" script "$dir/new.shen" > "$dir/native.out" 2>&1
native() { sed -n "s/.*native code: \([0-9]*\) code objects compiled, \([0-9]*\) freed$/\\$1/p" "$dir/native.out"; }
if [ "$(native 1)" -ge 2000 ] && [ "$(( $(native 1) - $(native 2) ))" -le 500 ]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL native-freed: $(native 1) compiled, $(native 2) freed"
fi

if [ "$posix" = yes ]; then
# The profiler: at exit, a flat profile
# on stderr, whose first line is the function that ran the longest.
printf '(define tak X Y Z -> (if (not (< Y X)) Z (tak (tak (- X 1) Y Z) (tak (- Y 1) Z X) (tak (- Z 1) X Y))))\n(tak 30 20 10)\n' \
    > "$dir/tak.shen"
SHEN_JIT_PROFILE=1 "$SHEN" script "$dir/tak.shen" > "$dir/profile.out" 2>&1
if awk 'header { exit $NF == "tak" ? 0 : 1 } /^shen-jit: profile of [0-9]+ samples/ { header = 1 } END { if (!header) exit 1 }' "$dir/profile.out"; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL profile: tak is not the first line of:"
    sed 's/^/    /' "$dir/profile.out"
fi
fi

# (shen-jit.save-executable Path Entry) writes a binary and ends the process.
# With an entry point it is a program: all its arguments are its own, and
# what the heap holds lasts, but not where it was built.
mkdir -p "$dir/elsewhere" "$dir/sub"
cat > "$dir/app.shen" <<EOF
(set app.kept 5)
(define app.main
  -> (do (output "args ~S~%" (tl (value *argv*)))
         (output "kept ~A~%" (value app.kept))))
(shen-jit.save-executable "$dir/app" app.main)
(output "not reached~%")
EOF
"$SHEN" eval -l "$dir/app.shen" > "$dir/save.out" 2>&1
echo "status $?" >> "$dir/save.out"
check save-exe-status "$dir/save.out" "status 0"
if grep -q "not reached" "$dir/save.out"; then
    fail=$((fail + 1))
    echo "FAIL save-exe-ends: it went on after saving"
else
    pass=$((pass + 1))
fi
(cd "$dir/elsewhere" && ../app --seal x) > "$dir/app.out" 2>&1
echo "status $?" >> "$dir/app.out"
check save-exe-args "$dir/app.out" 'args ["--seal" "x"]'
check save-exe-kept "$dir/app.out" "kept 5"
check save-exe-run "$dir/app.out" "status 0"
# Arguments arrive as UTF-8 on every platform, including supplementary Unicode scalars on Windows.
cat > "$dir/utf8-main.shen" <<'EOF'
(define utf8.main
  -> (if (= (tl (value *argv*)) ["c#206;c#187;" "c#240;c#159;c#152;c#128;" ""])
         (output "unicode argv ok~%")
         (error "command-line arguments changed")))
EOF
printf '(load "%s/utf8-main.shen")\n(utf8.main)\n' "$dir" > "$dir/utf8-script.shen"
"$SHEN" script "$dir/utf8-script.shen" 'λ' '😀' '' > "$dir/utf8-script.out" 2>&1
check utf8-script-args "$dir/utf8-script.out" "unicode argv ok"
"$SHEN" eval -l "$dir/utf8-main.shen" \
    -e "(shen-jit.save-executable \"$dir/utf8-app\" utf8.main)" > "$dir/utf8-save.out" 2>&1
"$dir/utf8-app" 'λ' '😀' '' > "$dir/utf8-app.out" 2>&1
check utf8-saved-args "$dir/utf8-app.out" "unicode argv ok"
# With a collection at every allocation, nothing but its value keeps the entry point's
# global alive while the image is written.
SHEN_JIT_GC_STRESS=1 "$SHEN" script "$dir/app.shen" > /dev/null 2>&1
"$dir/app" --seal x > "$dir/app-stress.out" 2>&1
check save-exe-stress "$dir/app-stress.out" "kept 5"
# Native code written by hand is saved like any other.
cat > "$dir/native.shen" <<EOF
(define-native native.double (X) (prim R * X 2) (return R))
(define native.main -> (output "double ~A~%" (native.double 21)))
(shen-jit.save-executable "$dir/native" native.main)
EOF
"$SHEN" eval -l lib/native.shen -l "$dir/native.shen" > /dev/null 2>&1
"$dir/native" > "$dir/native.out" 2>&1
check save-exe-native "$dir/native.out" "double 42"
# Buffers are saved with their contents, also a large one, whose block is its own.
cat > "$dir/buffers.shen" <<EOF
(set buffers.small (shen-jit.u32! (shen-jit.bytes 8) 4 123456))
(set buffers.large (shen-jit.u32! (shen-jit.bytes 300000) 299996 654321))
(define buffers.main -> (output "kept ~A ~A~%" (shen-jit.u32 (value buffers.small) 4) (shen-jit.u32 (value buffers.large) 299996)))
(shen-jit.save-executable "$dir/buffers" buffers.main)
EOF
"$SHEN" eval -l "$dir/buffers.shen" > /dev/null 2>&1
"$dir/buffers" > "$dir/buffers.out" 2>&1
check save-exe-buffers "$dir/buffers.out" "kept 123456 654321"
# Prolog variables: by value, printed unbound from a query, and kept in an image.
cat > "$dir/pvar.shen" <<EOF
(defprolog pvar.app
  [] X X <--;
  [H | T] X [H | Y] <-- (pvar.app T X Y);)
(set pvar.kept [(shen-jit.pvar 7)])
(define pvar.main ->
  (output "~S ~S ~S ~S ~S ~S~%"
    (prolog? (is X Y) (return X))
    (prolog? (pvar.app [1 2] [3] R) (return R))
    (prolog? (pvar.app A B [1]) (return [A B]))
    (prolog? (is [X Y] [1 2]) (is Z [Y X]) (return Z))
    ((fn shen-jit.pvar-offset) ((fn shen-jit.pvar) 9))
    (shen-jit.pvar-offset (hd (value pvar.kept)))))
(shen-jit.save-executable "$dir/pvar" pvar.main)
EOF
"$SHEN" eval -l "$dir/pvar.shen" > /dev/null 2>&1
"$dir/pvar" > "$dir/pvar.out" 2>&1
check prolog-variables "$dir/pvar.out" "Var2 [1 2 3] [[] [1]] [2 1] 9 7"
# The port's unifiers against the kernel's, on random terms.
"$SHEN" eval -l tests/prolog-unify.shen 2>&1 | grep -a 'differs\|passed,\|uncaught' > "$dir/unify.out"
check prolog-unify "$dir/unify.out" "1495 passed, 0 failed"
# Refusing a system function's name, in the kernel's words, which end the line.
"$SHEN" eval -e '(trap-error (shen.record-and-evaluate [defun hd [x] x]) (/. E (pr (cn "[" (cn (error-to-string E) "]")))))' > "$dir/refused.out" 2>&1
check refused-name "$dir/refused.out" "[hd is not a legitimate function name"
# From deep in the stack and inside a handler: those frames are not saved.
cat > "$dir/deep.shen" <<EOF
(define deep.main -> (output "deep ok~%"))
(define deep.go
  0 -> (shen-jit.save-executable "$dir/deep" deep.main)
  N -> (+ 1 (deep.go (- N 1))))
(trap-error (deep.go 5000) (/. E E))
EOF
"$SHEN" eval -q -l "$dir/deep.shen" > /dev/null 2>&1
"$dir/deep" > "$dir/deep.out" 2>&1
check save-exe-deep "$dir/deep.out" "deep ok"
# An error in the entry point, and its exit status.
"$SHEN" eval -q -e '(define err.main -> (simple-error "boom"))' \
    -e "(shen-jit.save-executable \"$dir/err\" err.main)" > /dev/null 2>&1
"$dir/err" > "$dir/err.out" 2>&1
echo "status $?" >> "$dir/err.out"
check save-exe-error "$dir/err.out" "shen-jit: uncaught error: boom"
check save-exe-error-status "$dir/err.out" "status 1"
"$SHEN" eval -q -e '(define st.main -> (shen-jit.exit 3))' \
    -e "(shen-jit.save-executable \"$dir/st\" st.main)" > /dev/null 2>&1
"$dir/st" > /dev/null 2>&1
echo "status $?" > "$dir/st.out"
check save-exe-exit "$dir/st.out" "status 3"
# Without an entry point it keeps the launcher. A binary can make another, or
# replace itself, and only ever holds one image.
"$SHEN" eval -q -e '(define lib.f -> lib-ok)' \
    -e "(shen-jit.save-executable \"$dir/lib\" [])" > /dev/null 2>&1
"$dir/lib" eval -q -e "(shen-jit.save-executable \"$dir/lib\" [])" > /dev/null 2>&1
"$dir/lib" eval -e '(lib.f)' > "$dir/lib.out" 2>&1
check save-exe-launcher "$dir/lib.out" "lib-ok"
if [ "$(wc -c < "$dir/lib")" -lt "$(($(wc -c < "$SHEN") + 65536))" ]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL save-exe-one-image: $(wc -c < "$dir/lib") bytes against $(wc -c < "$SHEN")"
fi
if ls "$dir"/*.tmp > /dev/null 2>&1; then
    fail=$((fail + 1))
    echo "FAIL save-exe-temporary: a temporary file is left"
else
    pass=$((pass + 1))
fi
# The path is relative to *home-directory*, as open's is; the home is not kept.
(cd "$dir" && "$SHEN" eval -q -e '(define home.main -> (output "home [~A]~%" (value *home-directory*)))' \
    -e '(cd "sub/")' -e '(shen-jit.save-executable "home" home.main)') > /dev/null 2>&1
"$dir/sub/home" > "$dir/home.out" 2>&1
check save-exe-home "$dir/home.out" "home []"
# From an image loaded with SHEN_JIT_IMAGE, the runtime is still this binary's.
"$SHEN" --save "$dir/v.img" eval -q -e '(set v.x 9)' > /dev/null 2>&1
SHEN_JIT_IMAGE="$dir/v.img" "$SHEN" eval -q -e "(shen-jit.save-executable \"$dir/v\" [])" > /dev/null 2>&1
"$dir/v" eval -e '(value v.x)' > "$dir/v.out" 2>&1
check save-exe-image "$dir/v.out" "9"
# Type information lasts: checked here against what the binary was saved with.
cat > "$dir/ty.shen" <<EOF
(datatype ty.colour
  ______________
  ty.red : ty.colour;)
(define ty.same
  {ty.colour --> ty.colour}
  C -> C)
EOF
printf '(define ty.good {ty.colour --> ty.colour} C -> (ty.same C))\n' > "$dir/ty-good.shen"
printf '(define ty.bad {number --> ty.colour} N -> (ty.same N))\n' > "$dir/ty-bad.shen"
"$SHEN" eval -q -e '(tc +)' -l "$dir/ty.shen" -e '(tc -)' -e "(shen-jit.save-executable \"$dir/ty\" [])" > /dev/null 2>&1
"$dir/ty" eval -q -e '(tc +)' -l "$dir/ty-good.shen" > "$dir/ty-good.out" 2>&1
echo "status $?" >> "$dir/ty-good.out"
check save-exe-types-accepted "$dir/ty-good.out" "status 0"
"$dir/ty" eval -q -e '(tc +)' -l "$dir/ty-bad.shen" > "$dir/ty-bad.out" 2>&1
echo "status $?" >> "$dir/ty-bad.out"
check save-exe-types-refused "$dir/ty-bad.out" "status 1"
# What it cannot do raises, and the process goes on.
(cd "$dir" && "$SHEN" eval -e '(define two.f X Y -> X)' \
    -e '(output "~A~%" (trap-error (shen-jit.save-executable "x" nosuch) (/. E (error-to-string E))))' \
    -e '(output "~A~%" (trap-error (shen-jit.save-executable "x" two.f) (/. E (error-to-string E))))' \
    -e '(output "~A~%" (trap-error (shen-jit.save-executable "none/x" []) (/. E (error-to-string E))))' \
    -e '(output "still here~%")') > "$dir/bad.out" 2>&1
check save-exe-undefined "$dir/bad.out" "nosuch is not a function of no arguments"
check save-exe-arity "$dir/bad.out" "two.f is not a function of no arguments"
check save-exe-unwritable "$dir/bad.out" 'save-executable: cannot write "none/x"'
check save-exe-goes-on "$dir/bad.out" "still here"

# Threads (tests/threads.shen).
"$SHEN" script "$(dirname "$0")/threads.shen" > "$dir/threads.out" 2> "$dir/threads.err" < /dev/null
check thread-started "$dir/threads.out" "first true"
check thread-spin-wait "$dir/threads.out" "spin spin"
check thread-loops "$dir/threads.out" "loops loops"
check thread-deep "$dir/threads.out" "deep 2400120000"
check thread-handlers "$dir/threads.out" "caught 15000"
check thread-after-error "$dir/threads.out" "after-error ok"
contains thread-error-message "$dir/threads.err" "shen-jit: thread: boom in a thread"
check thread-defines "$dir/threads.out" "defined 2"
check thread-by-fn "$dir/threads.out" "by-fn by-fn"
check thread-not-a-function "$dir/threads.out" "not-a-function thread: 1 is not a function"
check thread-many "$dir/threads.out" "many done"
# A thread runs while the REPL waits for input, whose line then sees its work.
{ printf '(thread (freeze (set tflag ran)))\n'; sleep 0.5; printf '(value tflag)\n'; } | "$SHEN" > "$dir/thr1.out" 2>&1
check thread-while-reading "$dir/thr1.out" "(1-) ran"
# A thread that ends the process while the REPL waits for input.
{ printf '(thread (freeze (shen-jit.exit 3)))\n'; sleep 0.5; } | "$SHEN" > "$dir/thr2.out" 2>&1
echo "status $?" >> "$dir/thr2.out"
contains thread-exit "$dir/thr2.out" "status 3"
# Threads end with the main one, however long they would run.
printf '(define forever N -> (forever (+ N 1)))\n(thread (freeze (forever 0)))\n(output "main ends~%%")\n' > "$dir/thr3.shen"
"$SHEN" script "$dir/thr3.shen" > "$dir/thr3.out" 2>&1 < /dev/null
echo "status $?" >> "$dir/thr3.out"
check thread-main-ends "$dir/thr3.out" "main ends"
check thread-main-ends-status "$dir/thr3.out" "status 0"
# Output written to a file before the process ends with threads about.
printf '(define forever N -> (forever (+ N 1)))\n(thread (freeze (forever 0)))\n(set s (open "%s/thr4.txt" out))\n(pr "written" (value s))\n(shen-jit.exit 0)\n' "$dir" > "$dir/thr4.shen"
"$SHEN" script "$dir/thr4.shen" > /dev/null 2>&1 < /dev/null
printf '\n' >> "$dir/thr4.txt"
check thread-flushes-files "$dir/thr4.txt" "written"
# Programs may define their own thread.
printf '(define thread X -> [own X])\n(output "~S~%%" (thread 1))\n' > "$dir/thr5.shen"
"$SHEN" script "$dir/thr5.shen" > "$dir/thr5.out" 2>&1 < /dev/null
check thread-own-definition "$dir/thr5.out" "[own 1]"
# An image saved with a thread still about holds what the main thread reaches.
printf '(define forever N -> (forever (+ N 1)))\n(thread (freeze (forever 0)))\n(set saved kept)\n' > "$dir/thr6.shen"
"$SHEN" --save "$dir/thr6.img" script "$dir/thr6.shen" > /dev/null 2>&1 < /dev/null
SHEN_JIT_IMAGE="$dir/thr6.img" "$SHEN" eval -e '(value saved)' > "$dir/thr6.out" 2>&1
check thread-saved-image "$dir/thr6.out" "kept"
printf '(define forever N -> (forever (+ N 1)))\n(thread (freeze (forever 0)))\n(output "~A~%%" (trap-error (shen-jit.save-executable "%s/thr7" (fn hd)) (/. E (error-to-string E))))\n' "$dir" > "$dir/thr7.shen"
"$SHEN" script "$dir/thr7.shen" > "$dir/thr7.out" 2>&1 < /dev/null
check thread-save-executable "$dir/thr7.out" "save-executable: other threads are running"

wait_for() { # text, file
    n=0
    while ! grep -qF -- "$1" "$2" && [ $n -lt 200 ]; do sleep 0.05; n=$((n + 1)); done
}

interrupts_to() { # how many lines saying interrupted to wait for, file; the process is $pid
    n=0
    while kill -0 $pid 2>/dev/null && [ "$(grep -c interrupted "$2")" -lt "$1" ] && [ $n -lt 40 ]; do
        kill -INT $pid 2>/dev/null
        sleep 0.1
        n=$((n + 1))
    done
}

ends() { # how long to give $pid to end; its status is in $status
    n=0
    while kill -0 $pid 2>/dev/null && [ $n -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
    kill -9 $pid 2>/dev/null
    wait $pid 2>/dev/null
    status=$?
}

if [ "$posix" = yes ]; then
# Ctrl-C is for the REPL's own work: a thread running beside it goes on, and its
# progress after the interrupt shows it was not the one stopped. A FIFO holds back
# what comes after the interrupt until it has been seen: on a busy machine the
# signal can take longer than the wait between tries, and a second one must not
# reach that expression.
mkfifo "$dir/thr8"
"$SHEN" < "$dir/thr8" > "$dir/thr8.out" 2>&1 &
pid=$!
exec 3> "$dir/thr8"
cat >&3 <<'EOF'
(define spin N -> (spin (+ N 1)))
(define pause 0 -> done N -> (pause (- N 1)))
(set beats 0)
(define beat N -> (do (set beats (+ (value beats) 1)) (beat N)))
(thread (freeze (beat 0)))
EOF
wait_for "(4-) true" "$dir/thr8.out"
printf '(spin 0)\n' >&3
sleep 0.2
interrupts_to 1 "$dir/thr8.out"
sleep 0.2
printf '(let A (value beats) W (pause 300000000) (if (> (value beats) A) beats-went-on stuck))\n' >&3
exec 3>&-
ends
contains thread-interrupt "$dir/thr8.out" "interrupted"
contains thread-survives-interrupt "$dir/thr8.out" "beats-went-on"

# Ctrl-C while the REPL waits for input, which a FIFO holds open: a half-typed
# expression is dropped, and a program waiting for input stops, even inside its own
# trap-error. With a thread running beside it the signal still has to reach the main
# thread, whose wait it ends. End of input then ends the REPL as usual.
mkfifo "$dir/held"
"$SHEN" < "$dir/held" > "$dir/held.out" 2>&1 &
pid=$!
exec 3> "$dir/held"
wait_for "(0-) " "$dir/held.out"
printf '(+ 1\n' >&3
sleep 0.3
interrupts_to 1 "$dir/held.out"
printf '(+ 3 4)\n' >&3
wait_for "(0-) 7" "$dir/held.out"
printf '(trap-error (read-byte (stinput)) (/. E caught))\n' >&3
sleep 0.3
interrupts_to 2 "$dir/held.out"
printf '(+ 5 6)\n(define beat N -> (beat (+ N 1)))\n(thread (freeze (beat 0)))\n' >&3
wait_for "(4-) true" "$dir/held.out"
sleep 0.1
interrupts_to 3 "$dir/held.out"
printf '(+ 7 8)\n' >&3
wait_for "(5-) 15" "$dir/held.out"
exec 3>&-
ends
check interrupt-half-typed "$dir/held.out" "(0-) interrupted"
check interrupt-half-typed-dropped "$dir/held.out" "(0-) 7"
check interrupt-program-reading "$dir/held.out" "(1-) interrupted"
check interrupt-program-reading-continues "$dir/held.out" "(2-) 11"
check interrupt-prompt-beside-thread "$dir/held.out" "(5-) interrupted"
check interrupt-prompt-beside-thread-continues "$dir/held.out" "(5-) 15"
[ "$status" -eq 0 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL interrupt-end-of-input: status $status"; }

# A loop that ran before the REPL started, so before it caught Ctrl-C, can still be
# stopped there: otherwise nothing would stop it, the signal no longer ending the process.
printf '(define count-down N -> (if (= N 0) done (count-down (- N 1))))\n(count-down 5)\n' > "$dir/early.shen"
printf '(count-down 100000000000000)\n(+ 1 2)\n' > "$dir/early.in"
for seal in "" --seal; do
    "$SHEN" $seal eval -l "$dir/early.shen" -r < "$dir/early.in" > "$dir/early.out" 2>&1 &
    pid=$!
    wait_for "(0-) " "$dir/early.out"
    interrupts_to 1 "$dir/early.out"
    ends
    check "interrupt-compiled-early$seal" "$dir/early.out" "(0-) interrupted"
    check "interrupt-compiled-early-continues$seal" "$dir/early.out" "(1-) 3"
done

# Ctrl-C after Ctrl-C, some landing while the REPL prints its prompt or the last
# error, outside its handler, where one must not end the session.
"$SHEN" < "$dir/held" > "$dir/burst.out" 2>&1 &
pid=$!
exec 3> "$dir/held"
wait_for "(0-) " "$dir/burst.out"
n=0
while [ $n -lt 300 ]; do kill -INT $pid 2>/dev/null; n=$((n + 1)); done
sleep 0.2
printf '(+ 8 9)\n' >&3
exec 3>&-
ends
contains interrupt-burst "$dir/burst.out" "(0-) 17"
[ "$status" -eq 0 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL interrupt-burst-status: status $status"; }
fi

# C functions (lib/ffi.shen; tests/ffi.shen has the rest). Saved in an image, one finds its
# function again and a pointer is dead. A backtrace names one, and a static build says what it cannot do.
cat > "$dir/ffi.shen" <<EOF
(shen-jit.library ffi.libc ["libc.so.6" "libSystem.dylib" "ucrtbase.dll"])
(define-foreign ffi.malloc ffi.libc "malloc" (int64) --> pointer)
(define-foreign ffi.free ffi.libc "free" (pointer) --> void)
(define-foreign ffi.strlen ffi.libc "strlen" (string) --> int64)
(set ffi.live (trap-error (ffi.malloc 16) (/. E (do (output "~A~%" (error-to-string E)) (shen-jit.exit 0)))))
(output "strlen ~A~%" (ffi.strlen "abc"))
(output "live ~A~%" (> (shen-jit.pointer-address (value ffi.live)) 0))
(define ffi.main
  -> (do (output "again ~A~%" (ffi.strlen "abcd"))
         (output "address ~A~%" (shen-jit.pointer-address (value ffi.live)))
         (output "~A~%" (trap-error (ffi.free (value ffi.live)) (/. E "raised")))
         (ffi.strlen 1)))
(shen-jit.save-executable "$dir/ffi" ffi.main)
EOF
"$SHEN" eval -l lib/ffi.shen -l "$dir/ffi.shen" > "$dir/ffi.out" 2>&1 < /dev/null
if grep -q "this static build" "$dir/ffi.out"; then
    check ffi-static "$dir/ffi.out" "foreign: this static build cannot load libraries"
else
    check ffi-before-saving "$dir/ffi.out" "strlen 3"
    check ffi-live-pointer "$dir/ffi.out" "live true"
    "$dir/ffi" > "$dir/ffi2.out" 2>&1 < /dev/null
    echo "status $?" >> "$dir/ffi2.out"
    check ffi-found-again "$dir/ffi2.out" "again 4"
    check ffi-pointer-address "$dir/ffi2.out" "address 0"
    check ffi-dead-pointer "$dir/ffi2.out" "raised"
    check ffi-uncaught "$dir/ffi2.out" "shen-jit: uncaught error: foreign: 1 is not a string"
    check ffi-status "$dir/ffi2.out" "status 1"
    # Memory outside the heap is not saved: in an image its pointer is dead, and the ordinary
    # bounds check refuses it.
    cat > "$dir/mem.shen" <<'EOF'
(set mem.kept (memory.alloc 8))
(shen-jit.u8! (value mem.kept) 0 9)
(output "before saving ~A~%" (shen-jit.u8 (value mem.kept) 0))
EOF
    "$SHEN" --save "$dir/mem.img" eval -l lib/ffi.shen -l lib/memory.shen -l "$dir/mem.shen" > "$dir/mem.out" 2>&1 < /dev/null
    check memory-before-saving "$dir/mem.out" "before saving 9"
    SHEN_JIT_IMAGE="$dir/mem.img" "$SHEN" eval \
        -e '(output "~A ~A~%" (shen-jit.bytes-length (value mem.kept)) (trap-error (shen-jit.u8 (value mem.kept) 0) (/. E (error-to-string E))))' \
        > "$dir/mem2.out" 2>&1 < /dev/null
    check memory-dead-in-image "$dir/mem2.out" "0 bytes: 0 is not a valid index"
    # A handle is dead there too, with nothing left to release it.
    cat > "$dir/handle.shen" <<'EOF'
(set handle.kept (handle.wrap (memory.alloc 8) (/. M (memory.free M))))
(shen-jit.u8! (value handle.kept) 0 9)
(output "before saving ~A~%" (shen-jit.u8 (value handle.kept) 0))
EOF
    "$SHEN" --save "$dir/handle.img" eval -l lib/ffi.shen -l lib/memory.shen -l lib/handle.shen -l "$dir/handle.shen" > "$dir/handle.out" 2>&1 < /dev/null
    check handle-before-saving "$dir/handle.out" "before saving 9"
    SHEN_JIT_IMAGE="$dir/handle.img" "$SHEN" eval \
        -e '(let K (value handle.kept) (do (set handle.kept []) (shen-jit.collect) (output "~A ~A ~A~%" (shen-jit.bytes-length K) (handle.sweep) (trap-error (handle.close K) (/. E (error-to-string E))))))' \
        > "$dir/handle2.out" 2>&1 < /dev/null
    check handle-dead-in-image "$dir/handle2.out" "0 0 handle.close: #<pointer pointer 0x0> is not a handle"
    cat > "$dir/ffi3.shen" <<EOF
(shen-jit.library ffi.libc ["libc.so.6" "libSystem.dylib" "ucrtbase.dll"])
(define-foreign ffi.strlen ffi.libc "strlen" (string) --> int64)
(define ffi.outer X -> (+ 1 (ffi.strlen X)))
(ffi.outer 1)
EOF
    "$SHEN" eval -l lib/ffi.shen -l "$dir/ffi3.shen" > "$dir/ffi3.out" 2>&1 < /dev/null
    check ffi-backtrace "$dir/ffi3.out" "  in ffi.strlen"
    check ffi-backtrace-caller "$dir/ffi3.out" "  in ffi.outer"

    # A child finds SIGPIPE at its default: exec resets the handler, as it would not an ignored signal.
    if [ "$posix" = yes ]; then
        cat > "$dir/child.shen" <<EOF
(shen-jit.library child.libc ["libc.so.6" "libSystem.dylib"])
(define-foreign child.system child.libc "system" (string) --> int32)
(child.system "(yes 2> /dev/null; echo \$? > $dir/child.out) | head -1 > /dev/null")
EOF
        "$SHEN" eval -l lib/ffi.shen -l "$dir/child.shen" > /dev/null 2>&1 < /dev/null
        check child-sigpipe "$dir/child.out" "141"
    fi

    # Shen called from C without end stops before the C stack does, as an error any code can
    # catch, on the main thread and on another. The test library is made for this by the Makefile,
    # and is named in full: a program finds what it names from wherever it runs.
    ffi_test=$PWD/build/ffi_test.so
    if [ "$posix" = no ]; then ffi_test=$(cygpath -w "$PWD/build/ffi_test.dll"); fi
    cat > "$dir/nest-lib.shen" <<EOF
(shen-jit.library c.lib ["$ffi_test"])
(define-foreign-procedure c.call c.lib "call_in_c" 2)
(define c.deep N -> (c.call (/. X (c.deep (+ X 1))) N))
EOF
    cat > "$dir/nest.shen" <<'EOF'
(output "main: ~A~%" (trap-error (c.deep 0) (/. E (error-to-string E))))
(set c.out 0)
(thread (freeze (set c.out (trap-error (c.deep 0) (/. E (error-to-string E))))))
(define c.wait -> (if (= (value c.out) 0) (c.wait) (value c.out)))
(output "thread: ~A~%" (c.wait))
(output "goes on: ~A~%" (c.call (/. X (+ X 1)) 1))
(define c.down N -> (if (= N 0) 0 (+ 1 (c.down (- N 1)))))
(output "stack moved: ~S~%" (let A (cn "a" "b") (cons A (c.call (/. X (c.down 300000)) 1))))
EOF
    cat > "$dir/nest-main.shen" <<EOF
(load "lib/ffi.shen")
(load "$dir/nest-lib.shen")
(load "$dir/nest.shen")
EOF
    "$SHEN" script "$dir/nest-main.shen" > "$dir/nest.out" 2>&1 < /dev/null
    check nested-stack-overflow "$dir/nest.out" "main: stack overflow"
    check nested-stack-overflow-thread "$dir/nest.out" "thread: stack overflow"
    check nested-goes-on "$dir/nest.out" "goes on: [1 | 2]"
    check nested-stack-moved "$dir/nest.out" 'stack moved: ["ab" 1 | 300000]'
    # The same under a handler that ignores its error: C still gets the error to read, and goes on.
    cat > "$dir/nest-quiet.shen" <<EOF
(shen-jit.library q.lib ["$ffi_test"])
(define-foreign-procedure q.capture q.lib "caught_exception" 2)
(set q.message missing)
(define q.recur N ->
  (trap-error (let R (q.capture (/. X (q.recur (+ X 1))) N)
                (if (= R no-error) done (do (set q.message (error-to-string R)) done)))
              (/. E ignored)))
(output "result: ~A~%" (q.recur 0))
(output "message: ~A~%" (value q.message))
(output "continues: ~A~%" (+ 20 22))
EOF
    "$SHEN" eval -l lib/ffi.shen -l "$dir/nest-quiet.shen" > "$dir/nest-quiet.out" 2>&1 < /dev/null
    check nested-quiet-result "$dir/nest-quiet.out" "result: done"
    check nested-quiet-message "$dir/nest-quiet.out" "message: stack overflow"
    check nested-quiet-continues "$dir/nest-quiet.out" "continues: 42"

    # A nested call near the end of the guest stack must leave room for a callee that does
    # not check its frame. An overrun usually goes unseen, so where Guard Malloc exists, which
    # faults on it at once, try each alignment of the stack: frames repeat every few words.
    if [ -f /usr/lib/libgmalloc.dylib ]; then
        k=0
        while [ $k -lt 12 ]; do
            cat > "$dir/align.shen" <<EOF
(define c.pad 0 F -> (thaw F) N F -> (hd [(c.pad (- N 1) F)]))
(output "~A~%" (c.pad $k (freeze (trap-error (c.deep 0) (/. E (error-to-string E))))))
EOF
            cat > "$dir/align-main.shen" <<EOF
(load "lib/ffi.shen")
(load "$dir/nest-lib.shen")
(load "$dir/align.shen")
EOF
            DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib "$SHEN" script "$dir/align-main.shen" > "$dir/align.out" 2>&1 < /dev/null
            check "nested-stack-end-$k" "$dir/align.out" "stack overflow"
            k=$((k + 1))
        done
    fi

    # What C must not do ends the process, naming the procedure and what it did. A value left over
    # from before a collection needs collections to show.
    misuse() { # the C function, what the message must contain, and the stress setting if any
        cat > "$dir/misuse.shen" <<EOF
(shen-jit.library c.lib ["$ffi_test"])
(define-foreign-procedure c.misuse c.lib "$1" 0)
(c.misuse)
EOF
        SHEN_JIT_GC_STRESS=$3 "$SHEN" eval -l lib/ffi.shen -l "$dir/misuse.shen" > "$dir/misuse.out" 2>&1 < /dev/null
        contains "misuse-$1" "$dir/misuse.out" "shen-jit: foreign function c.misuse: $2"
    }
    misuse returns_none "it returned SHEN_NONE"
    misuse cons_none "shen_cons was given SHEN_NONE"
    misuse cons_error "shen_cons was given SHEN_ERROR"
    misuse returns_stale "it returned a value from before a collection" 1000
    misuse reads_stale "shen_is_string was given a value from before a collection" 1000

    # Sockets in a saved program, which on Windows has to start Winsock again in its own process.
    cat > "$dir/net.shen" <<EOF
(define net.main
  -> (let L (socket.listen "127.0.0.1" 0)
          Port (socket.port L)
          Client (thread (freeze (let C (socket.connect "127.0.0.1" Port)
                                   (do (socket.send C "over the wire") (socket.close C)))))
          A (socket.accept L)
       (output "net: ~A~%" (socket.recv-string A 100))))
(shen-jit.save-executable "$dir/net" net.main)
EOF
    "$SHEN" eval -l lib/ffi.shen -l lib/socket.shen -l "$dir/net.shen" > /dev/null 2>&1 < /dev/null
    "$dir/net" > "$dir/net.out" 2>&1 < /dev/null
    check socket-saved-program "$dir/net.out" "net: over the wire"

    # Ctrl-C at the REPL ends a wait on a socket, in accept and in recv, and the REPL goes on.
    if [ "$posix" = yes ]; then
        mkfifo "$dir/sock"
        "$SHEN" < "$dir/sock" > "$dir/sock.out" 2>&1 &
        pid=$!
        exec 3> "$dir/sock"
        wait_for "(0-) " "$dir/sock.out"
        printf '(load "lib/ffi.shen")\n' >&3
        wait_for "(1-) " "$dir/sock.out"
        printf '(load "lib/socket.shen")\n' >&3
        wait_for "(2-) " "$dir/sock.out"
        printf '(set l (socket.listen "127.0.0.1" 0))\n' >&3
        wait_for "(3-) " "$dir/sock.out"
        printf '(socket.accept (value l))\n' >&3
        sleep 0.3
        interrupts_to 1 "$dir/sock.out"
        printf '(set c (socket.connect "127.0.0.1" (socket.port (value l))))\n' >&3
        wait_for "(5-) " "$dir/sock.out"
        printf '(socket.recv (value c) 10)\n' >&3
        sleep 0.3
        interrupts_to 2 "$dir/sock.out"
        printf '(+ 8 9)\n' >&3
        wait_for "17" "$dir/sock.out"
        exec 3>&-
        ends
        check interrupt-socket-accept "$dir/sock.out" "(3-) interrupted"
        check interrupt-socket-recv "$dir/sock.out" "(5-) interrupted"
        check interrupt-socket-continues "$dir/sock.out" "(6-) 17"
    fi
fi

# Each thread keeps its own backtrace, and the reports at exit still come once a thread has started.
cat > "$dir/thread-traces.shen" <<'EOF'
(define trace-wait Key -> (if (value Key) done (trace-wait Key)))
(define trace-first X -> (do (set first-done true) (hd X)))
(define trace-second X -> (do (set second-done true) (tl X)))
(set first-done false)
(set second-done false)
(thread (freeze (eval-kl [trace-first 0])))
(trace-wait first-done)
(thread (freeze (eval-kl [trace-second 0])))
(trace-wait second-done)
EOF
"$SHEN" script "$dir/thread-traces.shen" > "$dir/thread-traces.out" 2>&1
check thread-own-backtrace "$dir/thread-traces.out" "  in trace-second"
SHEN_JIT_STATS=1 "$SHEN" eval -e '(thread (freeze 1))' > "$dir/thread-stats.out" 2>&1
contains thread-statistics "$dir/thread-stats.out" "shen-jit: live heap"
if [ "$posix" = yes ]; then
    SHEN_JIT_PROFILE=1 "$SHEN" eval -e '(thread (freeze 1))' > "$dir/thread-profile.out" 2>&1
    contains thread-profile "$dir/thread-profile.out" "shen-jit: profile of"
    # A directory named shen-jit on PATH before the executable is not the executable.
    mkdir -p "$dir/path-a/shen-jit" "$dir/path-b"
    exe="$(cd "$(dirname "$SHEN")" && pwd)/$(basename "$SHEN")"
    ln -s "$exe" "$dir/path-b/shen-jit"
    PATH="$dir/path-a:$dir/path-b:$PATH" sh -c 'shen-jit eval -e 42' > "$dir/path.out" 2>&1
    check path-skips-directories "$dir/path.out" "42"
fi

# = on terms deeper than the C stack: heads, absvector elements, and a difference at the bottom. Too slow when
# every thousand words collect.
if [ -z "$SHEN_JIT_GC_STRESS" ]; then
cat > "$dir/deep.shen" <<'SHEN'
(define deep-heads 0 Acc -> Acc N Acc -> (deep-heads (- N 1) [Acc]))
(define deep-vectors 0 Acc -> Acc N Acc -> (deep-vectors (- N 1) (let V (absvector 1) (address-> V 0 Acc))))
(define deep-both 0 Acc -> Acc N Acc -> (deep-both (- N 1) [Acc (let V (absvector 1) (address-> V 0 Acc))]))
(output "heads ~S ~S~%" (= (deep-heads 300000 x) (deep-heads 300000 x)) (= (deep-heads 300000 x) (deep-heads 300000 y)))
(output "vectors ~S ~S~%" (= (deep-vectors 300000 x) (deep-vectors 300000 x)) (= (deep-vectors 300000 x) (deep-vectors 300000 y)))
(output "both ~S ~S~%" (= (deep-both 16 x) (deep-both 16 x)) (= (deep-both 16 x) (deep-both 16 y)))
(define deep-wide 0 Leaf -> [] N Leaf -> [(deep-heads 1000 Leaf) | (deep-wide (- N 1) Leaf)])
(output "wide ~S ~S~%" (= (deep-wide 300 x) (deep-wide 300 x)) (= (deep-wide 300 x) (deep-wide 300 y)))
SHEN
"$SHEN" eval -l "$dir/deep.shen" 2>&1 > "$dir/deep.out"
check deep-equal-heads "$dir/deep.out" "heads true false"
check deep-equal-vectors "$dir/deep.out" "vectors true false"
check deep-equal-both "$dir/deep.out" "both true false"
check deep-equal-wide "$dir/deep.out" "wide true false"
fi

echo "cli tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
