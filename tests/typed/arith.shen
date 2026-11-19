\\ Typed definitions over fixnums and floats, module arith, which requires numbers for their types.
(define typed-sq {float --> float} X -> (fl* X X))

\\ A literal bound by let infers as number, so a fixnum binding says so, at no cost.
(define typed-step {boolean --> fixnum --> fixnum}
  Up N -> (let Step (if Up (fixnum 1) (fixnum -1)) (fx+ N Step)))

(define typed-orbit {float --> float --> fixnum --> fixnum}
  _ _ 0 -> 0
  X C N -> (if (fl> (typed-sq X) 4.5) N (typed-orbit (fl+ (typed-sq X) C) C (fx- N 1))))

(define typed-mean {float --> float --> float} X Y -> (fl/ (fl+ X Y) (float 2)))

(define typed-steps {fixnum --> fixnum --> fixnum}
  0 Acc -> Acc
  N Acc -> (typed-steps (fx- N 1) (fx+ Acc N)))

(define typed-widen {fixnum --> float --> number} N X -> (+ (fx->number N) (fl->number X)))

(define typed-bound-literals {--> (number * (fixnum * float))}
  -> (let N 1
          Word (fixnum 1)
          Double (float 1.5)
       (@p (+ N 2) (fx+ Word 2) (fl+ Double 2.5))))

(define typed-fx-zero? {fixnum --> boolean}
  N -> (and ((fx= 0) N) (fx= N 0)))

(define typed-fx-zero-prefix {(list fixnum) --> (list fixnum)}
  Acc -> (let L (cons (fixnum 0) Acc)
           (if (element? (fixnum 0) L) L Acc)))
