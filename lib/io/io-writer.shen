\\ Buffered writes over the endpoint transfer boundary.
(shen.x.namespace io
  (use buffer)
  (use option)
  (use result)
  (import result ok err)
  (use shen-jit)
  (externals [flush write])
  (export writer pending io.flush => flush io.write => write)

(define writer
  {endpoint --> buffer-options --> writer}
  E Options ->
    (let _ (check E write [])
         Cap (options E Options)
         W (:writer endpoint <- E buffer <- (buffer.new Cap) start <- 0 end <- 0 failure <- (option.none))
      (do (endpoint.writer-> E W) W)))

(define writer-check
  {writer --> writer}
  W -> (if (writer? W)
           (do (check (writer.endpoint W) write W) W)
           (error "io: not a writer")))

(define pending
  {writer --> fixnum}
  W -> (let _ (writer-check W) (fx- (writer.end W) (writer.start W))))

\\ A backend that raises fails the flush as one that returns an error does: what it had taken
\\ counts as progress, the rest stays, and new writes are refused until a flush succeeds.
(define io.flush
  {writer --> (io.result fixnum)}
  W ->
    (let _ (writer-check W)
         From (writer.start W)
      (trap-error (flush-loop W 0)
        (/. X (let Message (error-to-string X)
                   Error (io.error flush (endpoint.name (writer.endpoint W)) Message)
                   Count (fx- (writer.start W) From)
                (do (writer.failure-> W (option.some (progress Error Count)))
                    (simple-error Message)))))))

(define flush-loop
  {writer --> fixnum --> (io.result fixnum)}
  W Total ->
    (let At (writer.start W)
         End (writer.end W)
      (if (= At End)
          (do (writer.start-> W 0)
              (writer.end-> W 0)
              (writer.failure-> W (option.none))
              (ok Total))
          (flush-step W Total
            (write-raw (writer.endpoint W) (buffer.slice (writer.buffer W) At (fx- End At)) W)))))

(define flush-step
  {writer --> fixnum --> (io.result fixnum) --> (io.result fixnum)}
  W Total (:ok N) ->
    (do (writer.start-> W (fx+ (writer.start W) N)) (flush-loop W (fx+ Total N)))
  W Total (:err Error) ->
    (let Saved (progress Error Total)
      (do (writer.failure-> W (option.some Saved)) (err Saved))))

(define io.write
  {writer --> buffer.view --> (io.result fixnum)}
  W V ->
    (let _ (writer-check W)
         N (buffer.length V)
         Failure (writer.failure W)
      (cases (= N 0) (ok 0)
             (empty? Failure) (buffer-write W V 0 N)
             true (saved-write-error Failure))))

(define saved-write-error
  {(option.t io.error) --> (io.result fixnum)}
  [Error] -> (err (progress Error 0)))

\\ A successful flush resets both offsets. A failed flush blocks writes until retry.
(define buffer-write
  {writer --> buffer.view --> fixnum --> fixnum --> (io.result fixnum)}
  _ _ N N -> (ok N)
  W V At End ->
    (let B (writer.buffer W)
         Room (fx- (buffer.length B) (writer.end W))
      (if (= Room 0)
          (buffer-write-step W V At End (io.flush W))
          (let N (min-count Room (fx- End At))
            (do (buffer.copy! B (writer.end W) V At N)
                (writer.end-> W (fx+ (writer.end W) N))
                (buffer-write W V (fx+ At N) End))))))

(define buffer-write-step
  {writer --> buffer.view --> fixnum --> fixnum --> (io.result fixnum) --> (io.result fixnum)}
  W V At End (:ok _) -> (buffer-write W V At End)
  _ _ At _ (:err Error) -> (err (progress Error At)))

)
