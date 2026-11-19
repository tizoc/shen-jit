(define proof-test.keep {(result.t (string * number)) --> (result.t (string * number))}
  X -> X)

(define proof-test.sum {(list (result.t (string * number))) --> (result.t (string * number))}
  [(:result.ok A) (:result.ok B) (:result.ok C) (:result.ok D) (:result.ok E) (:result.ok F) | _]
    -> (proof-test.keep (result.ok (+ A B C D E F)))
  _ -> (result.err "too few readings"))

(define proof-test.rows {proof-test.red --> proof-test.blue --> number}
  R B -> (length (map (/. X (@p X X X X X X X X X X X)) [R B])))

(define proof-test.painted-rows {proof-test.red --> proof-test.raw --> number}
  R B -> (length (map (/. X (@p X X X X X X X X X X X)) [R B])))

\\ The ordinary checker can supply a proof that requires the original context.
(define proof-test.contextual {number --> (result.t (string * number))}
  _ -> (result.ok proof-test.token))

(define proof-test.same {(list (A * A)) --> number} Rows -> (length Rows))
(define proof-test.order {--> number}
  -> (proof-test.same [(@p [] proof-test.unbound-token) (@p [1] [2])]))

(output "struct proof inferences: ~A~%" (inferences))
