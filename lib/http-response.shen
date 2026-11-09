\\ Bounded HTTP/1.1 final responses. Load http-request.shen after the buffer/I/O libraries first.
\\ Application fields are ordered pairs; framing fields are supplied by this encoder.

(shen.x.namespace http
  (use buffer)
  (use deadline)
  (use io)
  (use shen-jit)
  (import struct defstruct)
  (externals [active application chunk chunked closed deadline eof http-response
    http-response-framing http-response-options ok response-body-limit response-chunk-count-limit
    response-chunk-size response-head-limit suppressed timeout written])
  (export close-after encode-response request response response-framing response-option
    send-response source source-close stream-response)

\\ A response is a status, ordered fields and whether the connection closes after it, with either its
\\ whole body or a stream description: framing and a source.
(define show-buffered
  R -> (make-string "#<response ~A>" (buffered-response.status R)))

(defstruct buffered-response
  (printer show-buffered)
  status
  fields
  body
  close)

(define show-stream
  R -> (make-string "#<response ~A streamed>" (stream-description.status R)))

(defstruct stream-description
  (printer show-stream)
  status
  fields
  framing
  source
  close)

(define response
  Status Fields Body ->
    (let Code (buffer.index Status)
         _ (if (and (>= Code 200) (<= Code 599)) true
               (error "http: final response status must be 200..599"))
         _ (buffer.check Body)
      (buffered-response.make Code Fields Body false)))

(define response-check
  Response ->
    (if (or (buffered-response? Response) (stream-description? Response))
        Response (error "http: not a response")))

(define response-source
  Response -> (if (stream-description? Response) (stream-description.source Response) []))

(define response-status
  Response -> (if (stream-description? Response)
                  (stream-description.status Response)
                  (buffered-response.status Response)))

(define response-field-list
  Response -> (if (stream-description? Response)
                  (stream-description.fields Response)
                  (buffered-response.fields Response)))

(define response-closes?
  Response ->
    (let _ (response-check Response)
      (if (stream-description? Response)
          (stream-description.close Response)
          (buffered-response.close Response))))

(define close-after
  Response ->
    (response-copy-fields Response (response-field-list (response-check Response)) true))

(define response-copy-fields
  Response Fields Close ->
    (if (stream-description? Response)
        (stream-description.make (stream-description.status Response) Fields
          (stream-description.framing Response) (stream-description.source Response) Close)
        (buffered-response.make (buffered-response.status Response) Fields
          (buffered-response.body Response) Close)))

(define reason
  200 -> "OK"
  201 -> "Created"
  202 -> "Accepted"
  204 -> "No Content"
  205 -> "Reset Content"
  206 -> "Partial Content"
  304 -> "Not Modified"
  400 -> "Bad Request"
  403 -> "Forbidden"
  404 -> "Not Found"
  405 -> "Method Not Allowed"
  408 -> "Request Timeout"
  409 -> "Conflict"
  413 -> "Content Too Large"
  414 -> "URI Too Long"
  415 -> "Unsupported Media Type"
  417 -> "Expectation Failed"
  422 -> "Unprocessable Content"
  431 -> "Request Header Fields Too Large"
  500 -> "Internal Server Error"
  501 -> "Not Implemented"
  503 -> "Service Unavailable"
  505 -> "HTTP Version Not Supported"
  _ -> "")

(define response-value?
  _ At At -> true
  B At End ->
    (let Byte (shen-jit.u8 B At)
      (and (not (= Byte 127))
           (or (>= Byte 32) (= Byte 9))
           (response-value? B (+ At 1) End))))

(define response-field
  Name Value Budget ->
    (let _ (if (and (string? Name) (string? Value)) true (error "http: response fields must be strings"))
         B (shen-jit.string->bytes Name)
         V (shen-jit.string->bytes Value)
         N (shen-jit.bytes-length B)
         M (shen-jit.bytes-length V)
         _ (if (and (> N 0) (token-range? B 0 N)) true (error "http: invalid response field name"))
         Lower (lower Name)
         _ (if (element? Lower ["content-length" "transfer-encoding" "connection" "trailer"
                               "upgrade" "keep-alive" "proxy-connection" "te"])
               (error "http: response framing field is managed by the encoder") true)
         _ (if (response-value? V 0 M) true (error "http: invalid response field value"))
         _ (if (and (<= (+ N M 2) 8192) (<= (+ N M 4) Budget)) true
               (error "http: response head exceeds limit"))
      (shen-jit.string->bytes (cn Name (cn ": " (cn Value "c#13;c#10;"))))))

(define response-fields
  [] _ _ Acc Total -> (@p (reverse Acc) Total)
  [[Name Value] | Rest] Count Budget Acc Total ->
    (let _ (if (< Count 100) true (error "http: too many response fields"))
         Line (response-field Name Value Budget)
         N (shen-jit.bytes-length Line)
      (response-fields Rest (+ Count 1) (- Budget N) [Line | Acc] (+ Total N)))
  _ _ _ _ _ -> (error "http: response fields must be [Name Value] pairs"))

(define response-copy
  Out At [] -> At
  Out At [Chunk | Rest] ->
    (let N (shen-jit.bytes-length Chunk)
         _ (shen-jit.copy-bytes (buffer.owner Out) At Chunk 0 N)
      (response-copy Out (+ At N) Rest)))

(define encode-head
  Method Response Framing Close HeadLimit ->
    (let _ (response-check Response)
         MaxHead (buffer.index HeadLimit)
         _ (if (and (>= MaxHead 4) (<= MaxHead 1048576)) true
               (error "http: response head limit must be 4..1048576"))
         Status (response-status Response)
         _ (if (and (element? Status [204 205 304]) (not (= Framing [length 0])))
               (error "http: bodyless status requires zero length") true)
         Connection (if Close "Connection: closec#13;c#10;c#13;c#10;" "c#13;c#10;")
         TailText (if (element? Status [204 304])
                      Connection
                      (cn (framing-field Framing) Connection))
         Tail (shen-jit.string->bytes TailText)
         Start (shen-jit.string->bytes (make-string "HTTP/1.1 ~A ~Ac#13;c#10;" Status (reason Status)))
         Base (+ (shen-jit.bytes-length Start) (shen-jit.bytes-length Tail))
         _ (if (<= Base MaxHead) true (error "http: response head exceeds limit"))
         Fields (response-fields (response-field-list Response) 0 (- MaxHead Base) [Start] Base)
         Out (buffer.new (snd Fields))
         _ (response-copy Out 0 (append (fst Fields) [Tail]))
      Out))

(define framing-field
  [length N] -> (make-string "Content-Length: ~Ac#13;c#10;" N)
  [chunked] -> "Transfer-Encoding: chunkedc#13;c#10;")

(define suppressed?
  Method Status -> (or (= Method "HEAD") (element? Status [204 205 304])))

(define encode-mode
  Method Response HeadLimit BodyLimit Close ->
    (let _ (response-check Response)
         _ (if (buffered-response? Response) true
               (error "http: streaming responses require send-response"))
         Body (buffered-response.body Response)
         N (buffer.length Body)
         Maximum (buffer.index BodyLimit)
         _ (if (<= N Maximum) true (error "http: response body exceeds limit"))
         Head (encode-head Method Response [length N] Close HeadLimit)
         Send (if (suppressed? Method (buffered-response.status Response)) 0 N)
         Out (buffer.new (+ (buffer.length Head) Send))
         _ (buffer.copy! Out 0 Head 0 (buffer.length Head))
      (do (buffer.copy! Out (buffer.length Head) Body 0 Send) Out)))

(define encode-for
  Method Response HeadLimit BodyLimit -> (encode-mode Method Response HeadLimit BodyLimit true))

(define encode-response
  Request Response HeadLimit BodyLimit ->
    (encode-for (method Request) Response HeadLimit BodyLimit))

\\ Sources transfer to the sender, which closes them on every exit. Each callback
\\ receives a byte bound and the one absolute write deadline. No prefetch queue.
\\ A source: next and close callbacks, lifecycle, in-flight flag, cached close result
\\ and a guard that an image reload clears.
(define show-source
  S -> (make-string "#<source ~A>" (source-state.lifecycle S)))

(defstruct source-state
  (printer show-source)
  (mutable next)
  (mutable close)
  (mutable lifecycle)
  (mutable busy)
  (mutable close-result)
  guard)

(define source
  Next Close ->
    (let Guard (shen-jit.bytes->pointer (shen-jit.u32! (shen-jit.bytes 8) 0 1) 0 source)
      (source-state.make Next Close fresh false [] Guard)))

(define source-check
  S ->
    (let _ (if (source-state? S) true (error "http: not a response source"))
         _ (if (= (shen-jit.pointer-address (source-state.guard S)) 0)
               (error "http: saved response sources must be recreated") true)
         _ (if (source-state.busy S) (error "http: response source is in flight") true)
      S))

(define source-claim
  S ->
    (do (source-check S)
        (if (= (source-state.lifecycle S) fresh) (source-state.lifecycle-> S active)
            (error "http: response source has already been used"))))

(define source-close
  S ->
    (let _ (source-check S)
      (if (= (source-state.lifecycle S) closed)
          (source-state.close-result S)
          (let Close (source-state.close S)
               _ (source-state.lifecycle-> S closed)
               _ (source-state.next-> S [])
               _ (source-state.close-> S [])
               _ (source-state.busy-> S true)
               Result (trap-error (source-closed (thaw Close))
                        (/. X [error (output-error (error-to-string X))]))
            (do (source-state.busy-> S false) (source-state.close-result-> S Result) Result)))))

(define source-closed
  [ok] -> [ok]
  [error Error] -> (if (io.error? Error) [error Error] (error "http: invalid source close error"))
  _ -> (error "http: source close must return [ok] or [error Error]"))

(define output-error
  Message -> (io.native-error http-response application 500 "HTTP response" Message))

(define output-budget
  D -> (if (deadline.expired? D)
           [error (io.native-error http-response timeout 0 "HTTP response" "write deadline expired")]
           [ok]))

(define source-next
  S Maximum D ->
    (let _ (source-check S)
         _ (if (= (source-state.lifecycle S) active) true (error "http: response source is not active"))
      (io.let-ok _ (output-budget D)
        (let Next (source-state.next S)
             _ (source-state.busy-> S true)
             Result (trap-error (source-chunk (Next Maximum D) Maximum)
                      (/. X [error (output-error (error-to-string X))]))
             _ (source-state.busy-> S false)
          (io.let-ok _ (output-budget D) Result)))))

(define source-chunk
  [eof] _ -> [eof]
  [chunk V] Maximum ->
    (let N (buffer.length V)
      (if (and (> N 0) (<= N Maximum)) [chunk V]
          (error "http: source chunk must contain 1..Maximum bytes")))
  [error Error] _ ->
    (if (io.error? Error)
        [error (io.secondary (output-error "response producer failed") Error)]
        (error "http: invalid response producer error"))
  _ _ -> (error "http: source must return [chunk View], [eof] or [error Error]"))

(define framing-check
  [length N] -> (do (buffer.index N) [length N])
  [chunked] -> [chunked]
  _ -> (error "http: response framing must be [length N] or [chunked]"))

(define stream-response
  Status Fields Framing Source ->
    (let Code (buffer.index Status)
         _ (if (and (>= Code 200) (<= Code 599)) true
               (error "http: final response status must be 200..599"))
         _ (source-check Source)
         _ (framing-check Framing)
      (stream-description.make Code Fields Framing Source false)))

(defstruct output-limits
  head-limit
  body-limit
  chunk-size
  chunk-count-limit)

(define output-options
  Options ->
    (let Set (output-config Options [])
      (output-limits.make (option-value response-head-limit Set 16384)
                          (option-value response-body-limit Set 1048576)
                          (option-value response-chunk-size Set 16384)
                          (option-value response-chunk-count-limit Set 4096))))

(define output-index
  response-head-limit -> 0
  response-body-limit -> 1
  response-chunk-size -> 2
  response-chunk-count-limit -> 3
  _ -> (error "http: unknown response option"))

(define output-config
  [] Set -> Set
  [[Name Value] | Rest] Set ->
    (let I (output-index Name)
         N (buffer.index Value)
         _ (if (empty? (assoc Name Set)) true (error "http: duplicate response option"))
         _ (if (or (and (= I 0) (>= N 4) (<= N 1048576))
                   (= I 1)
                   (and (>= I 2) (> N 0) (<= N 1048576)))
               true (error "http: invalid response limit"))
      (output-config Rest [[Name N] | Set]))
  _ _ -> (error "http: response options must be [Name Number] pairs"))

(define finish-source
  Result [] -> Result
  Result S ->
    (finished-source Result (trap-error (source-close S)
                       (/. X [error (output-error (error-to-string X))]))))

(define finished-source
  [ok N] [error Error] -> [error (io.progress Error N)]
  Result Closed -> (io.finish Result Closed))

\\ Preparation validates metadata and primes at most one chunk before committing headers.
\\ Plans are private and single use: header/wire, source, framing, first result, limits, sent.
(define show-plan
  Plan -> (if (plan.sent Plan) "#<response plan sent>" "#<response plan>"))

(defstruct plan
  (printer show-plan)
  wire
  source
  framing
  first
  limits
  (mutable sent))

\\ What a send has done: its endpoint, deadline and plan, bytes written, body bytes used and chunks.
(define show-sending
  State -> (make-string "#<response output ~A bytes>" (sending.written State)))

(defstruct sending
  (printer show-sending)
  endpoint
  deadline
  plan
  (mutable written)
  (mutable used)
  (mutable count))

(define prepare-response
  Method Response Limits Close D ->
    (let S (response-source Response)
         Result (trap-error [ok (prepare-output Method Response Limits Close D)]
                  (/. X [error (output-error (error-to-string X))]))
      (prepared-source Result S)))

(define prepared-source
  [ok Plan] S -> (prepared-first Plan S (plan.first Plan))
  [error Error] S -> (finish-source [error Error] S))

(define prepare-output
  Method Response Limits Close D ->
    (let _ (response-check Response)
         S (response-source Response)
      (if (empty? S)
          (plan.make (encode-mode Method Response (output-limits.head-limit Limits)
                                  (output-limits.body-limit Limits) Close)
                     [] [] [suppressed] Limits false)
          (let _ (source-claim S)
               Framing (stream-description.framing Response)
               _ (length-limit Framing (output-limits.body-limit Limits))
               Head (encode-head Method Response Framing Close (output-limits.head-limit Limits))
               First (if (suppressed? Method (stream-description.status Response)) [suppressed]
                         (pull S Framing Limits 0 0 D))
            (plan.make Head S Framing First Limits false)))))

(define length-limit
  [length N] Maximum -> (if (<= N Maximum) true (error "http: response body exceeds limit"))
  [chunked] _ -> true)

(define prepared-first
  _ S [error Error] -> (finish-source [error Error] S)
  Plan _ _ -> [ok Plan])

(define body-remaining
  [length N] _ Used -> (- N Used)
  [chunked] Limits Used -> (- (output-limits.body-limit Limits) Used))

(define pull
  S Framing Limits Used Count D ->
    (let Left (body-remaining Framing Limits Used)
         Maximum (if (or (= Left 0) (= Count (output-limits.chunk-count-limit Limits))) 1
                     (io.min Left (output-limits.chunk-size Limits)))
      (pulled Framing Left Count Limits (source-next S Maximum D))))

(define pulled
  [length _] Left _ _ [eof] ->
    (if (= Left 0) [eof] [error (output-error "response source ended before Content-Length")])
  _ _ _ _ [eof] -> [eof]
  _ _ _ _ [error Error] -> [error Error]
  _ Left Count Limits [chunk V] ->
    (cond ((= Left 0) [error (output-error "response source exceeds body length or limit")])
          ((= Count (output-limits.chunk-count-limit Limits))
            [error (output-error "response source exceeds chunk count limit")])
          (true [chunk V])))

(define send-response
  E Request Response D Options ->
    (let Prepared (trap-error
                     (prepare-response (method Request) Response (output-options Options) true D)
                     (/. X (finish-source [error (output-error (error-to-string X))]
                             (response-source Response))))
      (io.let-ok Plan Prepared (send-plan E D Plan))))

(define send-plan
  E D Plan ->
    (let _ (if (plan.sent Plan) (error "http: response plan already sent") true)
         _ (plan.sent-> Plan true)
         State (sending.make E D Plan 0 0 0)
         Result (trap-error (output-start State)
                  (/. X [error (io.progress (output-error (error-to-string X))
                                            (sending.written State))]))
      (finish-source Result (plan.source Plan))))

\\ Write a complete frame before requesting the next producer chunk.
(define output-write
  State V -> (output-write-loop State V 0 (buffer.length V)))

(define output-write-loop
  _ _ N N -> [ok]
  State V At End ->
    (output-write-ready State V At End (output-budget (sending.deadline State))))

(define output-write-ready
  State _ _ _ [error Error] -> [error (io.progress Error (sending.written State))]
  State V At End [ok] ->
    (output-written State V At End
      (io.write-some (sending.endpoint State) (buffer.slice V At (- End At)) [])))

(define output-written
  State _ _ _ [error Error] -> [error (io.progress Error (sending.written State))]
  State V At End [written N] ->
    (do (sending.written-> State (+ (sending.written State) N))
        (output-write-loop State V (+ At N) End)))

(define output-start
  State ->
    (let Plan (sending.plan State)
      (io.let-ok _ (output-write State (plan.wire Plan))
        (output-step State (plan.first Plan)))))

(define output-step
  State [error Error] -> [error (io.progress Error (sending.written State))]
  State [suppressed] -> (output-done State)
  State [eof] ->
    (let Plan (sending.plan State)
      (if (= (plan.framing Plan) [chunked])
          (io.let-ok _ (output-write State (buffer.from-string "0c#13;c#10;c#13;c#10;"))
            (output-done State))
          (output-done State)))
  State [chunk V] ->
    (let Plan (sending.plan State)
         Frame (if (= (plan.framing Plan) [chunked]) (chunk-frame V) V)
      (io.let-ok _ (output-write State Frame)
        (let Used (+ (sending.used State) (buffer.length V))
             Count (+ (sending.count State) 1)
             _ (sending.used-> State Used)
             _ (sending.count-> State Count)
          (output-step State (pull (plan.source Plan) (plan.framing Plan)
                                            (plan.limits Plan) Used Count (sending.deadline State)))))))

(define output-done
  State ->
    (output-complete State (output-budget (sending.deadline State))))

(define output-complete
  State [ok] -> [ok (sending.written State)]
  State [error Error] -> [error (io.progress Error (sending.written State))])

(define hex
  N -> (if (< N 16) (pos "0123456789abcdef" N)
           (cn (hex (shen-jit.shift-right N 4))
               (pos "0123456789abcdef" (shen-jit.bit-and N 15)))))

(define chunk-frame
  V ->
    (let Prefix (buffer.from-string (cn (hex (buffer.length V)) "c#13;c#10;"))
         N (buffer.length V)
         P (buffer.length Prefix)
         Out (buffer.new (+ P N 2))
         _ (buffer.copy! Out 0 Prefix 0 P)
         _ (buffer.copy! Out P V 0 N)
      (do (buffer.u8! Out (+ P N) 13) (buffer.u8! Out (+ P N 1) 10) Out)))

(datatype http-response-framing
  N : number;
  ==============================
  [length N] : response-framing;

  ______________________________
  [chunked] : response-framing;)

(datatype http-response-options
  N : number;
  ==================================
  [response-head-limit N] : response-option;

  N : number;
  ==================================
  [response-body-limit N] : response-option;

  N : number;
  ==================================
  [response-chunk-size N] : response-option;

  N : number;
  ==================================
  [response-chunk-count-limit N] : response-option;)

(declare response [number --> [[list [list string]] --> [buffer.view --> response]]])
(declare close-after [response --> response])
(declare source
  [[number --> [deadline --> io.chunk-result]] --> [[lazy io.close-result] --> source]])
(declare source-close [source --> io.close-result])
(declare stream-response
  [number --> [[list [list string]] --> [response-framing --> [source --> response]]]])
(declare encode-response [request --> [response --> [number --> [number --> buffer.view]]]])
(declare send-response
  [io.endpoint --> [request --> [response --> [deadline -->
    [[list response-option] --> [io.result number]]]]]])

)
