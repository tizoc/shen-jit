\\ A chain gives the type its body gives, not the type of the results it reads.
(define result-refused.chain
  {number --> (result.t (string * string))}
  N -> (result.let-ok X (if (> N 0) (:result.ok N) (:result.err "no")) (:result.ok X)))
\\ next
\\ A result's error is of the type it says.
(define result-refused.error
  {(result.t (string * number)) --> number}
  (:result.err E) -> E
  (:result.ok N) -> N)
\\ next
\\ The compiler must reject the caller before a lambda reaches a result consumer.
(define result-refused.payload
  {(result.t (E * A)) --> A}
  (:result.ok X) -> X
  (:result.err _) -> (error "expected ok"))

(define result-refused.lambda
  {--> number}
  -> (result-refused.payload (/. Ignored 42)))
\\ next
(define result-refused.wrong-member
  {(result.err number) --> (result.t (string * number))}
  X -> X)
