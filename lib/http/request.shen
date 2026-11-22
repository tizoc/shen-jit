\\ Complete HTTP/1.1 request heads and bounded in-memory bodies over our I/O reader.
\\ Module http/request. No socket or kernel I/O dependency.

(shen.x.namespace http
  (use buffer)
  (use bytes)
  (use deadline)
  (use grammar)
  (use io)
  (use option)
  (use result)
  (import result let-ok ok err)
  (use shen-jit)
  (import struct defstruct)
  (externals [? at bad chunk-count-limit chunk-line-limit chunk-metadata-limit chunked deadline
    defgrammar done fixed http http-body http-request more require text timeout
    too-large trailer-fields-limit trailer-limit unsupported])
  (shadow digit? version)
  (export <token> body body-reader body-reader-with chunk-option chunked? connection-close? content-length
    forbidden-trailer? header-values headers method parse-request read-body read-body-until
    read-request request target trailers version)

(define http.problem
  Status Message -> (:err (io.native-error http-request http Status "HTTP request" Message)))

(define invalid
  Message -> (simple-error (cn "http syntax: " Message)))

(define ascii-letter?
  B -> (or (and (>= B 65) (<= B 90)) (and (>= B 97) (<= B 122))))

(define digit?
  B -> (and (>= B 48) (<= B 57)))

(define hex?
  B -> (or (digit? B) (and (>= B 65) (<= B 70)) (and (>= B 97) (<= B 102))))

(define token-byte?
  B -> (or (ascii-letter? B)
           (digit? B)
           (element? B [33 35 36 37 38 39 42 43 45 46 94 95 96 124 126])))

\\ Classes of bytes for bytes.span, made as the code is read.
(define token-bytes -> (bytes.class [33 35 36 37 38 39 42 43 45 46 94 95 96 124 126 [48 57] [65 90] [97 122]]))
(define ows-bytes -> (bytes.class [9 32]))
(define digit-bytes -> (bytes.class [[48 57]]))
(define line-bytes -> (bytes.class [9 [32 126] [128 255]]))

(define token-range?
  B At End -> (= (bytes.span B At End (token-bytes)) End))

(define ows?
  B -> (or (= B 32) (= B 9)))

(define trim-start
  B At End -> (bytes.span B At End (ows-bytes)))

(define trim-end
  B At End -> (bytes.span-back B At End (ows-bytes)))

(define http.text
  B Start End -> (shen-jit.bytes->string B Start (- End Start)))

\\ Where the line from At ends with CRLF: what a line may hold is tabs and bytes but controls.
(define line-end
  B At End ->
    (let Stop (bytes.span B At End (line-bytes))
      (cond ((>= Stop End) (invalid "unterminated line"))
            ((not (= (shen-jit.u8 B Stop) 13)) (invalid "control byte in head"))
            ((and (< (+ Stop 1) End) (= (shen-jit.u8 B (+ Stop 1)) 10)) Stop)
            (true (invalid "CR without LF")))))

(define uri-byte?
  B -> (or (ascii-letter? B)
           (digit? B)
           (element? B [33 36 38 39 40 41 42 43 44 45 46 47 58 59 61 63 64 95 126])))

(defgrammar <tchar> B where (token-byte? B);)
(defgrammar <token> (+ <tchar>);)
(defgrammar <digit> B where (digit? B);)
(defgrammar <hex> B where (hex? B);)
(defgrammar <pchar> 37 <hex> <hex>; B where (uri-byte? B);)
(defgrammar <origin> 47 (* <pchar>);)
(defgrammar <not-space> B where (or (>= B 128) (and (> B 32) (< B 127)));)
(defgrammar <authority> (+ <not-space>);)
(defgrammar <version> "HTTP/" <digit> "." <digit>;)

\\ The method decides the target: CONNECT names an authority, and OPTIONS may name the server.
(defgrammar <request-line>
  "CONNECT " (text <authority>) " " (text <version>) := ["CONNECT" <authority> <version>];
  "OPTIONS * " (text <version>) := ["OPTIONS" "*" <version>];
  (text <token>) (require " " "invalid request line")
    (require (text <origin>) " " "unsupported or invalid request target")
    (require (text <version>) "invalid HTTP version") := [<token> <origin> <version>];)

(define request-line
  B At End ->
    (do (if (<= (- End At) 8192) true (invalid "request line too long"))
        (grammar.parse-range <request-line> B At End
          (/. Position Message (invalid (if (element? Message ["no match" "trailing input"])
                                          "invalid request line" Message))))))

(define field
  B At End ->
    (let _ (if (<= (- End At) 8192) true (invalid "field line too long"))
         Colon (bytes.find B At End 58)
         _ (if (and (> Colon At) (< Colon End) (token-range? B At Colon))
               true (invalid "invalid field name or whitespace before colon"))
         Start (trim-start B (+ Colon 1) End)
         Finish (trim-end B Start End)
      [(bytes.lower (http.text B At Colon)) (http.text B Start Finish)]))

\\ A whole head read as it arrives, by http.read-request: the request line, the fields and the blank
\\ line, each line within its limit and ended by CRLF.
(defgrammar <ws> B where (ows? B);)
(defgrammar <ows> (* <ws>);)
(defgrammar <vchar> B where (or (>= B 128) (and (> B 32) (< B 127)));)
(defgrammar <word> (+ <vchar>);)
(defgrammar <spaced-word> (+ <ws>) <word>;)
(defgrammar <field-value> <word> (* <spaced-word>); <e>;)
(defgrammar <field-line>
  (text <token>) (require ":" "invalid field name or whitespace before colon")
    <ows> (text <field-value>) <ows> := [(bytes.lower <token>) <field-value>];)
(defgrammar <eol>
  13 (require 10 "CR without LF");
  B (require (where false) (if (or (< B 32) (= B 127)) (if (= B 10) "bare LF" "control byte in head")
                               "invalid line"));)
(defgrammar (<fields> Count)
  13 (require 10 "CR without LF") := [];
  (require (where (< Count 100)) "too many fields")
    (at A) (require <field-line> "invalid field name or whitespace before colon") (at B)
    (require (where (<= (- B A) 8192)) "field line too long") <eol> (<fields> (+ Count 1))
    := [<field-line> | <fields>];)
(defgrammar <head>
  (at A) (require <request-line> "invalid request line") (at B)
    (require (where (<= (- B A) 8192)) "request line too long") <eol>
    (<fields> 0) := [<request-line> <fields>];)

(define fields
  B At End Count Acc ->
    (let Line (line-end B At End)
      (if (= At Line)
          (if (= (+ Line 2) End) (reverse Acc) (invalid "trailing bytes after head"))
          (if (>= Count 100)
              (invalid "too many fields")
              (fields B (+ Line 2) End (+ Count 1) [(field B At Line) | Acc])))))

\\ A conservative authority subset: DNS-style ASCII labels or hex IPv6, with an optional port.
(define host-labels?
  _ At At Count Last -> (and (> Count 0) (not (= Last 45)))
  B At End Count Last ->
    (let Byte (shen-jit.u8 B At)
      (if (= Byte 46)
          (and (> Count 0)
               (not (= Last 45))
               (or (= (+ At 1) End) (host-labels? B (+ At 1) End 0 0)))
          (and (< Count 63)
               (or (ascii-letter? Byte) (digit? Byte) (= Byte 45))
               (or (> Count 0) (not (= Byte 45)))
               (host-labels? B (+ At 1) End (+ Count 1) Byte)))))

(define ipv6?
  B Start End ->
    (and (> (- End Start) 1)
         (if (= (shen-jit.u8 B Start) 58)
             (and (< (+ Start 1) End)
                  (= (shen-jit.u8 B (+ Start 1)) 58)
                  (ipv6-groups? B (+ Start 2) End 0 0 true))
             (ipv6-groups? B Start End 0 0 false))))

(define ipv6-groups?
  _ At At Groups Width Compressed ->
    (let Total (+ Groups (if (> Width 0) 1 0))
      (if Compressed (< Total 8) (and (> Width 0) (= Total 8))))
  B At End Groups Width Compressed ->
    (let Byte (shen-jit.u8 B At)
      (cond ((hex? Byte)
              (and (< Width 4) (ipv6-groups? B (+ At 1) End Groups (+ Width 1) Compressed)))
            ((and (= Byte 58) (> Width 0))
              (if (and (< (+ At 1) End) (= (shen-jit.u8 B (+ At 1)) 58))
                  (and (not Compressed) (ipv6-groups? B (+ At 2) End (+ Groups 1) 0 true))
                  (and (< (+ At 1) End)
                       (ipv6-groups? B (+ At 1) End (+ Groups 1) 0 Compressed))))
            (true false))))

(define digits?
  B At End -> (= (bytes.span B At End (digit-bytes)) End))

\\ Digits that digits? has checked, as a number, or too-large past Limit.
(define decimal
  B Start End Limit -> (let N (bytes.decimal B Start End Limit) (if (= N -2) too-large N)))

(define host-port?
  _ At At -> true
  B At End ->
    (and (= (shen-jit.u8 B At) 58)
         (< (+ At 1) End)
         (digits? B (+ At 1) End)
         (not (= (decimal B (+ At 1) End 65535) too-large))))

(define host?
  Text ->
    (let B (shen-jit.string->bytes Text)
         N (shen-jit.bytes-length B)
      (and (> N 0)
           (if (= (shen-jit.u8 B 0) 91)
               (let Close (bytes.find B 1 N 93)
                 (and (< Close N)
                      (ipv6? B 1 Close)
                      (host-port? B (+ Close 1) N)))
               (let Colon (bytes.find B 0 N 58)
                 (and (<= Colon 253)
                      (host-labels? B 0 Colon 0 0)
                      (host-port? B Colon N)))))))

(define token-list
  Values -> (token-values Values []))

(define token-values
  [] Acc -> (reverse Acc)
  [Value | Rest] Acc ->
    (let B (shen-jit.string->bytes Value)
         Tokens (token-parts B 0 (shen-jit.bytes-length B) Acc)
      (token-values Rest Tokens)))

(define token-parts
  B At End Acc ->
    (let Comma (bytes.find B At End 44)
         Start (trim-start B At Comma)
         Finish (trim-end B Start Comma)
         _ (if (and (< Start Finish) (token-range? B Start Finish))
               true (invalid "invalid token list"))
         Next [(bytes.lower (http.text B Start Finish)) | Acc]
      (if (= Comma End) Next (token-parts B (+ Comma 1) End Next))))

(define connection-framing?
  [] -> false
  [Name | Rest] ->
    (or (element? Name ["host" "content-length" "transfer-encoding" "expect" "trailer"])
        (connection-framing? Rest)))

(define http.length
  [] _ -> 0
  [Value] Limit ->
    (let B (shen-jit.string->bytes Value)
         N (shen-jit.bytes-length B)
         _ (if (and (> N 0) (digits? B 0 N)) true (invalid "invalid Content-Length"))
      (decimal B 0 N Limit))
  _ _ -> (invalid "duplicate Content-Length"))

(define transfer
  [] -> fixed
  [Value] ->
    (let Codings (token-list [Value])
         Last (hd (reverse Codings))
         _ (if (chunked-once? Codings) true (invalid "repeated chunked coding"))
         _ (if (= Last "chunked") true (invalid "final request coding must be chunked"))
      (if (= Codings ["chunked"]) chunked unsupported))
  _ -> (invalid "duplicate Transfer-Encoding"))

(define chunked-once?
  [] -> true
  ["chunked" | Rest] -> (not (element? "chunked" Rest))
  [_ | Rest] -> (chunked-once? Rest))

(define forbidden-trailer?
  Name -> (element? Name ["host" "content-length" "transfer-encoding" "trailer" "connection"
                         "te" "keep-alive" "proxy-connection" "upgrade" "expect"
                         "content-encoding" "content-type" "content-range"
                         "authorization" "proxy-authorization" "cookie" "range" "cache-control"
                         "content-disposition" "set-cookie" "location" "retry-after" "vary"
                         "www-authenticate" "proxy-authenticate" "authentication-info"
                         "max-forwards" "if-match" "if-none-match" "if-modified-since"
                         "if-unmodified-since" "if-range"]))

(define trailer-names
  [] _ -> true
  [Name | Rest] Connection ->
    (if (or (forbidden-trailer? Name) (element? Name Connection))
        (invalid "forbidden trailer field")
        (trailer-names Rest Connection)))

\\ A request: its request line and fields, the body's length (or chunked until read), the body (unread
\\ until read), the body limit, trailers and framing.
(define show-request
  Q -> (make-string "#<request ~A ~A>" (request.method Q) (request.target Q)))

