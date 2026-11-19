\\ Module unrequired uses fixnum without requiring numbers, whose rules it then does not see.
(define typed-twice {fixnum --> fixnum} N -> (+ N N))
