\\ defgrammar: matching, values, captures, repetition, requires and what definitions refuse.
\\ Load lib/buffer.shen and lib/grammar.shen first: the macro applies to files read after it.
(set grammar-test.passed 0)
(set grammar-test.failed 0)

(define grammar-test.check
  Name Expected F ->
    (let Actual (trap-error (thaw F) (/. X [raised (error-to-string X)]))
      (if (= Actual Expected)
          (set grammar-test.passed (+ 1 (value grammar-test.passed)))
          (do (set grammar-test.failed (+ 1 (value grammar-test.failed)))
              (output "FAIL ~A: wanted ~S, got ~S~%" Name Expected Actual)))))

(define grammar-test.raises
  Name F -> (grammar-test.check Name true (freeze (trap-error (do (thaw F) false) (/. X true)))))

(define grammar-test.fail
  Position Message -> [error Position Message])

(define grammar-test.view
  Text -> (buffer.from-string Text))

(defgrammar <g.digit> B := (- B 48) where (and (>= B 48) (<= B 57));)
(defgrammar <g.digits> (+ <g.digit>);)
(defgrammar <g.number> (text <g.digits>) := [number <g.digits>];)
(defgrammar <g.crlf> 13 10;)
(defgrammar <g.space> (* 32);)
(defgrammar <g.pair>
  "(" <g.space> (text <g.digits>) <g.space> "," (require <g.space> (text <g.digits>) "expected digits") ")"
    := <g.digits>;)
(defgrammar <g.keyword> "abc" := long; "ab" := short; "a" _ := any;)
(defgrammar <g.sign> 45 := -1; 43 := 1; <e> := 1;)
(defgrammar <g.signed> <g.sign> <g.digit> := (* <g.sign> <g.digit>);)
(defgrammar <g.list> <g.digit> "," <g.list> := [<g.digit> | <g.list>]; <g.digit> := [<g.digit>];)
(defgrammar <g.optional> "a" (? "b") "c";)
(defgrammar <g.span> "<" (span <g.digits>) ">" := (buffer.string <g.digits>);)
(defgrammar <g.guarded> <g.digit> (where (> <g.digit> 4)) "!" := big; <g.digit> "!" := small;)
(defgrammar <g.required> "x" (require <g.digit> (where (> <g.digit> 4)) "too small") := <g.digit>;)
(defgrammar <g.choice> <g.required>; "xy" := fallback;)
(defgrammar <g.loop-require> (* <g.required>) "." := done;)
(defgrammar <g.binary> (u16-be Tag) (u32-be N) := [Tag N];)
(defgrammar <g.byte> B := B; _ := never;)
(defgrammar <g.empty> (* <g.space>) := empty;)
(defgrammar <g.ab> (require "a" "b" (make-string "want ~A" "ab")) := ok;)
(defgrammar <g.utf8> "é" := e;)
(defgrammar <g.early> (+ <g.upper>) := early;)
(defgrammar <g.upper> B where (and (>= B 65) (<= B 90));)
(defgrammar <g.late> (+ <g.upper>) := late;)
(defgrammar <g.capture> B <g.upper> := B;)
(defgrammar <g.uppers> "[" (* <g.upper>) "]" := ok;)
(defgrammar <g.nest> "(" <g.nest-body> ")" := [<g.nest-body>]; "x" := x;)
(defgrammar <g.nest-body> <g.nest> := <g.nest>;)
(defgrammar <g.d1> "a" (? <g.d0>);)
(defgrammar <g.d0> "z";)
(defgrammar <g.d2> <g.d1> "b";)
(defgrammar <g.d3> <g.d2> "c";)
(defgrammar <g.d4> <g.d3> "d";)
(defgrammar <g.d5> <g.d4> "e" := deep;)
(defgrammar <g.picky> B where (grammar-test.picky? B);)
(defgrammar <g.pickies> (+ <g.picky>);)
(defgrammar <g.redefined> B where (= B 97);)
(defgrammar <g.as> (+ <g.redefined>);)
(defgrammar <g.redefined> B where (= B 98);)
(defgrammar <g.bs> (+ <g.redefined>);)
(defgrammar (<g.nested> D) "[" (require (where (< D 3)) "too deep") (* (<g.nested> (+ D 1))) "]" := D;)
(defgrammar (<g.is> Q) B where (= B Q);)
(defgrammar (<g.not> Q) B where (not (= B Q));)
(defgrammar <g.quoted> Q (* (<g.not> Q)) (<g.is> Q) := Q;)
(defgrammar (<g.pair2> A B) X := [A B X];)
(defgrammar <g.swap> A B (<g.pair2> B A) := <g.pair2>;)
(defgrammar (<g.text-at-least> N) (text <g.digits>) := <g.digits> where (>= (shen-jit.bytes-length (shen-jit.string->bytes <g.digits>)) N);)
(defgrammar <g.year> (<g.text-at-least> 4) := <g.text-at-least>;)
(defgrammar <g.answer> (text <g.digits>) (where (= <g.digits> "42")) "!" := yes; (text <g.digits>) "?" := <g.digits>;)
(defgrammar <g.vowel> B where (grammar-test.vowel? B);)
(defgrammar <g.vowels> (+ <g.vowel>);)
\\ Raises for one byte, so a loop over it cannot make a table and keeps its test.
(define grammar-test.picky?
  0 -> (error "no zero")
  B -> (= B 112))

