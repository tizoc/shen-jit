#!/bin/sh
# smt and refine (lib/smt.shen, lib/refine.shen): the checks, typed clients, generated formulas and
# functions, a namespace, and typed and closed programs, whose code must be what it would be without
# conditions. Usage: tests/smt.sh path/to/shen-jit [path/to/shen-jit-stlib]
set -eu
SHEN=$1
SHEN_JIT_MAX_HEAP=512M # a bug that never ends must end
export SHEN_JIT_MAX_HEAP
dir=$(mktemp -d)
trap 'smt_status=$?; if [ "$smt_status" -ne 0 ]; then cat "$dir"/*.out 2>/dev/null; fi; rm -rf "$dir"' EXIT
if command -v cygpath > /dev/null; then dir=$(cygpath -m "$dir"); fi
passed=0

# The standard library defines some of the modules' names.
for shen in "$SHEN" ${2:+"$2"}; do
    "$shen" eval -m smt -l tests/smt-generate.shen -l tests/smt.shen > "$dir/smt.out" 2>&1
    grep -a '^FAIL \|^[0-9]* passed' "$dir/smt.out" | awk '{ print } END { exit !/ 0 failed/ }'
    "$shen" eval -m buffer/contracts -l tests/smt-generate.shen -l tests/refine.shen > "$dir/refine.out" 2>&1
    grep -a '^FAIL \|^[0-9]* passed' "$dir/refine.out" | awk '{ print } END { exit !/ 0 failed/ }'
done

"$SHEN" eval -m smt -e '(tc +)' -l tests/smt_typed.shen -e '(tc -)' -e '(output "~A~%" (smt-typed.main))' > "$dir/smt-typed.out" 2>&1
grep -qxF 'x 0, y 0, p1 false / true true true unsat' "$dir/smt-typed.out"

line='804 25187 -1 104 true false 104 99 101 100 103 6 0 5 1 3 3 4 0 9 262 8 100 9 99 0 (@p 2 7) 5 10 0'
for shen in "$SHEN" ${2:+"$2"}; do
    "$shen" eval -m refine -e '(define pair-up A B -> (@p A B))' -e '(tc +)' -l tests/refine_typed.shen \
        -e '(tc -)' -e '(output "~A~%" (refine-typed.main (shen-jit.string->bytes "abcdefgh")))' > "$dir/refine-typed.out" 2>&1
    grep -qxF "$line" "$dir/refine-typed.out"
done

for shen in "$SHEN" ${2:+"$2"}; do
    "$shen" eval -m refine -e '(tc +)' -l tests/refine_data.shen -e '(tc -)' -e '(output "~A~%" (refine-data.main))' > "$dir/refine-data.out" 2>&1
    grep -qxF '3 6 1 2 0 5 4 [1 2] 0 7 1 0.5 1 0 3 2 9 ok true false 8 2 2 2 11 7 2 3 [4 4 5] 2 4 2 1 true true false 0' "$dir/refine-data.out"
done

"$SHEN" eval -m refine -m buffer -e '(tc +)' -l tests/refine_bytes.shen -e '(tc -)' -e '(output "~A~%" (refine-bytes.main))' > "$dir/refine-bytes.out" 2>&1
grep -qxF 'true false 2569 2 185207048 185207048 62 2 15 168297988 -123 -16 0 9 3 0 3 4 63 0 0 5 2 0 1 3 -1234 62 65295 4294967295' "$dir/refine-bytes.out"

"$SHEN" eval -m buffer/contracts -e '(tc +)' -l tests/refine_contracts.shen -e '(tc -)' -e '(output "~A~%" (refine-contracts.main))' > "$dir/refine-contracts.out" 2>&1
grep -qxF '98 -1 99 100 104 1734900351 4 true 6 1 2 9 0 4 1 4 4 3773727229' "$dir/refine-contracts.out"

# The documentation's example, and the same with one thing wrong: each a length, a test or a step.
"$SHEN" eval -m refine -e '(tc +)' -l tests/refine_records.shen -e '(tc -)' \
    -e '(output "~A ~A~%" (records (shen-jit.string->bytes (@s (n->string 7) (n->string 2) "ab" (n->string 9) (n->string 0)))) (trap-error (records (shen-jit.string->bytes (@s (n->string 7) (n->string 9) "ab"))) (/. E (error-to-string E))))' \
    > "$dir/records.out" 2>&1
grep -qxF '2 the record at 0 is cut short' "$dir/records.out"
for change in 's/(fx> (fx+ I 2) (shen-jit/(fx> (fx+ I 1) (shen-jit/' 's/(fx> (fx+ I N) (shen-jit/(fx> N (shen-jit/' \
    's/(fx= N -1)$/(fx= N 0)/' 's/(fx+ 2 (byte-at/(fx+ 1 (byte-at/'; do
    sed "$change" tests/refine_records.shen > "$dir/broken.shen"
    if cmp -s tests/refine_records.shen "$dir/broken.shen"; then echo "no change: $change"; exit 1; fi
    if "$SHEN" eval -m refine -e '(tc +)' -l "$dir/broken.shen" > "$dir/broken.out" 2>&1; then echo "accepted: $change"; exit 1; fi
    grep -q 'type error in .* may not be so' "$dir/broken.out"
done

