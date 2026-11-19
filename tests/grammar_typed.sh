#!/bin/sh
# Typed grammars refuse what does not typecheck, and say where; their rules read from a reader.
set -eu
SHEN=$1
dir=$(mktemp -d)
trap 'grammar_typed_status=$?; rm -rf "$dir"; exit $grammar_typed_status' EXIT
if command -v cygpath > /dev/null; then dir=$(cygpath -m "$dir"); fi

cat > "$dir/base.shen" <<'EOF'
(defgrammar <bad.digit> {==> fixnum} B := (fx- B 48) where (and (fx>= B 48) (fx<= B 57));)
(defgrammar <bad.letter> B where (and (>= B 97) (<= B 122));)
(defgrammar <bad.letters> (+ <bad.letter>);)
(defgrammar <bad.any> B := B;)
(defgrammar <bad.word> {==> string} (text <bad.letters>) := <bad.letters>;)
(defgrammar (<bad.times> Byte N) {fixnum --> fixnum ==> fixnum} (at P) := (fx+ P N);)
(define bad.fail {fixnum --> string --> A} At Message -> (error "~A at ~A" Message At))
EOF

passed=0
refused() {
  printf '%s\n' "$2" | cat "$dir/base.shen" - > "$dir/case.shen"
  if "$SHEN" eval -m grammar -e '(tc +)' -l "$dir/case.shen" > "$dir/case.out" 2>&1; then
    echo "FAIL accepted: $2"
    exit 1
  fi
  if ! grep -qF "$1" "$dir/case.out"; then
    echo "FAIL wanted '$1' for: $2"
    tail -3 "$dir/case.out"
    exit 1
  fi
  passed=$((passed + 1))
}

refused 'type error in rule 2 of <bad.x>.types' '(defgrammar <bad.x> {==> number} "a" := 1; B := "b";)'
refused 'type error in rule 1 of <bad.x>.types' '(defgrammar <bad.x> {==> number} B := 1 where B;)'
refused 'type error in rule 1 of <bad.x>.types' '(defgrammar <bad.x> {==> number} B (where (> B "a")) := 1;)'
refused 'type error in rule 1 of <bad.x>.types' '(defgrammar <bad.x> {==> number} (require <bad.digit> 42) := 1;)'
refused 'type error in rule 1 of <bad.x>.types' '(defgrammar <bad.x> {==> number} (<bad.times> "a" 3) := 1;)'
refused 'type error in rule 1 of <bad.x>.types' '(defgrammar <bad.x> {==> number} (* (<bad.times> 1 "x")) := 1;)'
refused 'type error in rule 1 of <bad.x>.types' '(defgrammar <bad.x> {==> number} <bad.word> := (+ 1 <bad.word>);)'
refused 'type error in rule 1 of <bad.x>.types' '(defgrammar (<bad.x> Q) {string ==> number} B := 1 where (= B Q);)'
refused 'type error in rule 1 of bad.go' \
  '(define bad.go {string --> string} S -> (grammar.parse <bad.digit> (buffer.from-string S) (function bad.fail)))'
refused 'type error in rule 1 of bad.go' \
  '(define bad.go {string --> boolean} S -> (grammar.match? (<bad.times> 1) (buffer.from-string S)))'
refused 'type error in rule 1 of bad.go' \
  '(define bad.go {io.reader --> number} R -> (grammar.read <bad.digit> R (function bad.fail)))'
refused "<bad.any>'s value has no type" '(defgrammar <bad.x> {==> number} <bad.any> := <bad.any>;)'
refused 'gives a value with := in every alternative' '(defgrammar <bad.x> {==> number} B := 1; B;)'
refused 'a signature gives a type for each parameter' '(defgrammar (<bad.x> A) {==> number} B := A;)'
refused 'a signature without }' '(defgrammar <bad.x> {==> number B := 1;)'
refused 'X is a parameter' '(defgrammar (<bad.x> X) {string ==> string} X := X;)'
refused 'X is a parameter' '(defgrammar (<bad.x> X) {string ==> string} (at X) := X;)'
refused 'X is a parameter' '(defgrammar (<bad.x> X) {string ==> string} (* X) := X;)'
refused 'type error in rule 1 of <bad.first>.types' '
(defgrammar <bad.first> {==> string} (<bad.later> 1) := "ok";)
(defgrammar (<bad.later> Text) {string ==> string} <e> := (cn Text "!");)'
refused 'type error in rule 1 of <bad.first>.types' '
(defgrammar <bad.first> {==> string} (<bad.later> 1) := "ok";)
(defgrammar (<bad.later> N) N2 := N;)'
refused 'free variables in <bad.x>' '(defgrammar <bad.x> {==> number} "a" B := B; "b" := B;)'
refused 'free variables in <bad.x>' '(defgrammar <bad.x> {==> number} (where (> B 1)) B := B;)'

# Rules loaded under (tc +) read from a reader under (tc -).
"$SHEN" eval -m grammar -e '(tc +)' -l tests/grammar_typed.shen -e '(tc -)' \
  -e '(output "read: ~S~%" (grammar.read <gt.numbers> (io.reader (io.input-buffer (buffer.from-string "1 22 333")) []) (/. P M [fail P M])))' \
  > "$dir/read.out" 2>&1
grep -qxF 'read: #<result.ok [[1 22 333]]>' "$dir/read.out" || { cat "$dir/read.out"; exit 1; }
passed=$((passed + 1))

# Both copies share one default source budget.
cat tests/grammar_typed.shen > "$dir/two-grammars.shen"
sed 's/gt\./gt2./g' tests/grammar_typed.shen >> "$dir/two-grammars.shen"
cat > "$dir/two-grammars.shenmod" <<'EOF'
(shen.module (version 1) (name two-grammars) (requires grammar)
  (sources tc+ "two-grammars.shen"))
EOF
"$SHEN" eval -m "$dir/two-grammars.shenmod" > "$dir/two.out" 2>&1
[ "$(grep -c '^[1-9][0-9]* passed, 0 failed$' "$dir/two.out")" = 2 ] || { cat "$dir/two.out"; exit 1; }
passed=$((passed + 1))

# One ordinary typed load after grammar must fit all 300 declarations in the default budget.
awk 'BEGIN { for (i = 1; i <= 300; i++) print "(define gt.id" i " {number --> number} X -> X)" }' \
  > "$dir/identities.shen"
"$SHEN" eval -m grammar -e '(tc +)' -l "$dir/identities.shen" \
  -e '(output "last identity: ~A~%" (gt.id300 42))' > "$dir/identities.out" 2>&1 || { tail -8 "$dir/identities.out"; exit 1; }
grep -qxF 'last identity: 42' "$dir/identities.out" || { cat "$dir/identities.out"; exit 1; }
passed=$((passed + 1))

echo "$passed passed, 0 failed"