(defstruct request
  (printer show-request)
  (method : string)
  (target : string)
  (version : string)
  (headers : (list (list string)))
  (length : (option.t fixnum))
  (body : (option.t buffer.view))
  (limit : fixnum)
  (trailers : (list (list string)))
  (chunked : boolean))

(preclude [request.%match])

\\ Another version is refused (505) before anything else in its head is checked, and an unsupported
\\ coding (501) before its trailers.
(define validate-request
  [_ _ Version] _ _ -> (http.problem 505 "only HTTP/1.1 is supported") where (not (= Version "HTTP/1.1"))
  [Method Target Version] Fields Limit ->
    (let Hosts (field-values Fields "host")
         _ (if (and (= (length Hosts) 1) (host? (hd Hosts)))
               true (invalid "one valid Host is required"))
         Lengths (field-values Fields "content-length")
         Coding (field-values Fields "transfer-encoding")
         Connection (token-list (field-values Fields "connection"))
         _ (if (connection-framing? Connection)
               (invalid "Connection nominates a framing field") true)
      (cond ((and (not (empty? Coding)) (not (empty? Lengths)))
              (http.problem 400 "Transfer-Encoding with Content-Length"))
            ((not (empty? (field-values Fields "expect")))
              (http.problem 417 "expectations are unsupported"))
            ((or (= Method "CONNECT")
                 (element? "upgrade" Connection)
                 (not (empty? (field-values Fields "upgrade"))))
              (http.problem 501 "tunnels and upgrades are unsupported"))
            (true
              (let Framing (transfer Coding)
                   Trailers (if (= Framing unsupported) [] (field-values Fields "trailer"))
                   _ (if (and (not (empty? Trailers)) (not (= Framing chunked)))
                         (invalid "Trailer requires chunked framing") true)
                   _ (trailer-names (token-list Trailers) Connection)
                   N (if (= Framing chunked) chunked (http.length Lengths Limit))
                (cond ((= Framing unsupported) (http.problem 501 "transfer coding is unsupported"))
                      ((= N too-large) (http.problem 413 "request body exceeds limit"))
                      ((= Framing chunked)
                        (:ok (request-from-head Method Target Version Fields (option.none) Limit true)))
                      ((and (= Method "TRACE") (> N 0)) (http.problem 400 "TRACE cannot have a body"))
                      (true
                        (:ok (request-from-head Method Target Version Fields (option.some N) Limit false)))))))))

