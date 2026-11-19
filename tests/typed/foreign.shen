\\ Typed calls of C functions of doubles, which keep their floats in registers.
(define foreign-sum {fixnum --> float --> float}
  0 Acc -> Acc
  N Acc -> (foreign-sum (fx- N 1) (fl+ Acc (float (foreign-cos (fl->number (fx->fl N)))))))

(define foreign-power {float --> float --> float}
  X Y -> (fl* (float (foreign-pow (fl->number X) (fl->number Y))) 2.5))

\\ Memory as typed code sees it, with the types numbers and memory give, and no declarations here.
(define foreign-memory {fixnum --> float}
  N -> (let B (memory.alloc (fx* N 8))
            S (shen-jit.f64! B (fx* (fx- N 1) 8) 2.5)
         (fl+ (shen-jit.f64 S (fx* (fx- N 1) 8)) (shen-jit.f64 B 0))))

\\ Integer arithmetic as a C function's argument is done as + and * do it, then made a double.
(define foreign-sum-of {number --> number --> float}
  P Q -> (float (foreign-pow (+ P Q) 1)))

(define foreign-product-of {number --> number --> float}
  P Q -> (float (foreign-pow (* P Q) 1)))

\\ A C function of no arguments, which is not one of doubles, is called as any other.
(define foreign-rounding-plus {number --> number} N -> (+ N (foreign-rounding)))
