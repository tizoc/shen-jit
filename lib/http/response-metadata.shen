\\ Construct HTTP responses in their private type scope.
(shen.x.namespace http
  (use buffer)
  (use shen-jit)
  (externals [chunked])
  (export close-after response stream-response)

(define response-code
  {number --> fixnum}
  Status ->
    (let Code (fixnum Status)
      (if (and (fx>= Code 200) (fx<= Code 599))
          Code
          (error "http: final response status must be 200..599"))))

(define response
  {number --> (list (list string)) --> buffer.view --> response}
  Status Fields Body ->
    (let Code (response-code Status)
         _ (buffer.check Body)
      (:response status <- Code fields <- Fields body <- Body close <- false)))

(define response-check
  {response --> response}
  R -> (if (response? R) R (error "http: not a response")))

(define close-after
  {response --> response}
  (:response status <- Status fields <- Fields body <- Body ...) ->
    (:response status <- Status fields <- Fields body <- Body close <- true)
  _ -> (error "http: not a response"))

(define response-copy-fields
  {response --> (list (list string)) --> response}
  (:response status <- Status body <- Body close <- Close ...) Fields ->
    (:response status <- Status fields <- Fields body <- Body close <- Close)
  _ _ -> (error "http: not a response"))

(define framing-check
  {response-framing --> response-framing}
  [length N] -> (do (buffer.index N) [length N])
  [chunked] -> [chunked]
  _ -> (error "http: response framing must be [length N] or [chunked]"))

(define stream-response
  {number --> (list (list string)) --> response-framing --> source --> response}
  Status Fields Framing Source ->
    (let Code (response-code Status)
         _ (source-check Source)
         Checked (framing-check Framing)
      (:response
        status <- Code
        fields <- Fields
        body <- (:stream-body framing <- Checked source <- Source)
        close <- false)))

)
\\ The public signatures use http.response. Its representation rules are private.
(preclude [http.response.%match http.stream-body.%match
           http.response-body.%buffer.view http.response-body.%http.stream-body])