(define syntax-error
  X ->
    (let Text (error-to-string X)
         B (shen-jit.string->bytes Text)
         N (shen-jit.bytes-length B)
      (if (and (>= N 13) (= (http.text B 0 13) "http syntax: "))
          (let Message (http.text B 13 N) (http.problem (head-status Message) Message))
          (simple-error Text))))

(define head-status
  "request line too long" -> 414
  "field line too long" -> 431
  "too many fields" -> 431
  "head exceeds byte limit" -> 431
  _ -> 400)

\\ Clean EOF is (:ok []); a complete, validated head gives (:ok [Request]).
(define read-request
  R HeadLimit BodyLimit ->
    (let Limit (buffer.index BodyLimit)
      (let-ok Head (grammar.read-within <head> R HeadLimit (function read-problem))
        (read-head-result Head Limit))))

(define read-problem
  _ "input ended" -> (http.problem 400 "incomplete head")
  _ "input exceeds the limit" -> (http.problem 431 "head exceeds byte limit")
  _ Message -> (http.problem (head-status Message) Message))

(define read-head-result
  [] _ -> (:ok [])
  [[Line Fields]] Limit ->
    (trap-error (let-ok Q (validate-request Line Fields Limit) (:ok [Q]))
                (function syntax-error)))

(define parse-request
  V BodyLimit ->
    (let Limit (buffer.index BodyLimit)
         B (buffer.owner V)
         At (buffer.offset V)
         End (buffer.end V)
      (if (> (- End At) 1048576)
          (http.problem 431 "request head exceeds limit")
          (trap-error
            (let Line (line-end B At End)
                 RequestLine (request-line B At Line)
                 Fields (fields B (+ Line 2) End 0 [])
              (validate-request RequestLine Fields Limit))
            (function syntax-error)))))

