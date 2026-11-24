\\ What smt trusts: rows, formulas as they are decided, and the check of a proof that a set of them
\\ cannot hold. smt.shen reads formulas into these and searches for the proofs; nothing it finds counts
\\ until check, here, has gone through it. Read under (tc +).

(shen.x.namespace smt
  (import struct defstruct union => struct-union)
  (shadow floor gcd)
  (export proof refutation refutation.make split split.make)

\\ The sum of each unknown times its coefficient is at most the bound. Unknowns are numbered, in
\\ ascending order, and no coefficient is 0.
(defstruct row
  (bound : fixnum)
  (terms : (list (fixnum * fixnum))))

\\ A formula with its negations moved to its atoms: a row, a proposition that holds or does not, all of
\\ some nodes, or any of them.
(defstruct atom (row : row))
(defstruct prop (name : fixnum) (holds : boolean))
(defstruct all (parts : (list node)))
(defstruct any (parts : (list node)))
(struct-union node atom prop all any)

\\ What holds at once: rows and choices, newest first, numbered from 1 as they come, and propositions.
\\ Closed once it plainly cannot: a row that is false by itself, a proposition and its negation, or a
\\ choice of nothing.
(defstruct facts
  (rows : (list row))
  (choices : (list (list node)))
  (props : (list (fixnum * boolean)))
  (closed : boolean))

\\ A proof that facts cannot hold: rows summed until one is false by itself, or a choice and a proof
\\ for each of its nodes. A step divides a sum of lines, each taken a positive number of times, by
\\ a divisor of all its coefficients, and rounds the bound down, as the unknowns are integers. A line
\\ is a row of the facts, by its number, or an earlier step, by its own negated.
(defstruct refutation (steps : (list (fixnum * (list (fixnum * fixnum))))))
(defstruct split (choice : fixnum) (cases : (list proof)))
(struct-union proof refutation split)

(define times
  {fixnum --> (list (fixnum * fixnum)) --> (list (fixnum * fixnum))}
  0 _ -> []
  _ [] -> []
  K [(@p X C) | Terms] -> [(@p X (fx* K C)) | (times K Terms)])

(define add-terms
  {(list (fixnum * fixnum)) --> (list (fixnum * fixnum)) --> (list (fixnum * fixnum))}
  [] Terms -> Terms
  Terms [] -> Terms
  [(@p X C) | As] [(@p Y D) | Bs] -> [(@p X C) | (add-terms As [(@p Y D) | Bs])] where (fx< X Y)
  [(@p X C) | As] [(@p Y D) | Bs] -> [(@p Y D) | (add-terms [(@p X C) | As] Bs)] where (fx< Y X)
  [(@p X C) | As] [(@p _ D) | Bs] -> (add-terms As Bs) where (fx= (fx+ C D) 0)
  [(@p X C) | As] [(@p _ D) | Bs] -> [(@p X (fx+ C D)) | (add-terms As Bs)])

\\ Row A and K times row B.
(define add-row
  {row --> fixnum --> row --> row}
  A K B -> (row.make (fx+ (row.bound A) (fx* K (row.bound B)))
                     (add-terms (row.terms A) (times K (row.terms B)))))

(define gcd
  {fixnum --> fixnum --> fixnum}
  A 0 -> (if (fx< A 0) (fx- 0 A) A)
  A B -> (gcd B (fxremainder A B)))

\\ The greatest divisor of the coefficients, 0 for no terms.
(define content
  {(list (fixnum * fixnum)) --> fixnum}
  [] -> 0
  [(@p _ C) | Terms] -> (gcd C (content Terms)))

(define floor
  {fixnum --> fixnum --> fixnum}
  N D -> (let Q (fxquotient N D) (if (fx< (fxremainder N D) 0) (fx- Q 1) Q)))

(define divide-terms
  {fixnum --> (list (fixnum * fixnum)) --> (list (fixnum * fixnum))}
  _ [] -> []
  D [(@p X C) | Terms] -> [(@p X (fxquotient C D)) | (divide-terms D Terms)])

(define divide-row
  {fixnum --> row --> row}
  D R -> (row.make (floor (row.bound R) D) (divide-terms D (row.terms R))))

(define divides?
  {fixnum --> (list (fixnum * fixnum)) --> boolean}
  _ [] -> true
  D [(@p _ C) | Terms] -> (and (fx= (fxremainder C D) 0) (divides? D Terms)))

\\ No unknowns, and a bound below their sum, which is 0.
(define false-row?
  {row --> boolean}
  (:row bound <- B terms <- []) -> (fx< B 0)
  _ -> false)

(define true-row?
  {row --> boolean}
  (:row bound <- B terms <- []) -> (fx>= B 0)
  _ -> false)

(define no-facts
  {--> facts}
  -> (facts.make [] [] [] false))

(define shut
  {facts --> facts}
  (:facts rows <- Rs choices <- Cs props <- Ps ...) -> (facts.make Rs Cs Ps true))

(define expand
  {node --> facts --> facts}
  _ F -> F where (facts.closed F)
  (:atom row <- R) F -> (expand-row R F)
  (:prop name <- X holds <- H) F -> (expand-prop X H (facts.props F) F)
  (:all parts <- Ps) F -> (expand-all Ps F)
  (:any parts <- []) F -> (shut F)
  (:any parts <- [P]) F -> (expand P F)
  (:any parts <- Ps) (:facts rows <- Rs choices <- Cs props <- Qs closed <- C) -> (facts.make Rs [Ps | Cs] Qs C))

(define expand-all
  {(list node) --> facts --> facts}
  [] F -> F
  [P | Ps] F -> (expand-all Ps (expand P F)))

(define expand-row
  {row --> facts --> facts}
  R F -> F where (true-row? R)
  R F -> (shut F) where (false-row? R)
  R (:facts rows <- Rs choices <- Cs props <- Ps closed <- C) -> (facts.make [R | Rs] Cs Ps C))

(define expand-prop
  {fixnum --> boolean --> (list (fixnum * boolean)) --> facts --> facts}
  X H [] (:facts rows <- Rs choices <- Cs props <- Ps closed <- C) -> (facts.make Rs Cs [(@p X H) | Ps] C)
  X H [(@p X H) | _] F -> F
  X _ [(@p X _) | _] F -> (shut F)
  X H [_ | Ps] F -> (expand-prop X H Ps F))

\\ Whether Proof shows that the facts cannot hold together.
(define check-facts
  {facts --> proof --> boolean}
  F _ -> true where (facts.closed F)
  F (:refutation steps <- Steps) -> (false-sum? Steps (reverse (facts.rows F)) [])
  F (:split choice <- N cases <- Proofs) -> (check-cases (numbered N (reverse (facts.choices F))) Proofs F))

\\ The Nth of a list, from 1, in a list, or [].
(define numbered
  {fixnum --> (list A) --> (list A)}
  _ [] -> []
  1 [X | _] -> [X]
  N [_ | Xs] -> (numbered (fx- N 1) Xs))

\\ A choice that is not there has no cases, and shows nothing.
(define check-cases
  {(list (list node)) --> (list proof) --> facts --> boolean}
  [Parts] Proofs F -> (every-case? Parts Proofs F)
  _ _ _ -> false)

(define every-case?
  {(list node) --> (list proof) --> facts --> boolean}
  [] [] _ -> true
  [P | Ps] [Proof | Proofs] F -> (and (check-facts (expand P F) Proof) (every-case? Ps Proofs F))
  _ _ _ -> false)

\\ Whether the last of the steps is false by itself. Earlier ones are newest first.
(define false-sum?
  {(list (fixnum * (list (fixnum * fixnum)))) --> (list row) --> (list row) --> boolean}
  [(@p D Parts) | Steps] Rows Derived
  -> (check-step (sum-of Parts Rows (reverse Derived) (row.make 0 [])) D Steps Rows Derived)
  _ _ [R | _] -> (false-row? R)
  _ _ _ -> false)

(define check-step
  {(list row) --> fixnum --> (list (fixnum * (list (fixnum * fixnum)))) --> (list row) --> (list row) --> boolean}
  [R] D Steps Rows Derived -> (false-sum? Steps Rows [(divide-row D R) | Derived])
    where (and (fx> D 0) (divides? D (row.terms R)))
  _ _ _ _ _ -> false)

\\ The sum of the lines, in a list, or [] if there is no such sum.
(define sum-of
  {(list (fixnum * fixnum)) --> (list row) --> (list row) --> row --> (list row)}
  [] _ _ Sum -> [Sum]
  [(@p Line Times) | Parts] Rows Derived Sum
  -> (add-line (if (fx> Line 0) (numbered Line Rows) (numbered (fx- 0 Line) Derived)) Times Parts Rows Derived Sum)
    where (fx> Times 0)
  _ _ _ _ -> [])

(define add-line
  {(list row) --> fixnum --> (list (fixnum * fixnum)) --> (list row) --> (list row) --> row --> (list row)}
  [R] Times Parts Rows Derived Sum -> (sum-of Parts Rows Derived (add-row Sum Times R))
  _ _ _ _ _ _ -> [])

)
