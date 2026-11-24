\\ Typed definitions that refine must refuse. Each is its own program.
(define-checked at {X : fixnum --> fixnum} {requires (fx<= 0 X)} X -> X)
(define refused {fixnum --> fixnum} X -> (at X))
\\ next
\\ One below, and the branch the condition does not hold in.
(define-checked at {X : fixnum --> fixnum} {requires (fx<= 0 X)} X -> X)
(define-checked refused {fixnum --> fixnum} X -> (at (fx- X 1)) where (fx>= X 0) _ -> 0)
\\ next
(define-checked at {X : fixnum --> fixnum} {requires (fx<= 0 X)} X -> X)
(define-checked refused {fixnum --> fixnum} X -> (if (fx>= X 0) 0 (at X)))
\\ next
\\ The clause before this one may not have matched for another reason.
(define-checked at {X : fixnum --> fixnum} {requires (fx<= 0 X)} X -> X)
(define-checked refused {fixnum --> fixnum --> fixnum} X 1 -> 0 where (fx< X 0) X _ -> (at X))
\\ next
\\ A loop that reads one byte too many.
(define-checked byte-at {B : buffer.storage --> I : fixnum --> fixnum}
  {requires (fx<= 0 I) (fx< I (shen-jit.bytes-length B))} B I -> (shen-jit.u8 B I))
(define-checked refused {B : buffer.storage --> I : fixnum --> N : fixnum --> fixnum --> fixnum}
  {requires (fx<= 0 I) (fx<= N (shen-jit.bytes-length B))}
  _ I N Acc -> Acc where (fx> I N)
  B I N Acc -> (refused B (fx+ I 1) N (fx+ Acc (byte-at B I))))