# The documentation's other examples, each also with something wrong, whose error is what it says or ends what it quotes.
awk '/^## /{on = /^## Examples$/} on && /^```/{kind = (kind == "") ? substr($0, 4) : ""; next} kind == "shen"' docs/refine.md > "$dir/examples.shen"
awk '/^## /{on = /^## Examples$/} on && /^```/{kind = (kind == "") ? substr($0, 4) : ""; if (kind == "") print ""; next} kind == "text" {printf "%s ", $0}' docs/refine.md | sed -e 's/ $//' -e '/^$/d' > "$dir/said"
"$SHEN" eval -m refine -e '(tc +)' -l "$dir/examples.shen" -e '(tc -)' \
    -e '(define said-by F -> (trap-error (thaw F) (/. E (error-to-string E))))' \
    -e '(output "~A ~A ~S ~A ~S ~A ~S ~A ~A ~A ~A~%" (index-of (shen-jit.string->bytes (@s (n->string 0) (n->string 3) (n->string 1) (n->string 4))) 260) (index-of (shen-jit.string->bytes "") 1) (read-date 2024 2 29) (said-by (freeze (read-date 2023 2 29))) (pay (account.make ann 10) (account.make bob 5) 7) (said-by (freeze (day 2023 4 31))) (greet) (summary []) (summary [1 2 6]) (cell (new-grid 3 2) 2 1) (said-by (freeze (cell (new-grid 3 2) 3 0))))' \
    > "$dir/examples.out" 2>&1
grep -qxF '1 -1 #<date year: 2024 month: 2 day: 29> there is no 2023-2-29 (@p #<account owner: ann balance: 3> #<account owner: bob balance: 12>) day: not so: (fx<= D (days-in Y M)) #<link state: down sent: 7> nothing 3 0 cell: not so: (fx< X (grid.width G))' "$dir/examples.out"
for change in 's/0 (fxquotient (shen-jit.bytes-length Table) 2)/0 (shen-jit.bytes-length Table)/' '/^(refine.pure days-in)$/d' \
    's/(if (and (fx<= 0 N) (fx<= N (account.balance A)))/(if (fx<= N (account.balance A))/' 's/(close-link (send L 2))/(send (close-link L) 2)/' \
    's/^  \[\] -> "nothing"$//' 's/(day Y M D)$/(day Y D M)/' 's/(@p (withdraw A N) (deposit B N))/(@p (withdraw A N) B)/' \
    's/(fxquotient (fx+ Low High) 2)/(fxquotient (fx+ Low (fx+ High 1)) 2)/' 's/(fx<= 1 D) (fx<= D (days-in Y M)))$/(fx<= D 31))/' \
    's/(fx\* Y (grid.width G))/(fx* Y (grid.height G))/'; do
    sed "$change" "$dir/examples.shen" > "$dir/broken.shen"
    if cmp -s "$dir/examples.shen" "$dir/broken.shen"; then echo "no change: $change"; exit 1; fi
    if "$SHEN" eval -m refine -e '(tc +)' -l "$dir/broken.shen" > "$dir/broken.out" 2>&1; then echo "accepted: $change"; exit 1; fi
    sed -n 's/^.*uncaught error: //p' "$dir/broken.out" >> "$dir/errors"
done
test "$(wc -l < "$dir/errors")" -eq 10
test "$(wc -l < "$dir/said")" -eq 6
while read -r error; do grep -qxF "$error" "$dir/errors" || { echo "not said: $error"; exit 1; }; done < "$dir/said"
test "$(grep -c 'may not be so' "$dir/errors")" -eq 10

# An error says where it is, its rule too if refine makes the rules, and who needs or promises what.
says() {
    printf '%s\n%s\n' '(define-checked at {I : fixnum --> fixnum} {requires (fx< I 99) (fx<= 0 I)} I -> I)' "$2" > "$dir/says.shen"
    if "$SHEN" eval -m refine -e '(tc +)' -l "$dir/says.shen" > "$dir/says.out" 2>&1; then echo "accepted: $2"; exit 1; fi
    grep -q "type error in $1, which may not be so, as if X is -1\$" "$dir/says.out" || { cat "$dir/says.out"; exit 1; }
}
says 'rule 1 of two: at needs (fx<= 0 X)' '(define two {fixnum --> fixnum} X -> (fx+ 1 (at X)) where (fx< X 9))'
says 'rule 2 of two: at needs (fx<= 0 X)' '(define-checked two {fixnum --> fixnum} X <- 1 where (fx> X 3) X -> (fx+ 1 (at X)) where (fx< X 9))'
says 'rule 3 of two: at needs (fx<= 0 X)' '(define-checked two {fixnum --> fixnum} 5 -> 0 6 -> 0 X -> 1 where (and (fx< X 9) (fx= 2 (at X))) _ -> 0)'
says 'rule 2 of two: two promises (fx<= 0 X)' '(define-checked two {fixnum --> R : fixnum} {ensures (fx<= 0 R)} 5 -> 0 X -> X)'
says 'rule 1 of two: two promises (fx<= 0 X)' '(define-checked two {X : fixnum --> fixnum} {ensures (fx<= 0 X)} X -> (let X 0 1))'
# A define knows its ifs, lets and earlier clauses too.
for body in 'X -> (if (fx< X 0) 0 (at X))' 'X -> 0 where (fx< X 0) X -> (at X)' 'X -> (let Y (fx- X X) (at Y))' 'X -> (do (at (fx- X X)) (at 1))'; do
    printf '%s\n%s\n' '(define-checked at {I : fixnum --> fixnum} {requires (fx<= 0 I)} I -> I)' "(define two {fixnum --> fixnum} $body)" > "$dir/says.shen"
    "$SHEN" eval -m refine -e '(tc +)' -l "$dir/says.shen" > "$dir/says.out" 2>&1
