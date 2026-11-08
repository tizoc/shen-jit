\\ Compile before the saved-image run enables collection at every allocation.
(define process-gc.run
  Helper ->
    (let Report (hd (tl (process.run Helper ["echo"] (buffer.from-string "gc c#0;bytes") [])))
         _ (shen-jit.collect)
      (if (and (process.success? Report) (= (buffer.string (process.output-bytes Report)) "gc c#0;bytes"))
          true
          (error "process values moved without roots"))))

(define process-gc.worker
  Done 0 -> (address-> Done 0 [ok])
  Done N ->
    (do (shen-jit.collect) (process.c-pause [] 10) (process-gc.worker Done (- N 1))))

(define process-gc.threaded
  Helper ->
    (let Done (io.record [[]])
         _ (thread (freeze (process-gc.worker Done 20)))
         _ (process-gc.run Helper)
         _ (process-test.join Done 1000)
      true))
