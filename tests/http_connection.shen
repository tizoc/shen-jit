\\ Persistent connections retain one reader and dispatch complete requests in wire order. Each case writes
\\ its requests, which fit the socket's buffers, then serves the connection to its end, then reads.
(set connection-test.passed 0)
(set connection-test.failed 0)

(define connection-test.check
  Name Expected F ->
    (let Actual (trap-error (thaw F) (/. X [raised (error-to-string X)]))
      (if (= Actual Expected)
          (set connection-test.passed (+ 1 (value connection-test.passed)))
          (do (set connection-test.failed (+ 1 (value connection-test.failed)))
              (output "FAIL ~A: wanted ~S, got ~S~%" Name Expected Actual)))))

(define connection-test.handler
  Calls Q ->
    (do (address-> Calls 0 [(http.target Q) | (<-address Calls 0)])
        (http.response 200 [["Date" "Sun, 06 Nov 1994 08:49:37 GMT"]]
          (buffer.from-string (http.target Q)))))

(define connection-test.start
  Options Handler ->
    (let L (socket.listen "127.0.0.1" 0)
         C (io.socket (socket.connect "127.0.0.1" (socket.port L)) "persistent client")
         E (io.socket (socket.accept L) "persistent server")
         _ (socket.close L)
         _ (io.socket-deadline C (clock.deadline 3000))
      [C (freeze (http.serve-connection E Handler Options))]))

(define connection-test.serve
  Pair -> (thaw (hd (tl Pair))))

(define connection-test.all
  E ->
    (let Wire (connection-test.collect (io.reader E []) 0 [])
         _ (io.close E)
      (buffer.string Wire)))

(define connection-test.collect
  R Total Chunks -> (connection-test.chunk R Total Chunks (io.read-chunk R)))

\\ An intentional close with unread pipeline input can reset after already delivered bytes.
(define connection-test.chunk
  R Total Chunks [chunk V] ->
    (connection-test.collect R (+ Total (buffer.length V)) [V | Chunks])
  _ Total Chunks [eof] -> (io.join Total (reverse Chunks))
  _ Total Chunks [error Error] ->
    (if (= (io.error-code Error) (socket.by-os 104 54 10054))
        (io.join Total (reverse Chunks))
        (error "client read failed: ~A" (io.error-message Error))))

(define connection-test.response
  Target Close ->
    (make-string "HTTP/1.1 200 OKc#13;c#10;Date: Sun, 06 Nov 1994 08:49:37 GMTc#13;c#10;Content-Length: 2c#13;c#10;~Ac#13;c#10;~A"
      (if Close "Connection: closec#13;c#10;" "") Target))

(map (/. Capacity
       (let Calls (io.record [[]])
            Pair (connection-test.start [[read-buffer-size Capacity]] (/. Q (connection-test.handler Calls Q)))
            E (hd Pair)
            _ (io.write-all E (buffer.from-string
                 "POST /a HTTP/1.1c#13;c#10;Host: localc#13;c#10;Transfer-Encoding: chunkedc#13;c#10;c#13;c#10;1c#13;c#10;xc#13;c#10;0c#13;c#10;c#13;c#10;GET /b HTTP/1.1c#13;c#10;Host: localc#13;c#10;Connection: CLOSEc#13;c#10;c#13;c#10;") [])
            Result (connection-test.serve Pair)
            Wire (connection-test.all E)
         (do (connection-test.check "pipeline response order and connection fields"
               (cn (connection-test.response "/a" false) (connection-test.response "/b" true)) (freeze Wire))
             (connection-test.check "close token stops dispatch" ["/b" "/a"] (freeze (<-address Calls 0)))
             (connection-test.check "connection returns total acknowledged bytes"
               [ok (shen-jit.bytes-length (shen-jit.string->bytes Wire))] (freeze Result)))))
  [1 7 8192 16384 65536])

(let Calls (io.record [[]])
     Pair (connection-test.start [[request-limit 1]] (/. Q (connection-test.handler Calls Q)))
     E (hd Pair)
     _ (io.write-all E (buffer.from-string
          "GET /a HTTP/1.1c#13;c#10;Host: localc#13;c#10;c#13;c#10;GET /b HTTP/1.1c#13;c#10;Host: localc#13;c#10;c#13;c#10;") [])
     _ (connection-test.serve Pair)
     Wire (connection-test.all E)
  (do (connection-test.check "request cap marks final response closing" (connection-test.response "/a" true) (freeze Wire))
      (connection-test.check "request cap never dispatches queued excess" ["/a"] (freeze (<-address Calls 0)))))

