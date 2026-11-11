\\ Loaded with lib/native.shen; worker-test.image names the compatible fixture image.
(set worker-test.passed 0)

(define worker-test.check
  Label Expected F -> (let Got (thaw F)
                         (if (= Expected Got)
                             (set worker-test.passed (+ 1 (value worker-test.passed)))
                             (error "FAIL ~A: expected ~S, got ~S" Label Expected Got))))

(define worker-test.request
  Op -> (shen-jit.u8! (shen-jit.bytes 1) 0 Op))

(define worker-test.scope
  N Shared F -> (shen-jit.worker-scope (value worker-test.image) worker-fixture.entry N
                  [1048576 33554432 Shared] F))

(define worker-test.repeat
  0 _ _ -> true
  N Token Requests -> (let Replies (shen-jit.worker-batch Token Requests)
                           _ (if (= Replies Requests) true (error "copied messages differ"))
                           _ (shen-jit.collect)
                           _ (if (= Replies Requests) true (error "host GC lost copied replies"))
                        (worker-test.repeat (- N 1) Token Requests)))

(worker-test.check "no workers initially" 0 (freeze (shen-jit.worker-live)))
(worker-test.check "parallel compilation, GC, equality and copied replies" true
  (freeze (worker-test.scope 4 (shen-jit.bytes 0)
    (/. Token (worker-test.repeat 3 Token (map (function worker-test.request) [1 1 1 1]))))))
(worker-test.check "joined normal scope" 0 (freeze (shen-jit.worker-live)))

(map (/. N
       (worker-test.check "raw worker count rejected before initialization"
         "worker: expected 0..64 workers and a scope body"
         (freeze (trap-error (worker-test.scope N (shen-jit.bytes 0) (/. Token true))
                             (/. E (error-to-string E))))))
     [-1 65 3.5 true [] "3"])
(worker-test.check "invalid counts did not start workers" 0 (freeze (shen-jit.worker-live)))

(let Token (worker-test.scope 1 (shen-jit.bytes 0) (/. Token Token))
  (worker-test.check "escaped token is invalid" rejected
    (freeze (trap-error (shen-jit.worker-batch Token [(shen-jit.bytes 0)]) (/. E rejected)))))

(map (/. Op
       (do (worker-test.check "worker host-operation/error/slice boundary" rejected
              (freeze (trap-error
                (worker-test.scope 4 (shen-jit.bytes 0)
                  (/. Token (shen-jit.worker-batch Token (map (/. I (worker-test.request Op)) [0 1 2 3]))))
                (/. E rejected))))
           (worker-test.check "joined failed scope" 0 (freeze (shen-jit.worker-live)))))
     [2 3 4 5 6 7 9 10 11 12 13 15 16 17 18 19])

(worker-test.check "empty replies" [0 0]
  (freeze (worker-test.scope 2 (shen-jit.bytes 0)
    (/. Token (map (function shen-jit.bytes-length)
                    (shen-jit.worker-batch Token (map (function worker-test.request) [14 14])))))))

(worker-test.check "bad request count rejected before dispatch" rejected
  (freeze (worker-test.scope 2 (shen-jit.bytes 0)
    (/. Token (trap-error (shen-jit.worker-batch Token [(shen-jit.bytes 0)]) (/. E rejected))))))
(worker-test.check "oversized request rejected" rejected
  (freeze (worker-test.scope 1 (shen-jit.bytes 0)
    (/. Token (trap-error (shen-jit.worker-batch Token [(shen-jit.bytes 1048577)]) (/. E rejected))))))
(worker-test.check "child failure remains sticky if caught by parent" rejected
  (freeze (trap-error (worker-test.scope 1 (shen-jit.bytes 0)
    (/. Token (trap-error (shen-jit.worker-batch Token [(worker-test.request 6)]) (/. E swallowed))))
    (/. E rejected))))

(worker-test.check "parent failure" rejected
  (freeze (trap-error (worker-test.scope 4 (shen-jit.bytes 0) (/. Token (error "parent failed")))
                      (/. E rejected))))
(worker-test.check "joined parent failure" 0 (freeze (shen-jit.worker-live)))

(worker-test.check "forged scope token" rejected
  (freeze (worker-test.scope 1 (shen-jit.bytes 0)
    (/. Token (trap-error (shen-jit.worker-batch (absvector 0) [(shen-jit.bytes 0)]) (/. E rejected))))))
