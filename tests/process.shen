(set process-test.passed 0)
(set process-test.failed 0)

(define process-test.check
  Name Expected F ->
    (let Actual (trap-error (thaw F) (/. X [raised (error-to-string X)]))
      (if (= Actual Expected)
          (set process-test.passed (+ 1 (value process-test.passed)))
          (do (set process-test.failed (+ 1 (value process-test.failed)))
              (output "FAIL ~A: wanted ~S, got ~S~%" Name Expected Actual)))))

(define process-test.ok
  [ok Value] -> Value
  [error E] -> (error "unexpected process failure: ~A" (io.error-message E))
  [error E _] -> (error "unexpected process failure: ~A" (io.error-message E)))

(define process-test.error
  [error E] -> E
  [error E _] -> E
  _ -> (error "expected process error"))

(define process-test.partial
  [error _ Report] -> Report
  _ -> (error "expected partial process report"))

(define process-test.u32
  View At ->
    (+ (+ (buffer.u8 View At) (* 256 (buffer.u8 View (+ At 1))))
       (+ (* 65536 (buffer.u8 View (+ At 2))) (* 16777216 (buffer.u8 View (+ At 3))))))

(define process-test.run
  Args Input Options -> (process.run (value process-test.helper) Args Input Options))

(define process-test.path
  Name -> (cn (value process-test.root) (cn "/" Name)))

(define process-test.closed?
  C -> (trap-error (do (process.poll C) false) (/. X true)))

(define process-test.output
  R -> (buffer.string (process.output-bytes (process-test.ok R))))

(let Report (process-test.ok (process-test.run ["exit" "17"] (buffer.new 0) []))
  (do (process-test.check "nonzero exit is data" [exited 17] (freeze (process.status Report)))
      (process-test.check "nonzero exit is not success" false (freeze (process.success? Report)))
      (process-test.check "run closes its child" true
        (freeze (process-test.closed? (process.child Report))))))

(let C (process-test.ok (process.spawn (value process-test.helper) ["hold" "200"]
                         [[stdin null] [stdout pipe] [stderr null]]))
     Poll (process.poll C)
     Early (process.close C)
     Pending (process.wait C 0)
     _ (process.pipe-until (process.stdout C) (clock.deadline 10) (freeze false))
     Read (io.read-some (process.stdout C) (buffer.new 1) [])
     _ (process.kill C)
     Wait (process.wait C 1000)
     Closed (process.close C)
  (do (process-test.check "poll reports running" [ok [running]] (freeze Poll))
      (process-test.check "close refuses to abandon running child" library
        (freeze (io.error-domain (process-test.error Early))))
      (process-test.check "zero-time wait is pending" [pending] (freeze Pending))
      (process-test.check "pipe read has its own deadline" timeout
        (freeze (io.error-domain (process-test.error Read))))
      (process-test.check "kill completes and wait observes exit" ok (freeze (hd Wait)))
      (process-test.check "child close succeeds" [ok] (freeze Closed))
      (process-test.check "close is idempotent" [ok] (freeze (process.close C)))
      (process-test.check "closed aliases cannot signal reused IDs" true
        (freeze (trap-error (do (process.kill C) false) (/. X true))))))

(let Args ["" "one two" "a'bc#34;d" "tailc#92;" "c#92;c#92;c#34;" "café λ" "$HOME; $(exit 9)" "linec#10;two"]
     Report (process-test.ok (process-test.run ["args" | Args] (buffer.new 0) []))
     _ (shen-jit.collect)
     _ (io.write-file (process-test.path "arguments.bin") (process.output-bytes Report))
  (do (process-test.check "arguments preserve their count" 8
        (freeze (process-test.u32 (process.output-bytes Report) 0)))
      (process-test.check "owned output survives collection" true
        (freeze (> (process.output-count Report) 40)))))

(process-test.check "environment override has Unicode bytes" "café λ"
  (freeze (process-test.output
            (process-test.run ["environment" "SHEN_PROCESS_VALUE"] (buffer.new 0)
              [[environment [["SHEN_PROCESS_VALUE" "café λ"]]]]))))
(process-test.check "empty environment value is retained" ""
  (freeze (process-test.output
            (process-test.run ["environment" "SHEN_PROCESS_VALUE"] (buffer.new 0)
              [[environment [["SHEN_PROCESS_VALUE" ""]]]]))))
