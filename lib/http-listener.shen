\\ Bounded HTTP connections over existing Shen threads. Load http-server.shen first.
\\ One supervisor owns admission and the registry; each worker publishes one final result.
\\ Stop and socket cancellation are monotonic flags. No shared read/modify/write queue is used.

(shen-jit.library http.wait-lib ["libc.so.6" "libSystem.dylib"])
(shen-jit.library http.wait-win ["kernel32.dll"])
(define-foreign http.c-pause http.wait-lib "poll" (pointer int64 int32) --> int32 blocking)
(define-foreign http.c-sleep http.wait-win "Sleep" (int32) --> void blocking)

(define http.pause
  Milliseconds ->
    (if (socket.windows?) (http.c-sleep Milliseconds) (http.c-pause [] 0 Milliseconds)))

(define http.listener-options
  Options -> (http.listener-config Options 16 1000 [] []))

(define http.listener-config
  [] Cap Grace Request _ ->
    (do (http.server-options Request) [Cap Grace Request])
  [[Name Value] | Rest] Cap Grace Request Seen ->
    (let _ (if (element? Name Seen) (error "http: duplicate listener option") true)
         N (buffer.index Value)
      (cases (= Name max-connections)
               (if (and (> N 0) (<= N 1024))
                   (http.listener-config Rest N Grace Request [Name | Seen])
                   (error "http: max-connections must be 1..1024"))
             (= Name shutdown-grace)
               (if (<= N 600000)
                   (http.listener-config Rest Cap N Request [Name | Seen])
                   (error "http: shutdown-grace must be 0..600000 ms"))
             true (http.listener-config Rest Cap Grace [[Name N] | Request] [Name | Seen])))
  _ _ _ _ _ -> (error "http: listener options must be [Name Number] pairs"))

\\ Public control: image guard, port, stop flag, immutable snapshot, final result.
\\ Private owner: listener token, workers, accepted/completed/failed/cancelled/peak,
\\ primary failure, grace deadline and phase. Only the supervisor writes this record.
(define http.listen
  Host Port Handler Options ->
    (let Config (http.listener-options Options)
         _ (clock.monotonic)
         _ (grammar.prepare http.<head>)
         L (socket.listen Host Port)
      (socket.closing-on-error L (freeze (http.listener-start L Handler Config)))))

(define http.listener-start
  L Handler Config ->
    (let Guard (shen-jit.bytes->pointer (shen-jit.u32! (shen-jit.bytes 8) 0 1) 0 http.server)
         S (io.record [http.server Guard (socket.port L) false
                       (io.record [listening 0 0 0 0 0 0]) []])
         O (io.record [(io.socket-token L) [] 0 0 0 0 0 [] [] listening])
         _ (thread (freeze (http.supervisor S O Handler Config)))
      S))

(define http.listener-check
  S ->
    (let _ (if (io.tag? S http.server) true (error "http: not a server"))
         _ (if (= (shen-jit.pointer-address (<-address S 1)) 0)
               (error "http: saved servers must be recreated") true)
      S))

(define http.port
  S -> (<-address (http.listener-check S) 2))

(define http.stop
  S -> (do (address-> (http.listener-check S) 3 true) true))

(define http.state
  S -> (<-address (<-address (http.listener-check S) 4) 0))

(define http.stats
  S ->
    (let V (<-address (http.listener-check S) 4)
      [(<-address V 1) (<-address V 2) (<-address V 3)
       (<-address V 4) (<-address V 5) (<-address V 6)]))

(define http.wait
  S Milliseconds ->
    (do (http.listener-check S) (http.wait-until S (clock.deadline Milliseconds))))

(define http.wait-until
  S D ->
    (let Result (<-address S 5)
      (cond ((not (empty? Result)) Result)
            ((deadline.expired? D) [pending])
            (true (do (http.pause (deadline.slice D 50)) (http.wait-until S D))))))

(define http.publish
  S O ->
    (address-> S 4 (io.record [(<-address O 9) (length (<-address O 1))
                              (<-address O 2) (<-address O 3) (<-address O 4)
                              (<-address O 5) (<-address O 6)])))

(define http.note-error
  O Error ->
    (let Previous (<-address O 7)
      (address-> O 7 (if (empty? Previous) Error (io.secondary Previous Error)))))

(define http.close-listener
  O ->
    (let Token (<-address O 0)
      (if (= (shen-jit.pointer-address Token) 0)
          true
          (http.listener-closed O (io.socket-close Token "HTTP listener")))))

(define http.listener-closed
  _ [ok] -> true
  O [error Error] -> (do (http.note-error O Error) true))

(define http.reap
  O -> (address-> O 1 (http.reap-workers O (<-address O 1) [])))

