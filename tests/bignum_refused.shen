\\ A bignum is no number, and a number no bignum, whatever it holds.
(define bignum-refused.add {bignum.t --> bignum.t} X -> (+ X 1))
\\ next
(define bignum-refused.number {number --> bignum.t} X -> X)
\\ next
(define bignum-refused.fixnum {bignum.t --> fixnum} X -> X)
\\ next
(define bignum-refused.of {number --> bignum.t} X -> (bignum.of X))
\\ next
(define bignum-refused.float {bignum.t --> bignum.t} X -> (bignum.* X 1.5))
\\ next
(define bignum-refused.count {bignum.t --> bignum.t} X -> (bignum.expt 2 X))
\\ next
(define bignum-refused.pair {bignum.t --> bignum.t} X -> (bignum.quotient-remainder X 2))
