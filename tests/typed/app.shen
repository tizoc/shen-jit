\\ The typed part of a typed program, which tests/cli.sh builds.
(define app-mean {float --> float --> float} X Y -> (fl/ (fl+ X Y) (float 2)))

(define app-steps {fixnum --> fixnum --> fixnum}
  0 Acc -> Acc
  N Acc -> (app-steps (fx- N 1) (fx+ Acc N)))
