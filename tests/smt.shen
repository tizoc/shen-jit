\\ lib/smt.shen: shen-jit eval -m smt -l tests/smt-generate.shen -l tests/smt.shen. Generated formulas are
\\ compared with every assignment of a small box, and proofs are tried on formulas that can hold.

(set smt-test.*passed* 0)
(set smt-test.*failed* 0)

(define smt-test.pass
  -> (set smt-test.*passed* (+ 1 (value smt-test.*passed*))))

(define smt-test.fail
  Name Got -> (do (output "FAIL ~A: ~S~%" Name Got)
                  (set smt-test.*failed* (+ 1 (value smt-test.*failed*)))))

(define smt-test.check
  Name Expected F -> (let Got (trap-error (thaw F) (/. E [error (error-to-string E)]))
                       (if (= Got Expected) (smt-test.pass) (smt-test.fail Name [Expected Got]))))

(define smt-test.kind
  R -> sat where (smt.sat? R)
  R -> unsat where (smt.unsat? R)
  R -> (smt.reason R))

(define smt-test.is
  Expected Fs -> (smt-test.check Fs Expected (freeze (smt-test.kind (smt.check Fs)))))

(define smt-test.refused
  Message Fs -> (smt-test.check Fs [error Message] (freeze (smt.check Fs))))

\\ ---------------------------------------------------------------------------
\\ What holds and what does not.

(smt-test.is sat [])
(smt-test.is sat [true])
(smt-test.is unsat [false])
(smt-test.is unsat [[or]])
(smt-test.is sat [[and]])
(smt-test.is sat [[<= 0 i] [< i n]])
(smt-test.is unsat [[<= 0 i] [< i n] [< n 1]])
(smt-test.is unsat [[< x y] [< y z] [< z x]])
(smt-test.is sat [[<= x y] [<= y z] [<= z x]])
(smt-test.is unsat [[= x y] [= y z] [not [= x z]]])
(smt-test.is unsat [[<= [+ start count] length] [<= 0 start] [<= 0 count] [> start length]])
(smt-test.is unsat [[< 0 x] [< x 1]])
(smt-test.is unsat [[= [* 2 x] [+ [* 2 y] 1]]])
(smt-test.is unsat [[< 0 [- [* 3 x] [* 3 y]]] [< [- [* 3 x] [* 3 y]] 3]])
(smt-test.is sat [[= [* 3 x] [+ [* 2 y] 1]] [= x 1]])
\\ Integers are looked for one unknown at a time, so some are missed.
(smt-test.is "no integers found" [[= [* 3 x] [+ [* 2 y] 1]]])
\\ Where another order of elimination loses integers: that what is equal to a multiple is one, and what is
\\ bounded above, or below, by itself and not by a multiple.
(smt-test.is unsat [[= x 2] [= [+ [* 2 y] [* 3 x]] 1]])
(smt-test.is sat [[= [+ [* -1 z] [* 3 y]] [+ z -2]] [>= [+ [* 3 y] [* 2 x]] z]])
(smt-test.is sat [[<= [* 3 z] [- y 2]] [>= [+ [* 3 z] [* 2 x]] 4] [>= [+ [* -2 y] [* 3 z]] [- x 1]]])
(smt-test.is unsat [[= i [* 4 q]] [= e [* 4 r]] [<= [* 4 q] i] [< i [+ [* 4 q] 4]] [< i e] [<= e n] [> [+ i 4] n]])
(smt-test.is unsat [[<= [* 4 q] i] [< i [+ [* 4 q] 4]] [= [- i [* 4 q]] 0] [<= [* 4 r] e] [< e [+ [* 4 r] 4]] [= [- e [* 4 r]] 0] [< i e] [<= e n] [> [+ i 4] n]])
(smt-test.is unsat [p [not p]])
(smt-test.is unsat [[or p q] [or p [not q]] [or [not p] q] [or [not p] [not q]]])
(smt-test.is sat [[or p q] [or [not p] [not q]]])
(smt-test.is unsat [[or p [< x 0]] [or [not p] [< x 0]] [> x 0]])
(smt-test.is sat [[< "a b" "x"]])
(smt-test.is unsat [[not [or [<= x y] [<= y x]]]])
(smt-test.is sat [[= [- x] 5]])
(smt-test.is unsat [[= [- x 1 2] 5] [not [= x 8]]])
(smt-test.is unsat [[= [* [- 2 5] x] 4]])
(smt-test.is unsat [[not true]])

