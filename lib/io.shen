\\ Independent bounded byte I/O. Load after lib/buffer.shen, under (tc -).
\\ Callbacks operate on fresh managed chunks; no kernel stream or I/O helper is used.
\\ One task owns an endpoint and its reader/writer. A lease prevents bypassing read-ahead.

(define io.min
  A B -> (if (< A B) A B))

(define io.record
  Fields -> (io.fill (absvector (length Fields)) 0 Fields))

(define io.fill
  V _ [] -> V
  V I [X | Rest] -> (io.fill (address-> V I X) (+ I 1) Rest))

(define io.tag?
  V Tag -> (trap-error (and (absvector? V) (= (<-address V 0) Tag)) (/. E false)))

(define io.capacity
  N ->
    (let I (buffer.index N)
      (if (and (> I 0) (<= I 1048576)) I (error "io: chunk size must be 1..1048576"))))

(define io.options
  E [] -> (<-address E 3)
  E [[chunk-size N]] ->
    (let Cap (io.capacity N)
      (if (<= Cap (<-address E 3)) Cap (error "io: chunk exceeds endpoint capacity")))
  _ _ -> (error "io: unsupported buffer options"))

(define io.transfer-options
  [] -> true
  _ -> (error "io: transfer options must currently be []"))

\\ Error fields: operation, domain, native code, resource, message, progress, secondary errors.
(define io.native-error
  Op Domain Code Resource Message -> [io-error Op Domain Code Resource Message 0 []])

(define io.error
  Op Resource Message -> (io.native-error Op library 0 Resource Message))

(define io.error?
  [io-error _ _ _ _ _ _ _] -> true
  _ -> false)

(define io.error-operation
  [io-error Op _ _ _ _ _ _] -> Op)

(define io.error-domain
  [io-error _ Domain _ _ _ _ _] -> Domain)

(define io.error-code
  [io-error _ _ Code _ _ _ _] -> Code)

(define io.error-resource
  [io-error _ _ _ Resource _ _ _] -> Resource)

(define io.error-message
  [io-error _ _ _ _ Message _ _] -> Message)

(define io.error-progress
  [io-error _ _ _ _ _ Progress _] -> Progress)

(define io.error-secondary
  [io-error _ _ _ _ _ _ Secondary] -> Secondary)

(define io.progress
  [io-error Op Domain Code Resource Message _ Secondary] N ->
    [io-error Op Domain Code Resource Message N Secondary])

(define io.secondary
  [io-error Op Domain Code Resource Message N Secondary] Other ->
    [io-error Op Domain Code Resource Message N (append Secondary [Other])])

\\ Endpoint slots: tag, name, mode, capacity, read/write/close callbacks, state,
\\ remembered close result, reader/writer leases, in-flight flag, optional native guard and backend context,
\\ and the read chunks.
(define io.endpoint
  Name Mode Capacity Read Write Close ->
    (let Cap (io.capacity Capacity)
         _ (if (and (string? Name) (element? Mode [read write read-write]))
               true
               (error "io: invalid endpoint name or mode"))
      (io.record [io.endpoint Name Mode Cap Read Write Close open [] [] [] false [] [] [] []])))

(define io.endpoint-check
  E -> (if (io.tag? E io.endpoint) E (error "io: not an endpoint")))

(define io.live?
  E ->
    (let Guard (<-address E 12)
      (or (empty? Guard) (not (= (shen-jit.pointer-address Guard) 0)))))

(define io.check
  E Direction Lease ->
    (let _ (io.endpoint-check E)
         _ (if (and (= (<-address E 7) open) (io.live? E))
               true
               (error "io: endpoint is closed or stale"))
         _ (if (<-address E 11) (error "io: endpoint operation is already in flight") true)
         _ (if (or (= (<-address E 2) read-write) (= (<-address E 2) Direction))
               true
               (error "io: endpoint does not support ~A" Direction))
         Existing (<-address E (if (= Direction read) 9 10))
      (if (shen-jit.same? Existing Lease)
          E
          (error "io: endpoint is owned by a buffered reader or writer"))))