(define connection-close?
  Request -> (element? "close" (token-list (header-values Request "connection"))))

(declare connection-close? [request --> boolean])

\\ Requests retain immutable metadata; a body read returns a new request with owned body bytes.
(define complete-request
  Request Body -> (completed-request Request Body []))

\\ A body reader: its borrowed reader, the request, the optional body length, the saved result, the
\\ busy flag, the chunked body's builder, the bytes of data and of chunk metadata read, the chunk count
\\ and the chunked limits.
(define show-body
  B -> (make-string "#<body-reader ~A bytes>" (body-state.total B)))

(defstruct body-state
  (printer show-body)
  reader
  request
  length
  (mutable result)
  (mutable busy)
  (mutable builder)
  (mutable total)
  (mutable metadata)
  (mutable chunks)
  limits)

(define body-reader-with
  R Request Options -> (body-reader-limits R Request (chunk-options Options)))

(define body-reader-limits
  R Request Limits ->
    (let _ (io.reader-check R)
         _ (request-check Request)
         N (request.length Request)
         _ (if (empty? (request.body Request)) true (error "http: request already has a body"))
      (:body-state
        reader <- R
        request <- Request
        length <- N
        result <- []
        busy <- false
        builder <- []
        total <- 0
        metadata <- 0
        chunks <- 0
        limits <- Limits)))