\\ A proposition that closes one case must not close the others.
(smt-test.is sat [[or p q] [not p]])
(smt-test.is unsat [[or p [and q [< x 0]]] [not p] [> x 0]])
\\ A case that nothing needs: the second choice alone refutes.
(smt-test.is unsat [[>= y 0] [not [= y 0]] [= x 0] [not [= x 0]]])

(smt-test.check "a model" [[i 0] [n 1]]
  (freeze (smt.model (smt.check [[<= 0 i] [< i n]]))))
(smt-test.check "a model names everything" [[x 0] [y 0] [p true] [q false]]
  (freeze (smt.model (smt.check [[= x x] [or p q] [not q] [<= y y]]))))
(smt-test.check "valid" [true false true]
  (freeze [(smt.valid? [[<= [+ i k] n]] [<= 0 [- n [+ i k]]]) (smt.valid? [[<= i n]] [< i n]) (smt.valid? [] true)]))
(smt-test.check "what an open goal's model is" [[x -1]]
  (freeze (smt.model (smt.check [[not [<= 0 x]]]))))

\\ Past 62 bits, and past the budget, the answer is not known.
(smt-test.is "integer overflow" [[<= [* 2305843009213693951 x] [* 2305843009213693950 y]] [<= [* 2305843009213693949 y] [* 2305843009213693951 x]] [> x 3]])
(define smt-test.pigeons
  N -> (append (map (/. P [or | (map (/. H (concat P H)) (smt-test.up-to N))]) (map (/. I (concat p I)) (smt-test.up-to (+ N 1))))
               (mapcan (/. H (mapcan (/. I (mapcan (/. J (if (< I J) [[not [and (concat (concat p I) H) (concat (concat p J) H)]]] []))
                                                  (smt-test.up-to (+ N 1))))
                                    (smt-test.up-to (+ N 1))))
                       (smt-test.up-to N))))
(define smt-test.up-to
  0 -> []
  N -> [N | (smt-test.up-to (- N 1))])
(smt-test.check "cases are in a budget too" [unsat "out of budget"]
  (freeze (let _ (smt.budget 300)
               R (map (/. N (smt-test.kind (smt.check (smt-test.pigeons N)))) [2 7])
               _ (smt.budget 20000)
            R)))
(smt-test.check "choices that have nothing to do with it" unsat
  (freeze (smt-test.kind (smt.check (append (map (/. N [or [= (concat x N) 1] [= (concat x N) 2]]) (smt-test.up-to 20)) [[or [< 2 1] [< 3 1]]])))))
(smt-test.check "nor with what a case denies" unsat
  (freeze (smt-test.kind (smt.check (append (map (/. N [or [= (concat x N) 1] [= (concat x N) 2]]) (smt-test.up-to 20)) [[not p] q [or p [and p q]]])))))
(smt-test.check "a model too large to be checked" "integer overflow"
  (freeze (smt-test.kind (smt.check [[<= x [* 8 y]] [>= y 1152921504606846975] [<= x 1]]))))
(smt-test.check "a budget" "out of budget"
  (freeze (let _ (smt.budget 2)
               R (smt-test.kind (smt.check [[< [* 3 x] [* 2 y]] [< [* 3 y] [* 2 z]] [< [* 3 z] [* 2 x]] [> x 0]]))
               _ (smt.budget 20000)
            R)))
(smt-test.is unsat [[< [* 3 x] [* 2 y]] [< [* 3 y] [* 2 z]] [< [* 3 z] [* 2 x]] [> x 0]])

