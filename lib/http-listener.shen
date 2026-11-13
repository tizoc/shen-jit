\\ An HTTP listener that serves each connection in an isolate of its own, at most max-connections at
\\ once, supervised in the caller of http.run until it is stopped. Load http-server.shen first.

(shen.x.namespace http
  (use buffer)
  (use clock)
  (use deadline)
  (use grammar)
  (use io)
  (use shen-jit)
  (use socket)
  (import struct defstruct)
  (externals [accept cancelling draining http-handler http-listener-options http-listener-results
    listening max-connections ok pending serve shutdown-grace stopped])
  (shadow port run)
  (export current-server handler listen listener-option option port request response run server
    state stats stop wait wait-result)

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

\\ A handler runs in its connection's isolate, which inherits no globals, so it goes by name: F,
\\ called with the request, or [F | Args], called with Args and then the request, which are copied
\\ to each connection.
(define handler-check
  F -> (handler-arity F 0) where (symbol? F)
  [F | Args] -> (handler-arity F (length Args)) where (symbol? F)
  _ -> (error "http: a handler is a function's name, or a list of one and the arguments it takes before the request"))

(define handler-arity
  F N -> (let A (arity F)
           (if (or (= A -1) (= A (+ N 1)))
               true
               (error "http: ~A takes ~A arguments, not ~A and the request" F A N))))

(define handler-function
  F -> (fn F) where (symbol? F)
  [F | Args] -> (/. Q (shen-jit.apply F (append Args [Q]))))

\\ The server: its image guard, port, listening socket, handler and options, the channel its
\\ connections tell it on, and what running it has done so far, which only http.run changes. A
\\ handler's copy (http.current-server) has the port and that channel's send endpoint alone.
(define show-server
  S -> (make-string "#<http server port ~A ~A>" (server.port S) (server.phase S)))

(defstruct server
  (printer show-server)
  guard
  port
  token
  handler
  options
  (mutable events)
  (mutable control)
  (mutable stopping)
  (mutable phase)
  (mutable connections)
  (mutable accepted)
  (mutable completed)
  (mutable failed)
  (mutable cancelled)
  (mutable peak)
  (mutable error)
  (mutable grace)
  (mutable result))

(define listen
  Host Port Handler Options ->
    (let Config (listener-options Options)
         _ (handler-check Handler)
         _ (clock.monotonic)
         _ (grammar.prepare <head>)
         L (socket.listen Host Port)
      (socket.closing-on-error L (freeze (listener-start L Handler Config)))))

(define listener-start
  L Handler Config ->
    (:server
      guard <- (shen-jit.bytes->pointer (shen-jit.u32! (shen-jit.bytes 8) 0 1) 0 server)
      port <- (socket.port L)
      token <- (io.socket-token L)
      handler <- Handler
      options <- Config
      events <- []
      control <- []
      stopping <- false
      phase <- listening
      connections <- []
      accepted <- 0
      completed <- 0
      failed <- 0
      cancelled <- 0
      peak <- 0
      error <- []
      grace <- []
      result <- []))

(define handler-copy
  Port Control ->
    (:server
      guard <- []
      port <- Port
      token <- []
      handler <- []
      options <- []
      events <- []
      control <- Control
      stopping <- false
      phase <- listening
      connections <- []
      accepted <- 0
      completed <- 0
      failed <- 0
      cancelled <- 0
      peak <- 0
      error <- []
      grace <- []
      result <- []))

(define listener-check
  S ->
    (let _ (if (server? S) true (error "http: not a server"))
         Guard (server.guard S)
         _ (if (and (not (empty? Guard)) (= (shen-jit.pointer-address Guard) 0))
               (error "http: saved servers must be recreated") true)
      S))

(define owner-check
  S -> (if (empty? (server.guard (listener-check S)))
           (error "http: a handler's server gives only its port, and stops")
           S))

(define cap
  S -> (hd (server.options S)))

(define grace-ms
  S -> (hd (tl (server.options S))))

(define request-options
  S -> (hd (tl (tl (server.options S)))))

(define port
  S -> (server.port (listener-check S)))

\\ In the caller of http.run, stop marks the server, which run sees; a handler's copy tells it once,
\\ unless it has finished.
(define stop
  S -> (let _ (listener-check S)
         (if (server.stopping S)
             true
             (do (server.stopping-> S true)
                 (if (empty? (server.guard S)) (tell (server.control S) halt) true)
                 true))))

(define tell
  Control Message ->
    (trap-error (shen-jit.send Control Message)
      (/. X (if (= (error-to-string X) "channel closed") true (simple-error (error-to-string X))))))

(define current-server
  -> (trap-error (value *serving*) (/. X (error "http: no handler runs here"))))

(define state
  S -> (server.phase (owner-check S)))

(define stats
  S ->
    (let _ (owner-check S)
      [(length (server.connections S)) (server.accepted S) (server.completed S) (server.failed S)
       (server.cancelled S) (server.peak S)]))

\\ The supervisor runs in the caller of http.run, so wait gives the result once run has returned,
\\ and [pending] before, at once; the budget, checked, stays for the code written for it.
(define wait
  S Milliseconds ->
    (let _ (owner-check S)
         _ (if (and (number? Milliseconds) (>= Milliseconds 0)) true
               (error "http: a wait budget is a nonnegative number of milliseconds"))
         Result (server.result S)
      (if (empty? Result) [pending] Result)))

\\ Serves until stopped, by http.stop before it or from a handler, or until the listener fails,
\\ then closes the listener, waits for the connections, at most shutdown-grace, kills those left
\\ and gives the result. Each turn waits at most 50 ms, on the listener while there is room for a
\\ connection, and otherwise for one to end or to tell, so that Ctrl-C reaches a REPL that runs it,
\\ which leaves the server as it was: running it again goes on.
(define run
  S -> (let _ (owner-check S)
            Result (server.result S)
         (if (empty? Result)
             (do (if (empty? (server.events S)) (open-events S) true)
                 (supervisor S))
             Result)))

\\ Each connection tells at most once that it failed and once that a handler stopped the server,
\\ and the supervisor takes all that is waiting at every turn.
(define open-events
  S -> (let R (shen-jit.channel (+ 2 (* 2 (cap S))))
         (do (server.events-> S R) (server.control-> S (shen-jit.sender R)))))

(define supervisor
  S -> (trap-error (supervise S)
         (/. X (do (note-error S (io.error serve "HTTP listener" (error-to-string X)))
                   (close-listener S)
                   (kill-all S)
                   (supervise S)))))

(define supervise
  S -> (do (reap S)
           (if (and (= (server.phase S) listening)
                    (or (server.stopping S) (not (empty? (server.error S)))))
               (begin-stop S)
               true)
           (cond ((= (server.phase S) listening)
                   (do (if (< (length (server.connections S)) (cap S))
                           (if (socket.readable? (io.socket-id (server.token S)) 50) (admit S) true)
                           (await S))
                       (supervise S)))
                 ((empty? (server.connections S)) (finish S))
                 ((and (= (server.phase S) draining) (deadline.expired? (server.grace S)))
                   (do (kill-all S) (supervise S)))
                 (true (do (await S) (supervise S))))))

(define await
  S -> (shen-jit.wait-any [(server.events S) | (map (/. C (hd (tl C))) (server.connections S))] 50))

(define ready?
  R -> (not (empty? (shen-jit.wait-any [R] 0))))

\\ A connection is [Isolate Monitor Stop]: closing Stop, a send endpoint, tells it to stop.
(define reap
  S -> (do (server.connections-> S (reap-ended S (server.connections S) []))
           (take-events S)))

(define reap-ended
  _ [] Live -> (reverse Live)
  S [[P M Stop] | Rest] Live ->
    (if (ready? M)
        (do (shen-jit.close M)
            (server.completed-> S (+ 1 (server.completed S)))
            (reap-ended S Rest Live))
        (reap-ended S Rest [[P M Stop] | Live])))

\\ After the ends: a connection tells before it ends.
(define take-events
  S -> (if (ready? (server.events S))
           (do (take-event S (shen-jit.receive (server.events S))) (take-events S))
           true))

(define take-event
  S halt -> (server.stopping-> S true)
  S failed -> (server.failed-> S (+ 1 (server.failed S))))

(define admit
  S ->
    (let Peer (socket.c-accept (io.socket-id (server.token S)) [] [])
         Code (if (< Peer 0) (io.socket-code) 0)
      (cond ((>= Peer 0) (launch S (socket.set-up Peer)))
            ((io.socket-again? Code) true)
            (true (note-error S (io.socket-error accept "HTTP listener" Code))))))

\\ The connection's isolate owns the socket from its start, and the supervisor never touches it.
(define launch
  S Peer ->
    (let Stop (shen-jit.channel 1)
         Sender (shen-jit.sender Stop)
         P (socket.closing-on-error Peer
             (freeze (shen-jit.spawn connection-isolate
                       [Peer (server.handler S) (request-options S) (server.port S) (server.control S)
                        (shen-jit.give Stop)])))
         Cs [[P (shen-jit.monitor P) Sender] | (server.connections S)]
         _ (server.connections-> S Cs)
         _ (server.accepted-> S (+ 1 (server.accepted S)))
      (if (> (length Cs) (server.peak S)) (server.peak-> S (length Cs)) true)))

\\ A connection's requests, under its limits and deadlines, until it ends; once the server stops,
\\ it closes after its active response is written. A failure ends it and is counted, not raised.
(define connection-isolate
  [Peer Handler Options Port Control Stop] ->
    (let _ (set *serving* (handler-copy Port Control))
         Result (trap-error
                  (io.with-endpoint (io.socket Peer "HTTP peer")
                    (/. E (serve-controlled E (handler-function Handler) Options
                            (freeze (ready? Stop)))))
                  (/. X [error (io.error serve "HTTP connection" (error-to-string X))]))
      (if (= (hd Result) error) (tell Control failed) true)))

(define begin-stop
  S -> (do (close-listener S)
           (server.grace-> S (clock.deadline (grace-ms S)))
           (server.phase-> S draining)
           (map (/. C (shen-jit.close (hd (tl (tl C))))) (server.connections S))))

(define kill-all
  S -> (let Cs (server.connections S)
         (do (map (/. C (shen-jit.kill (hd C))) Cs)
             (server.cancelled-> S (+ (server.cancelled S) (length Cs)))
             (server.phase-> S cancelling))))

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
         _ (take-events S)
         _ (shen-jit.close (server.events S))
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

(datatype http-handler
  F : symbol;
  _________________________________
  F : handler;

  F : symbol; Args : (list A);
  _________________________________
  [F | Args] : handler;)

(declare listen
  [string --> [number --> [handler --> [[list listener-option] --> server]]]])
(declare port [server --> number])
(declare stop [server --> boolean])
(declare current-server [--> server])
(declare state [server --> symbol])
(declare stats [server --> [list number]])
(declare wait [server --> [number --> wait-result]])
(declare run [server --> wait-result])

)
