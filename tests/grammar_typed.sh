#!/bin/sh
# Typed grammars refuse what does not typecheck, and say where; their rules read from a reader.
set -eu
SHEN=$1
dir=$(mktemp -d)
trap 'grammar_typed_status=$?; rm -rf "$dir"; exit $grammar_typed_status' EXIT
if command -v cygpath > /dev/null; then dir=$(cygpath -m "$dir"); fi

cat > "$dir/base.shen" <<'EOF'
(defgrammar <bad.digit> {==> number} B := (- B 48) where (and (>= B 48) (<= B 57));)
(defgrammar <bad.letter> B where (and (>= B 97) (<= B 122));)
(defgrammar <bad.letters> (+ <bad.letter>);)
(defgrammar <bad.any> B := B;)
(defgrammar <bad.word> {==> string} (text <bad.letters>) := <bad.letters>;)
(defgrammar (<bad.times> Byte N) {number --> number ==> number} (at P) := (+ P N);)
(define bad.fail {number --> string --> A} At Message -> (error "~A at ~A" Message At))
EOF

passed=0
refused() {
  printf '%s\n' "$2" | cat "$dir/base.shen" - > "$dir/case.shen"
  if "$SHEN" eval -l lib/buffer.shen -l lib/io.shen -l lib/grammar.shen -e '(tc +)' -l "$dir/case.shen" > "$dir/case.out" 2>&1; then
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
"$SHEN" eval -l lib/buffer.shen -l lib/io.shen -l lib/grammar.shen -e '(tc +)' -l tests/grammar_typed.shen -e '(tc -)' \
  -e '(output "read: ~S~%" (grammar.read <gt.numbers> (io.reader (io.input-buffer (buffer.from-string "1 22 333")) []) (/. P M [fail P M])))' \
  > "$dir/read.out" 2>&1
grep -qxF 'read: [ok [1 22 333]]' "$dir/read.out" || { cat "$dir/read.out"; exit 1; }
passed=$((passed + 1))

echo "$passed passed, 0 failed"
