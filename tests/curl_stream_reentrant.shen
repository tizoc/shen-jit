\\ Inside the client's own write callback, collect, then use the client again: the busy guard refuses
\\ both a close and a request, and the transfer resumes.
(define curl-stream-reentrant.write
  C Count Bytes ->
    (let _ (if (= (<-address Count 0) 0)
               (let _ (shen-jit.collect)
                    Close (curl.close C)
                    Request (curl.request C "GET" (value curl-test.base) [] (buffer.new 0) [[proxy ""]])
                 (if (and (= (hd Close) error) (= (hd Request) error))
                     true (error "reentrant use bypassed the busy guard"))) true)
         N (shen-jit.bytes-length Bytes)
         _ (address-> Count 0 (+ (<-address Count 0) N))
      [written N]))

(let C (curl.open)
     Count (io.record [0])
     Sink (io.endpoint "reentrant sink" write 128 (function io.no-read)
            (/. Bytes (curl-stream-reentrant.write C Count Bytes)) (freeze [ok]))
     Result (curl.request-to C "GET" (cn (value curl-test.base) "/binary") [] (buffer.new 0) Sink [[proxy ""]])
     _ (io.close Sink)
     Close (curl.close C)
  (if (and (= (hd Result) ok) (= (<-address Count 0) 1024) (= Close [ok]))
      (output "3 passed, 0 failed~%") (error "reentrant callback failed")))
