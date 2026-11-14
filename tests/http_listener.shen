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

(define listener-test.available
  -> (trap-error (do (clock.monotonic) true)
       (/. X (if (= (error-to-string X) "foreign: this static build cannot load libraries")
                 false (simple-error (error-to-string X))))))

(if (listener-test.available) true
    (do (output "0 passed, 0 failed (static build: native listener unavailable)~%") (shen-jit.exit 0)))

(define listener-test.listen
  Options -> (http.listen "127.0.0.1" 0 listener-test.handler Options))

(define listener-test.client
  S -> (socket.connect "127.0.0.1" (http.port S)))

(define listener-test.two
  X Q -> Q)

\\ Handlers run in the connections' isolates. /stop stops the server, /fail fails, and /tag, /port
\\ and /stats give the handler's argument, its server's port and what its server's stats raise.
(define listener-test.handler
  Q -> (listener-test.tagged "ok" Q))

(define listener-test.tagged
  Tag Q -> (let Target (http.target Q)
             (cases (= Target "/stop") (do (http.stop (http.current-server)) (listener-test.text "ok"))
                    (= Target "/fail") (error "handler failed")
                    (= Target "/tag") (listener-test.text Tag)
                    (= Target "/port") (listener-test.text (str (http.port (http.current-server))))
                    (= Target "/stats") (listener-test.text (trap-error (str (http.stats (http.current-server)))
                                                              (/. X (error-to-string X))))
                    true (listener-test.text "ok"))))

(define listener-test.text
  Text -> (http.response 200 [] (buffer.from-string Text)))

\\ A client, in an isolate of its own while the caller of http.run serves: each step is a connection,
\\ taken in turn, and it sends back what each gave. [get Target] gives [Status Body]; [stall Target]
\\ opens a connection that sends half a head and waits, takes [get Target], then reads what the
\\ first connection gets until it ends.
(define listener-test.client-isolate
  [Port Steps Out] -> (channel.send Out (map (/. Step (trap-error (listener-test.step Port Step)
                                                         (/. X [raised (error-to-string X)])))
                                              Steps)))

(define listener-test.step
  Port [get Target] -> (listener-test.get Port Target)
  Port [stall Target] -> (let A (socket.connect "127.0.0.1" Port)
                              _ (socket.send A "GET / HTTP/1.1c#13;c#10;")
                              Reply (listener-test.get Port Target)
                           [Reply (listener-test.read A)]))

(define listener-test.get
  Port Target ->
    (let C (socket.connect "127.0.0.1" Port)
         _ (socket.send C (make-string "GET ~A HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;Connection: closec#13;c#10;c#13;c#10;" Target))
      (listener-test.read C)))

\\ Everything until the end: [Status Body], or [] if there was nothing.
(define listener-test.read
  C -> (listener-test.parse (io.with-endpoint (io.socket C "listener test client")
                              (/. Peer (io.read-all (io.reader Peer []) 4096)))))

(define listener-test.parse
  [ok V] -> (let B (shen-jit.string->bytes (buffer.string V))
                 N (shen-jit.bytes-length B)
              (if (= N 0) [] (listener-test.split B N 0)))
  [error Error] -> (error "client read: ~A" (io.error-message Error)))

(define listener-test.split
  B N At -> (cond ((> (+ At 4) N) [(shen-jit.bytes->string B 9 3) ""])
                  ((and (= (shen-jit.u8 B At) 13) (= (shen-jit.u8 B (+ At 1)) 10)
                        (= (shen-jit.u8 B (+ At 2)) 13) (= (shen-jit.u8 B (+ At 3)) 10))
                    [(shen-jit.bytes->string B 9 3) (shen-jit.bytes->string B (+ At 4) (- N (+ At 4)))])
                  (true (listener-test.split B N (+ At 1)))))

\\ Runs S while a client takes Steps, and gives [Result Stats Replies] once the client has ended.
(define listener-test.serve
  S Steps -> (let R (channel.new 1)
                  P (isolate.spawn listener-test.client-isolate [(http.port S) Steps (channel.sender R)])
                  M (isolate.monitor P)
                  Result (http.run S)
                  Got (channel.receive-any [R M])
                  _ (if (= (hd Got) R) (channel.receive M) true)
               [Result (http.stats S) (if (= (hd Got) R) (hd (tl Got)) [client (hd (tl Got))])]))

