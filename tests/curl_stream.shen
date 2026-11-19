(set curl-test.passed 0)
(set curl-test.failed 0)

(define curl-stream.short-write
  State Output Bytes ->
    (let At (<-address State 0)
         N (io.min 3 (shen-jit.bytes-length Bytes))
         _ (shen-jit.copy-bytes (buffer.owner Output) At Bytes 0 N)
         _ (address-> State 0 (+ At N))
      (:result.ok N)))

(define curl-stream.close
  State Fail ->
    (do (address-> State 1 (+ (<-address State 1) 1))
        (if Fail (:result.err (io.native-error close fixture 19 "sink" "close failed")) (:result.ok []))))

(define curl-stream.short-sink
  State Output ->
    (io.endpoint "short sink" write 7 (function io.no-read)
      (/. Bytes (curl-stream.short-write State Output Bytes)) (freeze (curl-stream.close State false))))

(define curl-stream.failing-write
  State Limit Mode Bytes ->
    (let At (<-address State 0)
         N (io.min (- Limit At) (shen-jit.bytes-length Bytes))
      (if (= N 0)
          (cond ((= Mode zero) (:result.ok 0))
                ((= Mode throw) (error "sink threw"))
                ((= Mode malformed) (:result.ok 999999))
                (true (:result.err (io.native-error write fixture 17 "sink" "sink failed"))))
          (do (address-> State 0 (+ At N)) (:result.ok N)))))

(define curl-stream.failing-sink
  State Limit Mode CloseFail ->
    (io.endpoint "failing sink" write 128 (function io.no-read)
      (/. Bytes (curl-stream.failing-write State Limit Mode Bytes))
      (freeze (curl-stream.close State CloseFail))))

(let C (curl.open)
     Expected (curl-test.ok (curl-test.get C "/binary" []))
     Output (buffer.new 1024)
     State (io.record [0 0])
     Sink (curl-stream.short-sink State Output)
     R (curl-test.ok (curl.request-to C "GET" (curl-test.url "/binary") [] (buffer.new 0) Sink
                      [[proxy ""] [chunk-size 11]]))
     Again (curl-test.ok (curl-test.get C "/binary" []))
     _ (curl.close C)
  (do (curl-test.check "streamed status" 200 (freeze (curl.status R)))
      (curl-test.check "short sink receives exact binary body" true (freeze (buffer.equal? Output (curl.body Expected))))
      (curl-test.check "streamed body length" 1024 (freeze (curl.body-length R)))
      (curl-test.check "streamed marker" true (freeze (curl.streamed? R)))
      (curl-test.check "streamed response does not pretend to retain a body" true
        (freeze (curl-test.raises? (freeze (curl.body R)))))
      (curl-test.check "borrowed sink stays open" 0 (freeze (<-address State 1)))
      (curl-test.check "stream and buffered requests reuse connection" (curl.header-values Expected "x-client-port")
        (freeze (curl.header-values R "x-client-port")))
      (curl-test.check "buffered request works after stream" true (freeze (buffer.equal? Output (curl.body Again))))
      (curl-test.check "buffered response length accessor" 1024 (freeze (curl.body-length Again)))
      (curl-test.check "buffered response marker" false (freeze (curl.streamed? Again)))
      (io.close Sink)))

(map (/. Case
       (let State (io.record [0 0])
            Sink (curl-stream.failing-sink State 137 (hd Case) false)
            Error (curl-test.error (curl.get-to (curl-test.url "/binary") Sink [[proxy ""]]))
         (do (curl-test.check "sink error preserves exact partial progress" 137 (freeze (io.error-progress Error)))
             (curl-test.check "sink error preserves native code or validates backend" (hd (tl Case))
               (freeze (io.error-code Error)))
             (curl-test.check "failed borrowed sink is not closed" 0 (freeze (<-address State 1)))
             (io.close Sink))))
  [[error 17] [zero 0] [throw 0] [malformed 0]])

(let C (curl.open)
     State (io.record [0 0])
     Sink (curl-stream.failing-sink State 137 error true)
     Error (curl-test.error (curl.request-with-sink C "GET" (curl-test.url "/binary") [] (buffer.new 0)
                             (/. Head (:result.ok Sink)) [[proxy ""]]))
     Again (curl-test.ok (curl-test.get C "/binary" []))
     _ (curl.close C)
  (do (curl-test.check "owned sink closes after failure" 1 (freeze (<-address State 1)))
      (curl-test.check "primary sink failure wins" 17 (freeze (io.error-code Error)))
      (curl-test.check "close failure retained as secondary" 19
        (freeze (io.error-code (hd (io.error-secondary Error)))))
      (curl-test.check "partial progress survives cleanup" 137 (freeze (io.error-progress Error)))
      (curl-test.check "client reused after callback failure" 200 (freeze (curl.status Again)))))

(let C (curl.open)
     State (io.record [0 0])
     Sink (curl-stream.failing-sink State 2048 error true)
     Error (curl-test.error (curl.request-with-sink C "GET" (curl-test.url "/binary") [] (buffer.new 0)
                             (/. Head (:result.ok Sink)) [[proxy ""]]))
     _ (curl.close C)
  (do (curl-test.check "close failure after successful body" 19 (freeze (io.error-code Error)))
      (curl-test.check "close failure keeps total written" 1024 (freeze (io.error-progress Error)))
      (curl-test.check "owned sink closes once" 1 (freeze (<-address State 1)))))