(define body-check
  B ->
    (let _ (if (body-state? B) true (error "http: not a body reader"))
         _ (if (body-state.busy B) (error "http: body read is already in flight") true)
         _ (io.reader-check (body-state.reader B))
      B))

(define body-budget
  _ [] _ -> (:ok [])
  _ D Progress ->
    (if (deadline.expired? D)
        (:err (io.progress (io.native-error read timeout 0 "HTTP body" "deadline expired") Progress))
        (:ok [])))

(define read-body
  B -> (body-run B []))

(define read-body-until
  B D -> (do (deadline.check D) (body-run B D)))

(define body-run
  B D ->
    (let _ (body-check B)
         Saved (body-state.result B)
      (if (not (empty? Saved))
          Saved
          (let Start (io.position (body-state.reader B))
               _ (body-state.busy-> B true)
               Result (trap-error (let-ok _ (body-budget B D 0) (body-ready B D))
                        (/. X (do (body-state.busy-> B false)
                                  (body-state.builder-> B [])
                                  (body-state.result-> B
                                    (aborted (http.problem 400 "body read aborted")
                                             (trap-error (- (io.position (body-state.reader B)) Start) (/. E 0))))
                                  (simple-error (error-to-string X)))))
            (do (body-state.busy-> B false)
                (body-state.builder-> B [])
                (body-state.result-> B Result)
                Result)))))

\\ A read stopped by an exception: what it had read is its progress.
(define aborted
  (:err Error) N -> (:err (io.progress Error N)))

(define body-ready
  B D -> (body-ready-with-length B D (body-state.length B)))