(smt-test.refused "smt: (* x y) is not a linear term" [[< [* x y] 1]])
(smt-test.refused "smt: (f x) is not a linear term" [[< [f x] 1]])
(smt-test.refused "smt: 1.5 is not a linear term" [[< x 1.5]])
(smt-test.refused "smt: (xor p q) is not a formula" [[xor p q]])
(smt-test.refused "smt: (< x) is not a formula" [[< x]])
(smt-test.refused "smt: 3 is not a formula" [3])
(smt-test.refused "smt: p is an unknown and a proposition" [p [< p 1]])
(smt-test.check "a model without a name" [error "smt: the model has no y"] (freeze (smt.check-model [[< x y]] [[x 1]])))
(smt-test.check "models" [true false false true]
  (freeze [(smt.check-model [[< x 5] p] [[x 1] [p true]]) (smt.check-model [[< x 5] p] [[x 5] [p true]])
           (smt.check-model [[< x 5] p] [[x 1] [p false]]) (smt.check-model [[= [- [* 2 x] 3 1] -2]] [[x 1]])]))

\\ ---------------------------------------------------------------------------
\\ Proofs that are not.

(define smt-test.proves?
  Fs Proof -> (trap-error (smt.check-proof Fs Proof) (/. E [raised (error-to-string E)])))

(define smt-test.refutation
  Steps -> (:smt.refutation steps <- Steps))

(set smt-test.*two* [[<= x 0] [>= x 1]])
(smt-test.check "a proof" [true true]
  (freeze [(smt-test.proves? (value smt-test.*two*) (smt-test.refutation [(@p 1 [(@p 1 1) (@p 2 1)])]))
           (smt-test.proves? (value smt-test.*two*) (smt-test.refutation [(@p 1 [(@p 1 2) (@p 2 2)])]))]))
(smt-test.check "not proofs" [false false false false false false false false false]
  (freeze (map (/. Steps (smt-test.proves? (value smt-test.*two*) (smt-test.refutation Steps)))
    [[] [(@p 1 [])] [(@p 1 [(@p 1 1)])] [(@p 1 [(@p 1 1) (@p 2 2)])] [(@p 1 [(@p 1 -1) (@p 2 -1)])]
     [(@p 1 [(@p 3 1) (@p 2 1)])] [(@p 1 [(@p -1 1)])] [(@p 0 [(@p 1 1) (@p 2 1)])] [(@p 2 [(@p 1 1)])]])))
\\ A negative multiple of a row says nothing, and a multiple of 0 adds nothing.
(smt-test.check "multiples" [false false]
  (freeze (map (/. Steps (smt-test.proves? [[<= x 5] [<= x 6]] (smt-test.refutation Steps)))
    [[(@p 1 [(@p 1 1) (@p 2 -1)])] [(@p 1 [(@p 1 0) (@p 2 0)])]])))
\\ A choice that is not there, and one with a case missing.
(smt-test.check "not splits" [false false false false]
  (freeze [(smt-test.proves? [[<= x 0]] (:smt.split choice <- 1 cases <- []))
           (smt-test.proves? [[or p q]] (:smt.split choice <- 0 cases <- []))
           (smt-test.proves? [[or p q]] (:smt.split choice <- 1 cases <- []))
           (smt-test.proves? [[or p q] [not p]] (:smt.split choice <- 1 cases <- [(smt-test.refutation [])]))]))
\\ Rounding a bound down is for coefficients that the divisor divides.
(smt-test.check "divisors" [true false]
  (freeze [(smt-test.proves? [[<= [* 2 x] 1] [>= [* 2 x] 1]] (smt-test.refutation [(@p 2 [(@p 1 1)]) (@p 2 [(@p 2 1)]) (@p 1 [(@p -1 1) (@p -2 1)])]))
           (smt-test.proves? [[<= x 1] [>= x 1]] (smt-test.refutation [(@p 2 [(@p 1 1)]) (@p 2 [(@p 2 1)]) (@p 1 [(@p -1 1) (@p -2 1)])]))]))

