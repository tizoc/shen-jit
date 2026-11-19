\\ A typed loop over a view, which tests/buffer_registers.shen loads under (tc +).
(define buffer-loop.sum {buffer.view --> fixnum --> fixnum --> fixnum --> fixnum}
  V I N Acc -> (if (fx>= I N) Acc (buffer-loop.sum V (fx+ I 1) N (fx+ Acc (buffer.u8 V I)))))