\\ next
\\ What is tested second is not known in what is tested first.
(define-checked at {X : fixnum --> fixnum} {requires (fx<= 0 X)} X -> X)
(define-checked refused {fixnum --> boolean} X -> (and (fx< (at X) 9) (fx>= X 0)))
\\ next
\\ A variable of the same name is another.
(define-checked at {X : fixnum --> fixnum} {requires (fx<= 100 X)} X -> X)
(define-checked refused {fixnum --> fixnum} X -> (let X (fx+ X 1) (at X)))
\\ next
(define-checked at {X : fixnum --> fixnum} {requires (fx<= 0 X)} X -> X)
(define-checked refused {fixnum --> (fixnum --> fixnum)} X -> (/. X (at X)) where (fx>= X 0))
\\ next
\\ A call that is not pure may give something else the second time.
(define-checked at {X : fixnum --> fixnum} {requires (fx<= X 9)} X -> X)
(define-checked refused {buffer.storage --> fixnum} B -> (if (fx<= (shen-jit.u8 B 0) 9) (at (shen-jit.u8 B 0)) 0))
\\ next
\\ A promise not kept, on one way out.
(define-checked refused {fixnum --> R : fixnum} {ensures (fx> R 0)} N -> (if (fx< N 0) (fx- 0 N) N))
\\ next
(define-checked refused {fixnum --> R : fixnum} {ensures (fx> R 0)} N -> (if (fx< N 0) N 1))
\\ next
(define-checked refused {N : fixnum --> R : fixnum} {ensures (fx>= R N)} N -> (let M (fx* 2 N) M))
\\ next
\\ A recursive call that its condition does not hold of.
(define-checked refused {N : fixnum --> fixnum} {requires (fx>= N 0)} 0 -> 0 N -> (refused (fx- N 2)))
\\ next
\\ What a contract says of numbers is nothing to a number that may be a float.
(define-checked at {X : number --> number} {requires (fx<= 0 X)} X -> X)
\\ next
\\ Equality of numbers is not equality of fixnums: a float that is no number is not equal to itself.
(define-checked at {X : fixnum --> fixnum} {requires (fx<= 1 X)} X -> X)
(define-checked refused {number --> fixnum --> fixnum} N X -> (if (= N N) 0 (at X)))
\\ next
\\ Two calls are two unknowns, whichever arguments they are.
(define-checked in-order {A : fixnum --> B : fixnum --> fixnum} {requires (fx<= A B)} A B -> (fx- B A))
(define refused {buffer.storage --> fixnum} B -> (in-order (shen-jit.u8 B 0) (shen-jit.u8 B 1)))
\\ next
\\ A Boolean that cannot be read proves nothing, however it is asked for.
(define odd {fixnum --> boolean} N -> (fx= 1 (shen-jit.bit-and N 1)))
(define-checked at {X : fixnum --> fixnum} {requires (odd X)} X -> X)
(define-checked refused {fixnum --> fixnum} X -> (if (odd X) (at X) 0))
\\ next
(define odd {fixnum --> boolean} N -> (fx= 1 (shen-jit.bit-and N 1)))
(define-checked at {X : fixnum --> fixnum} {requires (fx<= 0 X)} X -> X)
(define-checked refused {fixnum --> fixnum} X -> (if (not (and (odd X) (fx< X 0))) (at X) 0))
\\ next
\\ Products of unknowns, and what wraps or overflows, are not worked out.
(define-checked at {X : fixnum --> fixnum} {requires (fx<= 0 X)} X -> X)
(define-checked refused {fixnum --> fixnum} X -> (at (fx* X X)))
\\ next
\\ Refined types.
(refine.type natural N where (fx<= 0 N))
(define refused {fixnum --> natural} N -> N)
\\ next
(refine.type natural N where (fx<= 0 N))
(define-checked refused {natural --> natural} N -> (fx- N 1))
\\ next
(refine.type natural N where (fx<= 0 N))
(define refused {number --> natural} N -> N)
\\ next
(refine.type natural N where (fx<= 0 N))
(defstruct span (start : natural) (size : natural))
(define refused {fixnum --> span} A -> (span.make A 0))
\\ next
\\ Not a fixnum at all: the type checker's own error.
(define-checked at {X : fixnum --> fixnum} {requires (fx<= 0 X)} X -> X)
(define refused {string --> fixnum} X -> (at X))
\\ next
\\ A promise of a call that may not have been made: g is given -7.
(define-checked at-least-5 {N : fixnum --> fixnum} {requires (fx>= N 5)} N -> N)
(define-checked f {N : fixnum --> R : fixnum} {requires (fx> N 0)} {ensures (fx<= 0 R) (fx< R N)} N -> (fx- N 1))
(define-checked refused {fixnum --> fixnum} N -> (if (or (fx<= N 0) (fx> (f N) 3)) (at-least-5 N) 0))
\\ next
\\ Nor does a call that raises promise anything where it is not made.
(define-checked positive {N : fixnum --> R : fixnum} {ensures (fx>= R N) (fx> R 0) (fx< R 9)} N -> (if (and (fx> N 0) (fx< N 9)) N (error "no")))
(define-checked at {N : fixnum --> fixnum} {requires (fx> N -5)} N -> N)
(define-checked refused {fixnum --> fixnum} N -> (if (or (fx< N -5) (fx> (positive N) 3)) (at N) 0))
\\ next
\\ A condition is not evaluated, so what its calls would promise is not known from it.
(define-checked positive {N : fixnum --> R : fixnum} {ensures (fx>= R N) (fx> R 0)} N -> (if (fx> N 0) N (error "no")))
(refine.pure positive)
(define-checked at {N : fixnum --> fixnum} {requires (fx> N 0)} N -> N)
(define-checked refused {N : fixnum --> fixnum} {requires (fx>= (fx- (positive N) (positive N)) 0)} N -> (at N))
\\ next
(define-checked positive {N : fixnum --> R : fixnum} {ensures (fx>= R N) (fx> R 0)} N -> (if (fx> N 0) N (error "no")))
(refine.pure positive)
(define-checked at {N : fixnum --> fixnum} {requires (fx> N 0)} N -> N)
(define-checked refused {N : fixnum --> fixnum} {requires (fx= (positive N) N)} N -> (at N))
\\ next
(define sorted? {(list number) --> boolean} _ -> true)
(refine.pure sorted?)
(define-checked search {Xs : (list number) --> fixnum} {requires (sorted? Xs)} _ -> 0)
(define-checked refused {(list number) --> fixnum} Xs -> (if (sorted? Xs) 0 (search Xs)))
\\ next
\\ A predicate of something else, and one that is not pure.
(define sorted? {(list number) --> boolean} _ -> true)
(refine.pure sorted?)
(define-checked search {Xs : (list number) --> fixnum} {requires (sorted? Xs)} _ -> 0)
(define-checked refused {(list number) --> (list number) --> fixnum} Xs Ys -> (if (sorted? Xs) (search Ys) 0))
\\ next
(define sorted? {(list number) --> boolean} _ -> true)
(define-checked search {Xs : (list number) --> fixnum} {requires (sorted? Xs)} _ -> 0)
(define-checked refused {(list number) --> fixnum} Xs -> (if (sorted? Xs) (search Xs) 0))
\\ next
\\ A named condition that its function is not.
(define-checked in-range? {I : fixnum --> N : fixnum --> R : boolean} {ensures (= R (and (fx<= 0 I) (fx< I N)))} I N -> (and (fx<= 0 I) (fx<= I N)))
\\ next
(define-checked in-range? {I : fixnum --> N : fixnum --> R : boolean} {ensures (= R (and (fx<= 0 I) (fx< I N)))} I N -> (and (fx<= 0 I) (fx< I N)))
(define-checked at {I : fixnum --> N : fixnum --> fixnum} {requires (in-range? I N)} I _ -> I)
(define-checked refused {fixnum --> fixnum --> fixnum} I N -> (if (in-range? I N) (at N I) 0))
\\ next
(define-checked opened {M : symbol --> fixnum} {requires (= M read)} _ -> 1)
(define-checked refused {symbol --> fixnum} M -> (if (= M write) 0 (opened M)))
\\ next
(define-checked named {S : string --> string} {requires (not (= S ""))} S -> S)
(define-checked refused {string --> string} S -> (named S) where (not (= S "a")) _ -> "")
\\ next
(define-checked first {Xs : (list number) --> number} {requires (not (empty? Xs))} [X | _] -> X)
(define-checked refused {(list number) --> number} Xs -> (if (> (length Xs) 0) (first (tail Xs)) 0))
\\ next
\\ What the tail of no list would be is not known.
(define-checked first {Xs : (list number) --> number} {requires (not (empty? Xs))} [X | _] -> X)
(define-checked refused {(list number) --> number} [_ | Xs] -> 0 where (> (length Xs) 5) Xs -> (first Xs))
\\ next
(refine.type (nonempty A) Xs : (list A) where (not (empty? Xs)))
(define first {(nonempty A) --> A} [X | _] -> X)
(define refused {--> number} -> (first []))
\\ next
(define-checked dot {Xs : (list number) --> Ys : (list number) --> number} {requires (= (length Xs) (length Ys))}
  [] [] -> 0
  [X | Xs] [Y | Ys] -> (dot Xs [Y | Ys]))
