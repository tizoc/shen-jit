\\ Typed grammars and typed code that parses with them. Load buffer.shen, io.shen and grammar.shen,
\\ then (tc +), then this.
(defgrammar <gt.digit> {==> number} B := (- B 48) where (and (>= B 48) (<= B 57));)

(defgrammar (<gt.number> Acc) {number ==> number}
  <gt.digit> (<gt.number> (+ (* 10 Acc) <gt.digit>)) := <gt.number>;
  <gt.digit> := (+ (* 10 Acc) <gt.digit>);)

\\ Rules without a value need no type, and typed rules call them.
(defgrammar <gt.space> B where (= B 32);)
(defgrammar <gt.spaces> (* <gt.space>);)
(defgrammar <gt.letter> B where (and (>= B 97) (<= B 122));)
(defgrammar <gt.letters> (+ <gt.letter>);)

(defgrammar <gt.numbers> {==> (list number)}
  (<gt.number> 0) <gt.spaces> <gt.numbers> := [<gt.number> | <gt.numbers>];
  <e> := [];)

(defgrammar <gt.word> {==> string} (text <gt.letters>) := <gt.letters>;)

(defgrammar <gt.field> {==> (string * number)}
  <gt.word> "=" (require (<gt.number> 0) "expected a number") := (@p <gt.word> <gt.number>);)

(defgrammar <gt.bracketed> {==> buffer.view} "[" (span <gt.letters>) "]" := <gt.letters>;)

(defgrammar <gt.short> {==> number} (at A) <gt.letters> (at Z) (where (< (- Z A) 5)) := (- Z A);)

(defgrammar <gt.u16> {==> number} (u16-be N) := N;)

(defgrammar (<gt.keyword> Word) {string ==> string} <gt.word> := <gt.word> where (= <gt.word> Word);)

(defgrammar <gt.let> {==> (string * number)} (<gt.keyword> "let") " " <gt.field> := <gt.field>;)

\\ A rule named in another alternative with another capture has the capture's type there.
(defgrammar <gt.either> {==> string}
  "#" <gt.word> := (cn "#" <gt.word>);
  (text <gt.word>) := <gt.word>;)

(define gt.raise
  {number --> string --> A}
  At Message -> (error "~A at ~A" Message At))

(define gt.error
  {(lazy A) --> string}
  F -> (trap-error (do (thaw F) "no error") (/. E (error-to-string E))))

(define gt.view
  {string --> buffer.view}
  Text -> (buffer.from-string Text))

(define gt.numbers
  {string --> (list number)}
  Text -> (grammar.parse <gt.numbers> (gt.view Text) (function gt.raise)))

(define gt.reader
  {string --> io.reader}
  Text -> (io.reader (io.input-buffer (gt.view Text)) []))

(define gt.reject
  {number --> string --> (grammar.read-result A)}
  At Message -> [error (io.error read "grammar" (make-string "~A at ~A" Message At))])

(define gt.message
  {(grammar.read-result A) --> string}
  [error Error] -> (io.error-message Error)
  _ -> "no error")

(define gt.checks
  {--> (list (string * boolean))}
  -> [(@p "a list of numbers" (= (gt.numbers "12 345 6") [12 345 6]))
      (@p "no numbers" (= (gt.numbers "") []))
      (@p "a pair" (= (grammar.parse <gt.field> (gt.view "ab=12") (function gt.raise)) (@p "ab" 12)))
      (@p "a required item's message" (= (gt.error (freeze (grammar.parse <gt.field> (gt.view "ab=x") (function gt.raise))))
                                         "expected a number at 3"))
      (@p "trailing input" (= (gt.error (freeze (gt.numbers "1 2x"))) "trailing input at 3"))
      (@p "a span" (= (buffer.string (grammar.parse <gt.bracketed> (gt.view "[abc]") (function gt.raise))) "abc"))
      (@p "positions" (= (grammar.parse <gt.short> (gt.view "abcd") (function gt.raise)) 4))
      (@p "a guard over positions" (= (gt.error (freeze (grammar.parse <gt.short> (gt.view "abcdef") (function gt.raise))))
                                      "no match at 0"))
      (@p "a binary field" (= (grammar.parse <gt.u16> (gt.view "AB") (function gt.raise)) 16706))
      (@p "an argument" (grammar.match? (<gt.keyword> "let") (gt.view "let")))
      (@p "an argument that does not match" (not (grammar.match? (<gt.keyword> "let") (gt.view "lot"))))
      (@p "rules within rules" (= (grammar.parse <gt.let> (gt.view "let x=5") (function gt.raise)) (@p "x" 5)))
      (@p "a read" (= (grammar.read <gt.numbers> (gt.reader "1 22 333") (function gt.reject)) [ok [1 22 333]]))
      (@p "a read within a limit" (= (grammar.read-within <gt.numbers> (gt.reader "1 22 333") 4 (function gt.reject))
                                     [ok [1 22]]))
      (@p "a read that fails" (= (gt.message (grammar.read <gt.field> (gt.reader "ab=x") (function gt.reject)))
                                 "expected a number at 3"))
      (@p "a read at the end" (= (grammar.read <gt.field> (gt.reader "") (function gt.reject)) [eof]))
      (@p "a read with an argument" (= (grammar.read (<gt.keyword> "let") (gt.reader "let") (function gt.reject))
                                       [ok "let"]))
      (@p "a value and a capture" (= (map (/. T (grammar.parse <gt.either> (gt.view T) (function gt.raise))) ["#ab" "cd"])
                                     ["#ab" "cd"]))])

(define gt.report
  {(list (string * boolean)) --> number --> number --> string}
  [] Passed Failed -> (make-string "~A passed, ~A failed" Passed Failed)
  [(@p _ true) | Checks] Passed Failed -> (gt.report Checks (+ Passed 1) Failed)
  [(@p Name _) | Checks] Passed Failed -> (do (output "FAIL ~A~%" Name) (gt.report Checks Passed (+ Failed 1))))

(output "~A~%" (gt.report (gt.checks) 0 0))
