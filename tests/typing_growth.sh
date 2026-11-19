#!/bin/sh
# Exercise declaration lookup and ambiguous option literals under the default inference limit.
set -eu
shen=$1
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
if command -v cygpath >/dev/null; then dir=$(cygpath -m "$dir"); fi

for n in 1 100 1000; do
    awk -v n="$n" 'BEGIN {
        for (i = 1; i <= n; i++) print "(define typing-test.id" i " {number --> number} X -> X)"
    }' > "$dir/identities.shen"
    "$shen" eval -m http/listener -e '(tc +)' -e '(set shen.*infs* 0)' -l "$dir/identities.shen" > "$dir/out" 2>&1 ||
        { tail -16 "$dir/out"; exit 1; }
    awk -v max="$((400 * n))" '/^typechecked in .* inferences$/ { count=$3 }
        END { if (count == 0 || count >= max) { print "unexpected declaration inferences", count; exit 1 } }' "$dir/out"
done

"$shen" eval -m json -e '(tc +)' -e '(set shen.*infs* 0)' -l tests/option_typed.shen > "$dir/out" 2>&1 ||
    { tail -16 "$dir/out"; exit 1; }
grep -qx '3 passed, 0 failed' "$dir/out"
awk '/^typechecked in .* inferences$/ { count=$3 }
    END { if (count == 0 || count >= 30000) { print "unexpected option inferences", count; exit 1 } }' "$dir/out"

# A rejected chain should reach its type error without retrying constructors
# for every earlier binding. Check ordinary, empty and nullary members.
check_rejected_chain() {
    payload=$1
    steps=$2
    ceiling=$3
    shift 3
    awk -v payload="$payload" -v steps="$steps" 'BEGIN {
        print "(define typing-test.rejected {--> (result.t (string * number))}"
        print "  -> (result.let-ok"
        for (i = 1; i <= steps; i++) print "       Value" i " (:result.ok " payload ")"
        print "       (result.ok \"wrong\")))"
    }' > "$dir/rejected.shen"
    "$shen" eval "$@" -e '(tc +)' -e '(set shen.*infs* 0)' \
        -e "(trap-error (load \"$dir/rejected.shen\")
               (/. E (output \"~A~%rejected inferences ~A~%\" (error-to-string E) (inferences))))" \
        > "$dir/out" 2>&1 || { tail -16 "$dir/out"; exit 1; }
    grep -q '^type error in rule 1 of typing-test.rejected' "$dir/out" ||
        { tail -16 "$dir/out"; exit 1; }
    awk -v max="$ceiling" '/^rejected inferences / { count=$3 }
        END { if (count == 0 || count >= max) { print "unexpected rejection inferences", count; exit 1 } }' "$dir/out"
}

check_rejected_chain 1 20 100000 -m result -m numbers
check_rejected_chain 1.5 20 100000 -m result -m numbers
check_rejected_chain 1 20 120000 -m http/server
check_rejected_chain '[]' 14 120000 -m http/server
check_rejected_chain '(:process.running)' 20 150000 -m process
check_rejected_chain null 12 100000 -m json

check_rejected_chain '[[chunk-size 8]]' 20 100000 -m process/io
check_rejected_chain inherit 20 150000 -m process

# A producer supplies the option type before the result chain binds it.
check_setting_chain() {
    kind=$1
    setting=$2
    shift 2
    awk -v kind="$kind" -v setting="$setting" 'BEGIN {
        result = "(result.t (string * (list " kind ")))"
        print "(define typing-test.setting {--> " kind "} -> " setting ")"
        print "(define typing-test.settings {--> " result "}"
        print "  -> (result.let-ok"
        for (i = 1; i <= 20; i++) print "       Value" i " (:result.ok (typing-test.setting))"
        printf "       (result.ok ["
        for (i = 1; i <= 20; i++) printf "%sValue%d", (i == 1 ? "" : " "), i
        print "])))"
        print "(define typing-test.count {" result " --> number}"
        print "  (:result.ok Values) -> (length Values)"
        print "  (:result.err _) -> 0)"
        print "(output \"setting count ~A~%\" (typing-test.count (typing-test.settings)))"
    }' > "$dir/settings.shen"
    "$shen" eval "$@" -e '(tc +)' -e '(set shen.*infs* 0)' -l "$dir/settings.shen" > "$dir/out" 2>&1 ||
        { tail -16 "$dir/out"; exit 1; }
    grep -qx 'setting count 20' "$dir/out"
    awk '/^typechecked in .* inferences$/ { count=$3 }
        END { if (count == 0 || count >= 50000) { print "unexpected setting inferences", count; exit 1 } }' "$dir/out"
}

check_setting_chain io.buffer-options '[[chunk-size 8]]' -m process/io
check_setting_chain process.stream inherit -m process

echo "typing growth checks passed"