(process-test.check "parent environment is inherited" "parent-value"
  (freeze (process-test.output
            (process-test.run ["environment" "SHEN_PROCESS_PARENT_FIXTURE"] (buffer.new 0) []))))
(process-test.check "environment entry can be removed" ""
  (freeze (process-test.output
            (process-test.run ["environment" "SHEN_PROCESS_PARENT_FIXTURE"] (buffer.new 0)
              [[environment [["SHEN_PROCESS_PARENT_FIXTURE" []]]]]))))
(process-test.check "replacement environment does not inherit unrelated entries" ""
  (freeze (process-test.output
            (process-test.run ["environment" "SHEN_PROCESS_PARENT_FIXTURE"] (buffer.new 0)
              [[clear-environment true]]))))

(let Home (value *home-directory*)
     _ (set *home-directory* (value process-test.root))
     Result (process-test.run ["cwd"] (buffer.new 0) [])
     _ (set *home-directory* Home)
  (process-test.check "cwd follows one home snapshot" (value process-test.root)
    (freeze (process-test.output Result))))

(let Report (process-test.ok
              (process.run "process-child" ["environment" "ONLY"] (buffer.new 0)
                [[cwd (value process-test.root)] [clear-environment true]
                 [environment [["PATH" "bin"] ["ONLY" "child-path"]]]]))
  (process-test.check "PATH comes from child environment and cwd" "child-path"
    (freeze (buffer.string (process.output-bytes Report)))))

(let C (process-test.ok
         (process.spawn (value process-test.helper) ["echo"]
           [[cwd (value process-test.root)] [stdin [file "input.bin"]]
            [stdout [file "redirect.bin"]] [stderr null]]))
     Status (process.wait C 1000)
     _ (process.close C)
  (process-test.check "file redirection exits normally" [ok [exited 0]] (freeze Status)))

(let Input (process-test.ok (io.read-file (process-test.path "large-input.bin") 2097152))
     Report (process-test.ok (process-test.run ["duplex" "262144"] Input []))
     _ (io.write-file (process-test.path "duplex-out.bin") (process.output-bytes Report))
     _ (io.write-file (process-test.path "duplex-err.bin") (process.error-bytes Report))
  (do (process-test.check "large stdin is fully written while both outputs drain" 2097152
        (freeze (process.input-count Report)))
      (process-test.check "stdout and stderr have independent counts" [262156 262144]
        (freeze [(process.output-count Report) (process.error-count Report)]))
      (process-test.check "duplex child succeeded" true (freeze (process.success? Report)))))

(let Result (process-test.run ["flood" "1048576"] (buffer.new 0) [[stdout-limit 10000]])
     Partial (process-test.partial Result)
  (do (process-test.check "output quota is explicit" limit
        (freeze (io.error-domain (process-test.error Result))))
      (process-test.check "quota retains exact prefix" 10000
        (freeze (buffer.length (process.output-bytes Partial))))
      (process-test.check "quota progress is exact" 10000
        (freeze (io.error-progress (process-test.error Result))))
      (process-test.check "quota cleanup releases child" true
        (freeze (process-test.closed? (process.child Partial))))))

(let Result (process-test.run ["hold" "10000"] (buffer.new 0) [[timeout 60] [terminate-grace 20]])
     Partial (process-test.partial Result)
  (do (process-test.check "run deadline bounds pipe draining" timeout
        (freeze (io.error-domain (process-test.error Result))))
      (process-test.check "timeout cleanup observes exit" false
        (freeze (= (process.status Partial) [running])))
      (process-test.check "timeout closes child after reaping" true
        (freeze (process-test.closed? (process.child Partial))))))

(let Result (process-test.run ["hold" "10000"] (buffer.new 0)
               [[cancel (freeze true)] [terminate-grace 0]])
  (do (process-test.check "cancellation is explicit" cancelled
        (freeze (io.error-domain (process-test.error Result))))
      (process-test.check "cancellation before the start launches nothing" 2
        (freeze (length Result)))))

(process-test.check "invalid cancel is refused before launching a child" true
  (freeze
    (trap-error
      (do (process-test.run ["hold" "1000"] (buffer.new 0) [[cancel 1] [terminate-grace 0]])
          false)
      (/. X true))))

