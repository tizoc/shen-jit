\\ Definitions with floats in registers, which tests/typed.shen loads sealed under (optimise +), runs,
\\ and compares with what the same arithmetic gives boxed.

\\ A loop carrying floats, with its parameters in another order each time round.
(define float-orbit {float --> float --> float --> float --> fixnum --> fixnum --> fixnum}
  _ _ _ _ Limit Limit -> Limit
  X Y CX CY N Limit -> (let XX (fl* X X)
                            YY (fl* Y Y)
                         (if (fl> (fl+ XX YY) (float 4))
                             N
                             (float-orbit (fl+ (fl- XX YY) CX) (fl+ (fl* (float 2) (fl* X Y)) CY) CX CY
                                         (fx+ N 1) Limit))))

(define float-swap {fixnum --> float --> float --> float}
  0 X Y -> (fl- X Y)
  N X Y -> (float-swap (fx- N 1) Y (fl+ X 0.5)))

\\ A float chosen by a test, and comparisons kept as values.
(define float-pick {boolean --> float --> float --> float}
  B X Y -> (fl* (if B X Y) 2.5))

(define float-order {float --> float --> (list boolean)}
  X Y -> [(fl< X Y) (fl> X Y) (fl<= X Y) (fl>= X Y) (= X Y)])

\\ Mixed comparisons retain exact fixnum ordering, even while float arithmetic uses registers.
\\ The second definition's number can be a fixnum or a float at run time.
(define float-word-order {float --> fixnum --> (list boolean)}
  X Y -> (let R (fl->number (fl+ X (float 0))) N (fx->number Y)
           [(< R N) (> R N) (<= R N) (>= R N) (< N R) (> N R) (<= N R) (>= N R)]))

(define float-number-order {float --> number --> (list boolean)}
  X N -> (let R (fl->number (fl+ X (float 0)))
           [(< R N) (> R N) (<= R N) (>= R N) (< N R) (> N R) (<= N R) (>= N R)]))

(define float-quotient {float --> float --> float}
  X Y -> (fl/ X Y))

(define float-hypot {float --> float --> float}
  X Y -> (flsqrt (fl+ (fl* X X) (fl* Y Y))))

\\ Integers and floats together, through fx->fl.
(define float-mean {(list fixnum) --> fixnum --> float --> float}
  [] N Acc -> (fl/ Acc (fx->fl N))
  [X | Xs] N Acc -> (float-mean Xs (fx+ N 1) (fl+ Acc (fx->fl X))))

\\ Floats read and stored in bytes, with none as a parameter.
(define float-smooth {buffer.storage --> fixnum --> fixnum --> buffer.storage}
  B I End -> B where (fx>= I End)
  B I End -> (do (shen-jit.f64! B I (fl* 0.5 (fl+ (shen-jit.f64 B (fx- I 8)) (shen-jit.f64 B (fx+ I 8)))))
                 (float-smooth B (fx+ I 8) End)))

\\ A call that is not the definition's own, so it stays boxed.
(define float-twice {float --> float}
  X -> (fl+ (float-swap 1 X X) 1.5))

\\ Fixnums in word registers: a loop, bit operations, comparisons, and overflow, which raises.
(define word-sum {fixnum --> fixnum --> fixnum}
  0 Acc -> Acc
  N Acc -> (word-sum (fx- N 1) (fx+ Acc (fx* N N))))

(define word-bits {fixnum --> fixnum --> fixnum}
  A B -> (shen-jit.bit-xor (shen-jit.bit-and A B) (shen-jit.bit-or A 1)))

(define word-max {fixnum --> fixnum --> fixnum}
  A B -> (if (fx>= A B) A B))

(define word-double {fixnum --> fixnum}
  N -> (word-double (fx* N 2)))

\\ Quotients and remainders, bytes read as fixnums, and vectors at fixnum indices.
(define word-div {fixnum --> fixnum --> fixnum}
  A B -> (fx+ (fx* (fxquotient A B) 100) (fxremainder A B)))

(define word-bytes {buffer.storage --> fixnum --> fixnum --> fixnum --> fixnum}
  B I End Acc -> Acc where (fx>= I End)
  B I End Acc -> (word-bytes B (fx+ I 1) End (fx+ Acc (shen-jit.u8 B I))))

(define word-vector {(vector fixnum) --> fixnum --> fixnum --> fixnum}
  V I Acc -> Acc where (fx> I (fxlimit V))
  V I Acc -> (word-vector (fxvector-> V I (fx* I I)) (fx+ I 1) (fx+ Acc (fx<-vector V I))))

