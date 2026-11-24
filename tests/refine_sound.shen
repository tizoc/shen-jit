\\ Programs that must not be believed, and some beside them that must be. Each case is loaded in turn.
(define-checked positive {X : fixnum --> fixnum} {requires (fx> X 0)} X -> X)
(define-checked same {A : fixnum --> B : fixnum --> fixnum} {requires (fx= A B)} A _ -> A)
(define-checked up-only {S : symbol --> symbol} {requires (= S up)} S -> S)
(define-checked no-fixnum {X : number --> number} {requires (not (shen-jit.fixnum? X))} X -> X)
(define-checked a-fixnum {X : number --> number} {requires (shen-jit.fixnum? X)} X -> X)
(defstruct span (start : fixnum) (end : fixnum))
\\ The wildcards of a pattern are not one another.
\\ says type error in rule 2 of wild: positive needs (fx> -1 0), which may not be so
(define-checked wild {(fixnum * fixnum) --> fixnum} (@p X Y) -> 0 where (fx= X Y) (@p _ _) -> (positive -1))
\\ says type error in rule 1 of wild: positive needs (fx> -1 0), which may not be so
(define-checked wild {Xs : (list symbol) --> fixnum} {requires (cons? Xs) (= (head Xs) a)} [_ | Ys] -> (positive -1) _ -> 0)
\\ says type error in rule 1 of wild: wild promises (fx= (fst P) (snd P)), which may not be so, as if (fst P) is -1 and (snd P) is 0
(define-checked wild {P : (fixnum * fixnum) --> R : boolean} {ensures (fx= (fst P) (snd P))} (@p _ _) -> true)
\\ loads
(define-checked wild {P : (fixnum * fixnum) --> fixnum} {requires (fx= (fst P) (snd P))} (@p _ Y) -> (same Y Y) where (fx> Y 0) (@p X Y) -> (same X Y))
\\ An action that tries the next clause.
\\ says type error in rule 1 of failing: failing promises (= (fail) up), which may not be so
(define-checked failing {X : fixnum --> R : symbol} {ensures (= R up)} X -> (if (fx> X 0) up (fail)))
\\ loads
(define-checked failing {X : fixnum --> R : symbol} {ensures (= R up)} X <- (if (fx> X 0) up (fail)) _ -> up)
\\ says type error in rule 2 of where-action: positive needs (fx> (if (fx= X 0) 0 1) 0), which may not be so, as if X is 0
(define-checked where-action {fixnum --> fixnum} 0 -> (where false 5) X -> (positive (if (fx= X 0) 0 1)))
\\ loads
(define-checked where-action {fixnum --> fixnum} X -> (where (fx> X 3) (positive X)) _ -> 0)
(define where-actions {fixnum --> fixnum} X -> (where (fx> X 3) (where (fx< X 9) (positive X))) _ -> 0)
\\ says refine: a where that is no guard in rule 1 of where-retried
(define-checked where-retried {fixnum --> fixnum} X <- (where (fx> X 3) (positive X)) _ -> 0)
\\ says refine: a where that is no guard in rule 1 of where-retried
(define where-retried {fixnum --> fixnum} X <- (where (fx> X 3) (positive X)) _ -> 0)
\\ says type error in rule 1 of where-inside
(define where-inside {fixnum --> fixnum} X -> (fx+ 1 (where (fx> X 3) (positive X))) _ -> 0)
\\ says type error in rule 1 of fails-if
(define-checked fails-if {X : fixnum --> R : symbol} {ensures (= R up)} X -> (fail-if (/. Y (= Y up)) up))
\\ loads
(define-checked fails-if {X : fixnum --> R : symbol} {ensures (= R up)} X <- (fail-if (/. Y (= Y down)) up) _ -> up)
\\ says type error in rule 1 of fails-if: fails-if promises (= (fail) up), which may not be so
(define-checked fails-if {X : fixnum --> R : symbol} {ensures (= R up)} X <- (fail-if (/. Y (= Y down)) (if (fx> X 0) up (fail))) _ -> up)
\\ loads
(define-checked at-4 {X : fixnum --> fixnum} {requires (fx> X 3) (fx< X 9)} X -> X)
(define-checked where-guarded {fixnum --> fixnum} X -> (where (fx> X 3) (at-4 X)) where (fx< X 9) _ -> 0)
(define where-guarded-2 {fixnum --> fixnum} X -> (where (fx> X 3) (at-4 X)) where (fx< X 9) _ -> 0)
\\ says type error in rule 1 of in-guard: positive needs (fx> X 0), which may not be so, as if X is 0
(define in-guard {fixnum --> fixnum} X -> 1 where (fx= 1 (positive X)) _ -> 2)
\\ What is not a call of a function with a condition tests it, or has none.
\\ loads
(define by-fn {fixnum --> fixnum} X -> (head (map (fn positive) [X])))
(if (= (trap-error (by-fn -1) (/. E 7)) 7) true (simple-error "not tested"))
\\ says type error in rule 1 of by-lambda: positive needs (fx> Yes 0), which may not be so, as if Yes is 0
(define by-lambda {fixnum --> (fixnum --> fixnum)} X -> (/. Yes (positive Yes)))
\\ loads
(define-checked adder {X : fixnum --> (fixnum --> fixnum)} {requires (fx> X 0)} X -> (/. Y (fx+ X Y)))
(define over-adder {fixnum --> fixnum} X -> (adder X 1))
(if (= (trap-error (over-adder -1) (/. E 7)) 7) true (simple-error "not tested"))
(if (= (over-adder 1) 2) true (simple-error "not 2"))
\\ loads
(define shadows {fixnum --> fixnum} X -> (let positive (/. Y (fx+ X Y)) (positive -1)))
(if (= (shadows 1) 0) true (simple-error "not 0"))
\\ What is given more arguments than it takes, as a pure function gives a function.
\\ says type error in rule 1 of over: same needs (fx= ((fst P) x) ((fst P) x)), which may not be so, as if ((fst P) x) is -1 and ((fst P) x) is 0
(define-checked over {((symbol --> fixnum) * fixnum) --> fixnum} P -> (same ((fst P) x) ((fst P) x)))
\\ says type error in rule 1 of applied: positive needs (fx> X 0), which may not be so, as if X is 0
(define-checked over {X : fixnum --> R : (fixnum --> fixnum)} {ensures (fx> X 100)} X -> (if (fx> X 100) (/. Y Y) (simple-error "no")))
(define-checked applied {fixnum --> boolean --> fixnum} X B -> (let Z (fx+ 0 ((if B (over X) (/. Y 5)) 1)) (positive X)))
\\ Equality of what changes, however it is asked.
\\ says type error in rule 1 of changes: positive needs (fx> -1 0), which may not be so
(define-checked changes {(vector fixnum) --> (vector fixnum) --> fixnum} V W -> (let A (= V W) X (vector-> V 1 99) (if A (if (= V W) 1 (positive -1)) 1)))
\\ loads
(define-checked changes {(vector fixnum) --> (vector fixnum) --> fixnum} V W -> (let A (= V W) (if A (if A 1 (positive -1)) 1)))
\\ says type error in rule 1 of changes: positive needs (fx> -1 0), which may not be so
(define-checked changes {(vector fixnum) --> (vector fixnum) --> fixnum} V W -> (let A (element? V [W]) X (vector-> V 1 99) (if A (if (element? V [W]) 1 (positive -1)) 1)))
\\ says type error in rule 1 of changes: positive needs (fx> -1 0), which may not be so
(define-checked changes {(list (vector fixnum)) --> (list (vector fixnum)) --> fixnum} V W -> (let A (= V W) X (vector-> (head V) 1 99) (if A (if (= V W) 1 (positive -1)) 1)))
\\ loads
(define pure-of {boolean --> fixnum} X -> (if X 1 2))
(refine.pure pure-of)
(define-checked stays {(list fixnum) --> (list fixnum) --> fixnum} V W -> (same (pure-of (= V W)) (pure-of (= V W))))
(define-checked stays-in {fixnum --> fixnum --> fixnum} V W -> (same (pure-of (element? V [W])) (pure-of (element? V [W]))))
\\ says type error in rule 1 of changes: same needs (fx= (pure-of (= V W)) (pure-of (= V W))), which may not be so, as if (pure-of (= V W)) is 1 and (pure-of (= V W)) is 0. What it compares may change, so (= V W) may be another each time
(define-checked changes {(vector fixnum) --> (vector fixnum) --> fixnum} V W -> (same (pure-of (= V W)) (pure-of (= V W))))
\\ says type error in rule 1 of changes: same needs (fx= (pure-of (or (= V W) false)) (pure-of (or (= V W) false))), which may not be so, as if (pure-of (or (= V W) false)) is 1 and (pure-of (or (= V W) false)) is 0. What it compares may change, so (= V W) may be another each time
(define-checked changes {(vector fixnum) --> (vector fixnum) --> fixnum} V W -> (same (pure-of (element? V [W])) (pure-of (element? V [W]))))
\\ says type error in rule 1 of changes: same-vectors needs (= V W), which may not be so, as if (= V W) is false. What it compares may change, so (= V W) may be another each time
(define-checked same-vectors {V : (vector fixnum) --> W : (vector fixnum) --> fixnum} {requires (= V W)} _ _ -> 1)
(define-checked changes {(vector fixnum) --> (vector fixnum) --> fixnum} V W -> (if (= V W) (same-vectors V W) 1))
\\ A Boolean, beside something else that may be one.
\\ loads
(datatype sometimes-boolean
  X : boolean;
  ____________
  X : sometimes-boolean;

  _______________________
  null : sometimes-boolean;)
