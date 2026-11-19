\\ A bounded one-connection header capture, useful before adding HTTP request semantics.
\\ Load ffi/socket/buffer/io/deadline/clock/io-socket/http-head first. This sends no HTTP response.

(shen.x.namespace http-head
  (import result ok err)
  (use clock)
  (use http)
  (use io)
  (externals [http-head])

(define capture
  E Limit Milliseconds ->
    (io.with-endpoint E
      (/. Connection
        (let D (clock.deadline Milliseconds)
             _ (io.socket-deadline Connection D)
             F (http.head-reader (io.reader Connection []) Limit)
          (capture-result (http.read-head-until F D))))))

(define capture-result
  (:ok [V]) -> (:ok V)
  (:err Error) -> (:err Error)
  (:ok []) -> (:err (io.error http-head "HTTP head" "connection ended before a head")))

)
