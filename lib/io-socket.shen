\\ Owned duplex endpoints over lib/socket.shen. Load ffi.shen, socket.shen, buffer.shen, io.shen.
\\ io.socket consumes a connected socket's raw integer. Do not use or wrap that integer again.
\\ Data calls stay nonblocking; only the existing poll FFI releases the VM lock.

(shen.x.namespace io
  (use buffer)
  (use deadline)
  (use shen-jit)
  (use socket)
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

\\ A policy cell keeps one absolute deadline across every short transfer and poll retry.
(define socket-budget
  Policy Op Name ->
    (let D (<-address Policy 0)
      (cond ((<-address Policy 1)
              [error (native-error Op cancelled 0 Name "socket operation cancelled")])
            ((or (empty? D) (not (deadline.expired? D))) [ok])
            (true [error (native-error Op timeout 0 Name "deadline expired")]))))

(define socket-slice
  Policy ->
    (let D (<-address Policy 0)
      (if (empty? D) 100 (deadline.slice D 100))))

(define socket-wait
  Token Name Policy Event Op ->
    (let-ok _ (socket-budget Policy Op Name)
      (let Slice (socket-slice Policy)
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
         Policy (record [[] false])
         E (endpoint Name read-write 65536
                        (/. B (socket-read Token Name Policy B))
                        (/. B (socket-write Token Name Policy B))
                        (freeze (socket-close Token Name)))
      (do (address-> E 12 Token) (address-> E 13 Policy) E)))

(define socket
  S Name ->
    (let N (buffer.index S)
         _ (if (and (string? Name)
                    (if (socket.windows?) (< N 2305843009213693951) (<= N 2147483647)))
               true
               (error "io: invalid socket or name"))
      (trap-error (socket-make N Name)
        (/. X (do (socket.c-close N) (simple-error (error-to-string X)))))))

(define socket-check
  E ->
    (let _ (endpoint-check E)
         Token (<-address E 12)
         _ (if (and (shen-jit.pointer? Token) (= (shen-jit.pointer-kind Token) socket))
               true
               (error "io: not a socket endpoint"))
         _ (check E read (<-address E 9))
      Token))

(define socket-deadline
  E D ->
    (let _ (socket-check E)
         _ (deadline.check D)
      (do (address-> (<-address E 13) 0 D) E)))

(define socket-unlimited
  E ->
    (let _ (socket-check E)
      (do (address-> (<-address E 13) 0 []) E)))

\\ Cancellation is the only cross-task endpoint operation. It publishes one monotonic flag,
\\ without closing or reusing a descriptor while its owner may still be inside poll.
(define socket-cancel
  E ->
    (let _ (endpoint-check E)
         Token (<-address E 12)
         _ (if (and (shen-jit.pointer? Token) (= (shen-jit.pointer-kind Token) socket))
               true (error "io: not a socket endpoint"))
      (do (address-> (<-address E 13) 1 true) true)))

\\ Flush before sending FIN. Read EOF, write shutdown and full close remain separate states.
(define shutdown-write
  E ->
    (let Token (socket-check E)
         W (<-address E 10)
      (if (= (<-address E 2) read)
          [ok]
          (socket-shutdown-ready E Token (if (empty? W) [ok 0] (flush W))))))

(define socket-shutdown-ready
  _ _ [error Error _] -> [error Error]
  E Token [ok N] ->
    (socket-shutdown-budget E Token N (socket-budget (<-address E 13) shutdown (<-address E 1))))

(define socket-shutdown-budget
  _ _ N [error Error] -> [error (progress Error N)]
  E Token N [ok] ->
    (let Result (socket.c-shutdown (socket-id Token) 1)
         Code (if (< Result 0) (socket-code) 0)
      (if (= Result 0)
          (do (address-> E 2 read)
              (address-> E 10 [])
              [ok])
          [error (progress (socket-error shutdown (<-address E 1) Code) N)])))

(declare socket [number --> [string --> endpoint]])
(declare socket-deadline [endpoint --> [deadline --> endpoint]])
(declare socket-unlimited [endpoint --> endpoint])
(declare socket-cancel [endpoint --> boolean])
(declare shutdown-write [endpoint --> close-result])

)
