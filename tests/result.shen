\\ Results and their chains, untyped: tests/result_typed.shen has the typed clients.
(set result-test.passed 0)
(set result-test.failed 0)

(define result-test.check
  Name Expected Actual
  -> (if (= Expected Actual)
         (set result-test.passed (+ 1 (value result-test.passed)))
         (do (set result-test.failed (+ 1 (value result-test.failed)))
             (output "FAIL ~A: wanted ~S, got ~S~%" Name Expected Actual))))

(define result-test.mark
  X -> (do (set result-test.order [X | (value result-test.order)]) X))

(define result-test.payload
  (:result.ok X) -> X
  (:result.err X) -> X)

(result-test.check "bind gives the value" (:result.ok 2) (result.bind (:result.ok 1) (/. X (:result.ok (+ X 1)))))
(result-test.check "bind passes an error on" (:result.err e) (result.bind (:result.err e) (/. X (:result.ok X))))
(result-test.check "bind rejects values outside the result type" "result.bind: expected a result"
  (trap-error (result.bind [other 7] (/. X (:result.ok X))) (/. E (error-to-string E))))
(result-test.check "bind preserves the error payload" true
  (let Failure (:result.err (@p e 4))
    (shen-jit.same? (result-test.payload Failure)
                    (result-test.payload (result.let-ok _ Failure (error "unexpected continuation"))))))
(result-test.check "a list headed by ok is ordinary data" false (result.ok? [ok 1]))
(result-test.check "let-ok binds in order" (:result.ok 3)
  (result.let-ok A (:result.ok 1) B (:result.ok (+ A 1)) (:result.ok (+ A B))))
(result-test.check "_ ignores empty and nonempty payloads" (:result.ok done)
  (result.let-ok _ (:result.ok []) _ (:result.ok 5) (:result.ok done)))
(result-test.check "the first result that is not ok, as it is" (:result.err (@p e 4))
  (result.let-ok A (:result.ok 1) B (:result.err (@p e 4)) C (:result.ok 3) (:result.ok [A B C])))
(result-test.check "a step after one that is not ok does not run" [(:result.err x) [a x]]
  (let _ (set result-test.order [])
       R (result.let-ok _ (result-test.mark (:result.ok a)) _ (result-test.mark (:result.err x))
                        _ (result-test.mark (:result.ok b)) (:result.ok c))
    [R (map (fn result-test.payload) (reverse (value result-test.order)))]))
(result-test.check "no pairs is the body" (:result.ok 1) (result.let-ok (:result.ok 1)))
(result-test.check "a binding with no body" "let-ok: no body after binding X"
  (trap-error (eval [result.let-ok X (:result.ok 1)]) (/. E (error-to-string E))))

(output "~A passed, ~A failed~%" (value result-test.passed) (value result-test.failed))