(define grammar-test.vowel?
  B -> (element? B [97 101 105 111 117]))

(grammar-test.check "digits match" true (freeze (grammar.match? <g.digits> (grammar-test.view "2026"))))
(grammar-test.check "+ needs one" false (freeze (grammar.match? <g.digits> (grammar-test.view ""))))
(grammar-test.check "match? wants all of it" false (freeze (grammar.match? <g.digits> (grammar-test.view "20x"))))
(grammar-test.check "text capture" [number "2026"]
  (freeze (grammar.parse <g.number> (grammar-test.view "2026") (function grammar-test.fail))))
(grammar-test.check "byte terminals" true (freeze (grammar.match? <g.crlf> (grammar-test.view "c#13;c#10;"))))
(grammar-test.check "short input fails" false (freeze (grammar.match? <g.crlf> (grammar-test.view "c#13;"))))
(grammar-test.check "string and spaces" "34"
  (freeze (grammar.parse <g.pair> (grammar-test.view "( 12 , 34)") (function grammar-test.fail))))
(grammar-test.check "after a require, failing is not an error" [error 0 "no match"]
  (freeze (grammar.parse <g.pair> (grammar-test.view "( 12 , 34 )") (function grammar-test.fail))))
(grammar-test.check "require reports where it began" [error 4 "expected digits"]
  (freeze (grammar.parse <g.pair> (grammar-test.view "(12,x)") (function grammar-test.fail))))
(grammar-test.check "no match at the start" [error 0 "no match"]
  (freeze (grammar.parse <g.pair> (grammar-test.view "[12,34]") (function grammar-test.fail))))
(grammar-test.check "trailing input at the first byte left" [error 7 "trailing input"]
  (freeze (grammar.parse <g.pair> (grammar-test.view "(12,34)x") (function grammar-test.fail))))
(grammar-test.check "positions count from the start of the bytes" [error 5 "expected digits"]
  (freeze (grammar.parse <g.pair> (buffer.slice (grammar-test.view "!(12,x)") 1 6) (function grammar-test.fail))))
(grammar-test.check "require at the end of input" [error 4 "expected digits"]
  (freeze (grammar.parse <g.pair> (grammar-test.view "(12,") (function grammar-test.fail))))

(map (/. Case (grammar-test.check (hd Case) (hd (tl Case))
                (freeze (grammar.parse <g.keyword> (grammar-test.view (hd Case)) (function grammar-test.fail)))))
  [["abc" long] ["ab" short] ["ax" any] ["a" [error 0 "no match"]] ["abcd" [error 3 "trailing input"]]])
(map (/. Case (grammar-test.check (hd Case) (hd (tl Case))
                (freeze (grammar.parse <g.signed> (grammar-test.view (hd Case)) (function grammar-test.fail)))))
  [["-7" -7] ["+7" 7] ["7" 7]])
(grammar-test.check "recursive rule builds a list" [1 2 3]
  (freeze (grammar.parse <g.list> (grammar-test.view "1,2,3") (function grammar-test.fail))))
(grammar-test.check "optional present" true (freeze (grammar.match? <g.optional> (grammar-test.view "abc"))))
(grammar-test.check "optional absent" true (freeze (grammar.match? <g.optional> (grammar-test.view "ac"))))
(grammar-test.check "optional takes one" false (freeze (grammar.match? <g.optional> (grammar-test.view "abbc"))))
(grammar-test.check "span is a view of the bytes matched" "123"
  (freeze (grammar.parse <g.span> (grammar-test.view "<123>") (function grammar-test.fail))))
(grammar-test.check "where as an item" big
  (freeze (grammar.parse <g.guarded> (grammar-test.view "7!") (function grammar-test.fail))))
(grammar-test.check "a failed where tries the next rule" small
  (freeze (grammar.parse <g.guarded> (grammar-test.view "3!") (function grammar-test.fail))))
(grammar-test.check "require with a guard" 7
  (freeze (grammar.parse <g.required> (grammar-test.view "x7") (function grammar-test.fail))))
(grammar-test.check "require's guard fails with its message" [error 1 "too small"]
  (freeze (grammar.parse <g.required> (grammar-test.view "x3") (function grammar-test.fail))))
