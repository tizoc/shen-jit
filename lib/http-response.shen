\\ Bounded HTTP/1.1 final responses. Load http-request.shen after the buffer/I/O libraries first.
\\ Application fields are ordered pairs; framing fields are supplied by this encoder.

(shen.x.namespace http
  (use buffer)
  (use deadline)
  (use io)
  (use shen-jit)
  (externals [active application chunk chunked closed deadline eof http-response
    http-response-framing http-response-options ok response-body-limit response-chunk-count-limit
    response-chunk-size response-head-limit suppressed timeout written])
  (export close-after encode-response request response response-framing response-option
    send-response source source-close stream-response)

(define response
  Status Fields Body ->
    (let Code (buffer.index Status)
         _ (if (and (>= Code 200) (<= Code 599)) true
               (error "http: final response status must be 200..599"))
         _ (buffer.check Body)
      (io.record [response Code Fields Body false])))

(define response-check
  Response ->
    (if (or (io.tag? Response response) (io.tag? Response stream-description))
        Response (error "http: not a response")))

(define response-source
  Response -> (if (io.tag? Response stream-description) (<-address Response 4) []))

(define response-closes?
  Response ->
    (let _ (response-check Response)
      (<-address Response (if (io.tag? Response stream-description) 5 4))))

(define close-after
  Response ->
    (response-copy-fields Response (<-address (response-check Response) 2) true))

(define response-copy-fields
  Response Fields Close ->
    (if (io.tag? Response stream-description)
        (io.record [stream-description (<-address Response 1) Fields
                    (<-address Response 3) (<-address Response 4) Close])
        (io.record [response (<-address Response 1) Fields (<-address Response 3) Close])))

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
         Status (<-address Response 1)
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
         Fields (response-fields (<-address Response 2) 0 (- MaxHead Base) [Start] Base)
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
         _ (if (io.tag? Response response) true (error "http: streaming responses require send-response"))
         Body (<-address Response 3)
         N (buffer.length Body)
         Maximum (buffer.index BodyLimit)
         _ (if (<= N Maximum) true (error "http: response body exceeds limit"))
         Head (encode-head Method Response [length N] Close HeadLimit)
         Send (if (suppressed? Method (<-address Response 1)) 0 N)
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
\\ Slots: tag, next, close, lifecycle, in-flight, cached close result, image guard.
(define source
  Next Close ->
    (let Guard (shen-jit.bytes->pointer (shen-jit.u32! (shen-jit.bytes 8) 0 1) 0 source)
      (io.record [source-state Next Close fresh false [] Guard])))

(define source-check
  S ->
    (let _ (if (io.tag? S source-state) true (error "http: not a response source"))
         _ (if (= (shen-jit.pointer-address (<-address S 6)) 0)
               (error "http: saved response sources must be recreated") true)
         _ (if (<-address S 4) (error "http: response source is in flight") true)
      S))

(define source-claim
  S ->
    (do (source-check S)
        (if (= (<-address S 3) fresh) (address-> S 3 active)
            (error "http: response source has already been used"))))

(define source-close
  S ->
    (let _ (source-check S)
      (if (= (<-address S 3) closed)
          (<-address S 5)
          (let Close (<-address S 2)
               _ (address-> S 3 closed)
               _ (address-> S 1 [])
               _ (address-> S 2 [])
               _ (address-> S 4 true)
               Result (trap-error (source-closed (thaw Close))
                        (/. X [error (output-error (error-to-string X))]))
            (do (address-> S 4 false) (address-> S 5 Result) Result)))))

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
         _ (if (= (<-address S 3) active) true (error "http: response source is not active"))
      (io.let-ok _ (output-budget D)
        (let Next (<-address S 1)
             _ (address-> S 4 true)
             Result (trap-error (source-chunk (Next Maximum D) Maximum)
                      (/. X [error (output-error (error-to-string X))]))
             _ (address-> S 4 false)
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
      (io.record [stream-description Code Fields Framing Source false])))

(define output-options
  Options -> (output-config (io.record [16384 1048576 16384 4096]) Options []))

(define output-index
  response-head-limit -> 0
  response-body-limit -> 1
  response-chunk-size -> 2
  response-chunk-count-limit -> 3
  _ -> (error "http: unknown response option"))

(define output-config
  Config [] _ -> Config
  Config [[Name Value] | Rest] Seen ->
    (let I (output-index Name)
         N (buffer.index Value)
         _ (if (element? Name Seen) (error "http: duplicate response option") true)
         _ (if (or (and (= I 0) (>= N 4) (<= N 1048576))
                   (= I 1)
                   (and (>= I 2) (> N 0) (<= N 1048576)))
               true (error "http: invalid response limit"))
         _ (address-> Config I N)
      (output-config Config Rest [Name | Seen]))
  _ _ _ -> (error "http: response options must be [Name Number] pairs"))

(define finish-source
  Result [] -> Result
  Result S ->
    (finished-source Result (trap-error (source-close S)
                       (/. X [error (output-error (error-to-string X))]))))

(define finished-source
  [ok N] [error Error] -> [error (io.progress Error N)]
  Result Closed -> (io.finish Result Closed))

\\ Preparation validates metadata and primes at most one chunk before committing headers.
\\ Plans are private and single use: header/wire, source, framing, first result, limits, used.
(define prepare-response
  Method Response Limits Close D ->
    (let S (response-source Response)
         Result (trap-error [ok (prepare-output Method Response Limits Close D)]
                  (/. X [error (output-error (error-to-string X))]))
      (prepared-source Result S)))

(define prepared-source
  [ok Plan] S -> (prepared-first Plan S (<-address Plan 3))
  [error Error] S -> (finish-source [error Error] S))

(define prepare-output
  Method Response Limits Close D ->
    (let _ (response-check Response)
         S (response-source Response)
      (if (empty? S)
          (io.record [(encode-mode Method Response (<-address Limits 0) (<-address Limits 1) Close)
                      [] [] [suppressed] Limits false])
          (let _ (source-claim S)
               Framing (<-address Response 3)
               _ (length-limit Framing (<-address Limits 1))
               Head (encode-head Method Response Framing Close (<-address Limits 0))
               First (if (suppressed? Method (<-address Response 1)) [suppressed]
                         (pull S Framing Limits 0 0 D))
            (io.record [Head S Framing First Limits false])))))

(define length-limit
  [length N] Maximum -> (if (<= N Maximum) true (error "http: response body exceeds limit"))
  [chunked] _ -> true)

(define prepared-first
  _ S [error Error] -> (finish-source [error Error] S)
  Plan _ _ -> [ok Plan])

(define body-remaining
  [length N] _ Used -> (- N Used)
  [chunked] Limits Used -> (- (<-address Limits 1) Used))

(define pull
  S Framing Limits Used Count D ->
    (let Left (body-remaining Framing Limits Used)
         Maximum (if (or (= Left 0) (= Count (<-address Limits 3))) 1
                     (io.min Left (<-address Limits 2)))
      (pulled Framing Left Count Limits (source-next S Maximum D))))

(define pulled
  [length _] Left _ _ [eof] ->
    (if (= Left 0) [eof] [error (output-error "response source ended before Content-Length")])
  _ _ _ _ [eof] -> [eof]
  _ _ _ _ [error Error] -> [error Error]
  _ Left Count Limits [chunk V] ->
    (cond ((= Left 0) [error (output-error "response source exceeds body length or limit")])
          ((= Count (<-address Limits 3)) [error (output-error "response source exceeds chunk count limit")])
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
    (let _ (if (<-address Plan 5) (error "http: response plan already sent") true)
         _ (address-> Plan 5 true)
         State (io.record [E D Plan 0 0 0])
         Result (trap-error (output-start State)
                  (/. X [error (io.progress (output-error (error-to-string X)) (<-address State 3))]))
      (finish-source Result (<-address Plan 1))))

\\ Write a complete frame before requesting the next producer chunk.
(define output-write
  State V -> (output-write-loop State V 0 (buffer.length V)))

(define output-write-loop
  _ _ N N -> [ok]
  State V At End ->
    (output-write-ready State V At End (output-budget (<-address State 1))))

(define output-write-ready
  State _ _ _ [error Error] -> [error (io.progress Error (<-address State 3))]
  State V At End [ok] ->
    (output-written State V At End
      (io.write-some (<-address State 0) (buffer.slice V At (- End At)) [])))

(define output-written
  State _ _ _ [error Error] -> [error (io.progress Error (<-address State 3))]
  State V At End [written N] ->
    (do (address-> State 3 (+ (<-address State 3) N))
        (output-write-loop State V (+ At N) End)))

(define output-start
  State ->
    (let Plan (<-address State 2)
      (io.let-ok _ (output-write State (<-address Plan 0))
        (output-step State (<-address Plan 3)))))

(define output-step
  State [error Error] -> [error (io.progress Error (<-address State 3))]
  State [suppressed] -> (output-done State)
  State [eof] ->
    (let Plan (<-address State 2)
      (if (= (<-address Plan 2) [chunked])
          (io.let-ok _ (output-write State (buffer.from-string "0c#13;c#10;c#13;c#10;"))
            (output-done State))
          (output-done State)))
  State [chunk V] ->
    (let Plan (<-address State 2)
         Frame (if (= (<-address Plan 2) [chunked]) (chunk-frame V) V)
      (io.let-ok _ (output-write State Frame)
        (let Used (+ (<-address State 4) (buffer.length V))
             Count (+ (<-address State 5) 1)
             _ (address-> State 4 Used)
             _ (address-> State 5 Count)
          (output-step State (pull (<-address Plan 1) (<-address Plan 2)
                                            (<-address Plan 4) Used Count (<-address State 1)))))))

(define output-done
  State ->
    (output-complete State (output-budget (<-address State 1))))

(define output-complete
  State [ok] -> [ok (<-address State 3)]
  State [error Error] -> [error (io.progress Error (<-address State 3))])

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
