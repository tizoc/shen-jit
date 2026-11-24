\\ Generated functions for lib/refine.shen, over tests/smt-generate.shen's numbers. Each calls probe, whose
\\ condition must be proved there, and may promise something of its result. Run as
\\   shen-jit eval -m refine -l tests/smt-generate.shen -l tests/refine-generate.shen
\\     -e '(refine-generate.run Directory Seed Count)'
\\ Every function that loads is called with each pair of a box, and what it calls tests what was proved.
(refine.test -)

(set *maximum-print-sequence-size* 100000)
(set refine-generate.*broken* [])
(set refine-generate.*loaded* 0)
(set refine-generate.*refused* 0)
(set refine-generate.*ill-typed* 0)
(set refine-generate.*slow* 0)
(set refine-generate.*called* 0)

(define refine-generate.variable
  S -> (intern S))

\\ Whether to write shifts, masks, remainders of any sign, element? and calls in a do, made or not, besides.
(set refine-generate.*wide* false)

(define refine-generate.term
  Vs 0 -> (if (= 0 (smt-generate.below 3)) (smt-generate.between -3 3) (smt-generate.pick Vs))
  Vs D -> (refine-generate.bits Vs (- D 1) (smt-generate.below 6)) where (and (value refine-generate.*wide*) (= 0 (smt-generate.below 2)))
  Vs D -> (refine-generate.term-of Vs (- D 1) (smt-generate.below 8)))

(define refine-generate.term-of
  Vs D 0 -> [fx+ (refine-generate.term Vs D) (refine-generate.term Vs D)]
  Vs D 1 -> [fx- (refine-generate.term Vs D) (refine-generate.term Vs D)]
  Vs D 2 -> [fx* (smt-generate.between -2 2) (refine-generate.term Vs D)]
  Vs D 3 -> [fxquotient (refine-generate.term Vs D) (smt-generate.between 1 3)]
  Vs D 4 -> [fxremainder (refine-generate.term Vs D) (smt-generate.between 1 3)]
  Vs D _ -> (refine-generate.term Vs 0))

(define refine-generate.bits
  Vs D 0 -> [shen-jit.shift-right (refine-generate.term Vs D) (smt-generate.below 3)]
  Vs D 1 -> [shen-jit.shift-left (refine-generate.term Vs D) (smt-generate.below 3)]
  Vs D 2 -> [shen-jit.bit-and (refine-generate.term Vs D) (smt-generate.pick [1 3 7 2 (smt-generate.pick Vs)])]
  Vs D 3 -> [shen-jit.bit-and (smt-generate.pick [1 3 7]) (refine-generate.term Vs D)]
  Vs D 4 -> [(smt-generate.pick [shen-jit.bit-or shen-jit.bit-xor]) (refine-generate.term Vs D) (refine-generate.term Vs 0)]
  Vs D 5 -> [fxremainder (refine-generate.term Vs D) (smt-generate.pick [-2 2 3 4])])

(define refine-generate.condition
  Vs 0 -> [(smt-generate.pick [fx< fx<= fx> fx>= fx= =]) (refine-generate.term Vs 1) (smt-generate.pick Vs)]
  Vs D -> (refine-generate.condition-of Vs (- D 1) (smt-generate.below 7)))

\\ odd is nothing that refine can read, and tick gives another number each time.
(define refine-generate.condition-of
  Vs D 3 -> [odd (smt-generate.pick Vs)]
  Vs D 4 -> [fx< [tick 0] (refine-generate.term Vs 1)]
  Vs D 0 -> [and (refine-generate.condition Vs D) (refine-generate.condition Vs D)]
  Vs D 1 -> [or (refine-generate.condition Vs D) (refine-generate.condition Vs D)]
  Vs D 2 -> [not (refine-generate.condition Vs D)]
  Vs D _ -> (refine-generate.condition Vs 0))

\\ A term, or one that differs from it by little.
(define refine-generate.near
  T -> (refine-generate.near-h T (smt-generate.below 6)))

(define refine-generate.near-h
  T 0 -> [fx+ T 1]
  T 1 -> [fx- T 1]
  T _ -> T)

(define refine-generate.expression
  Vs 0 -> (refine-generate.term Vs 1)
  Vs D -> (refine-generate.expression-of Vs (- D 1) (smt-generate.below 14)))

(define refine-generate.expression-of
  Vs D 0 -> [if (refine-generate.condition Vs 2) (refine-generate.expression Vs D) (refine-generate.expression Vs D)]
  Vs D 1 -> (let V (smt-generate.pick [(protect V) (protect W) (protect X)])
              [let V (refine-generate.term Vs 2) (refine-generate.expression (adjoin V Vs) D)])
  Vs D 2 -> [let (protect V) [if (refine-generate.condition Vs 1) (refine-generate.term Vs 1) (refine-generate.term Vs 1)]
              (refine-generate.expression (adjoin (protect V) Vs) D)]
  Vs D 3 -> [let (protect W) [probe | (refine-generate.ordered Vs)] (refine-generate.expression (adjoin (protect W) Vs) D)]
  Vs D 4 -> [fx+ (refine-generate.expression Vs D) (refine-generate.expression Vs D)]
  Vs D 5 -> [do (refine-generate.expression Vs D) (refine-generate.expression Vs D)]
  Vs D 6 -> (refine-generate.guarded Vs D (refine-generate.term Vs 1) (refine-generate.term Vs 1))
  Vs D 7 -> (refine-generate.guarded Vs D (refine-generate.term Vs 1) (refine-generate.term Vs 1))
  Vs D 8 -> (refine-generate.short Vs D (refine-generate.term Vs 1) (refine-generate.term Vs 1))
  Vs D 9 -> [helper (refine-generate.term Vs 1)]
  Vs D 10 -> (let V (smt-generate.pick Vs)
               [let V [fx+ V (smt-generate.between -2 2)] (refine-generate.guarded Vs D V (refine-generate.term Vs 1))])
  Vs D 11 -> (smt-generate.pick
               [[if [fx< [tick 0] 4] [probe [tick 0] 4] (refine-generate.expression Vs D)]
                [let (protect W) [tick 0] (refine-generate.guarded (adjoin (protect W) Vs) D (protect W) (refine-generate.term Vs 1))]])
  Vs D 12 -> (let V (smt-generate.pick Vs)
               (smt-generate.pick
                 [[if [not [odd V]] (refine-generate.guarded Vs D V (refine-generate.term Vs 1)) [probe V [fx+ V 1]]]
                  [if [or [odd V] [fx< V 2]] [probe V 2] (refine-generate.guarded Vs D V 2)]
                  [if [not [and [odd V] [fx>= V 2]]] [probe V 2] 0]
                  [if [and [odd V] [fx< V 2]] [probe V 2] [probe 1 V]]]))
  Vs D _ -> (refine-generate.term Vs 2))

(define refine-generate.ordered
  Vs -> (let T (refine-generate.term Vs 1) [T [fx+ T (smt-generate.between 0 3)]]))

(define refine-generate.guarded
  Vs D A B -> (smt-generate.pick
    [[if [fx< A B] [probe (refine-generate.near A) (refine-generate.near B)] (refine-generate.expression Vs D)]
     [if [fx>= A B] (refine-generate.expression Vs D) [probe (refine-generate.near A) B]]
     [if [or [fx>= A B] (refine-generate.condition Vs 1)] (refine-generate.expression Vs D) [probe A (refine-generate.near B)]]
     [if [and (refine-generate.condition Vs 1) [fx< A B]] [fx- [probe A (refine-generate.near B)] 1] (refine-generate.expression Vs D)]
     [if [not [and [fx< A B] (refine-generate.condition Vs 1)]] (refine-generate.expression Vs D) [probe (refine-generate.near A) B]]]))

(define refine-generate.short
  Vs D A B -> (smt-generate.pick
    [[if [and [fx< A B] [fx> [probe A (refine-generate.near B)] 0]] (refine-generate.expression Vs D) (refine-generate.term Vs 1)]
     [if [or [fx>= A B] [fx> [probe (refine-generate.near A) B] 0]] (refine-generate.term Vs 1) (refine-generate.expression Vs D)]
     [if [and [fx> [probe A B] 0] [fx< A B]] (refine-generate.expression Vs D) 0]
     [if [or [fx> [probe A B] 0] [fx>= A B]] (refine-generate.expression Vs D) 0]]))

\\ Clauses of two arguments, the last a catch-all.
(define refine-generate.clauses
  0 -> [(protect X) (protect Y) -> (refine-generate.expression [(protect X) (protect Y)] 3)]
  N -> (append (refine-generate.clause (smt-generate.below 9)) (refine-generate.clauses (- N 1))))

(define refine-generate.clause
  0 -> [(smt-generate.between -2 2) (protect Y) -> (refine-generate.expression [(protect Y)] 2)]
  1 -> [(protect X) _ -> (refine-generate.expression [(protect X)] 2) where (refine-generate.condition [(protect X)] 1)]
  2 -> [(protect A) (protect B) -> (refine-generate.expression [(protect A) (protect B)] 2)
        where (refine-generate.condition [(protect A) (protect B)] 2)]
  3 -> [_ (smt-generate.between -2 2) -> (smt-generate.between -3 3)]
  4 -> [(smt-generate.between -1 1) (smt-generate.between -1 1) -> (smt-generate.between -3 3)]
  5 -> [(smt-generate.between -1 1) (protect B) -> (refine-generate.term [(protect B)] 1) where (refine-generate.condition [(protect B)] 1)]
  6 -> [(protect A) (protect A) -> (refine-generate.term [(protect A)] 1)]
  7 -> [(protect A) (protect A) -> (refine-generate.term [(protect A)] 1) where (refine-generate.condition [(protect A)] 0)]
  8 -> [(protect A) (protect B) <- [fail-if [(intern "/.") (protect Z) [odd (protect Z)]] (protect A)]
        where (refine-generate.condition [(protect A) (protect B)] 0)])

(define refine-generate.function
  Name -> (refine-generate.promising Name) where (and (value refine-generate.*wide*) (= 0 (smt-generate.below 3)))
  Name -> (let Clauses (refine-generate.clauses (smt-generate.below 3))
            [define-checked Name | (append (refine-generate.contract (smt-generate.below 3)) Clauses)]))

