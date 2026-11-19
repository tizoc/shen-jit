(define curl-typed.status
  {(io.result curl.response) --> number}
  (:result.ok R) -> (let B (curl.body R)
                Fields (curl.headers R)
                Trailers (curl.trailers R)
                _ (buffer.length (curl.raw-headers R))
             (curl.status R))
  (:result.err E) -> (io.error-code E))

(define curl-typed.request
  {curl.client --> string --> (io.result curl.response)}
  C URL -> (curl.request C "POST" URL [["Content-Type" "application/json"]]
             (buffer.from-string "{}") [[body-limit 4096] [timeout 1000] [proxy ""]]))

(define curl-typed.get
  {string --> (io.result curl.response)}
  URL -> (curl.with-client (/. C (curl.request C "GET" URL [] (buffer.new 0)
                                  [[connect-timeout 500] [header-limit 4096] [redirect-limit 1]]))))

(define curl-typed.stream
  {curl.client --> string --> io.endpoint --> (io.result curl.response)}
  C URL Sink -> (curl.request-to C "GET" URL [] (buffer.new 0) Sink
                  [[chunk-size 4096] [body-limit 1073741824]]))

(define curl-typed.owned-stream
  {curl.client --> string --> (io.result curl.response)}
  C URL -> (curl.request-with-sink C "GET" URL [] (buffer.new 0)
             (/. Head (result.ok (io.output-buffer (buffer.new 1024)))) [[proxy ""]]))

(define curl-typed.stream-result
  {(io.result curl.response) --> fixnum}
  (:result.ok R) -> (if (curl.streamed? R) (curl.body-length R) (buffer.length (curl.body R)))
  (:result.err E) -> (io.error-progress E))

(define curl-typed.scoped-progress
  {(curl.client --> (io.result string)) --> (io.result string)}
  F -> (curl.with-client F))

(define curl-typed.run
  {string --> boolean}
  URL ->
    (let Sink (io.output-buffer (buffer.new 1024))
         A (curl.with-client (/. C (curl-typed.stream C URL Sink)))
         _ (io.close Sink)
         B (curl.with-client (/. C (curl-typed.owned-stream C URL)))
      (and (= (curl-typed.status (curl.get URL [[proxy ""]])) 200)
           (= (curl-typed.stream-result A) 1024) (= (curl-typed.stream-result B) 1024))))