(define body-ready-with-length
  B D [] ->
    (do (body-state.builder-> B (buffer.builder (request.limit (body-state.request B))))
        (chunk-next B D))
  B D [N] ->
    (let V (buffer.new N)
      (body-read B D V (io.reader-exact (body-state.reader B) V))))

(define body-read
  _ _ _ (:ok (:io.transfer false N)) ->
    (:err (io.progress (io.native-error http-body http 400 "HTTP body" "incomplete request body") N))
  _ _ _ (:err Error) -> (:err Error)
  B D V (:ok (:io.transfer true N)) -> (let-ok _ (body-budget B D N) (:ok (complete-request (body-state.request B) V))))

(declare parse-request [buffer.view --> [fixnum --> [result.t [io.error * request]]]])
(declare read-request [io.reader --> [fixnum --> [fixnum --> [result.t [io.error * [option.t request]]]]]])
(declare read-body [body-reader --> [result.t [io.error * request]]])
(declare read-body-until [body-reader --> [deadline --> [result.t [io.error * request]]]])

\\ Chunked decoding shares the fixed body's one-shot result and total deadline.
\\ Separate decoded/metadata bounds prevent tiny chunks or extensions defeating the body limit.
(define chunk-option-index
  chunk-line-limit -> 0
  chunk-metadata-limit -> 1
  trailer-limit -> 2
  trailer-fields-limit -> 3
  chunk-count-limit -> 4
  _ -> (error "http: unknown chunked body option"))

(defstruct chunk-limits
  line-limit
  metadata-limit
  trailer-limit
  trailer-fields-limit
  count-limit)

(define chunk-options
  Options -> (chunk-limits-from (chunk-configure Options [])))

(define chunk-limits-from
  Set ->
    (:chunk-limits
      line-limit <- (option-value chunk-line-limit Set 8192)
      metadata-limit <- (option-value chunk-metadata-limit Set 65536)
      trailer-limit <- (option-value trailer-limit Set 16384)
      trailer-fields-limit <- (option-value trailer-fields-limit Set 100)
      count-limit <- (option-value chunk-count-limit Set 4096)))

\\ Options checked: [[Name N] ...], each name once; the value given for Name, or Default.
(define option-value
  Name Set Default -> (let Entry (assoc Name Set) (if (empty? Entry) Default (hd (tl Entry)))))

(define chunk-configure
  [] Set -> Set
  [[Name Value] | Rest] Set ->
    (let I (chunk-option-index Name)
         _ (if (empty? (assoc Name Set)) true (error "http: duplicate chunked body option"))
         N (buffer.index Value)
         _ (if (and (<= N 1048576) (or (not (element? I [0 4])) (> N 0)))
               true (error "http: invalid chunked body limit"))
      (chunk-configure Rest [[Name N] | Set]))
  _ _ -> (error "http: chunked body options must be [Name Number] pairs"))

(define chunk-error
  B Status Message ->
    (:err (io.progress (io.native-error http-body http Status "HTTP chunked body" Message)
                        (body-state.total B))))

(define chunk-syntax
  B X -> (chunk-syntax-result B (syntax-error X)))

(define chunk-syntax-result
  B (:err Error) -> (chunk-error B (io.error-code Error) (io.error-message Error)))

(define chunk-next
  B D ->
    (let-ok _ (body-budget B D (body-state.total B))
      (if (>= (body-state.chunks B) (chunk-limits.count-limit (body-state.limits B)))
          (chunk-error B 413 "chunk count exceeds limit")
          (do (body-state.chunks-> B (+ 1 (body-state.chunks B)))
              (let-ok V (chunk-line B D)
                N (trap-error (:ok (chunk-size V (- (request.limit (body-state.request B))
                                                   (body-state.total B))))
                    (/. X (chunk-syntax B X)))
                (chunk-sized B D N))))))

(define chunk-sized
  B D too-large -> (chunk-error B 413 "request body exceeds limit")
  B D 0 -> (chunk-trailers B D 0 0 [])
  B D N ->
    (if (= (method (body-state.request B)) "TRACE")
        (chunk-error B 400 "TRACE cannot have a body")
        (let V (buffer.new N)
          (chunk-data B D V (io.reader-exact (body-state.reader B) V)))))

