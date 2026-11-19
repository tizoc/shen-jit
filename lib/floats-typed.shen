(shen.x.namespace floats
  (use shen-jit)
  (shadow get set length)
  (export new length of-list to-list)

(define new
  {fixnum --> t}
  N -> (of-bytes (shen-jit.bytes (fx* N 8))))

(define length
  {t --> fixnum}
  V -> (fxquotient (shen-jit.bytes-length (bytes V)) 8))

(define of-list
  {(list float) --> t}
  Xs -> (fill (new (count Xs 0)) 0 Xs))

(define to-list
  {t --> (list float)}
  V -> (from V (fx- (length V) 1) []))

(define count
  {(list float) --> fixnum --> fixnum}
  [] N -> N
  [_ | Xs] N -> (count Xs (fx+ N 1)))

(define fill
  {t --> fixnum --> (list float) --> t}
  V _ [] -> V
  V I [X | Xs] -> (fill (set V I X) (fx+ I 1) Xs))

(define from
  {t --> fixnum --> (list float) --> (list float)}
  _ -1 Xs -> Xs
  V I Xs -> (from V (fx- I 1) [(get V I) | Xs]))

)