\\ A function in registers with lets, larger than a body is inlined at, which a typed loop inlines.
(define float-pair {float --> float --> float}
  X Y -> (let D (fl- X Y)
              S (fl+ X Y)
              P (fl* D S)
              Q (fl/ P (fl+ (fl* X X) 1.5))
           (fl+ P Q)))

(define float-pairs {fixnum --> float --> float}
  0 Acc -> Acc
  N Acc -> (float-pairs (fx- N 1) (fl+ Acc (float-pair (fx->fl N) 0.5))))

\\ A float and integers mixed through number: the integers' own sum is exact, and raises on overflow,
\\ and only the result becomes a float.
(define float-mixed-sum {float --> fixnum --> fixnum --> number}
  X A B -> (+ (fl->number X) (+ (fx->number A) (fx->number B))))

\\ A fixnum stepped by a constant, up and down, each way round, to test overflow at both ends.
(define word-up8 {fixnum --> fixnum} X -> (fx+ X 8))
(define word-down8 {fixnum --> fixnum} X -> (fx- X 8))
(define word-plus-minus8 {fixnum --> fixnum} X -> (fx+ X -8))
(define word-minus-minus8 {fixnum --> fixnum} X -> (fx- X -8))

\\ Within its types, what typed code does otherwise than untyped code (docs/modules.md, Typed programs):
\\ a float in a register is no object, so a NaN never equals itself, and a byte index whose sum is no
\\ fixnum raises as an index past the end.
(define float-same {float --> boolean} X -> (= X X))
(define word-byte-at {buffer.storage --> fixnum --> fixnum --> fixnum} B I J -> (shen-jit.u8 B (fx+ I J)))

\\ Loop counters whose steps go unchecked (src/lowerer/registers.shen, word-op-of): one that a test
\\ found below a fixnum, stepped by a constant, and one read at as a byte index, stepped by any
\\ fixnum. Past the greatest fixnum, the value raises where it leaves the registers, or at the read.
(define word-count-up {fixnum --> fixnum --> symbol}
  I End -> done where (fx>= I End)
  I End -> (word-count-up (fx+ I 8) End))

(define word-count-to {fixnum --> fixnum --> fixnum}
  I End -> I where (fx>= I End)
  I End -> (word-count-to (fx+ I 8) End))

(define word-stride {buffer.storage --> fixnum --> fixnum --> fixnum --> fixnum}
  B P Step Acc -> (word-stride B (fx+ P Step) Step (fx+ Acc (shen-jit.u8 B P))))

\\ A counter below a bound that the loop steps too, which may be past the greatest fixnum: its
\\ step stays checked, or two such sums could pass 64 bits and come back as a fixnum.
(define word-leapfrog {fixnum --> fixnum --> fixnum}
  I J -> (fx- I J) where (fx>= I J)
  I J -> (word-leapfrog J (fx+ I 2305843009213693951)))

\\ A float truncated towards zero in a register (fl->fx), and a pixel's byte from a value in 0 to 1,
\\ as the typed tracer computes it.
(define float-truncated {float --> fixnum}
  X -> (fl->fx X))

(define float-byte {float --> fixnum}
  V -> (let B (fl->fx (fl* V 255.5)) (if (fx> B 255) 255 B)))

\\ A loop whose error's message is made by calls: they only lead to the raise, so the loop keeps
\\ its registers; and a helper that raises so, inlined into a loop that keeps them too.
(define float-checked {fixnum --> fixnum --> float --> float}
  I N Acc -> Acc where (fx>= I N)
  I N Acc -> (if (fx< I 0) (error "negative index ~A" I) (float-checked (fx+ I 1) N (fl+ Acc (fx->fl I)))))

(define float-root {float --> float}
  X -> (if (fl< X (float 0)) (error "no root of ~A" X) (flsqrt X)))

(define float-roots {fixnum --> fixnum --> float --> float}
  I N Acc -> Acc where (fx>= I N)
  I N Acc -> (float-roots (fx+ I 1) N (fl+ Acc (float-root (fx->fl I)))))

\\ A sealed call of no arguments that is not inlined, as one before its definition is not, is an
\\ ordinary call: only the C functions of doubles that lib/ffi.shen marks are called in registers.
(define float-after-later {fixnum --> fixnum} M -> (fx+ M (float-later)))

(define float-later {--> fixnum} -> 28)