\\ What promises something that it may well give, its arguments' names bound again in it.
(define refine-generate.promising
  Name -> [define-checked Name { (protect P) : fixnum --> (protect Q) : fixnum --> (protect R) : fixnum }
            { ensures (refine-generate.promise (smt-generate.below 6)) (refine-generate.promise (smt-generate.below 6)) }
            | (append (if (= 0 (smt-generate.below 2))
                          [(protect Y) (protect X) -> (refine-generate.small [(protect X) (protect Y)] 2) where (refine-generate.condition [(protect X) (protect Y)] 1)]
                          [])
                      [(protect X) (protect Y) -> (refine-generate.small [(protect X) (protect Y)] 3)])])

(define refine-generate.promise
  0 -> [fx<= (protect R) [fx+ (protect P) (smt-generate.between 0 9)]]
  1 -> [fx>= (protect R) [fx- (protect Q) (smt-generate.between 0 9)]]
  2 -> [fx<= (protect R) (smt-generate.between 0 9)]
  3 -> [fx>= (protect R) (smt-generate.between -9 0)]
  4 -> [or [fx= (protect R) (protect P)] [fx<= (protect R) (smt-generate.between -2 5)]]
  5 -> [or [fx<= (protect P) (protect R)] [or [fx<= (protect Q) (protect R)] [fx>= (protect R) (smt-generate.between -5 2)]]])

(define refine-generate.small
  Vs 0 -> (smt-generate.pick [(smt-generate.pick Vs) (smt-generate.pick Vs) (smt-generate.between -3 3) [helper (smt-generate.pick Vs)] [fx- (smt-generate.pick Vs) 1]])
  Vs D -> (refine-generate.small-of Vs (- D 1) (smt-generate.below 5)))

(define refine-generate.small-of
  Vs D 0 -> [if (refine-generate.condition Vs 1) (refine-generate.small Vs D) (refine-generate.small Vs D)]
  Vs D 1 -> (let V (smt-generate.pick [(protect X) (protect Y) (protect V)])
              [let V (refine-generate.small Vs 0) (refine-generate.small (adjoin V Vs) D)])
  Vs D 2 -> (let V (smt-generate.pick [(protect X) (protect Y) (protect V)])
              [let V (refine-generate.small Vs D) (refine-generate.small (adjoin V Vs) D)])
  Vs D 3 -> [do (refine-generate.small Vs 0) (refine-generate.small Vs D)]
  Vs D _ -> (refine-generate.small Vs 0))

(define refine-generate.contract
  0 -> [{ (protect P) : fixnum --> fixnum --> (protect R) : fixnum }
        { ensures [(smt-generate.pick [fx<= fx>=]) (protect R) [fx+ (protect P) (smt-generate.between -6 6)]] }]
  _ -> [{ fixnum --> fixnum --> fixnum }])

\\ ---------------------------------------------------------------------------

(define refine-generate.broke
  What -> (set refine-generate.*broken* [What | (value refine-generate.*broken*)]))

(set refine-generate.*tick* 0)
(define refine-generate.tick
  -> (set refine-generate.*tick* (shen-jit.bit-and 7 (+ 3 (value refine-generate.*tick*)))))

(declare refine-generate.broke [string --> [list string]])
(declare refine-generate.tick [--> fixnum])

