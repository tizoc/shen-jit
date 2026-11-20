\\ Loaded by tests/typed.shen, sealed, over an unsealed definition of the same name.
(define typed-replaced-loop {fixnum --> fixnum --> fixnum}
  0 Acc -> Acc
  N Acc -> (typed-replaced-loop (fx- N 1) (fx+ Acc N)))

(define typed-replaced-caller {fixnum --> fixnum}
  N -> (fx+ 1 (typed-replaced-loop N 0)))