\\ says type error in rule 3 of kind: positive needs (fx> -1 0), which may not be so
(define-checked kind {sometimes-boolean --> fixnum} true -> 1 false -> 2 _ -> (positive -1))
\\ loads
(define-checked kind {X : sometimes-boolean --> fixnum} {requires (not (= X true))} true -> (positive -1) _ -> 2)
(define-checked kinds {sometimes-boolean --> fixnum} true -> 1 X -> (kind X))
\\ What a pattern matches is equal to it, which another number may be: 1.0 to 1, and a float so large that 1 more is no more.
\\ says type error in rule 1 of equals: a-fixnum needs (shen-jit.fixnum? A), which may not be so, as if (shen-jit.fixnum? A) is false
(define-checked equals {X : number --> Y : number --> number} {requires (shen-jit.fixnum? X)} A A -> (a-fixnum A) _ _ -> 0)
\\ says type error in rule 1 of equals: no-fixnum needs (not (shen-jit.fixnum? 1)), which may not be so
(define-checked equals {X : number --> number} {requires (not (shen-jit.fixnum? X))} 1 -> (no-fixnum 1) _ -> 0)
\\ says type error in rule 1 of equals: positive needs (fx> -1 0), which may not be so
(define-checked equals {X : number --> fixnum} {requires (not (> (+ X 1) X))} 9007199254740992 -> (positive -1) _ -> 0)
\\ says type error in rule 1 of equals: positive needs (fx> -1 0), which may not be so
(define-checked equals {X : number --> Y : number --> fixnum} {requires (> (+ X 1) X) (not (> (+ Y 1) Y))} A A -> (positive -1) _ _ -> 0)
\\ loads
(define-checked equals {X : number --> number} {requires (shen-jit.fixnum? X)} X -> (a-fixnum X))
(define-checked equals-tested {X : fixnum --> Y : fixnum --> fixnum} {requires (fx= 1 (pure-of (fx> X 0)))} A A -> (same (pure-of (fx> A 0)) 1) _ _ -> 0)
(define-checked equals-fixnums {X : fixnum --> Y : fixnum --> fixnum} {requires (fx> X 0)} A A -> (positive A) 1 Y -> 1 _ _ -> 0)
\\ And so is what is written again as the pattern was, as the kernel takes it for what that matched.
\\ says type error in rule 1 of again: a-fixnum needs (shen-jit.fixnum? (head (cons 1 Xs))), which may not be so, as if (shen-jit.fixnum? (head (cons 1 Xs))) is false
(define-checked again {(list number) --> number} [1 | Xs] -> (a-fixnum (head [1 | Xs])) _ -> 0)
\\ loads
(define-checked again {(list number) --> number} [1 | Xs] -> (a-fixnum (head [1 | [2 | Xs]])) _ -> 0)
(define-checked again-pair {(number * number) --> number} (@p 1 X) -> (a-fixnum (fst (@p 2 X))) _ -> 0)
\\ says type error in rule 1 of again: a-fixnum needs (shen-jit.fixnum? (snd (@p X 1))), which may not be so, as if (shen-jit.fixnum? (snd (@p X 1))) is false
(define-checked again {(number * number) --> number} (@p X 1) -> (a-fixnum (snd (@p X 1))) _ -> 0)
\\ says type error in rule 1 of again: a-fixnum needs (shen-jit.fixnum? (two-numbers.v (two-numbers.%make 1 W))), which may not be so, as if (shen-jit.fixnum? (two-numbers.v (two-numbers.%make 1 W))) is false
(defstruct two-numbers (v : number) (w : number))
(define-checked again {two-numbers --> number} (:two-numbers v <- 1 w <- W) -> (a-fixnum (two-numbers.v (:two-numbers v <- 1 w <- W))) _ -> 0)
\\ says type error in rule 1 of again: again promises (or (empty? (cons 1 ())) (shen-jit.fixnum? (head (cons 1 ())))), which may not be so, as if (empty? (cons 1 ())) is false and (shen-jit.fixnum? (head (cons 1 ()))) is false
(refine.type whole X : number where (shen-jit.fixnum? X))
(define-checked again {Xs : (list number) --> R : (list number)} {ensures (or (empty? R) (shen-jit.fixnum? (head R)))} [1] -> [1] _ -> [])
\\ loads
(define-checked again {Xs : (list number) --> R : (list number)} {ensures (or (empty? R) (shen-jit.fixnum? (head R)))} [1] -> [2] _ -> [])
(define again-whole {whole --> whole} 25 -> 25 X -> X)
\\ says type error in rule 1 of again: again promises (shen-jit.fixnum? 25.0), which may not be so, as if (shen-jit.fixnum? 25.0) is false
(define again {whole --> whole} 25 -> 2.5e1 X -> X)
\\ says type error in rule 1 of again: again promises (shen-jit.fixnum? X), which may not be so, as if (shen-jit.fixnum? X) is false
(define again {whole --> number --> whole} X X -> X _ _ -> 0)
\\ says type error in rule 1 of again: again promises (shen-jit.fixnum? (fst (@p X X))), which may not be so, as if (shen-jit.fixnum? (fst (@p X X))) is false. What it is in may change, so (@p X X) may be another each time
(define-checked again {P : (number * number) --> R : (number * number)} {requires (shen-jit.fixnum? (fst P))} {ensures (shen-jit.fixnum? (fst R))} (@p X X) -> (@p X X) P -> P)
\\ says type error in rule 1 of again-symbol
(define again-symbol {symbol --> fixnum} 0 -> 1 _ -> 2)
\\ loads
(define again {number --> whole --> whole} X X -> X _ _ -> 0)
(define empty-vector {(vector fixnum) --> fixnum} <> -> 0 _ -> 1)
(define-checked guarded-again {X : fixnum --> Y : fixnum --> fixnum} {requires (fx> X 0)} A A -> (positive A) where (fx< A 9) _ _ -> 0)
(define-checked again-tested {X : fixnum --> Y : fixnum --> fixnum} {requires (fx= 1 (pure-of (fx> X 0)))} A A -> (same (pure-of (fx> A 0)) 1) where (fx< A 9) _ _ -> 0)
(define-checked literal-tested {X : fixnum --> fixnum} {requires (fx= 1 (pure-of (fx> X 0)))} 3 -> (same (pure-of (fx> 3 0)) 1) _ -> 0)
(refine.type over-9 N where (fx> N 9))
(define plain-again {over-9 --> fixnum --> fixnum} A A -> (positive A) _ _ -> 0)
(define kind-of {number --> fixnum} X -> (if (shen-jit.fixnum? X) 1 2))
(refine.pure kind-of)
\\ says type error in rule 1 of again: same needs (fx= (kind-of 25) (kind-of 25.0)), which may not be so, as if (kind-of 25) is -1 and (kind-of 25.0) is 0
(define-checked again {--> fixnum} -> (same (kind-of 25) (kind-of 2.5e1)))
\\ loads
(define-checked again {--> fixnum} -> (same (kind-of 2.5e1) (kind-of 2.5e1)))
\\ loads
(define-checked of-25 {X : fixnum --> fixnum} {requires (fx= X (kind-of 25))} X -> X)
(define-checked calls-25 {--> fixnum} -> (of-25 (kind-of 25)))
\\ loads
(define-checked of-25 {X : fixnum --> fixnum} {requires (fx= X (kind-of 2.5e1))} X -> (simple-error "called with 1"))
(if (= (calls-25) 1) true (simple-error "not 1"))
\\ A name that is bound is no other, whatever it is.
\\ says type error in rule 1 of bound: bound promises (= down up), which may not be so
(define-checked bound {--> R : symbol} {ensures (= R up)} -> (let up down up))
\\ loads
(define-checked bound {--> R : symbol} {ensures (= R down)} -> (let up down up))
\\ says type error in rule 1 of bound: positive needs (fx> X 0), which may not be so, as if X is 0
(define-checked bound {fixnum --> fixnum} X -> 0 where (let not (/. B B) (if (not (fx> X 0)) true (fx> (positive X) 0))) _ -> 1)
\\ says refine: bound has a condition with let, and conditions bind nothing
(define-checked bound {X : fixnum --> fixnum} {requires (let not (/. X X) (if (not (fx> X 0)) true (fx> (positive X) 0)))} X -> 1)
\\ loads
(refine.type ab S : symbol where (or (= S a) (= S b)))
(define-checked ab-only {S : symbol --> fixnum} {requires (or (= S a) (= S b))} S -> 1)
\\ says type error in rule 1 of bound: ab-only needs (or (= S a) (= S b)), which may not be so, as if S is up
(define-checked bound {symbol --> fixnum} S -> 0 where (let up (type (if (= S up) a b) ab) (if (= up a) (fx> (ab-only S) 0) false)) _ -> 1)
\\ says type error in rule 1 of bound: ab-only needs (or (= S a) (= S b)), which may not be so, as if S is _
(define-checked bound {symbol --> fixnum} S -> (let _ (type (if (= S _) a b) ab) (if (= _ a) (ab-only S) 0)))
\\ loads
(refine.type fin S : symbol where (= S refine.done))
(define-checked fin-only {S : symbol --> fixnum} {requires (= S refine.done)} S -> 1)
\\ says type error in rule 1 of bound: fin-only needs (= S refine.done), which may not be so
(define-checked bound {fin --> symbol --> fixnum} refine.done S -> (do S (fin-only S)))
\\ loads
(define-checked bound {fixnum --> fixnum} X -> (positive (let Y (fx+ 2 3) (do (fx+ X Y) Y))))
\\ loads
(define-checked bound {fixnum --> fixnum} X -> (let _ (fx+ X 1) _ 3 (if (fx> X 0) (positive X) 1)))
\\ Types.
\\ says refine.type: A is not a parameter of any
(refine.type any X : A where true)
\\ says refine.type: list is a type already
(refine.type list N where (fx< 1 0))
\\ says refine.type: span is under itself
(refine.type span S : span where (fx<= (span.start S) (span.end S)))
\\ says refine.type: span is a type already
(refine.type span N where (fx> N 0))
\\ says refine.type: rising needs a condition on (number * number), not (fx< (fst P) (snd P))
(refine.type rising P : (number * number) where (fx< (fst P) (snd P)))
(define rises {rising --> boolean} P -> (< (fst P) (snd P)))
\\ says refine: rising has a condition that was refused, in the signature of rises
(define rises {(number * number) --> rising} P -> P)
\\ loads
(define rises {number --> number} X -> X)
(refine.type over-0 X where (over-0? X))
(define over-0? {fixnum --> boolean} X -> (fx> X 0))
\\ says refine.type: tree is under itself
(refine.type tree Ts : (list tree) where (<= (length Ts) 2))
(define same-trees {tree --> (list tree) --> boolean} X Y -> (= X Y))
\\ loads
(refine.type none N where (and (fx< N 0) (fx> N 0)))
(defstruct has-none (x : none))
(defstruct has-some (y : fixnum))
(struct.union either has-none has-some)
(define makes-none {fixnum --> has-none} X -> (simple-error "no"))
\\ says type error in rule 2 of no-none: positive needs (fx> -1 0), which may not be so
(define-checked no-none {either --> fixnum} (:has-none x <- X) -> 0 where (fx= X 1) _ -> (positive -1))
\\ says type error in rule 3 of pair-or-none: positive needs (fx> -1 0), which may not be so
(datatype pair-or-none
  X : fixnum; Y : fixnum;
  ========================
  (@p X Y) : pair-or-none;

  _________________
  [] : pair-or-none;)
