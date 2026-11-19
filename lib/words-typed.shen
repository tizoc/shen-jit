(shen.x.namespace words
  (use shen-jit)
  (shadow get set length)
  (externals [buffer.storage word.t])
  (export new length of-list to-list)

(define new
  {fixnum --> t}
  N -> (of-bytes (shen-jit.bytes (fx* N 8))))

(define length
  {t --> fixnum}
  V -> (fxquotient (shen-jit.bytes-length (bytes V)) 8))

(define of-list
  {(list word.t) --> t}
  Ws -> (fill (new (count Ws 0)) 0 Ws))

(define to-list
  {t --> (list word.t)}
  V -> (from V (fx- (length V) 1) []))

(define count
  {(list word.t) --> fixnum --> fixnum}
  [] N -> N
  [_ | Ws] N -> (count Ws (fx+ N 1)))

(define fill
  {t --> fixnum --> (list word.t) --> t}
  V _ [] -> V
  V I [W | Ws] -> (fill (set V I W) (fx+ I 1) Ws))

(define from
  {t --> fixnum --> (list word.t) --> (list word.t)}
  _ -1 Ws -> Ws
  V I Ws -> (from V (fx- I 1) [(get V I) | Ws]))

)