done

# However many calls have a condition that a promise names.
awk 'BEGIN { print "(define-checked in? {I : fixnum --> N : fixnum --> R : boolean} {ensures (= R (and (fx<= 0 I) (fx< I N)))} I N -> (and (fx<= 0 I) (fx< I N)))"
             print "(define-checked at {I : fixnum --> fixnum} {requires (in? I 9)} I -> I)"
             print "(define many {fixnum --> fixnum} X -> (if (in? X 9) (do"
             for (i = 0; i < 120; i++) print "(at X)"
             print ") 0))" }' > "$dir/many.shen"
"$SHEN" eval -m refine -e '(tc +)' -l "$dir/many.shen" > "$dir/many.out" 2>&1

# What loading each case of a fixture says, after its own definitions: an error, which is the kernel's and ends its line
# if it needs nothing, or that it loads. A condition that was wrongly proved is not tested.
cases() {
    rm -f "$dir"/case* "$dir/cases.expected"
    awk -v dir="$dir" 'function another() { close(dir "/case" n ".shen"); n++ }
        BEGIN { n = 0 }
        /^\\\\ says / { another(); print substr($0, 9) (/ type error/ && !/ needs | promises / ? "" : ".") > (dir "/cases.expected"); next }
        /^\\\\ untyped says / { another(); print substr($0, 17) "." > (dir "/cases.expected"); print > (dir "/case" n ".untyped"); next }
        /^\\\\ loads/ { another(); print "loads." > (dir "/cases.expected"); if (/untyped/) print > (dir "/case" n ".untyped"); next }
        { print > (dir "/case" n ".shen") }' "$1"
    # They are in a file, as there are more than a command line can have on Windows.
    n=1
    while [ -f "$dir/case$n.shen" ]; do
        if [ ! -f "$dir/case$n.untyped" ]; then echo '(tc +)'; fi
        printf '(trap-error (do (load "%s") (do (output "says loads.~%%") loaded)) (/. E (do (output "says ~A.~%%" (error-to-string E)) loaded)))\n' "$dir/case$n.shen"
        echo '(tc -)'
        n=$((n + 1))
    done > "$dir/cases.shen"
    "$SHEN" eval -m refine -e '(maxinferences 100000000)' -e '(refine.test -)' -e '(tc +)' -l "$dir/case0.shen" -e '(tc -)' -l "$dir/cases.shen" > "$dir/cases.out" 2>&1
    sed -n 's/^says //p' "$dir/cases.out" > "$dir/cases.got"
    diff "$dir/cases.expected" "$dir/cases.got" || exit 1
}

# A type error for want of a proof that a term is of a refined type says which, and no other does.
cases tests/refine_errors.shen
# A contract is as its function was last defined.
cases tests/refine_redefined.shen
# And what a file that is loaded from another defines is as that has it.
printf '(define-checked inner {X : fixnum --> R : fixnum} {ensures (fx= R 2)} X -> 2)\n' > "$dir/inner.shen"
for n in 1 2; do
    printf '(define-checked at {X : fixnum --> fixnum} {requires (fx= X %s)} X -> X)\n(define-checked inner {X : fixnum --> R : fixnum} {ensures (fx= R 1)} X -> 1)\n(load "%s/inner.shen")\n(define uses {fixnum --> fixnum} X -> (at (inner X)))\n' $n "$dir" > "$dir/outer$n.shen"
