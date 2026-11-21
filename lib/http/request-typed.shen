(shen.x.namespace http
  (use buffer)
  (use bytes)
  (use io)
  (use option)
  (use shen-jit)
  (shadow version)
  (export body-reader body content-length chunked? header-values headers method target trailers version)

(define body-reader
  {io.reader --> request --> body-reader}
  R Request -> (body-reader-with R Request []))

(define field-values
  {(list (list string)) --> string --> (list string)}
  [] _ -> []
  [[Name Value] | Rest] Name -> [Value | (field-values Rest Name)]
  [_ | Rest] Name -> (field-values Rest Name))

(define request-check
  {request --> request}
  Request -> (if (request? Request) Request (error "http: not a request")))

(define method
  {request --> string}
  Request -> (request.method (request-check Request)))

(define target
  {request --> string}
  Request -> (request.target (request-check Request)))

(define version
  {request --> string}
  Request -> (request.version (request-check Request)))

(define headers
  {request --> (list (list string))}
  Request -> (request.headers (request-check Request)))

(define content-length
  {request --> fixnum}
  Request -> (known-length (request.length (request-check Request))))

(define known-length
  {(option.t fixnum) --> fixnum}
  [N] -> N
  [] -> (error "http: chunked body length is not known until read"))

(define chunked?
  {request --> boolean}
  Request -> (request.chunked (request-check Request)))

(define trailers
  {request --> (list (list string))}
  Request -> (do (body Request) (request.trailers Request)))

(define header-values
  {request --> string --> (list string)}
  Request Name -> (field-values (headers Request) (bytes.lower Name)))

(define body
  {request --> buffer.view}
  Request -> (read-view (request.body (request-check Request))))

(define read-view
  {(option.t buffer.view) --> buffer.view}
  [View] -> (buffer.check View)
  [] -> (error "http: request body has not been read"))

(define completed-request
  {request --> buffer.view --> (list (list string)) --> request}
  Request Body Trailers ->
    (:request
      method <- (method Request)
      target <- (target Request)
      version <- (version Request)
      headers <- (headers Request)
      length <- (option.some (buffer.length Body))
      body <- (option.some Body)
      limit <- (request.limit Request)
      trailers <- Trailers
      chunked <- (request.chunked Request)))

(define request-from-head
  {string --> string --> string --> (list (list string)) -->
   (option.t fixnum) --> fixnum --> boolean --> request}
  Method Target Version Fields Length Limit Chunked ->
    (:request
      method <- Method
      target <- Target
      version <- Version
      headers <- Fields
      length <- Length
      body <- (option.none)
      limit <- Limit
      trailers <- []
      chunked <- Chunked))

)
