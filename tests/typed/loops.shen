\\ Loops inlined into the loops that call them, which tests/typed.shen loads sealed under
\\ (optimise +), runs, and compares with what the same arithmetic gives boxed.

\\ An inner loop giving a float, two of them deep, from a constant and an index computed outside.
(define loop-dot {buffer.storage --> fixnum --> fixnum --> float --> float}
  B I End Acc -> Acc where (fx>= I End)
  B I End Acc -> (loop-dot B (fx+ I 8) End (fl+ Acc (fl* (shen-jit.f64 B I) (shen-jit.f64 B I)))))

(define loop-rows {buffer.storage --> fixnum --> fixnum --> fixnum --> float --> float}
  B Row Rows Width Acc -> Acc where (fx>= Row Rows)
  B Row Rows Width Acc -> (loop-rows B (fx+ Row 1) Rows Width
                                     (fl+ Acc (loop-dot B (fx* Row Width) (fx* (fx+ Row 1) Width) (float 0)))))

(define loop-sheets {buffer.storage --> fixnum --> fixnum --> float --> float}
  B K Width Acc -> Acc where (fx>= K 3)
  B K Width Acc -> (loop-sheets B (fx+ K 1) Width (fl+ Acc (loop-rows B 0 2 Width (fx->fl K)))))

\\ An inner loop giving a fixnum, with a parameter named as the outer one's, from a loop with a let
\\ of its own parameter, which the loop must read before it changes the parameter.
(define loop-count {fixnum --> fixnum --> fixnum --> fixnum}
  N Limit Acc -> Acc where (fx>= N Limit)
  N Limit Acc -> (loop-count (fx+ N 1) Limit (fx+ Acc 1)))

(define loop-triangle {fixnum --> fixnum --> fixnum}
  0 Acc -> Acc
  N Acc -> (let M N (loop-triangle (fx- N 1) (fx+ Acc (loop-count 0 M 0)))))

\\ An inner loop for its effect.
(define loop-fill {buffer.storage --> fixnum --> fixnum --> float --> buffer.storage}
  B I End X -> B where (fx>= I End)
  B I End X -> (do (shen-jit.f64! B I X) (loop-fill B (fx+ I 8) End X)))

(define loop-fills {buffer.storage --> fixnum --> fixnum --> fixnum --> symbol}
  B Row Rows Width -> done where (fx>= Row Rows)
  B Row Rows Width -> (do (loop-fill B (fx* Row Width) (fx* (fx+ Row 1) Width) (fx->fl Row))
                          (loop-fills B (fx+ Row 1) Rows Width)))

\\ An inner loop in tail position, whose exits return.
(define loop-tail {fixnum --> fixnum --> fixnum}
  N Limit -> (loop-count N Limit 0) where (fx>= Limit 0)
  _ _ -> 0)

\\ An inner loop giving a Boolean, which a test reads.
(define loop-has? {buffer.storage --> fixnum --> fixnum --> fixnum --> boolean}
  B I End V -> false where (fx>= I End)
  B I End V -> true where (= (shen-jit.u8 B I) V)
  B I End V -> (loop-has? B (fx+ I 1) End V))

(define loop-found {buffer.storage --> fixnum --> fixnum --> fixnum}
  B V Acc -> Acc where (fx>= V 8)
  B V Acc -> (loop-found B (fx+ V 1) (if (loop-has? B 0 (shen-jit.bytes-length B) V) (fx+ Acc 1) Acc)))

\\ An inner loop over a list, whose parameter is no register.
(define loop-mean {(list fixnum) --> fixnum --> float --> float}
  [] N Acc -> (fl/ Acc (fx->fl N))
  [X | Xs] N Acc -> (loop-mean Xs (fx+ N 1) (fl+ Acc (fx->fl X))))

(define loop-means {(list fixnum) --> fixnum --> float --> float}
  _ 0 Acc -> Acc
  L K Acc -> (loop-means L (fx- K 1) (fl+ Acc (loop-mean L 0 (float 0)))))

\\ A caller that calls another function keeps no registers, and calls the loop.
(define loop-calls {fixnum --> fixnum}
  N -> (do (length [N]) (loop-count 0 N 0)))

