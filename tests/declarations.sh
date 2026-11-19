#!/bin/sh
# Check prior-type warnings with user-defined typing rules.
set -eu
shen=$1
work=$(mktemp -d)
trap 'status=$?; if [ "$status" -ne 0 ]; then cat "$work"/out; fi; rm -rf "$work"' EXIT
if command -v cygpath > /dev/null; then work=$(cygpath -m "$work"); fi

"$shen" eval -l tests/declarations.shen > "$work/out" 2>&1
grep -qx 'declaration checks passed' "$work/out"
awk '/^warning: changing the type of / { print $6 }' "$work/out" > "$work/warnings"
printf '%s\n' decl.target decl.visible decl.also-visible | diff - "$work/warnings"

# Ordinary application can type the bare operator fn, then its argument as
# a symbol. No rule in this scope names the function being declared.
"$shen" eval -e '(define decl.indirect X -> X)' \
    -e '(datatype decl.operator ____ fn : (symbol --> (number --> number));)' \
    -e '(declare decl.indirect [string --> string])' > "$work/out" 2>&1
grep -qx 'warning: changing the type of decl.indirect may create errors' "$work/out"

# If a second widening consumes the type reached from symbol, its result
# can give bare fn an arrow type (B unifies with --> in the kernel query).
"$shen" eval -e '(define decl.chained X -> X)' \
    -e '(datatype decl.calls X : symbol; ____ X : decl.op;
                             X : decl.op; ____ X : (symbol B (number --> number));)' \
    -e '(declare decl.chained [string --> string])' > "$work/out" 2>&1
grep -qx 'warning: changing the type of decl.chained may create errors' "$work/out"

# A cycle has no base proof, but the kernel can exhaust its inference budget.
"$shen" eval -e '(define decl.cyclic X -> X)' \
    -e '(datatype decl.cycle X : decl.a; ____ X : decl.b; X : decl.b; ____ X : decl.a;)' \
    -e '(maxinferences 2000)' \
    -e '(trap-error (declare decl.cyclic [string --> string]) (/. E (output "~A~%" (error-to-string E))))' \
    > "$work/out" 2>&1
grep -qx 'maximum inferences exceeded' "$work/out"

# The parsed guard excludes fn, but a macro can change the predicate actually installed.
"$shen" eval -e '(define decl.macro-target X -> X)' \
    -e '(defmacro decl.rewrite [when [number? X] | Rest] -> [when true | Rest])' \
    -e '(datatype decl.rewritten if (number? X) ____ X : number;)' \
    -e '(undefmacro decl.rewrite)' -e '(declare decl.macro-target [string --> string])' > "$work/out" 2>&1
grep -qx 'warning: changing the type of decl.macro-target may create errors' "$work/out"
