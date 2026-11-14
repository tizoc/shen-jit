(define sd-test.error?
  Body -> (trap-error (do (thaw Body) false) (/. E true)))
(let Export (source-deps.export (<-address (value sd-test.analysis) 2))
     Queries [[0 0] [1 0]]
     Answer (source-deps.batch-execute Export Queries 0)
  (do (sd-test.check "batch serial root count" (= (length Answer) 2))
      (sd-test.check "batch in isolates, in order" (= (source-deps.batch-execute Export Queries 3) Answer))))
(sd-test.check "empty graph" (= (shen-jit.bytes-length (sdg.build 0 (shen-jit.bytes 0))) 72))
(sd-test.check "invalid edge ID"
  (sd-test.error? (freeze (sdg.build 0 (shen-jit.bytes 8)))))
(sd-test.check "out of range query"
  (sd-test.error? (freeze (sdg.query (sdg.build 0 (shen-jit.bytes 0)) 0 0))))