(define refine-generate.prelude
  -> "(define tick {fixnum --> fixnum} _ -> (refine-generate.tick))
(define odd {fixnum --> boolean} N -> (fx= 1 (shen-jit.bit-and N 1)))
(define even {fixnum --> boolean} N -> (fx= 0 (shen-jit.bit-and N 1)))
(refine.pure even)
(define-checked probe {A : fixnum --> B : fixnum --> R : fixnum}
  {requires (fx< A B)}
  {ensures (fx<= A R) (fx<= R B)}
  A B -> (if (fx< A B) A (let _ (refine-generate.broke (make-string `probe ~A ~A` A B)) A)))
(define-checked helper {fixnum --> R : fixnum}
  {ensures (fx<= 0 R) (fx<= R 5)}
  N -> 0 where (fx< N 0)
  N -> 5 where (fx> N 5)
  N -> N)
(define-checked below {N : fixnum --> R : fixnum}
  {requires (fx> N 0)}
  {ensures (fx<= 0 R) (fx< R N)}
  N -> (if (fx> N 0) (fxquotient N 2) (let _ (refine-generate.broke (make-string `below ~A` N)) 0)))
(define-checked same-positive {N : fixnum --> R : fixnum}
  {ensures (fx= R N) (fx> R 0)}
  N -> (if (fx> N 0) N (error `not positive`)))
(define-checked positive-below-9 {N : fixnum --> R : fixnum}
  {ensures (fx>= R N) (fx> R 0) (fx< R 9)}
  N -> (if (and (fx> N 0) (fx< N 9)) N (error `not below 9`)))
(define-checked in-range {I : fixnum --> N : fixnum --> R : boolean}
  {ensures (= R (and (fx<= 0 I) (fx< I N)))}
  I N -> (and (fx<= 0 I) (fx< I N)))
(define-checked twice {N : fixnum --> R : fixnum} {ensures (fx= R (fx* 2 N))} N -> (fx* 2 N))
(define-checked known-unit? {X : number --> R : boolean} {ensures (= R (and (>= X 0) (<= X 1)))} X -> (and (>= X 0) (<= X 1)))
(define-checked even-probe {N : fixnum --> fixnum} {requires (even N)}
  N -> (if (even N) 1 (let _ (refine-generate.broke (make-string `even-probe ~A` N)) 1)))
(define-checked range-probe {I : fixnum --> N : fixnum --> fixnum} {requires (in-range I N)}
  I N -> (if (and (fx<= 0 I) (fx< I N)) I (let _ (refine-generate.broke (make-string `range-probe ~A ~A` I N)) 0)))
(define-checked list-probe {Xs : (list fixnum) --> fixnum} {requires (not (empty? Xs))}
  [X | _] -> X
  [] -> (let _ (refine-generate.broke `list-probe`) 0))
(define-checked length-probe {Xs : (list fixnum) --> Ys : (list fixnum) --> fixnum} {requires (= (length Xs) (length Ys))}
  Xs Ys -> (if (= (length Xs) (length Ys)) 1 (let _ (refine-generate.broke (make-string `length-probe ~A ~A` Xs Ys)) 0)))
(define-checked longer-probe {Xs : (list fixnum) --> N : number --> fixnum} {requires (> (length Xs) N)}
  Xs N -> (if (> (length Xs) N) 1 (let _ (refine-generate.broke (make-string `longer-probe ~A ~A` Xs N)) 0)))
(define-checked mode-probe {M : symbol --> fixnum} {requires (or (= M read) (= M write))}
  M -> (if (or (= M read) (= M write)) 1 (let _ (refine-generate.broke (make-string `mode-probe ~A` M)) 0)))
(define-checked not-close {M : symbol --> fixnum} {requires (not (= M close))}
  M -> (if (= M close) (let _ (refine-generate.broke `not-close`) 0) 1))
(define-checked less-probe {A : number --> B : number --> fixnum} {requires (< A B)}
  A B -> (if (< A B) 1 (let _ (refine-generate.broke (make-string `less-probe ~A ~A` A B)) 0)))
(define-checked unit-probe {A : number --> fixnum} {requires (known-unit? A)}
  A -> (if (and (>= A 0) (<= A 1)) 1 (let _ (refine-generate.broke (make-string `unit-probe ~A` A)) 0)))
(refine.type portion X : number where (known-unit? X))
(refine.type (nonempty A) Xs : (list A) where (not (empty? Xs)))
(refine.type even-type N : fixnum where (even N))
(define unit-taker {portion --> fixnum}
  A -> (if (and (>= A 0) (<= A 1)) 1 (let _ (refine-generate.broke (make-string `portion ~A` A)) 0)))
(define nonempty-taker {(nonempty fixnum) --> fixnum}
  [X | _] -> X
  Xs -> (let _ (refine-generate.broke `nonempty`) 0))
(define even-taker {even-type --> fixnum}
  N -> (if (even N) 1 (let _ (refine-generate.broke (make-string `even-type ~A` N)) 0)))
")

(define refine-generate.write
  File Text -> (let S (open File out) _ (pr Text S) (close S)))

\\ The kernel counts inferences from the start, and a definition that is ill-typed may take any number.
(define refine-generate.load
  File -> (let _ (maxinferences (+ 500000 (inferences)))
               _ (tc +)
               R (trap-error (do (load File) true) (/. E (error-to-string E)))
               _ (tc -)
            R))

(define refine-generate.run
  Directory Seed Count
  -> (let _ (set smt-generate.*seed* Seed)
          File (@s Directory "/generated.shen")
          _ (refine-generate.start File)
       (refine-generate.each File Count)))

\\ The same with more of each.
(define refine-generate.run-wide
  Directory Seed Count
  -> (let _ (set refine-generate.*wide* true)
          _ (refine-generate.run Directory Seed Count)
          _ (refine-generate.run-data Directory Seed Count)
       (set refine-generate.*wide* false)))

(define refine-generate.start
  File -> (let _ (refine-generate.write File (refine-generate.prelude-text (refine-generate.prelude)))
               Prelude (refine-generate.load File)
            (if (= Prelude true) true (error "prelude: ~A" Prelude))))

\\ The prelude's format string, whose quotes are written as they are.
(define refine-generate.prelude-text
  "" -> ""
  (@s "`" S) -> (@s (n->string 34) (refine-generate.prelude-text S))
  (@s C S) -> (@s C (refine-generate.prelude-text S)))

(define refine-generate.each
  _ 0 -> done
  File N -> (let F (concat refine-generate.f N)
                 Form (refine-generate.function F)
                 _ (refine-generate.write File (make-string "~R~%" Form))
                 R (refine-generate.load File)
                 _ (if (= R true)
                       (do (set refine-generate.*loaded* (+ 1 (value refine-generate.*loaded*)))
                           (refine-generate.call-all F Form (refine-generate.promised F)))
                       (refine-generate.refused R Form))
              (refine-generate.each File (- N 1))))

\\ Any other error is the test's failure.
(define refine-generate.refused
  (@s "type error in rule" S) _ -> (set refine-generate.*refused* (+ 1 (value refine-generate.*refused*))) where (refine-generate.unproved? S)
  (@s "type error in rule" _) _ -> (set refine-generate.*ill-typed* (+ 1 (value refine-generate.*ill-typed*)))
  "maximum inferences exceeded" _ -> (set refine-generate.*slow* (+ 1 (value refine-generate.*slow*)))
  (@s "refine: a where that is no guard in" _) _ -> (set refine-generate.*ill-typed* (+ 1 (value refine-generate.*ill-typed*)))
  Message Form -> (refine-generate.broke (make-string "~A: ~R" Message Form)))

(define refine-generate.unproved?
  (@s " needs " _) -> true
  (@s " promises " _) -> true
  (@s _ S) -> (refine-generate.unproved? S)
  _ -> false)

(set refine-generate.*promising* 0)

\\ [Formals Result Promise], or [].
(define refine-generate.promised
  F -> (refine-generate.promise-in (refine.contract F)))

(define refine-generate.promise-in
  [Formals _ R Post] -> [] where (= Post true)
  [Formals _ R Post] -> [Formals R Post]
  _ -> [])

(define refine-generate.call-all
  F Form Promise -> (let _ (if (empty? Promise) skip (set refine-generate.*promising* (+ 1 (value refine-generate.*promising*))))
                      (refine-generate.call-from F Form Promise -4 -4)))

(define refine-generate.call-from
  _ _ _ 5 _ -> done
  F Form Promise X 5 -> (refine-generate.call-from F Form Promise (+ X 1) -4)
  F Form Promise X Y -> (let Before (length (value refine-generate.*broken*))
                           R ((function F) X Y)
                           _ (set refine-generate.*called* (+ 1 (value refine-generate.*called*)))
                           _ (if (refine-generate.within? Promise X Y R) skip
                                 (refine-generate.broke (make-string "~A ~A ~A gave ~A: ~R" F X Y R Form)))
                           _ (if (= Before (length (value refine-generate.*broken*))) skip
                                 (refine-generate.broke (make-string "in ~A ~A ~A: ~R" F X Y Form)))
                        (refine-generate.call-from F Form Promise X (+ Y 1))))

(define refine-generate.within?
  [] _ _ _ -> true
  [Formals R Post] X Y Got -> (eval (refine.replace [R | Formals] [Got X Y] Post)))

\\ ---------------------------------------------------------------------------
\\ Functions of a fixnum N, a list L, a symbol M and a number F.

(define refine-generate.list
  Ls D -> (if (= D 0)
              (smt-generate.pick Ls)
              (smt-generate.pick [(smt-generate.pick Ls) (smt-generate.pick Ls) [tail (smt-generate.pick Ls)] [cons [fixnum 1] (refine-generate.list Ls (- D 1))]
                                  [append (smt-generate.pick Ls) (refine-generate.list Ls (- D 1))] [reverse (smt-generate.pick Ls)] []])))

\\ The second argument, as the clause has it.
(set refine-generate.*list* [])

(define refine-generate.number
  Fs -> (smt-generate.pick [(smt-generate.pick Fs) (smt-generate.pick Fs) 0 1 0.5 [+ (smt-generate.pick Fs) 1] [length (value refine-generate.*list*)]]))

(define refine-generate.symbol
  Ms -> (smt-generate.pick [(smt-generate.pick Ms) (smt-generate.pick Ms) read write close]))

(define refine-generate.data-condition
  Vs 0 -> (refine-generate.data-atom Vs (smt-generate.below (if (value refine-generate.*wide*) 16 13)))
  Vs D -> (refine-generate.data-compound Vs (- D 1) (smt-generate.below 6)))

(define refine-generate.data-compound
  Vs D 0 -> [and (refine-generate.data-condition Vs D) (refine-generate.data-condition Vs D)]
  Vs D 1 -> [or (refine-generate.data-condition Vs D) (refine-generate.data-condition Vs D)]
  Vs D 2 -> [not (refine-generate.data-condition Vs D)]
  Vs D _ -> (refine-generate.data-condition Vs 0))

\\ Vs is [Fixnums Lists Symbols Numbers].
(define refine-generate.data-atom
  [Ns Ls Ms Fs] 0 -> [empty? (refine-generate.list Ls 0)]
  [Ns Ls Ms Fs] 1 -> [cons? (refine-generate.list Ls 1)]
  [Ns Ls Ms Fs] 2 -> [(smt-generate.pick [< <= > >= =]) [length (refine-generate.list Ls 1)] (smt-generate.between 0 2)]
  [Ns Ls Ms Fs] 3 -> [= (refine-generate.list Ls 0) []]
  [Ns Ls Ms Fs] 4 -> [= (refine-generate.symbol Ms) (refine-generate.symbol Ms)]
  [Ns Ls Ms Fs] 5 -> [= (smt-generate.pick Ms) (smt-generate.pick [read write close])]
  [Ns Ls Ms Fs] 6 -> [(smt-generate.pick [< <= > >= =]) (refine-generate.number Fs) (refine-generate.number Fs)]
  [Ns Ls Ms Fs] 7 -> [known-unit? (smt-generate.pick Fs)]
  [Ns Ls Ms Fs] 8 -> [(smt-generate.pick [even odd]) (smt-generate.pick Ns)]
  [Ns Ls Ms Fs] 9 -> [in-range (smt-generate.pick Ns) (smt-generate.between 0 3)]
  [Ns Ls Ms Fs] 10 -> (refine-generate.partial (smt-generate.pick Ns) (smt-generate.below 5))
  [Ns Ls Ms Fs] 13 -> (refine-generate.one-of (refine-generate.symbol Ms))
  [Ns Ls Ms Fs] 14 -> [element? (smt-generate.pick Ns) [cons 1 [cons 0 [cons (smt-generate.pick Ns) []]]]]
  [Ns Ls Ms Fs] _ -> [(smt-generate.pick [fx< fx<= fx> fx>= fx=]) (refine-generate.term Ns 1) (smt-generate.pick Ns)])

(define refine-generate.one-of
  M -> [element? M (smt-generate.pick [[] [cons read []] [cons read [cons write []]] [cons close [cons M []]] [cons read [cons close []]]])])

\\ Calls that are not made, or raise, where the first part decides.
(define refine-generate.partial
  N 0 -> [or [fx<= N 0] [fx> [below N] (smt-generate.between 0 2)]]
  N 1 -> [and [fx> N 0] [fx>= [below N] (smt-generate.between 0 1)]]
  N 2 -> [or [fx< N (smt-generate.between -2 1)] [fx> [same-positive N] (smt-generate.between 0 2)]]
  N 3 -> [or [fx< N 0] [fx< [positive-below-9 N] 9]]
  N 4 -> [and [fx> N 0] [fx< [same-positive N] 2]])

(define refine-generate.data
  Vs 0 -> (refine-generate.term (hd Vs) 1)
  Vs D -> (refine-generate.data-of Vs (- D 1) (smt-generate.below 9)))

(define refine-generate.data-of
  Vs D 0 -> [if (refine-generate.data-condition Vs 2) (refine-generate.data Vs D) (refine-generate.data Vs D)]
  [Ns Ls Ms Fs] D 1 -> (let V (smt-generate.pick [(protect K) (protect L)])
                         [let V (refine-generate.list Ls 2) (refine-generate.data [Ns (adjoin V Ls) Ms Fs] D)])
  [Ns Ls Ms Fs] D 2 -> (let V (smt-generate.pick [(protect G) (protect F)])
                         [let V (refine-generate.number Fs) (refine-generate.data [Ns Ls Ms (adjoin V Fs)] D)])
  [Ns Ls Ms Fs] D 3 -> (let V (smt-generate.pick [(protect I) (protect N)])
                         [let V (smt-generate.pick [(refine-generate.term Ns 1) [twice (smt-generate.pick Ns)] [helper (smt-generate.pick Ns)]])
                           (refine-generate.data [(adjoin V Ns) Ls Ms Fs] D)])
  Vs D 4 -> [let (protect B) (refine-generate.data-condition Vs 1)
              [if (protect B) (refine-generate.aimed Vs D) (refine-generate.data Vs D)]]
  Vs D _ -> (refine-generate.aimed Vs D))

\\ A probe behind a condition that should let it through, or that nearly does.
(define refine-generate.aimed
  Vs D -> (refine-generate.behind Vs D (refine-generate.aim Vs (smt-generate.below (if (value refine-generate.*wide*) 16 12)))))

(define refine-generate.behind
  Vs D [C Probe] -> (smt-generate.pick
    [[if C Probe (refine-generate.data Vs D)]
     [if C Probe (refine-generate.data Vs D)]
     [if [not C] (refine-generate.data Vs D) Probe]
     [if [and (refine-generate.data-condition Vs 0) C] Probe (refine-generate.data Vs D)]
     [if [or (refine-generate.data-condition Vs 0) [not C]] (refine-generate.data Vs D) Probe]
     [if [or C (refine-generate.data-condition Vs 0)] Probe (refine-generate.data Vs D)]
     [let (protect Z) C [if (protect Z) Probe (refine-generate.data Vs D)]]
     [if (refine-generate.data-condition Vs 1) Probe (refine-generate.data Vs D)]]))

(define refine-generate.aim
  [Ns Ls Ms Fs] 0 -> (let L (refine-generate.list Ls 1)
                       [(smt-generate.pick [[not [empty? L]] [cons? L] [> [length L] 0] [not [= L []]] [>= [length L] 0] [empty? L]]) [list-probe L]])
  [Ns Ls Ms Fs] 1 -> (let L (smt-generate.pick Ls) K (refine-generate.list Ls 1)
                       [(smt-generate.pick [[= [length L] [length K]] [<= [length L] [length K]] [empty? L]])
                        (smt-generate.pick [[length-probe L K] [length-probe K L] [length-probe L [reverse L]] [length-probe [append L K] [append K L]]])])
  [Ns Ls Ms Fs] 2 -> (let L (smt-generate.pick Ls)
                       [(smt-generate.pick [[> [length L] 1] [>= [length L] 2] [> [length L] 0] [not [empty? L]]])
                        (smt-generate.pick [[longer-probe L 0] [longer-probe [tail L] 0] [longer-probe [cons [fixnum 1] L] 1] [list-probe [tail L]]])])
  [Ns Ls Ms Fs] 3 -> (let M (smt-generate.pick Ms)
                       [(smt-generate.pick [[= M read] [or [= M read] [= M write]] [not [= M close]] [= write M]]) [mode-probe M]])
  [Ns Ls Ms Fs] 4 -> (let M (smt-generate.pick Ms) K (refine-generate.symbol Ms)
                       [(smt-generate.pick [[= M read] [not [= M close]] [and [= M K] [= K write]] [and [= M K] [not [= K close]]] [= M close]]) [not-close M]])
  [Ns Ls Ms Fs] 5 -> (let A (smt-generate.pick Fs) B (refine-generate.number Fs) C (refine-generate.number Fs)
                       [(smt-generate.pick [[< A B] [and [< A C] [<= C B]] [and [<= A C] [< C B]] [not [>= A B]] [<= A B] [and [< A 0.5] [>= B 1]] [and [= A C] [< C B]]])
                        [less-probe A B]])
  [Ns Ls Ms Fs] 6 -> (let A (refine-generate.number Fs)
                       [(smt-generate.pick [[known-unit? A] [and [>= A 0] [<= A 1]] [and [> A 0] [< A 0.5]] [not [or [< A 0] [> A 1]]] [= A 0.5] [and [>= A 0] [<= A 2]]])
                        (smt-generate.pick [[unit-probe A] [unit-taker A]])])
  [Ns Ls Ms Fs] 7 -> (let N (smt-generate.pick Ns)
                       [(smt-generate.pick [[even N] [not [odd N]] [and [even N] [fx> N 0]] [odd N]]) (smt-generate.pick [[even-probe N] [even-taker N] [even-probe [fx+ N 2]]])])
  [Ns Ls Ms Fs] 8 -> (let N (smt-generate.pick Ns) K (smt-generate.between 0 4)
                       [(smt-generate.pick [[in-range N K] [and [fx>= N 0] [fx< N K]] [and [in-range N 2] [fx>= K 2]] [fx< N K]]) [range-probe N K]])
  [Ns Ls Ms Fs] 9 -> (let N (smt-generate.pick Ns)
                       [(refine-generate.partial N (smt-generate.below 5)) (smt-generate.pick [[probe 0 N] [probe N 5] [probe (smt-generate.between -3 1) N] [below N]])])
  [Ns Ls Ms Fs] 10 -> (let L (refine-generate.list Ls 1)
                        [(smt-generate.pick [[not [empty? L]] [> [length L] 0] [cons? L] [empty? L]]) (smt-generate.pick [[nonempty-taker L] [nonempty-taker [cons [fixnum 1] L]]])])
  [Ns Ls Ms Fs] 11 -> (let N (smt-generate.pick Ns)
                        [(smt-generate.pick [[fx> [twice N] 3] [fx> N 1] [fx>= [twice N] 2]]) (smt-generate.pick [[probe 1 N] [probe 2 [twice N]] [probe 3 [twice N]]])])
  [Ns Ls Ms Fs] 12 -> (let M (smt-generate.pick Ms)
                        [(smt-generate.pick [(refine-generate.one-of M) [not (refine-generate.one-of M)]]) (smt-generate.pick [[mode-probe M] [not-close M]])])
  [Ns Ls Ms Fs] 13 -> (let N (smt-generate.pick Ns)
                        [(refine-generate.data-condition [Ns Ls Ms Fs] 0)
                         [do (smt-generate.pick [[same-positive N] [positive-below-9 N] [if [fx> N -2] [same-positive N] N] [helper N]
                                                 (refine-generate.given-some N (smt-generate.below 3))])
                             (smt-generate.pick [[probe 0 N] [probe N 9] [probe -2 N] [do [positive-below-9 N] [probe N 9]]])]])
  [Ns Ls Ms Fs] 14 -> (let N (smt-generate.pick Ns) K (smt-generate.between 1 2) P (if (= K 1) 2 4)
                        [(smt-generate.pick [[fx>= N 0] [fx< N [fx* P P]] [and [fx>= N 0] [fx< N [fx* P P]]]])
                         (smt-generate.pick [[probe [shen-jit.shift-right N K] P] [probe -1 [shen-jit.shift-right N K]] [probe [shen-jit.bit-and N [fx- P 1]] P]
                                             [probe [fx- [fx* P [shen-jit.shift-right N K]] 1] N] [probe N [fx+ P [fx* P [shen-jit.shift-right N K]]]]])])
  [Ns Ls Ms Fs] 15 -> (let N (smt-generate.pick Ns) K (smt-generate.pick [2 3 -2])
                        [(smt-generate.pick [[fx= [fxremainder N K] 0] [fx> [fxremainder N K] 0] [fx>= N 0]])
                         (smt-generate.pick [[probe [fx- [fx* K [fxquotient N K]] 1] N] [probe N [fx+ 1 [fx* K [fxquotient N K]]]] [probe -1 [fxremainder N K]]])]))

\\ A function with some of its arguments, whose calls are not made.
(define refine-generate.given-some
  N 0 -> [@p 1 [fx+ [same-positive N]]]
  N 1 -> [cons [fx+ [fx+ 1 [positive-below-9 N]]] []]
  N 2 -> [cons [(intern "/.") (protect Z) [fx+ [same-positive N] (protect Z)]] []])

(define refine-generate.data-clauses
  0 -> (let _ (set refine-generate.*list* (protect L))
         [(protect N) (protect L) (protect M) (protect F) -> (refine-generate.data [[(protect N)] [(protect L)] [(protect M)] [(protect F)]] 3)])
  K -> (let Kind (smt-generate.below 7)
            _ (set refine-generate.*list* (refine-generate.second-argument Kind))
         (append (refine-generate.data-clause Kind) (refine-generate.data-clauses (- K 1)))))

(define refine-generate.second-argument
  0 -> []
  1 -> [cons (protect X) (protect Y)]
  4 -> [cons (protect X) []]
  _ -> (protect L))

(define refine-generate.data-clause
  0 -> [(protect N) [] (protect M) (protect F) -> (refine-generate.data [[(protect N)] [[]] [(protect M)] [(protect F)]] 1)]
  1 -> [(protect N) [cons (protect X) (protect Y)] (protect M) (protect F) ->
         (refine-generate.data [[(protect N) (protect X)] [(protect Y) [cons (protect X) (protect Y)]] [(protect M)] [(protect F)]] 2)
         where (refine-generate.data-condition [[(protect N) (protect X)] [(protect Y)] [(protect M)] [(protect F)]] 1)]
  2 -> [(protect N) (protect L) (smt-generate.pick [read write close]) (protect F) -> (refine-generate.data [[(protect N)] [(protect L)] [read] [(protect F)]] 1)]
  3 -> [(protect N) (protect L) (protect M) (smt-generate.pick [0 1 0.5]) -> (refine-generate.data [[(protect N)] [(protect L)] [(protect M)] [0]] 1)]
  4 -> [(protect N) [cons (protect X) []] (protect M) (protect F) -> (refine-generate.data [[(protect N) (protect X)] [[cons (protect X) []]] [(protect M)] [(protect F)]] 1)]
  5 -> [(protect N) (protect L) (protect M) (protect F) -> (refine-generate.data [[(protect N)] [(protect L)] [(protect M)] [(protect F)]] 2)
         where (refine-generate.data-condition [[(protect N)] [(protect L)] [(protect M)] [(protect F)]] 2)]
  6 -> [0 (protect L) _ (protect F) -> (refine-generate.data [[0] [(protect L)] [read] [(protect F)]] 1)
         where (refine-generate.data-condition [[0] [(protect L)] [read] [(protect F)]] 0)])

(define refine-generate.data-function
  Name -> (append [define-checked Name { fixnum --> [list fixnum] --> symbol --> number --> fixnum }]
                  (refine-generate.data-clauses (smt-generate.below 3))))

(set refine-generate.*not-a-number* (let I (* 1e308 10) (- I I)))

(define refine-generate.call-data
  F Form -> (map (/. N (map (/. L (map (/. M (map (/. X (refine-generate.call-datum F Form N L M X))
                                                  [-1 0 0.25 0.5 1 2 (value refine-generate.*not-a-number*) (* 1e308 10)]))
                                       [read write close]))
                            [[] [1] [-2 3]]))
                 [-3 -1 0 1 2 6]))

(define refine-generate.call-datum
  F Form N L M X -> (let Before (length (value refine-generate.*broken*))
                         _ (set refine-generate.*called* (+ 1 (value refine-generate.*called*)))
                         _ (trap-error ((function F) N L M X) (/. E skip))
                      (if (= Before (length (value refine-generate.*broken*)))
                          skip
                          (refine-generate.broke (make-string "in ~A ~A ~A ~A ~A: ~R" F N L M X Form)))))

(define refine-generate.run-data
  Directory Seed Count
  -> (let _ (set smt-generate.*seed* Seed)
          File (@s Directory "/generated.shen")
          _ (refine-generate.start File)
       (refine-generate.each-datum File Count)))

(define refine-generate.each-datum
  _ 0 -> done
  File N -> (let F (concat refine-generate.d N)
                 Form (refine-generate.data-function F)
                 _ (refine-generate.write File (make-string "~R~%" Form))
                 R (refine-generate.load File)
                 _ (if (= R true)
                       (do (set refine-generate.*loaded* (+ 1 (value refine-generate.*loaded*)))
                           (refine-generate.call-data F Form))
                       (refine-generate.refused R Form))
              (refine-generate.each-datum File (- N 1))))

\\ ---------------------------------------------------------------------------
\\ Functions of structs with fields of refined types, one of them over another and one that changes, of pairs, lists and
\\ functions, and of what changes: (refine-generate.run-shapes Directory Seed Count).

(define refine-generate.shapes-prelude
  -> "(refine.type bit N where (and (fx<= 0 N) (fx<= N 1)))
(refine.type one N : bit where (fx= N 1))
(refine.type rising P : (fixnum * fixnum) where (fx<= (fst P) (snd P)))
(refine.type access S : symbol where (or (= S read) (= S write)))
(defstruct span (start : fixnum) (end : bit))
(defstruct cell (mutable n : fixnum))
(defstruct lamp (mutable lit : bit) (mode : access))
(define-checked bit-probe {A : fixnum --> fixnum} {requires (fx<= 0 A) (fx<= A 1)}
  A -> (if (and (fx<= 0 A) (fx<= A 1)) A (let _ (refine-generate.broke (make-string `bit-probe ~A` A)) 0)))
(define bit-taker {bit --> fixnum}
  A -> (if (and (fx<= 0 A) (fx<= A 1)) A (let _ (refine-generate.broke (make-string `bit ~A` A)) 0)))
(define one-taker {one --> fixnum}
  A -> (if (fx= A 1) A (let _ (refine-generate.broke (make-string `one ~A` A)) 0)))
(define rising-taker {rising --> fixnum}
  P -> (if (fx<= (fst P) (snd P)) 1 (let _ (refine-generate.broke (make-string `rising ~A` P)) 0)))
(define access-taker {access --> fixnum}
  S -> (if (or (= S read) (= S write)) 1 (let _ (refine-generate.broke (make-string `access ~A` S)) 0)))
(define-checked span-probe {S : span --> fixnum} {requires (fx<= (span.start S) (span.end S))}
  S -> (if (fx<= (span.start S) (span.end S)) 1 (let _ (refine-generate.broke (make-string `span ~A` S)) 0)))
(define-checked cell-probe {C : cell --> fixnum} {requires (fx> (cell.n C) 0)}
  C -> (if (fx> (cell.n C) 0) 1 (let _ (refine-generate.broke (make-string `cell ~A` C)) 0)))
(define-checked same-probe {P : (fixnum * symbol) --> Q : (fixnum * symbol) --> fixnum} {requires (= P Q)}
  P Q -> (if (= P Q) 1 (let _ (refine-generate.broke (make-string `same ~A ~A` P Q)) 0)))
(define-checked cells-probe {C : cell --> D : cell --> fixnum} {requires (= C D)}
  C D -> (if (= C D) 1 (let _ (refine-generate.broke (make-string `cells ~A ~A` C D)) 0)))
(define-checked bits-probe {Bs : (list fixnum) --> fixnum} {requires (not (empty? Bs))}
  [X | _] -> X
  [] -> (let _ (refine-generate.broke `bits`) 0))
(define-checked bump {C : cell --> fixnum} C -> (let _ (cell.n-> C (fx- (cell.n C) 2)) (cell.n C)))
(define-checked apply-bit {(fixnum --> fixnum) --> fixnum --> bit} F N -> (let X (F N) (if (and (fx<= 0 X) (fx<= X 1)) X 0)))
(define lit {lamp --> bit} H -> (lamp.lit H))
(define lamp-taker {lamp --> fixnum}
  H -> (do (bit-taker (lamp.lit H)) (access-taker (lamp.mode H))))
(define bits-of {(list fixnum) --> fixnum} [] -> 0 [X | Xs] -> (fx+ X (bits-of Xs)))
(define fixnums-of {(list fixnum) --> fixnum} [] -> 0 [X | Xs] -> (fx+ X (fixnums-of Xs)))
(define-checked pair-of-bit {P : (fixnum * symbol) --> fixnum} {requires (fx<= 0 (fst P)) (fx<= (fst P) 1)} (@p X _) -> (bit-taker X))
(define pair-of-fixnum {(fixnum * symbol) --> fixnum} (@p X _) -> X)
(define to-bit {(fixnum --> fixnum) --> fixnum} F -> (F 7))
(define to-fixnum {(fixnum --> fixnum) --> fixnum} F -> (F 7))
(define from-bit {(fixnum --> fixnum) --> fixnum} F -> (F 1))
(define from-fixnum {(fixnum --> fixnum) --> fixnum} F -> (F 7))
(define-checked flip {B : bit --> R : bit} {ensures (fx= R (fx- 1 B))} B -> (fx- 1 B))
")

\\ Vs is [Fixnums Pairs Structs Cells Lists Symbols], the pairs of (fixnum * symbol). R is of (fixnum * fixnum),
\\ W of ((fixnum * symbol) * fixnum), and H is a lamp.
(define refine-generate.shape-term
  Vs 0 -> (refine-generate.shape-leaf Vs (smt-generate.below 10))
  Vs D -> [(smt-generate.pick [fx+ fx-]) (refine-generate.shape-term Vs (- D 1)) (refine-generate.shape-leaf Vs (smt-generate.below 9))]
    where (= 0 (smt-generate.below 2))
  Vs _ -> (refine-generate.shape-term Vs 0))

(define refine-generate.shape-leaf
  _ 0 -> (smt-generate.between -2 3)
  _ 1 -> [(smt-generate.pick [fst snd]) (protect R)]
  [_ _ Ss | _] 2 -> [span.start (smt-generate.pick Ss)]
  [_ _ Ss | _] 3 -> [span.end (smt-generate.pick Ss)]
  [_ _ _ Cs | _] 4 -> [cell.n (smt-generate.pick Cs)]
  _ 5 -> [(smt-generate.pick [lamp.lit lit]) (protect H)]
  [Ns | _] _ -> (smt-generate.pick Ns))

(define refine-generate.shape-condition
  Vs 0 -> (refine-generate.shape-atom Vs (smt-generate.below 14))
  Vs D -> (refine-generate.shape-compound Vs (- D 1) (smt-generate.below 6)))

(define refine-generate.shape-compound
  Vs D 0 -> [and (refine-generate.shape-condition Vs D) (refine-generate.shape-condition Vs D)]
  Vs D 1 -> [or (refine-generate.shape-condition Vs D) (refine-generate.shape-condition Vs D)]
  Vs D 2 -> [not (refine-generate.shape-condition Vs D)]
  Vs D _ -> (refine-generate.shape-condition Vs 0))

(define refine-generate.shape-atom
  [_ Ps | _] 0 -> [= (smt-generate.pick Ps) (smt-generate.pick Ps)]
  [_ Ps | _] 1 -> [= [fst (smt-generate.pick Ps)] [fst (smt-generate.pick Ps)]]
  [_ Ps | _] 2 -> [= [snd (smt-generate.pick Ps)] (smt-generate.pick [read write [snd (smt-generate.pick Ps)]])]
  [_ _ Ss | _] 3 -> [= (smt-generate.pick Ss) (smt-generate.pick Ss)]
  [_ _ _ Cs | _] 4 -> [= (smt-generate.pick Cs) (smt-generate.pick Cs)]
  [_ _ _ Cs | _] 5 -> [fx> [cell.n (smt-generate.pick Cs)] (smt-generate.between -1 1)]
  [_ _ _ _ Ls _] 6 -> [= (smt-generate.pick Ls) (smt-generate.pick Ls)]
  [_ _ _ _ Ls _] 7 -> [empty? (smt-generate.pick Ls)]
  [_ _ _ _ _ Ms] 8 -> [= (smt-generate.pick Ms) (smt-generate.pick [read write (smt-generate.pick Ms)])]
  Vs 9 -> [fx<= [fst (protect R)] [snd (protect R)]]
  Vs _ -> [(smt-generate.pick [fx< fx<= fx> fx>= fx=]) (refine-generate.shape-term Vs 0) (refine-generate.shape-term Vs 1)])

(define refine-generate.shape
  Vs 0 -> (refine-generate.shape-term Vs 1)
  Vs D -> (refine-generate.shape-of Vs (- D 1) (smt-generate.below 12)))

(define refine-generate.shape-of
  Vs D 0 -> [if (refine-generate.shape-condition Vs 2) (refine-generate.shape Vs D) (refine-generate.shape Vs D)]
  Vs D 1 -> [do (refine-generate.change Vs) (refine-generate.shape Vs D)]
  [Ns | Vs] D 2 -> (let V (smt-generate.pick [(protect I) (protect J) (protect N)])
                     [let V (refine-generate.bound-part [Ns | Vs]) (refine-generate.shape [(adjoin V Ns) | Vs] D)])
  [Ns Ps | Vs] D 3 -> (let V (smt-generate.pick [(protect P) (protect Q)])
                        [let V [type [@p (smt-generate.pick [0 1 [flip [fst (smt-generate.pick Ps)]]]) (smt-generate.pick [read [snd (smt-generate.pick Ps)]])] [fixnum * symbol]]
                          (refine-generate.shape [Ns (adjoin V Ps) | Vs] D)]) where (= 0 (smt-generate.below 2))
  [Ns Ps | Vs] D 3 -> (let V (smt-generate.pick [(protect P) (protect Q)])
                        [let V [fst (protect W)]
                          (refine-generate.shape [Ns (adjoin V Ps) | Vs] D)])
  [Ns Ps Ss | Vs] D 4 -> [let (protect S) [span.make (refine-generate.shape-term [Ns Ps Ss | Vs] 0) (smt-generate.pick [0 1 [span.end (smt-generate.pick Ss)]])]
                           (refine-generate.shape [Ns Ps (adjoin (protect S) Ss) | Vs] D)]
  [Ns Ps Ss Cs | Vs] D 5 -> [let (protect E) (smt-generate.pick Cs) (refine-generate.shape [Ns Ps Ss (adjoin (protect E) Cs) | Vs] D)]
  Vs D _ -> (refine-generate.shape-behind Vs D (refine-generate.shape-aim Vs (smt-generate.below 17))))

\\ What a let binds of a refined type, or of one that may not be.
(define refine-generate.bound-part
  [Ns Ps Ss Cs Ls Ms] -> (smt-generate.pick [[fst (smt-generate.pick Ps)] [span.end (smt-generate.pick Ss)] [head [cons 1 (smt-generate.pick Ls)]] [(protect F) (smt-generate.pick Ns)]
                                             [apply-bit (protect F) (smt-generate.pick Ns)] [cell.n (smt-generate.pick Cs)] [flip [span.end (smt-generate.pick Ss)]]
                                             [bump (smt-generate.pick Cs)] [fst (protect R)] [lamp.lit (protect H)] [lit (protect H)]]))

(define refine-generate.change
  Vs -> (let C (smt-generate.pick (hd (tl (tl (tl Vs)))))
          (smt-generate.pick [[bump C] [cell.n-> C (refine-generate.shape-term Vs 0)] [cell.n-> C [fx- [cell.n C] 1]] [lamp.lit-> (protect H) (smt-generate.pick [0 1 [lamp.lit (protect H)]])]])))

(define refine-generate.shape-behind
  Vs D [C Probe] -> (smt-generate.pick
    [[if C Probe (refine-generate.shape Vs D)]
     [if [not C] (refine-generate.shape Vs D) Probe]
     [if [and (refine-generate.shape-condition Vs 0) C] Probe (refine-generate.shape Vs D)]
     [if [or C (refine-generate.shape-condition Vs 0)] Probe (refine-generate.shape Vs D)]
     [if C [do (refine-generate.change Vs) Probe] (refine-generate.shape Vs D)]
     [let (protect Z) C [do (refine-generate.change Vs) [if (protect Z) Probe (refine-generate.shape Vs D)]]]
     [if (refine-generate.shape-condition Vs 1) (refine-generate.among Vs Probe) (refine-generate.shape Vs D)]]))

\\ Three that differ where there are at most two, if what is compared is of a type with two values.
(define refine-generate.among
  [Ns Ps Ss Cs Ls Ms] Probe
  -> (let A (smt-generate.pick [[(smt-generate.pick Ps) (smt-generate.pick Ps) (smt-generate.pick Ps)]
                                [[fst (smt-generate.pick Ps)] [fst (smt-generate.pick Ps)] 1]
                                [(smt-generate.pick Ms) (smt-generate.pick Ms) read]
                                [(smt-generate.pick Ls) (smt-generate.pick Ls) (smt-generate.pick Ls)]
                                [(smt-generate.pick Ss) (smt-generate.pick Ss) (smt-generate.pick Ss)]])
       [if [= (hd A) (hd (tl A))] 0 [if [= (hd A) (hd (tl (tl A)))] 1 [if [= (hd (tl A)) (hd (tl (tl A)))] 2 Probe]]]))

(define refine-generate.shape-aim
  Vs 0 -> (let A (refine-generate.shape-term Vs 1) [[and [fx<= 0 A] [fx<= A (smt-generate.pick [0 1 1 2])]] (smt-generate.pick [[bit-probe A] [bit-taker A]])])
  [_ _ _ Cs | _] 1 -> [[= (hd Cs) (hd (tl Cs))] [cells-probe (hd Cs) (hd (tl Cs))]] where (= 0 (smt-generate.below 2))
  Vs 1 -> (let A (refine-generate.shape-term Vs 0) [(smt-generate.pick [[fx= A 1] [and [fx> A 0] [fx< A 2]] [fx> A 0]]) (smt-generate.pick [[one-taker A] [bit-taker A] [bit-probe [fx- 1 A]]])])
  Vs 2 -> [(smt-generate.pick [[fx<= [fst (protect R)] [snd (protect R)]] [fx< [fst (protect R)] [snd (protect R)]] [fx>= [fst (protect R)] [snd (protect R)]]])
           (smt-generate.pick [[rising-taker (protect R)] [rising-taker [@p [fst (protect R)] [fx+ [snd (protect R)] 1]]] [rising-taker [@p [snd (protect R)] [fst (protect R)]]]])]
  [_ _ Ss | _] 3 -> (let S (smt-generate.pick Ss) [(smt-generate.pick [[fx<= [span.start S] [span.end S]] [fx<= [span.start S] 0] [fx<= [span.start S] 1] [= S (smt-generate.pick Ss)]]) [span-probe S]])
  [_ _ _ Cs | _] 4 -> (let C (smt-generate.pick Cs) [(smt-generate.pick [[fx> [cell.n C] 0] [fx> [cell.n C] 1]]) (smt-generate.pick [[cell-probe C] [bit-probe [cell.n C]] [bit-taker [cell.n C]]])])
  [_ Ps | _] 5 -> (let P (smt-generate.pick Ps) Q (smt-generate.pick Ps) [(smt-generate.pick [[= P Q] [and [= [fst P] [fst Q]] [= [snd P] [snd Q]]]]) [same-probe P Q]])
  [_ _ _ _ Ls _] 6 -> (let L (smt-generate.pick Ls) [(smt-generate.pick [[not [empty? L]] [cons? L] [empty? L] [= L (smt-generate.pick Ls)]]) [bits-probe L]])
  [_ _ _ _ _ Ms] 7 -> (let M (smt-generate.pick Ms) [(smt-generate.pick [[= M read] [or [= M read] [= M write]] [not [= M write]] [= M (smt-generate.pick Ms)]]) [access-taker M]])
  [Ns | _] 8 -> (let N (smt-generate.pick Ns) [(smt-generate.pick [[fx> N -1] [fx>= N 1] [fx<= N 1]]) (smt-generate.pick [[bit-probe N] [bit-probe [fx- N 1]] [probe -1 N]])])
  [_ Ps | _] 9 -> [(smt-generate.pick [[= [snd (smt-generate.pick Ps)] read] [= 1 1]]) (smt-generate.pick [[let (protect K) [fst (smt-generate.pick Ps)] [bit-probe (protect K)]] [bit-taker [fst (smt-generate.pick Ps)]]])]
  [Ns Ps Ss Cs Ls Ms] 11 -> [(refine-generate.shape-condition [Ns Ps Ss Cs Ls Ms] 0)
                             (let L (smt-generate.pick [(smt-generate.pick Ls) [cons (smt-generate.pick Ns) (smt-generate.pick Ls)] [cons (smt-generate.pick Ns) []] [tail [cons 1 (smt-generate.pick Ls)]]])
                               (smt-generate.pick [[bits-of L] [fixnums-of L]]))]
  [Ns Ps Ss Cs Ls Ms] 12 -> [(refine-generate.shape-condition [Ns Ps Ss Cs Ls Ms] 0)
                             (let P (smt-generate.pick [(smt-generate.pick Ps) [@p (smt-generate.pick Ns) read] [fst (protect W)] [@p [fst (protect R)] (smt-generate.pick Ms)]])
                               (smt-generate.pick [[pair-of-bit P] [pair-of-fixnum P]]))]
  [Ns Ps Ss Cs Ls Ms] 13 -> [(refine-generate.shape-condition [Ns Ps Ss Cs Ls Ms] 0)
                             (let F (smt-generate.pick [(protect F) [lambda (protect Z) [fx- (protect Z) 1]] [lambda (protect Z) (smt-generate.pick Ns)] [fn bit-taker] [lambda (protect Z) [bit-taker (protect Z)]]])
                               (smt-generate.pick [[to-bit F] [to-fixnum F] [from-bit F] [from-fixnum F]]))]
  [Ns Ps Ss Cs Ls Ms] 14 -> (let N (smt-generate.pick Ns) B [fst (smt-generate.pick Ps)]
                             [(smt-generate.pick [[= [fst (smt-generate.pick Ps)] N] [= N [span.end (smt-generate.pick Ss)]] [= (smt-generate.pick Ls) [cons N []]] [= [span.end (smt-generate.pick Ss)] N]])
                              (smt-generate.pick [[bit-probe N] [bit-taker N] [bits-of [cons N []]]])])
  Vs 15 -> (let A (refine-generate.shape-term Vs 1) [[and [fx<= 0 A] [fx<= A (smt-generate.pick [0 1 1 2])]] (smt-generate.pick [[do [lamp.lit-> (protect H) A] [lamp-taker (protect H)]] [lamp-taker [lamp.make A read]] [lamp-taker [lamp.make (smt-generate.pick [0 1]) [lamp.mode (protect H)]]]])])
  Vs 16 -> (let M (smt-generate.pick (hd (tl (tl (tl (tl (tl Vs))))))) [(smt-generate.pick [[= M read] [= M [lamp.mode (protect H)]] [not [= M write]]]) (smt-generate.pick [[access-taker M] [lamp-taker [lamp.make 1 M]] [access-taker [lamp.mode (protect H)]] [bit-taker [lamp.lit (protect H)]] [one-taker [lamp.lit (protect H)]]])])
  [_ _ Ss | _] 10 -> (let S (smt-generate.pick Ss) [[fx>= [span.start S] (smt-generate.pick [0 1])] (smt-generate.pick [[bit-probe [span.end S]] [probe -1 [span.end S]] [one-taker [span.end S]] [bit-probe [span.start S]]])]))

(define refine-generate.shape-function
  Name -> (let Pair [fixnum * symbol]
            (append [define-checked Name { fixnum --> Pair --> Pair --> Pair --> [Pair * fixnum] --> [fixnum * fixnum] --> span --> span --> cell --> cell
                     --> [list fixnum] --> [list fixnum] --> symbol --> access --> [fixnum --> fixnum] --> lamp --> fixnum }]
                    (refine-generate.shape-clauses (smt-generate.below 2)))))

(define refine-generate.shape-variables
  -> [(protect N) (protect P) (protect Q) (protect G) (protect W) (protect R) (protect S) (protect T) (protect C) (protect D) (protect K) (protect L) (protect M) (protect O) (protect F) (protect H)])

(define refine-generate.shape-scope
  -> [[(protect N)] [(protect P) (protect Q) (protect G)] [(protect S) (protect T)] [(protect C) (protect D)] [(protect K) (protect L)] [(protect M) (protect O)]])

(define refine-generate.shape-clauses
  0 -> (append (refine-generate.shape-variables) [-> (refine-generate.shape (refine-generate.shape-scope) 4)])
  _ -> (append (refine-generate.shape-variables)
               [-> (refine-generate.shape (refine-generate.shape-scope) 2) where (refine-generate.shape-condition (refine-generate.shape-scope) 2)]
               (refine-generate.shape-clauses 0)))

\\ One call for each of some of the box, whose cells are new.
(define refine-generate.call-shapes
  _ _ 0 -> done
  F Form K -> (let Before (length (value refine-generate.*broken*))
                   _ (set refine-generate.*called* (+ 1 (value refine-generate.*called*)))
                   _ (trap-error (refine-generate.call-shape (function F)) (/. E skip))
                   _ (if (= Before (length (value refine-generate.*broken*))) skip (refine-generate.broke (make-string "in ~A: ~R" F Form)))
                (refine-generate.call-shapes F Form (- K 1))))

(define refine-generate.call-shape
  F -> (let C (cell.make (smt-generate.between -1 2))
            D (if (= 0 (smt-generate.below 3)) C (cell.make (smt-generate.between -1 2)))
            Bits (/. X (smt-generate.pick [[] [0] [1 0] [1]]))
            Pair (/. X (@p (smt-generate.below 2) (smt-generate.pick [read write close])))
          (F (smt-generate.between -2 3) (Pair 0) (Pair 0) (Pair 0) (@p (Pair 0) 7) (@p (smt-generate.between -1 1) (smt-generate.between -1 1))
             (span.make (smt-generate.between -1 2) (smt-generate.below 2)) (span.make (smt-generate.between -1 2) (smt-generate.below 2))
             C D (Bits 0) (Bits 0) (smt-generate.pick [read write close]) (smt-generate.pick [read write])
             (/. X (if (> X 0) 1 0)) (lamp.make (smt-generate.below 2) (smt-generate.pick [read write])))))

(define refine-generate.run-shapes
  Directory Seed Count
  -> (let _ (set smt-generate.*seed* Seed)
          File (@s Directory "/generated.shen")
          _ (refine-generate.start File)
          _ (refine-generate.write File (refine-generate.prelude-text (refine-generate.shapes-prelude)))
          Prelude (refine-generate.load File)
          _ (if (= Prelude true) skip (error "shapes: ~A" Prelude))
       (refine-generate.each-shape File Count)))

(define refine-generate.each-shape
  _ 0 -> done
  File N -> (let F (concat refine-generate.s N)
                 Form (refine-generate.shape-function F)
                 _ (refine-generate.write File (make-string "~R~%" Form))
                 R (refine-generate.load File)
                 _ (if (= R true)
                       (do (set refine-generate.*loaded* (+ 1 (value refine-generate.*loaded*)))
                           (refine-generate.call-shapes F Form 120))
                       (refine-generate.refused R Form))
              (refine-generate.each-shape File (- N 1))))

\\ ---------------------------------------------------------------------------
\\ Functions by patterns, with wildcards, literals and variables again, of a pair, a list, what may be a Boolean, a
\\ symbol, a pair or nothing, one of two structs, two numbers, one of a refined type, some of them equal and not the
\\ same, a pair of numbers, which may be written again in the action, a struct and a vector that the action may change
\\ after they were matched, and what a datatype has for some numbers. An action may be one that is not looked into:
\\ (refine-generate.run-patterns Directory Seed Count).

(define refine-generate.patterns-prelude
  -> "(defstruct two-parts (start : fixnum) (end : fixnum))
(defstruct one-part (only : fixnum))
(struct.union parts two-parts one-part)
(datatype mixed
  X : boolean;
  ____________
  X : mixed;

  X : symbol;
  ____________
  X : mixed;

  ____________
  [] : mixed;

  X : fixnum; Y : fixnum;
  =======================
  (@p X Y) : mixed;)
(defstruct gauge (name : fixnum) (mutable level : fixnum) (mutable items : (list fixnum)))
(datatype tagged
  __________________
  [tag 0] : tagged;

  __________________
  [tag 1] : tagged;

  N : fixnum;
  ==================
  [num N] : tagged;

  X : number; Y : number;
  =======================
  [twin X Y] : tagged;)
(datatype quiet
  ________________________________
  (refine-generate.quiet X) : fixnum;)
(define-checked over-0 {A : fixnum --> R : fixnum} {requires (fx> A 0)} {ensures (fx= R A)}
  A -> (if (fx> A 0) A (let _ (refine-generate.broke (make-string `over-0 ~A` A)) A)))
(define-checked alike {A : fixnum --> B : fixnum --> R : fixnum} {requires (fx= A B)} {ensures (fx= R B)}
  A B -> (if (fx= A B) A (let _ (refine-generate.broke (make-string `alike ~A ~A` A B)) B)))
(define-checked true-probe {V : mixed --> fixnum} {requires (= V true)}
  V -> (if (= V true) 1 (let _ (refine-generate.broke (make-string `true ~A` V)) 0)))
(define-checked none-probe {V : mixed --> fixnum} {requires (not (= V none))}
  V -> (if (= V none) (let _ (refine-generate.broke `none`) 0) 1))
(define-checked cons-probe {L : (list fixnum) --> fixnum} {requires (cons? L)}
  L -> (if (cons? L) 1 (let _ (refine-generate.broke `cons`) 0)))
(define-checked whole-probe {X : number --> fixnum} {requires (shen-jit.fixnum? X)}
  X -> (if (shen-jit.fixnum? X) 1 (let _ (refine-generate.broke (make-string `whole ~A` X)) 0)))
(refine.type whole X : number where (shen-jit.fixnum? X))
(define whole-taker {whole --> fixnum}
  X -> (if (shen-jit.fixnum? X) 1 (let _ (refine-generate.broke (make-string `taker ~A` X)) 0)))
(define-checked more-probe {X : number --> fixnum} {requires (> (+ X 1) X)}
  X -> (if (> (+ X 1) X) 1 (let _ (refine-generate.broke (make-string `more ~A` X)) 0)))
(define-checked not-less-probe {X : number --> Y : number --> fixnum} {requires (>= X Y)}
  X Y -> (if (>= X Y) 1 (let _ (refine-generate.broke (make-string `not less ~A ~A` X Y)) 0)))
")

(define refine-generate.quiet
  X -> X)

\\ Changes what was last given.
(define refine-generate.disturb
  -> (let _ (gauge.level-> (value refine-generate.*gauge*) (smt-generate.between -1 1))
          _ (gauge.items-> (value refine-generate.*gauge*) (smt-generate.pick [[] [0] [1] [1 1] [-1 1 2]]))
          _ (vector-> (value refine-generate.*vector*) 1 (smt-generate.between -1 1))
       0))

(declare refine-generate.disturb [--> fixnum])

\\ What a clause binds, by kind.
(define refine-generate.bind
  Kind X -> (let _ (put refine-generate.patterns Kind (adjoin X (get refine-generate.patterns Kind))) X))

(define refine-generate.bound
  Kind Others -> (append Others (get refine-generate.patterns Kind)))

(define refine-generate.part
  0 -> (intern "_")
  1 -> (smt-generate.pick [0 1 -1])
  _ -> (refine-generate.bind fixnums (smt-generate.pick [(protect A) (protect B)])))

(define refine-generate.any-part
  -> (refine-generate.part (smt-generate.below 5)))

(define refine-generate.rest
  0 -> (intern "_")
  1 -> []
  _ -> (refine-generate.bind lists (protect Zs)))

(define refine-generate.pair-pattern
  0 -> (intern "_")
  1 -> (refine-generate.bind pairs (protect G))
  _ -> [@p (refine-generate.any-part) (refine-generate.any-part)])

(define refine-generate.list-pattern
  0 -> (intern "_")
  1 -> []
  2 -> (refine-generate.bind lists (protect Ys))
  3 -> [cons (refine-generate.any-part) [cons (refine-generate.any-part) (refine-generate.rest (smt-generate.below 3))]]
  _ -> [cons (refine-generate.any-part) (refine-generate.rest (smt-generate.below 3))])

(define refine-generate.mixed-pattern
  0 -> (intern "_")
  1 -> (refine-generate.bind mixed (protect W))
  2 -> (refine-generate.bind mixed (protect W))
  3 -> [@p (refine-generate.any-part) (refine-generate.any-part)]
  _ -> (smt-generate.pick [true false none []]))

(define refine-generate.parts-pattern
  0 -> (intern "_")
  1 -> [:two-parts start <- (refine-generate.any-part) end <- (refine-generate.any-part)]
  _ -> [:one-part only <- (refine-generate.any-part)])

(define refine-generate.gauge-pattern
  0 -> (intern "_")
  1 -> [: gauge name <- (refine-generate.any-part) level <- (refine-generate.any-part) items <- (intern "_")]
  _ -> [: gauge name <- (intern "_") level <- (refine-generate.any-part) items <- (refine-generate.list-pattern (smt-generate.below 7))])

(define refine-generate.vector-pattern
  0 -> [vector 0]
  1 -> [@v (refine-generate.any-part) [vector 0]]
  _ -> [@v (refine-generate.any-part) (intern "_")])

(define refine-generate.tagged-pattern
  0 -> [cons tag [cons 0 []]]
  1 -> [cons tag [cons 1 []]]
  2 -> (let N (refine-generate.bind numbers (smt-generate.pick [(protect N) (protect M)])) [cons twin [cons N [cons N []]]])
  _ -> [cons num [cons (refine-generate.any-part) []]])

(define refine-generate.number-pattern
  0 -> (intern "_")
  1 -> (smt-generate.pick [0 1 9007199254740992])
  _ -> (refine-generate.bind numbers (smt-generate.pick [(protect N) (protect M)])))

(define refine-generate.numbers-pattern
  -> (let P [@p (refine-generate.number-pattern (smt-generate.below 4)) (refine-generate.number-pattern (smt-generate.below 4))]
          _ (put refine-generate.patterns written (if (> (occurrences (intern "_") P) 0) [] [P]))
       P))

(define refine-generate.patterns
  -> (do (map (/. K (put refine-generate.patterns K [])) [fixnums lists pairs mixed numbers written])
         (map (/. F (if (= 0 (smt-generate.below 2)) (intern "_") (thaw F)))
              [(freeze (refine-generate.pair-pattern (smt-generate.below 6))) (freeze (refine-generate.list-pattern (smt-generate.below 7)))
               (freeze (refine-generate.mixed-pattern (smt-generate.below 8))) (freeze (refine-generate.parts-pattern (smt-generate.below 3)))
               (freeze (refine-generate.number-pattern (smt-generate.below 5))) (freeze (refine-generate.number-pattern (smt-generate.below 5)))
               (freeze (refine-generate.numbers-pattern)) (freeze (refine-generate.gauge-pattern (smt-generate.below 3)))
               (freeze (refine-generate.vector-pattern (smt-generate.below 4))) (freeze (refine-generate.tagged-pattern (smt-generate.below 5)))])))

(define refine-generate.any-fixnum
  -> (smt-generate.pick (refine-generate.bound fixnums [0 1 -1])))

(define refine-generate.test
  -> (refine-generate.test-of (smt-generate.below 10)))

(define refine-generate.test-of
  0 -> [not (refine-generate.test)]
  1 -> [(smt-generate.pick [and or]) (refine-generate.test) (refine-generate.test)]
  2 -> [= (smt-generate.pick (refine-generate.bound mixed [none])) (smt-generate.pick [true false none []])]
  3 -> [(smt-generate.pick [empty? cons?]) (smt-generate.pick (refine-generate.bound lists [[]]))]
  4 -> [(smt-generate.pick [< >= =]) (smt-generate.pick (refine-generate.bound numbers [0])) (smt-generate.pick (refine-generate.bound numbers [0 1]))]
  5 -> [shen-jit.fixnum? (smt-generate.pick (refine-generate.bound numbers [1]))]
  6 -> (let X (smt-generate.pick (refine-generate.bound numbers [1])) [> [+ X 1] X])
  7 -> [= (smt-generate.pick (refine-generate.bound pairs [[@p 1 0]])) [@p (refine-generate.any-fixnum) 1]]
  _ -> [(smt-generate.pick [fx< fx<= fx= fx>]) (refine-generate.any-fixnum) (refine-generate.any-fixnum)])

(define refine-generate.probe-of
  0 -> [alike (refine-generate.any-fixnum) (refine-generate.any-fixnum)]
  1 -> [true-probe (smt-generate.pick (refine-generate.bound mixed [none true]))]
  2 -> [none-probe (smt-generate.pick (refine-generate.bound mixed [none true]))]
  3 -> [cons-probe (smt-generate.pick (refine-generate.bound lists [[]]))]
  4 -> [whole-probe (smt-generate.pick (refine-generate.bound numbers [1]))]
  5 -> [more-probe (smt-generate.pick (refine-generate.bound numbers [1]))]
  6 -> [not-less-probe (smt-generate.pick (refine-generate.bound numbers [0 1])) (smt-generate.pick (refine-generate.bound numbers [0 1]))]
  7 -> [whole-taker (smt-generate.pick (refine-generate.bound numbers [1]))]
  8 -> [over-0 (refine-generate.any-fixnum)]
  9 -> [over-0 (refine-generate.any-fixnum)]
  _ -> [(smt-generate.pick [whole-probe whole-taker]) [(smt-generate.pick [fst snd]) (refine-generate.first (refine-generate.bound written []))]])

(define refine-generate.first
  [] -> [@p 0 1]
  [P | _] -> P)

\\ A probe, what it needs, or near it, and it with that.
(define refine-generate.need
  [alike A B] -> [fx= A B]
  [true-probe V] -> [= V true]
  [none-probe V] -> [not [= V none]]
  [cons-probe L] -> [cons? L]
  [whole-probe X] -> [shen-jit.fixnum? X]
  [whole-taker X] -> [shen-jit.fixnum? X]
  [more-probe X] -> [> [+ X 1] X]
  [not-less-probe X Y] -> [not [< X Y]]
  [over-0 A] -> [fx> A 0])

(define refine-generate.matched-action
  D -> (let Probe (refine-generate.probe-of (smt-generate.below 13))
            Need (if (= 0 (smt-generate.below 3)) (refine-generate.test) (refine-generate.need Probe))
         (refine-generate.matched-action-of D (smt-generate.below 12) Need [do Probe (smt-generate.pick [up up down])])))

\\ What it gives is a symbol, as (fail) is one.
(define refine-generate.matched-action-of
  0 _ _ Probe -> Probe
  D 0 Need Probe -> [where Need Probe]
  D 1 Need Probe -> [if Need Probe [fail]]
  D 2 Need Probe -> [let (intern "_") (refine-generate.any-fixnum) [if Need Probe (refine-generate.matched-action (- D 1))]]
  D 3 Need Probe -> [do [if Need Probe down] (refine-generate.matched-action (- D 1))]
  D 4 Need Probe -> [let (protect Z) Need [if (protect Z) Probe (refine-generate.matched-action (- D 1))]]
  D 5 Need Probe -> (smt-generate.pick [up down [fail]])
  D 6 _ Probe -> Probe
  D 7 Need Probe -> [if Need [do [refine-generate.disturb] Probe] (refine-generate.matched-action (- D 1))]
  D 8 Need Probe -> [let (protect T) [freeze [if Need Probe down]] [do [refine-generate.disturb] [thaw (protect T)]]]
  D 9 Need [do [F | Args] End] -> [do [refine-generate.quiet [F | Args]] [if Need End down]] where (not (= F whole-taker))
  D 10 Need Probe -> [let (protect A) (refine-generate.any-fixnum) [if Need [do [refine-generate.disturb] Probe] down]]
  D _ Need Probe -> [if Need Probe (refine-generate.matched-action (- D 1))])

(define refine-generate.matched-clauses
  0 -> (append (map (/. K (intern "_")) [1 2 3 4 5 6 7 8 9 10]) [-> [simple-error "none"]])
  N -> (let Patterns (refine-generate.patterns)
            Action (refine-generate.matched-action 2)
            Arrow (if (= 0 (smt-generate.below 5)) <- ->)
            Guard (if (= 0 (smt-generate.below 3)) [where (refine-generate.test)] [])
         (append Patterns [Arrow Action | Guard] (refine-generate.matched-clauses (- N 1)))))

(define refine-generate.required
  0 -> []
  _ -> (let P (protect P) L (protect L) V (protect V) X (protect X) Y (protect Y)
         [{ requires | (append (map (/. K (smt-generate.pick [[fx= [fst P] [snd P]] [fx> [fst P] 0] [cons? L] [and [cons? L] [fx> [head L] 0]] [= V true]
            [not [= V none]] [not [= V true]] [> X 0] [= X Y] [shen-jit.fixnum? X] [not [shen-jit.fixnum? X]] [> [+ X 1] X] [not [> [+ Y 1] Y]]])) (smt-generate.pick [[1] [1 2]])) [}])]))

(define refine-generate.ensured
  0 -> (let P (protect P) R (protect R) [{ ensures (smt-generate.pick [[= R up] [not [= R down]] [or [= R up] [fx= [fst P] 0]] [fx= [fst P] [snd P]]]) }])
  _ -> [])

(define refine-generate.pattern-function
  Name -> (append [define Name { [fixnum * fixnum] --> [list fixnum] --> mixed --> parts --> number --> whole --> [number * number] --> gauge
                   --> [vector fixnum] --> tagged --> symbol }] (refine-generate.matched-clauses (smt-generate.between 1 3)))
    where (= 0 (smt-generate.below 5))
  Name -> (append [define-checked Name { (protect P) : [fixnum * fixnum] --> (protect L) : [list fixnum] --> (protect V) : mixed
                 --> parts --> (protect X) : number --> (protect Y) : whole --> (protect Q) : [number * number] --> gauge
                 --> [vector fixnum] --> tagged --> (protect R) : symbol }]
                (refine-generate.required (smt-generate.below 3))
                (refine-generate.ensured (smt-generate.below 5)) (refine-generate.matched-clauses (smt-generate.between 1 3))))

(set refine-generate.*numbers*
  (let One (/ 1.5 1.5) [0 1 2 -1 One 0.5 9007199254740992 (* One 9007199254740992) (* One 2) (value refine-generate.*not-a-number*) (* 1e308 10)]))

(define refine-generate.call-patterns
  _ _ _ 0 -> done
  F Form Promise K -> (let Before (length (value refine-generate.*broken*))
                           _ (set refine-generate.*called* (+ 1 (value refine-generate.*called*)))
                           _ (trap-error (refine-generate.call-matched (function F) Promise) (/. E skip))
                           _ (if (= Before (length (value refine-generate.*broken*))) skip (refine-generate.broke (make-string "in ~A: ~R" F Form)))
                        (refine-generate.call-patterns F Form Promise (- K 1))))

(define refine-generate.call-matched
  F Promise -> (let P (@p (smt-generate.between -1 1) (smt-generate.between -1 1))
                    X (smt-generate.pick (value refine-generate.*numbers*))
                    Whole (mapcan (/. N (if (shen-jit.fixnum? N) [N] [])) (value refine-generate.*numbers*))
                    Same (mapcan (/. N (if (= N X) [N] [])) Whole)
                    Y (smt-generate.pick (if (and (cons? Same) (= 0 (smt-generate.below 2))) Same Whole))
                    Q (@p (smt-generate.pick (value refine-generate.*numbers*)) (smt-generate.pick (value refine-generate.*numbers*)))
                    G (gauge.make (smt-generate.between -1 1) (smt-generate.between -1 1) (smt-generate.pick [[] [0] [1] [1 1] [0 1] [-1 1 2]]))
                    V (vector-> (vector (smt-generate.between 1 2)) 1 (smt-generate.between -1 1))
                    _ (set refine-generate.*gauge* G)
                    _ (set refine-generate.*vector* (if (= 1 (limit V)) V (vector-> V 2 (smt-generate.between -1 1))))
                    R (F P (smt-generate.pick [[] [0] [1] [1 1] [0 1] [-1 1 2]]) (smt-generate.pick [true false none other [] (@p 0 0) (@p 1 0) (@p 1 1)])
                         ((smt-generate.pick [(/. N (two-parts.make N (smt-generate.between -1 1))) (/. N (one-part.make N))]) (smt-generate.between -1 1)) X Y Q G V
                         (smt-generate.pick [[tag 0] [tag 1] [num 0] [num 1] [num -1] [twin 1 (/ 1.5 1.5)] [twin (/ 1.5 1.5) 1] [twin 0 0]]))
                 (if (Promise P R) skip (refine-generate.broke (make-string "gave ~A of ~A" R P)))))

(define refine-generate.promise-of
  [] -> (/. P R true)
  [[P | _] R Post] -> (eval [lambda P [lambda R Post]]))

(define refine-generate.run-patterns
  Directory Seed Count
  -> (let _ (set smt-generate.*seed* Seed)
          File (@s Directory "/generated.shen")
          _ (refine-generate.write File (refine-generate.prelude-text (refine-generate.patterns-prelude)))
          Prelude (refine-generate.load File)
          _ (if (= Prelude true) skip (error "patterns: ~A" Prelude))
       (refine-generate.each-pattern File Count)))

(define refine-generate.each-pattern
  _ 0 -> done
  File N -> (let F (concat refine-generate.p N)
                 Form (refine-generate.pattern-function F)
                 _ (refine-generate.write File (make-string "~R~%" Form))
                 R (refine-generate.load File)
                 _ (if (= R true)
                       (let Promise (refine-generate.promised F)
                            _ (if (empty? Promise) skip (set refine-generate.*promising* (+ 1 (value refine-generate.*promising*))))
                            _ (set refine-generate.*loaded* (+ 1 (value refine-generate.*loaded*)))
                         (refine-generate.call-patterns F Form (refine-generate.promise-of Promise) 150))
                       (refine-generate.refused R Form))
              (refine-generate.each-pattern File (- N 1))))