(let Output (buffer.new 5)
     Sink (io.output-buffer Output)
     R (curl-test.ok (curl.get-to (curl-test.url "/chunked") Sink [[proxy ""]]))
     _ (io.close Sink)
  (do (curl-test.check "streamed chunked body" "abcde" (freeze (buffer.string Output)))
      (curl-test.check "streamed trailers" [["x-trail" "yes"]] (freeze (curl.trailers R)))
      (curl-test.check "streamed trailers remain separate" [] (freeze (curl.header-values R "x-trail")))))

(let C (curl.open)
     State (io.record [0 0])
     Sink (curl-stream.failing-sink State 4096 error false)
     Opened (io.record [0 []])
     Open (/. Head (do (address-> Opened 0 (+ (<-address Opened 0) 1)) (address-> Opened 1 Head) (:result.ok Sink)))
     R (curl-test.ok (curl.request-with-sink C "GET" (curl-test.url "/redirect") [] (buffer.new 0) Open
                      [[proxy ""] [redirect-limit 2]]))
     _ (curl.close C)
  (do (curl-test.check "opener called once after redirects" 1 (freeze (<-address Opened 0)))
      (curl-test.check "opener sees final status" 200 (freeze (curl.status (<-address Opened 1))))
      (curl-test.check "opener excludes intermediate headers" [] (freeze (curl.header-values (<-address Opened 1) "x-hop")))
      (curl-test.check "redirect body is not written" 1024 (freeze (<-address State 0)))
      (curl-test.check "owned sink closes after success" 1 (freeze (<-address State 1)))
      (curl-test.check "redirect metadata retained" 1 (freeze (curl.redirects R)))))

(let C (curl.open)
     State (io.record [0 0])
     Sink (curl-stream.failing-sink State 4096 error false)
     Partial (curl-test.error (curl.request-to C "GET" (curl-test.url "/partial") [] (buffer.new 0) Sink [[proxy ""]]))
     Timeout (curl-test.error (curl.request-to C "GET" (curl-test.url "/stall-body") [] (buffer.new 0) Sink
                               [[proxy ""] [timeout 100]]))
     Limit (curl-test.error (curl.request-to C "GET" (curl-test.url "/binary") [] (buffer.new 0) Sink
                             [[proxy ""] [body-limit 16]]))
     Rejected (curl-test.error (curl.request-with-sink C "GET" (curl-test.url "/error") [] (buffer.new 0)
                                (/. Head (:result.err (io.native-error download http (curl.status Head) "URL" "rejected")))
                                [[proxy ""]]))
     Throw (curl-test.error (curl.request-with-sink C "GET" (curl-test.url "/binary") [] (buffer.new 0)
                             (/. Head (error "opener threw")) [[proxy ""]]))
     _ (curl.close C)
  (do (curl-test.check "streamed partial response keeps CURLcode" 18 (freeze (io.error-code Partial)))
      (curl-test.check "streamed partial response keeps written progress" 3 (freeze (io.error-progress Partial)))
      (curl-test.check "timeout after a partial body keeps CURLcode" 28 (freeze (io.error-code Timeout)))
      (curl-test.check "timeout after a partial body keeps sink progress" 3 (freeze (io.error-progress Timeout)))
      (curl-test.check "streamed budget distinguished" limit (freeze (io.error-domain Limit)))
      (curl-test.check "limit before first accepted chunk writes nothing" 0 (freeze (io.error-progress Limit)))
      (curl-test.check "opener rejects status before writes" 404 (freeze (io.error-code Rejected)))
      (curl-test.check "opener failure has zero progress" 0 (freeze (io.error-progress Rejected)))
      (curl-test.check "opener exception handled" callback (freeze (io.error-operation Throw)))
      (io.close Sink)))

(let C (curl.open)
     State (io.record [0 0])
     Sink (curl-stream.failing-sink State 0 error false)
     R (curl-test.ok (curl.request-with-sink C "HEAD" (curl-test.url "/binary") [] (buffer.new 0)
                      (/. Head (:result.ok Sink)) [[proxy ""] [body-limit 0]]))
     _ (curl.close C)
  (do (curl-test.check "empty body still opens and closes sink" 1 (freeze (<-address State 1)))
      (curl-test.check "empty streamed body has length zero" 0 (freeze (curl.body-length R)))
      (curl-test.check "empty streamed body has metadata" ["1024"] (freeze (curl.header-values R "content-length")))))

(let C (curl.open)
     Data (buffer.from-string "ac#0;bc#255;")
     Output (buffer.new 4)
     Sink (io.output-buffer Output)
     R (curl-test.ok (curl.request-to C "POST" (curl-test.url "/echo") [] Data Sink
                      [[proxy ""] [chunk-size 1]]))
     _ (io.close Sink)
     _ (curl.close C)
  (do (curl-test.check "binary upload with streamed response" true (freeze (buffer.equal? Data Output)))
      (curl-test.check "streamed custom request method" ["POST"] (freeze (curl.header-values R "x-method")))
      (curl-test.check "one-byte deliveries keep length" 4 (freeze (curl.body-length R)))))

(output "~A passed, ~A failed~%" (value curl-test.passed) (value curl-test.failed))