(define chunk-data
  B _ _ (:ok (:io.transfer false N)) ->
    (do (body-state.total-> B (+ (body-state.total B) N)) (chunk-error B 400 "incomplete chunk data"))
  B _ _ (:err Error) -> (:err (io.progress Error (+ (body-state.total B) (io.error-progress Error))))
  B D V (:ok (:io.transfer true N)) ->
    (do (buffer.append! (body-state.builder B) V)
        (body-state.total-> B (+ (body-state.total B) N))
        (let-ok _ (body-budget B D (body-state.total B))
          (if (> 2 (- (chunk-limits.metadata-limit (body-state.limits B)) (body-state.metadata B)))
              (chunk-error B 413 "chunk metadata exceeds limit")
              (let End (buffer.new 2)
                (chunk-end B D End (io.reader-exact (body-state.reader B) End)))))))

(define chunk-end
  B _ _ (:ok (:io.transfer false _)) -> (chunk-error B 400 "incomplete chunk delimiter")
  B _ _ (:err Error) -> (:err (io.progress Error (body-state.total B)))
  B D End (:ok (:io.transfer true _)) ->
    (do (body-state.metadata-> B (+ 2 (body-state.metadata B)))
        (if (and (= (buffer.u8 End 0) 13) (= (buffer.u8 End 1) 10))
            (chunk-next B D)
            (chunk-error B 400 "invalid chunk delimiter"))))

(define chunk-line
  B D ->
    (chunk-line-more B D (buffer.builder (+ 2 (chunk-limits.line-limit (body-state.limits B)))) false))

(define chunk-line-more
  B D Out CR ->
    (let-ok _ (body-budget B D (body-state.total B))
      (let Limits (body-state.limits B)
           Left (io.min (- (+ 2 (chunk-limits.line-limit Limits)) (buffer.builder-length Out))
                        (- (chunk-limits.metadata-limit Limits) (body-state.metadata B)))
        (if (= Left 0)
            (chunk-error B 413 "chunk metadata exceeds limit")
            (chunk-line-input B D Out CR (io.peek-up-to (body-state.reader B) (io.min Left 64)))))))

(define chunk-line-input
  B _ _ _ (:ok []) -> (chunk-error B 400 "incomplete chunked body line")
  B _ _ _ (:err Error) -> (:err (io.progress Error (body-state.total B)))
  B D Out CR (:ok [V]) ->
    (chunk-line-scanned B D Out V
      (chunk-line-scan (buffer.owner V) (buffer.offset V) (buffer.end V) CR)))

(define chunk-line-scan
  _ At At CR -> [more CR]
  Data At End true -> (if (= (shen-jit.u8 Data At) 10) [done (+ At 1)] [bad])
  Data At End false ->
    (let Byte (shen-jit.u8 Data At)
      (cond ((= Byte 13) (chunk-line-scan Data (+ At 1) End true))
            ((or (= Byte 10) (= Byte 127) (and (< Byte 32) (not (= Byte 9)))) [bad])
            (true (chunk-line-scan Data (+ At 1) End false)))))

(define chunk-line-copy
  B Out V N ->
    (do (buffer.append! Out (buffer.slice V 0 N))
        (body-state.metadata-> B (+ (body-state.metadata B) N))
        (io.consume (body-state.reader B) N)))

(define chunk-line-scanned
  B _ _ _ [bad] -> (chunk-error B 400 "invalid chunked body line")
  B D Out V [more CR] ->
    (do (chunk-line-copy B Out V (buffer.length V)) (chunk-line-more B D Out CR))
  B D Out V [done End] ->
    (let _ (chunk-line-copy B Out V (- End (buffer.offset V)))
         Line (buffer.finish Out)
      (let-ok _ (body-budget B D (body-state.total B))
        (:ok (buffer.slice Line 0 (- (buffer.length Line) 2))))))