(define io.writable
  V ->
    (let Owner (buffer.owner V)
         Start (buffer.offset V)
      (do (shen-jit.copy-bytes Owner Start Owner Start 0) V)))

(define io.invoke
  E F ->
    (do (address-> E 11 true)
        (let Result (trap-error (thaw F)
                       (/. X (do (address-> E 11 false) (simple-error (error-to-string X)))))
          (do (address-> E 11 false) Result))))

\\ Backend transfers use bounded scratch chunks. Validate the result before copying a read out.
(define io.count
  N Limit ->
    (let Count (buffer.index N)
      (if (and (> Count 0) (<= Count Limit))
          Count
          (error "io: backend returned an invalid transfer count"))))

(define io.read-result
  _ _ _ [eof] -> [eof]
  _ _ _ [error Error] ->
    (if (io.error? Error) [error Error] (error "io: malformed backend error"))
  _ V Chunk [read N] ->
    (let Count (io.count N (shen-jit.bytes-length Chunk))
      (do (shen-jit.copy-bytes (buffer.owner V) (buffer.offset V) Chunk 0 Count)
          [read Count]))
  _ _ _ _ -> (error "io: invalid backend read result"))

\\ A read's chunk, which the endpoint keeps and lends again; the backend copies into it and the read
\\ copies out at once. A reader asks for its whole free space: the same size while it keeps up, which
\\ gets the largest chunk asked for, and less while it waits for more of a value, which gets the
\\ largest power of two below, kept apart: a few chunks, each read at least half as large.
(define io.scratch
  E Size -> (let Full (<-address E 14)
              (cases (or (= Full []) (> Size (shen-jit.bytes-length Full))) (io.keep E 14 (shen-jit.bytes Size))
                     (= Size (shen-jit.bytes-length Full)) Full
                     true (io.scratch-below E (io.power-below Size 1)))))

(define io.scratch-below
  E Size -> (let Kept (<-address E 15)
              (if (and (not (= Kept [])) (= (shen-jit.bytes-length Kept) Size))
                  Kept
                  (io.keep E 15 (shen-jit.bytes Size)))))

(define io.power-below
  Size P -> (if (> (* 2 P) Size) P (io.power-below Size (* 2 P))))

(define io.keep
  E Slot B -> (do (address-> E Slot B) B))

(define io.read-raw
  E V Lease ->
    (let _ (io.check E read Lease)
         _ (io.writable V)
         N (buffer.length V)
      (if (= N 0)
          [read 0]
          (let Chunk (io.scratch E (io.min N (<-address E 3)))
               Read (<-address E 4)
               Result (io.invoke E (freeze (Read Chunk)))
            (io.read-result E V Chunk Result)))))

(define io.write-result
  E _ [written 0] -> [error (io.error write (<-address E 1) "backend made no progress")]
  _ Limit [written N] -> [written (io.count N Limit)]
  _ _ [error Error] ->
    (if (io.error? Error) [error Error] (error "io: malformed backend error"))
  _ _ _ -> (error "io: invalid backend write result"))

(define io.write-raw
  E V Lease ->
    (let _ (io.check E write Lease)
         N (buffer.length V)
      (if (= N 0)
          [written 0]
          (let Count (io.min N (<-address E 3))
               Chunk (shen-jit.bytes Count)
               _ (shen-jit.copy-bytes Chunk 0 (buffer.owner V) (buffer.offset V) Count)
               Write (<-address E 5)
               Result (io.invoke E (freeze (Write Chunk)))
            (io.write-result E Count Result)))))

(define io.read-some
  E V Options -> (do (io.transfer-options Options) (io.read-raw E V [])))

(define io.write-some
  E V Options -> (do (io.transfer-options Options) (io.write-raw E V [])))

