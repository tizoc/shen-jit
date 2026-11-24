\\ Typed definitions about values of any type that refine (lib/refine.shen) must accept: loaded under (tc +)
\\ by tests/smt.sh, whose check is of refine-data.main.

\\ A predicate that is pure is a proposition, and what a call gives may be promised to meet one.
(define sorted?
  {(list number) --> boolean}
  [X Y | Zs] -> (and (<= X Y) (sorted? [Y | Zs]))
  _ -> true)
(refine.pure sorted?)
(define insert-in
  {number --> (list number) --> (list number)}
  X [] -> [X]
  X [Y | Ys] -> (if (<= X Y) [X Y | Ys] [Y | (insert-in X Ys)]))
(define sort-all
  {(list number) --> (list number)}
  [] -> []
  [X | Xs] -> (insert-in X (sort-all Xs)))
(refine.trust (sort-all Xs) --> R where (sorted? R))
(define-checked least
  {Xs : (list number) --> number}
  {requires (sorted? Xs) (not (empty? Xs))}
  [X | _] -> X)
(define-checked least-of
  {(list number) --> number}
  Xs -> (let Ys (sort-all Xs) (if (empty? Ys) 0 (least Ys))))
(define-checked least-if-sorted
  {(list number) --> number}
  [] -> 0
  Xs -> (least Xs) where (sorted? Xs)
  _ -> -1)

\\ A named condition is what its promise says it is, in tests, in conditions and in types.
(define-checked in-range?
  {I : fixnum --> N : fixnum --> R : boolean}
  {ensures (= R (and (fx<= 0 I) (fx< I N)))}
  I N -> (and (fx<= 0 I) (fx< I N)))
(define-checked end-of
  {I : fixnum --> N : fixnum --> R : fixnum}
  {ensures (fx= R (fx+ I N))}
  I N -> (fx+ I N))
(define-checked at {I : fixnum --> N : fixnum --> fixnum} {requires (in-range? I N)} I _ -> I)
(define-checked by-name {fixnum --> fixnum --> fixnum} I N -> (if (in-range? I N) (at I N) 0))
(define-checked by-parts {fixnum --> fixnum --> fixnum} I N -> (if (or (fx< I 0) (fx>= I N)) 0 (at I N)))
(define-checked by-variable {fixnum --> fixnum --> fixnum} I N -> (let Ok (in-range? I N) (if (not Ok) 0 (at I N))))
(define-checked slice {I : fixnum --> N : fixnum --> L : fixnum --> fixnum} {requires (fx<= (end-of I N) L)} _ N _ -> N)
(define-checked sliced {fixnum --> fixnum --> fixnum --> fixnum} I N L -> (if (fx<= N (fx- L I)) (slice I N L) 0))
(refine.type small N where (in-range? N 10))
(define-checked small-or-0 {fixnum --> small} N -> N where (in-range? N 10) _ -> 0)

\\ Symbols and strings are what they are and nothing else.
(define-checked opened {M : symbol --> fixnum} {requires (or (= M read) (= M write))} read -> 1 _ -> 2)
(define-checked opening
  {symbol --> fixnum}
  closed -> 0
  M -> (if (= M read) (opened M) (if (not (= M write)) 0 (opened M))))
(define-checked same-mode {symbol --> symbol --> fixnum} M N -> (if (and (= M N) (= write N)) (opened M) 0))
(define-checked named {S : string --> string} {requires (not (= S ""))} S -> S)
(define-checked named-or {string --> string} "" -> "nobody" S -> (named S))

\\ Lists by test, by pattern and by length.
(refine.type (nonempty A) Xs : (list A) where (not (empty? Xs)))
(define first {(nonempty A) --> A} [X | _] -> X)
(define-checked by-test {(list number) --> number} Xs -> (if (cons? Xs) (first Xs) 0))
(define-checked by-pattern {(list number) --> number} [] -> 0 Xs -> (first Xs))
(define-checked second-by-length {(list number) --> number} Xs -> (if (> (length Xs) 1) (first (tail Xs)) 0))
(define-checked both-lists {(nonempty number) --> (list number) --> (nonempty number)} Xs Ys -> (append Ys Xs))
(define size-of {(nonempty number) --> number} Xs -> (length Xs))
(define-checked dot
  {Xs : (list number) --> Ys : (list number) --> number}
  {requires (= (length Xs) (length Ys))}
  [] [] -> 0
  [X | Xs] [Y | Ys] -> (+ (* X Y) (dot Xs Ys)))
