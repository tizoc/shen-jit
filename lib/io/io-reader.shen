\\ Buffered reader operations over the endpoint's checked transfer boundary.
(shen.x.namespace io
  (use buffer)
  (use option)
  (use result)
  (import result ok err)
  (use shen-jit)
  (externals [eof failed ready timeout])
  (export available consume join peek peek-some peek-up-to position read-all read-chunk
    read-into reader reader-check reader-exact reader-status reader-terminal window window-fill
    window-size)

(define min-count
  {fixnum --> fixnum --> fixnum}
  A B -> (if (fx< A B) A B))

(define writable
  {buffer.view --> buffer.view}
  V ->
    (let Owner (buffer.owner V)
         Start (buffer.offset V)
      (do (shen-jit.copy-bytes Owner Start Owner Start 0) V)))

(define reader
  {endpoint --> buffer-options --> reader}
  E Options ->
    (let _ (check E read [])
         Cap (options E Options)
         R (:reader
             endpoint <- E
             buffer <- (buffer.new Cap)
             start <- 0
             end <- 0
             end-result <- (option.none)
             retry-timeout <- false
             position <- 0)
      (do (endpoint.reader-> E R) R)))

\\ Inspecting the status leaves a pending timeout unreported.
(define reader-status
  {reader --> symbol}
  R -> (end-status (reader.end-result R)))

(define end-status
  {(option.t (io.result result.empty)) --> symbol}
  [] -> ready
  [(:ok _)] -> eof
  [(:err _)] -> failed)

(define reader-terminal
  {reader --> (io.result (option.t A))}
  R -> (terminal-result R (reader.end-result R)))

(define terminal-result
  {reader --> (option.t (io.result result.empty)) --> (io.result (option.t A))}
  _ [(:ok _)] -> (ok (option.none))
  R [(:err Error)] ->
    (do (if (= (error-domain Error) timeout) (reader.retry-timeout-> R true) R)
        (err Error))
  _ [] -> (error "io: reader has no terminal result"))

(define reader-check
  {reader --> reader}
  R ->
    (if (reader? R)
        (do (check (reader.endpoint R) read R)
            (if (reader.retry-timeout R)
                (do (reader.end-result-> R (option.none)) (reader.retry-timeout-> R false))
                R)
            R)
        (error "io: not a reader")))

(define available
  {reader --> fixnum}
  R -> (let _ (reader-check R) (fx- (reader.end R) (reader.start R))))

(define position
  {reader --> fixnum}
  R -> (reader.position (reader-check R)))

(define compact-reader
  {reader --> reader}
  R ->
    (let At (reader.start R)
      (if (fx> At 0)
          (let B (reader.buffer R)
               N (fx- (reader.end R) At)
            (do (buffer.copy! B 0 B At N)
                (reader.start-> R 0)
                (reader.end-> R N)))
          R)))

(define fill-reader
  {reader --> fixnum --> reader}
  R Need ->
    (if (or (fx>= (fx- (reader.end R) (reader.start R)) Need)
            (not (empty? (reader.end-result R))))
        R
        (let _ (compact-reader R)
             B (reader.buffer R)
             End (reader.end R)
             Tail (buffer.slice B End (fx- (buffer.length B) End))
          (fill-step R Need (read-raw (reader.endpoint R) Tail R)))))

(define fill-step
  {reader --> fixnum --> (io.result (option.t fixnum)) --> reader}
  R Need (:ok [N]) -> (do (reader.end-> R (fx+ (reader.end R) N)) (fill-reader R Need))
  R _ (:ok []) -> (reader.end-result-> R (option.some (ok [])))
  R _ (:err Error) -> (reader.end-result-> R (option.some (err Error))))

(define owned-span
  {reader --> fixnum --> buffer.view}
  R N -> (buffer.wrap (buffer.bytes (buffer.slice (reader.buffer R) (reader.start R) N))))

(define peek
  {reader --> fixnum --> (io.result (option.t buffer.view))}
  R Count ->
    (let _ (reader-check R)
         N (buffer.index Count)
         B (reader.buffer R)
         _ (buffer.range (buffer.length B) 0 N)
         _ (fill-reader R N)
         Available (fx- (reader.end R) (reader.start R))
      (if (or (fx> Available 0) (= N 0))
          (ok (option.some (owned-span R (min-count N Available))))
          (reader-terminal R))))

\\ Unlike peek Count, this waits only for some input, then exposes an owned available span.
(define peek-some
  {reader --> (io.result (option.t buffer.view))}
  R -> (do (reader-check R) (peek-up-to R (buffer.length (reader.buffer R)))))

\\ Wait for one byte, then copy no more than Count from the available span.
\\ This bounds copying for a short delimiter without waiting to fill Count bytes.
(define peek-up-to
  {reader --> fixnum --> (io.result (option.t buffer.view))}
  R Count ->
    (let _ (reader-check R)
         Maximum (buffer.index Count)
         _ (fill-reader R (if (= Maximum 0) 0 1))
         N (fx- (reader.end R) (reader.start R))
      (if (or (fx> N 0) (= Maximum 0))
          (ok (option.some (owned-span R (min-count N Maximum))))
          (reader-terminal R))))

\\ For a parser that reads the queue in place: the queue moves to the start of the reader's buffer,
\\ and fills append to it until something is consumed, so positions in the window stay valid.
\\ io.window gives the buffer's storage, io.window-fill fills it towards Need bytes, as far as the
\\ input and the buffer allow, and gives how many it holds, and io.window-size is its capacity.
(define window
  {reader --> buffer.storage}
  R -> (buffer.owner (reader.buffer (compact-reader (reader-check R)))))

(define window-fill
  {reader --> fixnum --> fixnum}
  R Need -> (let _ (reader-check R)
                 N (buffer.index Need)
              (do (fill-reader R (min-count N (buffer.length (reader.buffer R)))) (reader.end R))))

(define window-size
  {reader --> fixnum}
  R -> (buffer.length (reader.buffer R)))

(define consume
  {reader --> fixnum --> reader}
  R Count ->
    (let _ (reader-check R)
         N (buffer.index Count)
         _ (buffer.range (fx- (reader.end R) (reader.start R)) 0 N)
      (do (reader.start-> R (fx+ (reader.start R) N))
          (reader.position-> R (fx+ (reader.position R) N))
          R)))

(define read-chunk
  {reader --> (io.result (option.t buffer.view))}
  R ->
    (let _ (reader-check R)
         _ (fill-reader R 1)
         N (fx- (reader.end R) (reader.start R))
      (if (fx> N 0)
          (let Out (owned-span R N)
            (do (consume R N) (ok (option.some Out))))
          (reader-terminal R))))

(define read-into
  {reader --> buffer.view --> (io.result (option.t fixnum))}
  R V ->
    (let _ (reader-check R)
         _ (writable V)
         Count (buffer.length V)
      (if (= Count 0)
          (ok (option.some 0))
          (let _ (fill-reader R 1)
               N (min-count Count (fx- (reader.end R) (reader.start R)))
            (if (fx> N 0)
                (do (buffer.copy! V 0 (reader.buffer R) (reader.start R) N)
                    (consume R N)
                    (ok (option.some N)))
                (reader-terminal R))))))

(define reader-exact
  {reader --> buffer.view --> (io.result transfer)}
  R V ->
    (do (reader-check R)
        (writable V)
        (reader-exact-loop R V 0 (buffer.length V))))

(define reader-exact-loop
  {reader --> buffer.view --> fixnum --> fixnum --> (io.result transfer)}
  _ _ N N -> (ok (:transfer true N))
  R V At End -> (reader-exact-step R V At End (read-into R (buffer.slice V At (fx- End At)))))

(define reader-exact-step
  {reader --> buffer.view --> fixnum --> fixnum -->
   (io.result (option.t fixnum)) --> (io.result transfer)}
  R V At End (:ok [N]) -> (reader-exact-loop R V (fx+ At N) End)
  _ _ At _ (:ok []) -> (ok (:transfer false At))
  _ _ At _ (:err Error) -> (err (progress Error At)))

\\ Whole-input aggregation has an explicit limit. A limit failure does not consume the next byte.
(define read-all
  {reader --> fixnum --> (io.result buffer.view)}
  R Limit -> (do (reader-check R) (collect R (buffer.index Limit) 0 [])))

(define collect
  {reader --> fixnum --> fixnum --> (list buffer.view) --> (io.result buffer.view)}
  R Limit Total Chunks ->
    (if (= Total Limit)
        (collect-limit R Total Chunks (peek R 1))
        (collect-step R Limit Total Chunks
          (peek R (min-count (fx- Limit Total) (buffer.length (reader.buffer R)))))))

(define collect-step
  {reader --> fixnum --> fixnum --> (list buffer.view) -->
   (io.result (option.t buffer.view)) --> (io.result buffer.view)}
  R Limit Total Chunks (:ok [V]) ->
    (let N (buffer.length V)
      (do (consume R N) (collect R Limit (fx+ Total N) [V | Chunks])))
  _ _ Total Chunks (:ok []) -> (ok (join Total (reverse Chunks)))
  _ _ Total _ (:err Error) -> (err (progress Error Total)))

(define collect-limit
  {reader --> fixnum --> (list buffer.view) -->
   (io.result (option.t buffer.view)) --> (io.result buffer.view)}
  _ Total Chunks (:ok []) -> (ok (join Total (reverse Chunks)))
  _ Total _ (:err Error) -> (err (progress Error Total))
  R Total _ (:ok [_]) ->
    (err (progress (io.error read (endpoint.name (reader.endpoint R)) "input exceeds limit") Total)))

(define join
  {fixnum --> (list buffer.view) --> buffer.view}
  N Chunks -> (join-loop (buffer.new N) 0 Chunks))

(define join-loop
  {buffer.view --> fixnum --> (list buffer.view) --> buffer.view}
  Out _ [] -> Out
  Out At [V | Rest] ->
    (do (buffer.copy! Out At V 0 (buffer.length V))
        (join-loop Out (fx+ At (buffer.length V)) Rest)))

)
