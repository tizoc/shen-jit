\\ A typed client of lib/bignum.shen: loaded under (tc +). Its main is also a closed program's.

\\ Under names of its own, where + and * are the module's.
(shen.x.namespace bignum-typed
  (import bignum t => bignum + * of)
  (export sum-of-squares)

  (define sum-of-squares
    {fixnum --> bignum --> bignum}
    A B -> (+ (* (of A) (of A)) (* B B))))

(define factorial
  {bignum.t --> bignum.t}
  0 -> 1
  N -> (bignum.* N (factorial (bignum.- N 1))))

(define collatz
  {bignum.t --> fixnum --> fixnum}
  1 N -> N
  X N -> (collatz (if (bignum.even? X) (bignum.quotient X 2) (bignum.+ 1 (bignum.* 3 X))) (fx+ N 1)))

(define euclid
  {bignum.t --> bignum.t --> bignum.t}
  A 0 -> A
  A B -> (euclid B (bignum.modulo A B)))

\\ The identity that division keeps, and Bezout's.
(define divides
  {bignum.t --> bignum.t --> boolean}
  A B -> (let P (bignum.quotient-remainder A B)
           (and (= (fst P) (bignum.quotient A B)) (= (bignum.+ (bignum.* (fst P) B) (snd P)) A))))

(define bezout
  {bignum.t --> bignum.t --> boolean}
  A B -> (let G (bignum.gcd-extended A B)
           (= (fst G) (bignum.+ (bignum.* A (fst (snd G))) (bignum.* B (snd (snd G)))))))

(define digits
  {fixnum --> string}
  N -> (bignum.to-string (bignum.expt 10 N)))

(define bignum-typed.main
  {--> symbol}
  -> (do (output "~A ~A ~A ~A ~A ~A ~A ~A~%" (factorial 25) (collatz (bignum.of-string "1000000000000000000000000000") (fixnum 0))
                 (euclid (bignum.expt 6 60) (bignum.expt 10 40)) (divides (bignum.expt 7 80) -12345)
                 (bezout (bignum.expt 7 80) (bignum.expt 3 70)) (digits (fixnum 20))
                 (bignum.to-fixnum (bignum.shift-right (bignum.expt 2 100) 90)) (bignum-typed.sum-of-squares 3 (bignum.expt 10 10)))
         done))