(define with-itself-back {(list number) --> number} Xs -> (dot Xs (reverse Xs)))

\\ What an earlier clause's pattern took apart.
(define-checked over {N : fixnum --> fixnum} {requires (fx> N 0)} N -> N)
(define-checked first-over {(fixnum * fixnum) --> fixnum} (@p A _) -> 0 where (fx<= A 0) (@p A _) -> (over A))
(define-checked head-over {(list fixnum) --> fixnum} [X | _] -> 0 where (fx<= X 0) [X | _] -> (over X) _ -> 0)

\\ Structs, pairs and what a pure function gives for equal arguments.
(defstruct span (start : fixnum) (end : fixnum))
(define-checked span-size
  {S : span --> R : fixnum}
  {requires (fx<= (span.start S) (span.end S))}
  {ensures (fx>= R 0)}
  S -> (fx- (span.end S) (span.start S)))
(define-checked made
  {fixnum --> fixnum --> fixnum}
  A B -> (let S (:span end <- B start <- A) P (@p A B) (if (fx<= (fst P) (snd P)) (span-size S) 0)))
(define-checked opened-span
  {span --> fixnum}
  (:span start <- A end <- B) -> (span-size (span.make A B)) where (fx<= A B)
  _ -> 0)
(define code-of {symbol --> fixnum} read -> 7 _ -> 1)
(refine.pure code-of)
(define-checked coded {N : fixnum --> S : symbol --> fixnum} {requires (fx= N (code-of S))} N _ -> N)
(define-checked recoded {symbol --> symbol --> fixnum} S T -> (let N (code-of S) (if (= S T) (coded N T) 0)))
(define-checked least-fixnum
  {A : fixnum --> B : fixnum --> R : fixnum}
  {ensures (fx<= R A) (fx<= R B)}
  A B -> (let M (if (fx< A B) A B) M))

\\ Numbers by their order, where a test that is false may mean a float that is no number.
(refine.type probability X : number where (and (>= X 0) (<= X 1)))
(define chance {probability --> number} X -> X)
(define-checked clamped
  {number --> probability}
  X -> 0 where (not (>= X 0))
  X -> 1 where (not (<= X 1))
  X -> X)
(define-checked between {A : number --> B : number --> number} {requires (< A B)} A _ -> A)
(define-checked ordered {number --> number --> number --> number} A B C -> (if (and (< A B) (<= B C)) (between A C) 0))
(define-checked quarter {number --> number} X -> (if (< X 0.25) (between X 1) 0))
(define-checked above {X : float --> float} {requires (fl> X 0.5)} X -> X)
(define-checked above-or {float --> float} X -> (if (fl>= X 0.75) (above X) X))

\\ What a call promises is known once it has been made, and where it was not its test decides.
(define-checked below
  {N : fixnum --> R : fixnum}
  {requires (fx> N 0)}
  {ensures (fx<= 0 R) (fx< R N)}
  N -> (fxquotient N 2))
(define-checked made-or-not
  {fixnum --> fixnum}
  N -> (if (and (fx> N 4) (fx> (below N) 2)) (at (below N) N) (if (or (fx<= N 0) (fx> (below N) 9)) 0 (below N))))

\\ What a let binds is what it was, and functions of any pair or list take those of a refined type.
(refine.type natural N where (fx<= 0 N))
(refine.type rising P : (fixnum * fixnum) where (fx<= (fst P) (snd P)))
(refine.type couple Xs : (list fixnum) where (= (length Xs) 2))
(define-checked from-0 {N : fixnum --> fixnum} {requires (fx<= 0 N)} N -> N)
(define-checked first-natural {(list fixnum) --> fixnum} Ns -> (let N (head Ns) (if (fx<= 0 N) (from-0 N) 0)) where (cons? Ns) _ -> 0)
(define-checked rise {rising --> fixnum} P -> (from-0 (fx- (snd P) (fst P))))
(define-checked rises {rising --> (list fixnum)} P -> [(from-0 (fx- (snd P) (fst P)))])
(define couple-size {couple --> number} Xs -> (length Xs))
(define-checked counted {symbol --> (list symbol) --> number} X Xs -> (let N (occurrences X Xs) (between N (+ N 1))))

