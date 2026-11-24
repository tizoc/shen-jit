\\ lib/refine.shen in untyped code, its errors, and what lib/refine-facts.shen trusts, tried on numbers.
\\ shen-jit eval -m buffer/contracts -l tests/smt-generate.shen -l tests/refine.shen

(set refine-test.*passed* 0)
(set refine-test.*failed* 0)

(define refine-test.check
  Name Expected F -> (let Got (trap-error (thaw F) (/. E [error (error-to-string E)]))
                       (if (= Got Expected)
                           (set refine-test.*passed* (+ 1 (value refine-test.*passed*)))
                           (do (output "FAIL ~A: expected ~S, got ~S~%" Name Expected Got)
                               (set refine-test.*failed* (+ 1 (value refine-test.*failed*)))))))

\\ In untyped code a condition is tested as the function is called, and a promise is taken as said.
(define-checked refine-test.at
  {V : (vector A) --> I : fixnum --> A}
  {requires (fx<= 0 I) (fx< I (fxlimit V))}
  V I -> (<-vector V (+ I 1)))
(define-checked refine-test.no-condition X -> (* 2 X) where (> X 0) _ -> 0)
(define-checked refine-test.promise {X : fixnum --> R : fixnum} {ensures (fx> R X)} X -> (- X 1))

(refine-test.check "a condition" [b [error "refine-test.at: not so: (fx< I (fxlimit V))"] [error "refine-test.at: not so: (fx<= 0 I)"]]
  (freeze (map (/. I (trap-error (refine-test.at (@v a b c <>) I) (/. E [error (error-to-string E)]))) [1 3 -1])))
(refine-test.check "through fn" [a c] (freeze (map ((fn refine-test.at) (@v a b c <>)) [0 2])))
(refine-test.check "no condition" [6 0] (freeze (map (fn refine-test.no-condition) [3 -3])))
(refine-test.check "a promise untested" 4 (freeze (refine-test.promise 5)))

(define refine-test.reads
  S -> (trap-error (do (read-from-string S) read) (/. E (error-to-string E))))

(refine-test.check "declarations that are not"
  ["define-checked: the signature of f does not have its arguments"
   "define-checked: f has a clause with no arrow"
   "define-checked: f has a { with no }"
   "define-checked: f has a { with no }"
   "define-checked: f has conditions, and no signature to name what they are of"
   "define-checked: f has conditions, and no signature to name what they are of"
   "define-checked: f has requires in braces, where requires can be and then ensures"
   "define-checked: f has require in braces, where requires can be and then ensures"
   "refine: f requires something of R, which is not a name it can be of"
   "refine: f ensures something of Y, which is not a name it can be of"
   "refine.type: (refine.type t where true) is not (refine.type Name Variable : Base where Condition)"
   "refine.type: (t A) is under itself"
   "refine.trust: (refine.trust f --> R where (fx> R 0)) is not (refine.trust (F Formal ...) --> Result where Condition)"
   "refine.contract: buffer.u8 takes 2, and not the arguments (V)"
   "refine.contract: refine-test.at has a contract of its own"
   "refine: buffer.u8 requires something of J, which is not a name it can be of"
   "refine: buffer.u8 requires something of R, which is not a name it can be of"
   "refine: buffer.u8 trusts something of J, which is not a name it can be of"
   "refine: not a condition on what buffer.new takes and gives: (fx< N (buffer.length N))"
   "refine: not a condition on what buffer.new takes and gives: (fx< R 3)"
   "refine: not a condition on what buffer.new takes and gives: (buffer.new N)"
   "refine.contract: (refine.contract buffer.new requires (fx< N 3)) is not (refine.contract (F X ...) --> Result requires Condition ... trusts Promise ...)"
   "refine.trust: refine-test.at has a contract of its own"
   read]
  (freeze (map (fn refine-test.reads)
    ["(define-checked f {X : fixnum --> fixnum} {requires (fx> X 0)} X Y -> X)" "(define-checked f X)"
     "(define-checked f {fixnum --> fixnum X -> X)" "(define-checked f {X : fixnum --> fixnum} {requires (fx> X 0) X -> X)"
     "(define-checked f {requires (fx> X 0)} X -> X)" "(define-checked f {ensures (fx> X 0)} X -> X)"
     "(define-checked f {X : fixnum --> R : fixnum} {ensures (fx> R 0)} {requires (fx> X 0)} X -> X)"
     "(define-checked f {X : fixnum --> fixnum} {require (fx> X 0)} X -> X)"
     "(define-checked f {X : fixnum --> R : fixnum} {requires (fx> R 0)} X -> X)"
     "(define-checked f {X : fixnum --> R : fixnum} {ensures (fx> R Y)} X -> X)"
     "(refine.type t where true)" "(refine.type (t A) X : (t A) where true)" "(refine.trust f --> R where (fx> R 0))"
     "(refine.contract (buffer.u8 V) requires (fx<= 0 V))" "(refine.contract (refine-test.at V I) requires (fx<= 1 I))"
     "(refine.contract (buffer.u8 V I) requires (fx<= 0 J))" "(refine.contract (buffer.u8 V I) --> R requires (fx<= 0 R))"
     "(refine.contract (buffer.u8 V I) trusts (fx<= 0 J))"
     "(refine.contract (buffer.new N) requires (fx< N (buffer.length N)))" "(refine.contract (buffer.new N) --> R trusts (fx< R 3))"
     "(refine.contract (buffer.new N) requires (buffer.new N))" "(refine.contract buffer.new requires (fx< N 3))"
     "(refine.trust (refine-test.at V I) --> R where true)" "(refine.trust (refine-test.other V I) --> R where (fx>= R 0))"])))