(define-checked pair-or-none {pair-or-none --> fixnum} (@p X Y) -> 1 where (fx> X 0) (@p X Y) -> 2 where (fx<= X 0) _ -> (positive -1))
\\ loads
(define-checked pair-only {(fixnum * fixnum) --> fixnum} (@p X Y) -> 1 where (fx> X 0) (@p X Y) -> 2 where (fx<= X 0) _ -> (positive -1))
(define-checked span-only {span --> fixnum} (:span start <- 0 end <- _) -> 0 S -> (if (fx= (span.start S) 0) (positive -1) 1))
\\ says type error in rule 1 of of-triple: positive needs (fx> -1 0), which may not be so
(refine.type triple P : (fixnum * fixnum * fixnum) where (fx<= 0 (fst P)))
(define-checked of-triple {triple --> fixnum} P -> (if (shen-jit.fixnum? P) 1 (positive -1)))
\\ says refine: (list triple) has a refined type in it, which is for a whole argument, result or field, in the signature of uses-triples
(define uses-triples {(list triple) --> fixnum} P -> 1)
\\ says refine: width is a refined type and a struct
(refine.type width N where (fx> N 0))
(defstruct width (px : fixnum))
(define of-width {width --> fixnum} W -> (positive W))
\\ says refine.type: verified is a type already
(refine.type verified B : boolean where (= B false))
\\ says type error in rule 1 of no-none: positive needs (fx> X 0), which may not be so, as if X is 0
(define-checked no-none {X : fixnum --> fixnum} {requires (or (fx> X 0) (fx= 0 (has-none.x (makes-none X))))} X -> (positive X))
\\ says type error in rule 1 of if-none: positive needs (fx> -1 0), which may not be so
(define-checked if-none {boolean --> fixnum} B -> (let Z (if B (fx+ 0 (has-none.x (makes-none 1))) (fx+ 2 3)) (if (fx> Z 0) (positive -1) 0)))
\\ says type error in rule 1 of no-none: positive needs (fx> X 0), which may not be so, as if X is 0
(define pure-none {fixnum --> fixnum --> has-none} X Y -> (simple-error "no"))
(refine.pure pure-none)
(define-checked no-none {X : fixnum --> fixnum} {requires (or (fx> X 0) (fx= 0 (has-none.x (pure-none X X))))} X -> (positive X))
\\ What is not a condition, or not one that can be read.
\\ says refine: not a condition on what ill-typed takes and gives: (fx< X R)
(define-checked ill-typed {X : number --> R : number} {ensures (fx< X R)} X -> (+ X 1))
\\ says refine: own-name has refine.valued, which is refine's own
(define-checked own-name {X : fixnum --> R : fixnum} {ensures (fx= R (refine.valued 0))} X -> X)
\\ says refine: not a condition on what has-value takes and gives: (and (fx= 0 0) (fx= R (value 1)))
(define-checked has-value {X : fixnum --> R : fixnum} {ensures (fx= 0 0) (fx= R (value 1))} X -> X)
\\ A field's type is known of a struct that no one has read.
\\ loads
(refine.type from-0 N where (fx<= 0 N))
(defstruct counter (count : from-0))
(define-checked counted {C : counter --> fixnum} {requires (fx<= 0 (counter.count C))} _ -> 1)
(define-checked counts {counter --> fixnum} C -> (counted C))
\\ What is trusted is not checked, and is read as far as it can be.
\\ says type error in rule 1 of uses-oddly: positive needs (fx> (oddly X) 0), which may not be so, as if (oddly X) is 0
(define oddly {fixnum --> fixnum} X -> X)
(refine.trust (oddly X) --> R where (fx> (span.end (span.make X)) 0))
(define-checked uses-oddly {fixnum --> fixnum} X -> (positive (oddly X)))
\\ What is known of a function is of what it is now.
\\ loads
(defstruct ends (low : fixnum) (high : fixnum))
(define ends.make {fixnum --> fixnum --> ends} A B -> (if (fx<= A B) (:ends low <- A high <- B) (:ends low <- B high <- A)))
(defstruct sides (low : fixnum) (high : fixnum))
\\ says type error in rule 1 of uses-ends: same needs (fx= 9 (ends.low (ends.make 9 7))), which may not be so, as if (ends.low (ends.make 9 7)) is 10
(define-checked uses-ends {--> fixnum} -> (same 9 (ends.low (ends.make 9 7))))
\\ loads
(define-checked uses-ends {--> fixnum} -> (same 9 (ends.low (ends.%make 9 7))))
(define-checked uses-sides {--> fixnum} -> (same 9 (sides.low (sides.make 9 7))))
\\ loads
(define sides.low {sides --> fixnum} S -> (fx+ 1 (sides.high S)))
\\ says type error in rule 1 of uses-sides: same needs (fx= 9 (sides.low (sides.make 9 7))), which may not be so, as if (sides.low (sides.make 9 7)) is 10
(define-checked uses-sides {--> fixnum} -> (same 9 (sides.low (sides.make 9 7))))
\\ says type error in rule 1 of uses-ends: same needs (fx= 9 (ends.low (ends.%make 9 7))), which may not be so, as if (ends.low (ends.%make 9 7)) is 10
(define-checked uses-ends {--> fixnum} -> (same 9 (ends.low (ends.%make 9 7))))
(define ends.low {ends --> fixnum} S -> (fx+ 1 (ends.high S)))
\\ loads
(defstruct buffer (text : string) (mutable size : fixnum))
(define buffer.length {buffer --> fixnum} B -> (fx- (buffer.size B) 10))
\\ says type error in rule 1 of uses-buffer: positive needs (fx> (fx+ 1 (buffer.length (buffer.make "" 0))) 0), which may not be so, as if (buffer.length (buffer.make "" 0)) is -1
(define-checked uses-buffer {--> fixnum} -> (positive (fx+ 1 (buffer.length (buffer.make "" 0)))))
\\ says type error in rule 1 of uses-buffer: same needs (fx= N (buffer.length B)), which may not be so, as if N is -1 and (buffer.length B) is 0. buffer.length is not declared pure, so (buffer.length B) may be another each time
(define-checked uses-buffer {buffer --> fixnum} B -> (let N (buffer.length B) _ (buffer.size-> B 3) (same N (buffer.length B))))
\\ refine's own names.
\\ says type error in rule 1 of by-name
(define by-name {fixnum --> fixnum} X -> (positive.%body X))
\\ loads
(define own.%body {fixnum --> fixnum} X -> (fx+ X 1))
(define-checked own {X : fixnum --> fixnum} {requires (fx> X 0)} X -> X)
(define-checked own {X : fixnum --> fixnum} {requires (fx> X 1)} X -> X)
\\ A lambda is a function with some of its arguments only as the reader makes that.
\\ says type error in rule 1 of by-lambda: same needs (fx= -5 Y1), which may not be so, as if Y1 is 0
(define by-lambda {fixnum --> fixnum} X -> ((/. Y1 (same -5 Y1)) X))
\\ says type error in rule 1 of by-lambda: same needs (fx= -5 Yonder), which may not be so, as if Yonder is 0
(define by-lambda {fixnum --> fixnum} X -> ((/. Yonder (same -5 Yonder)) X))
\\ says type error in rule 1 of by-lambda: positive needs (fx> -5 0), which may not be so
(define by-lambda {fixnum --> fixnum} X -> ((/. Y999999 ((let Z (positive -5) (fn positive)) Y999999)) X))
\\ says type error in rule 1 of by-lambda: pairs needs (fx< Y999999 Y999999), which may not be so, as if Y999999 is 0
(define-checked pairs {A : fixnum --> B : fixnum --> fixnum} {requires (fx< A B)} A _ -> A)
(define by-lambda {fixnum --> fixnum} X -> ((/. Y999999 (pairs Y999999 Y999999)) X))
\\ loads
(define by-lambda {fixnum --> fixnum} X -> ((/. Y1 (same Y1 Y1)) ((same X) X)))
\\ says type error in rule 1 of by-marker
(define by-marker {fixnum --> fixnum} X -> (let V (type (type 0 refine.never) (refine.known false)) (positive X)))
\\ Definitions that could not be.
\\ says define-checked: no name
(define-checked)
\\ says define-checked: the clauses of bad do not have as many arguments
(define-checked bad {fixnum --> fixnum} 0 1 -> 1 X -> 2)
\\ says define-checked: bad names X twice
(define-checked bad {X : fixnum --> X : fixnum --> R : fixnum} {requires (fx> X 0)} A B -> B)
\\ A function may have the name of a refined type, as its promise is of the type.
\\ loads
(refine.type (both-named A) Xs : (list A) where (not (empty? Xs)))
(define-checked both-named {Xs : (list A) --> (both-named A)} {requires (cons? Xs)} Xs -> Xs)
(define uses-both-named {(list fixnum) --> number} Xs -> (length (both-named Xs)) where (not (empty? Xs)) _ -> 0)
\\ The order of a file: what is evaluated at once calls what is there.
\\ says type error: now needs (fx> 5 100), which may not be so
(define-checked now {X : fixnum --> fixnum} {requires (fx> X 100)} X -> X)
(now 5)
(define-checked now {X : fixnum --> fixnum} {requires (fx> X 0)} X -> X)
\\ says type error: same needs (fx= 2 (one)), which may not be so, as if (one) is 3
(define one {--> fixnum} -> 1)
(same 2 (one))
(define-checked one {--> R : fixnum} {ensures (fx= R 2)} -> 2)
\\ loads
(define two-now {--> fixnum} -> 1)
\\ says type error: same needs (fx= 2 (two-now)), which may not be so, as if (two-now) is 3
(same 2 (two-now))
(define-checked two-now {--> R : fixnum} {ensures (fx= R 2)} -> 2)
\\ loads
(define-checked two-now {--> R : fixnum} {ensures (fx= R 2)} -> 2)
\\ loads
(same 2 (two-now))
(define-checked two-now {--> R : fixnum} {ensures (fx= R 2)} -> 2)
\\ loads
(same 2 (two-now))
(define two-now {--> fixnum} -> 2)
\\ loads
(define-checked two-now {--> R : fixnum} {ensures (fx= R 2)} -> 2)
\\ says type error in rule 1 of uses-two: same needs (fx= 2 (two-now)), which may not be so, as if (two-now) is 3
(define-checked uses-two {--> fixnum} -> (same 2 (two-now)))
(define two-now {--> fixnum} -> 1)
\\ says type error in rule 1 of stale: stale promises (fx= 3 2), which may not be so
(define-checked stale {X : fixnum --> R : fixnum} {ensures (fx= R 2)} X -> 3)
\\ says type error in rule 1 of uses-stale: same needs (fx= 2 (stale X)), which may not be so, as if (stale X) is 3
(define uses-stale {fixnum --> fixnum} X -> (same 2 (stale X)))
(define stale {fixnum --> fixnum} X -> 3)
\\ says define-checked: unread has ensurse in braces, where requires can be and then ensures
(define-checked stale {X : fixnum --> R : fixnum} {ensures (fx= R 2)} X -> 2)
(define-checked unread {X : fixnum --> fixnum} {ensurse (fx= X 2)} X -> 2)
\\ says type error in rule 1 of uses-stale: same needs (fx= 2 (stale X)), which may not be so, as if (stale X) is 3
(define uses-stale {fixnum --> fixnum} X -> (same 2 (stale X)))
(define stale {fixnum --> fixnum} X -> 3)
\\ says type error in rule 1 of stale
(define-checked stale {X : fixnum --> fixnum} {requires (fx> X 0)} X -> "no")
\\ loads
(define uses-stale {fixnum --> fixnum} X -> (stale X))
(define stale {fixnum --> fixnum} X -> 3)
(if (= (uses-stale -1) 3) true (simple-error "not 3"))
\\ loads
(define-checked wrapped {X : fixnum --> R : fixnum} {ensures (fx= R 1)} X -> 1)
\\ says type error in rule 1 of wrapped
(define-checked wrapped {X : fixnum --> R : fixnum} {requires (fx> X "a")} {ensures (fx= R 2)} X -> 2)
\\ says type error: same needs (fx= 2 1), which may not be so
(same 2 (wrapped 1))
(define wrapped {fixnum --> fixnum} X -> 3)
\\ loads
(define-checked last-counts {X : fixnum --> R : fixnum} {ensures (fx= R 1)} X -> 1)
(define uses-last {fixnum --> fixnum} X -> (same 2 (last-counts X)))
(define-checked last-counts {X : fixnum --> R : fixnum} {ensures (fx= R 2)} X -> 2)
(if (= (uses-last 1) 2) true (simple-error "not 2"))
\\ loads
(let positive (/. Y (fx+ Y 1)) (positive -1))
\\ loads
(define-checked made-twice {X : fixnum --> fixnum} {requires (fx> X 0)} X -> (if (fx> X 1) (made-twice (fx- X 1)) 1))
(define-checked made-twice {X : fixnum --> fixnum} {requires (fx> X 5)} X -> X)
\\ What was proved of one condition does not call what has another.
\\ loads
(define-checked later {X : fixnum --> fixnum} {requires (fx> X 0)} X -> X)
(define calls-later {--> fixnum} -> (later 5))
\\ loads
(define-checked later {X : fixnum --> fixnum} {requires (fx> X 1000)} X -> (simple-error "called with less"))
(if (= (calls-later) 5) true (simple-error "not 5"))
\\ Nor what is refused for its condition, which is the same.
\\ loads
(define shown-as {fixnum --> fixnum} X -> X)
(define-checked kept {X : fixnum --> fixnum} {requires (fx> (shown-as X) 0)} X -> X)
(refine.pure shown-as)
(define-checked calls-kept {fixnum --> fixnum} X -> (if (fx> (shown-as X) 0) (kept X) 0))
\\ loads
(define-checked shown-as {X : fixnum --> fixnum} {requires (fx> X 100)} X -> X)
\\ says type error in the condition of kept: shown-as needs (fx> X 100), which may not be so, as if X is 0
(define-checked kept {X : fixnum --> fixnum} {requires (fx> (shown-as X) 0)} X -> (simple-error "refused"))
\\ loads
(if (= (calls-kept 101) 101) true (simple-error "not 101"))
\\ says positive: not so: (fx> X 0)
(datatype side
  if (positive -1)
  ________________
  foo : side;)
(define uses-side {--> side} -> foo)
\\ Terms that double each time they are used.
\\ loads
(define-checked lets {X : fixnum --> R : fixnum} {ensures (fx<= R 100)}
  X -> (let A (if (fx> X 0) X 0) B (if (fx> A 1) A 1) C (if (fx> B 2) B 2) D (if (fx> C 3) C 3)
            E (if (fx> D 4) D 4) F (if (fx> E 5) E 5) G (if (fx> F 6) F 6) H (if (fx> G 7) G 7)
            I (if (fx> H 8) H 8) J (if (fx> I 9) I 9) K (if (fx> J 10) J 10) L (if (fx> K 11) K 11) M (if (fx> L 12) L 12)
            (if (fx> M 100) 100 M)))
\\ loads
(define-checked clamp {X : fixnum --> R : fixnum} {ensures (fx= R (if (fx< X 0) 0 (if (fx> X 255) 255 X)))} X -> (if (fx< X 0) 0 (if (fx> X 255) 255 X)))
(define-checked octet {X : fixnum --> fixnum} {requires (fx<= 0 X) (fx<= X 255)} X -> X)
(define-checked clamps {fixnum --> fixnum} X -> (octet (clamp (fx+ 1 (clamp (fx+ 1 (clamp (fx+ 1 (clamp (fx+ 1 (clamp (fx+ 1 (clamp (fx+ 1 (clamp (fx+ 1 (clamp (fx+ 1 (clamp (fx+ 1 (clamp (fx+ 1 (clamp (fx+ 1 (clamp (fx+ 1 (clamp (fx+ 1 (clamp (fx+ 1 (clamp (fx+ 1 (clamp (fx+ 1 X))))))))))))))))))))))))))))))))))
\\ loads
(define-checked ifs {A : boolean --> B : boolean --> fixnum}
  {requires (if (if (if (if (if (if (if (if (if (if (if (if (if (if (if (if (if (if (if (if A B A) B A) B A) B A) B A) B A) B A) B A) B A) B A) B A) B A) B A) B A) B A) B A) B A) B A) B A) B A)}
  A B -> 1)
(define-checked uses-ifs {boolean --> fixnum} B -> (ifs B B) where B _ -> 0)
\\ loads
(define-checked sums {X : fixnum --> fixnum} {requires (fx> X 0)}
  X -> (let A (fx+ X X) B (fx+ A A) C (fx+ B B) D (fx+ C C) E (fx+ D D) F (fx+ E E) G (fx+ F F) H (fx+ G G) I (fx+ H H) J (fx+ I I)
            K (fx+ J J) L (fx+ K K) M (fx+ L L) N (fx+ M M) O (fx+ N N) P (fx+ O O) Q (fx+ P P) R (fx+ Q Q) S (fx+ R R) T (fx+ S S)
            U (fx+ T T) V (fx+ U U) W (fx+ V V) A1 (fx+ W W) B1 (fx+ A1 A1) C1 (fx+ B1 B1) D1 (fx+ C1 C1)
            (positive D1)))
