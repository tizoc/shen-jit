\\ Deterministic budgets with a managed, injectable clock; this also runs on static builds.
(set deadline-test.passed 0)
(set deadline-test.failed 0)

(define deadline-test.check
  Name Expected F ->
    (let Got (trap-error (thaw F) (/. X [raised (error-to-string X)]))
      (if (= Expected Got)
          (set deadline-test.passed (+ 1 (value deadline-test.passed)))
          (do (output "FAIL ~A: expected ~S, got ~S~%" Name Expected Got)
              (set deadline-test.failed (+ 1 (value deadline-test.failed)))))))

(define deadline-test.raises
  Name F -> (deadline-test.check Name true (freeze (trap-error (do (thaw F) false) (/. X true)))))

(let Time (io.record [100])
     D (deadline.after (freeze (<-address Time 0)) 250)
  (do (deadline-test.check "initial remaining time" 250 (freeze (deadline.remaining D)))
      (deadline-test.check "bounded poll slice" 100 (freeze (deadline.slice D 100)))
      (address-> Time 0 300)
      (deadline-test.check "time is charged to the original deadline" 50 (freeze (deadline.remaining D)))
      (deadline-test.check "last poll slice" 50 (freeze (deadline.slice D 100)))
      (address-> Time 0 350)
      (deadline-test.check "expiry includes the boundary" true (freeze (deadline.expired? D)))
      (address-> Time 0 400)
      (deadline-test.check "expired budget stays zero" 0 (freeze (deadline.remaining D)))
      (address-> Time 0 399)
      (deadline-test.raises "non-monotonic clock" (freeze (deadline.remaining D)))
      (deadline-test.raises "zero slice" (freeze (deadline.slice D 0)))
      (deadline-test.raises "real slice" (freeze (deadline.slice D (+ 0.5 0.5))))))

(deadline-test.check "zero duration is immediately expired" true
  (freeze (deadline.expired? (deadline.after (freeze 10) 0))))
(deadline-test.raises "negative duration" (freeze (deadline.after (freeze 10) -1)))
(deadline-test.raises "real duration" (freeze (deadline.after (freeze 10) (+ 0.5 0.5))))
(deadline-test.raises "negative clock" (freeze (deadline.after (freeze -1) 10)))
(deadline-test.raises "real clock" (freeze (deadline.after (freeze (+ 0.5 0.5)) 10)))
(deadline-test.raises "duration overflow" (freeze (deadline.after (freeze 2305843009213693951) 1)))
(deadline-test.raises "not a budget" (freeze (deadline.remaining [])))
(let D (deadline.after (freeze 10) 20)
     _ (shen-jit.pointer-kill (deadline.budget.guard D))
  (deadline-test.raises "saved/stale deadline" (freeze (deadline.remaining D))))

(let Time (io.record [100])
     Parent (deadline.after (freeze (<-address Time 0)) 200)
     _ (address-> Time 0 250)
     Short (deadline.within Parent 20)
     Long (deadline.within Parent 100)
  (do (deadline-test.check "short phase" 20 (freeze (deadline.remaining Short)))
      (deadline-test.check "phase capped by parent" 50 (freeze (deadline.remaining Long)))
      (address-> Time 0 310)
      (deadline-test.check "expired parent cannot be renewed" 0
        (freeze (deadline.remaining (deadline.within Parent 100))))))

(output "~A passed, ~A failed~%" (value deadline-test.passed) (value deadline-test.failed))