\\ ---------------------------------------------------------------------------
\\ For rules of one's own. What cannot be read proves nothing.

(define refine-test.proves?
  Guards Goal -> (refine.proves? (map (/. G [G : verified]) Guards) Goal))

(refine-test.check "proves?" [true false true false true false false true]
  (freeze [(refine-test.proves? [[[fx< a] b]] [fx<= a b])
           (refine-test.proves? [[[fx<= a] b]] [fx< a b])
           (refine-test.proves? [[[and [[fx< a] b]] [odd? a]]] [fx<= [fx+ a 1] b])
           (refine-test.proves? [[[or [[fx< a] b]] [odd? a]]] [fx<= a b])
           (refine-test.proves? [[not [[or [[fx>= a] b]] [odd? a]]]] [fx<= a b])
           (refine-test.proves? [] [odd? a])
           (refine-test.proves? [] [not [odd? a]])
           (refine-test.proves? [[odd? a]] [or [odd? a] [fx>= 1 0]])]))
(refine-test.check "a hypothesis that cannot hold" true (freeze (refine-test.proves? [[[fx< a] a]] [odd? a])))
(refine-test.check "pure or not" [true false]
  (freeze [(refine-test.proves? [[[fx< a] [fxlimit v]]] [fx< a [fxlimit v]])
           (refine-test.proves? [[[fx< a] [refine-test.some v]]] [fx< a [refine-test.some v]])]))

\\ ---------------------------------------------------------------------------
\\ What is trusted of the operations, which must hold of what they give.

(define refine-test.trusted
  F Args -> (let C (refine.trusted F)
              (refine-test.holds? (refine.replace [(hd (tl C)) | (hd C)] [(refine-test.apply (function F) Args) | Args]
                                                  (hd (tl (tl C)))))))

(define refine-test.apply
  F [] -> F
  F [X | Xs] -> (refine-test.apply (F X) Xs))

\\ Products that leave the fixnums are no reason to fail, as no code computes them.
(define refine-test.holds?
  P -> (trap-error (eval P) (/. E (= (error-to-string E) "integer overflow"))))

(define refine-test.number
  -> (smt-generate.pick [0 1 -1 2 7 -7 (smt-generate.between -100 100) (smt-generate.between -100 100)
                         2305843009213693951 -2305843009213693951]))

(define refine-test.every-trusted?
  _ 0 -> true
  F N -> (let A (refine-test.number) B (refine-test.number)
           (if (or (= B 0) (refine-test.trusted F [A B])) (refine-test.every-trusted? F (- N 1)) [A B])))

(define refine-test.every-shift?
  0 -> true
  N -> (let A (refine-test.number) K (smt-generate.below 62)
         (if (refine-test.trusted shen-jit.shift-right [A K]) (refine-test.every-shift? (- N 1)) [A K])))

(refine-test.check "division and masks" [true true true true true true]
  (freeze [(refine-test.every-trusted? fxquotient 400) (refine-test.every-trusted? fxremainder 400)
           (refine-test.every-trusted? shen-jit.bit-and 400) (refine-test.every-trusted? shen-jit.bit-or 400)
           (refine-test.every-trusted? shen-jit.bit-xor 400) (refine-test.every-shift? 400)]))

\\ Shifts and masks by constants, each with each number.
(define refine-test.every-bits?
  F Ks -> (refine-test.every? (/. K (refine-test.every? (/. A (refine-test.bits? F A K)) (refine-test.numbers))) Ks))

(define refine-test.every?
  _ [] -> true
  F [X | Xs] -> (and (F X) (refine-test.every? F Xs)))

(define refine-test.bits?
  F A K -> (refine-test.holds? (refine.bits F [A K] ((function F) A K))))

(define refine-test.numbers
  -> [0 1 -1 2 -2 3 7 8 -8 -9 15 16 255 -256 -257 1000 65535 16777215 16777216 16777217 -16777216 -16777217
      4294967295 -4294967296 -4294967297 2305843009213693951 -2305843009213693951])