done
printf '(refine.type five N where (fx= N 5))\n(defstruct fives (it : five))\n' > "$dir/fives.shen"
printf '(load "%s/fives.shen")\n(define maker {--> (fixnum --> fives)} -> (fn fives.make))\n' "$dir" > "$dir/outer3.shen"
if "$SHEN" eval -m refine -e '(tc +)' -l "$dir/outer3.shen" > "$dir/nested.out" 2>&1; then echo "accepted: a constructor as a value"; exit 1; fi
grep -q 'refine: fives.make does not test' "$dir/nested.out"
if "$SHEN" eval -m refine -e '(tc +)' -l "$dir/outer1.shen" > "$dir/nested.out" 2>&1; then echo "accepted: a nested load"; exit 1; fi
grep -q 'type error in rule 1 of uses: at needs (fx= 2 1)' "$dir/nested.out"
"$SHEN" eval -m refine -e '(tc +)' -l "$dir/outer2.shen" > "$dir/nested.out" 2>&1
# A file that a side condition loads leaves what is known of the one being checked as it was.
printf '(define helper {fixnum --> fixnum} X -> X)\n' > "$dir/helper.shen"
printf '(refine.type above N where (fx> N 0))\n(datatype loads-helper\n  if (do (load "%s/helper.shen") true)\n  ___\n  needs-helper : helped;)\n(define use-helped {helped --> fixnum} _ -> 1)\n(define mk {fixnum --> acc} N -> (do (use-helped needs-helper) (acc.make N)))\n(defstruct acc (bal : above))\n' "$dir" > "$dir/outer4.shen"
if "$SHEN" eval -m refine -e '(tc +)' -l "$dir/outer4.shen" > "$dir/nested.out" 2>&1; then echo "accepted: a load in a side condition"; exit 1; fi
grep -q 'type error in rule 1 of mk: acc.make needs (fx> N 0)' "$dir/nested.out"
# What input+ reads is checked as any typed expression is.
printf '(account.make a -5)\n' > "$dir/account.data"
printf '(refine.type money N where (fx<= 0 N))\n(defstruct account (owner : symbol) (balance : money))\n(define from-file {string --> account} File -> (input+ account (open File in)))\n' > "$dir/input.shen"
"$SHEN" eval -m refine -e '(tc +)' -l "$dir/input.shen" -e "(output \"~A~%\" (trap-error (from-file \"$dir/account.data\") (/. E (error-to-string E))))" > "$dir/input.out" 2>&1
grep -q '^type error: account.make needs (fx<= 0 -5)' "$dir/input.out"
# Nor is what is known of a function by its name known of another in its place: a struct's, a layout's or a library's.
printf '(define ends.low {ends --> fixnum} S -> (fx+ 1 (ends.high S)))\n' > "$dir/inner.shen"
printf '(define-checked at {X : fixnum --> fixnum} {requires (fx= X 9)} X -> X)\n(defstruct ends (low : fixnum) (high : fixnum))\n(load "%s/inner.shen")\n(define-checked uses {--> fixnum} -> (at (ends.low (ends.make 9 7))))\n' "$dir" > "$dir/outer.shen"
printf '(deflayout lay (tag 8) (length 16))\n(define lay.size {--> fixnum} -> 5)\n' > "$dir/layout1.shen"
printf '(define-checked uses {--> R : fixnum} {ensures (fx= R 3)} -> (lay.size))\n' > "$dir/layout2.shen"
printf '(define buffer.length {buffer.view --> fixnum} V -> (fx- 0 1))\n' > "$dir/library1.shen"
printf '(define-checked buffer.length {buffer.view --> fixnum} V -> (fx- 0 1))\n' > "$dir/library3.shen"
printf '(define-checked from-0 {N : fixnum --> fixnum} {requires (fx<= 0 N)} N -> N)\n(define uses {buffer.view --> fixnum} V -> (from-0 (buffer.length V)))\n' > "$dir/library2.shen"
printf '(deflayout lay (tag 8) (length 16))\n' > "$dir/layout3.shen"
printf '(define-checked from-0 {N : fixnum --> fixnum} {requires (fx<= 0 N)} N -> N)\n(define lay.tag {fixnum --> fixnum} N -> (from-0 N))\n' > "$dir/layout4.shen"
printf '(define buffer.length V -> -1)\n' > "$dir/untyped.shen"
printf '(let A (tc -) B (load "untyped.shen") (tc +))\n' > "$dir/library4.shen"
printf '(eval-kl [defun buffer.length [(protect V)] -1])\n(update-lambda-table buffer.length 1)\n(declare buffer.length [number --> fixnum])\n' > "$dir/bare.shen"
printf '(let A (tc -) B (load "bare.shen") (tc +))\n' > "$dir/library5.shen"
printf '(define-checked from-0 {N : fixnum --> fixnum} {requires (fx<= 0 N)} N -> N)\n(define uses {number --> fixnum} V -> (from-0 (buffer.length V)))\n' > "$dir/library6.shen"
for n in '-l outer.shen' '-m layout -l layout1.shen -l layout2.shen' '-m layout -l layout3.shen -l layout4.shen' \
    '-m buffer -l library1.shen -l library2.shen' '-m buffer -l library3.shen -l library2.shen' '-m buffer -l library4.shen -l library2.shen' \
    '-l library5.shen -l library6.shen'; do
    if (cd "$dir" && "$SHEN" eval -m refine $(echo "$n" | sed 's/ -l.*//; s/^-l.*//') -e '(tc +)' $(echo "$n" | sed 's/^-m [a-z]* //')) > "$dir/names.out" 2>&1; then echo "accepted: $n"; exit 1; fi
    grep -q 'type error in rule 1 of \(uses\|lay.tag\): .*, which may not be so' "$dir/names.out"
done
# A condition that was proved is tested too, as what was proved may no longer be so, until that is not asked for.
printf '(define-checked at-1 {X : fixnum --> fixnum} {requires (fx= X 1)} X -> X)\n(define-checked one {--> R : fixnum} {ensures (fx= R 1)} -> 1)\n' > "$dir/one.shen"
for n in before during after; do printf '(define %s {--> fixnum} -> (at-1 (one)))\n' $n > "$dir/$n.shen"; done
printf '(refine.test +)\n' > "$dir/on.shen"
printf '(refine.test -)\n' > "$dir/off.shen"
"$SHEN" eval -m refine -e '(tc +)' -l "$dir/off.shen" -l "$dir/one.shen" -l "$dir/on.shen" -l "$dir/before.shen" -l "$dir/off.shen" -l "$dir/off.shen" -l "$dir/during.shen" -l "$dir/on.shen" -l "$dir/after.shen" \
    -e '(tc -)' -e '(define one -> 2)' -e '(define try F -> (trap-error (thaw F) (/. E (error-to-string E))))' \
    -e '(output "~A, ~A, ~A, ~A~%" (try (freeze (before))) (during) (try (freeze (after))) (try (freeze (refine.test yes))))' > "$dir/tested.out" 2>&1
