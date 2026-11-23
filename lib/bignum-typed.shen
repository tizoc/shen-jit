(shen.x.namespace bignum
  (shadow - < <= > >= abs even? negate odd?)
  (export > >= abs negate odd? bit-not)

(define >
  {t --> t --> boolean}
  A B -> (< B A))

(define >=
  {t --> t --> boolean}
  A B -> (<= B A))

(define negate
  {t --> t}
  A -> (- 0 A))

(define abs
  {t --> t}
  A -> (if (< A 0) (negate A) A))

(define odd?
  {t --> boolean}
  A -> (not (even? A)))

(define bit-not
  {t --> t}
  A -> (- -1 A))

)
