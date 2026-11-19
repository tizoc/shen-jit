\\ Consume a body larger than the allowed heap, without retaining its chunks.
(define curl-memory.write
  State Bytes ->
    (let N (shen-jit.bytes-length Bytes)
         At (<-address State 0)
         _ (if (and (= (shen-jit.u8 Bytes 0) (shen-jit.bit-and At 255))
                    (= (shen-jit.u8 Bytes (- N 1)) (shen-jit.bit-and (+ At (- N 1)) 255)))
               true (error "stream payload is corrupt"))
         _ (address-> State 0 (+ At N))
         _ (address-> State 1 (if (> N (<-address State 1)) N (<-address State 1)))
      (:result.ok N)))

(let Size (value curl-memory.size)
     State (io.record [0 0])
     Sink (io.endpoint "discard" write 16384 (function io.no-read)
            (/. Bytes (curl-memory.write State Bytes)) (freeze (:result.ok [])))
     Result (curl.get-to (cn (value curl-test.base) (cn "/bulk/" (str Size))) Sink
              [[body-limit 1073741824] [chunk-size 4096] [timeout 30000] [proxy ""]])
     _ (io.close Sink)
     R (fixture.success Result)
  (if (and (result.ok? Result) (= (<-address State 0) Size) (<= (<-address State 1) 4096)
           (= (curl.body-length R) Size) (curl.streamed? R))
      (output "stream memory ok ~A ~A~%" Size (<-address State 1))
      (error "stream exceeded a bound or lost data")))
(shen-jit.collect)
