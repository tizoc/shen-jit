\* The entry, which reads and writes through b. *\
(define main
  -> (do (run (read-number)) (helper 1)))

(define run
  N -> (if (> N 0) (b.step N) (b.stop)))

(define helper
  X -> [X | (helper (- X 1))])

(define unused
  -> (external-call 1))
