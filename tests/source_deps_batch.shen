(define sd-test.error?
  Body -> (trap-error (do (thaw Body) false) (/. E true)))
(let Export (source-deps.export (<-address (value sd-test.analysis) 2))
     Queries [[0 0] [1 0]]
     Answer (source-deps.batch-execute Export Queries 0 "")
  (sd-test.check "batch serial root count" (= (length Answer) 2)))
(sd-test.check "empty graph" (= (shen-jit.bytes-length (sdg.build 0 (shen-jit.bytes 0))) 72))
(sd-test.check "invalid graph header" (sd-test.error? (freeze (sdg.check (shen-jit.bytes 72)))))
(sd-test.check "invalid edge ID"
  (sd-test.error? (freeze (sdg.build 0 (shen-jit.bytes 8)))))
(sd-test.check "short request"
  (sd-test.error? (freeze (sdg.execute (sdg.build 0 (shen-jit.bytes 0)) (shen-jit.bytes 1) false))))
(sd-test.check "bounded result assembly"
  (sd-test.error? (freeze
    (sdg.execute (sdg.build 1 (shen-jit.bytes 0))
                 (buffer.owner (sdg.request [[0 0]] 0 1 4)) false))))
(sd-test.check "out of range query"
  (sd-test.error? (freeze (sdg.query (sdg.build 0 (shen-jit.bytes 0)) 0 0 false))))