(define io.read-exact
  E V Options ->
    (do (io.transfer-options Options)
        (io.check E read [])
        (io.writable V)
        (io.exact-loop E V 0 (buffer.length V))))

(define io.exact-loop
  _ _ N N -> [ok N]
  E V At End -> (io.exact-step E V At End (io.read-raw E (buffer.slice V At (- End At)) [])))

(define io.exact-step
  E V At End [read N] -> (io.exact-loop E V (+ At N) End)
  _ _ At _ [eof] -> [eof At]
  _ _ At _ [error Error] -> [error (io.progress Error At) At])

(define io.write-all
  E V Options ->
    (do (io.transfer-options Options)
        (io.check E write [])
        (io.all-loop E V 0 (buffer.length V))))

(define io.all-loop
  _ _ N N -> [ok N]
  E V At End -> (io.all-step E V At End (io.write-raw E (buffer.slice V At (- End At)) [])))

(define io.all-step
  E V At End [written N] -> (io.all-loop E V (+ At N) End)
  _ _ At _ [error Error] -> [error (io.progress Error At) At])

\\ Reader slots: tag, endpoint, bounded buffer, next/unfilled offsets, terminal result, position.
(define io.reader
  E Options ->
    (let _ (io.check E read [])
         Cap (io.options E Options)
         R (io.record [io.reader E (buffer.new Cap) 0 0 [] 0])
      (do (address-> E 9 R) R)))

(define io.timeout-result?
  [retry-timeout _] -> true
  _ -> false)

(define io.reader-terminal
  R -> (io.terminal-result R (<-address R 5)))

(define io.terminal-result
  R [pending-timeout Error] ->
    (do (address-> R 5 [retry-timeout Error]) [error Error])
  _ Terminal -> Terminal)

(define io.reader-check
  R -> (if (io.tag? R io.reader)
           (do (io.check (<-address R 1) read R)
               (if (io.timeout-result? (<-address R 5)) (address-> R 5 []) true)
               R)
           (error "io: not a reader")))

(define io.available
  R -> (let _ (io.reader-check R) (- (<-address R 4) (<-address R 3))))

(define io.position
  R -> (<-address (io.reader-check R) 6))

(define io.fill-reader
  R Need ->
    (if (or (>= (- (<-address R 4) (<-address R 3)) Need) (not (empty? (<-address R 5))))
        R
        (let B (<-address R 2)
             At (<-address R 3)
             End (<-address R 4)
             _ (if (> At 0)
                   (do (buffer.copy! B 0 B At (- End At))
                       (address-> R 3 0)
                       (address-> R 4 (- End At)))
                   true)
             Tail (buffer.slice B (<-address R 4) (- (buffer.length B) (<-address R 4)))
             Result (io.read-raw (<-address R 1) Tail R)
          (io.fill-step R Need Result))))

(define io.fill-step
  R Need [read N] -> (do (address-> R 4 (+ (<-address R 4) N)) (io.fill-reader R Need))
  R _ [error Error] ->
    (do (address-> R 5 (if (= (io.error-domain Error) timeout)
                           [pending-timeout Error]
                           [error Error]))
        R)
  R _ Terminal -> (do (address-> R 5 Terminal) R))

(define io.peek
  R Count ->
    (let _ (io.reader-check R)
         N (buffer.index Count)
         B (<-address R 2)
         _ (buffer.range (buffer.length B) 0 N)
         _ (io.fill-reader R N)
         Available (- (<-address R 4) (<-address R 3))
      (if (or (> Available 0) (= N 0))
          [ok (buffer.wrap (buffer.bytes (buffer.slice B (<-address R 3) (io.min N Available))))]
          (io.reader-terminal R))))

\\ Unlike peek Count, this waits only for some input, then exposes an owned available span.
(define io.peek-some
  R -> (do (io.reader-check R) (io.peek-up-to R (buffer.length (<-address R 2)))))

