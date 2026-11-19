\\ Construct and inspect the two response variants in the response module's type scope.
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
      (:buffered-response status <- Code fields <- Fields body <- Body close <- false)))

(define response-check
  {response --> response}
  Response ->
    (if (or (buffered-response? Response) (stream-description? Response))
        Response (error "http: not a response")))

(define response-status
  {response --> fixnum}
  (:stream-description status <- Status ...) -> Status
  (:buffered-response status <- Status ...) -> Status
  _ -> (error "http: not a response"))

(define response-field-list
  {response --> (list (list string))}
  (:stream-description fields <- Fields ...) -> Fields
  (:buffered-response fields <- Fields ...) -> Fields
  _ -> (error "http: not a response"))

(define response-closes?
  {response --> boolean}
  (:stream-description close <- Close ...) -> Close
  (:buffered-response close <- Close ...) -> Close
  _ -> (error "http: not a response"))

(define close-after
  {response --> response}
  (:buffered-response status <- Status fields <- Fields body <- Body ...) ->
    (:buffered-response status <- Status fields <- Fields body <- Body close <- true)
  (:stream-description status <- Status fields <- Fields framing <- Framing source <- Source ...) ->
    (:stream-description
      status <- Status fields <- Fields framing <- Framing source <- Source close <- true)
  _ -> (error "http: not a response"))

(define response-copy-fields
  {response --> (list (list string)) --> boolean --> response}
  (:stream-description status <- Status framing <- Framing source <- Source ...) Fields Close
  -> (:stream-description
       status <- Status fields <- Fields framing <- Framing source <- Source close <- Close)
  (:buffered-response status <- Status body <- Body ...) Fields Close
  -> (:buffered-response status <- Status fields <- Fields body <- Body close <- Close)
  _ _ _ -> (error "http: not a response"))

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
      (:stream-description
        status <- Code
        fields <- Fields
        framing <- Checked
        source <- Source
        close <- false)))

)
\\ The public signatures use http.response. Its representation rules are private.
(preclude [http.buffered-response.%match http.stream-description.%match
           http.response.%http.buffered-response http.response.%http.stream-description])
