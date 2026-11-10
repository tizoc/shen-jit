\\ Deterministic response streaming over independent managed I/O, including short writes.
(set stream-test.passed 0)
(set stream-test.failed 0)

(define stream-test.check
  Name Expected F ->
    (let Actual (trap-error (thaw F) (/. X [raised (error-to-string X)]))
      (if (= Actual Expected)
          (set stream-test.passed (+ 1 (value stream-test.passed)))
          (do (set stream-test.failed (+ 1 (value stream-test.failed)))
              (output "FAIL ~A: wanted ~S, got ~S~%" Name Expected Actual)))))

(define stream-test.request
  Method -> (hd (tl (http.parse-request
                     (buffer.from-string (make-string "~A / HTTP/1.1c#13;c#10;Host: localc#13;c#10;c#13;c#10;" Method)) 0))))

\\ State: remaining chunks, pulls, closes, reverse event log, output, clock, close result.
(define stream-test.state
  Chunks -> (io.record [Chunks 0 0 [] (buffer.builder 10000) 0 [ok]]))

(define stream-test.event
  State Event -> (address-> State 3 [Event | (<-address State 3)]))

(define stream-test.next
  State Maximum D ->
    (do (deadline.check D)
        (stream-test.event State [pull Maximum (buffer.builder-length (<-address State 4))])
        (address-> State 1 (+ 1 (<-address State 1)))
        (stream-test.pop State (<-address State 0))))

(define stream-test.pop
  _ [] -> [eof]
  State [X | Rest] ->
    (do (address-> State 0 Rest)
        (if (string? X) [chunk (buffer.from-string X)] X)))

(define stream-test.close
  State ->
    (do (stream-test.event State [close])
        (address-> State 2 (+ 1 (<-address State 2)))
        (<-address State 6)))

(define stream-test.source
  State -> (http.source (/. Maximum D (stream-test.next State Maximum D))
                        (freeze (stream-test.close State))))

(define stream-test.endpoint
  State ->
    (io.endpoint "stream test" write 3 (function io.no-read)
      (/. Bytes (let N (shen-jit.bytes-length Bytes)
                  (do (buffer.append! (<-address State 4) (buffer.wrap Bytes))
                      (stream-test.event State [write N])
                      [written N])))
      (freeze [ok])))

(define stream-test.send
  State Method Status Framing Options ->
    (let E (stream-test.endpoint State)
         S (stream-test.source State)
         Response (http.stream-response Status [] Framing S)
         D (deadline.after (freeze (<-address State 5)) 100)
         Result (http.send-response E (stream-test.request Method) Response D Options)
         _ (io.close E)
      Result))

(define stream-test.wire
  State -> (buffer.string (buffer.finish (<-address State 4))))

(define stream-test.progress
  [error Error] -> [(io.error-domain Error) (io.error-progress Error)])

(let State (stream-test.state ["abc" "de"])
     Result (stream-test.send State "GET" 200 [chunked] [[response-chunk-size 3]])
     Wire (stream-test.wire State)
  (do (stream-test.check "chunk framing" "HTTP/1.1 200 OKc#13;c#10;Transfer-Encoding: chunkedc#13;c#10;Connection: closec#13;c#10;c#13;c#10;3c#13;c#10;abcc#13;c#10;2c#13;c#10;dec#13;c#10;0c#13;c#10;c#13;c#10;" (freeze Wire))
      (stream-test.check "acknowledged wire length" [ok (shen-jit.bytes-length (shen-jit.string->bytes Wire))] (freeze Result))
      (stream-test.check "one EOF probe" 3 (freeze (<-address State 1)))
      (stream-test.check "exactly one cleanup" 1 (freeze (<-address State 2)))
      (stream-test.check "backpressure before second pull" true
        (freeze (element? [pull 3 74] (<-address State 3))))))