grep -qxF 'at-1: not so: (fx= X 1), 2, at-1: not so: (fx= X 1), refine.test expects a + or a -' "$dir/tested.out"
# A function that tests when it is defined has no body to go to.
"$SHEN" eval -m refine -e '(tc +)' -l "$dir/one.shen" -l "$dir/off.shen" -l "$dir/during.shen" -e '(tc -)' -e '(define one -> 2)' \
    -e '(output "~A~%" (trap-error (during) (/. E (error-to-string E))))' > "$dir/tested.out" 2>&1
grep -qx 'at-1: not so: (fx= X 1)' "$dir/tested.out"
# What was proved of a contract calls a definition of it under (tc -), which tests it.
for n in 1 2; do printf '(define-checked f {X : fixnum --> fixnum} {requires (fx> X 0)} X -> %s)\n' $n > "$dir/f$n.shen"; done
for n in g h; do printf '(define %s {fixnum --> fixnum} X -> (f 5))\n' $n > "$dir/$n.shen"; done
"$SHEN" eval -m refine -e '(refine.test -)' -e '(tc +)' -l "$dir/f1.shen" -l "$dir/g.shen" -e '(tc -)' -l "$dir/f2.shen" -e '(tc +)' -l "$dir/h.shen" \
    -e '(output "~A ~A~%" (g 1) (h 1))' > "$dir/tested.out" 2>&1
grep -qx '2 2' "$dir/tested.out"
# A condition with a function given some of its arguments, or more than it takes, is tested as the reader makes it.
printf '(define all? {(A --> boolean) --> (list A) --> boolean} _ [] -> true F [X | Xs] -> (and (F X) (all? F Xs)))\n(refine.pure all?)\n' > "$dir/partial.shen"
printf '(define adder {fixnum --> (fixnum --> fixnum)} X -> (/. Y (fx+ X Y)))\n(define-checked over-3 {Ns : (list number) --> number} {requires (all? (< 3) Ns)} Ns -> (length Ns))\n' >> "$dir/partial.shen"
printf '(define-checked added {X : fixnum --> fixnum} {requires (fx> (adder X 1) 0)} X -> X)\n' >> "$dir/partial.shen"
"$SHEN" eval -m refine -e '(tc +)' -l "$dir/partial.shen" -e '(output "~A ~A~%" (over-3 [4 5]) (added 5))' > "$dir/tested.out" 2>&1
grep -qx '2 5' "$dir/tested.out"
# A module asks for itself, and not for one that requires it, nor for a file.
printf '(shen.module (version 1) (name untested) (requires refine) (sources tc- "test.shen" tc+ "one.shen" "during.shen"))\n' > "$dir/untested.shenmod"
printf '(shen.module (version 1) (name tested) (requires refine untested) (sources tc+ "before.shen"))\n' > "$dir/tested.shenmod"
printf '(shen.x.namespace untested (use refine => r) (r.test -))\n' > "$dir/test.shen"
"$SHEN" eval -m "$dir/untested.shenmod" -m "$dir/tested.shenmod" -e '(tc +)' -l "$dir/after.shen" -e '(tc -)' \
    -e '(define one -> 2)' -e '(define try F -> (trap-error (thaw F) (/. E (error-to-string E))))' \
    -e '(output "~A, ~A, ~A~%" (try (freeze (before))) (during) (try (freeze (after))))' > "$dir/tested.out" 2>&1
grep -qxF 'at-1: not so: (fx= X 1), 2, at-1: not so: (fx= X 1)' "$dir/tested.out"
printf '(shen.module (version 1) (name asked) (requires refine) (sources tc- "asked.shen"))\n' > "$dir/asked.shenmod"
printf '(shen.x.namespace asked (use refine => r) (r.test +))\n' > "$dir/asked.shen"
"$SHEN" eval -m refine -e '(tc +)' -l "$dir/off.shen" -l "$dir/one.shen" -m "$dir/asked.shenmod" -l "$dir/during.shen" -e '(tc -)' -e '(define one -> 2)' -e '(output "~A~%" (during))' > "$dir/tested.out" 2>&1
grep -qx 2 "$dir/tested.out"
# What a rule types without looking inside is asked for all the same.
printf '(datatype any\n  _______\n  X : any;)\n' > "$dir/any.shen"
printf '(define-checked promises {X : fixnum --> R : any} {ensures (fx= X 0)} X -> X)\n' > "$dir/any1.shen"
printf '(define-checked from-0 {N : fixnum --> fixnum} {requires (fx<= 0 N)} N -> N)\n(define uses {fixnum --> any} N -> (from-0 N))\n' > "$dir/any2.shen"
for n in '1 promises: promises promises (fx= X 0)' '2 uses: from-0 needs (fx<= 0 N)'; do
    if "$SHEN" eval -e '(tc +)' -l "$dir/any.shen" -e '(tc -)' -m refine -e '(tc +)' -l "$dir/any${n%% *}.shen" > "$dir/any.out" 2>&1; then echo "accepted: $n"; exit 1; fi
    grep -q "type error in rule 1 of ${n#* }, which may not be so" "$dir/any.out"
