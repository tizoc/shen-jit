(set pt.passed 0)
(set pt.failed 0)
(define pt.check
  Name Value -> (if Value (set pt.passed (+ (value pt.passed) 1))
                    (do (output "FAIL ~A~%" Name) (set pt.failed (+ (value pt.failed) 1)))))
(define pt.error?
  Code -> (trap-error (do (thaw Code) false) (/. E true)))
(define pt.indices
  At End -> (if (> At End) [] [At | (pt.indices (+ At 1) End)]))
(define pt.request
  Op -> (let B (buffer.new 1) _ (buffer.u8! B 0 Op) B))
(define pt.config
  -> (let Input (buffer.new 4) _ (shen-jit.u32! (buffer.owner Input) 0 1977)
       (parallel.config 16777216 67108864 Input)))
(define pt.scope
  Count Body -> (parallel.with-workers (value pt.image) (intern "pt.worker") Count (pt.config) Body))

\\ The optional checker accepts clients of the small opaque interface.
(tc +)
(define pt.typed-read
  {parallel.shared --> number}
  Input -> (parallel.shared-u32 Input 0))
(define pt.typed-copy
  {parallel.shared --> buffer.view}
  Input -> (parallel.shared-copy Input 0 4))
(tc -)

(map (/. P
       (let Results (pt.scope P (/. S
                       (do (pt.check "scope count" (= (parallel.count S) P))
                           (set pt.escaped S)
                           (set pt.borrow (parallel.shared))
                           (pt.check "typed shared read" (= (pt.typed-read (value pt.borrow)) 1977))
                           (set pt.copy (pt.typed-copy (value pt.borrow)))
                           (pt.check "owned copy" (= (shen-jit.u32 (buffer.owner (value pt.copy)) 0) 1977))
                           (let First (parallel.batch S (map (/. Ignored (pt.request 1)) (pt.indices 1 P)))
                                _ (parallel.batch S (map (/. Ignored (pt.request 0)) (pt.indices 1 P)))
                             First))))
            _ (shen-jit.collect)
         (do (pt.check "retained parent replies" (= (length Results) P))
             (map (/. I (let B (buffer.owner (nth I Results))
                          (pt.check "worker index and shared value"
                            (and (= (shen-jit.u32 B 0) (- I 1)) (= (shen-jit.u32 B 4) 1977)))))
                  (pt.indices 1 P))
             (pt.check "borrow revoked" (= (parallel.shared-length (value pt.borrow)) 0))
             (pt.check "owned shared copy outlives scope" (= (shen-jit.u32 (buffer.owner (value pt.copy)) 0) 1977))
             (pt.check "revoked read fails" (pt.error? (freeze (pt.typed-read (value pt.borrow)))))
             (pt.check "escaped scope fails" (pt.error? (freeze (parallel.batch (value pt.escaped) [])))))))
     [1 2 3 4 5 8])
(map (/. Op (pt.check "worker error and forbidden shared writes/replies"
             (pt.error? (freeze (pt.scope 2 (/. S (parallel.batch S [(pt.request Op) (pt.request 0)]))))))) [2 3 4])
(pt.check "parent error joins" (pt.error? (freeze (pt.scope 2 (/. S (error "parent failed"))))))
(pt.check "scope usable after errors" (= (length (pt.scope 1 (/. S (parallel.batch S [(pt.request 0)])))) 1))
(pt.check "wrong batch length" (pt.error? (freeze (pt.scope 2 (/. S (parallel.batch S [(pt.request 0)]))))))
(map (/. N (pt.check "invalid worker count rejected"
             (pt.error? (freeze (pt.scope N (/. S true)))))) [0 -1 65 3.5 true [] "3"])
(pt.check "maximum worker count reaches image loading"
  (= (trap-error
       (parallel.with-workers "build/no-such-worker-image" (intern "pt.worker") 64
         (pt.config) (/. S (error "invalid image ran the scope body")))
       (/. E (error-to-string E)))
     "worker: cannot load image"))
(pt.check "invalid config" (pt.error? (freeze (parallel.with-workers "" worker 1 [] (/. S true)))))
(pt.check "invalid scope" (pt.error? (freeze (parallel.batch [] []))))
(output "~A passed, ~A failed (structured parallel library)~%" (value pt.passed) (value pt.failed))
(if (= (value pt.failed) 0) true (shen-jit.exit 1))