(grammar-test.check "a require is not retried by alternatives" [error 1 "too small"]
  (freeze (grammar.parse <g.choice> (grammar-test.view "xy") (function grammar-test.fail))))
(grammar-test.check "nothing required before it: the next rule" fallback
  (freeze (grammar.parse <g.choice> (grammar-test.view "xy") (/. P M fallback))))
(grammar-test.check "a loop stops where its item fails" done
  (freeze (grammar.parse <g.loop-require> (grammar-test.view "x5x6.") (function grammar-test.fail))))
(grammar-test.check "a require inside a loop stops it" [error 3 "too small"]
  (freeze (grammar.parse <g.loop-require> (grammar-test.view "x5x1.") (function grammar-test.fail))))
(grammar-test.check "big-endian fields" [258 16909060]
  (freeze (let V (buffer.new 6)
               _ (map (/. I (buffer.u8! V I (hd (tl (assoc I [[0 1] [1 2] [2 1] [3 2] [4 3] [5 4]])))))
                      [0 1 2 3 4 5])
            (grammar.parse <g.binary> V (function grammar-test.fail)))))
(grammar-test.check "short field fails" [error 2 "no match"]
  (freeze (grammar.parse <g.binary> (buffer.slice (buffer.new 8) 2 5) (function grammar-test.fail))))
(grammar-test.check "first rule wins" 255
  (freeze (grammar.parse <g.byte> (buffer.u8! (buffer.new 1) 0 255) (function grammar-test.fail))))
(grammar-test.check "a loop that matches nothing stops" empty
  (freeze (grammar.parse <g.empty> (grammar-test.view "") (function grammar-test.fail))))
(grammar-test.check "a message can be computed" [error 0 "want ab"]
  (freeze (grammar.parse <g.ab> (grammar-test.view "ax") (function grammar-test.fail))))
(grammar-test.check "strings are UTF-8 bytes" e
  (freeze (grammar.parse <g.utf8> (grammar-test.view "é") (function grammar-test.fail))))
(grammar-test.check "a named rule through fn" [number "42"]
  (freeze (let Rule <g.number> (grammar.parse Rule (grammar-test.view "42") (function grammar-test.fail)))))
(grammar-test.check "match? through fn" true
  (freeze (let Rule <g.digits> (grammar.match? Rule (grammar-test.view "42")))))
(grammar-test.check "a range of storage" [error 3 "trailing input"]
  (freeze (grammar.parse-range <g.digits> (shen-jit.string->bytes "x12yz") 1 5 (function grammar-test.fail))))
(grammar-test.check "a range of storage, matched" [number "12"]
  (freeze (grammar.parse-range <g.number> (shen-jit.string->bytes "x12y") 1 3 (/. P M (error M)))))
(grammar-test.check "a class named before it is defined" early
  (freeze (grammar.parse <g.early> (grammar-test.view "AB") (function grammar-test.fail))))
(grammar-test.check "a class tested in place" late
  (freeze (grammar.parse <g.late> (grammar-test.view "AB") (function grammar-test.fail))))
(grammar-test.check "a class in place fails as a call does" false
  (freeze (grammar.match? <g.late> (grammar-test.view "Ab"))))
(grammar-test.check "a class's variable does not capture the rule's" 98
  (freeze (grammar.parse <g.capture> (grammar-test.view "bC") (function grammar-test.fail))))
(grammar-test.check "a loop over a function its file defines later" [true false]
  (freeze [(grammar.match? <g.vowels> (grammar-test.view "aeiou")) (grammar.match? <g.vowels> (grammar-test.view "aex"))]))
(grammar-test.check "mutual recursion through a rule compiled in place" [[x]]
  (freeze (grammar.parse <g.nest> (grammar-test.view "((x))") (function grammar-test.fail))))
(grammar-test.check "and from the other side" [x]
  (freeze (grammar.parse <g.nest-body> (grammar-test.view "(x)") (function grammar-test.fail))))
(grammar-test.check "a chain deeper than rules are compiled in place" deep
  (freeze (grammar.parse <g.d5> (grammar-test.view "abcde") (function grammar-test.fail))))
(grammar-test.check "a class loop, empty, one and several" [ok ok ok [error 0 "no match"]]
  (freeze (map (/. T (grammar.parse <g.uppers> (grammar-test.view T) (function grammar-test.fail)))
               ["[]" "[A]" "[ABC]" "[a]"])))
(grammar-test.check "a class whose guard raises for a byte keeps its test" [true false]
  (freeze [(grammar.match? <g.pickies> (grammar-test.view "ppp")) (grammar.match? <g.pickies> (grammar-test.view "pq"))]))