(define refine-test.up-to
  N N -> [N]
  I N -> [I | (refine-test.up-to (+ I 1) N)])

(refine-test.check "shifts and masks by constants" [true true true true [true true true true true] false]
  (freeze [(refine-test.every-bits? shen-jit.shift-right (refine-test.up-to 0 40))
           (refine-test.every-bits? shen-jit.shift-left (refine-test.up-to 0 40))
           (refine-test.every-bits? shen-jit.bit-and [1 3 7 255 65535 4294967295 8589934591 0 -1 6])
           (refine-test.every? (/. M (refine-test.every-bits? shen-jit.bit-and [M])) (refine-test.numbers))
           (map (/. P (= true P))
                [(refine.bits shen-jit.shift-right [(protect A) 33] (protect R)) (refine.bits shen-jit.shift-left [(protect A) -1] (protect R))
                 (refine.bits shen-jit.bit-and [(protect A) 6] (protect R)) (refine.bits shen-jit.bit-and [(protect A) (protect B)] (protect R))
                 (refine.bits shen-jit.bit-or [(protect A) 7] (protect R))])
           (= true (refine.bits shen-jit.bit-and [7 (protect A)] (protect R)))]))

(set refine-test.*bytes* (let B (shen-jit.bytes 8) (do (shen-jit.s32! B 0 -1) (shen-jit.s32! B 4 -2147483648) B)))
(refine-test.check "reads" [true true true true true true true]
  (freeze [(refine-test.trusted shen-jit.u8 [(value refine-test.*bytes*) 0]) (refine-test.trusted shen-jit.u16 [(value refine-test.*bytes*) 0])
           (refine-test.trusted shen-jit.u32 [(value refine-test.*bytes*) 0]) (refine-test.trusted shen-jit.s32 [(value refine-test.*bytes*) 4])
           (refine-test.trusted shen-jit.bytes-length [(value refine-test.*bytes*)]) (refine-test.trusted fxlimit [(vector 0)])
           (refine-test.trusted shen-jit.popcount [-1])]))

\\ The lengths of what is made, sliced and written, whose arguments are called for once.
(define refine-test.length-trusted
  [F | Args] -> (refine-test.trusted F Args))

(set refine-test.*view* (buffer.new 9))
(refine-test.check "lengths" [true true true true true true true true true true true true true true true true true]
  (freeze (map (fn refine-test.length-trusted)
    [[shen-jit.bytes 5] [shen-jit.bytes 0] [shen-jit.u8! (shen-jit.bytes 9) 1 2] [shen-jit.u16! (shen-jit.bytes 9) 1 2]
     [shen-jit.u32! (shen-jit.bytes 9) 1 2] [shen-jit.s32! (shen-jit.bytes 9) 1 -2] [shen-jit.s64! (shen-jit.bytes 9) 1 -2]
     [shen-jit.copy-bytes (shen-jit.bytes 9) 1 (shen-jit.bytes 20) 4 3]
     [buffer.new 7] [buffer.wrap (shen-jit.bytes 6)] [buffer.bytes (value refine-test.*view*)]
     [buffer.slice (value refine-test.*view*) 2 5] [buffer.slice (buffer.slice (value refine-test.*view*) 2 5) 5 0]
     [buffer.u8-> (value refine-test.*view*) 8 1] [buffer.u16-be-> (value refine-test.*view*) 7 1]
     [buffer.u32-be-> (value refine-test.*view*) 5 1] [buffer.copy-into! (value refine-test.*view*) 1 (buffer.new 20) 4 3]])))
(refine-test.check "occurrences" true (freeze (refine-test.trusted occurrences [a [a b a]])))

\\ What buffer's contracts ask is what its functions need, over small arguments: where it is so they give
\\ something, and where it is not they raise. offset-at takes a count below 0, as it were none.
(set refine-test.*views* (map (fn buffer.new) [0 1 5]))
(define refine-test.small -> [-1 0 1 2 4 5 6])
(define refine-test.stored -> [-1 0 255 256 65535 65536 4294967295 4294967296])

(define refine-test.agrees?
  F Args -> (let C (refine.contract F)
                 Asked (eval (refine.replace (hd C) (map (fn refine-test.quoted) Args) (hd (tl C))))
                 Given (trap-error (do (refine-test.apply (function F) Args) true) (/. E false))
              (if (= Asked Given) true [F Args Asked Given])))

\\ A view, where code has one, is the value of a global.
(define refine-test.quoted
  X -> X where (number? X)
  X -> [nth (refine-test.place X (value refine-test.*views*)) [value refine-test.*views*]])

(define refine-test.place
  X [Y | Ys] -> 1 where (= (buffer.length X) (buffer.length Y))
  X [_ | Ys] -> (+ 1 (refine-test.place X Ys)))

