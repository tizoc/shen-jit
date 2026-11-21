(shen.x.namespace curl
  (use buffer)
  (use bytes)
  (use io)
  (use option)
  (use result)
  (use shen-jit)
  (shadow get)
  (export get status url body streamed? body-length headers header-values trailers raw-headers raw-trailers elapsed redirects)

(define get
  {string --> (list option) --> (result.t (io.error * response))}
  URL Options -> (fetch "GET" URL [] (buffer.new 0) Options))

(define response-check
  {response --> response}
  R -> (if (response? R) R (error "curl: not a response")))

(define body
  {response --> buffer.view}
  R -> (body-value (response.body (response-check R))))

(define body-value
  {(option.t buffer.view) --> buffer.view}
  [Body] -> Body
  [] -> (error "curl: response body was streamed"))

(define status
  {response --> number}
  R -> (response.status (response-check R)))

(define url
  {response --> string}
  R -> (response.url (response-check R)))

(define streamed?
  {response --> boolean}
  R -> (empty? (response.body (response-check R))))

(define body-length
  {response --> fixnum}
  R -> (response.body-length (response-check R)))

(define headers
  {response --> (list (list string))}
  R -> (response.headers (response-check R)))

(define field-values
  {(list (list string)) --> string --> (list string)}
  [] _ -> []
  [[Name Value] | Rest] Name -> [Value | (field-values Rest Name)]
  [_ | Rest] Name -> (field-values Rest Name))

(define header-values
  {response --> string --> (list string)}
  R Name -> (field-values (headers R) (bytes.lower Name)))

(define trailers
  {response --> (list (list string))}
  R -> (response.trailers (response-check R)))

(define raw-headers
  {response --> buffer.view}
  R -> (response.raw-headers (response-check R)))

(define raw-trailers
  {response --> buffer.view}
  R -> (response.raw-trailers (response-check R)))

(define elapsed
  {response --> number}
  R -> (response.elapsed (response-check R)))

(define redirects
  {response --> number}
  R -> (response.redirects (response-check R)))

)
