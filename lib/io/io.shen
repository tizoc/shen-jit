\\ Independent bounded byte I/O. Module io.
\\ Callbacks operate on fresh managed chunks; no kernel stream or I/O helper is used.
\\ One task owns an endpoint and its reader/writer. A lease prevents bypassing read-ahead.

(shen.x.namespace io
  (use buffer)
  (use result)
  (use option)
  (import result ok err)
  (use shen-jit)
  (import struct defstruct)
  (externals [callback chunk-size closed flush library
    read-write shen timeout write])
  (shadow count min)
  (export available buffer-options check io.close => close eof? transfer
    close-result consume endpoint endpoint-check endpoint.busy endpoint.busy-> endpoint.close-result
    endpoint.context endpoint.context-> endpoint.guard endpoint.guard-> endpoint.mode endpoint.name
    endpoint.state reader-status io.error => error error-code error-domain
    error-message error-operation error-progress error-resource error-secondary error? finish scope-error
    io.flush => flush input-buffer join min native-error no-read no-write output-buffer
    peek peek-some peek-up-to pending position progress read-all read-chunk
    read-exact read-into read-some reader reader-check reader-exact reader-terminal
    record result secondary tag? transfer-options window window-fill window-size
    with-endpoint io.write => write write-all write-some writer ok err)

\\ An exact read gives the count even when EOF prevents it from completing.
(defstruct transfer (_ : boolean) (_ : fixnum))

(define eof?
  (:ok []) -> true
  _ -> false)

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

(defstruct io.error
  (operation : symbol) (domain : symbol) (code : number) (resource : string)
  (message : string) (progress : fixnum) (secondary : (list io.error)))

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

\\ A reader: the endpoint, bounded buffer, next and unfilled offsets, and stream position.
\\ Its terminal result is absent until EOF or failure. A reported timeout permits a retry.
(define show-reader
  R -> (make-string "#<reader ~S at ~A>" (endpoint.name (reader.endpoint R)) (reader.position R)))

(defstruct reader
  (printer show-reader)
  (endpoint : endpoint)
  (buffer : buffer.view)
  (mutable start : fixnum)
  (mutable end : fixnum)
  (mutable end-result : (option.t (result.t (io.error * result.empty))))
  (mutable retry-timeout : boolean)
  (mutable position : fixnum))

(preclude [reader.%match])

\\ A writer: its endpoint, bounded buffer, sent/unfilled offsets, last flush error.
(define show-writer
  W -> (make-string "#<writer ~S ~A pending>" (endpoint.name (writer.endpoint W))
                    (- (writer.end W) (writer.start W))))

(defstruct writer
  (printer show-writer)
  (endpoint : endpoint)
  (buffer : buffer.view)
  (mutable start : fixnum)
  (mutable end : fixnum)
  (mutable failure : (option.t io.error)))

(preclude [writer.%match])

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

(define backend-read
  _ _ _ (:ok []) -> (:ok [])
  _ _ _ (:err Error) ->
    (if (error? Error) (:err Error) (error "io: malformed backend error"))
  _ V Chunk (:ok [N]) ->
    (let Count (count N (shen-jit.bytes-length Chunk))
      (do (shen-jit.copy-bytes (buffer.owner V) (buffer.offset V) Chunk 0 Count)
          (:ok [Count])))
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
          (:ok [0])
          (let Chunk (scratch E (min N (endpoint.capacity E)))
               Read (endpoint.read E)
               Result (invoke E (freeze (Read Chunk)))
            (backend-read E V Chunk Result)))))

(define backend-written
  E _ (:ok 0) -> (:err (io.error write (endpoint.name E) "backend made no progress"))
  _ Limit (:ok N) -> (:ok (count N Limit))
  _ _ (:err Error) ->
    (if (error? Error) (:err Error) (error "io: malformed backend error"))
  _ _ _ -> (error "io: invalid backend write result"))

(define write-raw
  E V Lease ->
    (let _ (check E write Lease)
         N (buffer.length V)
      (if (= N 0)
          (:ok 0)
          (let Count (min N (endpoint.capacity E))
               Chunk (shen-jit.bytes Count)
               _ (shen-jit.copy-bytes Chunk 0 (buffer.owner V) (buffer.offset V) Count)
               Write (endpoint.write E)
               Result (invoke E (freeze (Write Chunk)))
            (backend-written E Count Result)))))

