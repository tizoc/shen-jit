\\ A bounded one-connection header capture, useful before adding HTTP request semantics.
\\ Load ffi/socket/buffer/io/deadline/clock/io-socket/http-head first. This sends no HTTP response.

(shen.x.namespace http-head
  (use clock)
  (use http)
  (use io)
  (externals [eof http-head ok])

(define capture
  E Limit Milliseconds ->
    (io.with-endpoint E
      (/. Connection
        (let D (clock.deadline Milliseconds)
             _ (io.socket-deadline Connection D)
             F (http.head-reader (io.reader Connection []) Limit)
          (capture-result (http.read-head-until F D))))))

(define capture-result
  [head V] -> [ok V]
  [error Error] -> [error Error]
  [eof] -> [error (io.error http-head "HTTP head" "connection ended before a head")])

)