(map (/. Options
       (let Calls (io.record [[]])
            Pair (connection-test.start Options (/. Q (connection-test.handler Calls Q)))
            E (hd Pair)
            _ (io.write-all E (buffer.from-string "GET /a HTTP/1.1c#13;c#10;Host: localc#13;c#10;c#13;c#10;") [])
            Result (connection-test.serve Pair)
            Wire (connection-test.all E)
         (do (connection-test.check "unused connection expiry adds no 408" (connection-test.response "/a" false) (freeze Wire))
             (connection-test.check "unused connection expiry succeeds" ok (freeze (hd Result))))))
  [[[idle-timeout 100]] [[connection-timeout 200]]])

(let Calls (io.record [[]])
     Pair (connection-test.start [] (/. Q (connection-test.handler Calls Q)))
     E (hd Pair)
     _ (io.write-all E (buffer.from-string
          "GET /a HTTP/1.1c#13;c#10;Host: localc#13;c#10;c#13;c#10;POST /b HTTP/1.1c#13;c#10;Host: localc#13;c#10;Transfer-Encoding: chunkedc#13;c#10;c#13;c#10;Qc#13;c#10;GET /c HTTP/1.1c#13;c#10;Host: localc#13;c#10;c#13;c#10;") [])
     Result (connection-test.serve Pair)
     Wire (connection-test.all E)
  (do (connection-test.check "malformed second body ends connection" error (freeze (hd Result)))
      (connection-test.check "no pipeline dispatch after framing failure" ["/a"] (freeze (<-address Calls 0)))
      (connection-test.check "successful first response preserved" (connection-test.response "/a" false)
        (freeze (shen-jit.bytes->string (shen-jit.string->bytes Wire) 0
                  (shen-jit.bytes-length (shen-jit.string->bytes (connection-test.response "/a" false))))))))

(let Closed (io.record [0])
     Pair (connection-test.start []
            (/. Q (http.stream-response 200 [] [chunked]
                    (http.source (/. N D [chunk (buffer.new 0)])
                      (freeze (do (address-> Closed 0 (+ 1 (<-address Closed 0))) [ok]))))))
     E (hd Pair)
     _ (io.write-all E (buffer.from-string "GET /a HTTP/1.1c#13;c#10;Host: localc#13;c#10;c#13;c#10;") [])
     Result (connection-test.serve Pair)
     Wire (connection-test.all E)
  (do (connection-test.check "producer preflight sends 500" "HTTP/1.1 500 "
        (freeze (shen-jit.bytes->string (shen-jit.string->bytes Wire) 0 13)))
      (connection-test.check "producer preflight failure remains local error" error (freeze (hd Result)))
      (connection-test.check "producer preflight closes once" 1 (freeze (<-address Closed 0)))))

(define connection-test.stopper
  Q -> (do (http.stop (http.current-server)) (http.response 200 [] (buffer.new 0))))

\\ A handler's stop: its response is written, then the persistent connection closes.
(let S (http.listen "127.0.0.1" 0 connection-test.stopper [[shutdown-grace 1000]])
     C (socket.connect "127.0.0.1" (http.port S))
     _ (socket.send C "GET / HTTP/1.1c#13;c#10;Host: localc#13;c#10;c#13;c#10;")
     Result (http.run S)
     Reply (socket.recv C 4096)
     EOF (socket.recv C 1)
     _ (socket.close C)
  (do (connection-test.check "stop from a handler ends the run" [ok] (freeze Result))
      (connection-test.check "stopped after its connection" [0 1 1 0 0 1] (freeze (http.stats S)))
      (connection-test.check "the stopping response is written" "HTTP/1.1 200"
        (freeze (shen-jit.bytes->string Reply 0 12)))
      (connection-test.check "then the persistent connection closes" 0 (freeze (shen-jit.bytes-length EOF)))))

(output "~A passed, ~A failed~%" (value connection-test.passed) (value connection-test.failed))
