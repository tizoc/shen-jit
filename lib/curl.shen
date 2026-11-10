\\ Bounded synchronous HTTP(S) over the optional libcurl adapter. Load ffi, buffer and io first.
\\ A client is single-owner; the adapter rejects concurrent request/close on the same handle.

(shen.x.namespace curl
  (use buffer)
  (use io)
  (use shen-jit)
  (import struct defstruct)
  (externals [body-limit ca-file callback chunk-size connect-timeout curl curl-options
    define-foreign define-foreign-procedure header-limit int32 ok proxy redirect-limit request
    request-limit timeout write written])
  (shadow get input open trim-left trim-right version)
  (export *adapter-files* body body-length client curl.close => close elapsed fetch get get-to
    header-values headers open option raw-headers raw-trailers redirects curl.request => request
    request-to request-with-sink response status streamed? trailers url version with-client)

(shen-jit.library adapter
  (trap-error (value *adapter-files*)
    (/. X ["./build/shen-curl.so" "./lib/shen-curl.so" "./shen-curl.so"
           "./build/shen-curl.dll" "./lib/shen-curl.dll" "./shen-curl.dll"])))
(define-foreign c-abi adapter "shen_curl_abi" () --> int32)
(define-foreign-procedure c-version adapter "shen_curl_version" 0)
(define-foreign-procedure c-open adapter "shen_curl_open" 0)
(define-foreign-procedure c-close adapter "shen_curl_close" 2)
(define-foreign-procedure c-request adapter "shen_curl_request" 6)
(define-foreign-procedure c-stream adapter "shen_curl_stream" 3)

(define abi-check
  -> (if (= (c-abi) 2) true (error "curl: incompatible adapter ABI; rebuild with make curl")))

(define version
  -> (do (abi-check) (c-version)))

\\ A client: its libcurl handle, and the result of closing it once that has run.
(define show-client
  C -> (make-string "#<curl client ~A>"
         (if (= (shen-jit.pointer-address (client.handle C)) 0) "closed" "open")))

(defstruct client
  (printer show-client)
  handle
  (mutable closed))

(define open
  -> (do (abi-check) (client.make (c-open) [])))

(define client-check
  Client -> (if (client? Client) Client (error "curl: not a client")))

(define live
  Client ->
    (let P (client.handle (client-check Client))
      (if (= (shen-jit.pointer-address P) 0)
          (error "curl: client is closed or stale") P)))

(define invalidate
  P -> (shen-jit.pointer-kill P))

(define curl.close
  Client ->
    (let _ (client-check Client)
         P (client.handle Client)
         Saved (client.closed Client)
      (if (not (empty? Saved))
          Saved
          (let Result (trap-error (do (c-close P (function invalidate)) [ok])
                         (/. X [error (io.error close "curl client" (error-to-string X))]))
            (do (if (= (shen-jit.pointer-address P) 0) (client.closed-> Client Result) true)
                Result)))))

(define scope-result
  [ok Value] -> [ok Value]
  [error Error] -> (if (io.error? Error) [error Error] (error "curl: invalid callback error"))
  _ -> (error "curl: callback must return [ok Value] or [error Error]"))

(define with-client
  F ->
    (let Client (open)
         Result (trap-error (scope-result (F Client))
                  (/. X [error (io.error callback "curl client" (error-to-string X))]))
      (io.finish Result (curl.close Client))))

(define option-index
  request-limit -> 0
  body-limit -> 1
  header-limit -> 2
  timeout -> 3
  connect-timeout -> 4
  redirect-limit -> 5
  ca-file -> 6
  proxy -> 7
  chunk-size -> 8
  _ -> (error "curl: unknown option"))

\\ The adapter reads a configuration, and a request's input below, by position: they stay vectors.
(define options
  Options -> (configure (io.record [1048576 1048576 65536 30000 5000 0 [] []]) Options [] false))

(define stream-options
  Options -> (configure (io.record [1048576 1048576 65536 30000 5000 0 [] [] 16384]) Options [] true))

(define configure
  Config [] _ _ -> Config
  Config [[Name Value] | Rest] Seen Stream ->
    (let I (option-index Name)
         _ (if (and (= I 8) (not Stream)) (error "curl: chunk-size requires a streaming request") true)
         _ (if (element? Name Seen) (error "curl: duplicate option") true)
         V (if (element? I [6 7])
               (text Value (if (= I 6) 4096 8192))
               (numeric-option I Value Stream))
         _ (if (and (= I 6) (= V "")) (error "curl: empty CA file") true)
         _ (address-> Config I V)
      (configure Config Rest [Name | Seen] Stream))
  _ _ _ _ -> (error "curl: options must be [Name Value] pairs"))

(define numeric-option
  I Value Stream ->
    (let N (buffer.index Value)
         Maximum (cond ((and (= I 1) Stream) 2305843009213693951)
                       ((< I 2) 268435456) ((= I 2) 1048576) ((< I 5) 2147483647)
                       ((= I 8) 65536) (true 20))
      (if (and (<= N Maximum) (or (not (element? I [3 4 8])) (> N 0)))
          N (error "curl: invalid numeric option"))))

(define no-nul
  _ At At -> true
  B At End -> (if (= (shen-jit.u8 B At) 0) (error "curl: text contains NUL")
                 (no-nul B (+ At 1) End)))

(define text
  Text Maximum ->
    (let _ (if (string? Text) true (error "curl: expected a string"))
         B (shen-jit.string->bytes Text)
         N (shen-jit.bytes-length B)
         _ (if (<= N Maximum) true (error "curl: text exceeds limit"))
      (do (no-nul B 0 N) Text)))

(define lower-byte
  B -> (if (and (>= B 65) (<= B 90)) (+ B 32) B))

(define lower
  Text ->
    (let B (shen-jit.string->bytes Text)
         _ (lower-bytes B 0 (shen-jit.bytes-length B))
      (shen-jit.bytes->string B 0 (shen-jit.bytes-length B))))

(define lower-bytes
  _ At At -> true
  B At End -> (do (shen-jit.u8! B At (lower-byte (shen-jit.u8 B At)))
                  (lower-bytes B (+ At 1) End)))

(define url-check
  URL ->
    (let Text (text URL 8192)
         B (shen-jit.string->bytes Text)
         N (shen-jit.bytes-length B)
      (cond ((and (>= N 7) (= (lower (shen-jit.bytes->string B 0 7)) "http://"))
              (cn "http://" (shen-jit.bytes->string B 7 (- N 7))))
            ((and (>= N 8) (= (lower (shen-jit.bytes->string B 0 8)) "https://"))
              (cn "https://" (shen-jit.bytes->string B 8 (- N 8))))
            (true (error "curl: URL must use http:// or https://")))))

(define token-byte?
  B -> (or (and (>= B 48) (<= B 57)) (and (>= B 65) (<= B 90))
           (and (>= B 97) (<= B 122)) (element? B [33 35 36 37 38 39 42 43 45 46 94 95 96 124 126])))

(define token-range?
  _ At At -> true
  B At End -> (and (token-byte? (shen-jit.u8 B At)) (token-range? B (+ At 1) End)))

(define token
  Text Maximum ->
    (let _ (text Text Maximum)
         B (shen-jit.string->bytes Text)
         N (shen-jit.bytes-length B)
      (if (and (> N 0) (token-range? B 0 N)) Text (error "curl: invalid HTTP token"))))

(define field-value?
  _ At At -> true
  B At End ->
    (let C (shen-jit.u8 B At)
      (and (or (= C 9) (>= C 32)) (not (= C 127)) (field-value? B (+ At 1) End))))

(define has-content-type?
  [] -> false
  [[Name _] | Rest] -> (or (= (lower Name) "content-type") (has-content-type? Rest))
  _ -> (error "curl: headers must be [Name Value] pairs"))

(define request-fields
  [] _ _ Acc -> (reverse Acc)
  [[Name Value] | Rest] Count Total Acc ->
    (let _ (token Name 8192)
         _ (text Value 8192)
         _ (if (element? (lower Name) ["content-length" "transfer-encoding"])
               (error "curl: request framing headers are managed by libcurl") true)
         V (shen-jit.string->bytes Value)
         _ (if (field-value? V 0 (shen-jit.bytes-length V)) true (error "curl: invalid header value"))
         Line (cn Name (if (= Value "") ";" (cn ": " Value)))
         N (shen-jit.bytes-length (shen-jit.string->bytes Line))
         _ (if (and (< Count 100) (<= N 8192) (<= (+ Total N) 65536)) true
               (error "curl: request headers exceed limit"))
      (request-fields Rest (+ Count 1) (+ Total N) [Line | Acc]))
  _ _ _ _ -> (error "curl: headers must be [Name Value] pairs"))

(define request-input
  Method URL Fields Body Options ->
    (input Method URL Fields Body (options Options)))

(define input
  Method URL Fields Body Config ->
    (let _ (token Method 32)
         Target (url-check URL)
         N (buffer.length Body)
         _ (if (<= N (<-address Config 0)) true (error "curl: request body exceeds limit"))
         _ (if (and (element? Method ["GET" "HEAD"]) (> N 0)) (error "curl: GET/HEAD require an empty body") true)
         _ (if (and (> (<-address Config 5) 0) (not (element? Method ["GET" "HEAD"])))
               (error "curl: automatic redirects are limited to GET/HEAD") true)
         Headers (if (or (element? Method ["GET" "HEAD"]) (has-content-type? Fields)) Fields
                     (append Fields [["Content-Type" "application/octet-stream"]]))
         Lines (request-fields Headers 0 0 [])
         Bytes (buffer.bytes Body)
      (io.record [Method Target Lines Bytes Config])))

(define perform
  Client Input ->
    (let P (live Client)
         URL (<-address Input 1)
      (trap-error (result URL (c-request P (<-address Input 0) URL
                                    (<-address Input 2) (<-address Input 3) (<-address Input 4)))
        (/. X [error (io.error request URL (error-to-string X))]))))

(define curl.request
  Client Method URL Fields Body Options ->
    (do (live Client)
        (perform Client (request-input Method URL Fields Body Options))))

\\ A response. A streamed one has no body, only the count of bytes its sink accepted.
(define show-response
  R -> (make-string "#<curl response ~A ~S>" (response.status R) (response.url R)))

(defstruct response
  (printer show-response)
  status
  url
  (mutable body)
  headers
  trailers
  raw-headers
  raw-trailers
  elapsed
  redirects
  (mutable body-length))

(define result
  URL Native ->
    (if (= (<-address Native 0) 0)
        (let Head (buffer.wrap (<-address Native 7))
             Trailers (buffer.wrap (<-address Native 8))
          [ok (:response
                status <- (<-address Native 4)
                url <- (<-address Native 5)
                body <- (buffer.wrap (<-address Native 6))
                headers <- (parse-fields Head true)
                trailers <- (parse-fields Trailers false)
                raw-headers <- Head
                raw-trailers <- Trailers
                elapsed <- (<-address Native 9)
                redirects <- (<-address Native 10)
                body-length <- (shen-jit.bytes-length (<-address Native 6)))])
        [error (io.progress (io.native-error request
                             (cond ((element? (<-address Native 1) [2 3]) limit)
                                   ((= (<-address Native 0) 28) timeout)
                                   (true curl))
                             (<-address Native 0) URL (<-address Native 2)) (<-address Native 3))]))

(define fetch
  Method URL Fields Body Options ->
    (let Input (request-input Method URL Fields Body Options)
      (with-client (/. Client (perform Client Input)))))

(define get
  URL Options -> (fetch "GET" URL [] (buffer.new 0) Options))

\\ Streaming state: current sink, bytes accepted by it, first error. Only one chunk is live here.
(define show-sink-state
  S -> (make-string "#<curl stream ~A bytes>" (sink-state.written S)))

(defstruct sink-state
  (printer show-sink-state)
  (mutable sink)
  (mutable written)
  (mutable failure))

(define stream-mark
  R Count -> (do (response.body-> R []) (response.body-length-> R Count) R))

(define sink-result
  [ok Sink] -> [ok (io.endpoint-check Sink)]
  [error Error] -> (if (io.error? Error) [error Error] (error "curl: invalid sink error"))
  _ -> (error "curl: sink opener must return [ok Endpoint] or [error Error]"))

(define stream-opened
  State [ok Sink] ->
    (do (sink-state.sink-> State Sink) (io.check Sink write []) true)
  State [error Error] -> (do (sink-state.failure-> State Error) false))

(define stream-write
  State Bytes ->
    (stream-write-loop State (buffer.wrap Bytes) 0 (shen-jit.bytes-length Bytes)))

(define stream-write-loop
  _ _ End End -> true
  State View At End ->
    (let Sink (sink-state.sink State)
         Result (trap-error (io.write-some Sink (buffer.slice View At (- End At)) [])
                  (/. X [error (io.error write (io.endpoint.name Sink) (error-to-string X))]))
      (stream-written State View At End Result)))

(define stream-written
  State View At End [written N] ->
    (do (sink-state.written-> State (+ (sink-state.written State) N))
        (stream-write-loop State View (+ At N) End))
  State _ _ _ [error Error] -> (do (sink-state.failure-> State Error) false))

(define stream-event
  State _ _ [] Bytes -> (stream-write State Bytes)
  State Open URL Native _ ->
    (stream-opened State
      (sink-result (Open (stream-mark (stream-head (result URL Native)) 0)))))

(define stream-head
  [ok R] -> R)

(define stream-deliver
  State Open URL Native Bytes ->
    (trap-error (stream-event State Open URL Native Bytes)
      (/. X (do (sink-state.failure-> State (io.error callback URL (error-to-string X))) false))))

(define stream-completed
  State [ok R] -> [ok (stream-mark R (sink-state.written State))]
  State [error Error] -> [error (io.progress Error (sink-state.written State))])

(define stream-perform
  Client Input Open State ->
    (let P (live Client)
         URL (<-address Input 1)
         Native (trap-error
                  (result URL (c-stream P Input (/. Head Bytes (stream-deliver State Open URL Head Bytes))))
                  (/. X [error (io.error request URL (error-to-string X))]))
         Error (sink-state.failure State)
      (stream-completed State (if (empty? Error) Native [error Error]))))

(define request-to
  Client Method URL Fields Body Sink Options ->
    (do (live Client) (io.check Sink write [])
        (stream-perform Client (input Method URL Fields Body (stream-options Options))
          (/. Head [ok Sink]) (sink-state.make [] 0 []))))

(define stream-close
  [] -> [ok]
  Sink -> (trap-error (io.close Sink)
            (/. X [error (io.error close "curl sink" (error-to-string X))])))

(define request-with-sink
  Client Method URL Fields Body Open Options ->
    (let _ (live Client)
         Input (input Method URL Fields Body (stream-options Options))
         State (sink-state.make [] 0 [])
         Result (stream-perform Client Input Open State)
      (stream-completed State (io.finish Result (stream-close (sink-state.sink State))))))

(define get-to
  URL Sink Options ->
    (let _ (io.check Sink write [])
         Input (input "GET" URL [] (buffer.new 0) (stream-options Options))
      (with-client
        (/. Client (stream-perform Client Input (/. Head [ok Sink]) (sink-state.make [] 0 []))))))

\\ Parse only the final status block; native callbacks retain trailers separately.
(define find-byte
  _ At At _ -> At
  B At End Byte -> (if (= (shen-jit.u8 B At) Byte) At (find-byte B (+ At 1) End Byte)))

(define trim-left
  B At End -> (if (and (< At End) (element? (shen-jit.u8 B At) [9 32]))
                 (trim-left B (+ At 1) End) At))

(define trim-right
  B At End -> (if (and (> End At) (element? (shen-jit.u8 B (- End 1)) [9 32]))
                 (trim-right B At (- End 1)) End))

(define header-text
  B At End ->
    (let Start (trim-left B At End)
         Stop (trim-right B Start End)
      (shen-jit.bytes->string B Start (- Stop Start))))

(define parse-fields
  View SkipStatus ->
    (let B (buffer.owner View)
         N (buffer.length View)
         At (if SkipStatus (io.min N (+ (find-byte B 0 N 10) 1)) 0)
      (parse-lines B At N [])))

(define parse-lines
  _ At At Acc -> (reverse Acc)
  B At End Acc ->
    (let LF (find-byte B At End 10)
         Stop (if (and (> LF At) (= (shen-jit.u8 B (- LF 1)) 13)) (- LF 1) LF)
         Next (io.min End (+ LF 1))
         _ (if (field-value? B At Stop) true (error "curl: invalid response field value"))
         Fields (if (= Stop At) Acc (parse-line B At Stop Acc))
      (parse-lines B Next End Fields)))

(define parse-line
  B At End Acc ->
    (if (element? (shen-jit.u8 B At) [9 32])
        (continuation Acc (header-text B At End))
        (let Colon (find-byte B At End 58)
             _ (if (and (> Colon At) (< Colon End) (token-range? B At Colon))
                   true (error "curl: malformed response field"))
             _ (if (field-value? B (+ Colon 1) End) true (error "curl: invalid response field value"))
             Name (lower (shen-jit.bytes->string B At (- Colon At)))
          [[Name (header-text B (+ Colon 1) End)] | Acc])))

(define continuation
  [[Name Value] | Rest] Text -> [[Name (cn Value (cn " " Text))] | Rest]
  _ _ -> (error "curl: response continuation without a field"))

(define response-check
  R -> (if (response? R) R (error "curl: not a response")))

(define status
  R -> (response.status (response-check R)))
(define url
  R -> (response.url (response-check R)))
(define body
  R -> (let Body (response.body (response-check R))
         (if (empty? Body) (error "curl: response body was streamed") Body)))
(define streamed?
  R -> (empty? (response.body (response-check R))))
(define body-length
  R -> (response.body-length (response-check R)))
(define headers
  R -> (response.headers (response-check R)))
(define trailers
  R -> (response.trailers (response-check R)))
(define raw-headers
  R -> (response.raw-headers (response-check R)))
(define raw-trailers
  R -> (response.raw-trailers (response-check R)))
(define elapsed
  R -> (response.elapsed (response-check R)))
(define redirects
  R -> (response.redirects (response-check R)))

(define field-values
  [] _ -> []
  [[Name Value] | Rest] Name -> [Value | (field-values Rest Name)]
  [_ | Rest] Name -> (field-values Rest Name))

(define header-values
  R Name -> (field-values (headers R) (lower Name)))

(datatype curl-options
  N : number;
  =============================
  [request-limit N] : option;
  N : number;
  =============================
  [body-limit N] : option;
  N : number;
  =============================
  [header-limit N] : option;
  N : number;
  =============================
  [timeout N] : option;
  N : number;
  =============================
  [connect-timeout N] : option;
  N : number;
  =============================
  [redirect-limit N] : option;
  S : string;
  =============================
  [ca-file S] : option;
  S : string;
  =============================
  [proxy S] : option;
  N : number;
  =============================
  [chunk-size N] : option;)

(declare version [--> string])
(declare open [--> client])
(declare curl.close [client --> io.close-result])
(declare with-client [[client --> [io.result A]] --> [io.result A]])
(declare curl.request
  [client --> [string --> [string --> [[list [list string]] -->
    [buffer.view --> [[list option] --> [io.result response]]]]]]])
(declare fetch
  [string --> [string --> [[list [list string]] --> [buffer.view --> [[list option] --> [io.result response]]]]]])
(declare get [string --> [[list option] --> [io.result response]]])
(declare request-to
  [client --> [string --> [string --> [[list [list string]] --> [buffer.view -->
    [io.endpoint --> [[list option] --> [io.result response]]]]]]]])
(declare request-with-sink
  [client --> [string --> [string --> [[list [list string]] --> [buffer.view -->
    [[response --> [io.result io.endpoint]] --> [[list option] --> [io.result response]]]]]]]])
(declare get-to [string --> [io.endpoint --> [[list option] --> [io.result response]]]])
(declare status [response --> number])
(declare url [response --> string])
(declare body [response --> buffer.view])
(declare streamed? [response --> boolean])
(declare body-length [response --> number])
(declare headers [response --> [list [list string]]])
(declare trailers [response --> [list [list string]]])
(declare raw-headers [response --> buffer.view])
(declare raw-trailers [response --> buffer.view])
(declare elapsed [response --> number])
(declare redirects [response --> number])
(declare header-values [response --> [string --> [list string]]])

)