\\ loads
(define-checked any-fixnum {X : fixnum --> fixnum} {requires (fx<= X X)} X -> X)
(define-checked sums-in {X : fixnum --> fixnum} X -> (any-fixnum (let A (fx+ X X) B (fx+ A A) C (fx+ B B) D (fx+ C C) E (fx+ D D) F (fx+ E E) G (fx+ F F) H (fx+ G G) I (fx+ H H) J (fx+ I I) K (fx+ J J) L (fx+ K K) M (fx+ L L) N (fx+ M M) O (fx+ N N) P (fx+ O O) Q (fx+ P P) R (fx+ Q Q) S (fx+ R R) T (fx+ S S) U (fx+ T T) V (fx+ U U) W (fx+ V V) W)))
\\ loads
(define-checked long? {A : fixnum --> R : boolean} {ensures (= R (and (fx< A 100) (fx< A 101) (fx< A 102) (fx< A 103) (fx< A 104) (fx< A 105) (fx< A 106) (fx< A 107) (fx< A 108) (fx< A 109) (fx< A 110) (fx< A 111) (fx< A 112) (fx< A 113) (fx< A 114) (fx< A 115) (fx< A 116) (fx< A 117) (fx< A 118) (fx< A 119) (fx< A 120) (fx< A 121) (fx< A 122) (fx< A 123) (fx< A 124) (fx< A 125) (fx< A 126) (fx< A 127) (fx< A 128) (fx< A 129) (fx< A 130) (fx< A 131) (fx< A 132) (fx< A 133) (fx< A 134) (fx< A 135) (fx< A 136) (fx< A 137) (fx< A 138) (fx< A 139) (fx< A 140)))} A -> (and (fx< A 140) (fx< A 139) (fx< A 138) (fx< A 137) (fx< A 136) (fx< A 135) (fx< A 134) (fx< A 133) (fx< A 132) (fx< A 131) (fx< A 130) (fx< A 129) (fx< A 128) (fx< A 127) (fx< A 126) (fx< A 125) (fx< A 124) (fx< A 123) (fx< A 122) (fx< A 121) (fx< A 120) (fx< A 119) (fx< A 118) (fx< A 117) (fx< A 116) (fx< A 115) (fx< A 114) (fx< A 113) (fx< A 112) (fx< A 111) (fx< A 110) (fx< A 109) (fx< A 108) (fx< A 107) (fx< A 106) (fx< A 105) (fx< A 104) (fx< A 103) (fx< A 102) (fx< A 101) (fx< A 100)))
(define-checked needs-long {A : fixnum --> fixnum} {requires (if (and (fx< A 100) (fx< A 101) (fx< A 102) (fx< A 103) (fx< A 104) (fx< A 105) (fx< A 106) (fx< A 107) (fx< A 108) (fx< A 109) (fx< A 110) (fx< A 111) (fx< A 112) (fx< A 113) (fx< A 114) (fx< A 115) (fx< A 116) (fx< A 117) (fx< A 118) (fx< A 119) (fx< A 120) (fx< A 121) (fx< A 122) (fx< A 123) (fx< A 124) (fx< A 125) (fx< A 126) (fx< A 127) (fx< A 128) (fx< A 129) (fx< A 130) (fx< A 131) (fx< A 132) (fx< A 133) (fx< A 134) (fx< A 135) (fx< A 136) (fx< A 137) (fx< A 138) (fx< A 139) (fx< A 140)) (fx> A 0) (fx< A 0))} A -> A)
(define-checked meets-long {fixnum --> fixnum} A -> (if (and (fx< A 140) (fx< A 139) (fx< A 138) (fx< A 137) (fx< A 136) (fx< A 135) (fx< A 134) (fx< A 133) (fx< A 132) (fx< A 131) (fx< A 130) (fx< A 129) (fx< A 128) (fx< A 127) (fx< A 126) (fx< A 125) (fx< A 124) (fx< A 123) (fx< A 122) (fx< A 121) (fx< A 120) (fx< A 119) (fx< A 118) (fx< A 117) (fx< A 116) (fx< A 115) (fx< A 114) (fx< A 113) (fx< A 112) (fx< A 111) (fx< A 110) (fx< A 109) (fx< A 108) (fx< A 107) (fx< A 106) (fx< A 105) (fx< A 104) (fx< A 103) (fx< A 102) (fx< A 101) (fx< A 100)) (needs-long A) 1) where (fx> A 0) _ -> 0)
\\ says type error in rule 1 of meets-long: needs-long needs (if (and (fx< A 100) (and (fx< A 101) (and (fx< A 102) (and (fx< A 103) (and (fx< A 104) (and (fx< A 105) (and (fx< A 106) (and (fx< A 107) (and (fx< A 108) (and (fx< A 109) (and (fx< A 110) (and (fx< A 111) (and (fx< A 112) (and (fx< A 113) (and (fx< A 114) (and (fx< A 115) (and (fx< A 116) (and (fx< A 117) (and (fx< A 118) (and (fx< A 119) (and (fx< A 120) (and (fx< A 121) (and (fx< A 122) (and (fx< A 123) (and (fx< A 124) (and (fx< A 125) (and (fx< A 126) (and (fx< A 127) (and (fx< A 128) (and (fx< A 129) (and (fx< A 130) (and (fx< A 131) (and (fx< A 132) (and (fx< A 133) (and (fx< A 134) (and (fx< A 135) (and (fx< A 136) (and (fx< A 137) (and (fx< A 138) (and (fx< A 139) (fx< A 140))))))))))))))))))))))))))))))))))))))))) (fx> A 0) (fx< A 0)), which may not be so, as if A is 140
(define-checked meets-long {fixnum --> fixnum} A -> (needs-long A) where (fx> A 139) _ -> 0)
\\ says type error in rule 1 of done-long: positive needs (fx> -1 0), which may not be so
(define-checked done-long {fixnum --> fixnum} A -> (do (if (fx< A 100) up (if (fx< A 101) up (if (fx< A 102) up (if (fx< A 103) up (if (fx< A 104) up (if (fx< A 105) up (if (fx< A 106) up (if (fx< A 107) up (if (fx< A 108) up (if (fx< A 109) up (if (fx< A 110) up (if (fx< A 111) up (if (fx< A 112) up (if (fx< A 113) up (if (fx< A 114) up (if (fx< A 115) up (if (fx< A 116) up (if (fx< A 117) up (if (fx< A 118) up (if (fx< A 119) up (if (fx< A 120) up (if (fx< A 121) up (if (fx< A 122) up (if (fx< A 123) up (if (fx< A 124) up (if (fx< A 125) up (if (fx< A 126) up (if (fx< A 127) up (if (fx< A 128) up (if (fx< A 129) up (if (fx< A 130) up (if (fx< A 131) up (if (fx< A 132) up (if (fx< A 133) up (if (fx< A 134) up (if (fx< A 135) up (if (fx< A 136) up (if (fx< A 137) up (if (fx< A 138) up (if (fx< A 139) up (if (fx< A 140) up down))))))))))))))))))))))))))))))))))))))))) (positive -1)))
\\ says type error in rule 1 of large: positive needs (fx> X 0), which is not proved: integer overflow
(define-checked large {X : fixnum --> Y : fixnum --> fixnum} {requires (fx<= X (fx* 8 Y)) (fx>= Y 1152921504606846975)} X Y -> (positive X))
\\ Many cases, of which few matter.
\\ loads
(define-checked cost
  {Op : fixnum --> Mode : fixnum --> R : fixnum}
  {ensures (fx<= 1 R) (fx<= R 8)}
  0 0 -> 1 0 1 -> 2 0 2 -> 3 0 3 -> 4 1 0 -> 2 1 1 -> 3 1 2 -> 4 1 3 -> 5 2 0 -> 3 2 1 -> 4 2 2 -> 5 2 3 -> 6 3 0 -> 4 3 1 -> 5 3 2 -> 6 3 3 -> 7 _ _ -> 1)
\\ What a pattern binds is of the type it has there.
\\ loads
(defstruct purse (owner : symbol) (money : from-0))
(refine.type (some A) Xs : (list A) where (not (empty? Xs)))
(define-checked over-none {X : fixnum --> fixnum} {requires (fx<= 0 X)} X -> X)
(define some-purse {fixnum --> purse} X -> (purse.make a 1))
(define-checked needs-money {P : purse --> fixnum} {requires (fx<= 0 (purse.money P))} P -> 1)
(define-checked of-some-purse {fixnum --> fixnum} X -> (needs-money (some-purse X)))
(define-checked in-purse {purse --> fixnum} (:purse owner <- _ money <- X) -> (over-none X))
(define-checked of-purse {P : purse --> R : fixnum} {ensures (fx<= 0 R)} (:purse owner <- _ money <- X) -> X)
\\ says type error in rule 1 of in-some: over-none needs (fx<= 0 X), which may not be so, as if X is -1
(define-checked in-some {(some fixnum) --> fixnum} [X | _] -> (over-none X))
\\ says type error in rule 1 of in-some: from-0-only needs (fx<= 0 P), which may not be so, as if P is -2
(define from-0-only {from-0 --> from-0} N -> N)
(define-checked in-some {(some fixnum) --> fixnum} [P | _] -> (if (fx<= 0 P) (from-0-only P) (if (fx= P -1) 0 (from-0-only P))))
\\ says type error in rule 1 of in-some
(define in-some {(some fixnum) --> string} [P | Ps] -> (cn "a" (cn (str P) (cn "b" (cn (str (length Ps)) (cn "c" P))))))
\\ says refine.trust: two-contracts has a contract of its own
(define-checked two-contracts {X : fixnum --> fixnum} {requires (fx> X 0)} X -> X)
(refine.trust (two-contracts X) --> R where (fx> R 0))
\\ What an error says.
\\ loads
(define-checked needs-it {B : boolean --> fixnum} {requires B} _ -> 1)
(define-checked by-not {boolean --> fixnum} X -> (if X (needs-it X) (needs-it (not X))))
\\ says type error in rule 2 of no-number: at-least-0 needs (>= X 0), which may not be so, as if X is no number
(define-checked at-least-0 {X : number --> number} {requires (>= X 0)} X -> X)
(define-checked no-number {number --> number} X -> 0 where (< X 0) X -> (at-least-0 X))
\\ loads
(define-checked same-lists {Xs : (list fixnum) --> Ys : (list fixnum) --> fixnum} {requires (= Xs Ys)} _ _ -> 1)
(define-checked lists {fixnum --> fixnum} X -> (same-lists [1 X] [1 X]))
(define-checked lists-2 {(list fixnum) --> (list fixnum) --> fixnum} Xs Ys -> (if (= Xs Ys) (same-lists Xs Ys) (same-lists Xs Xs)))
\\ says type error in rule 1 of lists: same-lists needs (= (cons 1 (cons X ())) (cons 1 (cons 2 ()))), which may not be so, as if X is 0
(define-checked lists {fixnum --> fixnum} X -> (same-lists [1 X] [1 2]))
\\ loads
(define-checked numbers {(list fixnum) --> fixnum} X -> (positive (fx+ 1 (fixnum (length X)))))
(define-checked a-whole {number --> fixnum} X -> (let I (fixnum X) (if (= I 3) (same I 3) 0)))
(define-checked constants {--> fixnum} -> (same (shen-jit.shift-left 1 40) 1099511627776))
(define-checked constants-2 {--> fixnum} -> (same (shen-jit.bit-or 1 2) 3))
(define-checked nonzero {X : fixnum --> fixnum} {requires (not (fx= X 0))} X -> X)
(define-checked remainders {fixnum --> fixnum --> fixnum} X Y -> (if (and (fx= (fxremainder X Y) 3) (fx> X 0)) (nonzero Y) 0))
(define-checked remainders-2 {fixnum --> fixnum} X -> (positive (fx- 5 (fxremainder X -5))))
\\ says type error in rule 1 of remainders: positive needs (fx> Y 0), which may not be so, as if Y is -4
(define-checked remainders {fixnum --> fixnum --> fixnum} X Y -> (if (fx= (fxremainder X Y) 3) (positive Y) 0))
\\ A variable of a pattern is read again wherever it is written, if it is in what may change. A let reads it once.
\\ loads
(defstruct gauge (name : symbol) (mutable level : fixnum) (mutable items : (list fixnum)))
(define-checked an-item {Xs : (list fixnum) --> fixnum} {requires (not (empty? Xs))} Xs -> (head Xs))
\\ says type error in rule 1 of later: positive needs (fx> N 0), which may not be so, as if N is 0. What it is in may change, so N may be another each time
(define later {gauge --> (lazy fixnum)} (:gauge level <- N ...) -> (freeze (positive N)) where (fx> N 0) _ -> (freeze 1))
\\ says type error in rule 1 of later: positive needs (fx> N 0), which may not be so, as if N is 0. What it is in may change, so N may be another each time
(define-checked later {gauge --> (lazy fixnum)} (:gauge level <- N ...) -> (if (fx> N 0) (freeze (positive N)) (freeze 1)))
\\ says type error in rule 1 of level-of: level-of promises (fx> N 0), which may not be so, as if N is 0. What it is in may change, so N may be another each time
(define-checked level-of {gauge --> R : fixnum} {ensures (fx> R 0)} (:gauge level <- N ...) -> (if (fx> N 0) N 1))
\\ says type error in rule 1 of later: an-item needs (not (empty? (cons X Xs))), which may not be so, as if (empty? (cons X Xs)) is true. What it is in may change, so (cons X Xs) may be another each time
(define-checked later {gauge --> (lazy fixnum)} (:gauge items <- [X | Xs] ...) -> (freeze (an-item [X | Xs])) _ -> (freeze 1))
\\ says type error in rule 1 of level-of: level-of promises (fx= (gauge.level (gauge.%make S 5 I)) 5), which may not be so, as if (gauge.level (gauge.%make S 5 I)) is 0
(define-checked level-of {gauge --> R : fixnum} {ensures (fx= R 5)} (:gauge level <- 5 name <- S items <- I) -> (gauge.level (:gauge level <- 5 name <- S items <- I)) _ -> 5)
\\ says type error in rule 1 of later: positive needs (fx> X 0), which may not be so, as if X is 0. What it is in may change, so X may be another each time
(define later {gauge --> (lazy fixnum)} (:gauge items <- [X | Xs] ...) -> (freeze (positive X)) where (fx> X 0) _ -> (freeze 1))
\\ says type error in rule 1 of later: positive needs (fx> X 0), which may not be so, as if X is 0. What it is in may change, so X may be another each time
(define later {(vector fixnum) --> (lazy fixnum)} (@v X _) -> (freeze (positive X)) where (fx> X 0) _ -> (freeze 1))
\\ says type error in rule 1 of later: an-item needs (not (empty? (cons X Xs))), which may not be so, as if (empty? (cons X Xs)) is true. What it is in may change, so (cons X Xs) may be another each time
(define-checked later {(vector (list fixnum)) --> (lazy fixnum)} (@v [X | Xs] _) -> (freeze (an-item [X | Xs])) _ -> (freeze 1))
\\ loads
(define-checked once-read {gauge --> fixnum} (:gauge level <- N ...) -> (let M N (if (fx> M 0) (positive M) 1)))
(define-checked once-read-2 {(vector fixnum) --> fixnum} (@v X Xs) -> (let Y X (if (fx> Y 0) (positive Y) 1)) _ -> 1)
(define-checked name-of {gauge --> symbol} (:gauge name <- S ...) -> (if (= S up) (up-only S) up))
(refine.type above-0 N where (fx> N 0))
(defstruct good-gauge (mutable level : above-0))
(define-checked good-level {good-gauge --> fixnum} (:good-gauge level <- N) -> (positive N))
(define good-again {good-gauge --> good-gauge} (:good-gauge level <- 5) -> (:good-gauge level <- 5) (:good-gauge level <- N) -> (:good-gauge level <- N))
(define same-gauge {gauge --> gauge} (:gauge level <- N name <- S items <- [X | Xs]) -> (:gauge level <- N name <- S items <- [X | Xs]) G -> G)
\\ A rule of one's own may type a term and not look inside: what is called there is asked for all the same.
\\ says type error in rule 1 of boxed: positive needs (fx> X 0), which may not be so, as if X is 0
(datatype boxed
  _________________
  [boxed X] : boxed;)