\\ next
\\ A field that changes may be another the second time.
(defstruct cell (mutable held : fixnum))
(define-checked at {N : fixnum --> fixnum} {requires (fx> N 0)} N -> N)
(define-checked refused {cell --> fixnum} C -> (if (fx> (cell.held C) 0) (at (cell.held C)) 0))
\\ next
\\ So may whatever a vector holds, and whether two are equal.
(define-checked at {V : (vector number) --> W : (vector number) --> fixnum} {requires (= V W)} _ _ -> 0)
(define-checked refused {(vector number) --> (vector number) --> fixnum} V W -> (if (= V W) (at V W) 0))
\\ next
(define code-of {symbol --> fixnum} _ -> 1)
(refine.pure code-of)
(define-checked coded {N : fixnum --> S : symbol --> fixnum} {requires (fx= N (code-of S))} N _ -> N)
(define-checked refused {symbol --> symbol --> fixnum} S T -> (let N (code-of S) (if (= S T) 0 (coded N T))))
\\ next
\\ Neither less than 0 nor more than 1, and no number.
(refine.type probability X : number where (and (>= X 0) (<= X 1)))
(define-checked refused {number --> probability} X -> 0 where (< X 0) X -> 1 where (> X 1) X -> X)
\\ next
(refine.type probability X : number where (and (>= X 0) (<= X 1)))
(define refused {--> probability} -> 1.5)
\\ next
\\ Between two numbers there is another, and arithmetic rounds.
(define-checked above {X : number --> number} {requires (>= X 1)} X -> X)
(define-checked refused {number --> number} X -> (if (> X 0) (above X) 0))
\\ next
(define-checked above {X : number --> number} {requires (> X 0)} X -> X)
(define-checked refused {number --> number} X -> (if (> X 0) (above (+ X 1)) 0))
\\ next
\\ Two floats that are no numbers may be equal.
(define-checked above {X : number --> number} {requires (>= X 0)} X -> X)
(define-checked refused {number --> number --> number} X Y -> (if (and (= X Y) (not (< X 0))) (above X) 0))
\\ next
\\ The parts of a pair, of a struct and of a promise are their own.
(define-checked at {N : fixnum --> fixnum} {requires (fx> N 0)} N -> N)
(define-checked refused {(fixnum * fixnum) --> fixnum} (@p A _) -> 0 where (fx<= A 0) (@p _ B) -> (at B))
\\ next
(defstruct span (start : fixnum) (end : fixnum))
(define-checked size {S : span --> fixnum} {requires (fx<= (span.start S) (span.end S))} S -> (fx- (span.end S) (span.start S)))
(define refused {fixnum --> fixnum --> fixnum} A B -> (size (span.make A B)))
\\ next
(define-checked up {N : fixnum --> R : fixnum} {ensures (fx>= R N)} N -> (fx+ N 1))
(define-checked in-order {A : fixnum --> B : fixnum --> fixnum} {requires (fx<= A B)} A _ -> A)
(define refused {fixnum --> fixnum} N -> (in-order (up N) N))
\\ next
\\ Sums of floats round, so that one may not be less where another is.
(define-checked less {A : number --> B : number --> number} {requires (< A B)} A _ -> A)
(define-checked refused {number --> number --> number --> number} X Y Z -> (if (< (+ X Y) (+ X Z)) (less (+ Y 1) (+ Z 1)) 0))
\\ next
\\ Promises that define each other in a circle, which nothing gives, as both only raise.
(refine.pure f g)
(define-checked f {X : fixnum --> R : fixnum} {ensures (fx= R (fx+ (g X) 1))} _ -> (simple-error "f"))
(define-checked g {X : fixnum --> R : fixnum} {ensures (fx= R (f X))} _ -> (simple-error "g"))
(define-checked at {N : fixnum --> fixnum} {requires (fx> N 0)} N -> N)
(define-checked not-above {X : fixnum --> fixnum} {requires (not (fx> (f X) (f X)))} _ -> (at -1))
(define-checked refused {X : fixnum --> fixnum} {requires (fx>= (f X) (f X))} X -> (not-above X))
\\ next
(refine.pure f g)
(define-checked f {X : fixnum --> R : fixnum} {ensures (fx= R (fx+ (g X) 1))} _ -> (simple-error "f"))
(define-checked g {X : fixnum --> R : fixnum} {ensures (fx= R (f X))} _ -> (simple-error "g"))
(define-checked at {N : fixnum --> fixnum} {requires (fx> N 0)} N -> N)
(define-checked refused {X : fixnum --> fixnum} {requires (fx<= (f X) (f X)) (fx>= (f X) (f X))} _ -> (at -1))
\\ next
\\ What a vector holds changes, so a pair that has one may be equal to another and then not.
(define-checked at {N : fixnum --> fixnum} {requires (fx> N 0)} N -> N)
(define-checked refused {(fixnum * (vector number)) --> (fixnum * (vector number)) --> fixnum}
  P Q -> (if (= P Q) (do (vector-> (snd P) 1 2) (if (= P Q) 0 (at -1))) 0))
