\\ Independent bounded byte I/O. Load after lib/buffer.shen, under (tc -).
\\ Callbacks operate on fresh managed chunks; no kernel stream or I/O helper is used.
\\ One task owns an endpoint and its reader/writer. A lease prevents bypassing read-ahead.

(shen.x.namespace io
  (use buffer)
  (use shen-jit)
  (import struct defstruct)
  (externals [accepted callback chunk chunk-size closed eof flush io-error io-results library ok
    pending-timeout read-write retry-timeout shen timeout write written])
  (shadow count min)
  (export accept-result available buffer-options check chunk-result io.close => close
    close-result consume endpoint endpoint-check endpoint.busy endpoint.busy-> endpoint.close-result
    endpoint.context endpoint.context-> endpoint.guard endpoint.guard-> endpoint.mode endpoint.name
    endpoint.state reader.terminal io.error => error error-code error-domain
    error-message error-operation error-progress error-resource error-secondary error? finish
    io.flush => flush input-buffer join let-ok min native-error no-read no-write output-buffer
    peek peek-result peek-some peek-up-to pending position progress read-all read-chunk
    read-exact read-into read-result read-some reader reader-check reader-exact reader-terminal
    record result secondary tag? transfer-options transfer-result window window-fill window-size
    with-endpoint io.write => write write-all write-result write-some writer ok eof io-error)

(define min
  A B -> (if (< A B) A B))

(define record
  Fields -> (fill (absvector (length Fields)) 0 Fields))

(define fill
  V _ [] -> V
  V I [X | Rest] -> (fill (address-> V I X) (+ I 1) Rest))

(define tag?
  V Tag -> (trap-error (and (absvector? V) (= (<-address V 0) Tag)) (/. E false)))

(define capacity
  N ->
    (let I (buffer.index N)
      (if (and (> I 0) (<= I 1048576)) I (error "io: chunk size must be 1..1048576"))))

(define options
  E [] -> (endpoint.capacity E)
  E [[chunk-size N]] ->
    (let Cap (capacity N)
      (if (<= Cap (endpoint.capacity E)) Cap (error "io: chunk exceeds endpoint capacity")))
  _ _ -> (error "io: unsupported buffer options"))

(define transfer-options
  [] -> true
  _ -> (error "io: transfer options must currently be []"))

\\ Error fields: operation, domain, native code, resource, message, progress, secondary errors.
(define native-error
  Op Domain Code Resource Message -> [io-error Op Domain Code Resource Message 0 []])

(define io.error
  Op Resource Message -> (native-error Op library 0 Resource Message))

(define error?
  [io-error _ _ _ _ _ _ _] -> true
  _ -> false)

(define error-operation
  [io-error Op _ _ _ _ _ _] -> Op)

(define error-domain
  [io-error _ Domain _ _ _ _ _] -> Domain)

(define error-code
  [io-error _ _ Code _ _ _ _] -> Code)

(define error-resource
  [io-error _ _ _ Resource _ _ _] -> Resource)

(define error-message
  [io-error _ _ _ _ Message _ _] -> Message)

(define error-progress
  [io-error _ _ _ _ _ Progress _] -> Progress)

(define error-secondary
  [io-error _ _ _ _ _ _ Secondary] -> Secondary)

(define progress
  [io-error Op Domain Code Resource Message _ Secondary] N ->
    [io-error Op Domain Code Resource Message N Secondary])

(define secondary
  [io-error Op Domain Code Resource Message N Secondary] Other ->
    [io-error Op Domain Code Resource Message N (append Secondary [Other])])

\\ An endpoint: name, mode, capacity, read/write/close callbacks, state, remembered close result,
\\ reader/writer leases, in-flight flag, optional native guard and backend context, and the read
\\ chunks.
(define show-endpoint
  E -> (make-string "#<endpoint ~S ~A>" (endpoint.name E) (endpoint.state E)))

(defstruct endpoint
  (printer show-endpoint)
  name
  (mutable mode)
  (mutable capacity)
  read
  (mutable write)
  close
  (mutable state)
  (mutable close-result)
  (mutable reader)
  (mutable writer)
  (mutable busy)
  (mutable guard)
  (mutable context)
  (mutable scratch)
  (mutable scratch-below))

\\ A reader: its endpoint, bounded buffer, next/unfilled offsets, terminal result, position.
(define show-reader
  R -> (make-string "#<reader ~S at ~A>" (endpoint.name (reader.endpoint R)) (reader.position R)))

(defstruct reader
  (printer show-reader)
  endpoint
  buffer
  (mutable start)
  (mutable end)
  (mutable terminal)
  (mutable position))

\\ A writer: its endpoint, bounded buffer, sent/unfilled offsets, last flush error.
(define show-writer
  W -> (make-string "#<writer ~S ~A pending>" (endpoint.name (writer.endpoint W))
                    (- (writer.end W) (writer.start W))))

(defstruct writer
  (printer show-writer)
  endpoint
  buffer
  (mutable start)
  (mutable end)
  (mutable failure))

(define endpoint
  Name Mode Capacity Read Write Close ->
    (let Cap (capacity Capacity)
         _ (if (and (string? Name) (element? Mode [read write read-write]))
               true
               (error "io: invalid endpoint name or mode"))
      (:endpoint
        name <- Name
        mode <- Mode
        capacity <- Cap
        read <- Read
        write <- Write
        close <- Close
        state <- open
        close-result <- []
        reader <- []
        writer <- []
        busy <- false
        guard <- []
        context <- []
        scratch <- []
        scratch-below <- [])))

(define endpoint-check
  E -> (if (endpoint? E) E (error "io: not an endpoint")))

(define live?
  E ->
    (let Guard (endpoint.guard E)
      (or (empty? Guard) (not (= (shen-jit.pointer-address Guard) 0)))))

(define check
  E Direction Lease ->
    (let _ (endpoint-check E)
         _ (if (and (= (endpoint.state E) open) (live? E))
               true
               (error "io: endpoint is closed or stale"))
         _ (if (endpoint.busy E) (error "io: endpoint operation is already in flight") true)
         _ (if (or (= (endpoint.mode E) read-write) (= (endpoint.mode E) Direction))
               true
               (error "io: endpoint does not support ~A" Direction))
         Existing (if (= Direction read) (endpoint.reader E) (endpoint.writer E))
      (if (shen-jit.same? Existing Lease)
          E
          (error "io: endpoint is owned by a buffered reader or writer"))))

(define writable
  V ->
    (let Owner (buffer.owner V)
         Start (buffer.offset V)
      (do (shen-jit.copy-bytes Owner Start Owner Start 0) V)))

(define invoke
  E F ->
    (do (endpoint.busy-> E true)
        (let Result (trap-error (thaw F)
                       (/. X (do (endpoint.busy-> E false) (simple-error (error-to-string X)))))
          (do (endpoint.busy-> E false) Result))))

\\ Backend transfers use bounded scratch chunks. Validate the result before copying a read out.
(define count
  N Limit ->
    (let Count (buffer.index N)
      (if (and (> Count 0) (<= Count Limit))
          Count
          (error "io: backend returned an invalid transfer count"))))

(define read-result
  _ _ _ [eof] -> [eof]
  _ _ _ [error Error] ->
    (if (error? Error) [error Error] (error "io: malformed backend error"))
  _ V Chunk [read N] ->
    (let Count (count N (shen-jit.bytes-length Chunk))
      (do (shen-jit.copy-bytes (buffer.owner V) (buffer.offset V) Chunk 0 Count)
          [read Count]))
  _ _ _ _ -> (error "io: invalid backend read result"))

\\ A read's chunk, which the endpoint keeps and lends again; the backend copies into it and the read
\\ copies out at once. A reader asks for its whole free space: the same size while it keeps up, which
\\ gets the largest chunk asked for, and less while it waits for more of a value, which gets the
\\ largest power of two below, kept apart: a few chunks, each read at least half as large.
(define scratch
  E Size -> (let Full (endpoint.scratch E)
              (cases (or (= Full []) (> Size (shen-jit.bytes-length Full)))
                       (let B (shen-jit.bytes Size) (do (endpoint.scratch-> E B) B))
                     (= Size (shen-jit.bytes-length Full)) Full
                     true (scratch-below E (power-below Size 1)))))

(define scratch-below
  E Size -> (let Kept (endpoint.scratch-below E)
              (if (and (not (= Kept [])) (= (shen-jit.bytes-length Kept) Size))
                  Kept
                  (let B (shen-jit.bytes Size) (do (endpoint.scratch-below-> E B) B)))))

(define power-below
  Size P -> (if (> (* 2 P) Size) P (power-below Size (* 2 P))))

(define read-raw
  E V Lease ->
    (let _ (check E read Lease)
         _ (writable V)
         N (buffer.length V)
      (if (= N 0)
          [read 0]
          (let Chunk (scratch E (min N (endpoint.capacity E)))
               Read (endpoint.read E)
               Result (invoke E (freeze (Read Chunk)))
            (read-result E V Chunk Result)))))

(define write-result
  E _ [written 0] -> [error (io.error write (endpoint.name E) "backend made no progress")]
  _ Limit [written N] -> [written (count N Limit)]
  _ _ [error Error] ->
    (if (error? Error) [error Error] (error "io: malformed backend error"))
  _ _ _ -> (error "io: invalid backend write result"))

(define write-raw
  E V Lease ->
    (let _ (check E write Lease)
         N (buffer.length V)
      (if (= N 0)
          [written 0]
          (let Count (min N (endpoint.capacity E))
               Chunk (shen-jit.bytes Count)
               _ (shen-jit.copy-bytes Chunk 0 (buffer.owner V) (buffer.offset V) Count)
               Write (endpoint.write E)
               Result (invoke E (freeze (Write Chunk)))
            (write-result E Count Result)))))

(define read-some
  E V Options -> (do (transfer-options Options) (read-raw E V [])))

(define write-some
  E V Options -> (do (transfer-options Options) (write-raw E V [])))

(define read-exact
  E V Options ->
    (do (transfer-options Options)
        (check E read [])
        (writable V)
        (exact-loop E V 0 (buffer.length V))))

(define exact-loop
  _ _ N N -> [ok N]
  E V At End -> (exact-step E V At End (read-raw E (buffer.slice V At (- End At)) [])))

(define exact-step
  E V At End [read N] -> (exact-loop E V (+ At N) End)
  _ _ At _ [eof] -> [eof At]
  _ _ At _ [error Error] -> [error (progress Error At) At])

(define write-all
  E V Options ->
    (do (transfer-options Options)
        (check E write [])
        (all-loop E V 0 (buffer.length V))))

(define all-loop
  _ _ N N -> [ok N]
  E V At End -> (all-step E V At End (write-raw E (buffer.slice V At (- End At)) [])))

(define all-step
  E V At End [written N] -> (all-loop E V (+ At N) End)
  _ _ At _ [error Error] -> [error (progress Error At) At])

(define reader
  E Options ->
    (let _ (check E read [])
         Cap (options E Options)
         R (:reader
             endpoint <- E
             buffer <- (buffer.new Cap)
             start <- 0
             end <- 0
             terminal <- []
             position <- 0)
      (do (endpoint.reader-> E R) R)))

(define timeout-result?
  [retry-timeout _] -> true
  _ -> false)

(define reader-terminal
  R -> (terminal-result R (reader.terminal R)))

(define terminal-result
  R [pending-timeout Error] ->
    (do (reader.terminal-> R [retry-timeout Error]) [error Error])
  _ Terminal -> Terminal)

(define reader-check
  R -> (if (reader? R)
           (do (check (reader.endpoint R) read R)
               (if (timeout-result? (reader.terminal R)) (reader.terminal-> R []) true)
               R)
           (error "io: not a reader")))

(define available
  R -> (let _ (reader-check R) (- (reader.end R) (reader.start R))))

(define position
  R -> (reader.position (reader-check R)))

(define fill-reader
  R Need ->
    (if (or (>= (- (reader.end R) (reader.start R)) Need) (not (empty? (reader.terminal R))))
        R
        (let B (reader.buffer R)
             At (reader.start R)
             End (reader.end R)
             _ (if (> At 0)
                   (do (buffer.copy! B 0 B At (- End At))
                       (reader.start-> R 0)
                       (reader.end-> R (- End At)))
                   true)
             Tail (buffer.slice B (reader.end R) (- (buffer.length B) (reader.end R)))
             Result (read-raw (reader.endpoint R) Tail R)
          (fill-step R Need Result))))

(define fill-step
  R Need [read N] -> (do (reader.end-> R (+ (reader.end R) N)) (fill-reader R Need))
  R _ [error Error] ->
    (do (reader.terminal-> R (if (= (error-domain Error) timeout)
                           [pending-timeout Error]
                           [error Error]))
        R)
  R _ Terminal -> (do (reader.terminal-> R Terminal) R))

(define peek
  R Count ->
    (let _ (reader-check R)
         N (buffer.index Count)
         B (reader.buffer R)
         _ (buffer.range (buffer.length B) 0 N)
         _ (fill-reader R N)
         Available (- (reader.end R) (reader.start R))
      (if (or (> Available 0) (= N 0))
          [ok (buffer.wrap (buffer.bytes (buffer.slice B (reader.start R) (min N Available))))]
          (reader-terminal R))))

\\ Unlike peek Count, this waits only for some input, then exposes an owned available span.
(define peek-some
  R -> (do (reader-check R) (peek-up-to R (buffer.length (reader.buffer R)))))

\\ Wait for one byte, then copy no more than Count from the available span.
\\ This bounds copying for a short delimiter without waiting to fill Count bytes.
(define peek-up-to
  R Count ->
    (let _ (reader-check R)
         Maximum (buffer.index Count)
         _ (fill-reader R (if (= Maximum 0) 0 1))
         N (- (reader.end R) (reader.start R))
      (if (or (> N 0) (= Maximum 0))
          [ok (buffer.wrap (buffer.bytes (buffer.slice (reader.buffer R) (reader.start R)
                                                     (min N Maximum))))]
          (reader-terminal R))))

\\ For a parser that reads the queue in place: the queue moves to the start of the reader's buffer,
\\ and fills append to it until something is consumed, so positions in the window stay valid.
\\ io.window gives the buffer's storage, io.window-fill fills it towards Need bytes, as far as the
\\ input and the buffer allow, and gives how many it holds, and io.window-size is its capacity.
(define window
  R -> (let _ (reader-check R)
            B (reader.buffer R) At (reader.start R) End (reader.end R)
            _ (if (> At 0)
                  (do (buffer.copy! B 0 B At (- End At)) (reader.start-> R 0) (reader.end-> R (- End At)))
                  true)
         (buffer.owner B)))

(define window-fill
  R Need -> (let _ (reader-check R)
                 N (buffer.index Need)
              (do (fill-reader R (min N (buffer.length (reader.buffer R)))) (reader.end R))))

(define window-size
  R -> (buffer.length (reader.buffer R)))

(define consume
  R Count ->
    (let _ (reader-check R)
         N (buffer.index Count)
         _ (buffer.range (- (reader.end R) (reader.start R)) 0 N)
      (do (reader.start-> R (+ (reader.start R) N))
          (reader.position-> R (+ (reader.position R) N))
          R)))

(define read-chunk
  R ->
    (let _ (reader-check R)
         _ (fill-reader R 1)
         N (- (reader.end R) (reader.start R))
      (if (> N 0)
          (let Out (buffer.wrap (buffer.bytes (buffer.slice (reader.buffer R) (reader.start R) N)))
            (do (consume R N) [chunk Out]))
          (reader-terminal R))))

(define read-into
  R V ->
    (let _ (reader-check R)
         _ (writable V)
         Count (buffer.length V)
      (if (= Count 0)
          [read 0]
          (let _ (fill-reader R 1)
               N (min Count (- (reader.end R) (reader.start R)))
            (if (> N 0)
                (do (buffer.copy! V 0 (reader.buffer R) (reader.start R) N)
                    (consume R N)
                    [read N])
                (reader-terminal R))))))

(define reader-exact
  R V ->
    (do (reader-check R)
        (writable V)
        (reader-exact-loop R V 0 (buffer.length V))))

(define reader-exact-loop
  _ _ N N -> [ok N]
  R V At End -> (reader-exact-step R V At End (read-into R (buffer.slice V At (- End At)))))

(define reader-exact-step
  R V At End [read N] -> (reader-exact-loop R V (+ At N) End)
  _ _ At _ [eof] -> [eof At]
  _ _ At _ [error Error] -> [error (progress Error At) At])

\\ Whole-input aggregation has an explicit limit. A limit failure does not consume the next byte.
(define read-all
  R Limit -> (do (reader-check R) (buffer.index Limit) (collect R Limit 0 [])))

(define collect
  R Limit Total Chunks ->
    (if (= Total Limit)
        (collect-limit R Total Chunks (peek R 1))
        (collect-step R Limit Total Chunks
          (peek R (min (- Limit Total) (buffer.length (reader.buffer R)))))))

(define collect-step
  R Limit Total Chunks [ok V] ->
    (let N (buffer.length V)
      (do (consume R N) (collect R Limit (+ Total N) [V | Chunks])))
  _ _ Total Chunks [eof] -> [ok (join Total (reverse Chunks))]
  _ _ Total _ [error Error] -> [error (progress Error Total)])

(define collect-limit
  _ Total Chunks [eof] -> [ok (join Total (reverse Chunks))]
  _ Total _ [error Error] -> [error (progress Error Total)]
  R Total _ [ok _] ->
    [error (progress (io.error read (endpoint.name (reader.endpoint R)) "input exceeds limit") Total)])

(define join
  N Chunks -> (join-loop (buffer.new N) 0 Chunks))

(define join-loop
  Out _ [] -> Out
  Out At [V | Rest] ->
    (do (buffer.copy! Out At V 0 (buffer.length V))
        (join-loop Out (+ At (buffer.length V)) Rest)))

(define writer
  E Options ->
    (let _ (check E write [])
         Cap (options E Options)
         W (:writer endpoint <- E buffer <- (buffer.new Cap) start <- 0 end <- 0 failure <- [])
      (do (endpoint.writer-> E W) W)))

(define writer-check
  W -> (if (writer? W)
           (do (check (writer.endpoint W) write W) W)
           (error "io: not a writer")))

(define pending
  W -> (let _ (writer-check W) (- (writer.end W) (writer.start W))))

\\ A backend that raises fails the flush as one that returns an error does: what it had taken
\\ counts as progress, the rest stays, and new writes are refused until a flush succeeds.
(define io.flush
  W -> (let _ (writer-check W)
            From (writer.start W)
         (trap-error (flush-loop W 0)
           (/. X (do (writer.failure-> W (progress (io.error flush (endpoint.name (writer.endpoint W))
                                                             (error-to-string X))
                                                   (- (writer.start W) From)))
                     (simple-error (error-to-string X)))))))

(define flush-loop
  W Total ->
    (let At (writer.start W)
         End (writer.end W)
      (if (= At End)
          (do (writer.start-> W 0)
              (writer.end-> W 0)
              (writer.failure-> W [])
              [ok Total])
          (flush-step W Total
            (write-raw (writer.endpoint W) (buffer.slice (writer.buffer W) At (- End At)) W)))))

(define flush-step
  W Total [written N] ->
    (do (writer.start-> W (+ (writer.start W) N)) (flush-loop W (+ Total N)))
  W Total [error Error] ->
    (let Saved (progress Error Total)
      (do (writer.failure-> W Saved) [error Saved Total])))

(define io.write
  W V ->
    (let _ (writer-check W)
         N (buffer.length V)
      (cond ((= N 0) [accepted 0])
            ((not (empty? (writer.failure W))) [error (progress (writer.failure W) 0) 0])
            (true (buffer-write W V 0 N)))))

(define buffer-write
  _ _ N N -> [accepted N]
  W V At End ->
    (let B (writer.buffer W)
         Sent (writer.start W)
         Used (writer.end W)
         _ (if (> Sent 0)
               (do (buffer.copy! B 0 B Sent (- Used Sent))
                   (writer.start-> W 0)
                   (writer.end-> W (- Used Sent)))
               true)
         Room (- (buffer.length B) (writer.end W))
      (if (= Room 0)
          (buffer-write-step W V At End (io.flush W))
          (let N (min Room (- End At))
            (do (buffer.copy! B (writer.end W) V At N)
                (writer.end-> W (+ (writer.end W) N))
                (buffer-write W V (+ At N) End))))))

(define buffer-write-step
  W V At End [ok _] -> (buffer-write W V At End)
  _ _ At _ [error Error _] -> [error (progress Error At) At])

\\ Close always attempts cleanup after a flush failure, then remembers the combined result.
(define close-result
  _ [ok] -> [ok]
  _ [error Error] ->
    (if (error? Error) [error Error] (error "io: malformed close error"))
  E _ -> [error (io.error close (endpoint.name E) "invalid backend close result")])

(define io.close
  E ->
    (let _ (endpoint-check E)
      (cond ((= (endpoint.state E) closed) (endpoint.close-result E))
            ((endpoint.busy E) (error "io: endpoint operation is already in flight"))
            ((not (live? E))
              (let Result [error (io.error close (endpoint.name E) "native endpoint is stale")]
                (do (endpoint.state-> E closed)
                    (endpoint.close-result-> E Result)
                    Result)))
            (true
              (let W (endpoint.writer E)
                   Flush (if (empty? W)
                             [ok 0]
                             (trap-error (io.flush W)
                               (/. X (let Failure (writer.failure W)
                                       (if (empty? Failure)
                                           [error (io.error flush (endpoint.name E) (error-to-string X)) 0]
                                           [error Failure (io.error-progress Failure)])))))
                   _ (endpoint.state-> E closed)
                   _ (endpoint.close-result-> E [error (io.error close (endpoint.name E) "close is in progress")])
                   Close (endpoint.close E)
                   Result (trap-error (close-result E (thaw Close))
                            (/. X [error (io.error close (endpoint.name E) (error-to-string X))]))
                   Final (close-combine Flush Result)
                (do (endpoint.close-result-> E Final) Final))))))

(define close-combine
  [ok _] Result -> Result
  [error Error _] [ok] -> [error Error]
  [error Error _] [error Other] -> [error (secondary Error Other)])

(define finish
  [ok Value] [ok] -> [ok Value]
  [ok _] [error Error] -> [error Error]
  [error Error] [ok] -> [error Error]
  [error Error] [error Other] -> [error (secondary Error Other)])

(define scope-result
  _ [ok Value] -> [ok Value]
  _ [error Error] ->
    (if (error? Error) [error Error] (error "io: malformed scope error"))
  E _ -> [error (io.error callback (endpoint.name E) "callback must return [ok Value] or [error Error]")])

(define with-endpoint
  E F ->
    (let _ (endpoint-check E)
         _ (if (and (= (endpoint.state E) open) (live? E))
               true
               (error "io: endpoint is closed or stale"))
         _ (if (endpoint.busy E) (error "io: endpoint operation is already in flight") true)
         Result (trap-error (scope-result E (F E))
                  (/. X [error (native-error callback shen 0 (endpoint.name E) (error-to-string X))]))
      (finish Result (io.close E))))

\\ Memory input owns a snapshot; memory output borrows a fixed writable range.
(define no-read
  _ -> (error "io: endpoint is not readable"))

(define no-write
  _ -> (error "io: endpoint is not writable"))

(define input-buffer
  V ->
    (let B (buffer.bytes V)
         State (record [0])
      (endpoint "memory input" read 65536
        (/. Out (let At (<-address State 0)
                     N (min (shen-jit.bytes-length Out) (- (shen-jit.bytes-length B) At))
                  (if (= N 0)
                      [eof]
                      (do (shen-jit.copy-bytes Out 0 B At N)
                          (address-> State 0 (+ At N))
                          [read N]))))
        (function no-write)
        (freeze [ok]))))

(define output-buffer
  V ->
    (let _ (writable V)
         State (record [0])
      (endpoint "memory output" write 65536
        (function no-read)
        (/. In (let At (<-address State 0)
                    N (min (shen-jit.bytes-length In) (- (buffer.length V) At))
                 (if (= N 0)
                     [error (io.error write "memory output" "output buffer is full")]
                     (do (shen-jit.copy-bytes (buffer.owner V) (+ (buffer.offset V) At) In 0 N)
                         (address-> State 0 (+ At N))
                         [written N]))))
        (freeze [ok]))))

\\ Opaque resources with explicit, pattern-matchable outcomes for typed clients.
(datatype io-results
  N : number;
  =====================
  [read N] : read-result;

  _____________________
  [eof] : read-result;

  Error : io.error;
  =====================
  [error Error] : read-result;

  N : number;
  =====================
  [written N] : write-result;

  Error : io.error;
  =====================
  [error Error] : write-result;

  N : number;
  =====================
  [ok N] : transfer-result;

  N : number;
  =====================
  [eof N] : transfer-result;

  Error : io.error; N : number;
  =====================
  [error Error N] : transfer-result;

  V : A;
  =====================
  [ok V] : (result A);

  Error : io.error;
  =====================
  [error Error] : (result A);

  V : buffer.view;
  =====================
  [ok V] : peek-result;

  _____________________
  [eof] : peek-result;

  Error : io.error;
  =====================
  [error Error] : peek-result;

  V : buffer.view;
  =====================
  [chunk V] : chunk-result;

  _____________________
  [eof] : chunk-result;

  Error : io.error;
  =====================
  [error Error] : chunk-result;

  N : number;
  =====================
  [accepted N] : accept-result;

  Error : io.error; N : number;
  =====================
  [error Error N] : accept-result;

  _____________________
  [ok] : close-result;

  Error : io.error;
  =====================
  [error Error] : close-result;

  _____________________
  [] : transfer-options;

  _____________________
  [] : buffer-options;

  N : number;
  =====================
  [[chunk-size N]] : buffer-options;)

\\ (io.let-ok X Result ... Body): Body with each X bound to the value of [ok X], in order, or the
\\ first result that is not ok, as it is. _ takes [ok] or [ok X] and binds nothing. The libraries
\\ read after this one use it for their chains of results.
(defmacro let-ok-macro
  [let-ok Body] -> Body
  [let-ok X Result | More] ->
    (let R (gensym (protect R))
      [let R Result
        [if [and [cons? R] [= [hd R] ok]]
            (if (= (str X) "_") [let-ok | More] [let X [hd [tl R]] [let-ok | More]])
            R]]))

(declare io.error [symbol --> [string --> [string --> io.error]]])
(declare native-error [symbol --> [symbol --> [number --> [string --> [string --> io.error]]]]])
(declare error? [A --> boolean])
(declare error-operation [io.error --> symbol])
(declare error-domain [io.error --> symbol])
(declare error-code [io.error --> number])
(declare error-resource [io.error --> string])
(declare error-message [io.error --> string])
(declare error-progress [io.error --> number])
(declare error-secondary [io.error --> [list io.error]])
(declare endpoint
  [string --> [symbol --> [number --> [[buffer.storage --> read-result] -->
    [[buffer.storage --> write-result] --> [[lazy close-result] --> endpoint]]]]]])
(declare no-read [buffer.storage --> read-result])
(declare no-write [buffer.storage --> write-result])
(declare input-buffer [buffer.view --> endpoint])
(declare output-buffer [buffer.view --> endpoint])
(declare read-some [endpoint --> [buffer.view --> [transfer-options --> read-result]]])
(declare write-some [endpoint --> [buffer.view --> [transfer-options --> write-result]]])
(declare read-exact [endpoint --> [buffer.view --> [transfer-options --> transfer-result]]])
(declare write-all [endpoint --> [buffer.view --> [transfer-options --> transfer-result]]])
(declare reader [endpoint --> [buffer-options --> reader]])
(declare available [reader --> number])
(declare position [reader --> number])
(declare peek [reader --> [number --> peek-result]])
(declare peek-some [reader --> peek-result])
(declare peek-up-to [reader --> [number --> peek-result]])
(declare consume [reader --> [number --> reader]])
(declare read-chunk [reader --> chunk-result])
(declare window [reader --> buffer.storage])
(declare window-fill [reader --> [number --> number]])
(declare window-size [reader --> number])
(declare read-into [reader --> [buffer.view --> read-result]])
(declare reader-exact [reader --> [buffer.view --> transfer-result]])
(declare read-all [reader --> [number --> [result buffer.view]]])
(declare writer [endpoint --> [buffer-options --> writer]])
(declare pending [writer --> number])
(declare io.write [writer --> [buffer.view --> accept-result]])
(declare io.flush [writer --> transfer-result])
(declare io.close [endpoint --> close-result])
(declare with-endpoint [endpoint --> [[endpoint --> [result A]] --> [result A]]])

)
