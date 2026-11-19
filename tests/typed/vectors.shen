\\ Typed code over floats (lib/floats.shen), its names imported: a double read and written at an
\\ index of doubles, in registers (float-load-index, float-store-index).
(shen.x.namespace vectors
  (import floats t => floats get set length)

  (define dot {floats --> floats --> fixnum --> fixnum --> float --> float}
    A B I N Acc -> Acc where (fx>= I N)
    A B I N Acc -> (dot A B (fx+ I 1) N (fl+ Acc (fl* (get A I) (get B I)))))

  (define scale {floats --> float --> fixnum --> floats}
    V K I -> V where (fx>= I (length V))
    V K I -> (scale (set V I (fl* K (get V I))) K (fx+ I 1))))
