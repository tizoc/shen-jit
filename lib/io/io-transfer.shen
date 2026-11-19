\\ Direct byte transfers and memory-backed endpoint callbacks.
(shen.x.namespace io
  (use buffer)
  (use shen-jit)
  (use option)
  (use result)
  (import result ok err)
  (externals [write])
  (export input-buffer output-buffer read-exact read-some write-all write-some transfer-options)

(define transfer-options
  {transfer-options --> boolean}
  [] -> true
  _ -> (error "io: transfer options must currently be []"))

(define read-some
  {endpoint --> buffer.view --> transfer-options --> (io.result (option.t fixnum))}
  E V Options -> (do (transfer-options Options) (read-raw E V [])))

(define write-some
  {endpoint --> buffer.view --> transfer-options --> (io.result fixnum)}
  E V Options -> (do (transfer-options Options) (write-raw E V [])))

(define read-exact
  {endpoint --> buffer.view --> transfer-options --> (io.result transfer)}
  E V Options ->
    (do (transfer-options Options)
        (check E read [])
        (writable V)
        (exact-loop E V 0 (buffer.length V))))

(define exact-loop
  {endpoint --> buffer.view --> fixnum --> fixnum --> (io.result transfer)}
  _ _ N N -> (ok (:transfer true N))
  E V At End -> (exact-step E V At End (read-raw E (buffer.slice V At (fx- End At)) [])))

(define exact-step
  {endpoint --> buffer.view --> fixnum --> fixnum --> (io.result (option.t fixnum)) --> (io.result transfer)}
  E V At End (:ok [N]) -> (exact-loop E V (fx+ At N) End)
  _ _ At _ (:ok []) -> (ok (:transfer false At))
  _ _ At _ (:err Error) -> (err (progress Error At)))

(define write-all
  {endpoint --> buffer.view --> transfer-options --> (io.result fixnum)}
  E V Options ->
    (do (transfer-options Options)
        (check E write [])
        (all-loop E V 0 (buffer.length V))))

(define all-loop
  {endpoint --> buffer.view --> fixnum --> fixnum --> (io.result fixnum)}
  _ _ N N -> (ok N)
  E V At End -> (all-step E V At End (write-raw E (buffer.slice V At (fx- End At)) [])))

(define all-step
  {endpoint --> buffer.view --> fixnum --> fixnum --> (io.result fixnum) --> (io.result fixnum)}
  E V At End (:ok N) -> (all-loop E V (fx+ At N) End)
  _ _ At _ (:err Error) -> (err (progress Error At)))

\\ Memory input owns a snapshot; memory output borrows a fixed writable range.
(define memory-position
  {--> (vector fixnum)}
  -> (fxvector-> (vector 1) 1 0))

(define memory-read
  {buffer.storage --> (vector fixnum) --> buffer.storage --> (io.result (option.t fixnum))}
  B State Out ->
    (let At (fx<-vector State 1)
         N (min-count (shen-jit.bytes-length Out) (fx- (shen-jit.bytes-length B) At))
      (if (= N 0)
          (ok (option.none))
          (do (shen-jit.copy-bytes Out 0 B At N)
              (fxvector-> State 1 (fx+ At N))
              (ok (option.some N))))))

(define input-buffer
  {buffer.view --> endpoint}
  V ->
    (let B (buffer.bytes V)
         State (memory-position)
      (endpoint "memory input" read 65536
        (/. Out (memory-read B State Out))
        (function no-write)
        (freeze (ok [])))))

(define memory-write
  {buffer.view --> (vector fixnum) --> buffer.storage --> (io.result fixnum)}
  V State In ->
    (let At (fx<-vector State 1)
         N (min-count (shen-jit.bytes-length In) (fx- (buffer.length V) At))
      (if (= N 0)
          (err (io.error write "memory output" "output buffer is full"))
          (do (shen-jit.copy-bytes (buffer.owner V) (fx+ (buffer.offset V) At) In 0 N)
              (fxvector-> State 1 (fx+ At N))
              (ok N)))))

(define output-buffer
  {buffer.view --> endpoint}
  V ->
    (let _ (writable V)
         State (memory-position)
      (endpoint "memory output" write 65536
        (function no-read)
        (/. In (memory-write V State In))
        (freeze (ok [])))))

)