\\ Wait for one byte, then copy no more than Count from the available span.
\\ This bounds copying for a short delimiter without waiting to fill Count bytes.
(define io.peek-up-to
  R Count ->
    (let _ (io.reader-check R)
         Maximum (buffer.index Count)
         _ (io.fill-reader R (if (= Maximum 0) 0 1))
         N (- (<-address R 4) (<-address R 3))
      (if (or (> N 0) (= Maximum 0))
          [ok (buffer.wrap (buffer.bytes (buffer.slice (<-address R 2) (<-address R 3)
                                                     (io.min N Maximum))))]
          (io.reader-terminal R))))

\\ For a parser that reads the queue in place: the queue moves to the start of the reader's buffer,
\\ and fills append to it until something is consumed, so positions in the window stay valid.
\\ io.window gives the buffer's storage, io.window-fill fills it towards Need bytes, as far as the
\\ input and the buffer allow, and gives how many it holds, and io.window-size is its capacity.
(define io.window
  R -> (let _ (io.reader-check R)
            B (<-address R 2) At (<-address R 3) End (<-address R 4)
            _ (if (> At 0)
                  (do (buffer.copy! B 0 B At (- End At)) (address-> R 3 0) (address-> R 4 (- End At)))
                  true)
         (buffer.owner B)))

(define io.window-fill
  R Need -> (do (io.fill-reader R (io.min Need (buffer.length (<-address R 2)))) (<-address R 4)))

(define io.window-size
  R -> (buffer.length (<-address R 2)))

(define io.consume
  R Count ->
    (let _ (io.reader-check R)
         N (buffer.index Count)
         _ (buffer.range (- (<-address R 4) (<-address R 3)) 0 N)
      (do (address-> R 3 (+ (<-address R 3) N))
          (address-> R 6 (+ (<-address R 6) N))
          R)))

(define io.read-chunk
  R ->
    (let _ (io.reader-check R)
         _ (io.fill-reader R 1)
         N (- (<-address R 4) (<-address R 3))
      (if (> N 0)
          (let Out (buffer.wrap (buffer.bytes (buffer.slice (<-address R 2) (<-address R 3) N)))
            (do (io.consume R N) [chunk Out]))
          (io.reader-terminal R))))

(define io.read-into
  R V ->
    (let _ (io.reader-check R)
         _ (io.writable V)
         Count (buffer.length V)
      (if (= Count 0)
          [read 0]
          (let _ (io.fill-reader R 1)
               N (io.min Count (- (<-address R 4) (<-address R 3)))
            (if (> N 0)
                (do (buffer.copy! V 0 (<-address R 2) (<-address R 3) N)
                    (io.consume R N)
                    [read N])
                (io.reader-terminal R))))))

(define io.reader-exact
  R V ->
    (do (io.reader-check R)
        (io.writable V)
        (io.reader-exact-loop R V 0 (buffer.length V))))

(define io.reader-exact-loop
  _ _ N N -> [ok N]
  R V At End -> (io.reader-exact-step R V At End (io.read-into R (buffer.slice V At (- End At)))))

(define io.reader-exact-step
  R V At End [read N] -> (io.reader-exact-loop R V (+ At N) End)
  _ _ At _ [eof] -> [eof At]
  _ _ At _ [error Error] -> [error (io.progress Error At) At])

\\ Whole-input aggregation has an explicit limit. A limit failure does not consume the next byte.
(define io.read-all
  R Limit -> (do (io.reader-check R) (buffer.index Limit) (io.collect R Limit 0 [])))

(define io.collect
  R Limit Total Chunks ->
    (if (= Total Limit)
        (io.collect-limit R Total Chunks (io.peek R 1))
        (io.collect-step R Limit Total Chunks
          (io.peek R (io.min (- Limit Total) (buffer.length (<-address R 2)))))))

(define io.collect-step
  R Limit Total Chunks [ok V] ->
    (let N (buffer.length V)
      (do (io.consume R N) (io.collect R Limit (+ Total N) [V | Chunks])))
  _ _ Total Chunks [eof] -> [ok (io.join Total (reverse Chunks))]
  _ _ Total _ [error Error] -> [error (io.progress Error Total)])