done
# A product of unknowns is as its factors are ordered.
cases tests/refine_products.shen
# What an independent review found to be believed, refused or never answered, and should not be.
cases tests/refine_sound.shen

# Functions that load never break what they proved, nor promise what they do not give.
"$SHEN" eval -m refine -l tests/smt-generate.shen -l tests/refine-generate.shen -e "(refine-generate.run \"$dir\" 5 ${SMT_FUNCTIONS:-500})" \
    -e '(map (/. X (output "BROKEN ~A~%" X)) (value refine-generate.*broken*))' \
    -e '(output "generated: ~A loaded, ~A refused, ~A broken, ~A with a promise~%" (value refine-generate.*loaded*) (value refine-generate.*refused*) (length (value refine-generate.*broken*)) (value refine-generate.*promising*))' \
    > "$dir/generated.out" 2>&1
grep -aq '^generated: [1-9][0-9][0-9]* loaded, [1-9][0-9][0-9]* refused, 0 broken, [1-9][0-9]* with a promise$' "$dir/generated.out"
# The same of lists, symbols, numbers, predicates and calls that are not always made.
"$SHEN" eval -m refine -l tests/smt-generate.shen -l tests/refine-generate.shen -e "(refine-generate.run-data \"$dir\" 13 ${SMT_FUNCTIONS:-250})" \
    -e '(map (/. X (output "BROKEN ~A~%" X)) (value refine-generate.*broken*))' \
    -e '(output "generated: ~A loaded, ~A refused, ~A broken~%" (value refine-generate.*loaded*) (value refine-generate.*refused*) (length (value refine-generate.*broken*)))' \
    > "$dir/generated-data.out" 2>&1
grep -aq '^generated: [1-9][0-9][0-9]* loaded, [1-9][0-9][0-9]* refused, 0 broken$' "$dir/generated-data.out"
# And of shifts, masks, remainders of any sign, products of two, element? and calls in a do.
"$SHEN" eval -m refine -l tests/smt-generate.shen -l tests/refine-generate.shen -e "(refine-generate.run-wide \"$dir\" 13 ${SMT_FUNCTIONS:-250})" \
    -e '(map (/. X (output "BROKEN ~A~%" X)) (value refine-generate.*broken*))' \
    -e '(output "generated: ~A loaded, ~A refused, ~A broken~%" (value refine-generate.*loaded*) (value refine-generate.*refused*) (length (value refine-generate.*broken*)))' \
    > "$dir/generated-wide.out" 2>&1
grep -aq '^generated: [1-9][0-9][0-9]* loaded, [1-9][0-9][0-9]* refused, 0 broken$' "$dir/generated-wide.out"
# And of pairs, structs, lists and functions whose parts are of refined types, and of what changes.
"$SHEN" eval -m refine -l tests/smt-generate.shen -l tests/refine-generate.shen -e "(refine-generate.run-shapes \"$dir\" 5 ${SMT_FUNCTIONS:-600})" \
    -e '(map (/. X (output "BROKEN ~A~%" X)) (value refine-generate.*broken*))' \
    -e '(output "generated: ~A loaded, ~A refused, ~A broken~%" (value refine-generate.*loaded*) (value refine-generate.*refused*) (length (value refine-generate.*broken*)))' \
    > "$dir/generated-shapes.out" 2>&1
grep -aq '^generated: [1-9][0-9][0-9]* loaded, [1-9][0-9][0-9]* refused, 0 broken$' "$dir/generated-shapes.out"
# And of patterns, with wildcards, literals and variables again, and of what tries the next clause.
"$SHEN" eval -m refine -l tests/smt-generate.shen -l tests/refine-generate.shen -e "(refine-generate.run-patterns \"$dir\" 5 ${SMT_FUNCTIONS:-600})" \
    -e '(map (/. X (output "BROKEN ~A~%" X)) (value refine-generate.*broken*))' \
    -e '(output "generated: ~A loaded, ~A refused, ~A broken, ~A with a promise~%" (value refine-generate.*loaded*) (value refine-generate.*refused*) (length (value refine-generate.*broken*)) (value refine-generate.*promising*))' \
    > "$dir/generated-patterns.out" 2>&1
grep -aq '^generated: [1-9][0-9][0-9]* loaded, [1-9][0-9][0-9]* refused, 0 broken, [1-9][0-9]* with a promise$' "$dir/generated-patterns.out"
passed=$((passed + 35))

