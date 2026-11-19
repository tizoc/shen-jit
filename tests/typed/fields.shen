\\ A typed struct and typed definitions over it, which tests/typed.shen loads sealed under
\\ (optimise +): their reads of its fields have no check.
(defstruct spot (x : fixnum) (mutable y : fixnum))

(define spot-sum {spot --> fixnum} P -> (fx+ (spot.x P) (spot.y P)))

(define spot-twice {spot --> fixnum} P -> (fx+ (spot-sum P) (spot-sum P)))

(define spot-bump {spot --> spot} P -> (spot.y-> P (fx+ (spot.y P) 1)))

\\ Fixnum and float fields read into registers, and an error whose message formats values in
\\ registers, which are boxed before the calls that make it.
(defstruct dot (x : float) (y : float))

(define dot-norm2 {dot --> float} D -> (fl+ (fl* (dot.x D) (dot.x D)) (fl* (dot.y D) (dot.y D))))

(define spot-next {spot --> fixnum}
  P -> (if (fx< (spot.x P) (spot.y P))
           (fx+ (spot.x P) 1)
           (error "~A is not below ~A" (spot.x P) (spot.y P))))