(define io.collect-limit
  _ Total Chunks [eof] -> [ok (io.join Total (reverse Chunks))]
  _ Total _ [error Error] -> [error (io.progress Error Total)]
  R Total _ [ok _] ->
    [error (io.progress (io.error read (<-address (<-address R 1) 1) "input exceeds limit") Total)])

(define io.join
  N Chunks -> (io.join-loop (buffer.new N) 0 Chunks))

(define io.join-loop
  Out _ [] -> Out
  Out At [V | Rest] ->
    (do (buffer.copy! Out At V 0 (buffer.length V))
        (io.join-loop Out (+ At (buffer.length V)) Rest)))

\\ Writer slots: tag, endpoint, bounded buffer, sent/unfilled offsets, last flush error.
(define io.writer
  E Options ->
    (let _ (io.check E write [])
         Cap (io.options E Options)
         W (io.record [io.writer E (buffer.new Cap) 0 0 []])
      (do (address-> E 10 W) W)))

(define io.writer-check
  W -> (if (io.tag? W io.writer)
           (do (io.check (<-address W 1) write W) W)
           (error "io: not a writer")))

(define io.pending
  W -> (let _ (io.writer-check W) (- (<-address W 4) (<-address W 3))))

(define io.flush
  W -> (do (io.writer-check W) (io.flush-loop W 0)))

(define io.flush-loop
  W Total ->
    (let At (<-address W 3)
         End (<-address W 4)
      (if (= At End)
          (do (address-> W 3 0)
              (address-> W 4 0)
              (address-> W 5 [])
              [ok Total])
          (io.flush-step W Total
            (io.write-raw (<-address W 1) (buffer.slice (<-address W 2) At (- End At)) W)))))

(define io.flush-step
  W Total [written N] ->
    (do (address-> W 3 (+ (<-address W 3) N)) (io.flush-loop W (+ Total N)))
  W Total [error Error] ->
    (let Saved (io.progress Error Total)
      (do (address-> W 5 Saved) [error Saved Total])))

(define io.write
  W V ->
    (let _ (io.writer-check W)
         N (buffer.length V)
      (cond ((= N 0) [accepted 0])
            ((not (empty? (<-address W 5))) [error (io.progress (<-address W 5) 0) 0])
            (true (io.buffer-write W V 0 N)))))

(define io.buffer-write
  _ _ N N -> [accepted N]
  W V At End ->
    (let B (<-address W 2)
         Sent (<-address W 3)
         Used (<-address W 4)
         _ (if (> Sent 0)
               (do (buffer.copy! B 0 B Sent (- Used Sent))
                   (address-> W 3 0)
                   (address-> W 4 (- Used Sent)))
               true)
         Room (- (buffer.length B) (<-address W 4))
      (if (= Room 0)
          (io.buffer-write-step W V At End (io.flush W))
          (let N (io.min Room (- End At))
            (do (buffer.copy! B (<-address W 4) V At N)
                (address-> W 4 (+ (<-address W 4) N))
                (io.buffer-write W V (+ At N) End))))))

(define io.buffer-write-step
  W V At End [ok _] -> (io.buffer-write W V At End)
  _ _ At _ [error Error _] -> [error (io.progress Error At) At])

\\ Close always attempts cleanup after a flush failure, then remembers the combined result.
(define io.close-result
  _ [ok] -> [ok]
  _ [error Error] ->
    (if (io.error? Error) [error Error] (error "io: malformed close error"))
  E _ -> [error (io.error close (<-address E 1) "invalid backend close result")])

