(shen.x.namespace word
  (shadow < <= > >=)
  (export bit-not > >= u> u>=)

(define bit-not
  {t --> t}
  A -> (bit-xor A (of -1)))

(define >
  {t --> t --> boolean}
  A B -> (< B A))

(define >=
  {t --> t --> boolean}
  A B -> (<= B A))

(define u>
  {t --> t --> boolean}
  A B -> (u< B A))

(define u>=
  {t --> t --> boolean}
  A B -> (u<= B A))

)
