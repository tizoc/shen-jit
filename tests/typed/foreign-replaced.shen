(define foreign-replaced {number --> number} X -> (trap-error (+ X 10) (/. E 0)))
(define foreign-replaced-call {float --> float} X -> (float (foreign-replaced (fl->number X))))
