(set listener-test.passed 0)
(set listener-test.failed 0)

(define listener-test.check
  Name Expected F ->
    (let Actual (trap-error (thaw F) (/. X [raised (error-to-string X)]))
      (if (= Actual Expected)
          (set listener-test.passed (+ 1 (value listener-test.passed)))
          (do (set listener-test.failed (+ 1 (value listener-test.failed)))
              (output "FAIL ~A: wanted ~S, got ~S~%" Name Expected Actual)))))

(define listener-test.raises?
  F -> (trap-error (do (thaw F) false) (/. X true)))

(define listener-test.handler
  Q -> (http.response 200 [] (buffer.from-string "ok")))

(define listener-test.available
  -> (trap-error (do (clock.monotonic) true)
       (/. X (if (= (error-to-string X) "foreign: this static build cannot load libraries")
                 false (simple-error (error-to-string X))))))

(if (listener-test.available) true
    (do (output "0 passed, 0 failed (static build: native listener unavailable)~%") (shen-jit.exit 0)))

(define listener-test.listen
  Options -> (http.listen "127.0.0.1" 0 (function listener-test.handler) Options))

(define listener-test.client
  S -> (socket.connect "127.0.0.1" (http.port S)))

(define listener-test.request
  S Target ->
    (let C (listener-test.client S)
         _ (socket.closing-on-error C
             (freeze (socket.send C (make-string "GET ~A HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;Connection: closec#13;c#10;c#13;c#10;" Target))))
      C))

(define listener-test.reply
  C -> (listener-test.body (io.with-endpoint (io.socket C "listener test client")
                             (/. Peer (io.read-all (io.reader Peer []) 4096)))))

(define listener-test.body
  [ok V] ->
    (let B (buffer.owner V)
         N (buffer.length V)
      (shen-jit.bytes->string B (- N 2) 2))
  [error Error] -> (error "client read: ~A" (io.error-message Error)))

\\ The server a handler stops, once it has answered Count requests.
(set listener-test.server [])
(set listener-test.count 0)

(define listener-test.stop-after
  Count Q -> (do (set listener-test.count (+ 1 (value listener-test.count)))
                 (if (= (value listener-test.count) Count) (http.stop (value listener-test.server)) true)
                 (if (= (http.target Q) "/fail") (error "handler failed") (listener-test.handler Q))))

(define listener-test.serving
  Count Options -> (let _ (set listener-test.count 0)
                        S (http.listen "127.0.0.1" 0 (/. Q (listener-test.stop-after Count Q)) Options)
                        _ (set listener-test.server S)
                     S))

(map (/. Options
       (listener-test.check "invalid options rejected" true
         (freeze (listener-test.raises? (freeze (listener-test.listen Options))))))
  [[[max-connections 0]] [[max-connections 1025]] [[shutdown-grace -1]]
   [[shutdown-grace 600001]] [[unknown 1]] [[max-connections 2] [max-connections 3]]
   [[body-limit -1]] [[head-limit 3]] [[max-connections nope]]
   [[read-buffer-size 0]] [[read-buffer-size 65537]] [[read-buffer-size -1]]
   [[read-buffer-size 1] [read-buffer-size 2]]])

(let S (listener-test.listen [[shutdown-grace 0]])
     Before (http.wait S 0)
     _ (http.stop S)
     _ (http.stop S)
     Result (http.run S)
  (do (listener-test.check "nothing runs before http.run" [pending] (freeze Before))
      (listener-test.check "empty listener stops" [ok] (freeze Result))
      (listener-test.check "stopped state" stopped (freeze (http.state S)))
      (listener-test.check "empty statistics" [0 0 0 0 0 0] (freeze (http.stats S)))
      (listener-test.check "wait gives the final result" [ok] (freeze (http.wait S 0)))
      (listener-test.check "run again gives it too" [ok] (freeze (http.run S)))
      (listener-test.check "listener port is closed" true
        (freeze (listener-test.raises? (freeze (listener-test.client S)))))))

\\ Connections queued before the run are served one at a time, in order.
(let S (listener-test.serving 3 [[max-connections 2]])
     A (listener-test.request S "/a")
     B (listener-test.request S "/b")
     C (listener-test.request S "/c")
     Result (http.run S)
  (do (listener-test.check "connections served in turn" [ok] (freeze Result))
      (listener-test.check "served in turn, one at a time" [0 3 3 0 0 1] (freeze (http.stats S)))
      (listener-test.check "every reply is complete" ["ok" "ok" "ok"]
        (freeze (map (function listener-test.reply) [A B C])))))

(let S (listener-test.serving 2 [])
     Bad (listener-test.request S "/fail")
     Good (listener-test.request S "/ok")
     Result (http.run S)
     Reply (listener-test.reply Good)
     _ (socket.close Bad)
  (do (listener-test.check "handler failure does not stop admission" "ok" (freeze Reply))
      (listener-test.check "server survives a failed connection" [ok] (freeze Result))
      (listener-test.check "request failure is counted separately" [0 2 2 1 0 1] (freeze (http.stats S)))))

(define listener-test.progress
  [error Error N] -> [(io.error-domain Error) N (io.error-progress Error)])

(let L (socket.listen "127.0.0.1" 0)
     C (io.socket (socket.connect "127.0.0.1" (socket.port L)) "cancel client")
     E (io.socket (socket.accept L) "cancel server")
     _ (socket.close L)
     _ (io.write-all E (buffer.from-string "abc") [])
     _ (io.socket-cancel C)
     V (buffer.new 4)
     Read (io.read-exact C V [])
     _ (io.socket-unlimited C)
     _ (io.socket-deadline C (clock.deadline 1000))
  (do (listener-test.check "a cancelled socket reads nothing" [cancelled 0 0]
        (freeze (listener-test.progress Read)))
      (listener-test.check "new deadline does not undo cancellation" [cancelled 0 0]
        (freeze (listener-test.progress (io.write-all C (buffer.from-string "x") []))))
      (io.close C)
      (listener-test.check "cancelling an already closed socket is harmless" true
        (freeze (io.socket-cancel C)))
      (io.close E)))

\\ A listener failure ends the run with its error, and closes the listener.
(set listener-test.poll-failure false)
(define socket.readable?
  S N -> (if (value listener-test.poll-failure)
             (error "forced listener poll failure")
             (socket.wait-for S (socket.readable-event) N)))

(let S (listener-test.listen [])
     _ (set listener-test.poll-failure true)
     Result (http.run S)
     _ (set listener-test.poll-failure false)
  (do (listener-test.check "listener error is retained" serve
        (freeze (io.error-operation (hd (tl Result)))))
      (listener-test.check "listener error stops it" stopped (freeze (http.state S)))
      (listener-test.check "listener error closes listener" true
        (freeze (listener-test.raises? (freeze (listener-test.client S)))))))

(output "~A passed, ~A failed~%" (value listener-test.passed) (value listener-test.failed))