\\ One more than a fixnum known below another needs no check; one more than any other does.
(define loop-up {fixnum --> fixnum --> fixnum}
  N N -> N
  N Limit -> (loop-up (fx+ N 1) Limit))

\\ Shifts by constants, in registers, as the primitives give them: a shift left drops what leaves the
\\ 62 bits of a fixnum, and a shift right keeps the sign.
(define loop-shifts {fixnum --> fixnum --> (list fixnum)}
  X Y -> [(shen-jit.shift-left X 3) (shen-jit.shift-right Y 2) (shen-jit.shift-left X 61)
          (shen-jit.shift-right Y 63) (shen-jit.bit-xor (shen-jit.shift-left X 20) (shen-jit.shift-right Y 1))])

\\ A body with more lets than a loop has word registers for, twice in one value: their registers go
\\ back once each value is computed.
(define loop-mix {fixnum --> fixnum}
  X -> (let A (fx+ X 1) B (fx+ A 2) C (fx+ B 3) D (fx+ C 4) E (fx+ D 5) F (fx+ E 6) G (fx+ F 7) H (fx+ G 8)
         (fx+ (fx+ (fx+ A B) (fx+ C D)) (fx+ (fx+ E F) (fx+ G H)))))

(define loop-mixes {fixnum --> fixnum --> fixnum}
  0 Acc -> Acc
  N Acc -> (loop-mixes (fx- N 1) (fx+ Acc (fx+ (loop-mix N) (loop-mix (fx+ N 1))))))

\\ Products computed again from the same values, through the lets of inlined reads, and in a branch and
\\ after it; an overflow raises after the effect before it.
(define loop-get {buffer.storage --> fixnum --> fixnum --> float}
  B I F -> (shen-jit.f64 B (fx+ (fx* I 24) (fx* F 8))))

(define loop-row {buffer.storage --> fixnum --> float}
  B I -> (fl+ (loop-get B I 0) (fl+ (loop-get B I 1) (loop-get B I 2))))

(define loop-branchy {fixnum --> boolean --> fixnum}
  I B -> (fx+ (if B (fx* I 3) 0) (fx* I 3)))

(define loop-raise {buffer.storage --> fixnum --> fixnum}
  B I -> (do (shen-jit.u8! B 0 7) (fx+ (fx* I 4) (fx* I 4))))

\\ Arguments that cannot raise or write wait until nothing reads their registers (src/lowerer/registers.shen,
\\ in-order): a dot product's indices, read by its sum, step in place. Arguments that read each other's
\\ registers in a cycle are moved through one; one with an effect still sees the counter as it was.
(define loop-strided {buffer.storage --> fixnum --> buffer.storage --> fixnum --> fixnum --> fixnum --> float --> float}
  A AI B BI End Step Acc -> Acc where (fx>= AI End)
  A AI B BI End Step Acc -> (loop-strided A (fx+ AI 8) B (fx+ BI Step) End Step
                                       (fl+ Acc (fl* (shen-jit.f64 A AI) (shen-jit.f64 B BI)))))

(define loop-swap {fixnum --> fixnum --> fixnum --> fixnum}
  0 X Y -> (fx- X Y)
  N X Y -> (loop-swap (fx- N 1) Y X))

(define loop-fib {fixnum --> float --> float --> float}
  0 X _ -> X
  N X Y -> (loop-fib (fx- N 1) Y (fl+ X Y)))

(define loop-marks {buffer.storage --> fixnum --> fixnum --> fixnum}
  _ I N -> I where (fx>= I N)
  B I N -> (loop-marks B (fx+ I 1) (do (shen-jit.u8! B I (fx+ I 10)) N)))

\\ A loop's exit tested on floats, which a NaN does not take.
(define loop-nan {float --> fixnum --> fixnum}
  X N -> N where (fl< X (float 1))
  _ 0 -> 0
  X N -> (loop-nan X (fx- N 1)))

