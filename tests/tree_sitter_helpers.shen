(set ts-test.passed 0)
(set ts-test.failed 0)

(define ts-test.check
  Name true -> (set ts-test.passed (+ (value ts-test.passed) 1))
  Name false -> (do (output "FAIL ~A~%" Name) (set ts-test.failed (+ (value ts-test.failed) 1))))

(define ts-test.raises?
  F -> (trap-error (do (thaw F) false) (/. X true)))

(define ts-test.error-domain
  [error E] -> (treesitter.error-domain E)
  _ -> unexpected-success)

(define ts-test.ok
  [ok X] -> X
  Other -> (error "treesitter test: ~S" Other))
