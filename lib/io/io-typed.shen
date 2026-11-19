(shen.x.namespace io
  (use buffer)
  (use result)
  (import result ok err)
  (use option)
  (externals [library])
  (export io.error => error native-error error-operation error-domain error-code
    error-resource error-message error-progress error-secondary finish no-read no-write)

(define native-error
  {symbol --> symbol --> number --> string --> string --> io.error}
  Op Domain Code Resource Message -> (error.make Op Domain Code Resource Message 0 []))

(define io.error
  {symbol --> string --> string --> io.error}
  Op Resource Message -> (native-error Op library 0 Resource Message))

(define error-operation
  {io.error --> symbol}
  (:io.error operation <- X ...) -> X)

(define error-domain
  {io.error --> symbol}
  (:io.error domain <- X ...) -> X)

(define error-code
  {io.error --> number}
  (:io.error code <- X ...) -> X)

(define error-resource
  {io.error --> string}
  (:io.error resource <- X ...) -> X)

(define error-message
  {io.error --> string}
  (:io.error message <- X ...) -> X)

(define error-progress
  {io.error --> fixnum}
  (:io.error progress <- X ...) -> X)

(define error-secondary
  {io.error --> (list io.error)}
  (:io.error secondary <- X ...) -> X)

(define no-read
  {buffer.storage --> (io.result (option.t fixnum))}
  _ -> (error "io: endpoint is not readable"))

(define no-write
  {buffer.storage --> (io.result fixnum)}
  _ -> (error "io: endpoint is not writable"))

(define progress
  {io.error --> fixnum --> io.error}
  (:io.error operation <- Op domain <- D code <- C resource <- R message <- M secondary <- S ...) N ->
    (error.make Op D C R M N S))

(define secondary
  {io.error --> io.error --> io.error}
  (:io.error operation <- Op domain <- D code <- C resource <- R message <- M progress <- N secondary <- S) Other ->
    (error.make Op D C R M N (append S [Other])))

(define finish
  {(io.result A) --> (io.result result.empty) --> (io.result A)}
  (:ok Value) (:ok []) -> (:ok Value)
  (:ok _) (:err Error) -> (:err Error)
  (:err Error) (:ok []) -> (:err Error)
  (:err Error) (:err Other) -> (:err (secondary Error Other)))

)