# Under a namespace's own names, in a typed program, whose loop must be the plain one's.
cat > "$dir/app.shenmod" <<'END'
(shen.module (version 1) (name app) (typed) (requires refine) (main app.main) (sources tc+ "app.shen"))
END
cat > "$dir/app.shen" <<'END'
(shen.x.namespace app
  (use refine => r)
  (use shen-jit)
  (import refine define-checked => checked)
  (externals [buffer.storage])
  (export main add-up plain)

  (r.test -)
  (r.type natural N where (fx<= 0 N))

  (checked byte-at {B : buffer.storage --> I : fixnum --> natural}
    {requires (fx<= 0 I) (fx< I (shen-jit.bytes-length B))}
    B I -> (shen-jit.u8 B I))

  (r.define-checked add-up {B : buffer.storage --> I : fixnum --> N : fixnum --> fixnum --> fixnum}
    {requires (fx<= 0 I) (fx<= N (shen-jit.bytes-length B))}
    _ I N Acc -> Acc where (fx>= I N)
    B I N Acc -> (let J (fx+ I 1) (add-up B J N (fx+ Acc (byte-at B I)))))

  (define plain {buffer.storage --> fixnum --> fixnum --> fixnum --> fixnum}
    _ I N Acc -> Acc where (fx>= I N)
    B I N Acc -> (let J (fx+ I 1) (plain B J N (fx+ Acc (shen-jit.u8 B I)))))

  (r.define-checked main {--> symbol}
    -> (let B (shen-jit.u8! (shen-jit.u8! (shen-jit.bytes 5) 1 30) 4 12)
            N (shen-jit.bytes-length B)
         (do (output "sum ~A ~A~%" (add-up B 0 N 0) (plain B 0 N 0)) done))))
END
cat > "$dir/code.shen" <<'END'
(define instructions
  F -> (mapcan (/. I (if (= (hd I) inline) [] [I])) (hd (tl (tl (tl (tl (tl (hd (tl (tl (shen-jit.code F))))))))))))
(output "same code: ~A~%" (= (instructions (tl (hd (get app.add-up refine.bodies)))) (instructions app.plain)))
END
"$SHEN" eval -m "$dir/app.shenmod" -l "$dir/code.shen" > "$dir/code.out" 2>&1
grep -qxF 'same code: true' "$dir/code.out"
for closed in '' --closed; do
    "$SHEN" build "$dir/app.shenmod" $closed -o "$dir/app.exe" > "$dir/build.out" 2>&1
    "$dir/app.exe" > "$dir/app.out" 2>&1
    grep -qxF 'sum 42 42' "$dir/app.out"
done

# A contract from elsewhere binds the modules that require the one it is in, and no other, whatever was
# loaded before: not those that require these, nor a library. And it leaves what is called as it was.
module() { printf '(shen.module (version 1) (name %s) (requires %s) (sources %s))\n' "$1" "$2" "$3" > "$dir/$1.shenmod"; }
printf '(define %s {buffer.view --> fixnum --> fixnum} V I -> (buffer.u8 V I) where (and (fx<= 0 I) (fx< I (buffer.length V))) _ _ -> 0)\n' scope.proved > "$dir/proved.shen"
printf '(define %s {buffer.view --> fixnum --> fixnum} V I -> (buffer.u8 V I) where (and (fx<= 0 I) (fx< I (buffer.length V))) _ _ -> 0)\n' scope.plain > "$dir/plain.shen"
for n in direct through without; do printf '(define scope.%s {buffer.view --> fixnum --> fixnum} V I -> (buffer.u8 V I))\n' $n > "$dir/$n.shen"; done
printf '(refine.contract (buffer.u8 V I) requires (fx<= 0 I) (fx< I (buffer.length V)))\n' > "$dir/own.shen"
module proved 'buffer/contracts buffer' 'tc+ "proved.shen"'
module plain buffer 'tc+ "plain.shen"'
module through 'buffer proved' 'tc+ "through.shen"'
module without buffer 'tc+ "without.shen"'
module direct 'buffer/contracts buffer' 'tc+ "direct.shen"'
module own 'refine buffer' 'tc- "own.shen" tc+ "direct.shen"'
"$SHEN" eval -m "$dir/proved.shenmod" -m "$dir/through.shenmod" -m "$dir/without.shenmod" -m net/dns -e '(output "loaded~%")' > "$dir/scope.out" 2>&1
grep -qx 'loaded' "$dir/scope.out"
for n in direct own; do
    if "$SHEN" eval -m "$dir/$n.shenmod" > "$dir/scope.out" 2>&1; then echo "accepted: module $n"; exit 1; fi
    grep -q 'type error in rule 1 of scope.direct: buffer.u8 needs (fx<= 0 I)' "$dir/scope.out"
done
if "$SHEN" eval -m buffer/contracts -e '(tc +)' -l "$dir/direct.shen" > "$dir/scope.out" 2>&1; then echo "accepted: a file"; exit 1; fi
"$SHEN" eval -m buffer -m refine -e '(tc +)' -l "$dir/direct.shen" > "$dir/scope.out" 2>&1
# Another module's contract of the same function leaves it, and where both are required both hold, of their own names.
printf '(define scope.raw {buffer.view --> fixnum --> fixnum} V I -> (if (and (fx<= 0 I) (fx< I 9)) (fx+ I 6) 0))\n' > "$dir/raw.shen"
printf '(refine.contract (scope.raw W J) --> S requires (fx< J 9) trusts (fx> S 5))\n' > "$dir/below.shen"
printf '(refine.contract (scope.raw V I) --> R requires (fx<= 0 I) trusts (fx< R 20))\n' > "$dir/above.shen"
printf '(define-checked scope.few {X : fixnum --> fixnum} {requires (fx> X 5) (fx< X 20)} X -> X)\n' > "$dir/few.shen"
for n in both low high; do
    case $n in both) guard='(and (fx<= 0 I) (fx< I 9))';; low) guard='(fx<= 0 I)';; high) guard='(fx< I 9)';; esac
    printf '(define-checked scope.%s {buffer.view --> fixnum --> fixnum} V I -> (if %s (let N (scope.raw V I) (scope.few N)) 0))\n' $n "$guard" > "$dir/$n.shen"