(define io.close
  E ->
    (let _ (io.endpoint-check E)
      (cond ((= (<-address E 7) closed) (<-address E 8))
            ((<-address E 11) (error "io: endpoint operation is already in flight"))
            ((not (io.live? E))
              (let Result [error (io.error close (<-address E 1) "native endpoint is stale")]
                (do (address-> E 7 closed)
                    (address-> E 8 Result)
                    Result)))
            (true
              (let W (<-address E 10)
                   Flush (if (empty? W)
                             [ok 0]
                             (trap-error (io.flush W)
                               (/. X [error (io.error flush (<-address E 1) (error-to-string X)) 0])))
                   _ (address-> E 7 closed)
                   _ (address-> E 8 [error (io.error close (<-address E 1) "close is in progress")])
                   Close (<-address E 6)
                   Result (trap-error (io.close-result E (thaw Close))
                            (/. X [error (io.error close (<-address E 1) (error-to-string X))]))
                   Final (io.close-combine Flush Result)
                (do (address-> E 8 Final) Final))))))

(define io.close-combine
  [ok _] Result -> Result
  [error Error _] [ok] -> [error Error]
  [error Error _] [error Other] -> [error (io.secondary Error Other)])

(define io.finish
  [ok Value] [ok] -> [ok Value]
  [ok _] [error Error] -> [error Error]
  [error Error] [ok] -> [error Error]
  [error Error] [error Other] -> [error (io.secondary Error Other)])

(define io.scope-result
  _ [ok Value] -> [ok Value]
  _ [error Error] ->
    (if (io.error? Error) [error Error] (error "io: malformed scope error"))
  E _ -> [error (io.error callback (<-address E 1) "callback must return [ok Value] or [error Error]")])

(define io.with-endpoint
  E F ->
    (let _ (io.endpoint-check E)
         _ (if (and (= (<-address E 7) open) (io.live? E))
               true
               (error "io: endpoint is closed or stale"))
         _ (if (<-address E 11) (error "io: endpoint operation is already in flight") true)
         Result (trap-error (io.scope-result E (F E))
                  (/. X [error (io.native-error callback shen 0 (<-address E 1) (error-to-string X))]))
      (io.finish Result (io.close E))))

\\ Memory input owns a snapshot; memory output borrows a fixed writable range.
(define io.no-read
  _ -> (error "io: endpoint is not readable"))

(define io.no-write
  _ -> (error "io: endpoint is not writable"))

(define io.input-buffer
  V ->
    (let B (buffer.bytes V)
         State (io.record [0])
      (io.endpoint "memory input" read 65536
        (/. Out (let At (<-address State 0)
                     N (io.min (shen-jit.bytes-length Out) (- (shen-jit.bytes-length B) At))
                  (if (= N 0)
                      [eof]
                      (do (shen-jit.copy-bytes Out 0 B At N)
                          (address-> State 0 (+ At N))
                          [read N]))))
        (function io.no-write)
        (freeze [ok]))))