(map (/. Options
       (listener-test.check "invalid options rejected" true
         (freeze (listener-test.raises? (freeze (listener-test.listen Options))))))
  [[[max-connections 0]] [[max-connections 1025]] [[shutdown-grace -1]]
   [[shutdown-grace 600001]] [[unknown 1]] [[max-connections 2] [max-connections 3]]
   [[body-limit -1]] [[head-limit 3]] [[max-connections nope]]
   [[read-buffer-size 0]] [[read-buffer-size 65537]] [[read-buffer-size -1]]
   [[read-buffer-size 1] [read-buffer-size 2]]])

(map (/. Handler
       (listener-test.check "invalid handlers rejected" true
         (freeze (listener-test.raises? (freeze (http.listen "127.0.0.1" 0 Handler []))))))
  [(/. Q Q) (function listener-test.handler) [] [1 2] "f" listener-test.two [listener-test.handler 1]])

(let S (listener-test.listen [[shutdown-grace 0]])
     Before (http.wait S 0)
     _ (http.stop S)
     _ (http.stop S)
     Result (http.run S)
  (do (listener-test.check "nothing runs before http.run" [pending] (freeze Before))
      (listener-test.check "empty listener stops" [ok] (freeze Result))
      (listener-test.check "without making its events channel" [] (freeze (http.server.events S)))
      (listener-test.check "stopped state" stopped (freeze (http.state S)))
      (listener-test.check "empty statistics" [0 0 0 0 0 0] (freeze (http.stats S)))
      (listener-test.check "wait gives the final result" [ok] (freeze (http.wait S 0)))
      (listener-test.check "run again gives it too" [ok] (freeze (http.run S)))
      (listener-test.check "listener port is closed" true
        (freeze (listener-test.raises? (freeze (listener-test.client S)))))))

\\ A connection waiting for its head does not hold the next one back, and is killed once the grace
\\ has passed: counted as failed and as cancelled.
(let Run (listener-test.serve (listener-test.listen [[shutdown-grace 0]]) [[stall "/stop"]])
  (do (listener-test.check "a stalled connection stops nothing" [ok] (freeze (hd Run)))
      (listener-test.check "the next is served meanwhile" [[["200" "ok"] []]] (freeze (nth 3 Run)))
      (listener-test.check "the stalled one is killed" [0 2 2 1 1 2] (freeze (nth 2 Run)))))

\\ At most max-connections at once: the next waits until the stalled one times out, with a 408.
(let Run (listener-test.serve (listener-test.listen [[max-connections 1] [head-timeout 300]])
           [[stall "/stop"]])
  (do (listener-test.check "a full listener waits" [[["200" "ok"] ["408" ""]]] (freeze (nth 3 Run)))
      (listener-test.check "one connection at a time" [0 2 2 1 0 1] (freeze (nth 2 Run)))))

(let Run (listener-test.serve (listener-test.listen []) [[get "/fail"] [get "/ok"] [get "/stop"]])
  (do (listener-test.check "handler failure does not stop admission" [["500" ""] ["200" "ok"] ["200" "ok"]]
        (freeze (nth 3 Run)))
      (listener-test.check "server survives a failed connection" [ok] (freeze (hd Run)))
      (listener-test.check "request failure is counted separately" [0 3 3 1 0]
        (freeze (reverse (tl (reverse (nth 2 Run))))))))

(let S (http.listen "127.0.0.1" 0 [listener-test.tagged "tagged"] [])
     Run (listener-test.serve S [[get "/tag"] [get "/port"] [get "/stats"] [get "/stop"]])
  (listener-test.check "a handler's arguments and its server"
    [["200" "tagged"] ["200" (str (http.port S))]
     ["200" "http: a handler's server gives only its port, and stops"] ["200" "ok"]]
    (freeze (nth 3 Run))))

(listener-test.check "no handler runs in the caller" [raised "http: no handler runs here"]
  (freeze (http.current-server)))

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