(let State (stream-test.state ["abc" "de"])
     Result (stream-test.send State "GET" 200 [length 5] [[response-chunk-size 3]])
  (do (stream-test.check "known length framing" "HTTP/1.1 200 OKc#13;c#10;Content-Length: 5c#13;c#10;Connection: closec#13;c#10;c#13;c#10;abcde"
        (freeze (stream-test.wire State)))
      (stream-test.check "known length succeeds" ok (freeze (hd Result)))
      (stream-test.check "bounded EOF probe" true (freeze (element? [pull 1 62] (<-address State 3))))))

(map (/. Framing
       (let State (stream-test.state ["must not pull"])
            Result (stream-test.send State "HEAD" 200 Framing [])
         (do (stream-test.check "HEAD succeeds" ok (freeze (hd Result)))
             (stream-test.check "HEAD never pulls" 0 (freeze (<-address State 1)))
             (stream-test.check "HEAD closes" 1 (freeze (<-address State 2))))))
  [[length 13] [chunked]])

(map (/. Status
       (let State (stream-test.state ["must not pull"])
            Result (stream-test.send State "GET" Status [length 0] [])
         (do (stream-test.check "bodyless status succeeds" ok (freeze (hd Result)))
             (stream-test.check "bodyless never pulls" 0 (freeze (<-address State 1)))
             (stream-test.check "bodyless closes" 1 (freeze (<-address State 2))))))
  [204 205 304])

(map (/. Case
       (let State (stream-test.state (hd Case))
            Result (stream-test.send State "GET" 200 (hd (tl Case)) (hd (tl (tl Case))))
         (do (stream-test.check "invalid initial source rejected" [application 0]
               (freeze (stream-test.progress Result)))
             (stream-test.check "preflight commits no bytes" "" (freeze (stream-test.wire State)))
             (stream-test.check "preflight closes once" 1 (freeze (<-address State 2))))))
  [[[] [length 1] []]
   [[""] [chunked] []]
   [["abcd"] [chunked] [[response-chunk-size 3]]]
   [["x"] [length 0] []]
   [["x"] [chunked] [[response-body-limit 0]]]
   [[[error (io.error read "producer" "failed")]] [chunked] []]])

(map (/. Case
       (let State (stream-test.state (hd Case))
            Result (stream-test.send State "GET" 200 (hd (tl Case)) (hd (tl (tl Case))))
            Wire (stream-test.wire State)
         (do (stream-test.check "late source error fails" error (freeze (hd Result)))
             (stream-test.check "late error retains wire progress" (shen-jit.bytes-length (shen-jit.string->bytes Wire))
               (freeze (io.error-progress (hd (tl Result)))))
             (stream-test.check "failed stream has no terminator" false
               (freeze (= (shen-jit.bytes->string (shen-jit.string->bytes Wire)
                            (- (shen-jit.bytes-length (shen-jit.string->bytes Wire)) 5) 5)
                   "0c#13;c#10;c#13;c#10;")))
             (stream-test.check "late source cleanup once" 1 (freeze (<-address State 2))))))
  [[["a"] [length 2] []]
   [["a" "b"] [length 1] []]
   [["a" "b"] [chunked] [[response-body-limit 1]]]
   [["a" "b"] [chunked] [[response-chunk-count-limit 1]]]
   [["a" [error (io.error read "producer" "failed")]] [chunked] []]])

(let State (stream-test.state [])
     _ (address-> State 6 [error (io.error close "producer" "close failed")])
     Result (stream-test.send State "GET" 200 [length 1] [])
     Error (hd (tl Result))
  (do (stream-test.check "cleanup preserves initial failure" application (freeze (io.error-domain Error)))
      (stream-test.check "cleanup failure secondary" "close failed"
        (freeze (io.error-message (hd (io.error-secondary Error)))))
      (stream-test.check "cleanup still once" 1 (freeze (<-address State 2)))))