\\ Close always attempts cleanup after a flush failure, then remembers the combined result.
(define close-result
  _ (:ok []) -> (:ok [])
  _ (:err Error) ->
    (if (error? Error) (:err Error) (error "io: malformed close error"))
  E _ -> (:err (io.error close (endpoint.name E) "invalid backend close result")))

(define io.close
  E ->
    (let _ (endpoint-check E)
      (cond ((= (endpoint.state E) closed) (endpoint.close-result E))
            ((endpoint.busy E) (error "io: endpoint operation is already in flight"))
            ((not (live? E))
              (let Result (:err (io.error close (endpoint.name E) "native endpoint is stale"))
                (do (endpoint.state-> E closed)
                    (endpoint.close-result-> E Result)
                    Result)))
            (true
              (let W (endpoint.writer E)
                   Flush (if (empty? W)
                             (:ok 0)
                             (trap-error (io.flush W)
                               (/. X (close-flush-error E (error-to-string X) (writer.failure W)))))
                   _ (endpoint.state-> E closed)
                   _ (endpoint.close-result-> E (:err (io.error close (endpoint.name E) "close is in progress")))
                   Close (endpoint.close E)
                   Result (trap-error (close-result E (thaw Close))
                            (/. X (:err (io.error close (endpoint.name E) (error-to-string X)))))
                   Final (close-combine Flush Result)
                (do (endpoint.close-result-> E Final) Final))))))

(define close-flush-error
  E Message [] -> (:err (io.error flush (endpoint.name E) Message))
  _ _ [Failure] -> (:err Failure))

(define close-combine
  (:ok _) Result -> Result
  (:err Error) (:ok []) -> (:err Error)
  (:err Error) (:err Other) -> (:err (secondary Error Other)))

\\ Scopes return one io.error, including the total supplied by a transfer.
(define scope-error
  E _ -> E where (error? E)
  _ Message -> (simple-error Message))

(define scope-result
  _ (:ok Value) -> (:ok Value)
  _ (:err Error) -> (:err (scope-error Error "io: malformed scope error"))
  E _ -> (:err (io.error callback (endpoint.name E) "callback must return (:ok Value) or (:err Error)")))

(define with-endpoint
  E F ->
    (let _ (endpoint-check E)
         _ (if (and (= (endpoint.state E) open) (live? E))
               true
               (error "io: endpoint is closed or stale"))
         _ (if (endpoint.busy E) (error "io: endpoint operation is already in flight") true)
         Result (trap-error (scope-result E (F E))
                  (/. X (:err (native-error callback shen 0 (endpoint.name E) (error-to-string X)))))
      (finish Result (io.close E))))

(synonyms close-result (result.t (io.error * result.empty)))

(datatype t
  _____________________
  [] : (- transfer-options);

  _____________________
  [] : (- buffer-options);

  N : fixnum;
  _____________________
  [[chunk-size N]] : (- buffer-options);)

\\ (io.result A) is (result.t (io.error * A)): an (:ok V) with V of the type A, or an (:err E) with E
\\ an io.error. The library's own declarations name the long form, as declare keeps a type as it
\\ is written, and so would not match a client's (io.result A).
(synonyms (result A) (result.t (io.error * A)))

(declare endpoint
  [string --> [symbol --> [number --> [[buffer.storage --> [result.t [io.error * [option.t fixnum]]]] -->
    [[buffer.storage --> [result.t [io.error * fixnum]]] --> [[lazy [result.t [io.error * result.empty]]] --> endpoint]]]]]])

\\ Buffered I/O crosses the unchecked endpoint boundary through these operations.
(declare check [endpoint --> [symbol --> [(protect A) --> endpoint]]])
(declare options [endpoint --> [buffer-options --> fixnum]])
(declare endpoint.reader-> [endpoint --> [reader --> endpoint]])
(declare endpoint.name [endpoint --> string])
(declare read-raw
  [endpoint --> [buffer.view --> [(protect A) --> [result.t [io.error * [option.t fixnum]]]]]])

(declare endpoint.writer-> [endpoint --> [writer --> endpoint]])
(declare write-raw [endpoint --> [buffer.view --> [(protect A) --> [result.t [io.error * fixnum]]]]])

(declare io.close [endpoint --> [result.t [io.error * result.empty]]])
(declare with-endpoint [endpoint --> [[endpoint --> [result.t [io.error * A]]] --> [result.t [io.error * A]]]])

)
