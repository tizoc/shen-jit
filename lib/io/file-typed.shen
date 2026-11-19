(shen.x.namespace io
  (use buffer)
  (use result)
  (import result ok err)
  (externals [read write])
  (shadow read-file)
  (export with-input-file with-output-file read-file write-file)

\\ File scopes share the core's result and cleanup policy.
(define with-input-file
  {string --> (endpoint --> (result.t (io.error * A))) --> (result.t (io.error * A))}
  Path F -> (with-open-file (open-file Path read) F))

(define with-output-file
  {string --> (endpoint --> (result.t (io.error * A))) --> (result.t (io.error * A))}
  Path F -> (with-open-file (open-file Path write) F))

\\ Pass the existing callback directly after acquiring the file.
(define with-open-file
  {(io.result endpoint) --> (endpoint --> (io.result A)) --> (io.result A)}
  (:ok E) F -> (with-endpoint E F)
  (:err E) _ -> (err E))

(define read-file
  {string --> fixnum --> (result.t (io.error * buffer.view))}
  Path Limit ->
    (do (buffer.index Limit)
        (with-input-file Path (/. E (read-all (reader E []) Limit)))))

(define file-transfer-finish
  {(io.result fixnum) --> (io.result result.empty) --> (io.result fixnum)}
  (:ok N) (:err Error) -> (err (progress Error N))
  Result Closed -> (finish Result Closed))

(define write-file-open
  {buffer.view --> (io.result endpoint) --> (io.result fixnum)}
  _ (:err Error) -> (:err Error)
  V (:ok E) ->
    (let Result (trap-error (write-all E V [])
                   (/. X (do (io.close E) (simple-error (error-to-string X)))))
      (file-transfer-finish Result (io.close E))))

(define write-file
  {string --> buffer.view --> (io.result fixnum)}
  Path V -> (do (buffer.check V) (write-file-open V (open-file Path write))))

)