(define chunk-hex-end
  Data At End ->
    (if (and (< At End) (hex? (shen-jit.u8 Data At)))
        (chunk-hex-end Data (+ At 1) End) At))

(define chunk-hex-value
  B -> (cond ((<= B 57) (- B 48)) ((<= B 70) (- B 55)) (true (- B 87))))

(define chunk-size
  V Limit ->
    (let Data (buffer.owner V)
         Start (buffer.offset V)
         End (buffer.end V)
         Stop (chunk-hex-end Data Start End)
         _ (if (> Stop Start) true (invalid "empty or invalid chunk size"))
         _ (if (= Stop End)
               true
               (grammar.parse-range <chunk-extensions> Data Stop End
                 (/. Position Message
                   (invalid (if (= Message "trailing input") "invalid chunk extension separator" Message)))))
      (chunk-hex Data Start Stop 0 (shen-jit.shift-right Limit 4) (shen-jit.bit-and Limit 15))))

(define chunk-hex
  _ At At N _ _ -> N
  Data At End N Tens Last ->
    (let Digit (chunk-hex-value (shen-jit.u8 Data At))
      (if (or (> N Tens) (and (= N Tens) (> Digit Last)))
          too-large
          (chunk-hex Data (+ At 1) End (+ (* N 16) Digit) Tens Last))))

(define text-byte?
  B -> (or (= B 9) (and (>= B 32) (not (= B 127)))))

\\ Extensions are named and ignored: ; name, or ; name = token or quoted string, with optional whitespace.
(defgrammar <text-byte> B where (text-byte? B);)
(defgrammar <qdtext> B where (and (text-byte? B) (not (= B 34)) (not (= B 92)));)
(defgrammar <quoted> 34 <quoted-rest>;)
(defgrammar <quoted-rest>
  (+ <qdtext>) <quoted-rest>; 92 <text-byte> <quoted-rest>;
  (require 34 "unterminated chunk extension string");)
(defgrammar <chunk-value-text> <token>; <quoted>;)
(defgrammar <chunk-value>
  <ows> "=" <ows> (require <chunk-value-text> "invalid chunk extension value");)
(defgrammar <chunk-extension>
  <ows> ";" <ows> (require <token> "invalid chunk extension name") (? <chunk-value>);)
(defgrammar <chunk-extensions> (* <chunk-extension>);)

(define chunk-trailers
  B D Bytes Count Acc ->
    (let-ok V (chunk-line B D)
     (let Total (+ Bytes (buffer.length V) 2)
          Limits (body-state.limits B)
      (cond ((> Total (chunk-limits.trailer-limit Limits)) (chunk-error B 413 "trailers exceed byte limit"))
            ((= (buffer.length V) 0)
              (:ok (completed-request (body-state.request B) (buffer.finish (body-state.builder B))
                                     (reverse Acc))))
            ((>= Count (chunk-limits.trailer-fields-limit Limits))
              (chunk-error B 413 "trailers exceed field limit"))
            (true
              (let Field (trap-error
                            (let Pair (field (buffer.owner V) (buffer.offset V) (buffer.end V))
                                 _ (trailer-names [(hd Pair)]
                                     (token-list (header-values (body-state.request B) "connection")))
                              (:ok Pair))
                            (/. X (chunk-syntax B X)))
                (let-ok Pair Field (chunk-trailers B D Total (+ Count 1) [Pair | Acc]))))))))

(datatype http.request.t
  N : fixnum;
  ______________________________________
  [chunk-line-limit N] : chunk-option;

  N : fixnum;
  ______________________________________
  [chunk-metadata-limit N] : chunk-option;

  N : fixnum;
  ______________________________________
  [trailer-limit N] : chunk-option;

  N : number;
  ______________________________________
  [trailer-fields-limit N] : chunk-option;

  N : number;
  ______________________________________
  [chunk-count-limit N] : chunk-option;)

(declare body-reader-with
  [io.reader --> [request --> [[list chunk-option] --> body-reader]]])

)
