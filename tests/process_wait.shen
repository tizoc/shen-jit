(define process-test.join
  Done 0 -> (error "process worker did not complete")
  Done N ->
    (if (= (<-address Done 0) [])
        (do (process.c-pause [] 10) (process-test.join Done (- N 1)))
        true))
