\\ Functions that call each other, and callers of them with constants: the lowerer inlines each a
\\ bounded number of times (src/lowerer/inline.shen, inline-at).

\\ The first's tail call is of a function not defined yet, and the second's own code is a loop,
\\ through the first inlined.
(define mutual-up
  {fixnum --> fixnum --> fixnum}
  I N -> I where (fx>= I N)
  I N -> (let J (fx+ I 1) (mutual-up-checked J N)))

(define mutual-up-checked
  {fixnum --> fixnum --> fixnum}
  I N -> (mutual-up I N) where (fx<= 0 I)
  I N -> (simple-error "negative"))

(define mutual-up-main
  {--> fixnum}
  -> (mutual-up 0 1))

\\ Neither a small body.
(define mutual-left
  {fixnum --> fixnum --> fixnum}
  I N -> I where (fx>= I N)
  I N -> (let J (fx+ I 1) (mutual-right J N)))

(define mutual-right
  {fixnum --> fixnum --> fixnum}
  I N -> (mutual-left (fx+ (fx- I 1) 2) N) where (fx<= 0 (fx+ I 1))
  I N -> (fx- 0 I))

(define mutual-left-main
  {--> fixnum}
  -> (mutual-left 0 10))

\\ Three, each going on to the other two.
(define mutual-a
  {fixnum --> fixnum --> fixnum}
  I N -> I where (fx>= I N)
  I N -> (mutual-b (fx+ I 1) N) where (fx= (fx- I 4) 0)
  I N -> (mutual-c (fx+ I 2) N))

(define mutual-b
  {fixnum --> fixnum --> fixnum}
  I N -> I where (fx>= I N)
  I N -> (mutual-c (fx+ I 1) N) where (fx= (fx- I 5) 0)
  I N -> (mutual-a (fx+ I 2) N))

(define mutual-c
  {fixnum --> fixnum --> fixnum}
  I N -> I where (fx>= I N)
  I N -> (mutual-a (fx+ I 2) N) where (fx= (fx- I 2) 0)
  I N -> (mutual-b (fx+ I 3) N))

(define mutual-a-main
  {--> fixnum}
  -> (mutual-a 0 10))

\\ Bodies of primitives and each other alone, which end in an error.
(define mutual-add
  {fixnum --> fixnum}
  I -> (mutual-double (fx+ I 1)))

(define mutual-double
  {fixnum --> fixnum}
  I -> (mutual-add (fx* I 2)))

(define mutual-add-main
  {--> fixnum}
  -> (mutual-add 1))
