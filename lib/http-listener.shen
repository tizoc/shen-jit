\\ Bounded HTTP connections over existing Shen threads. Load http-server.shen first.
\\ One supervisor owns admission and the registry; each worker publishes one final result.
\\ Stop and socket cancellation are monotonic flags. No shared read/modify/write queue is used.

(shen.x.namespace http
  (use buffer)
  (use clock)
  (use deadline)
  (use grammar)
  (use io)
  (use shen-jit)
  (use socket)
  (externals [accept blocking cancelling define-foreign draining http-listener-options
    http-listener-results int32 int64 listening max-connections ok pending pointer serve
    shutdown-grace stopped thread void])
  (shadow port)
  (export listen listener-option option port request response server state stats stop wait
    wait-result)

(shen-jit.library wait-lib ["libc.so.6" "libSystem.dylib"])
(shen-jit.library wait-win ["kernel32.dll"])
(define-foreign c-pause wait-lib "poll" (pointer int64 int32) --> int32 blocking)
(define-foreign c-sleep wait-win "Sleep" (int32) --> void blocking)

(define pause
  Milliseconds ->
    (if (socket.windows?) (c-sleep Milliseconds) (c-pause [] 0 Milliseconds)))

(define listener-options
  Options -> (listener-config Options 16 1000 [] []))

(define listener-config
  [] Cap Grace Request _ ->
    (do (server-options Request) [Cap Grace Request])
  [[Name Value] | Rest] Cap Grace Request Seen ->
    (let _ (if (element? Name Seen) (error "http: duplicate listener option") true)
         N (buffer.index Value)
      (cases (= Name max-connections)
               (if (and (> N 0) (<= N 1024))
                   (listener-config Rest N Grace Request [Name | Seen])
                   (error "http: max-connections must be 1..1024"))
             (= Name shutdown-grace)
               (if (<= N 600000)
                   (listener-config Rest Cap N Request [Name | Seen])
                   (error "http: shutdown-grace must be 0..600000 ms"))
             true (listener-config Rest Cap Grace [[Name N] | Request] [Name | Seen])))
  _ _ _ _ _ -> (error "http: listener options must be [Name Number] pairs"))

\\ Public control: image guard, port, stop flag, immutable snapshot, final result.
\\ Private owner: listener token, workers, accepted/completed/failed/cancelled/peak,
\\ primary failure, grace deadline and phase. Only the supervisor writes this record.
(define listen
  Host Port Handler Options ->
    (let Config (listener-options Options)
         _ (clock.monotonic)
         _ (grammar.prepare <head>)
         L (socket.listen Host Port)
      (socket.closing-on-error L (freeze (listener-start L Handler Config)))))

(define listener-start
  L Handler Config ->
    (let Guard (shen-jit.bytes->pointer (shen-jit.u32! (shen-jit.bytes 8) 0 1) 0 server)
         S (io.record [server Guard (socket.port L) false
                       (io.record [listening 0 0 0 0 0 0]) []])
         O (io.record [(io.socket-token L) [] 0 0 0 0 0 [] [] listening])
         _ (thread (freeze (supervisor S O Handler Config)))
      S))

(define listener-check
  S ->
    (let _ (if (io.tag? S server) true (error "http: not a server"))
         _ (if (= (shen-jit.pointer-address (<-address S 1)) 0)
               (error "http: saved servers must be recreated") true)
      S))

(define port
  S -> (<-address (listener-check S) 2))

(define stop
  S -> (do (address-> (listener-check S) 3 true) true))

(define state
  S -> (<-address (<-address (listener-check S) 4) 0))

(define stats
  S ->
    (let V (<-address (listener-check S) 4)
      [(<-address V 1) (<-address V 2) (<-address V 3)
       (<-address V 4) (<-address V 5) (<-address V 6)]))

(define wait
  S Milliseconds ->
    (do (listener-check S) (wait-until S (clock.deadline Milliseconds))))

(define wait-until
  S D ->
    (let Result (<-address S 5)
      (cond ((not (empty? Result)) Result)
            ((deadline.expired? D) [pending])
            (true (do (pause (deadline.slice D 50)) (wait-until S D))))))

(define publish
  S O ->
    (address-> S 4 (io.record [(<-address O 9) (length (<-address O 1))
                              (<-address O 2) (<-address O 3) (<-address O 4)
                              (<-address O 5) (<-address O 6)])))

(define note-error
  O Error ->
    (let Previous (<-address O 7)
      (address-> O 7 (if (empty? Previous) Error (io.secondary Previous Error)))))

(define close-listener
  O ->
    (let Token (<-address O 0)
      (if (= (shen-jit.pointer-address Token) 0)
          true
          (listener-closed O (io.socket-close Token "HTTP listener")))))

(define listener-closed
  _ [ok] -> true
  O [error Error] -> (do (note-error O Error) true))

(define reap
  O -> (address-> O 1 (reap-workers O (<-address O 1) [])))

(define reap-workers
  _ [] Live -> (reverse Live)
  O [W | Rest] Live ->
    (let Result (<-address W 1)
      (if (empty? Result)
          (reap-workers O Rest [W | Live])
          (do (address-> O 3 (+ 1 (<-address O 3)))
              (count-failure O Result)
              (reap-workers O Rest Live)))))

(define count-failure
  _ [ok _] -> true
  O [error _] -> (do (address-> O 4 (+ 1 (<-address O 4))) true))

(define worker
  W Handler Options Stop ->
    (let E (<-address W 0)
         Result (io.with-endpoint E
                  (/. Connection (serve-controlled Connection Handler Options Stop)))
      (address-> W 1 Result)))

(define admit
  S O Handler Options ->
    (let Peer (socket.c-accept (io.socket-id (<-address O 0)) [] [])
         Code (if (< Peer 0) (io.socket-code) 0)
      (cond ((>= Peer 0)
              (if (<-address S 3)
                  (socket.close Peer)
                  (launch S O (socket.closing-on-error Peer (freeze (socket.set-up Peer)))
                               Handler Options)))
            ((io.socket-again? Code) true)
            (true (note-error O (io.socket-error accept "HTTP listener" Code))))))

(define launch
  S O Peer Handler Options ->
    (let E (io.socket Peer "HTTP peer")
         W (io.record [E []])
         Workers [W | (<-address O 1)]
         _ (address-> O 1 Workers)
         _ (address-> O 2 (+ 1 (<-address O 2)))
         N (length Workers)
         _ (if (> N (<-address O 6)) (address-> O 6 N) true)
      (trap-error (thread (freeze (worker W Handler Options (freeze (<-address S 3)))))
        (/. X (address-> W 1
                (io.finish [error (io.error thread "HTTP worker" (error-to-string X))] (io.close E)))))))

(define begin-stop
  O Grace ->
    (do (close-listener O)
        (address-> O 8 (clock.deadline Grace))
        (address-> O 9 draining)))

(define cancel-workers
  [] -> true
  [W | Rest] -> (do (io.socket-cancel (<-address W 0)) (cancel-workers Rest)))

(define supervise
  S O Handler [Cap Grace Options] ->
    (do (reap O)
        (if (and (= (<-address O 9) listening)
                 (or (<-address S 3) (not (empty? (<-address O 7)))))
            (begin-stop O Grace) true)
        (publish S O)
        (cond ((= (<-address O 9) listening)
                (do (if (< (length (<-address O 1)) Cap)
                        (if (socket.readable? (io.socket-id (<-address O 0)) 50)
                            (admit S O Handler Options) true)
                        (pause 50))
                    (supervise S O Handler [Cap Grace Options])))
              ((empty? (<-address O 1)) (finish-listener S O))
              ((and (= (<-address O 9) draining) (deadline.expired? (<-address O 8)))
                (do (cancel-workers (<-address O 1))
                    (address-> O 5 (length (<-address O 1)))
                    (address-> O 9 cancelling)
                    (supervise S O Handler [Cap Grace Options])))
              (true (do (pause 50) (supervise S O Handler [Cap Grace Options]))))))

(define finish-listener
  S O ->
    (let _ (close-listener O)
         _ (address-> O 9 stopped)
         _ (publish S O)
         Error (<-address O 7)
      (address-> S 5 (if (empty? Error) [ok] [error Error]))))

(define supervisor
  S O Handler Config ->
    (trap-error (supervise S O Handler Config)
      (/. X (do (note-error O (io.error serve "HTTP listener" (error-to-string X)))
                (close-listener O)
                (cancel-workers (<-address O 1))
                (address-> O 5 (length (<-address O 1)))
                (address-> O 9 cancelling)
                (supervise S O Handler Config)))))

(datatype http-listener-results
  ___________________________
  [ok] : wait-result;

  ___________________________
  [pending] : wait-result;

  Error : io.error;
  ___________________________
  [error Error] : wait-result;)

(datatype http-listener-options
  N : number;
  =================================
  [max-connections N] : listener-option;

  N : number;
  =================================
  [shutdown-grace N] : listener-option;

  Option : option;
  =================================
  Option : listener-option;)

(declare listen
  [string --> [number --> [[request --> response] -->
    [[list listener-option] --> server]]]])
(declare port [server --> number])
(declare stop [server --> boolean])
(declare state [server --> symbol])
(declare stats [server --> [list number]])
(declare wait [server --> [number --> wait-result]])

)