\\ A promise is of the argument where a let binds its name again.
(define-checked stepped {X : fixnum --> R : fixnum} {ensures (fx> R X)} X -> (let Y X (let X (fx+ Y 1) (if (fx> X 9) (fx+ X 1) X))))
(define-checked stepped-back
  {X : fixnum --> Y : fixnum --> R : fixnum}
  {ensures (fx< R X) (fx<= R Y)}
  X Y -> (let Z X (let X Y (let Y (fx- Z 1) (if (fx< X Y) X Y)))))

\\ A type over another says what that says too.
(refine.type bit N where (and (fx<= 0 N) (fx<= N 1)))
(refine.type single N : bit where (fx= N 1))
(refine.type (one-or-two B) Xs : (nonempty B) where (<= (length Xs) 2))
(define add-bits {bit --> bit --> fixnum} A B -> (fx+ A B))
(define-checked from-unit {single --> fixnum} N -> (fx+ (from-0 (fx- N 1)) (add-bits N N)))
(define the-unit {--> single} -> 1)
(define twice-the-unit {--> fixnum} -> (fx+ (the-unit) (add-bits (the-unit) (the-unit))))
(define all-of {(list A) --> (list A)} Xs -> Xs)
(define-checked both {(one-or-two A) --> (list A)} Xs -> [(first Xs) | (all-of Xs)])
(define first {(nonempty A) --> A} Xs -> (head Xs))
(define-checked five {--> R : fixnum} {ensures (fx= R 5)} -> 5)
(define-checked five-more {fixnum --> fixnum} N -> (fx+ N (from-0 (fx- (five) 5))))

\\ A refined type is its base to the kernel.
(define same-unit? {single --> fixnum --> boolean} X Y -> (= X Y))
(define same-mode? {mode-name --> symbol --> boolean} X S -> (= X S))
(refine.type mode-name S : symbol where (or (= S read) (= S write)))
(define never? {natural --> boolean} X -> (= X -3))
(define-checked told-by {single --> bit --> fixnum} X Y -> (if (= X Y) (from-0 (fx- Y 1)) 0))

\\ A promise that equates is a definition where what it names is not defined by it again.
(define-checked twice {N : fixnum --> R : fixnum} {ensures (fx= R (fx+ N N))} N -> (fx* 2 N))
(define-checked fourfold {N : fixnum --> R : fixnum} {ensures (fx= R (fx+ (twice N) (twice N)))} N -> (fx* 4 N))
(define-checked at-most {A : fixnum --> N : fixnum --> fixnum} {requires (fx<= (fourfold A) N)} A _ -> A)
(define-checked at-most-a-quarter {fixnum --> fixnum} N -> (at-most N (fx* 4 N)))

(define refine-data.main
  {--> string}
  -> (@s (make-string "~A ~A ~A ~A " (least-of [5 3 4]) (by-name 6 7) (opened read) (opening write))
         (make-string "~A ~A ~A ~A " (least-if-sorted []) (by-parts 5 9) (by-variable 4 9) (both-lists [2] [1]))
         (make-string "~A ~A ~A ~A " (small-or-0 99) (recoded read read) (by-test [1 2]) (chance (clamped 0.5)))
         (make-string "~A ~A ~A ~A " (chance (clamped 7)) (second-by-length [1]) (made 2 5) (same-mode write write))
         (make-string "~A ~A " (sliced 1 9 10) (named-or "ok"))
         (make-string "~A ~A " (= (with-itself-back [1 2 3]) 10) (= (quarter 0.1) (ordered 0 2 1)))
         (make-string "~A ~A ~A " (first-natural [8 9]) (rise (@p 3 5)) (couple-size [4 6]))
         (make-string "~A ~A ~A " (counted read [read write read]) (at-most-a-quarter 11) (head (rises (@p 2 9))))
         (make-string "~A ~A ~A ~A" (from-unit 1) (twice-the-unit) (both [4 5]) (five-more 2))
         (make-string " ~A ~A ~A" (stepped 3) (stepped-back 8 2) (stepped-back 2 8))
         (make-string " ~A ~A ~A ~A" (same-unit? 1 1) (same-mode? read read) (never? 3) (told-by 1 1))))