(let State (stream-test.state [])
     S (http.source (/. N D (do (address-> State 5 100) [eof])) (freeze (stream-test.close State)))
     E (stream-test.endpoint State)
     Result (http.send-response E (stream-test.request "GET")
              (http.stream-response 200 [] [chunked] S)
              (deadline.after (freeze (<-address State 5)) 100) [])
     _ (io.close E)
  (do (stream-test.check "callback uses total write deadline" [timeout 0]
        (freeze (stream-test.progress Result)))
      (stream-test.check "expired producer closes" 1 (freeze (<-address State 2)))))

(let State (stream-test.state ["a" "b"])
     E (io.endpoint "failing writer" write 3 (function io.no-read)
         (/. B (if (> (buffer.builder-length (<-address State 4)) 67)
                   [error (io.error write "failing writer" "forced")]
                   (do (buffer.append! (<-address State 4) (buffer.wrap B))
                       [written (shen-jit.bytes-length B)]))) (freeze [ok]))
     Result (http.send-response E (stream-test.request "GET")
              (http.stream-response 200 [] [chunked] (stream-test.source State))
              (deadline.after (freeze 0) 100) [])
     _ (io.close E)
  (do (stream-test.check "write failure retains partial progress" (buffer.builder-length (<-address State 4))
        (freeze (io.error-progress (hd (tl Result)))))
      (stream-test.check "no producer read ahead after write failure" 1 (freeze (<-address State 1)))
      (stream-test.check "write failure closes source" 1 (freeze (<-address State 2)))))

(let State (stream-test.state [])
     S (stream-test.source State)
     _ (http.source-close S)
     _ (http.source-close S)
  (stream-test.check "explicit close idempotent" 1 (freeze (<-address State 2))))

(map (/. Framing
       (let State (stream-test.state [])
            Result (stream-test.send State "GET" 200 Framing [])
         (do (stream-test.check "empty stream succeeds" ok (freeze (hd Result)))
             (stream-test.check "empty stream closes" 1 (freeze (<-address State 2))))))
  [[length 0] [chunked]])

(let State (stream-test.state [])
     _ (address-> State 6 [error (io.error close "producer" "late cleanup failed")])
     Result (stream-test.send State "GET" 200 [chunked] [])
  (stream-test.check "successful output keeps progress if cleanup fails"
    (buffer.builder-length (<-address State 4))
    (freeze (io.error-progress (hd (tl Result))))))

(let State (stream-test.state ["must not pull"])
     E (stream-test.endpoint State)
     Result (http.send-response E (stream-test.request "GET")
              (http.stream-response 200 [["X" "badc#13;c#10;injection"]] [chunked] (stream-test.source State))
              (deadline.after (freeze 0) 100) [])
     _ (io.close E)
  (do (stream-test.check "invalid metadata commits no bytes" [application 0]
        (freeze (stream-test.progress Result)))
      (stream-test.check "metadata rejected before producer call" 0 (freeze (<-address State 1)))
      (stream-test.check "invalid metadata still closes source" 1 (freeze (<-address State 2)))))

(define stream-test.contains-cause?
  X X -> true
  X [H | T] -> (or (stream-test.contains-cause? X H) (stream-test.contains-cause? X T))
  _ _ -> false)
(stream-test.check "expiry retains simultaneous producer failure" [timeout true 1]
  (freeze
    (let Time (io.record [0])
         Closed (io.record [0])
         Cause (io.error read "producer" "producer broke")
         S (http.source (/. Maximum D (do (address-> Time 0 10) [error Cause]))
                        (freeze (do (address-> Closed 0 (+ 1 (<-address Closed 0))) [ok])))
         E (io.output-buffer (buffer.new 256))
         D (deadline.after (freeze (<-address Time 0)) 10)
         Result (http.send-response E (stream-test.request "GET") (http.stream-response 200 [] [chunked] S) D [])
         Error (hd (tl Result))
         _ (io.close E)
      [(io.error-domain Error) (stream-test.contains-cause? Cause Error) (<-address Closed 0)])))

(output "~A passed, ~A failed~%" (value stream-test.passed) (value stream-test.failed))