(worker-test.check "nested scope" rejected
  (freeze (worker-test.scope 1 (shen-jit.bytes 0)
    (/. Token (trap-error (worker-test.scope 1 (shen-jit.bytes 0) (/. Other true)) (/. E rejected))))))

(worker-test.check "bad image initialization" rejected
  (freeze (trap-error
    (shen-jit.worker-scope "build/no-such-worker-image" worker-fixture.entry 4
      [1048576 33554432 (shen-jit.bytes 0)] (/. Token true))
    (/. E rejected))))
(worker-test.check "joined initialization failure" 0 (freeze (shen-jit.worker-live)))

(worker-test.check "bad entry initialization" rejected
  (freeze (trap-error
    (shen-jit.worker-scope (value worker-test.image) no-such-worker-entry 4
      [1048576 33554432 (shen-jit.bytes 0)] (/. Token true))
    (/. E rejected))))
(worker-test.check "joined bad entry" 0 (freeze (shen-jit.worker-live)))

(let Input (shen-jit.u32! (shen-jit.bytes 4) 0 12345)
     Results (worker-test.scope 4 Input
       (/. Token (do (shen-jit.u32! Input 0 999)
                     (shen-jit.collect)
                     (shen-jit.worker-batch Token (map (/. I (worker-test.request 8)) [0 1 2 3])))))
  (worker-test.check "scope owns immutable shared input; replies survive join" [12345 12345 12345 12345]
    (freeze (map (/. B (shen-jit.u32 B 0)) Results))))

(let Input (shen-jit.u32! (shen-jit.bytes 4) 0 12345)
  (worker-test.scope 4 Input
    (/. Token
      (do (shen-jit.u32! Input 0 999)
          (worker-test.check "direct shared reads and worker GC" [12345 12345 12345 12345]
            (freeze (map (/. B (shen-jit.u32 B 0))
                     (shen-jit.worker-batch Token (map (function worker-test.request) [20 20 20 20])))))
          (shen-jit.collect)
          (worker-test.check "shared descriptor survives repeated jobs" [12345 12345 12345 12345]
            (freeze (map (/. B (shen-jit.u32 B 0))
                     (shen-jit.worker-batch Token (map (function worker-test.request) [21 21 21 21])))))))))

(map (/. Op
       (do (worker-test.check "shared view rejects stores, bounds, pointer operations and escape" rejected
             (freeze (trap-error
               (worker-test.scope 2 (shen-jit.bytes 4)
                 (/. Token (shen-jit.worker-batch Token (map (/. I (worker-test.request Op)) [0 1]))))
               (/. E rejected))))
           (worker-test.check "shared view failure joins" 0 (freeze (shen-jit.worker-live)))))
     [22 23 24 25 26 27 28])

(define worker-test.parent-view
  F -> (worker-test.scope 0 (shen-jit.u32! (shen-jit.bytes 4) 0 12345)
         (/. Token (F (shen-jit.worker-shared-view)))))

(let View (worker-test.parent-view
            (/. View (do (shen-jit.collect)
                         (set worker-test.view-alias (shen-jit.worker-shared-view))
                         (worker-test.check "parent reads frozen view" 12345
                           (freeze (shen-jit.u32 View 0))) View)))
  (do (worker-test.check "escaped parent view invalidated" 0 (freeze (shen-jit.bytes-length View)))
      (worker-test.check "escaped parent view read rejected" rejected
        (freeze (trap-error (shen-jit.u32 View 0) (/. E rejected))))
      (set worker-test.closed-view View)))

(worker-test.check "all parent aliases invalidated" 0
  (freeze (shen-jit.bytes-length (value worker-test.view-alias))))
(trap-error
  (worker-test.parent-view (/. View (do (set worker-test.failed-view View) (error "parent view failed"))))
  (/. E true))
(worker-test.check "parent error invalidates views" 0
  (freeze (shen-jit.bytes-length (value worker-test.failed-view))))

(worker-test.check "view outside scope rejected" rejected
  (freeze (trap-error (shen-jit.worker-shared-view) (/. E rejected))))

(worker-test.check "joined every worker" 0 (freeze (shen-jit.worker-live)))
(output "~A worker checks passed~%" (value worker-test.passed))
(shen-jit.save-executable (value worker-test.closed-image) [])
