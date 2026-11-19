(define typed-replaced-read {typed-replaced --> fixnum}
  P -> (fx+ (typed-replaced.x P) (typed-replaced.y P)))
(define typed-failed-read {spot --> fixnum} P -> (typed-failed P))
