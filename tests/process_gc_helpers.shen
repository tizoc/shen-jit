\\ Compile before the saved-image run enables collection at every allocation.
(define process-gc.run
  Helper ->
    (let Report (hd (tl (process.run Helper ["echo"] (buffer.from-string "gc c#0;bytes") [])))
         _ (shen-jit.collect)
      (if (and (process.success? Report) (= (buffer.string (process.output-bytes Report)) "gc c#0;bytes"))
          true
          (error "process values moved without roots"))))
