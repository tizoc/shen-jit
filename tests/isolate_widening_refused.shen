\\ Without an expected endpoint type, length alone cannot pick a common type for this list.
(define widening.unconstrained
  {(receiver number) --> (sender number) --> number}
  R S -> (length [R S]))
