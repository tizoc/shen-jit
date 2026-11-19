(shen.x.namespace net-seq
  (use shen-jit)

(datatype seq-rules
  X : fixnum;
  ____________________
  (seq-of X) : seq;

  X : seq;
  ____________________
  (seq-number X) : fixnum;)

(define seq-add
  {seq --> fixnum --> seq}
  S N -> (seq-of (shen-jit.bit-and (fx+ (seq-number S) N) 4294967295)))

\\ How far End is past Start, modulo 2^32.
(define seq-distance
  {seq --> seq --> fixnum}
  End Start -> (shen-jit.bit-and (fx- (seq-number End) (seq-number Start)) 4294967295))

\\ Whether A is after B, less than half the space ahead (RFC 9293 3.4).
(define seq-after?
  {seq --> seq --> boolean}
  A B -> (let Delta (seq-distance A B)
           (and (fx> Delta 0) (fx< Delta 2147483648))))
)
