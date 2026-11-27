\\ Whether formulas over the integers can hold together: smt.check, with a model or a proof that they
\\ cannot. Formulas are Shen data, and their atoms linear:
\\
\\   F   true, false, a proposition's name, [not F], [and F ...], [or F ...],
\\       [<= T T], [< T T], [>= T T], [> T T], [= T T]
\\   T   an integer, an unknown's name, [+ T ...], [- T], [- T T ...], [* T T], one of them constant
\\
\\ A name is a symbol or a string. smt-proof.shen has what is trusted: this reads formulas into rows,
\\ choosing among disjunctions and eliminating unknowns until no case is left or one has a model. An
\\ unknown is eliminated by adding each of its upper bounds to each of its lower ones, as Fourier and
\\ Motzkin did, rounding each sum's bound down. All arithmetic is fixnum arithmetic, which raises past
\\ 62 bits: the answer is then unknown.

(shen.x.namespace smt
  (use shen-jit)
  (shadow floor gcd product)
  (import struct defstruct)
  (export budget check check-model check-within check-proof formula integer model proof reason result sat? t term truth unknown?
    unsat? valid?)

\\ What check gives. Typed code sees one type, result, and the functions below.
(defstruct sat model)
(defstruct unsat proof)
(defstruct unknown reason)

\\ ---------------------------------------------------------------------------
\\ Reading formulas.

(define name?
  X -> (or (string? X) (and (symbol? X) (not (element? X [true false])))))

(define malformed
  X -> (error "smt: ~R is not a formula" X))

(define malformed-term
  X -> (error "smt: ~R is not a linear term" X))

\\ The names of the unknowns, then of the propositions, each once, as [Unknowns Propositions].
(define names
  F Ns -> Ns where (boolean? F)
  P [Us Ps] -> [Us (adjoin P Ps)] where (name? P)
  [not F] Ns -> (names F Ns)
  [Op | Fs] Ns -> (names-in Fs Ns) where (element? Op [and or])
  [Op A B] [Us Ps] -> [(term-names B (term-names A Us)) Ps] where (element? Op [<= < >= > =])
  F _ -> (malformed F))

(define names-in
  [] Ns -> Ns
  [F | Fs] Ns -> (names-in Fs (names F Ns))
  F _ -> (malformed F))

(define term-names
  N Us -> Us where (shen-jit.fixnum? N)
  X Us -> (adjoin X Us) where (name? X)
  [Op | Ts] Us -> (term-names-in Ts Us) where (element? Op [+ - *])
  T _ -> (malformed-term T))

(define term-names-in
  [] Us -> Us
  [T | Ts] Us -> (term-names-in Ts (term-names T Us))
  T _ -> (malformed-term T))

\\ Each name's number, from 1.
(define with-numbers
  [] _ -> []
  [X | Xs] N -> [[X | N] | (with-numbers Xs (+ N 1))])

(define number-of
  X Table -> (tl (assoc X Table)))

\\ A formula, or its negation if Holds is false, with the numbers of the unknowns and propositions.
(define read-formula
  F Holds _ -> (if (= F Holds) (all.make []) (any.make [])) where (boolean? F)
  P Holds [_ Ps] -> (prop.make (number-of P Ps) Holds) where (name? P)
  [not F] Holds Ns -> (read-formula F (not Holds) Ns)
  [and | Fs] true Ns -> (all.make (map (/. F (read-formula F true Ns)) Fs))
  [and | Fs] false Ns -> (any.make (map (/. F (read-formula F false Ns)) Fs))
  [or | Fs] true Ns -> (any.make (map (/. F (read-formula F true Ns)) Fs))
  [or | Fs] false Ns -> (all.make (map (/. F (read-formula F false Ns)) Fs))
  [<= A B] Holds Ns -> (if Holds (at-most A B 0 Ns) (at-most B A -1 Ns))
  [< A B] Holds Ns -> (read-formula [<= B A] (not Holds) Ns)
  [>= A B] Holds Ns -> (read-formula [<= B A] Holds Ns)
  [> A B] Holds Ns -> (read-formula [<= A B] (not Holds) Ns)
  [= A B] true Ns -> (all.make [(at-most A B 0 Ns) (at-most B A 0 Ns)])
  [= A B] false Ns -> (any.make [(at-most A B -1 Ns) (at-most B A -1 Ns)]))

\\ A - B <= K. A term is a row whose bound is its constant.
(define at-most
  A B K [Us _] -> (let Difference (add-row (read-term A Us) -1 (read-term B Us))
                    (atom.make (row.make (- K (row.bound Difference)) (row.terms Difference)))))

(define read-term
  N _ -> (row.make N []) where (shen-jit.fixnum? N)
  X Us -> (row.make 0 [(@p (number-of X Us) 1)]) where (name? X)
  [+ | Ts] Us -> (sum-terms (row.make 0 []) Ts 1 Us)
  [- T] Us -> (add-row (row.make 0 []) -1 (read-term T Us))
  [- T | Ts] Us -> (sum-terms (read-term T Us) Ts -1 Us)
  [* A B] Us -> (product (read-term A Us) (read-term B Us) [* A B])
  T _ -> (malformed-term T))

(define sum-terms
  R [] _ _ -> R
  R [T | Ts] K Us -> (sum-terms (add-row R K (read-term T Us)) Ts K Us))

(define product
  A B T -> (add-row (row.make 0 []) (row.bound A) B) where (empty? (row.terms A))
  A B T -> (add-row (row.make 0 []) (row.bound B) A) where (empty? (row.terms B))
  _ _ T -> (malformed-term T))

(define read-facts
  Fs Ns -> (expand-all (map (/. F (read-formula F true Ns)) Fs) (no-facts)))

(define names-of
  Fs -> (let Ns (names-in Fs [[] []])
             Both (intersection (hd Ns) (hd (tl Ns)))
          (if (empty? Both)
              (map (/. Xs (with-numbers (reverse Xs) 1)) Ns)
              (error "smt: ~S is an unknown and a proposition" (hd Both)))))

\\ ---------------------------------------------------------------------------
\\ Eliminating unknowns. A line is [N | Row]: a row of the facts by its number, or a step by its own
\\ negated. The steps made are kept newest first.

(set *steps* [])
(set *made* 0)
(set *left* 0)
(set *budget* 20000)

\\ How many sums smt.check may make and cases it may try before it answers that it does not know.
(define budget
  N -> (set *budget* (some-budget N)))

(define some-budget
  N -> N where (and (shen-jit.fixnum? N) (> N 0))
  N -> (error "smt: a budget of ~S" N))

(define spend
  -> (if (= (value *left*) 0) (simple-error "smt: out of budget") (set *left* (- (value *left*) 1))))

\\ The line of a step that adds Parts, divided by what its coefficients have in common.
(define derive
  Parts Row
  -> (let Spent (spend)
          D (content (row.terms Row))
          Divisor (if (= D 0) 1 D)
          N (- (value *made*) 1)
          _ (set *made* N)
          _ (set *steps* [(@p Divisor Parts) | (value *steps*)])
       [N | (divide-row Divisor Row)]))

(define combine
  [N | A] K [M | B] L -> (derive [(@p N K) (@p M L)] (add-row (add-row (row.make 0 []) K A) L B)))

\\ The rows of the facts as lines, each divided by what its coefficients have in common.
(define lines
  [] _ -> []
  [R | Rs] N -> [(if (= (content (row.terms R)) 1) [N | R] (derive [(@p N 1)] R)) | (lines Rs (+ N 1))])

\\ Lines with one added, but for what another already says: of two with the same terms, the lower.
(define add-tight
  L [] -> [L]
  [N | R] [[M | S] | Ls] -> (if (= (row.terms R) (row.terms S))
                                (if (< (row.bound R) (row.bound S)) [[N | R] | Ls] [[M | S] | Ls])
                                [[M | S] | (add-tight [N | R] Ls)]))

\\ The lines, or [refuted N] if one of those added is false by itself or directly denies another.
(define add-lines
  [] Ls -> Ls
  [[N | R] | More] Ls -> (cases (false-row? R) [refuted N]
                                (true-row? R) (add-lines More Ls)
                                true (add-one-line [N | R] More Ls)))

(define add-one-line
  L More Ls -> (let Opp (opposite-contradiction (tl L) Ls)
                 (if (cons? Opp)
                     [refuted (hd (combine L 1 Opp 1))]
                     (add-lines More (add-tight L Ls)))))

(define opposite-contradiction
  _ [] -> []
  R [[M | S] | Ls] -> [M | S] where (and (sum-negative? (row.bound R) (row.bound S))
                                         (negated-terms? (row.terms R) (row.terms S)))
  R [_ | Ls] -> (opposite-contradiction R Ls))

\\ Whether A + B < 0 without overflowing fixnums.
(define sum-negative?
  A B -> (if (fx< A 0)
             (if (fx< B 0)
                 (fx>= A (fx- -2305843009213693951 B))
                 (fx< (fx+ A B) 0))
             (and (fx< B 0) (fx< (fx+ A B) 0))))

(define negated-coeff?
  C D -> (if (fx< C 0)
             (and (fx> D 0) (fx= (fx+ C D) 0))
             (and (fx< D 0) (fx= (fx+ C D) 0))))

(define negated-terms?
  [] [] -> true
  [(@p X C) | As] [(@p X D) | Bs] -> (and (negated-coeff? C D) (negated-terms? As Bs))
  _ _ -> false)

(define coefficient
  X [] -> 0
  X [(@p X C) | _] -> C
  X [_ | Terms] -> (coefficient X Terms))

(define coefficient-of
  X [_ | R] -> (coefficient X (row.terms R)))

(define unknowns
  [] -> []
  [[_ | R] | Ls] -> (union (map (fn fst) (row.terms R)) (unknowns Ls)))

\\ The unknown to eliminate next: of those that lose no integers if there are any, the one that adds
\\ fewest lines.
(define cheapest
  Ls [X | Xs] -> (cheapest-h Ls Xs X (cost X Ls)))

(define cheapest-h
  _ [] X _ -> X
  Ls [Y | Ys] X C -> (let D (cost Y Ls) (if (< D C) (cheapest-h Ls Ys Y D) (cheapest-h Ls Ys X C))))

(define cost
  X Ls -> (let Above (filter-lines X Ls 1)
               Below (filter-lines X Ls -1)
               A (length Above)
               B (length Below)
            (+ (if (exact? X Above Below) 0 1000000) (- (* A B) (+ A B)))))

\\ Whether eliminating X loses no integers: all that bounds it above, or all that bounds it below, or what
\\ it is equal to, has X itself and not a multiple of it.
(define exact?
  X Above Below -> (or (single? X Above) (single? X Below)
                 (let E (equality Above Below) (and (cons? E) (single? X E)))))

(define single?
  _ [] -> true
  X [L | Ls] -> (and (element? (coefficient-of X L) [1 -1]) (single? X Ls)))

\\ [unsat Steps], [sat Values] or [stuck]: rows that hold for rationals and for which no integers were found.
(define refute
  F -> (let _ (set *steps* [])
            _ (set *made* 0)
            First (add-lines (lines (reverse (facts.rows F)) 1) [])
         (eliminate First [])))

\\ Gone is each unknown eliminated, the last first, with the lines that bounded it.
(define eliminate
  [refuted N] _ -> [unsat (needed (value *steps*) (value *made*) (- 0 N))]
  [] Gone -> (values Gone [])
  Ls Gone -> (let X (cheapest Ls (unknowns Ls))
                  Above (filter-lines X Ls 1)
                  Below (filter-lines X Ls -1)
                  Rest (filter-lines X Ls 0)
               (eliminate (add-lines (pairs X Above Below) Rest) [[X Above Below] | Gone])))

(define filter-lines
  _ [] _ -> []
  X [L | Ls] S -> (let C (coefficient-of X L)
                    (if (if (= S 0) (= C 0) (> (* S C) 0))
                        [L | (filter-lines X Ls S)]
                        (filter-lines X Ls S))))

\\ Each line above X with each below it. Where one of each makes X equal to something, the rest with
\\ those two say as much.
(define pairs
  X Above Below -> (pairs-with X Above Below (equality Above Below)))

(define pairs-with
  X Above Below [] -> (mapcan (/. A (map (/. B (pair X A B)) Below)) Above)
  X Above Below [A B] -> (append (map (/. L (pair X L B)) (without A Above)) (map (/. L (pair X A L)) (without B Below))))

(define without
  _ [] -> []
  [N | R] [[N | _] | Ls] -> Ls
  L [M | Ls] -> [M | (without L Ls)])

(define pair
  X A B -> (let C (coefficient-of X A)
                D (- 0 (coefficient-of X B))
                G (gcd C D)
             (combine A (fxquotient D G) B (fxquotient C G))))

(define equality
  [] _ -> []
  [A | As] Bs -> (let B (opposite A Bs) (if (empty? B) (equality As Bs) [A B])))

(define opposite
  _ [] -> []
  [N | R] [[M | S] | Ls] -> (if (and (= (row.bound R) (- 0 (row.bound S))) (negated-terms? (row.terms R) (row.terms S)))
                                [M | S]
                                (opposite [N | R] Ls)))

\\ Values for the unknowns, the last eliminated first: each the one nearest 0 that its lines allow.
(define values
  [] Vs -> [sat Vs]
  [[X Above Below] | Gone] Vs
  -> (let Highest (bounds X Above Vs [])
          Lowest (bounds X Below Vs [])
          V (choose Lowest Highest)
       (if (= V none) [stuck] (values Gone [[X | V] | Vs]))))

(define choose
  [] [] -> 0
  [] [H] -> (if (< H 0) H 0)
  [L] [] -> (if (> L 0) L 0)
  [L] [H] -> (cases (> L H) none (> L 0) L (< H 0) H true 0))

\\ The tightest bound that lines put on X, in a list, given the other unknowns' values; [] for none.
(define bounds
  _ [] _ Best -> Best
  X [[_ | R] | Ls] Vs Best
  -> (let C (coefficient X (row.terms R))
          Rest (- (row.bound R) (sum-values X (row.terms R) Vs))
          B (if (> C 0) (floor Rest C) (- 0 (floor Rest (- 0 C))))
       (bounds X Ls Vs (cases (empty? Best) [B]
                              (> C 0) (if (< B (hd Best)) [B] Best)
                              true (if (> B (hd Best)) [B] Best)))))

(define sum-values
  _ [] _ -> 0
  X [(@p X _) | Terms] Vs -> (sum-values X Terms Vs)
  X [(@p Y C) | Terms] Vs -> (+ (* C (value-of Y Vs)) (sum-values X Terms Vs)))

(define value-of
  X Vs -> (let Entry (assoc X Vs) (if (empty? Entry) 0 (tl Entry))))

\\ ---------------------------------------------------------------------------
\\ The steps that one of them needs, and it, numbered again, and the rows they use.

\\ Steps newest first, the first being Made negated, and the number of the last one needed.
(define needed
  Steps Made N -> (renumber (reverse (needed-from Steps (- 0 Made) [N])) []))

\\ Steps newest first, the first being the Nth, and the numbers of those wanted: [N | Step] each.
(define needed-from
  [] _ _ -> []
  [Step | Steps] N Wanted -> (if (element? N Wanted)
                                 [[N | Step] | (needed-from Steps (- N 1) (union (steps-in (snd Step)) Wanted))]
                                 (needed-from Steps (- N 1) Wanted)))

(define steps-in
  [] -> []
  [(@p Line _) | Parts] -> (if (< Line 0) [(- 0 Line) | (steps-in Parts)] (steps-in Parts)))

\\ Table is each kept step's old number and new one.
(define renumber
  [] _ -> []
  [[N | (@p D Parts)] | Steps] Table
  -> [(@p D (map (/. P (if (< (fst P) 0) (@p (- 0 (tl (assoc (- 0 (fst P)) Table))) (snd P)) P)) Parts))
      | (renumber Steps [[N | (+ 1 (length Table))] | Table])])

(define rows-used
  [] -> []
  [(@p _ Parts) | Steps] -> (union (rows-in Parts) (rows-used Steps)))

(define rows-in
  [] -> []
  [(@p Line _) | Parts] -> (if (> Line 0) [[row | Line] | (rows-in Parts)] (rows-in Parts)))

\\ ---------------------------------------------------------------------------
\\ Choosing. [unsat Proof Used], [sat Values Props] or [unknown Reason]. Used is what a proof uses of the
\\ facts, [row | N], [choice | N] and [prop | N] each, or everything, for facts that were closed.

(define search
  F _ _ -> [unsat (refutation.make []) everything] where (facts.closed F)
  F Made R -> (search-choice F Made R (open-choice (facts.choices F) (length (facts.choices F)) Made (facts.props F) (facts.rows F) [])))

(define search-choice
  F Made R [] -> (settled F Made (if (= R none) (refute F) R))
  F Made R [N K Parts] -> (branch F [N | Made] N Parts [] [] [] R) where (fx<= K 1)
  F Made R [N _ Parts] -> (search-branch F Made N Parts (if (= R none) (refute F) R)))

(define search-branch
  _ _ _ _ [unsat Steps] -> [unsat (refutation.make Steps) (rows-used Steps)]
  F Made N Parts R -> (branch F [N | Made] N Parts [] [] [] R))

\\ What the rows give once each choice is made or holds. Where they have no integers found, each choice that
\\ holds is split after all, one at a time, as the rows of another of its cases may lead to some. Its cases
\\ split no other that holds: stuck, among the choices made, says so.
(define settled
  _ _ [unsat Steps] -> [unsat (refutation.make Steps) (rows-used Steps)]
  F _ [sat Values] -> [sat Values (facts.props F)]
  F Made [stuck] -> (if (element? stuck Made)
                        [unknown "no integers found"]
                        (split-held F Made (unmade (facts.choices F) (length (facts.choices F)) Made))))

(define split-held
  _ _ [] -> [unknown "no integers found"]
  F Made [[N | Parts] | Cs] -> (let R (branch F [N stuck | Made] N Parts [] [] [] [stuck])
                                 (if (= (hd R) unknown) (split-held F Made Cs) R)))

\\ The choices not made yet, newest first, each as [N | Parts].
(define unmade
  [] _ _ -> []
  [Parts | Cs] N Made -> (if (element? N Made)
                             (unmade Cs (fx- N 1) Made)
                             [[N | Parts] | (unmade Cs (fx- N 1) Made)]))

\\ The open choice with the fewest unclosed cases, skipping any that already hold: [N Open Parts], or [].
(define open-choice
  [] _ _ _ _ Best -> Best
  [Parts | Cs] N Made Props Rows Best
  -> (if (element? N Made)
         (open-choice Cs (fx- N 1) Made Props Rows Best)
         (let Limit (if (empty? Best) -1 (hd (tl Best)))
              K (choice-open Parts Props Rows 0 Limit)
           (cases (= K held) (open-choice Cs (fx- N 1) Made Props Rows Best)
                  (= K 0) [N 0 Parts]
                  (or (empty? Best) (fx< K Limit)) (open-choice Cs (fx- N 1) Made Props Rows [N K Parts])
                  true (open-choice Cs (fx- N 1) Made Props Rows Best)))))

(define choice-open
  [] _ _ K _ -> K
  _ _ _ K Limit -> Limit where (and (fx> Limit 0) (fx>= K Limit))
  [P | Ps] Props Rows K Limit
  -> (let S (node-state P Props Rows)
       (cases (= S held) held
              (= S closed) (choice-open Ps Props Rows K Limit)
              true (choice-open Ps Props Rows (fx+ K 1) Limit))))

(define node-state
  (:prop name <- X holds <- H) Props _ -> (prop-state X H Props)
  (:atom row <- R) _ Rows -> (row-state R Rows)
  (:all parts <- Ps) Props Rows -> (all-state Ps Props Rows held)
  (:any parts <- Ps) Props Rows -> (any-state Ps Props Rows closed))

(define prop-state
  _ _ [] -> open
  X H [(@p X H) | _] -> held
  X _ [(@p X _) | _] -> closed
  X H [_ | Ps] -> (prop-state X H Ps))

(define row-state
  R _ -> held where (true-row? R)
  R _ -> closed where (false-row? R)
  R Rows -> (row-state-in (row.terms R) (row.bound R) Rows))

(define row-state-in
  _ _ [] -> open
  Ts B [S | Rows] -> (cases (and (fx<= (row.bound S) B) (= Ts (row.terms S))) held
                            (and (sum-negative? B (row.bound S)) (negated-terms? Ts (row.terms S))) closed
                            true (row-state-in Ts B Rows)))

(define all-state
  [] _ _ Acc -> Acc
  [P | Ps] Props Rows Acc
  -> (let S (node-state P Props Rows)
       (cases (= S closed) closed
              (= S open) (all-state Ps Props Rows open)
              true (all-state Ps Props Rows Acc))))

(define any-state
  [] _ _ Acc -> Acc
  [P | Ps] Props Rows Acc
  -> (let S (node-state P Props Rows)
       (cases (= S held) held
              (= S open) (any-state Ps Props Rows open)
              true (any-state Ps Props Rows Acc))))

(define contradicting-row
  _ [] _ -> 0
  R [S | Rows] N -> N where (and (sum-negative? (row.bound R) (row.bound S))
                                 (negated-terms? (row.terms R) (row.terms S)))
  R [_ | Rows] N -> (contradicting-row R Rows (fx- N 1)))

(define quick-refute
  0 _ _ _ _ -> []
  Count [R | More] AllRows Total N
  -> (let K (contradicting-row R AllRows Total)
       (if (fx> K 0)
           [unsat (refutation.make [(@p 1 [(@p K 1) (@p N 1)])]) [[row | K] [row | N]]]
           (quick-refute (fx- Count 1) More AllRows Total (fx- N 1)))))

\\ Proofs, newest first, and what they used, of the cases of choice N tried so far; Reasons is why some
\\ are not known. A proof that does not use its case shows that the facts cannot hold without it, once
\\ what it numbers after that case's rows and choices is numbered without them.
(define branch
  F _ N [] Proofs Used [] _ -> [unsat (split.make N (reverse Proofs)) [[choice | N] | Used]]
  _ _ _ [] _ _ [Reason | _] _ -> [unknown Reason]
  F Made N [P | Ps] Proofs Used Reasons R
  -> (let Spent (spend)
          G (expand P F)
       (branch-h F Made N Ps Proofs Used Reasons R G (branch-case P F G Made R))))

(define branch-case
  P F G _ _ -> (closing P F) where (facts.closed G)
  _ F G Made R -> (let Old (facts.rows F)
                       New (facts.rows G)
                    (if (= New Old)
                        (search G Made R)
                        (let NewN (length New)
                             Quick (quick-refute (fx- NewN (length Old)) New New NewN)
                          (if (cons? Quick) Quick (search G Made none))))))

\\ What closes facts with a case: that, as a row they do not have, and the propositions that it denies.
(define closing
  P F -> [unsat (refutation.make []) [[row | (+ 1 (length (facts.rows F)))] | (denied (literals P) (facts.props F))]])

(define literals
  (:prop name <- X holds <- Holds) -> [(@p X Holds)]
  (:all parts <- Ps) -> (mapcan (fn literals) Ps)
  (:any parts <- [P]) -> (literals P)
  _ -> [])

(define denied
  _ [] -> []
  Ls [(@p X Holds) | Ps] -> (if (element? (@p X (not Holds)) Ls) [[prop | (+ 1 (length Ps))] | (denied Ls Ps)] (denied Ls Ps)))

(define branch-h
  F Made N Ps Proofs Used Reasons R G [unsat Proof New]
  -> (if (uses? New F)
         (branch F Made N Ps [Proof | Proofs] (union (known New F) Used) Reasons R)
         [unsat (without-case Proof F G) New])
  _ _ _ _ _ _ _ _ _ [sat Values Props] -> [sat Values Props]
  F Made N Ps Proofs Used Reasons R _ [unknown Reason] -> (branch F Made N Ps Proofs Used [Reason | Reasons] R))

(define without-case
  Proof F G -> (renumbered Proof (length (facts.rows F)) (- (length (facts.rows G)) (length (facts.rows F)))
                                 (length (facts.choices F)) (- (length (facts.choices G)) (length (facts.choices F)))))

(define renumbered
  Proof _ 0 _ 0 -> Proof
  (:refutation steps <- Steps) Rows R _ _
  -> (refutation.make (map (/. S (@p (fst S) (map (/. P (@p (moved (fst P) Rows R) (snd P))) (snd S)))) Steps))
  (:split choice <- N cases <- Proofs) Rows R Choices C
  -> (split.make (moved N Choices C) (map (/. P (renumbered P Rows R Choices C)) Proofs)))

(define moved
  N Most By -> (if (> N Most) (- N By) N))

\\ Whether a proof uses something that the facts do not have.
(define uses?
  everything _ -> true
  Used F -> (not (= Used (known Used F))))

(define known
  everything F -> (append (up-to row (length (facts.rows F)))
                          (up-to choice (length (facts.choices F))) (up-to prop (length (facts.props F))))
  Used F -> (known-h Used (length (facts.rows F)) (length (facts.choices F)) (length (facts.props F))))

(define known-h
  [] _ _ _ -> []
  [[Kind | N] | Used] Rows Choices Props
  -> (if (<= N (cases (= Kind row) Rows (= Kind choice) Choices true Props))
         [[Kind | N] | (known-h Used Rows Choices Props)]
         (known-h Used Rows Choices Props)))

(define up-to
  _ 0 -> []
  Kind N -> [[Kind | N] | (up-to Kind (- N 1))])

\\ ---------------------------------------------------------------------------
\\ What it is for.

(define check
  Fs -> (check-within (value *budget*) Fs))

\\ The same with a budget of its own.
(define check-within
  Budget Fs -> (let Ns (names-of Fs)
                    _ (set *left* (some-budget Budget))
                 (trap-error (answer (search (read-facts Fs Ns) [] none) Fs Ns) (/. E (gave-up (error-to-string E))))))

(define gave-up
  "integer overflow" -> (unknown.make "integer overflow")
  "smt: out of budget" -> (unknown.make "out of budget")
  Message -> (simple-error Message))

(define answer
  [unsat Proof _] Fs Ns -> (if (check-facts (read-facts Fs Ns) Proof)
                               (unsat.make Proof)
                               (error "smt: a proof that does not check, of ~R" Fs))
  [sat Values Props] Fs [Us Ps]
  -> (let Model (append (map (/. U [(hd U) (value-of (tl U) Values)]) Us)
                        (map (/. P [(hd P) (holds? (tl P) Props)]) Ps))
       (if (every-holds? Fs Model)
           (sat.make Model)
           (error "smt: a model that does not check, of ~R" Fs)))
  [unknown Reason] _ _ -> (unknown.make Reason))

(define holds?
  _ [] -> false
  X [(@p X Holds) | _] -> Holds
  X [_ | Props] -> (holds? X Props))

\\ Whether the goal holds wherever the assumptions do, with a proof that has been checked.
(define valid?
  Fs Goal -> (unsat? (check (append Fs [[not Goal]]))))

(define check-proof
  Fs Proof -> (trap-error (check-facts (read-facts Fs (names-of Fs)) Proof) (/. E (overflowed (error-to-string E)))))

(define overflowed
  "integer overflow" -> false
  Message -> (simple-error Message))

\\ Whether every formula holds in a model, read apart from the rows: a list of [Name Value].
(define check-model
  Fs Model -> (trap-error (every-holds? Fs Model) (/. E (overflowed (error-to-string E)))))

(define every-holds?
  [] _ -> true
  [F | Fs] Model -> (and (holds-in? F Model) (every-holds? Fs Model)))

(define holds-in?
  F _ -> F where (boolean? F)
  P Model -> (let V (lookup P Model) (if (boolean? V) V (malformed P))) where (name? P)
  [not F] Model -> (not (holds-in? F Model))
  [and | Fs] Model -> (every-holds? Fs Model)
  [or | Fs] Model -> (some-holds? Fs Model)
  [<= A B] Model -> (<= (term-value A Model) (term-value B Model))
  [< A B] Model -> (< (term-value A Model) (term-value B Model))
  [>= A B] Model -> (>= (term-value A Model) (term-value B Model))
  [> A B] Model -> (> (term-value A Model) (term-value B Model))
  [= A B] Model -> (= (term-value A Model) (term-value B Model))
  F _ -> (malformed F))

(define some-holds?
  [] _ -> false
  [F | Fs] Model -> (or (holds-in? F Model) (some-holds? Fs Model)))

(define term-value
  N _ -> N where (shen-jit.fixnum? N)
  X Model -> (let V (lookup X Model) (if (shen-jit.fixnum? V) V (malformed-term X))) where (name? X)
  [+ | Ts] Model -> (sum-of-values (map (/. T (term-value T Model)) Ts))
  [- T] Model -> (- 0 (term-value T Model))
  [- T | Ts] Model -> (- (term-value T Model) (sum-of-values (map (/. U (term-value U Model)) Ts)))
  [* A B] Model -> (* (term-value A Model) (term-value B Model))
  T _ -> (malformed-term T))

(define sum-of-values
  [] -> 0
  [V | Vs] -> (+ V (sum-of-values Vs)))

(define lookup
  X Model -> (let Entry (assoc X Model)
               (if (empty? Entry) (error "smt: the model has no ~S" X) (hd (tl Entry)))))

\\ The model, the proof or the reason of a result that has one. A model is a list of [Name Value].
(define model
  R -> (sat.model R) where (sat? R)
  R -> (error "smt: ~S has no model" R))

(define proof
  R -> (unsat.proof R) where (unsat? R)
  R -> (error "smt: ~S has no proof" R))

(define reason
  R -> (unknown.reason R) where (unknown? R)
  R -> (error "smt: ~S has no reason" R))

\\ What a model gives an unknown, and a proposition.
(define integer
  Model X -> (term-value X Model))

(define truth
  Model P -> (holds-in? P Model))

\\ Formulas and terms, where typed code expects one.
(datatype t
  P : symbol;
  ________________
  P : (- formula);

  P : string;
  ________________
  P : (- formula);

  P : boolean;
  ________________
  P : (- formula);

  F : formula;
  ______________________
  [not F] : (- formula);

  if (element? Op [and or])
  Fs : (list formula);
  ________________________
  [Op | Fs] : (- formula);

  if (element? Op [<= < >= > =])
  A : term; B : term;
  _______________________
  [Op A B] : (- formula);

  N : fixnum;
  _____________
  N : (- term);

  X : symbol;
  _____________
  X : (- term);

  X : string;
  _____________
  X : (- term);

  if (element? Op [+ - *])
  Ts : (list term);
  _____________________
  [Op | Ts] : (- term);)

(declare check [[list formula] --> result])
(declare check-within [fixnum --> [[list formula] --> result]])
(declare valid? [[list formula] --> [formula --> boolean]])
(declare check-model [[list formula] --> [model --> boolean]])
(declare check-proof [[list formula] --> [proof --> boolean]])
(declare budget [fixnum --> fixnum])
(map (/. F (declare F [result --> boolean])) [sat? unsat? unknown?])
(declare model [result --> model])
(declare integer [model --> [term --> fixnum]])
(declare truth [model --> [formula --> boolean]])
(declare proof [result --> proof])
(declare reason [result --> string])

\\ The rules of the structs are the search's and the check's alone: each would be tried wherever a goal's
\\ type is open.
(preclude [row.%match atom.%match prop.%match all.%match any.%match facts.%match refutation.%match split.%match
           node.%smt.atom node.%smt.prop node.%smt.all node.%smt.any proof.%smt.refutation proof.%smt.split])

)