(define refine-test.over
  [] -> [[]]
  [Xs | More] -> (let Rest (refine-test.over More) (mapcan (/. X (map (/. R [X | R]) Rest)) Xs)))

(define refine-test.disagreements
  F Boxes -> (mapcan (/. Args (let A (refine-test.agrees? F Args) (if (= A true) [] [A]))) (refine-test.over Boxes)))

(refine-test.check "contracts of buffer" [[] [] [] [] [] [] [] [] []]
  (freeze (let Vs (value refine-test.*views*) Is (refine-test.small) Xs (refine-test.stored)
            [(refine-test.disagreements buffer.new [Is]) (refine-test.disagreements buffer.slice [Vs Is Is])
             (refine-test.disagreements buffer.copy-into! [Vs Is Vs Is Is])
             (refine-test.disagreements buffer.u8 [Vs Is]) (refine-test.disagreements buffer.u16-be [Vs Is]) (refine-test.disagreements buffer.u32-be [Vs Is])
             (refine-test.disagreements buffer.u8-> [Vs Is Xs]) (refine-test.disagreements buffer.u16-be-> [Vs Is Xs]) (refine-test.disagreements buffer.u32-be-> [Vs Is Xs])])))
(refine-test.check "a count below 0 of offset-at" [-1]
  (freeze (map (/. D (hd (tl (tl (hd (tl D)))))) [(hd (refine-test.disagreements buffer.offset-at [[(hd (tl (value refine-test.*views*)))] [0] [-1 0 1]]))])))

(define refine-test.read
  Forms -> (address-> (absvector 2) 0 Forms))

\\ A contract is there once its definition was evaluated, and not once it was read or checked.
(set refine-test.*read* (do (tc +) (let Forms (read-from-string "(define-checked refine-test.late {X : fixnum --> R : fixnum} {ensures (fx= R 2)} X -> 2)") _ (tc -) Forms)))
(refine-test.check "a contract once evaluated" [[] [] [[(protect X)] true (protect R) [fx= (protect R) 2]]]
  (freeze (let Read (refine.contract refine-test.late)
               _ (declare refine-test.late [fixnum --> fixnum])
               R (refine.around (hd (value refine-test.*read*)) (refine-test.read (value refine-test.*read*)) (/. X (shen.typecheck X [fixnum --> fixnum])))
               Checked (refine.contract refine-test.late)
               _ (shen-jit.eval-checked (hd (tl R)))
               _ (thaw (tl (tl R)))
            [Read Checked (refine.contract refine-test.late)])))
(refine-test.check "the call that was proved, and no other like it" [f [g 1] [f 1]]
  (freeze (let Call [f 1]
               _ (set refine.*proved* [[Call | g]])
               R (refine.rewritten [f Call [f 1]])
               _ (set refine.*proved* [])
            R)))
\\ In a datatype's side condition, a variable is of its type in the hypotheses, if it has one.
(define refine-test.equal-5?
  X Hyps -> (refine.proves? [[[[= X] 5] : verified] | Hyps] [fx= X 5]))
(refine-test.check "types of hypotheses" [true false false]
  (freeze (let X (shen.freshterm (protect X))
               Y (shen.freshterm (protect Y))
            [(refine-test.equal-5? X [[Y : symbol] [X : fixnum]]) (refine-test.equal-5? X [[Y : fixnum]]) (refine-test.equal-5? X [])])))
\\ A definition calls the body of what it defines, or of what is after it, and an expression that of what is there.
(define refine-test.body?
  Checking Place -> (let _ (set refine.*checking* Checking)
                         _ (set refine.*together* [[refine-test.later 2]])
                         _ (set refine.*place* Place)
                         Body (refine.body-of refine-test.later [[(protect X)] true (protect R) true])
                         _ (map (/. X (set X [])) [refine.*checking* refine.*together*])
                      (cons? Body)))
(refine-test.check "the body of what is defined later" [true false false true]
  (freeze [(refine-test.body? [refine-test.f] 1) (refine-test.body? [refine-test.f] 2) (refine-test.body? [] 1) (refine-test.body? [refine-test.later] 2)]))
(refine-test.check "nothing checked after an error" [["refine: a where that is no guard in rule 1 of refine-test.f" []] ["refine: a where that is no guard" []]]
  (freeze (map (/. Form (let Message (trap-error (refine.around Form (refine-test.read [Form]) (/. X true)) (/. E (error-to-string E)))
                          [Message (value refine.*checking*)]))
               [[define refine-test.f { fixnum --> fixnum } (protect X) -> [fx+ 1 [where true (protect X)]]]
                [fx+ 1 [where true 1]]])))

(output "~A passed, ~A failed~%" (value refine-test.*passed*) (value refine-test.*failed*))