(process-test.check "invalid cancel is refused before launching a pipeline" true
  (freeze
    (trap-error
      (do (process.pipeline [[(value process-test.helper) ["hold" "1000"]]] (buffer.new 0)
            [[cancel 1] [terminate-grace 0]])
          false)
      (/. X true))))

(let Input (buffer.new 1048576)
     Result (process-test.run ["slow-input"] Input [[timeout 60] [terminate-grace 0]])
     Partial (process-test.partial Result)
  (do (process-test.check "blocked stdin remains cancellable" timeout
        (freeze (io.error-domain (process-test.error Result))))
      (process-test.check "short stdin retains acknowledged progress" true
        (freeze (< (process.input-count Partial) 1048576)))))

(let Result (process-test.run ["descendant"] (buffer.new 0) [[timeout 100] [terminate-grace 20]])
     Partial (process-test.partial Result)
  (do (process-test.check "leader exit does not imply pipe EOF" timeout
        (freeze (io.error-domain (process-test.error Result))))
      (process-test.check "exited leader status is retained during descendant cleanup" [exited 0]
        (freeze (process.status Partial)))
      (process-test.check "descendant did write its PID" 4
        (freeze (buffer.length (process.output-bytes Partial))))))

(let Reports (process-test.ok
                (process.pipeline [[(value process-test.helper) ["echo"]]
                                   [(value process-test.helper) ["echo"]]]
                  (buffer.from-string "a c#0;bc#13;c#10;") []))
     Last (hd (tl Reports))
  (do (process-test.check "pipeline records each exit" [[exited 0] [exited 0]]
        (freeze (map (function process.status) Reports)))
      (process-test.check "pipeline preserves binary bytes" "a c#0;bc#13;c#10;"
        (freeze (buffer.string (process.output-bytes Last))))
      (process-test.check "pipeline closes every child" [true true]
        (freeze (map (/. R (process-test.closed? (process.child R))) Reports)))))

(let Result (process.pipeline [[(value process-test.helper) ["hold" "10000"]]
                              [(process-test.path "missing-program") []]] (buffer.new 0)
               [[terminate-grace 0]])
     Reports (hd (tl (tl Result)))
  (do (process-test.check "partial pipeline spawn is an error" error (freeze (hd Result)))
      (process-test.check "partial pipeline retains launched stage" 1 (freeze (length Reports)))
      (process-test.check "partial pipeline is terminated and reaped" true
        (freeze (process-test.closed? (process.child (hd Reports)))))))

(process-test.check "missing executable is a native spawn error" true
  (freeze (> (io.error-code (process-test.error
               (process.spawn (process-test.path "missing-program") [] []))) 0)))
(process-test.check "missing cwd is a native spawn error" true
  (freeze (> (io.error-code (process-test.error
               (process.spawn (value process-test.helper) ["exit" "0"]
                 [[cwd (process-test.path "missing-directory")]]))) 0)))

(if (io.file-windows?)
    (process-test.check "exit code 259 is not mistaken for running" [exited 259]
      (freeze (process.status (process-test.ok (process-test.run ["exit" "259"] (buffer.new 0) [])))))
    \\ The helper's own runtime may hold sockets, as a sanitizer's did on one macOS: what counts is
    \\ that a listener open here adds none.
    (let Before (process-test.ok (process-test.run ["sockets"] (buffer.new 0) []))
         Stream (open (process-test.path "input.bin") in)
         S (socket.listen "127.0.0.1" 0)
         Files (process-test.ok (process-test.run ["has-file" (process-test.path "input.bin")] (buffer.new 0) []))
         Sockets (process-test.ok (process-test.run ["sockets"] (buffer.new 0) []))
         _ (close Stream)
         _ (socket.close S)
      (do (process-test.check "kernel streams do not leak into children" 0
            (freeze (process-test.u32 (process.output-bytes Files) 0)))
          (process-test.check "listeners do not leak into children"
            (process-test.u32 (process.output-bytes Before) 0)
            (freeze (process-test.u32 (process.output-bytes Sockets) 0))))))

(output "~A passed, ~A failed~%" (value process-test.passed) (value process-test.failed))
