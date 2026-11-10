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
  (import struct defstruct)
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
\\ Private registry: listener token, workers, accepted/completed/failed/cancelled/peak,
\\ primary failure, grace deadline and phase. Only the supervisor writes the registry.
(define show-server
  S -> (make-string "#<http server port ~A ~A>" (server.port S) (snapshot.phase (server.snapshot S))))

(defstruct server
  (printer show-server)
  guard
  port
  (mutable stopping)
  (mutable snapshot)
  (mutable result))

(defstruct snapshot
  phase
  live
  accepted
  completed
  failed
  cancelled
  peak)

(define show-registry
  O -> (make-string "#<http listener ~A>" (registry.phase O)))

(defstruct registry
  (printer show-registry)
  token
  (mutable workers)
  (mutable accepted)
  (mutable completed)
  (mutable failed)
  (mutable cancelled)
  (mutable peak)
  (mutable error)
  (mutable grace)
  (mutable phase))

\\ A worker: its endpoint and, once it has finished, its result.
(define show-task
  W -> (if (empty? (task.result W)) "#<http worker running>" "#<http worker done>"))

(defstruct task
  (printer show-task)
  endpoint
  (mutable result))

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
         S (:server
             guard <- Guard
             port <- (socket.port L)
             stopping <- false
             snapshot <- (:snapshot
                           phase <- listening
                           live <- 0
                           accepted <- 0
                           completed <- 0
                           failed <- 0
                           cancelled <- 0
                           peak <- 0)
             result <- [])
         O (:registry
             token <- (io.socket-token L)
             workers <- []
             accepted <- 0
             completed <- 0
             failed <- 0
             cancelled <- 0
             peak <- 0
             error <- []
             grace <- []
             phase <- listening)
         _ (thread (freeze (supervisor S O Handler Config)))
      S))

(define listener-check
  S ->
    (let _ (if (server? S) true (error "http: not a server"))
         _ (if (= (shen-jit.pointer-address (server.guard S)) 0)
               (error "http: saved servers must be recreated") true)
      S))

(define port
  S -> (server.port (listener-check S)))

(define stop
  S -> (do (server.stopping-> (listener-check S) true) true))

(define state
  S -> (snapshot.phase (server.snapshot (listener-check S))))

(define stats
  S ->
    (let V (server.snapshot (listener-check S))
      [(snapshot.live V) (snapshot.accepted V) (snapshot.completed V)
       (snapshot.failed V) (snapshot.cancelled V) (snapshot.peak V)]))

(define wait
  S Milliseconds ->
    (do (listener-check S) (wait-until S (clock.deadline Milliseconds))))

(define wait-until
  S D ->
    (let Result (server.result S)
      (cond ((not (empty? Result)) Result)
            ((deadline.expired? D) [pending])
            (true (do (pause (deadline.slice D 50)) (wait-until S D))))))

(define publish
  S O ->
    (server.snapshot-> S (:snapshot
                           phase <- (registry.phase O)
                           live <- (length (registry.workers O))
                           accepted <- (registry.accepted O)
                           completed <- (registry.completed O)
                           failed <- (registry.failed O)
                           cancelled <- (registry.cancelled O)
                           peak <- (registry.peak O))))

(define note-error
  O Error ->
    (let Previous (registry.error O)
      (registry.error-> O (if (empty? Previous) Error (io.secondary Previous Error)))))

(define close-listener
  O ->
    (let Token (registry.token O)
      (if (= (shen-jit.pointer-address Token) 0)
          true
          (listener-closed O (io.socket-close Token "HTTP listener")))))

(define listener-closed
  _ [ok] -> true
  O [error Error] -> (do (note-error O Error) true))

(define reap
  O -> (registry.workers-> O (reap-workers O (registry.workers O) [])))

(define reap-workers
  _ [] Live -> (reverse Live)
  O [W | Rest] Live ->
    (let Result (task.result W)
      (if (empty? Result)
          (reap-workers O Rest [W | Live])
          (do (registry.completed-> O (+ 1 (registry.completed O)))
              (count-failure O Result)
              (reap-workers O Rest Live)))))

(define count-failure
  _ [ok _] -> true
  O [error _] -> (do (registry.failed-> O (+ 1 (registry.failed O))) true))

(define worker
  W Handler Options Stop ->
    (let E (task.endpoint W)
         Result (io.with-endpoint E
                  (/. Connection (serve-controlled Connection Handler Options Stop)))
      (task.result-> W Result)))

(define admit
  S O Handler Options ->
    (let Peer (socket.c-accept (io.socket-id (registry.token O)) [] [])
         Code (if (< Peer 0) (io.socket-code) 0)
      (cond ((>= Peer 0)
              (if (server.stopping S)
                  (socket.close Peer)
                  (launch S O (socket.closing-on-error Peer (freeze (socket.set-up Peer)))
                               Handler Options)))
            ((io.socket-again? Code) true)
            (true (note-error O (io.socket-error accept "HTTP listener" Code))))))

(define launch
  S O Peer Handler Options ->
    (let E (io.socket Peer "HTTP peer")
         W (task.make E [])
         Workers [W | (registry.workers O)]
         _ (registry.workers-> O Workers)
         _ (registry.accepted-> O (+ 1 (registry.accepted O)))
         N (length Workers)
         _ (if (> N (registry.peak O)) (registry.peak-> O N) true)
      (trap-error (thread (freeze (worker W Handler Options (freeze (server.stopping S)))))
        (/. X (task.result-> W
                (io.finish [error (io.error thread "HTTP worker" (error-to-string X))] (io.close E)))))))

(define begin-stop
  O Grace ->
    (do (close-listener O)
        (registry.grace-> O (clock.deadline Grace))
        (registry.phase-> O draining)))

(define cancel-workers
  [] -> true
  [W | Rest] -> (do (io.socket-cancel (task.endpoint W)) (cancel-workers Rest)))

(define supervise
  S O Handler [Cap Grace Options] ->
    (do (reap O)
        (if (and (= (registry.phase O) listening)
                 (or (server.stopping S) (not (empty? (registry.error O)))))
            (begin-stop O Grace) true)
        (publish S O)
        (cond ((= (registry.phase O) listening)
                (do (if (< (length (registry.workers O)) Cap)
                        (if (socket.readable? (io.socket-id (registry.token O)) 50)
                            (admit S O Handler Options) true)
                        (pause 50))
                    (supervise S O Handler [Cap Grace Options])))
              ((empty? (registry.workers O)) (finish-listener S O))
              ((and (= (registry.phase O) draining) (deadline.expired? (registry.grace O)))
                (do (cancel-workers (registry.workers O))
                    (registry.cancelled-> O (length (registry.workers O)))
                    (registry.phase-> O cancelling)
                    (supervise S O Handler [Cap Grace Options])))
              (true (do (pause 50) (supervise S O Handler [Cap Grace Options]))))))

(define finish-listener
  S O ->
    (let _ (close-listener O)
         _ (registry.phase-> O stopped)
         _ (publish S O)
         Error (registry.error O)
      (server.result-> S (if (empty? Error) [ok] [error Error]))))

(define supervisor
  S O Handler Config ->
    (trap-error (supervise S O Handler Config)
      (/. X (do (note-error O (io.error serve "HTTP listener" (error-to-string X)))
                (close-listener O)
                (cancel-workers (registry.workers O))
                (registry.cancelled-> O (length (registry.workers O)))
                (registry.phase-> O cancelling)
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