\\ next
\\ A list of a refined type is of its base for head, and what is known of the head is what is of any.
(refine.type couple Xs : (list fixnum) where (= (length Xs) 2))
(define-checked at {N : fixnum --> fixnum} {requires (fx> N 0)} N -> N)
(define-checked refused {couple --> fixnum} Xs -> (at (head Xs)))
\\ next
\\ A variable of a refined type is of its base, and one of the base is not of the type.
(refine.type rising P : (fixnum * fixnum) where (fx<= (fst P) (snd P)))
(define rise {rising --> fixnum} P -> (fx- (snd P) (fst P)))
(define refused {(fixnum * fixnum) --> fixnum} P -> (rise P))
\\ next
\\ Shifts, masks and remainders that give one more, or less than nothing.
(define-checked at {I : fixnum --> N : fixnum --> fixnum} {requires (fx<= 0 I) (fx< I N)} I _ -> I)
(define-checked refused {B : fixnum --> fixnum} {requires (fx<= 0 B) (fx<= B 255)} B -> (at (shen-jit.shift-right B 3) 31))
\\ next
(define-checked at {I : fixnum --> N : fixnum --> fixnum} {requires (fx<= 0 I) (fx< I N)} I _ -> I)
(define-checked refused {fixnum --> fixnum} B -> (at (shen-jit.shift-right B 3) 4611686))
\\ next
(define-checked at {I : fixnum --> N : fixnum --> fixnum} {requires (fx<= 0 I) (fx< I N)} I _ -> I)
(define-checked refused {fixnum --> fixnum} B -> (at (shen-jit.bit-and B 15) 15))
\\ next
(define-checked at {I : fixnum --> N : fixnum --> fixnum} {requires (fx<= 0 I) (fx< I N)} I _ -> I)
(define-checked refused {A : fixnum --> B : fixnum --> fixnum} {requires (fx<= 0 A) (fx<= A 2) (fx<= 0 B) (fx<= B 1)} A B -> (at (shen-jit.bit-or A B) 3))
\\ next
(define-checked at {I : fixnum --> N : fixnum --> fixnum} {requires (fx<= 0 I) (fx< I N)} I _ -> I)
(define-checked refused {A : fixnum --> fixnum --> fixnum} {requires (fx<= 0 A) (fx<= A 2)} A B -> (at (shen-jit.bit-xor A B) 99))
\\ next
(define-checked at {I : fixnum --> N : fixnum --> fixnum} {requires (fx<= 0 I) (fx< I N)} I _ -> I)
(define-checked refused {fixnum --> fixnum} N -> (at (fxremainder N 4) 4))
\\ next
(define-checked same {A : fixnum --> B : fixnum --> fixnum} {requires (fx= A B)} A _ -> A)
(define-checked refused {fixnum --> fixnum --> fixnum} N D -> (same N (fx* (fxquotient N D) D)))
\\ next
\\ A left shift of a number that is large enough loses bits.
(define-checked same {A : fixnum --> B : fixnum --> fixnum} {requires (fx= A B)} A _ -> A)
(define-checked refused {fixnum --> fixnum} N -> (same (fx* 16 N) (shen-jit.shift-left N 4)))
\\ next
\\ One past the end of what is made, of a slice, and of what is written.
(define-checked byte {B : buffer.storage --> I : fixnum --> fixnum} {requires (fx<= 0 I) (fx< I (shen-jit.bytes-length B))} B I -> (shen-jit.u8 B I))
(define-checked refused {N : fixnum --> fixnum} {requires (fx> N 0)} N -> (let B (shen-jit.bytes N) (byte B N)))
\\ next
(define-checked item {V : buffer.view --> I : fixnum --> fixnum} {requires (fx<= 0 I) (fx< I (buffer.length V))} V I -> (buffer.u8 V I))
(define-checked refused {V : buffer.view --> fixnum} {requires (fx= 8 (buffer.length V))} V -> (let W (buffer.slice V 4 4) (item W 4)))
\\ next
(define-checked byte {B : buffer.storage --> I : fixnum --> fixnum} {requires (fx<= 0 I) (fx< I (shen-jit.bytes-length B))} B I -> (shen-jit.u8 B I))
(define-checked refused {--> fixnum} -> (byte (shen-jit.copy-bytes (shen-jit.bytes 3) 0 (shen-jit.bytes 9) 0 3) 3))
\\ next
\\ There are no bytes of a negative length, but a condition that names some says nothing of their length.
(define-checked from-0 {N : fixnum --> fixnum} {requires (fx<= 0 N)} N -> N)
(define-checked refused {N : fixnum --> fixnum} {requires (fx< (shen-jit.bytes-length (shen-jit.bytes N)) 5)} N -> (from-0 N))
\\ next
(define-checked from-0 {N : fixnum --> fixnum} {requires (fx<= 0 N)} N -> N)
(define-checked refused {V : buffer.view --> N : fixnum --> fixnum} {requires (fx< (buffer.length (buffer.slice V 0 N)) 5)} _ N -> (from-0 N))
\\ next
(define-checked from-0 {N : fixnum --> fixnum} {requires (fx<= 0 N)} N -> N)
(define-checked refused {N : fixnum --> fixnum} {requires (fx< (buffer.length (buffer.new N)) 5)} N -> (from-0 N))
\\ next
\\ There is no remainder of a division by 0, which says nothing of what is divided.
(define-checked odd-one {N : fixnum --> fixnum} {requires (fx= 7 (fxremainder N 0))} N -> N)
(define-checked refused {N : fixnum --> fixnum} {requires (fx>= N 0)} N -> (odd-one N))
\\ next
\\ What the first part of a do may not have called, and what only the second does.
(define-checked from-0 {N : fixnum --> fixnum} {requires (fx<= 0 N)} N -> N)
(define-checked check {N : fixnum --> boolean} {ensures (fx<= 0 N)} N -> true where (fx<= 0 N) _ -> (error "negative"))
(define-checked refused {fixnum --> boolean --> fixnum} N Maybe -> (do (if Maybe (check N) true) (from-0 N)))
\\ next
(define-checked from-0 {N : fixnum --> fixnum} {requires (fx<= 0 N)} N -> N)
(define-checked check {N : fixnum --> boolean} {ensures (fx<= 0 N)} N -> true where (fx<= 0 N) _ -> (error "negative"))
(define-checked refused {fixnum --> boolean} N -> (do (from-0 N) (check N)))
\\ next
(define-checked from-0 {N : fixnum --> fixnum} {requires (fx<= 0 N)} N -> N)
(define-checked check {N : fixnum --> boolean} {ensures (fx<= 0 N)} N -> true where (fx<= 0 N) _ -> (error "negative"))
(define-checked refused {fixnum --> fixnum} N -> (do (trap-error (check N) (/. E true)) (from-0 N)))
\\ next
\\ One of three is not one of two, and a list that is not written may have anything.
(define-checked access {M : symbol --> fixnum} {requires (element? M [read write])} read -> 1 _ -> 2)
(define-checked refused {symbol --> fixnum} M -> (if (element? M [read write other]) (access M) 0))
\\ next
(define-checked access {M : symbol --> fixnum} {requires (element? M [read write])} read -> 1 _ -> 2)
(define-checked refused {symbol --> (list symbol) --> fixnum} M Ms -> (if (element? M [read | Ms]) (access M) 0))
\\ next
(define-checked access {M : symbol --> fixnum} {requires (element? M [read write])} read -> 1 _ -> 2)
(define-checked refused {symbol --> fixnum} M -> (if (element? M [read close]) 0 (access M)))
\\ next
\\ element? of a list that is not written is nothing that can be read: its elements may be vectors.
(define-checked among {M : symbol --> Ms : (list symbol) --> fixnum} {requires (element? M Ms)} _ _ -> 1)
(define-checked refused {symbol --> (list symbol) --> fixnum} M Ms -> (if (element? M Ms) (among M Ms) 0))
\\ next
\\ What is under a type has its parameters.
(refine.type (nonempty A) Xs : (list A) where (not (empty? Xs)))
(refine.type (short B) Xs : (nonempty B) where (<= (length Xs) 2))
(define refused {(short fixnum) --> (list symbol)} Xs -> Xs)
\\ next
\\ What is promised is of the argument, and not of a let that has its name.
(define-checked refused {X : fixnum --> R : fixnum} {ensures (fx<= R X)} X -> (let X 0 -3))
\\ next
(define-checked refused {X : fixnum --> Y : fixnum --> R : fixnum} {ensures (fx<= R Y)} X Y -> (if (fx< X Y) X (let Z X (let Y Z Y))))
\\ next
(define-checked refused {P : (fixnum * fixnum) --> R : fixnum} {ensures (fx<= R (fst P))} (@p A B) -> (let A B A))
\\ next
\\ One bit more than both have, one that has more, and one that may be negative.
(refine.type u8 N where (and (fx<= 0 N) (fx<= N 255)))
(define-checked refused {u8 --> N : fixnum --> u8} {requires (fx<= 0 N) (fx<= N 256)} A N -> (shen-jit.bit-xor A N))
\\ next
(refine.type u8 N where (and (fx<= 0 N) (fx<= N 255)))
(refine.type u16 N where (and (fx<= 0 N) (fx<= N 65535)))
(define-checked refused {u8 --> u16 --> u8} A B -> (shen-jit.bit-or A B))
\\ next
(refine.type u32 N where (and (fx<= 0 N) (fx<= N 4294967295)))
(define-checked refused {u32 --> N : fixnum --> u32} {requires (fx<= N 4294967295)} A N -> (shen-jit.bit-xor A N))
\\ next
\\ What is compared is of one type in the end.
(refine.type natural N where (fx<= 0 N))
(refine.type small N : natural where (fx< N 10))
(define refused {natural --> symbol --> boolean} X S -> (= X S))
\\ next
\\ That two are equal does not make one of the other's type where it is false.
(refine.type natural N where (fx<= 0 N))
(refine.type small N : natural where (fx< N 10))
(define-checked from-0 {N : fixnum --> fixnum} {requires (fx<= 0 N)} N -> N)
(define-checked refused {natural --> fixnum --> fixnum} X Y -> (if (= X Y) 0 (from-0 Y)))
\\ next
\\ What is compared is well typed itself.
(refine.type natural N where (fx<= 0 N))
(define refused {natural --> symbol --> boolean} X S -> (= X (fx+ S 1)))
\\ next
\\ A constructor of too few arguments makes no struct.
(defstruct span (start : fixnum) (end : fixnum))
(define-checked positive {X : fixnum --> fixnum} {requires (fx> X 0)} X -> X)
(define-checked refused {fixnum --> fixnum} X -> (positive (span.end (span.make X))))