(define boxed {fixnum --> boxed} X -> [boxed (positive X)])
\\ loads
(define-checked boxed-over {fixnum --> boxed} X -> (if (fx> X 0) [boxed (positive X)] [boxed 1]))
\\ says type error in rule 1 of by-rule: positive needs (fx> X 0), which may not be so, as if X is 0
(datatype kept-by
  F : (symbol --> fixnum); N : symbol;
  ____________________________________
  (kept-by F N) : boxed;

  N : fixnum;
  ____________________________________
  (kept-by F N) : boxed;)
(define kept-by {(fixnum --> fixnum) --> fixnum --> fixnum} F N -> (F N))
(define by-rule {fixnum --> boxed} N -> (kept-by (/. X (positive X)) N))
\\ loads
(define unbox {boxed --> fixnum} B -> 1)
(define-checked kept-and-said {N : fixnum --> R : fixnum} {ensures (fx> R 0)} N -> (if (fx> N 0) N (do (unbox (kept-by (/. X (if (fx> X 0) (positive X) 0)) N)) 1)))
\\ A condition binds nothing.
\\ says refine: binds has a condition with let, and conditions bind nothing
(define-checked binds {I : fixnum --> fixnum} {requires (let I (fixnum 0) (fx= I 0)) (fx= I 0)} I -> I)
\\ says refine: bound-zero has a condition with let, and conditions bind nothing
(refine.type bound-zero N where (let N (fixnum 0) (fx= N 0)))
\\ says refine: binds has a condition with let, and conditions bind nothing
(define-checked binds {S : symbol --> symbol} {requires (let up down (= up down)) (= S up)} S -> S)
\\ says refine: binds has a condition with lambda, and conditions bind nothing
(refine.trust (binds S) --> R where ((/. R (= R up)) down))
\\ says refine: binds trusts something of T, which is not a name it can be of
(refine.trust (binds S) --> R where (= R T))
\\ loads
(define-checked binds {S : symbol --> symbol} {requires (element? S [let lambda])} S -> S)
\\ The name of a refined type is no other type's.
\\ says refine.type: unit is a type already
(refine.type unit X : number where (>= X 0))
\\ loads
(defstruct round (radius : fixnum))
(defstruct square (side : fixnum))
(struct.union shape round square)
\\ says refine.type: shape is a type already
(refine.type shape N where (fx<= 0 N))
\\ loads
(synonyms index fixnum)
\\ says refine.type: index is a type already
(refine.type index N where (fx<= 0 N))
\\ loads
(datatype colour
  if (element? X [red green])
  ___________________________
  X : colour;)
\\ says refine.type: colour is a type already
(refine.type colour S : symbol where (= S blue))
\\ says refine: again-typed says something of M, which is not a name it can be of
(refine.type again-typed N where (fx<= 0 N M))
\\ says refine.type: again-typed needs a condition on fixnum, not (not-known N)
(refine.type again-typed N where (not-known N))
(define again-typed-2 {again-typed --> fixnum} N -> N)
\\ loads
(refine.type again-typed N where (fx<= 0 N))
(define again-typed-2 {again-typed --> fixnum} N -> N)
\\ A struct of two parameters, and one of anonymous fields, whose readers have other names.
\\ loads
(defstruct (both (A * B)) (a : A) (b : B))
(define-checked both-of {(both (fixnum * symbol)) --> fixnum} (:both a <- X b <- S) -> (do (up-only S) (positive X)) where (and (fx> X 0) (= S up)) _ -> 1)
(defstruct (quantity (A * Unit)) (amount : A))
(define-checked a-pair {X : A --> symbol} {requires (tuple? X)} X -> ok)
\\ says type error in rule 1 of amount-of: a-pair needs (tuple? X), which may not be so, as if (tuple? X) is false
(define amount-of {(quantity (fixnum * metres)) --> symbol} (:quantity amount <- X) -> (a-pair X))
\\ loads
(defstruct two (_ : fixnum) (_ : fixnum))
(define two.1 {two --> fixnum} (:two _ Y) -> Y)
(refine.pure two.1)
(define-checked second-not-5 {P : two --> fixnum} {requires (not (fx= 5 (two.1 P)))} P -> 0)
\\ says type error in rule 2 of first-5: second-not-5 needs (not (fx= 5 (two.1 P))), which may not be so, as if (two.1 P) is 5
(define-checked first-5 {two --> fixnum} (:two 5 _) -> 0 P -> (second-not-5 P))
\\ loads
(define-checked not-five {X : fixnum --> fixnum} {requires (not (fx= X 5))} X -> X)
(define-checked by-first {two --> fixnum} (:two 5 _) -> 0 (:two X _) -> (not-five X))
(define-checked early-start {--> fixnum} -> (positive (early.start (early.make 9 7))))
(defstruct early (start : fixnum) (end : fixnum))
\\ loads
(defstruct two-ends (left : fixnum) (right : fixnum))
(define swapped {fixnum --> fixnum --> two-ends} A B -> (two-ends.make B A))
(refine.pure swapped)
\\ says type error in rule 1 of of-swapped: positive needs (fx> (two-ends.left (swapped 9 -7)) 0), which may not be so, as if (two-ends.left (swapped 9 -7)) is 0
(define-checked of-swapped {--> fixnum} -> (positive (two-ends.left (swapped 9 -7))))
\\ What a let binds is bound in an expression, in a protect, and in what is read.
\\ says type error: up-only needs (= down up), which may not be so
(let up down (up-only up))
\\ says type error in rule 1 of protected
(define protected {number --> symbol} N -> (let X N (protect X)))
\\ loads
(define read-from {(stream in) --> fixnum} S -> (let T S (input+ fixnum T)))
\\ A function with more arguments than it takes gives what another does.
\\ loads
(define reader {(vector fixnum) --> (fixnum --> fixnum)} V -> (/. I (<-vector V (fx->number I))))
(refine.pure reader)
(define-checked reads-1 {V : (vector fixnum) --> fixnum} {requires (fx= 1 (reader V 1))} V -> 0)
\\ says type error in rule 1 of reads-again: reads-1 needs (fx= 1 (reader V 1)), which may not be so, as if ((fn reader) V 1) is 2
(define-checked reads-again {V : (vector fixnum) --> fixnum} {requires (fx= 1 (reader V 1))} V -> (do (vector-> V 1 (fixnum 2)) (reads-1 V)))
\\ Of a variable of a pattern that a rule of one's own takes apart nothing is known but what is tested.
\\ says type error in rule 1 of pushed: positive needs (fx> N 0), which may not be so, as if N is 0
(datatype command
  N : fixnum;
  ================
  [push N] : command;

  N : fixnum; C : command;
  =========================
  [twice N C] : command;)
(define-checked pushed {command --> fixnum} [push N] -> (positive N) _ -> 1)
\\ loads
(define-checked pushed {command --> fixnum} [push N] -> (let M N (if (fx> M 0) (positive M) 1)) [twice N [push M]] -> (let K (fx+ N M) (if (fx> K 0) (positive K) 1)) _ -> 1)
\\ says type error in rule 1 of pushed: positive needs (fx> (fx- N 1) 0), which may not be so, as if N is 0
(define-checked pushed {command --> fixnum} [push N] -> (positive (fx- N 1)) _ -> 1)
\\ says type error in rule 1 of pushed: positive needs (fx> (fx- A B) 0), which may not be so, as if A is 0 and B is 0
(define-checked pushed {command --> command --> command --> fixnum} [twice A [push B]] [twice C [push D]] [twice E F] -> (positive (fx- A B)) _ _ _ -> 1)
\\ A datatype's rule may be of a number. A variable that is there twice is two.
\\ loads
(datatype stage
  _____________
  [stage 0] : stage;

  _____________
  [stage 1] : stage;)
(define stage-name {stage --> string} [stage 0] -> "first" [stage 1] -> "second")
(define-checked stage-number {S : stage --> R : fixnum} {ensures (fx<= 0 R)} [stage 0] -> 0 [stage 1] -> 1)
(define-checked stage-again {stage --> stage} [stage 0] -> [stage 0] X -> X)
\\ loads
(datatype non-fixnums
  X : number;
  ===============
  [non X] : non-fixnums;

  X : number; Y : number;
  =============================
  [either X Y] : either;)
(refine.type non-fixnum X : number where (not (shen-jit.fixnum? X)))
(refine.type whole-number X : number where (shen-jit.fixnum? X))
(define a-non {non-fixnum --> symbol} X -> ok)
(define a-whole-number {whole-number --> symbol} X -> ok)
\\ says type error in rule 1 of of-non: a-non needs (not (shen-jit.fixnum? 1)), which may not be so
(define of-non {non-fixnums --> symbol} [non 1] -> (a-non 1) _ -> no)
\\ says type error in rule 1 of of-either: a-whole-number needs (shen-jit.fixnum? X), which may not be so, as if (shen-jit.fixnum? X) is false
(define of-either {either --> symbol} [either X X] -> (a-whole-number X) _ -> no)
\\ loads
(define of-either-2 {either --> symbol} [either X X] -> yes _ -> no)
(define of-either-3 {either --> number} [either X X] -> X _ -> 0)
\\ says type error in rule 1 of list-twice: a-fixnum needs (shen-jit.fixnum? X), which may not be so, as if (shen-jit.fixnum? X) is false
(define-checked list-twice {Xs : (list number) --> number} {requires (shen-jit.fixnum? (head (tail Xs)))} [_ X X] -> (a-fixnum X) _ -> 0)
\\ loads
(datatype item
  X : symbol;
  ___________
  X : item;

  X : number;
  ___________
  X : item;)
(define-checked fixnum-item {X : item --> item} {requires (shen-jit.fixnum? X)} X -> X)
\\ says type error in rule 1 of item-twice: fixnum-item needs (shen-jit.fixnum? X), which may not be so, as if (shen-jit.fixnum? X) is false
(define-checked item-twice {Xs : (list item) --> item} {requires (shen-jit.fixnum? (head (tail Xs)))} [none X X] -> (fixnum-item X) _ -> none)
\\ says type error in rule 1 of item-twice: item-twice promises (= (shen-jit.fixnum? X) (shen-jit.fixnum? X)), which may not be so, as if (shen-jit.fixnum? X) is true and (shen-jit.fixnum? X) is false
(define-checked item-twice {Xs : (list item) --> R : boolean} {ensures (= R (shen-jit.fixnum? (head (tail Xs))))} [none X X] -> (shen-jit.fixnum? X) Xs -> (shen-jit.fixnum? (head (tail Xs))))
\\ says type error in rule 2 of item-twice: fixnum-item needs (shen-jit.fixnum? X), which may not be so, as if (shen-jit.fixnum? X) is false
(define-checked item-twice {Xs : (list item) --> item} [none X Y] -> none where (not (shen-jit.fixnum? X)) [none X X] -> (fixnum-item X) _ -> none)
\\ says type error in rule 1 of of-symbol
(define of-symbol {symbol --> fixnum} 0 -> 1 _ -> 2)
\\ A guard is as it was written for a rule of one's own.
\\ loads
(datatype positives
  X : fixnum;
  ____________________________
  (positive? X) : verified >> X : pos;)
(define positive? {fixnum --> boolean} X -> (fx> X 0))
(define-checked up-to-pos {fixnum --> pos} -5 -> (up-to-pos 0) X -> X where (positive? X) X -> (up-to-pos (fx+ X 1)))
(define-checked up-to-pos-2 {X : fixnum --> pos} {requires (fx> X -9)} X -> X where (positive? X) X -> (up-to-pos 1))
(datatype overs
  X : fixnum;
  ______________________________
  (over? X Y) : verified >> X : pos;)