(define io.output-buffer
  V ->
    (let _ (io.writable V)
         State (io.record [0])
      (io.endpoint "memory output" write 65536
        (function io.no-read)
        (/. In (let At (<-address State 0)
                    N (io.min (shen-jit.bytes-length In) (- (buffer.length V) At))
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
  [read N] : io.read-result;

  _____________________
  [eof] : io.read-result;

  Error : io.error;
  =====================
  [error Error] : io.read-result;

  N : number;
  =====================
  [written N] : io.write-result;

  Error : io.error;
  =====================
  [error Error] : io.write-result;

  N : number;
  =====================
  [ok N] : io.transfer-result;

  N : number;
  =====================
  [eof N] : io.transfer-result;

  Error : io.error; N : number;
  =====================
  [error Error N] : io.transfer-result;

  V : A;
  =====================
  [ok V] : (io.result A);

  Error : io.error;
  =====================
  [error Error] : (io.result A);

  V : buffer.view;
  =====================
  [ok V] : io.peek-result;

  _____________________
  [eof] : io.peek-result;

  Error : io.error;
  =====================
  [error Error] : io.peek-result;

  V : buffer.view;
  =====================
  [chunk V] : io.chunk-result;

  _____________________
  [eof] : io.chunk-result;

  Error : io.error;
  =====================
  [error Error] : io.chunk-result;

  N : number;
  =====================
  [accepted N] : io.accept-result;

  Error : io.error; N : number;
  =====================
  [error Error N] : io.accept-result;

  _____________________
  [ok] : io.close-result;

  Error : io.error;
  =====================
  [error Error] : io.close-result;

  _____________________
  [] : io.transfer-options;

  _____________________
  [] : io.buffer-options;

  N : number;
  =====================
  [[chunk-size N]] : io.buffer-options;)

\\ (io.let-ok X Result ... Body): Body with each X bound to the value of [ok X], in order, or the
\\ first result that is not ok, as it is. _ takes [ok] or [ok X] and binds nothing. The libraries
\\ read after this one use it for their chains of results.
(defmacro io.let-ok-macro
  [io.let-ok Body] -> Body
  [io.let-ok X Result | More] ->
    (let R (gensym (protect R))
      [let R Result
        [if [and [cons? R] [= [hd R] ok]]
            (if (= (str X) "_") [io.let-ok | More] [let X [hd [tl R]] [io.let-ok | More]])
            R]]))

(declare io.error [symbol --> [string --> [string --> io.error]]])
(declare io.native-error [symbol --> [symbol --> [number --> [string --> [string --> io.error]]]]])
(declare io.error? [A --> boolean])
(declare io.error-operation [io.error --> symbol])
(declare io.error-domain [io.error --> symbol])
(declare io.error-code [io.error --> number])
(declare io.error-resource [io.error --> string])
(declare io.error-message [io.error --> string])
(declare io.error-progress [io.error --> number])
(declare io.error-secondary [io.error --> [list io.error]])
(declare io.endpoint
  [string --> [symbol --> [number --> [[buffer.storage --> io.read-result] -->
    [[buffer.storage --> io.write-result] --> [[lazy io.close-result] --> io.endpoint]]]]]])
(declare io.no-read [buffer.storage --> io.read-result])
(declare io.no-write [buffer.storage --> io.write-result])
(declare io.input-buffer [buffer.view --> io.endpoint])
(declare io.output-buffer [buffer.view --> io.endpoint])
(declare io.read-some [io.endpoint --> [buffer.view --> [io.transfer-options --> io.read-result]]])
(declare io.write-some [io.endpoint --> [buffer.view --> [io.transfer-options --> io.write-result]]])
(declare io.read-exact [io.endpoint --> [buffer.view --> [io.transfer-options --> io.transfer-result]]])
(declare io.write-all [io.endpoint --> [buffer.view --> [io.transfer-options --> io.transfer-result]]])
(declare io.reader [io.endpoint --> [io.buffer-options --> io.reader]])
(declare io.available [io.reader --> number])
(declare io.position [io.reader --> number])
(declare io.peek [io.reader --> [number --> io.peek-result]])
(declare io.peek-some [io.reader --> io.peek-result])
(declare io.peek-up-to [io.reader --> [number --> io.peek-result]])
(declare io.consume [io.reader --> [number --> io.reader]])
(declare io.read-chunk [io.reader --> io.chunk-result])
(declare io.window [io.reader --> buffer.storage])
(declare io.window-fill [io.reader --> [number --> number]])
(declare io.window-size [io.reader --> number])
(declare io.read-into [io.reader --> [buffer.view --> io.read-result]])
(declare io.reader-exact [io.reader --> [buffer.view --> io.transfer-result]])
(declare io.read-all [io.reader --> [number --> [io.result buffer.view]]])
(declare io.writer [io.endpoint --> [io.buffer-options --> io.writer]])
(declare io.pending [io.writer --> number])
(declare io.write [io.writer --> [buffer.view --> io.accept-result]])
(declare io.flush [io.writer --> io.transfer-result])
(declare io.close [io.endpoint --> io.close-result])
(declare io.with-endpoint [io.endpoint --> [[io.endpoint --> [io.result A]] --> [io.result A]]])
