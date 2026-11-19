(define curl-pressure.write
  State Bytes ->
    (let _ (if (= (<-address State 0) 0)
               (curl.get (cn (value curl-test.base) "/sink-hold") [[proxy ""]]) true)
         N (shen-jit.bytes-length Bytes)
         _ (address-> State 0 (+ (<-address State 0) N))
      (:result.ok N)))

(let State (io.record [0])
     Sink (io.endpoint "held sink" write 16384 (function io.no-read)
            (/. Bytes (curl-pressure.write State Bytes)) (freeze (:result.ok [])))
     Result (curl.get-to (cn (value curl-test.base) "/backpressure") Sink
              [[body-limit 67108864] [proxy ""] [timeout 30000]])
     _ (io.close Sink)
  (if (and (result.ok? Result) (= (<-address State 0) 67108864))
      (output "stream pressure ok~%") (error "backpressure transfer failed")))
(shen-jit.collect)