\\ ---------------------------------------------------------------------------
\\ Generated formulas, against every assignment of a box.

(define smt-test.holds-somewhere?
  Fs Us Ps Lo Hi -> (smt-test.some-value? Fs Us Ps Lo Lo Hi []))

(define smt-test.some-value?
  Fs [] Ps _ _ _ Model -> (smt-test.some-truth? Fs Ps Model)
  _ _ _ _ V Hi _ -> false where (> V Hi)
  Fs [U | Us] Ps Lo V Hi Model -> (or (smt-test.some-value? Fs Us Ps Lo Lo Hi [[U V] | Model])
                                      (smt-test.some-value? Fs [U | Us] Ps Lo (+ V 1) Hi Model)))

(define smt-test.some-truth?
  Fs [] Model -> (smt.check-model Fs Model)
  Fs [P | Ps] Model -> (or (smt-test.some-truth? Fs Ps [[P true] | Model])
                           (smt-test.some-truth? Fs Ps [[P false] | Model])))

(set smt-test.*unknown* 0)
(set smt-test.*unsat* 0)
(set smt-test.*misused* 0)

(define smt-test.generated
  0 _ _ _ _ -> done
  N Us Box K D -> (let Fs (smt-generate.formulas Us [p q] K D (smt-generate.between 2 5))
                    (do (smt-test.compare Fs Us Box (smt.check Fs))
                        (smt-test.generated (- N 1) Us Box K D))))

(define smt-test.compare
  Fs _ _ R -> (if (smt.check-model Fs (smt.model R)) (smt-test.pass) (smt-test.fail "a model" [Fs R])) where (smt.sat? R)
  Fs Us Box R
  -> (do (set smt-test.*unsat* (+ 1 (value smt-test.*unsat*)))
         (if (smt.check-proof Fs (smt.proof R)) (smt-test.pass) (smt-test.fail "a proof" Fs))
         (if (smt-test.holds-somewhere? Fs Us [p q] (- 0 Box) Box) (smt-test.fail "unsat, and not" Fs) (smt-test.pass))
         (smt-test.misuse Fs [] Us Box (smt.proof R)))
    where (smt.unsat? R)
  _ _ _ _ -> (set smt-test.*unknown* (+ 1 (value smt-test.*unknown*))))

\\ The proof must not check where a formula it was made from is gone and the rest can hold.
(define smt-test.misuse
  [] _ _ _ _ -> done
  [F | Fs] Before Us Box Proof
  -> (do (smt-test.misuse-h (append (reverse Before) Fs) Us Box Proof)
         (smt-test.misuse Fs [F | Before] Us Box Proof)))

(define smt-test.misuse-h
  Fs Us Box Proof -> (do (set smt-test.*misused* (+ 1 (value smt-test.*misused*)))
                         (if (= true (smt-test.proves? Fs Proof)) (smt-test.fail "proof misused" Fs) (smt-test.pass)))
    where (smt-test.holds-somewhere? Fs Us [p q] (- 0 Box) Box)
  _ _ _ _ -> skip)

(smt-test.generated 400 [x y] 4 4 2)
(smt-test.generated 120 [x y z] 2 3 2)
(smt-test.generated 60 [x y] 4 6 3)

(if (and (> (value smt-test.*unsat*) 60) (> (value smt-test.*misused*) 100) (< (value smt-test.*unknown*) 30))
    (smt-test.pass)
    (smt-test.fail "what was generated" [(value smt-test.*unsat*) (value smt-test.*misused*) (value smt-test.*unknown*)]))

(output "~A unsat, ~A proofs misused, ~A unknown~%" (value smt-test.*unsat*) (value smt-test.*misused*) (value smt-test.*unknown*))
(output "~A passed, ~A failed~%" (value smt-test.*passed*) (value smt-test.*failed*))