(grammar-test.check "each loop over a redefined class sees its own definition" [true false true false]
  (freeze [(grammar.match? <g.as> (grammar-test.view "aaa")) (grammar.match? <g.as> (grammar-test.view "bbb"))
           (grammar.match? <g.bs> (grammar-test.view "bbb")) (grammar.match? <g.bs> (grammar-test.view "aaa"))]))
(grammar-test.check "parameters bound the depth" [0 0 [error 4 "too deep"]]
  (freeze (map (/. T (grammar.parse (<g.nested> 0) (grammar-test.view T) (function grammar-test.fail)))
               ["[[[]]]" "[[][]]" "[[[[]]]]"])))
(grammar-test.check "a parameter given by the entry point" [true false]
  (freeze [(grammar.match? (<g.nested> 2) (grammar-test.view "[]")) (grammar.match? (<g.nested> 3) (grammar-test.view "[]"))]))
(grammar-test.check "a byte passed into a loop" [39 34 [error 0 "no match"]]
  (freeze (map (/. T (grammar.parse <g.quoted> (grammar-test.view T) (function grammar-test.fail)))
               ["'abc'" "c#34;a'bc#34;" "'abc#34;"])))
(grammar-test.check "arguments are evaluated before parameters are bound" [2 1 3]
  (freeze (let V (buffer.new 3)
               _ (buffer.u8! (buffer.u8! (buffer.u8! V 0 1) 1 2) 2 3)
            (grammar.parse <g.swap> V (function grammar-test.fail)))))
(grammar-test.check "a parameter in a guard" ["2026" [error 0 "no match"]]
  (freeze (map (/. T (grammar.parse <g.year> (grammar-test.view T) (function grammar-test.fail))) ["2026" "26"])))
(grammar-test.check "a capture a later item names is there for it, and one left for the end too"
  [yes [error 0 "no match"] "7"]
  (freeze (map (/. T (grammar.parse <g.answer> (grammar-test.view T) (function grammar-test.fail))) ["42!" "41!" "7?"])))
(grammar-test.raises "not a view" (freeze (grammar.parse <g.digits> "42" (function grammar-test.fail))))

(define grammar-test.fill
  _ I I -> true
  B I N -> (do (shen-jit.u8! B I 55) (grammar-test.fill B (+ I 1) N)))

(let B (shen-jit.bytes 1000000)
     _ (grammar-test.fill B 0 1000000)
  (grammar-test.check "a long run loops in constant stack" true
    (freeze (grammar.match? <g.digits> (buffer.wrap B)))))

(define grammar-test.refused
  Name Text -> (grammar-test.raises Name (freeze (eval (hd (read-from-string Text))))))

(grammar-test.refused "a value from a rule without :=" "(defgrammar <g.bad> <g.crlf> := <g.crlf>;)")
(grammar-test.refused "a parameter bound by an item" "(defgrammar (<g.bad> X) X := X;)")
(grammar-test.refused "a rule named but not matched" "(defgrammar <g.bad> <g.digit> := <g.digits>;)")
(grammar-test.refused "a rule named only inside a repetition" "(defgrammar <g.bad> (* <g.digit>) := <g.digit>;)")
(grammar-test.refused "a repetition of several items" "(defgrammar <g.bad> (* 1 2 3);)")
(grammar-test.refused "a byte out of range" "(defgrammar <g.bad> 256;)")
(grammar-test.refused "an unknown form" "(defgrammar <g.bad> (many 1);)")
(grammar-test.refused "not a rule name" "(defgrammar bad 1;)")
(grammar-test.refused "no rules" "(defgrammar <g.bad>)")
(grammar-test.refused "a call with too many arguments" "(defgrammar <g.bad> (<g.is> 1 2);)")
(grammar-test.refused "a parameter that is not a variable" "(defgrammar (<g.bad> x) 1;)")
(grammar-test.refused "a message naming what it requires"
  "(defgrammar <g.bad> (require <g.digit> (make-string c#34;~Ac#34; <g.digit>));)")

(defgrammar <g.any> B := B;)
(defgrammar <g.last> (text <g.any>) <g.any> := <g.any>;)

(grammar-test.check "later match replaces a deferred capture" 98
  (freeze
    (grammar.parse <g.last> (buffer.from-string "ab")
      (function grammar-test.fail))))

(defgrammar <g.plus> <g.digit> (+ <g.digit>) := <g.digit>;)

(grammar-test.check "plus does not replace an outside value" 1
  (freeze
    (grammar.parse <g.plus> (buffer.from-string "123")
      (function grammar-test.fail))))

(defgrammar <g.cut-short> "a" (require "bc" "want bc") := yes;)

(grammar-test.check "truncated require reports the input end"
  [error 2 "want bc"]
  (freeze
    (grammar.parse <g.cut-short> (buffer.from-string "ab")
      (function grammar-test.fail))))

(output "~A passed, ~A failed~%" (value grammar-test.passed) (value grammar-test.failed))