done
module raw buffer 'tc+ "raw.shen"'
module below 'refine raw' 'tc- "below.shen"'
module above 'refine raw' 'tc- "above.shen"'
module both 'refine raw below above buffer' 'tc+ "few.shen" "both.shen"'
module low 'refine raw below above buffer' 'tc+ "few.shen" "low.shen"'
module alone 'refine raw below buffer' 'tc+ "few.shen" "low.shen"'
module high 'refine raw below above buffer' 'tc+ "few.shen" "high.shen"'
"$SHEN" eval -m "$dir/both.shenmod" -e '(output "~A~%" (scope.both (buffer.new 1) 3))' > "$dir/scope.out" 2>&1
grep -qx 9 "$dir/scope.out"
for n in 'low (fx< I 9)' 'high (fx<= 0 I)' 'alone (fx< I 9)'; do
    if "$SHEN" eval -m "$dir/below.shenmod" -m "$dir/above.shenmod" -m "$dir/${n%% *}.shenmod" > "$dir/scope.out" 2>&1; then echo "accepted: module $n"; exit 1; fi
    grep -q "type error in rule 1 of .*: scope.raw needs ${n#* }" "$dir/scope.out"
done
# What a layout makes tests what it is given, and needs no proof.
printf '(deflayout lay (tag 8) (length 16) (rest 24))\n(deflayout bits (low 3) (high 5))\n' > "$dir/lay.shen"
module laid 'buffer/contracts layout buffer' 'tc+ "lay.shen"'
"$SHEN" eval -m "$dir/laid.shenmod" > "$dir/scope.out" 2>&1
sed 's/(tl (hd (get app.add-up refine.bodies)))/scope.proved/; s/app.plain/scope.plain/' "$dir/code.shen" > "$dir/scope-code.shen"
"$SHEN" eval -m "$dir/plain.shenmod" -m "$dir/proved.shenmod" -l "$dir/scope-code.shen" > "$dir/scope.out" 2>&1
grep -qxF 'same code: true' "$dir/scope.out"
# The size of a layout is the number it is, in a namespace or not.
module lay layout 'tc+ "lay.shen"'
cat > "$dir/sized.shen" <<'END'
(define-checked after {V : buffer.view --> I : fixnum --> fixnum} {requires (fx<= 0 I) (fx< I (buffer.length V))} V I -> (buffer.u8 V I))
(define-checked rest {V : buffer.view --> fixnum} {requires (fx> (buffer.length V) (lay.size))} V -> (let N (lay.size) (after V N)))
(define-checked inside {V : buffer.view --> fixnum} {requires (fx>= (buffer.length V) 12)} V -> (after V (fx- (net-wire.dns.size) 1)))
(define-checked seven {--> R : fixnum} {ensures (fx= R 7)} -> (fx+ 1 (lay.size)))
END
cat > "$dir/oversized.shen" <<'END'
(define-checked after {V : buffer.view --> I : fixnum --> fixnum} {requires (fx<= 0 I) (fx< I (buffer.length V))} V I -> (buffer.u8 V I))
(define-checked inside {V : buffer.view --> fixnum} {requires (fx>= (buffer.length V) 12)} V -> (after V (net-wire.dns.size)))
END
"$SHEN" eval -m refine -m "$dir/lay.shenmod" -m net/wire -e '(tc +)' -l "$dir/sized.shen" -e '(tc -)' \
    -e '(output "~A ~A ~A ~A~%" (tl (get lay.size layout.size)) (lay.size) (tl (get net-wire.dns.size layout.size)) (net-wire.dns.size))' > "$dir/sized.out" 2>&1
grep -qxF '6 6 12 12' "$dir/sized.out"
if "$SHEN" eval -m refine -m net/wire -e '(tc +)' -l "$dir/oversized.shen" > "$dir/sized.out" 2>&1; then echo "accepted: past a layout"; exit 1; fi
grep -q 'type error in rule 1 of inside: after needs (fx< 12 (buffer.length V))' "$dir/sized.out"
# In a namespace.
cat > "$dir/ns.shenmod" <<'END'
(shen.module (version 1) (name ns) (requires refine buffer) (sources tc- "ns.shen" tc+ "ns-typed.shen"))
END
cat > "$dir/ns.shen" <<'END'
(shen.x.namespace ns (use refine => r) (use buffer)
  (r.contract (buffer.u8 V I) --> R requires (fx<= 0 I) (fx< I (buffer.length V)) trusts (fx<= 0 R)))
END
cp "$dir/direct.shen" "$dir/ns-typed.shen"
if "$SHEN" eval -m "$dir/ns.shenmod" > "$dir/scope.out" 2>&1; then echo "accepted: a namespace"; exit 1; fi
grep -q 'type error in rule 1 of scope.direct: buffer.u8 needs (fx<= 0 I)' "$dir/scope.out"
echo "$((passed + 18)) passed, 0 failed"
