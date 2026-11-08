(set process-test.passed 0)
(set process-test.failed 0)

(define process-stream.write
  State Bytes ->
    (let Count (<-address State 0)
         Limit (<-address State 2)
      (if (>= Count Limit)
          (if (= (<-address State 3) throw)
              (error "sink threw after acknowledged writes")
              [error (io.native-error write fixture 37 "sink" "sink failed")])
          (let N (io.min 3 (io.min (- Limit Count) (shen-jit.bytes-length Bytes)))
               _ (address-> State 0 (+ Count N))
            [written N]))))

(define process-stream.sink
  State ->
    (io.endpoint "fixture sink" write 65536 (function io.no-read)
      (/. B (process-stream.write State B))
      (freeze (do (address-> State 1 (+ 1 (<-address State 1))) [ok]))))

(map (/. Mode
       (let State (io.record [0 0 (if (= Mode throw) 5 7) Mode])
            Source (io.input-buffer (buffer.new 0))
            Out (process-stream.sink State)
            Err (io.output-buffer (buffer.new 0))
            Result (process.run-to (value process-test.helper) ["flood" "10000"] Source Out Err
                       [[terminate-grace 0]])
            Partial (process-test.partial Result)
         (do (process-test.check "failed sink preserves each acknowledged short write" (<-address State 2)
               (freeze (process.output-count Partial)))
             (process-test.check "streamed reports do not retain output bytes" 0
               (freeze (buffer.length (process.output-bytes Partial))))
             (process-test.check "failure releases the child" true
               (freeze (process-test.closed? (process.child Partial))))
             (process-test.check "borrowed sink remains open" 0 (freeze (<-address State 1)))
             (process-test.check "sink failure domain" (if (= Mode throw) shen fixture)
               (freeze (io.error-domain (process-test.error Result))))
             (io.close Out) (io.close Err) (io.close Source))))
  [error throw])

(let Source (io.input-buffer (buffer.new 0))
     Out (io.output-buffer (buffer.new 0))
     Err (io.output-buffer (buffer.new 0))
     Result (process.run-to (value process-test.helper) ["exit" "0"] Source Out Err [])
  (do (process-test.check "empty streams succeed with zero-capacity sinks" true
        (freeze (process.success? (process-test.ok Result))))
      (io.close Source) (io.close Out) (io.close Err)))

(let Source (io.input-buffer (buffer.new 0))
     Out (io.output-buffer (buffer.new 0))
     Result (trap-error
              (do (process.run-to (process-test.path "missing-program") [] Source Out [] []) false)
              (/. X true))
  (do (process-test.check "streaming requires actual sinks before spawning" true (freeze Result))
      (io.close Source) (io.close Out)))

(let Result (process-test.run ["exit" "0"] (buffer.new 1048576) [[terminate-grace 0]])
     Partial (process-test.partial Result)
  (do (process-test.check "early stdin closure reports an error instead of killing parent" error
        (freeze (hd Result)))
      (process-test.check "early stdin closure keeps partial progress" true
        (freeze (< (process.input-count Partial) 1048576)))
      (process-test.check "prefetched input is retained separately" true
        (freeze (<= (buffer.length (process.pending-input Partial)) 16384)))
      (process-test.check "input read count includes pending bytes" true
        (freeze (= (process.input-read-count Partial)
                   (+ (process.input-count Partial) (buffer.length (process.pending-input Partial))))))))

(map (/. Cleanup
       (let Ready (io.record [false])
            Source (io.input-buffer (buffer.new 0))
            Out (io.output-buffer (buffer.new 0))
            Err (io.endpoint "readiness" write 65536 (function io.no-read)
                  (/. B (do (address-> Ready 0 true) [written (shen-jit.bytes-length B)]))
                  (freeze [ok]))
            Result (process.run-to (value process-test.helper) ["ready-ignore-term" "10000"] Source Out Err
                       [[cancel (freeze (<-address Ready 0))] [timeout 5000]
                        [cleanup-timeout Cleanup] [terminate-grace (if (= Cleanup 1) 60000 30)]])
            Partial (process-test.partial Result)
            Child (process.child Partial)
            Wait (if (process-test.closed? Child) [ok (process.status Partial)] (process.wait Child 1000))
            _ (if (= Wait [pending])
                  (do (process.kill Child) (process.wait Child 1000)) true)
            _ (process.close Child)
            _ (io.close Source)
            _ (io.close Out)
            _ (io.close Err)
         (do (process-test.check "cleanup sends force even when its budget expires" false
               (freeze (= Wait [pending])))
             (if (io.file-windows?) skip
                 (process-test.check "ignored SIGTERM is followed by SIGKILL" [ok [signalled 9]]
                   (freeze Wait))))))
  [1000 1])

(let Cancel (io.record [false])
     _ (thread (freeze (do (process.c-pause [] 40) (address-> Cancel 0 true))))
     Result (process-test.run ["hold" "10000"] (buffer.new 0)
               [[cancel (freeze (<-address Cancel 0))] [terminate-grace 0]])
  (process-test.check "cooperative cancellation is observed from another task" cancelled
    (freeze (io.error-domain (process-test.error Result)))))

(if (io.file-windows?) skip
    (let Done (io.record [[]])
         _ (thread (freeze (address-> Done 0 (process-test.run ["signals"] (buffer.new 0) []))))
         _ (process-test.join Done 200)
         Report (process-test.ok (<-address Done 0))
      (do (process-test.check "worker-spawned child does not inherit blocked SIGINT" 0
            (freeze (process-test.u32 (process.output-bytes Report) 0)))
          (process-test.check "child receives default SIGPIPE" 1
            (freeze (process-test.u32 (process.output-bytes Report) 4))))))

(output "~A passed, ~A failed~%" (value process-test.passed) (value process-test.failed))