\\ A flag a loop passes on as it is, given true or false where the loop is inlined, is that constant
\\ there (src/lowerer/registers.shen, inline-loop), so the loop tests nothing for it; one the loop
\\ changes stays a parameter.
(define loop-flagged {fixnum --> boolean --> fixnum --> fixnum}
  0 _ Acc -> Acc
  N Up Acc -> (loop-flagged (fx- N 1) Up (if Up (fx+ Acc 1) (fx- Acc 1))))

(define loop-flags {fixnum --> fixnum}
  N -> (fx- (loop-flagged N true 0) (loop-flagged N false 0)))

(define loop-toggled {fixnum --> boolean --> fixnum --> fixnum}
  0 _ Acc -> Acc
  N Up Acc -> (loop-toggled (fx- N 1) (not Up) (if Up (fx+ Acc 2) (fx- Acc 1))))

(define loop-toggles {fixnum --> fixnum}
  N -> (loop-toggled N true 0))

\\ A double at a fixnum times 8, as floats.get reads it, is read and written at that fixnum as an index of
\\ doubles (src/lowerer/registers.shen, scaled-index?): in a loop, whose buffer's length in doubles is
\\ worked out once, and in a definition that is no loop.
(define loop-scaled-sum {buffer.storage --> fixnum --> fixnum --> float --> float}
  B I N Acc -> Acc where (fx>= I N)
  B I N Acc -> (loop-scaled-sum B (fx+ I 1) N (fl+ Acc (shen-jit.f64 B (fx* I 8)))))

(define scaled-get {buffer.storage --> fixnum --> float}
  B I -> (shen-jit.f64 B (fx* I 8)))

(define scaled-set {buffer.storage --> fixnum --> float --> buffer.storage}
  B I X -> (do (shen-jit.f64! B (fx* 8 I) X) B))

\\ Fixnums stored into bytes from registers (fix-store8 and the others, word-store64), checked to fit
\\ as the primitives check them, for their effect and for their value, the bytes.
(define store-each {buffer.storage --> fixnum --> fixnum --> buffer.storage}
  B X Y -> (do (shen-jit.u8! B 0 X) (shen-jit.u16! B 2 X) (shen-jit.u32! B 4 Y) (shen-jit.s32! B 8 Y)
               (shen-jit.s64! B 16 Y) B))

(define store-nested {buffer.storage --> fixnum --> fixnum --> buffer.storage}
  B X Y -> (shen-jit.u32! (shen-jit.u32! B 0 X) 4 Y))

(define store-wide {buffer.storage --> fixnum --> fixnum --> buffer.storage}
  B X Y -> (do (shen-jit.s32! B 8 X) (shen-jit.s64! B 16 Y) B))

\\ A loop inlined where its result goes on to code after it, here (fx+ 1000 ...), is in no tail position
\\ of the loops around it, so its call of the definition around it is a call, not a jump back
\\ (src/lowerer/registers.shen, alone).
(define loop-inner {fixnum --> fixnum --> fixnum}
  I N -> (if (fx< I N) (loop-inner (fx+ I 1) N) (loop-outer I)))

(define loop-outer {fixnum --> fixnum}
  X -> (if (fx> X 100) X (fx+ 1000 (loop-inner X (fx+ X 3)))))

\\ A bound that is a sum, bound by the lets that inlining fx+ leaves, is no exact bound where the sum may
\\ be past the greatest fixnum (exact-in?, alias-of): the steps under it are checked, and one past the
\\ greatest fixnum raises.
(define loop-aliased {fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum}
  I J Q R N -> R where (and (fx< R 0) (fx> R -10))
  I J Q R N -> (if (fx< I N)
                  (let E1 (fx+ I 2305843009213693951)
                    (if (fx< J E1)
                        (let E2 (fx+ J 2305843009213693951)
                          (if (fx< Q E2)
                              (let E3 (fx+ Q 2305843009213693951)
                                (if (fx< R E3)
                                    (loop-aliased I J Q (fx+ R 2305843009213693951) N)
                                    (loop-aliased I J (fx+ Q 2305843009213693951) R N)))
                              (loop-aliased I (fx+ J 2305843009213693951) Q R N)))
                        0))
                  0))