(define http.reap-workers
  _ [] Live -> (reverse Live)
  O [W | Rest] Live ->
    (let Result (<-address W 1)
      (if (empty? Result)
          (http.reap-workers O Rest [W | Live])
          (do (address-> O 3 (+ 1 (<-address O 3)))
              (http.count-failure O Result)
              (http.reap-workers O Rest Live)))))

(define http.count-failure
  _ [ok _] -> true
  O [error _] -> (do (address-> O 4 (+ 1 (<-address O 4))) true))

(define http.worker
  W Handler Options Stop ->
    (let E (<-address W 0)
         Result (io.with-endpoint E
                  (/. Connection (http.serve-controlled Connection Handler Options Stop)))
      (address-> W 1 Result)))

(define http.admit
  S O Handler Options ->
    (let Peer (socket.c-accept (io.socket-id (<-address O 0)) [] [])
         Code (if (< Peer 0) (io.socket-code) 0)
      (cond ((>= Peer 0)
              (if (<-address S 3)
                  (socket.close Peer)
                  (http.launch S O (socket.closing-on-error Peer (freeze (socket.set-up Peer)))
                               Handler Options)))
            ((io.socket-again? Code) true)
            (true (http.note-error O (io.socket-error accept "HTTP listener" Code))))))

(define http.launch
  S O Peer Handler Options ->
    (let E (io.socket Peer "HTTP peer")
         W (io.record [E []])
         Workers [W | (<-address O 1)]
         _ (address-> O 1 Workers)
         _ (address-> O 2 (+ 1 (<-address O 2)))
         N (length Workers)
         _ (if (> N (<-address O 6)) (address-> O 6 N) true)
      (trap-error (thread (freeze (http.worker W Handler Options (freeze (<-address S 3)))))
        (/. X (address-> W 1
                (io.finish [error (io.error thread "HTTP worker" (error-to-string X))] (io.close E)))))))

(define http.begin-stop
  O Grace ->
    (do (http.close-listener O)
        (address-> O 8 (clock.deadline Grace))
        (address-> O 9 draining)))

(define http.cancel-workers
  [] -> true
  [W | Rest] -> (do (io.socket-cancel (<-address W 0)) (http.cancel-workers Rest)))

(define http.supervise
  S O Handler [Cap Grace Options] ->
    (do (http.reap O)
        (if (and (= (<-address O 9) listening)
                 (or (<-address S 3) (not (empty? (<-address O 7)))))
            (http.begin-stop O Grace) true)
        (http.publish S O)
        (cond ((= (<-address O 9) listening)
                (do (if (< (length (<-address O 1)) Cap)
                        (if (socket.readable? (io.socket-id (<-address O 0)) 50)
                            (http.admit S O Handler Options) true)
                        (http.pause 50))
                    (http.supervise S O Handler [Cap Grace Options])))
              ((empty? (<-address O 1)) (http.finish-listener S O))
              ((and (= (<-address O 9) draining) (deadline.expired? (<-address O 8)))
                (do (http.cancel-workers (<-address O 1))
                    (address-> O 5 (length (<-address O 1)))
                    (address-> O 9 cancelling)
                    (http.supervise S O Handler [Cap Grace Options])))
              (true (do (http.pause 50) (http.supervise S O Handler [Cap Grace Options]))))))

(define http.finish-listener
  S O ->
    (let _ (http.close-listener O)
         _ (address-> O 9 stopped)
         _ (http.publish S O)
         Error (<-address O 7)
      (address-> S 5 (if (empty? Error) [ok] [error Error]))))

(define http.supervisor
  S O Handler Config ->
    (trap-error (http.supervise S O Handler Config)
      (/. X (do (http.note-error O (io.error serve "HTTP listener" (error-to-string X)))
                (http.close-listener O)
                (http.cancel-workers (<-address O 1))
                (address-> O 5 (length (<-address O 1)))
                (address-> O 9 cancelling)
                (http.supervise S O Handler Config)))))

(datatype http-listener-results
  ___________________________
  [ok] : http.wait-result;

  ___________________________
  [pending] : http.wait-result;

  Error : io.error;
  ___________________________
  [error Error] : http.wait-result;)

(datatype http-listener-options
  N : number;
  =================================
  [max-connections N] : http.listener-option;

  N : number;
  =================================
  [shutdown-grace N] : http.listener-option;

  Option : http.option;
  =================================
  Option : http.listener-option;)

(declare http.listen
  [string --> [number --> [[http.request --> http.response] -->
    [[list http.listener-option] --> http.server]]]])
(declare http.port [http.server --> number])
(declare http.stop [http.server --> boolean])
(declare http.state [http.server --> symbol])
(declare http.stats [http.server --> [list number]])
(declare http.wait [http.server --> [number --> http.wait-result]])
