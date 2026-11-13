\\ Owned duplex endpoints over lib/socket.shen. Load ffi.shen, socket.shen, buffer.shen, io.shen.
\\ io.socket consumes a connected socket's raw integer. Do not use or wrap that integer again.
\\ Data calls stay nonblocking; waits poll in slices of at most 100 ms, after each of which a kill
\\ (isolate.kill) reaches an isolate that waits.

(shen.x.namespace io
  (use buffer)
  (use deadline)
  (use shen-jit)
  (use socket)
  (import struct defstruct)
  (externals [cancelled deadline define-foreign eof int32 ok poll posix read-write shutdown
    timeout winsock write written])
  (export close-result endpoint let-ok shutdown-write socket socket-again? socket-cancel
    socket-check socket-close socket-code socket-deadline socket-error socket-id socket-token
    socket-unlimited)

(define-foreign socket-c-error socket.lib "WSAGetLastError" () --> int32)

(define socket-code
  -> (if (socket.windows?) (socket-c-error) (shen-jit.errno)))

(define socket-error
  Op Name Code ->
    (native-error Op (if (socket.windows?) winsock posix) Code Name
      (if (socket.windows?) (make-string "socket error ~A" Code) (socket.c-strerror Code))))

(define socket-again?
  Code -> (or (= Code (socket.by-os 11 35 10035)) (= Code (socket.by-os 4 4 10004))))

\\ Native identities reload dead in images. The token is never dereferenced or passed to C.
(define socket-token
  S ->
    (let Address (+ S 1)
         B (shen-jit.bytes 8)
         _ (shen-jit.u32! B 0 (shen-jit.bit-and Address 4294967295))
         _ (shen-jit.u32! B 4 (shen-jit.shift-right Address 32))
      (shen-jit.bytes->pointer B 0 socket)))

(define socket-id
  Token ->
    (let Address (shen-jit.pointer-address Token)
      (if (> Address 0) (- Address 1) (error "io: socket endpoint is stale"))))

\\ A policy keeps one absolute deadline across every short transfer and poll retry, and the
\\ cancellation flag.
(defstruct socket-policy
  (mutable budget)
  (mutable cancelled))

(define socket-budget
  Policy Op Name ->
    (let D (socket-policy.budget Policy)
      (cond ((socket-policy.cancelled Policy)
              [error (native-error Op cancelled 0 Name "socket operation cancelled")])
            ((or (empty? D) (not (deadline.expired? D))) [ok])
            (true [error (native-error Op timeout 0 Name "deadline expired")]))))

(define socket-slice
  Policy ->
    (let D (socket-policy.budget Policy)
      (if (empty? D) 100 (deadline.slice D 100))))

(define socket-wait
  Token Name Policy Event Op ->
    (let-ok _ (socket-budget Policy Op Name)
      (let Slice (socket-slice Policy)
           _ (isolate.check-kill)
        (if (= Slice 0)
            [error (native-error Op timeout 0 Name "deadline expired")]
            (let Ready (socket.c-poll (socket.pollfd (socket-id Token) Event) 1 Slice)
                 Code (if (< Ready 0) (socket-code) 0)
              (cond ((> Ready 0) (socket-budget Policy Op Name))
                    ((or (= Ready 0) (socket-again? Code))
                      (socket-wait Token Name Policy Event Op))
                    (true [error (socket-error poll Name Code)])))))))

(define socket-read
  Token Name Policy Chunk ->
    (let-ok _ (socket-budget Policy read Name)
      (let N (socket.c-recv (socket-id Token) Chunk (shen-jit.bytes-length Chunk) 0)
           Code (if (< N 0) (socket-code) 0)
        (cond ((> N 0) [read N])
              ((= N 0) [eof])
              ((socket-again? Code)
                (let-ok _ (socket-wait Token Name Policy (socket.readable-event) read)
                  (socket-read Token Name Policy Chunk)))
              (true [error (socket-error read Name Code)])))))

(define socket-write
  Token Name Policy Chunk ->
    (let-ok _ (socket-budget Policy write Name)
      (let N (socket.c-send (socket-id Token) Chunk (shen-jit.bytes-length Chunk) (socket.send-flags))
           Code (if (< N 0) (socket-code) 0)
        (cond ((>= N 0) [written N])
              ((socket-again? Code)
                (let-ok _ (socket-wait Token Name Policy (socket.writable-event) write)
                  (socket-write Token Name Policy Chunk)))
              (true [error (socket-error write Name Code)])))))

(define socket-close
  Token Name ->
    (let S (socket-id Token)
         _ (shen-jit.pointer-kill Token)
         Result (socket.c-close S)
         Code (if (< Result 0) (socket-code) 0)
      (if (= Result 0) [ok] [error (socket-error close Name Code)])))

(define socket-make
  S Name ->
    (let Token (socket-token S)
         Policy (socket-policy.make [] false)
         E (endpoint Name read-write 65536
                        (/. B (socket-read Token Name Policy B))
                        (/. B (socket-write Token Name Policy B))
                        (freeze (socket-close Token Name)))
      (do (endpoint.guard-> E Token) (endpoint.context-> E Policy) E)))

(define socket
  S Name ->
    (let N (buffer.index S)
         _ (if (and (string? Name)
                    (if (socket.windows?) (< N 2305843009213693951) (<= N 2147483647)))
               true
               (error "io: invalid socket or name"))
      (shen-jit.on-error (freeze (socket-make N Name)) (freeze (socket.c-close N)))))

(define socket-check
  E ->
    (let _ (endpoint-check E)
         Token (endpoint.guard E)
         _ (if (and (shen-jit.pointer? Token) (= (shen-jit.pointer-kind Token) socket))
               true
               (error "io: not a socket endpoint"))
         _ (check E read (endpoint.reader E))
      Token))

(define socket-deadline
  E D ->
    (let _ (socket-check E)
         _ (deadline.check D)
      (do (socket-policy.budget-> (endpoint.context E) D) E)))

(define socket-unlimited
  E ->
    (let _ (socket-check E)
      (do (socket-policy.budget-> (endpoint.context E) []) E)))

\\ Cancellation is the only cross-task endpoint operation. It publishes one monotonic flag,
\\ without closing or reusing a descriptor while its owner may still be inside poll.
(define socket-cancel
  E ->
    (let _ (endpoint-check E)
         Token (endpoint.guard E)
         _ (if (and (shen-jit.pointer? Token) (= (shen-jit.pointer-kind Token) socket))
               true (error "io: not a socket endpoint"))
      (do (socket-policy.cancelled-> (endpoint.context E) true) true)))

\\ Flush before sending FIN. Read EOF, write shutdown and full close remain separate states.
(define shutdown-write
  E ->
    (let Token (socket-check E)
         W (endpoint.writer E)
      (if (= (endpoint.mode E) read)
          [ok]
          (socket-shutdown-ready E Token (if (empty? W) [ok 0] (flush W))))))

(define socket-shutdown-ready
  _ _ [error Error _] -> [error Error]
  E Token [ok N] ->
    (socket-shutdown-budget E Token N (socket-budget (endpoint.context E) shutdown (endpoint.name E))))

(define socket-shutdown-budget
  _ _ N [error Error] -> [error (progress Error N)]
  E Token N [ok] ->
    (let Result (socket.c-shutdown (socket-id Token) 1)
         Code (if (< Result 0) (socket-code) 0)
      (if (= Result 0)
          (do (endpoint.mode-> E read)
              (endpoint.writer-> E [])
              [ok])
          [error (progress (socket-error shutdown (endpoint.name E) Code) N)])))

(declare socket [number --> [string --> endpoint]])
(declare socket-deadline [endpoint --> [deadline --> endpoint]])
(declare socket-unlimited [endpoint --> endpoint])
(declare socket-cancel [endpoint --> boolean])
(declare shutdown-write [endpoint --> close-result])

)