(define over? {fixnum --> fixnum --> boolean} X Y -> (fx> X Y))
(define-checked up-to-pos-4 {fixnum --> pos} -5 -> (up-to-pos-4 0) X -> X where (over? X 0) X -> (up-to-pos-4 (fx+ X 1)))
(define up-to-pos-3 {number --> fixnum --> pos} 0 X -> X where (positive? X) _ X -> (up-to-pos X))
\\ says type error in rule 2 of up-to-pos
(define-checked up-to-pos {fixnum --> pos} -5 -> (up-to-pos 0) X -> X where (positive? (fx+ X 1)) X -> (up-to-pos (fx+ X 1)))
\\ A pure function of a pure function, or of one with some of its arguments, is the same.
\\ loads
(define all? {(A --> boolean) --> (list A) --> boolean} _ [] -> true F [X | Xs] -> (and (F X) (all? F Xs)))
(define over-3 {fixnum --> boolean} X -> (fx< 3 X))
(define under-3 {fixnum --> boolean} X -> (fx> 3 X))
(refine.pure all? over-3 under-3)
(define-checked all-over {Xs : (list fixnum) --> fixnum} {requires (all? (fn over-3) Xs)} Xs -> 1)
(define-checked all-fewer {Xs : (list fixnum) --> fixnum} {requires (all? (fx< 3) Xs)} Xs -> 1)
(define-checked overs {(list fixnum) --> fixnum} Xs -> (if (all? (fn over-3) Xs) (all-over Xs) 0))
(define-checked overs-2 {(list fixnum) --> fixnum} Xs -> (if (all? (/. X (over-3 X)) Xs) (all-over Xs) 0))
(define-checked overs-3 {(list fixnum) --> fixnum} Xs -> (if (all? (fx< 3) Xs) (all-fewer Xs) 0))
(define between? {fixnum --> fixnum --> fixnum --> boolean} L H X -> (and (fx<= L X) (fx<= X H)))
(refine.pure between?)
(define-checked all-between {Xs : (list fixnum) --> fixnum} {requires (all? (between? 1 5) Xs)} Xs -> 1)
(define-checked overs-4 {(list fixnum) --> fixnum} Xs -> (if (all? (between? 1 5) Xs) (all-between Xs) 0))
(define-checked overs-5 {(list fixnum) --> fixnum} Xs -> (if (all? (/. X (between? 1 5 X)) Xs) (all-between Xs) 0))
\\ says type error in rule 1 of overs: all-over needs (all? (fn over-3) Xs), which may not be so, as if (all? (fn over-3) Xs) is false
(define-checked overs {(list fixnum) --> fixnum} Xs -> (if (all? (fn under-3) Xs) (all-over Xs) 0))
\\ says type error in rule 1 of overs: all-fewer needs (all? (fx< 3) Xs), which may not be so, as if (all? (fx< 3) Xs) is false
(define-checked overs {(list fixnum) --> fixnum} Xs -> (if (all? (/. X (fx< 3 5)) Xs) (all-fewer Xs) 0))
\\ says type error in rule 1 of overs: all-between needs (all? (between? 1 5) Xs), which may not be so, as if (all? (between? 1 5) Xs) is false
(define-checked overs {(list fixnum) --> fixnum} Xs -> (if (all? (between? 5 1) Xs) (all-between Xs) 0))
\\ says type error in rule 1 of overs: all-fewer needs (all? (fx< 3) Xs), which may not be so, as if (all? (fx< 3) Xs) is false
(define-checked overs {fixnum --> (list fixnum) --> fixnum} Y Xs -> (if (all? (fx< Y) Xs) (all-fewer Xs) 0))
\\ says type error in rule 1 of over-any
(define over-any {fixnum --> boolean} X -> (fx< (value *any*) X))
(define-checked all-any {Xs : (list fixnum) --> fixnum} {requires (all? (fn over-any) Xs)} Xs -> 1)
\\ says type error in rule 1 of anys: all-any needs (all? (fn over-any) Xs), which may not be so, as if (all? (fn over-any) Xs) is false. over-any is not declared pure, so (all? (fn over-any) Xs) may be another each time
(define over-any {fixnum --> boolean} X -> (fx< 3 X))
(define-checked all-any {Xs : (list fixnum) --> fixnum} {requires (all? (fn over-any) Xs)} Xs -> 1)
(define-checked anys {(list fixnum) --> fixnum} Xs -> (if (all? (fn over-any) Xs) (all-any Xs) 0))
\\ What has an answer, and an error.
\\ loads
(define size-of {(list fixnum) --> fixnum} Xs -> (fixnum (length Xs)))
(refine.pure size-of)
(refine.trust (size-of Xs) --> R where (if (empty? Xs) (fx= R 0) (fx= R (fx+ 1 (size-of (tail Xs))))))
\\ says type error in rule 2 of sizes: positive needs (fx> (size-of Xs) 0), which may not be so, as if (size-of Xs) is 0
(define-checked sizes {(list fixnum) --> fixnum} [] -> 0 Xs -> (positive (size-of Xs)))
\\ says define-checked: no-clauses has no clauses
(define-checked no-clauses {X : fixnum --> fixnum})
\\ What a function with some of its arguments is given is not evaluated until it has the others.
\\ says type error in rule 1 of given-some: positive needs (fx> X 0), which may not be so, as if X is 0
(define-checked given-some {fixnum --> fixnum} X -> (let P (@p 1 (fx+ (fxquotient 1 0))) (positive X)))
\\ says type error in rule 1 of given-some: positive needs (fx> X 0), which may not be so, as if X is 0
(define-checked given-some {fixnum --> fixnum} X -> (let P [(/. Y (fx+ (fxquotient 1 0) Y))] (positive X)))
\\ says type error in rule 1 of given-some: positive needs (fx> X 0), which may not be so, as if X is 0
(define-checked over-zero {X : fixnum --> R : fixnum} {ensures (fx> X 0)} X -> X where (fx> X 0) _ -> (simple-error "not over zero"))
(define-checked given-some {fixnum --> fixnum} X -> (do [(fx+ (fx+ 1 (over-zero X)))] (positive X)))
\\ says type error in rule 1 of given-some: positive needs (fx> X 0), which may not be so, as if X is 0
(define-checked over-zero {X : fixnum --> R : fixnum} {ensures (fx> X 0)} X -> X where (fx> X 0) _ -> (simple-error "not over zero"))
(define-checked given-some {fixnum --> fixnum} X -> (positive X) where (cons? [(span.make (over-zero X))]) _ -> 0)
\\ says type error in rule 1 of given-some: positive needs (fx> X 0), which may not be so, as if X is 0
(define-checked over-zero {X : fixnum --> R : fixnum} {ensures (fx> X 0)} X -> X where (fx> X 0) _ -> (simple-error "not over zero"))
(define-checked takes {F : (fixnum --> fixnum) --> X : fixnum --> R : fixnum} {ensures (fx= R X)} _ X -> X)
(define-checked given-some {fixnum --> fixnum} X -> (let Y (takes (fx+ (over-zero X)) X) (positive X)))
\\ loads
(define-checked over-zero {X : fixnum --> R : fixnum} {ensures (fx> X 0)} X -> X where (fx> X 0) _ -> (simple-error "not over zero"))
(define-checked given-all {fixnum --> fixnum} X -> (let P (@p 1 (fx+ 1 (over-zero X))) (positive X)))
\\ What is written as a pattern was is what that matched only where its names are the pattern's.
\\ loads
(define-checked as-5 {X : fixnum --> fixnum} {requires (fx= X 5)} X -> X)
(define shadowed {(list fixnum) --> fixnum --> fixnum} [X | Xs] Y -> (let X Y (if (fx= X 5) (as-5 (head [X | Xs])) 0)) _ _ -> 0)
(define shadowed-2 {(list fixnum) --> fixnum} [X | Xs] -> ((/. X (if (fx= X 5) (as-5 (head [X | Xs])) 0)) (fixnum 5)) _ -> 0)
\\ says type error in rule 1 of shadowed-3: as-5 needs (fx= Y 5), which may not be so, as if Y is 0
(define shadowed-3 {(list fixnum) --> fixnum --> fixnum} [X | Xs] Y -> (if (fx= X 5) (let X Y (as-5 (head [X | Xs]))) 0) _ _ -> 0)
\\ A fixnum that is written may be of any number's type.
\\ loads
(define later-of {A --> A --> A} X Y -> Y)
(refine.pure later-of)
(define literal-types {fixnum --> fixnum} X -> (as-5 (later-of 5 X)) where (fx= 5 (later-of 5 X)) _ -> (as-5 (if (fx= 5 (later-of 4 5)) (later-of 4 5) 5)))
\\ says type error in rule 1 of literal-type: a-fixnum needs (shen-jit.fixnum? (later-of 1 2.5)), which may not be so, as if (shen-jit.fixnum? (later-of 1 2.5)) is false
(define literal-type {--> number} -> (a-fixnum (later-of 1 2.5)))
\\ says type error in rule 1 of literal-type: a-fixnum needs (shen-jit.fixnum? (if B 1 X)), which may not be so, as if (shen-jit.fixnum? (if B 1 X)) is false
(define literal-type {boolean --> number --> number} B X -> (a-fixnum (if B 1 X)))
\\ says type error in rule 1 of literal-type: a-fixnum needs (shen-jit.fixnum? (head (append (cons 1 ()) Xs))), which may not be so, as if (shen-jit.fixnum? (head (append (cons 1 ()) Xs))) is false
(define literal-type {(list number) --> number} Xs -> (a-fixnum (head (append [1] Xs))))
\\ A signature's condition is tested, and one of a struct's fields is for direct calls.
\\ loads
(refine.type five N where (fx= N 5))
(defstruct fives (first : five) (mutable second : five))
(define of-five {five --> fixnum} N -> (as-5 N))
(define gives-5 {(fixnum --> fixnum) --> fixnum} F -> (F 5))
(define gives-of-five {--> fixnum} -> (gives-5 (fn of-five)))
(define made-fives {fixnum --> fives} N -> (fives.make N 5) where (fx= N 5) _ -> (fives.make 5 5))
(define both-fives {fives --> fixnum} F -> (do (as-5 (fives.first F)) (as-5 (fives.second F))))
\\ says type error in rule 1 of set-five: fives.second-> needs (fx= N 5), which may not be so, as if N is 0
(define set-five {fives --> fixnum --> fives} F N -> (fives.second-> F N))
\\ says refine: fives.make does not test what its fields' types say, and is only for direct calls
(define passed-on {--> (fixnum --> (fixnum --> fives))} -> (fn fives.make))
\\ says refine: fives.make does not test what its fields' types say, and is only for direct calls
(define passed-on {--> (fixnum --> fives)} -> (fives.make 5))
\\ says refine: fives.second-> does not test what its fields' types say, and is only for direct calls
(define passed-on {fives --> (fixnum --> fives)} F -> (fives.second-> F))
\\ says type error in rule 1 of passed-on: fives.make needs (fx= X 5), which may not be so, as if X is 0
(define passed-on {--> (fixnum --> fives)} -> (/. X (fives.make X 5)))
\\ says not so
(define said-by {(lazy A) --> string} F -> (trap-error (do (thaw F) "so") (/. E "not so")))
(if (= "so" (said-by (freeze ((fn of-five) 4)))) true (simple-error (said-by (freeze ((fn of-five) 4)))))
\\ What an argument is of whose type cannot be told, a result may be.
\\ loads
(datatype fixnum-is-number X : fixnum; _____ X : number;)
(define through {A --> (A --> A) --> A} X F -> (F X))
(define half {number --> number} X -> (/ X 2))
\\ says type error in rule 1 of through-half: a-fixnum needs (shen-jit.fixnum? (through X (fn half))), which may not be so, as if (shen-jit.fixnum? (through X (fn half))) is false
(define through-half {fixnum --> number} X -> (a-fixnum (through X (fn half))))
\\ says type error in rule 1 of through-half: a-fixnum needs (shen-jit.fixnum? (through X (lambda))), which may not be so, as if (shen-jit.fixnum? (through X (lambda))) is false
(define through-half {fixnum --> number} X -> (a-fixnum (through X (/. Y (half Y)))))
\\ loads
(define fixnum-of {fixnum --> fixnum} X -> X)
(define through-after {fixnum --> number} X -> (a-fixnum (fx->number (through X (fn fixnum-of)))))
\\ Nothing is in a type that nothing is of, but another member of a union may be.
\\ loads
(refine.type nothing N where (and (fx< N 0) (fx> N 0)))
(defstruct nothings (it : nothing))
(defstruct some-nothings (those : nothings))
(defstruct no-nothings)
(struct.union maybe-nothings some-nothings no-nothings)
(define of-nothing {maybe-nothings --> fixnum} (:some-nothings those <- T) -> (as-5 3) where (fx= 0 (nothings.it T)) _ -> 0)
\\ says type error in rule 2 of of-nothing-2: as-5 needs (fx= 3 5), which may not be so
(define of-nothing-2 {maybe-nothings --> fixnum} (:some-nothings those <- T) -> 0 where (fx= 0 (nothings.it T)) _ -> (as-5 3))
\\ What is not run, or may not have been.
\\ loads
(define-checked five-or-none {X : fixnum --> R : fixnum} {ensures (fx= X 5)} X -> X where (fx= X 5) _ -> (simple-error ""))
(define did-run {fixnum --> fixnum} X -> (do (five-or-none X) (as-5 X)))
\\ says type error in rule 1 of not-run: as-5 needs (fx= X 5), which may not be so, as if X is 0
(define not-run {fixnum --> fixnum} X -> (do (freeze (five-or-none X)) (as-5 X)))
\\ says type error in rule 1 of not-run: as-5 needs (fx= X 5), which may not be so, as if X is 0
(define not-run {fixnum --> fixnum} X -> (do (/. Z (five-or-none X)) (as-5 X)))
\\ says type error in rule 1 of not-run: as-5 needs (fx= X 5), which may not be so, as if X is 0
(define not-run {fixnum --> fixnum} X -> (do (trap-error (five-or-none X) (/. E 0)) (as-5 X)))
\\ says type error in rule 1 of not-run: as-5 needs (fx= X 5), which may not be so, as if X is 0
(define not-run {fixnum --> fixnum} X -> (do (trap-error (fixnum 1) (/. E (five-or-none X))) (as-5 X)))
\\ A variable that is protected is that variable, as a definition is compiled without protect.
\\ loads
(define-checked up-only {S : symbol --> symbol} {requires (= S up)} S -> S)
(define is-up {symbol --> symbol} Up -> (if (= Up up) (up-only Up) up))
(define is-up {symbol --> symbol} Up -> (if (= Up up) (up-only (protect Up)) up))
\\ What fn is of may be defined later.
\\ says refine: later-fives.make does not test what its fields' types say, and is only for direct calls
(define later-maker {--> (fixnum --> later-fives)} -> (fn later-fives.make))
(defstruct later-fives (it : five))
\\ loads
(define later-function {--> (fixnum --> fixnum)} -> (fn later-five))
(define-checked later-five {X : fixnum --> fixnum} {requires (fx= X 5)} X -> X)
\\ What a guard needs is asked in its own clause.
\\ loads
(refine.type from-0 N where (fx<= 0 N))
(defstruct counts (n : from-0))
(defstruct in-counts (in : counts))
(define-checked counted {C : counts --> boolean} {requires (fx<= 0 (counts.n C))} _ -> true)
(define guarded-counts {in-counts --> fixnum} (:in-counts in <- C) -> 1 where (counted C) _ -> 2)
\\ A let has the name of a form.
\\ loads
(define in-place-of {boolean --> fixnum --> fixnum --> fixnum} _ _ _ -> 7)
(define said-in-place {string --> fixnum} _ -> 7)
\\ says type error in rule 1 of named-if: named-if promises (fx= (if B 1 1) 1), which may not be so, as if (if B 1 1) is 0
(define-checked named-if {B : boolean --> R : fixnum} {ensures (fx= R 1)} B -> (let if (fn in-place-of) (if B 1 1)))
\\ says type error in rule 1 of named-error: named-error promises (fx= (simple-error "x") 1), which may not be so, as if (simple-error "x") is 0
(define-checked named-error {B : boolean --> R : fixnum} {ensures (fx= R 1)} B -> (let simple-error (fn said-in-place) (simple-error "x")))
\\ says type error in rule 1 of named-do: named-do promises (fx= (do 2 1) 1), which may not be so, as if (do 2 1) is 0
(define-checked named-do {B : boolean --> R : fixnum} {ensures (fx= R 1)} B -> (let do (/. X (/. Y (fixnum 7))) (do 2 1)))
\\ says type error in rule 1 of named-if: as-5 needs (fx= (if B 5 5) 5), which may not be so, as if (if B 5 5) is 0
(define named-if {boolean --> fixnum} B -> (let if (fn in-place-of) (as-5 (if B 5 5))))
\\ What a function of fewer arguments than it was given promises is not of what that gave.
\\ loads
(define known? {A --> boolean} _ -> true)
(refine.pure known?)
(define made-known {fixnum --> (fixnum --> fixnum)} X -> (fx+ X))
(refine.trust (made-known X) --> R where (known? R))
(define-checked adds {X : fixnum --> R : (fixnum --> fixnum)} {ensures (known? R)} X -> (made-known X))
(define-checked needs-known {X : A --> fixnum} {requires (known? X)} _ -> 1)
(define known-adds {fixnum --> fixnum} X -> (needs-known (adds X)))
\\ says type error in rule 1 of known-adds: needs-known needs (known? (((fn adds) X) X)), which may not be so, as if (known? (((fn adds) X) X)) is false
(define known-adds {fixnum --> fixnum} X -> (needs-known (adds X X)))
\\ What raises promises nothing, after what was done before it too.
\\ loads
(define-checked or-raises {X : fixnum --> R : fixnum} {ensures (fx= R 5)} 5 -> 5 X -> (do (str X) (simple-error "not 5")))
\\ Where it is no clause's action that may be tried again, fail-if gives what it is given, or (fail).
\\ loads untyped
(declare fail-if [[A --> boolean] --> [A --> A]])
\\ loads
(define-checked may-fail {X : fixnum --> R : fixnum} {ensures (fx= R 5)} X <- (fail-if (/. Y (fx= X 4)) 5) _ -> 5)
\\ says type error in rule 1 of may-fail: may-fail promises (fx= (fail-if (lambda) 5) 5), which may not be so, as if (fail-if (lambda) 5) is 0
(define-checked may-fail {X : fixnum --> R : fixnum} {ensures (fx= R 5)} X -> (fail-if (/. Y (fx= X 4)) 5))
\\ What a term is of, by what it is made of. Only of a fixnum do = and fx= say the same.
\\ loads
(define same-of {A --> A} X -> X)
(define gives-5 {--> fixnum} -> 5)
(define increased {fixnum --> fixnum} X -> (fx+ X 1))
(refine.pure swapped halves)
(define swapped {(A * B) --> (B * A)} P -> (@p (snd P) (fst P)))
(defstruct tally (mutable count : fixnum))
(define-checked needs-list {Xs : (list number) --> fixnum} {requires (= Xs [2.5])} _ -> 1)
(define-checked needs-same {X : A --> Y : A --> fixnum} {requires (= X Y)} _ _ -> 1)
(define type-of-call {--> fixnum} -> (let N (gives-5) (if (= N 5) (as-5 N) 0)))
(define type-of-applied {(fixnum --> fixnum) --> fixnum} F -> (let N (F 1) (if (= N 5) (as-5 N) 0)))
(define type-of-field {tally --> fixnum} (:tally count <- C) -> (let N C (if (= N 5) (as-5 N) 0)))
(define type-of-partial {(list fixnum) --> fixnum} Xs -> (let N (head (map (fn increased) Xs)) (if (= N 5) (as-5 N) 0)))
(refine.pure lowered)
(define lowered {fixnum --> fixnum} X -> (fx- X 1))
(define type-of-pure {(list fixnum) --> fixnum} Xs -> (let N (head (map (fn lowered) Xs)) (if (= N 5) (as-5 N) 0)))
(define type-of-pair {(symbol * fixnum) --> fixnum} P -> (let N (fst (swapped P)) (if (= N 5) (as-5 N) 0)))
(define type-of-made {symbol --> fixnum --> fixnum} S X -> (let N (fst (swapped (@p S X))) (if (= N 5) (as-5 N) 0)))
(define type-of-if {boolean --> fixnum --> fixnum} B X -> (let N (same-of (if B X 3)) (if (= N 5) (as-5 N) 0)))
(define type-of-list {(list fixnum) --> fixnum --> fixnum} Xs X -> (let N (head (append Xs [X 1])) (if (= N 5) (as-5 N) 0)))
(define type-of-lists {(list fixnum) --> fixnum} Xs -> (let N (head (append Xs [1 2 | Xs])) (if (= N 5) (as-5 N) 0)))
(define type-of-nested {(list (list fixnum)) --> fixnum} Xs -> (let N (head (head (append Xs [[1] | Xs]))) (if (= N 5) (as-5 N) 0)))
(define type-of-float {(list number) --> fixnum} Xs -> (if (= Xs [2.5]) (needs-list Xs) 0))
(define type-of-pairs {(list (fixnum * symbol)) --> (list (fixnum * symbol)) --> fixnum} P Q -> (if (= P Q) (needs-same P Q) 0))
(define type-of-numbers {number --> number --> fixnum} X Y -> (if (= [X 2.5] [2 Y]) (needs-same [X 2.5] [2 Y]) 0))
(define type-of-sum {(list symbol) --> number} Xs -> (a-fixnum (+ (length Xs) 1)))
(define type-of-choice {boolean --> (list symbol) --> number} B Xs -> (a-fixnum (if B (length Xs) 1)))
\\ says type error in rule 1 of type-of-vectors: needs-same needs (= P Q), which may not be so, as if (= P Q) is false. What it compares may change, so (= P Q) may be another each time
(define type-of-vectors {(vector number) --> (vector number) --> fixnum} P Q -> (if (= P Q) (needs-same P Q) 0))
\\ loads
(define halves {fixnum --> fixnum --> number} X Y -> (/ (fx->number X) (fx->number Y)))
\\ says type error in rule 1 of type-of-halves: a-fixnum needs (shen-jit.fixnum? (halves 1 2)), which may not be so, as if (shen-jit.fixnum? (halves 1 2)) is false
(define type-of-halves {--> number} -> (a-fixnum (halves 1 2)))
\\ says type error in rule 1 of type-of-number: a-fixnum needs (shen-jit.fixnum? (+ X 1)), which may not be so, as if (shen-jit.fixnum? (+ X 1)) is false
(define type-of-number {number --> number} X -> (a-fixnum (+ X 1)))
\\ What is of no type that is known may change.
\\ loads
(datatype things X : (vector number); _____ X : thing; _____ red : thing; _____ 7 : thing;)
(define-checked needs-same-thing {X : thing --> Y : thing --> fixnum} {requires (= X Y)} _ _ -> 1)
(define one-of-things {boolean --> thing --> thing --> thing} true X _ -> X _ _ Y -> Y)
(refine.pure one-of-things later-thing)
(define later-thing {A --> A --> A} X Y -> Y)
\\ says type error in rule 1 of same-things: needs-same-thing needs (= (one-of-things B red V) (one-of-things B 7 V)), which may not be so, as if (= (one-of-things B red V) (one-of-things B 7 V)) is false. What it compares may change, so (= (one-of-things B red V) (one-of-things B 7 V)) may be another each time
(define same-things {boolean --> (vector number) --> fixnum} B V -> (if (= (one-of-things B red V) (one-of-things B 7 V)) (needs-same-thing (one-of-things B red V) (one-of-things B 7 V)) 0))
\\ says type error in rule 1 of same-things: needs-same-thing needs (= (if B red 7) (if B 7 red)), which may not be so, as if (= (if B red 7) (if B 7 red)) is false. What it compares may change, so (= (if B red 7) (if B 7 red)) may be another each time
(define same-things {boolean --> (vector number) --> fixnum} B V -> (if (= (if B red 7) (if B 7 red)) (needs-same-thing (if B red 7) (if B 7 red)) 0))
\\ A list is empty or is not, whatever its elements are.
\\ loads
(define-checked needs-some {Xs : (list A) --> fixnum} {requires (not (= Xs []))} _ -> 1)
(define-checked needs-cons {Xs : (list A) --> fixnum} {requires (cons? Xs)} _ -> 1)
(define some-if {(list A) --> fixnum} Xs -> (if (= [] Xs) 0 (fx+ (needs-some Xs) (needs-cons Xs))))
(define some-after {(list A) --> fixnum} [] -> 0 Xs -> (fx+ (needs-some Xs) (needs-cons Xs)))
(define some-guarded {(list A) --> fixnum} Xs -> (needs-some Xs) where (cons? Xs) _ -> 0)
\\ says type error in rule 1 of some-not: needs-some needs (not (= Xs ())), which may not be so, as if (empty? Xs) is true
(define some-not {(list A) --> fixnum} Xs -> (needs-some Xs) where (= Xs []) _ -> 0)
\\ A Boolean of others, and a term with its type.
\\ loads
(define-checked flips {B : boolean --> C : boolean --> fixnum} {requires (= (not B) C)} _ _ -> 1)
(define flipped {boolean --> boolean --> fixnum} B C -> (if (= (not B) C) (flips B C) (fx+ (flips B (not B)) (flips (not B) B))))
(define-checked below-3 {X : fixnum --> fixnum} {requires (fx< (type X fixnum) 3)} _ -> 1)
(define is-below-3 {fixnum --> fixnum} X -> (if (fx< X 3) (below-3 X) 0))
\\ says type error in rule 1 of not-flipped: flips needs (= (not B) B), which may not be so, as if B is false
(define not-flipped {boolean --> fixnum} B -> (flips B B))
\\ What is no cons may be no list.
\\ loads
(define-checked needs-empty {X : A --> fixnum} {requires (empty? X)} _ -> 1)
(define no-cons {(list A) --> fixnum} Xs -> (if (cons? Xs) 0 (needs-empty Xs)))
\\ says type error in rule 1 of no-cons: needs-empty needs (empty? X), which may not be so, as if (empty? X) is false
(define no-cons {thing --> fixnum} X -> (if (cons? X) 0 (needs-empty X)))
\\ As many numbers as there are may be between any two.
\\ loads
(define-checked unit-taker {X : number --> number} {requires (> X 0) (< X 1)} X -> X)
(define some-between {number --> number --> number --> number} X Y Z -> (if (and (< 0 X) (and (< X Y) (and (< Y Z) (< Z 1)))) (unit-taker Y) 0))
\\ says type error in rule 1 of none-between: as-5 needs (fx= 3 5), which may not be so
(define none-between {number --> number --> number --> fixnum} X Y Z -> (if (and (< 0 X) (and (< X Y) (and (< Y Z) (< Z 1)))) (as-5 3) 0))
\\ What is equal is no less.
\\ loads
(define-checked needs-least {X : number --> Y : number --> number} {requires (<= X Y)} X _ -> X)
(define equal-numbers {number --> number --> number} X Y -> (if (and (= X Y) (>= X 0)) (needs-least X Y) 0))
\\ says type error in rule 1 of equal-numbers: needs-least needs (<= X Y), which may not be so, as if X is no number and Y is no number
(define equal-numbers {number --> number --> number} X Y -> (if (= X Y) (needs-least X Y) 0))
\\ What has a float that is no number in it is not equal to what is made the same.
\\ loads
(define floats-of {number --> (list number)} X -> [(- X X)])
(refine.pure floats-of)
\\ says type error in rule 1 of same-floats: needs-same needs (= (floats-of X) (floats-of X)), which may not be so, as if (= (floats-of X) (floats-of X)) is false
(define same-floats {number --> fixnum} X -> (needs-same (floats-of X) (floats-of X)))
\\ says type error in rule 1 of same-floats: needs-same needs (= X X), which may not be so, as if X is no number
(define same-floats {number --> fixnum} X -> (needs-same X X))
\\ A pure function gives the same for the same.
\\ loads
(refine.pure of-number of-list of-flag of-name of-both)
(define of-both {fixnum --> (list fixnum) --> fixnum} X _ -> X)
(define same-both {(list fixnum) --> fixnum --> fixnum --> fixnum} Xs X Y -> (if (and (fx= X Y) (fx= (of-both X Xs) 5)) (as-5 (of-both Y Xs)) 0))
(define other-both {(list fixnum) --> (list fixnum) --> fixnum --> fixnum --> fixnum} Xs Ys X Y -> (if (and (fx= X Y) (fx= (of-both X Xs) (of-both Y Ys))) 1 0))
(define of-number {fixnum --> fixnum} X -> X)
(define of-list {(list fixnum) --> fixnum --> fixnum} _ X -> X)
(define of-flag {boolean --> fixnum} B -> (if B 5 6))
(define of-name {symbol --> fixnum} _ -> 5)
(define same-number {fixnum --> fixnum --> fixnum} X Y -> (if (and (fx= X Y) (fx= (of-number X) 5)) (as-5 (of-number Y)) 0))
(define same-list {(list fixnum) --> fixnum --> fixnum --> fixnum} Xs X Y -> (if (and (fx= X Y) (fx= (of-list Xs X) 5)) (as-5 (of-list Xs Y)) 0))
(define same-flag {boolean --> boolean --> fixnum} B C -> (if (and (= B C) (fx= (of-flag B) 5)) (as-5 (of-flag C)) 0))
(define same-name {symbol --> symbol --> fixnum} B C -> (if (and (= B C) (fx= (of-name B) 5)) (as-5 (of-name C)) 0))
\\ says type error in rule 1 of same-list: as-5 needs (fx= (of-list Ys X) 5), which may not be so, as if (of-list Ys X) is 0
(define same-list {(list fixnum) --> (list fixnum) --> fixnum --> fixnum} Xs Ys X -> (if (fx= (of-list Xs X) 5) (as-5 (of-list Ys X)) 0))
\\ says type error in rule 1 of same-number: as-5 needs (fx= (of-number Y) 5), which may not be so, as if (of-number Y) is 0
(define same-number {fixnum --> fixnum --> fixnum} X Y -> (if (fx= (of-number X) 5) (as-5 (of-number Y)) 0))
\\ A type of two parameters is known by its name.
\\ loads
(refine.type (led A B) P : (A * (list B)) where (cons? (snd P)))
(define led-by {(led symbol fixnum) --> fixnum} P -> (needs-cons (snd P)))
\\ says type error in rule 1 of led-none: led-none promises (cons? (snd (@p S ()))), which may not be so
(define led-none {symbol --> (led symbol fixnum)} S -> (@p S []))
\\ A pattern that is there twice is what it matched first.
\\ says type error in rule 1 of twice-written: a-fixnum needs (shen-jit.fixnum? (head (cons 1 ()))), which may not be so, as if (shen-jit.fixnum? (head (cons 1 ()))) is false. What it is in may change, so (cons 1 ()) may be another each time
(define-checked twice-written {X : (list number) --> Y : (list number) --> number} {requires (shen-jit.fixnum? (head Y))} [1] [1] -> (a-fixnum (head [1])) _ _ -> 0)
\\ says type error in rule 1 of twice-written: a-fixnum needs (shen-jit.fixnum? (head (cons 1 ()))), which may not be so, as if (shen-jit.fixnum? (head (cons 1 ()))) is false. What it is in may change, so (cons 1 ()) may be another each time
(define-checked twice-written {X : (list (list number)) --> number} {requires (shen-jit.fixnum? (head (head (tail X))))} [[1] [1]] -> (a-fixnum (head [1])) _ -> 0)
\\ loads
(define-checked twice-written {X : (list number) --> Y : (list number) --> number} {requires (shen-jit.fixnum? (head Y))} [1] [1 2] -> (a-fixnum (head [1 2])) _ _ -> 0)
\\ What is written as a pattern with a wildcard is another.
\\ says type error in rule 1 of wild-written: up-only needs (= _ up), which may not be so
(define-checked wild-written {Xs : (list symbol) --> symbol} {requires (cons? Xs) (= (head Xs) up)} [_ | Xs] -> (up-only (head [_ | Xs])))
\\ says type error in rule 1 of wild-written: up-only needs (= _ up), which may not be so
(define-checked wild-written {P : (symbol * symbol) --> symbol} {requires (= (fst P) up)} (@p _ X) -> (up-only (fst (@p _ X))))
\\ says type error in rule 1 of wild-written: wild-written promises (= (fst (@p _ _)) up), which may not be so
(define-checked wild-written {P : (symbol * symbol) --> R : (symbol * symbol)} {requires (= (fst P) up)} {ensures (= (fst R) up)} (@p _ _) -> (@p _ _))
\\ Nor is one that is written where a let has one of its names, whatever that is.
\\ loads
(define-checked no-fixnum {P : (number * number) --> fixnum} {requires (not (shen-jit.fixnum? (fst P)))} _ -> 1)
(define-checked no-let {P : (number * number) --> fixnum} {requires (not (shen-jit.fixnum? (fst P)))} (@p 1 C) -> (no-fixnum (@p 1 C)) _ -> 0)
\\ says type error in rule 1 of let-itself: no-fixnum needs (not (shen-jit.fixnum? (fst (@p 1 C)))), which may not be so
(define-checked let-itself {P : (number * number) --> fixnum} {requires (not (shen-jit.fixnum? (fst P)))} (@p 1 C) -> (let C C (no-fixnum (@p 1 C))) _ -> 0)
\\ A function of no arguments names a number, and a part of what is made is what it was made of.
\\ loads
(define-checked at-most {--> R : fixnum} {ensures (fx= R 9)} -> 9)
(define-checked up-to-most {X : fixnum --> fixnum} {requires (fx<= X (at-most))} X -> X)
(define below-most {fixnum --> fixnum} X -> (if (fx< X 9) (up-to-most X) 0))
(define rest-of {(list A) --> (list A) --> fixnum} Xs Ys -> (needs-some (tail (append [] [(head Xs) | Ys]))) where (cons? Ys) _ _ -> 0)
(define rest-made {(list A) --> A --> fixnum} Xs X -> (needs-some (tail [X | Xs])) where (cons? Xs) _ _ -> 0)
\\ A let or a lambda that binds a constant of a pattern has it where that is written, as the kernel compiles them.
\\ says type error in rule 1 of up-again: up-only needs (= down up), which may not be so
(define up-again {(list symbol) --> symbol} [up | Xs] -> (let up down (up-only (head [up | Xs]))) _ -> up)
\\ says type error in rule 1 of up-again: up-only needs (= up up), which may not be so
(define up-again {(list symbol) --> symbol} [up | Xs] -> ((lambda up (up-only (head [up | Xs]))) down) _ -> up)
\\ loads
(defstruct above-acc (bal : above-0))
\\ says type error in rule 1 of one-again: above-acc.make needs (fx> Y 0), which may not be so, as if Y is 0
(define one-again {(fixnum * fixnum) --> fixnum --> above-acc} (@p 1 X) Y -> (let 1 Y (above-acc.make (fst (@p 1 X)))) _ _ -> (above-acc.make 1))
\\ And one that binds a form is refused.
\\ says refine: a let or a lambda binds (same 5 5) in rule 1 of let-form, which is no name
(define let-form {fixnum --> fixnum} X -> (let (same 5 5) (fx+ X 0) (as-5 (same 5 5))))
\\ What is written as a pattern is what it matched as = has it: 2.5e1 is 25.
\\ loads
(define kind-of {number --> fixnum} X -> (if (shen-jit.fixnum? X) 1 2))
(refine.pure kind-of)
(define-checked two-only {X : fixnum --> fixnum} {requires (fx= X 2)} X -> X)
\\ says type error in rule 1 of equal-written: two-only needs (fx= (kind-of (head (cons 25 Xs))) 2), which may not be so, as if (kind-of (head (cons 25 Xs))) is 0
(define equal-written {(list number) --> fixnum} [25 | Xs] -> (if (fx= (kind-of 2.5e1) 2) (two-only (kind-of (head [2.5e1 | Xs]))) 0) _ -> 0)
\\ says type error in rule 1 of protect-written: two-only needs (fx= (kind-of (head (cons 25 Xs))) 2), which may not be so, as if (kind-of (head (cons 25 Xs))) is 0
(define protect-written {(list number) --> fixnum} [25 | Xs] -> (if (fx= (kind-of 2.5e1) 2) (two-only (kind-of (head [(protect 2.5e1) | Xs]))) 0) _ -> 0)
\\ A definition is compiled without protect: of a name, it is the value that the name has there.
\\ says type error in rule 1 of protected-twice: same needs (fx= X X), which may not be so, as if Z is 0
(define protected-twice {fixnum --> fixnum} Z -> (let X (fx+ Z 5) (let Y (protect X) (let X (fx+ Z 6) (same Y (protect X))))))
\\ says type error in rule 1 of protected-call: above-acc.make needs (fx> N 0), which may not be so, as if N is 0
(define protected-call {fixnum --> above-acc} N -> (protect (above-acc.make N)))
\\ A field is what its reader says, and not what a type that was declared again says now.
\\ loads
(refine.type declared-again N where (fx<= 0 N))
(defstruct holds-again (v : declared-again))
\\ says type error in rule 1 of read-again: hundred needs (fx<= 100 (holds-again.v B)), which may not be so, as if (holds-again.v B) is 0
(refine.type declared-again N where (fx<= 100 N))
(define-checked hundred {X : fixnum --> fixnum} {requires (fx<= 100 X)} X -> X)
(define read-again {holds-again --> fixnum} B -> (hundred (holds-again.v B)))
\\ A type over a triple is one of pairs, in a field that changes too.
\\ loads
(defstruct holds-triple (mutable t : triple))
(defstruct holds-pair (mutable p : (fixnum * fixnum)))
(define pair-first {holds-pair --> number} (:holds-pair p <- (@p A B)) -> (a-fixnum A))
\\ says type error in rule 1 of in-triple: positive needs (fx> -1 0), which may not be so
(define in-triple {holds-triple --> fixnum} (:holds-triple t <- P) -> (if (shen-jit.fixnum? P) 1 (positive -1)))
\\ A function that a lambda gives with some of its arguments is not the same where they may change, nor is = of what may,
\\ nor a function that one is given.
\\ loads
(defstruct cell-of (mutable m : fixnum))
(define apply-1 {(fixnum --> fixnum) --> fixnum} F -> (F 1))
(refine.pure apply-1)
(define-checked needs-all {F : (A --> boolean) --> Xs : (list A) --> fixnum} {requires (all? F Xs)} F Xs -> 1)
\\ says type error in rule 1 of read-each-call: as-5 needs (fx= (apply-1 F) 5), which may not be so, as if (apply-1 F) is 0. A function that it is given may change, so (apply-1 F) may be another each time
(define read-each-call {cell-of --> fixnum} C -> (let F (fx+ (cell-of.m C)) (if (fx= (apply-1 F) 5) (do (cell-of.m-> C 9) (as-5 (apply-1 F))) 0)))
\\ says type error in rule 1 of equal-vector: needs-all needs (all? (fn = V) Vs), which may not be so, as if (all? (fn = V) Vs) is false. What it compares may change, so (all? (fn = V) Vs) may be another each time
(define equal-vector {(vector fixnum) --> (list (vector fixnum)) --> fixnum} V Vs -> (if (all? (= V) Vs) (do (vector-> V 1 (fixnum 0)) (needs-all (= V) Vs)) 0))
\\ says type error in rule 1 of reads-vector: needs-all needs (all? F Xs), which may not be so, as if (all? F Xs) is false. A function that it is given may change, so (all? F Xs) may be another each time
(define reads-vector {(vector fixnum) --> (list fixnum) --> fixnum} V Xs -> (let F (/. X (fx> (<-vector V 1) X)) (if (all? F Xs) (do (vector-> V 1 (fixnum 0)) (needs-all F Xs)) 0)))
\\ says type error in rule 1 of given-on: needs-all needs (all? F Xs), which may not be so, as if (all? F Xs) is false. A function that it is given may change, so (all? F Xs) may be another each time
(define given-on {(fixnum --> boolean) --> (list fixnum) --> fixnum} F Xs -> (if (all? F Xs) (needs-all F Xs) 0))
\\ loads
(define given-on {(list fixnum) --> fixnum} Xs -> (if (all? (fx< 3) Xs) (needs-all (fx< 3) Xs) 0))
(define given-equal {(list fixnum) --> fixnum} Xs -> (if (all? (= 5) Xs) (needs-all (= 5) Xs) 0))
\\ A cond that a rule of one's own types is ifs.
\\ loads
(datatype cond-rule
  P : boolean; A : T; B : T;
  __________________________
  (cond (P A) (true B)) : T;)
