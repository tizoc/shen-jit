(define source-test.write-error
  _ -> (:result.err (io.error write "report fixture" "report write failed")))

(define source-test.writer
  -> (io.writer (io.endpoint "report fixture" write 1
                 (function io.no-read) (function source-test.write-error)
                 (freeze (:result.ok []))) []))

(define source-test.write-failed?
  (:result.err E) -> (and (io.error? E) (= "report write failed" (io.error-message E)))
  _ -> false)

(if (and (source-test.write-failed?
           (source-facts.emit (source-test.writer) (io.record [0 0]) null))
         (source-test.write-failed?
           (source-deps.emit (source-test.writer) (io.record [0 0 0 0 1024 3]) (io.record [0 0]) null)))
    (output "2 passed, 0 failed (report write errors)~%")
    (simple-error "wrong report write error"))
