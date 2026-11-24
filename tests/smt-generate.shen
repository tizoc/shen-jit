\\ Formulas for lib/smt.shen's tests, the same for the same seed.

(set smt-generate.*seed* 1)

\\ From 0 up to but not N, by Park and Miller's generator.
(define smt-generate.below
  N -> (let Next (fxremainder (* 48271 (value smt-generate.*seed*)) 2147483647)
            _ (set smt-generate.*seed* Next)
         (fxremainder (fxquotient Next 16) N)))

(define smt-generate.pick
  Xs -> (nth (+ 1 (smt-generate.below (length Xs))) Xs))

(define smt-generate.between
  A B -> (+ A (smt-generate.below (+ 1 (- B A)))))

\\ Us the unknowns, Ps the propositions, K what coefficients and constants go up to.
(define smt-generate.term
  Us K 0 -> (smt-generate.leaf Us K (smt-generate.below 3))
  Us K D -> (smt-generate.inner Us K D (smt-generate.below 5)))

(define smt-generate.leaf
  Us K 0 -> (smt-generate.between (- 0 K) K)
  Us K 1 -> (smt-generate.pick Us)
  Us K 2 -> [* (smt-generate.between (- 0 K) K) (smt-generate.pick Us)])

(define smt-generate.inner
  Us K D 0 -> [+ (smt-generate.term Us K (- D 1)) (smt-generate.term Us K (- D 1))]
  Us K D 1 -> [- (smt-generate.term Us K (- D 1)) (smt-generate.term Us K (- D 1))]
  Us K D 2 -> [- (smt-generate.term Us K (- D 1))]
  Us K D 3 -> [+ (smt-generate.term Us K (- D 1)) (smt-generate.term Us K (- D 1)) (smt-generate.term Us K (- D 1))]
  Us K D _ -> (smt-generate.term Us K 0))

(define smt-generate.formula
  Us Ps K 0 -> (if (= 0 (smt-generate.below 6))
                   (smt-generate.pick Ps)
                   [(smt-generate.pick [<= < >= > = <= <]) (smt-generate.term Us K 1) (smt-generate.term Us K 1)])
  Us Ps K D -> (smt-generate.compound Us Ps K (- D 1) (smt-generate.below 5)))

(define smt-generate.compound
  Us Ps K D 0 -> [and | (smt-generate.formulas Us Ps K D (smt-generate.between 1 3))]
  Us Ps K D 1 -> [or | (smt-generate.formulas Us Ps K D (smt-generate.between 1 3))]
  Us Ps K D 2 -> [or | (smt-generate.formulas Us Ps K D 2)]
  Us Ps K D 3 -> [not (smt-generate.formula Us Ps K D)]
  Us Ps K D _ -> (smt-generate.formula Us Ps K 0))

(define smt-generate.formulas
  _ _ _ _ 0 -> []
  Us Ps K D N -> [(smt-generate.formula Us Ps K D) | (smt-generate.formulas Us Ps K D (- N 1))])