\\ says type error in rule 1 of in-cond: as-5 needs (fx= X 5), which may not be so, as if X is 0
(define in-cond {fixnum --> fixnum} X -> (do (cond ((fx= X 5) (five-or-none X)) (true 0)) (as-5 X)))
\\ loads
(define in-cond {fixnum --> fixnum} X -> (cond ((fx= X 5) (as-5 X)) (true 0)))
\\ says type error in rule 1 of in-cond: as-5 needs (fx= X 5), which may not be so, as if X is 0
(define in-cond {fixnum --> fixnum} X -> (cond ((fx= X 5) (as-5 X)) (true (as-5 X))))
\\ What refine makes of terms is no program's.
\\ says refine: refine.valued is refine's own in rule 1 of own-name
(define refine.valued {fixnum --> fixnum} N -> 100)
(define own-name {fixnum --> fixnum} X -> (if (fx= X 5) (as-5 (refine.valued 1)) 0))
\\ A signature may write a function that the result is, or its synonym.
\\ loads
(define sum-3 {above-0 --> (fixnum --> fixnum --> fixnum)} X Y Z -> (fx+ X (fx+ Y Z)))
(synonyms three-op (fixnum --> fixnum --> fixnum))
(define sum-3-named {above-0 --> three-op} X Y Z -> (fx+ X (fx+ Y Z)))
(define sums-3 {--> fixnum} -> (fx+ (sum-3 3 1 2) (sum-3-named 3 1 2)))
(sums-3)
\\ A type with parameters has them.
\\ loads
(refine.type (nonempty-of A) Xs : (list A) where (not (empty? Xs)))
\\ says refine: nonempty-of is not a type, and (nonempty-of A) is, in the signature of first-of
(define first-of {nonempty-of --> fixnum} [X | _] -> X)
\\ A struct that is declared after what makes one.
\\ loads
(define make-later {fixnum --> later-acc} N -> (if (fx> N 0) (later-acc.make N) (later-acc.make 1)))
(defstruct later-acc (bal : above-0))
(make-later 5)
