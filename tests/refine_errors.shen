(refine.type natural N where (fx<= 0 N))
(refine.type octet N : natural where (fx<= N 255))
(refine.type digit N where (and (fx<= 0 N) (fx<= N 9)))
(refine.type span P : (fixnum * fixnum) where (fx<= (fst P) (snd P)))
(refine.type (nonempty A) Xs : (list A) where (not (empty? Xs)))
(refine.type name S : string where (not (= S "")))
(refine.type square N where (fx<= 0 (fx* N N)))
(define natural->fixnum {natural --> fixnum} N -> N)
(define octet->natural {octet --> natural} N -> N)
(define digit->fixnum {digit --> fixnum} N -> N)
(define span->fixnum {span --> fixnum} P -> 1)
(define first {(nonempty A) --> A} Xs -> (head Xs))
(define name->string {name --> string} S -> S)
(define square->fixnum {square --> fixnum} N -> N)
(define-checked at {I : fixnum --> fixnum} {requires (fx<= 0 I)} I -> I)
(defstruct box (count : natural))
\\ says type error in rule 1 of f: natural->fixnum needs (fx<= 0 (fx- X 1)), which may not be so, as if X is 0
(define f {fixnum --> fixnum} X -> (natural->fixnum (fx- X 1)))
\\ says type error in rule 2 of f: f promises (fx<= 0 X), which may not be so, as if X is -1
(define f {fixnum --> natural} 0 -> 0 X -> X)
\\ says type error in rule 2 of f
(define f {fixnum --> fixnum} X -> (natural->fixnum X) where (fx< X 5) X -> (cn "a" "b"))
\\ says type error in rule 2 of f
(define f {fixnum --> fixnum} X -> (natural->fixnum X) where (fx> X 5) X -> (cn "a" "b"))
\\ says type error in rule 1 of f: octet->natural needs (fx<= 256 255), which may not be so
(define f {--> natural} -> (octet->natural 256))
\\ says type error in rule 1 of f: octet->natural needs (fx<= X 255), which may not be so, as if X is 256
(define f {natural --> natural} X -> (octet->natural X))
\\ says type error in rule 1 of f: octet->natural needs (fx<= 0 X), which may not be so, as if X is -1
(define f {fixnum --> natural} X -> (octet->natural X))
\\ says type error in rule 1 of f: span->fixnum needs (fx<= (fst (@p A B)) (snd (@p A B))), which may not be so, as if A is 1 and B is 0
(define f {fixnum --> fixnum --> fixnum} A B -> (span->fixnum (@p A B)))
\\ loads
(define f {span --> fixnum} (@p A B) -> A)
\\ says type error in rule 1 of f: first needs (not (empty? Xs)), which may not be so, as if (empty? Xs) is true
(define f {(list fixnum) --> fixnum} Xs -> (first Xs))
\\ says refine: (list natural) has a refined type in it, which is for a whole argument, result or field, in the signature of f
(define f {fixnum --> (list natural)} X -> [1 X])
\\ says type error in rule 1 of f: box.make needs (fx<= 0 X), which may not be so, as if X is -1
(define f {fixnum --> box} X -> (box.make X))
\\ says type error in rule 1 of f: name->string needs (not (= S "")), which may not be so, as if S is ""
(define f {string --> string} S -> (name->string S))
\\ says type error in rule 1 of f: square->fixnum needs (fx<= 0 (fx* X X)), which may not be so, as if (fx* X X) is -1
(define f {fixnum --> fixnum} X -> (square->fixnum X))
\\ says type error in rule 1 of f: f promises (fx<= 0 (fx- X 1)), which may not be so, as if X is 0
(define f {fixnum --> natural} X -> (if (fx> X 5) X (fx- X 1)))
\\ says type error in rule 1 of f: f promises (fx<= 0 (fx- Y 1)), which may not be so, as if X is 0
(define f {fixnum --> natural} X -> (let Y (fx- X 2) (fx- Y 1)))
\\ says type error in rule 1 of f: f promises (fx<= 0 X), which may not be so, as if X is -1
(define f {fixnum --> natural} X -> (do (print X) X))
\\ loads
(define f {fixnum --> natural} X -> (if (fx> X 5) (let Y (fx- X 2) (fx- Y 1)) 5))
\\ says type error in rule 1 of f: f promises (fx<= 0 (fx- Y 1)), which may not be so, as if X is 6
(define f {fixnum --> natural} X -> (if (fx> X 5) (let Y (fx- X 9) (fx- Y 1)) 5))
\\ says type error in rule 1 of f: f promises (fx<= 0 (fx- Y 1)), which may not be so, as if X is 0
(define f {fixnum --> natural} X -> (if (fx> X 5) 5 (let Y (fx- X 2) (fx- Y 1))))
\\ says type error in rule 1 of f: f promises (fx<= 0 X), which may not be so, as if X is -1
(define f {fixnum --> fixnum --> natural} X Y -> X where (fx> (if (fx> Y 0) Y 1) 0))
\\ says type error in rule 1 of f: digit->fixnum needs (fx<= X 9), which may not be so, as if X is 10
(define f {natural --> fixnum} X -> (digit->fixnum X))
\\ says type error in rule 1 of f: octet->natural needs (fx<= X 255), which may not be so, as if X is 256
(define-checked f {X : fixnum --> natural} {requires (fx<= 0 X)} X -> (octet->natural X))
\\ says type error in rule 1 of f: digit->fixnum needs (fx<= X 9), which may not be so, as if X is 10
(define-checked f {X : fixnum --> fixnum} {requires (fx<= 0 X)} X -> (digit->fixnum X))
\\ says type error in rule 1 of f: f promises (fx<= 0 (fx- Y 1)), which may not be so, as if Y is 0
(define-checked f {X : fixnum --> Y : fixnum --> natural} {requires (fx<= 0 X)} X Y -> (if (fx> X 5) (if (fx> Y X) Y (fx- Y 1)) X))
\\ says type error in rule 1 of f: f promises (fx<= 0 (fx- X 1)), which may not be so, as if X is 0
(define-checked f {N : natural --> Y : fixnum --> X : fixnum --> natural} {requires (fx<= 0 X)} N Y X -> (let B (if (fx> X 3) (= N Y) false) (fx- X 1)))
\\ says type error in rule 2 of f: f promises (fx<= 0 (fx- X 1)), which may not be so, as if X is 0
(define-checked f {X : fixnum --> natural} {requires true} X -> X where (fx> X 5) X -> (fx- X 1))
\\ says type error in rule 1 of f: at needs (fx<= 0 X), which may not be so, as if X is -1
(define-checked f {N : natural --> X : fixnum --> fixnum} {requires (fx<= X 9)} N X -> (if (= N X) 1 (at X)))
\\ says type error in rule 1 of f
(define f {symbol --> fixnum} X -> (natural->fixnum X))
\\ says type error in rule 1 of f.%bodyguard
(define f.%bodyguard {symbol --> fixnum} X -> (natural->fixnum X))
\\ says type error in rule 1 of f
(define f {fixnum --> fixnum} X -> (natural->fixnum (nowhere X)))
\\ says type error in rule 1 of f
(define f {natural --> fixnum --> string} X Y -> (if (= X Y) (cn "a" 3) "b"))
\\ says type error in rule 1 of f
(define f {natural --> fixnum --> boolean --> string} X Y B -> (let Z (if B X Y) (cn Z "")))
\\ says type error in rule 1 of f
(define-checked f {X : fixnum --> string} {requires (fx<= 0 X)} X -> (cn (natural->fixnum X) ""))
\\ says type error in rule 1 of g: natural->fixnum needs (fx<= 0 (if B X Y)), which may not be so, as if X is 0 and Y is -1 and B is false
(define g {natural --> fixnum --> boolean --> fixnum} X Y B -> (if (= X Y) 1 (natural->fixnum (if B X Y))))
\\ says type error: natural->fixnum needs (fx<= 0 -3), which may not be so
(natural->fixnum -3)
\\ says type error: natural->fixnum needs (fx<= 0 X), which may not be so, as if X is -1
(map (/. X (natural->fixnum X)) [1 -2])
\\ says type error
(natural->fixnum "s")
\\ says type error
(nowhere 1)
\\ says type error in rule 1 of f: f promises (fx<= 0 X), which may not be so, as if X is -1
(define f {fixnum --> natural} X -> X)
\\ loads
(define unsure {fixnum --> fixnum} X -> X)
(define unsure? {fixnum --> boolean} X -> true)
(define sure? {fixnum --> boolean} X -> true)
(refine.pure sure?)
(define-checked needs-unsure {X : fixnum --> fixnum} {requires (unsure? X)} X -> X)
(define-checked needs-sure {X : fixnum --> fixnum} {requires (sure? X)} X -> X)
(define-checked first-byte {B : buffer.storage --> fixnum} {requires (fx< 0 (shen-jit.bytes-length B))} B -> (shen-jit.u8 B 0))
\\ says type error in rule 1 of f: at needs (fx<= 0 (unsure X)), which may not be so, as if (unsure X) is -1. unsure is not declared pure, so (unsure X) may be another each time
(define-checked f {fixnum --> fixnum} X -> (if (fx<= 0 (unsure X)) (at (unsure X)) 0))
\\ says type error in rule 1 of f: at needs (fx<= 0 (unsure Y)), which may not be so, as if (unsure Y) is -1
(define-checked f {fixnum --> fixnum --> fixnum} X Y -> (if (fx<= 0 (unsure X)) (at (unsure Y)) 0))
\\ says type error in rule 1 of f: at needs (fx<= 0 (unsure Y)), which may not be so, as if (unsure Y) is -1. unsure is not declared pure, so (unsure Y) may be another each time
(define-checked f {fixnum --> fixnum --> fixnum} X Y -> (if (and (fx<= 0 (unsure X)) (fx<= 0 (unsure Y))) (fx+ (at (unsure Y)) 0) 0))
\\ says type error in rule 1 of f: at needs (fx<= 0 (<-vector V 1)), which may not be so, as if (<-vector V 1) is -1. <-vector is not declared pure, so (<-vector V 1) may be another each time
(define-checked f {(vector fixnum) --> fixnum} V -> (if (fx<= 0 (<-vector V 1)) (at (<-vector V 1)) 0))
\\ says type error in rule 1 of f: f promises (fx<= 0 (unsure X)), which may not be so, as if (unsure X) is -1. unsure is not declared pure, so (unsure X) may be another each time
(define-checked f {fixnum --> natural} X -> (if (fx<= 0 (unsure X)) (unsure X) 0))
\\ says type error in rule 1 of f: needs-unsure needs (unsure? X), which may not be so, as if (unsure? X) is false. unsure? is not declared pure, so (unsure? X) may be another each time
(define-checked f {fixnum --> fixnum} X -> (if (unsure? X) (needs-unsure X) 0))
\\ says type error in rule 1 of g: needs-unsure needs (unsure? X), which may not be so, as if (unsure? X) is false. unsure? is not declared pure, so (unsure? X) may be another each time
(define g {fixnum --> fixnum} X -> (if true (needs-unsure X) 0))
\\ says type error in rule 1 of f: in-order needs (fx<= (unsure X) (unsure Y)), which may not be so, as if (unsure X) is 1 and (unsure Y) is 0. unsure is not declared pure, so (unsure X) may be another each time
(define-checked in-order {A : fixnum --> B : fixnum --> fixnum} {requires (fx<= A B)} A B -> A)
(define-checked f {fixnum --> fixnum --> fixnum} X Y -> (if (fx<= (unsure X) 5) (in-order (unsure X) (unsure Y)) 0))
\\ loads
(define g {fixnum --> fixnum} X -> (at (let Y X Y)) where (fx<= 0 (let Y X Y)))
\\ says type error in rule 1 of f: needs-sure needs (sure? X), which may not be so, as if (sure? X) is false
(define-checked f {fixnum --> fixnum} X -> (needs-sure X))
\\ says type error in rule 1 of f: at needs (fx<= 0 (at X)), which may not be so, as if (at X) is -1. at is not declared pure, so (at X) may be another each time
(define-checked f {X : fixnum --> fixnum} X -> (if (and (fx<= 0 X) (fx<= 0 (at X))) (at (at X)) 0))
\\ loads
(define-checked f {fixnum --> fixnum} X -> (let Y (unsure X) (if (and (sure? Y) (fx<= 0 Y)) (fx+ (at Y) (needs-sure Y)) 0)))
\\ loads
(define-checked tagged {B : buffer.storage --> fixnum} {requires (fx< 1 (shen-jit.bytes-length B)) (fx= 7 (first-byte B))} B -> (first-byte B))
(refine.pure first-byte)
(define-checked f {buffer.storage --> fixnum} B -> (if (and (fx< 1 (shen-jit.bytes-length B)) (fx= 7 (first-byte B))) (tagged B) 0))
\\ loads
(define-checked either {B : buffer.storage --> fixnum} {requires (or (fx= 0 (shen-jit.bytes-length B)) (fx= 7 (first-byte B)))} B -> 1)
\\ says type error in the condition of untagged: first-byte needs (fx< 0 (shen-jit.bytes-length B)), which may not be so, as if (shen-jit.bytes-length B) is 0
(define-checked untagged {B : buffer.storage --> fixnum} {requires (fx= 7 (first-byte B)) (fx< 1 (shen-jit.bytes-length B))} B -> (first-byte B))
\\ An argument has the name that the signature gives it, or its pattern.
\\ says type error in rule 1 of by-name: by-name promises (fx= X 5), which may not be so, as if X is 0
(define-checked by-name {X : fixnum --> R : fixnum} {ensures (fx= X 5)} _ -> 1)
\\ says type error in rule 1 of by-pattern: by-pattern promises (fx= X Y), which may not be so, as if X is -1 and Y is 0
(define-checked by-pattern {fixnum --> Y : fixnum --> R : fixnum} {ensures (fx= R Y)} X _ -> X)
\\ Where a number is among those that are written.
\\ loads
(define-checked unit-probe {X : number --> fixnum} {requires (> X 0) (< X 1)} _ -> 1)
\\ says type error in rule 1 of places: unit-probe needs (> X 0), which may not be so, as if X is no number
(define places {number --> fixnum} X -> (unit-probe X))
\\ says type error in rule 1 of places: unit-probe needs (< X 1), which may not be so, as if X is 1
(define places {number --> fixnum} X -> (unit-probe X) where (> X 0))
\\ says type error in rule 1 of places: unit-probe needs (< X 1), which may not be so, as if X is 1
(define places {number --> fixnum} X -> (unit-probe X) where (and (> X 0.5) (< X 2.5)))
\\ says type error in rule 1 of places: unit-probe needs (< X 1), which may not be so, as if X is 1
(define places {number --> fixnum} X -> (unit-probe X) where (>= X 1))
\\ says type error in rule 1 of places: unit-probe needs (> X 0), which may not be so, as if X is no number
(define places {number --> fixnum} X -> (if (or (<= X 0) (>= X 1)) 0 (unit-probe X)))
\\ What is not read as a declaration.
\\ says refine.type: (refine.type lower x where (fx< x 3)) is not (refine.type Name Variable : Base where Condition)
(refine.type lower x where (fx< x 3))
\\ says refine.type: Upper is not a type
(refine.type Upper X where (fx< X 3))
\\ says refine.type: _ is not a type
(refine.type _ X where (fx< X 3))
\\ says refine.type: (of-list (list A)) is not a type
(refine.type (of-list (list A)) X : (list A) where (cons? X))
\\ says refine.trust: (refine.trust (trusted-lower x) --> R where (fx< R 3)) is not (refine.trust (F Formal ...) --> Result where Condition)
(refine.trust (trusted-lower x) --> R where (fx< R 3))
\\ says refine: (natural --> fixnum) has a refined type in it, which is for a whole argument, result or field, in the signature of gives-taker
(define gives-taker {fixnum --> natural --> fixnum} X -> (/. Y (fx+ X Y)))
\\ says refine.type: (refine.type lower-2 x : number where (< x 3)) is not (refine.type Name Variable : Base where Condition)
(refine.type lower-2 x : number where (< x 3))
\\ loads
(define-checked from-0-probe {X : number --> fixnum} {requires (>= X 0)} _ -> 1)
(define-checked up-to-5-probe {X : number --> fixnum} {requires (<= X 5)} _ -> 1)
(define-checked less-probe {X : number --> Y : number --> fixnum} {requires (<= X Y)} _ _ -> 1)
\\ says type error in rule 1 of places: from-0-probe needs (>= X 0), which may not be so, as if X is below 0
(define places {number --> fixnum} X -> (from-0-probe X) where (< X 5))
\\ says type error in rule 1 of places: up-to-5-probe needs (<= X 5), which may not be so, as if X is above 5
(define places {number --> fixnum} X -> (up-to-5-probe X) where (> X 1))
\\ says type error in rule 1 of places: less-probe needs (<= X Y), which may not be so
(define places {number --> number --> fixnum} X Y -> (less-probe X Y) where (and (= X X) (and (= Y Y) (> X Y))))
\\ says type error in rule 1 of places: from-0-probe needs (>= X 0), which may not be so, as if X is between -2.5 and -1
(define places {number --> number --> fixnum} X Y -> (from-0-probe X) where (and (> X -2.5) (< X -1)))
