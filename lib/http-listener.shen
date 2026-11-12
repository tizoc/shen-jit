\\ An HTTP listener that serves its connections one at a time, in the caller of http.run, until a
\\ handler calls http.stop. Load http-server.shen first.

(shen.x.namespace http
  (use buffer)
  (use clock)
  (use deadline)
  (use grammar)
  (use io)
  (use shen-jit)
  (use socket)
  (import struct defstruct)
  (externals [accept blocking define-foreign draining http-listener-options
    http-listener-results int32 int64 listening max-connections ok pending pointer serve
    shutdown-grace stopped void])
  (shadow port run)
  (export listen listener-option option port request response run server state stats stop wait
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

\\ The server: its image guard, port, listening socket, handler and options, and what running it has
\\ done so far. Only http.run and the handlers it calls change it.
(define show-server
  S -> (make-string "#<http server port ~A ~A>" (server.port S) (server.phase S)))

(defstruct server
  (printer show-server)
  guard
  port
  token
  handler
  options
  (mutable stopping)
  (mutable phase)
  (mutable active)
  (mutable accepted)
  (mutable completed)
  (mutable failed)
  (mutable error)
  (mutable result))

(define listen
  Host Port Handler Options ->
    (let Config (listener-options Options)
         _ (clock.monotonic)
         _ (grammar.prepare <head>)
         L (socket.listen Host Port)
      (socket.closing-on-error L (freeze (listener-start L Handler Config)))))

(define listener-start
  L Handler [_ _ Options] ->
    (:server
      guard <- (shen-jit.bytes->pointer (shen-jit.u32! (shen-jit.bytes 8) 0 1) 0 server)
      port <- (socket.port L)
      token <- (io.socket-token L)
      handler <- Handler
      options <- Options
      stopping <- false
      phase <- listening
      active <- 0
      accepted <- 0
      completed <- 0
      failed <- 0
      error <- []
      result <- []))

(define listener-check
  S ->
    (let _ (if (server? S) true (error "http: not a server"))
         _ (if (= (shen-jit.pointer-address (server.guard S)) 0)
               (error "http: saved servers must be recreated") true)
      S))

(define port
  S -> (server.port (listener-check S)))

(define stop
  S -> (let _ (server.stopping-> (listener-check S) true)
            _ (if (= (server.phase S) listening) (server.phase-> S draining) true)
         true))

(define state
  S -> (server.phase (listener-check S)))

(define stats
  S ->
    (let _ (listener-check S)
      [(server.active S) (server.accepted S) (server.completed S) (server.failed S) 0
       (if (> (server.accepted S) 0) 1 0)]))

\\ Connections are served in the caller of http.run, so nothing progresses while one waits: wait gives
\\ the result once run has returned, and [pending] before.
(define wait
  S Milliseconds ->
    (let _ (listener-check S)
         _ (if (and (number? Milliseconds) (>= Milliseconds 0)) true
               (error "http: a wait budget is a nonnegative number of milliseconds"))
         Result (server.result S)
      (if (empty? Result) [pending] Result)))

\\ Serves connections one at a time, each to its end, until a handler calls http.stop or the listener
\\ fails, then closes the listener and gives the result. The listener is polled in slices, so that
\\ Ctrl-C reaches a REPL that runs it.
(define run
  S -> (let _ (listener-check S)
            Result (server.result S)
         (if (empty? Result)
             (trap-error (serve-turns S)
               (/. X (do (note-error S (io.error serve "HTTP listener" (error-to-string X)))
                         (finish S))))
             Result)))

(define serve-turns
  S -> (cond ((or (server.stopping S) (not (empty? (server.error S)))) (finish S))
             ((socket.readable? (io.socket-id (server.token S)) 50) (do (admit S) (serve-turns S)))
             (true (serve-turns S))))

(define admit
  S ->
    (let Peer (socket.c-accept (io.socket-id (server.token S)) [] [])
         Code (if (< Peer 0) (io.socket-code) 0)
      (cond ((>= Peer 0) (serve-peer S (socket.closing-on-error Peer (freeze (socket.set-up Peer)))))
            ((io.socket-again? Code) true)
            (true (note-error S (io.socket-error accept "HTTP listener" Code))))))

\\ A connection's requests, under its limits and deadlines, until it ends; after http.stop, it closes
\\ once its active response is written. A failure ends the connection and is counted, not raised.
(define serve-peer
  S Peer ->
    (let E (io.socket Peer "HTTP peer")
         _ (server.accepted-> S (+ 1 (server.accepted S)))
         _ (server.active-> S 1)
         Result (trap-error
                  (io.with-endpoint E
                    (/. Connection (serve-controlled Connection (server.handler S) (server.options S)
                                                     (freeze (server.stopping S)))))
                  (/. X [error (io.error serve "HTTP connection" (error-to-string X))]))
         _ (server.active-> S 0)
         _ (server.completed-> S (+ 1 (server.completed S)))
      (count-failure S Result)))

(define count-failure
  _ [ok | _] -> true
  S [error | _] -> (do (server.failed-> S (+ 1 (server.failed S))) true))

(define note-error
  S Error ->
    (let Previous (server.error S)
      (server.error-> S (if (empty? Previous) Error (io.secondary Previous Error)))))

(define close-listener
  S ->
    (let Token (server.token S)
      (if (= (shen-jit.pointer-address Token) 0)
          true
          (listener-closed S (io.socket-close Token "HTTP listener")))))

(define listener-closed
  _ [ok] -> true
  S [error Error] -> (do (note-error S Error) true))

(define finish
  S ->
    (let _ (close-listener S)
         _ (server.phase-> S stopped)
         Error (server.error S)
         Result (if (empty? Error) [ok] [error Error])
         _ (server.result-> S Result)
      Result))

(datatype http-listener-results
  ___________________________
  [ok] : wait-result;

  ___________________________
  [pending] : wait-result;

  Error : io.error;
  ===========================
  [error Error] : wait-result;)

(datatype http-listener-options
  N : number;
  =================================
  [max-connections N] : listener-option;

  N : number;
  =================================
  [shutdown-grace N] : listener-option;

  Option : option;
  _________________________________
  Option : listener-option;)

(declare listen
  [string --> [number --> [[request --> response] -->
    [[list listener-option] --> server]]]])
(declare port [server --> number])
(declare stop [server --> boolean])
(declare state [server --> symbol])
(declare stats [server --> [list number]])
(declare wait [server --> [number --> wait-result]])
(declare run [server --> wait-result])

)
