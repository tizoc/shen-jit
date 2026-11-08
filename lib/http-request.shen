\\ Complete HTTP/1.1 request heads and bounded in-memory bodies over our I/O reader.
\\ Load buffer.shen, io.shen, grammar.shen and http-head.shen first. No socket or kernel I/O dependency.

(define http.problem
  Status Message -> [error (io.native-error http-request http Status "HTTP request" Message)])

(define http.invalid
  Message -> (simple-error (cn "http syntax: " Message)))

(define http.ascii-letter?
  B -> (or (and (>= B 65) (<= B 90)) (and (>= B 97) (<= B 122))))

(define http.digit?
  B -> (and (>= B 48) (<= B 57)))

(define http.hex?
  B -> (or (http.digit? B) (and (>= B 65) (<= B 70)) (and (>= B 97) (<= B 102))))

(define http.token-byte?
  B -> (or (http.ascii-letter? B)
           (http.digit? B)
           (element? B [33 35 36 37 38 39 42 43 45 46 94 95 96 124 126])))

(define http.token-range?
  _ At At -> true
  B At End -> (and (http.token-byte? (shen-jit.u8 B At)) (http.token-range? B (+ At 1) End)))

(define http.ows?
  B -> (or (= B 32) (= B 9)))

(define http.trim-start
  B At End -> (if (and (< At End) (http.ows? (shen-jit.u8 B At)))
                  (http.trim-start B (+ At 1) End)
                  At))

(define http.trim-end
  B At End -> (if (and (< At End) (http.ows? (shen-jit.u8 B (- End 1))))
                  (http.trim-end B At (- End 1))
                  End))

(define http.text
  B Start End -> (shen-jit.bytes->string B Start (- End Start)))

(define http.lower
  Text ->
    (let B (shen-jit.string->bytes Text)
         _ (http.lower-bytes B 0 (shen-jit.bytes-length B))
      (shen-jit.bytes->string B 0 (shen-jit.bytes-length B))))

(define http.lower-bytes
  _ At At -> true
  B At End ->
    (let Byte (shen-jit.u8 B At)
         _ (if (and (>= Byte 65) (<= Byte 90)) (shen-jit.u8! B At (+ Byte 32)) true)
      (http.lower-bytes B (+ At 1) End)))

(define http.line-end
  B At End ->
    (if (>= At End)
        (http.invalid "unterminated line")
        (let Byte (shen-jit.u8 B At)
          (cond ((= Byte 13)
                  (if (and (< (+ At 1) End) (= (shen-jit.u8 B (+ At 1)) 10))
                      At
                      (http.invalid "CR without LF")))
                ((or (= Byte 10) (= Byte 127) (and (< Byte 32) (not (= Byte 9))))
                  (http.invalid "control byte in head"))
                (true (http.line-end B (+ At 1) End))))))

(define http.find-byte
  _ At End _ -> End where (>= At End)
  B At End Byte -> (if (= (shen-jit.u8 B At) Byte) At (http.find-byte B (+ At 1) End Byte)))

(define http.uri-byte?
  B -> (or (http.ascii-letter? B)
           (http.digit? B)
           (element? B [33 36 38 39 40 41 42 43 44 45 46 47 58 59 61 63 64 95 126])))

(defgrammar http.<tchar> B where (http.token-byte? B);)
(defgrammar http.<token> (+ http.<tchar>);)
(defgrammar http.<digit> B where (http.digit? B);)
(defgrammar http.<hex> B where (http.hex? B);)
(defgrammar http.<pchar> 37 http.<hex> http.<hex>; B where (http.uri-byte? B);)
(defgrammar http.<origin> 47 (* http.<pchar>);)
(defgrammar http.<not-space> B where (or (>= B 128) (and (> B 32) (< B 127)));)
(defgrammar http.<authority> (+ http.<not-space>);)
(defgrammar http.<version> "HTTP/" http.<digit> "." http.<digit>;)

\\ The method decides the target: CONNECT names an authority, and OPTIONS may name the server.
(defgrammar http.<request-line>
  "CONNECT " (text http.<authority>) " " (text http.<version>) := ["CONNECT" http.<authority> http.<version>];
  "OPTIONS * " (text http.<version>) := ["OPTIONS" "*" http.<version>];
  (text http.<token>) (require " " "invalid request line")
    (require (text http.<origin>) " " "unsupported or invalid request target")
    (require (text http.<version>) "invalid HTTP version") := [http.<token> http.<origin> http.<version>];)

(define http.request-line
  B At End ->
    (do (if (<= (- End At) 8192) true (http.invalid "request line too long"))
        (grammar.parse-range http.<request-line> B At End
          (/. Position Message (http.invalid (if (element? Message ["no match" "trailing input"])
                                          "invalid request line" Message))))))

(define http.field
  B At End ->
    (let _ (if (<= (- End At) 8192) true (http.invalid "field line too long"))
         Colon (http.find-byte B At End 58)
         _ (if (and (> Colon At) (< Colon End) (http.token-range? B At Colon))
               true (http.invalid "invalid field name or whitespace before colon"))
         Start (http.trim-start B (+ Colon 1) End)
         Finish (http.trim-end B Start End)
      [(http.lower (http.text B At Colon)) (http.text B Start Finish)]))

\\ A whole head read as it arrives, by http.read-request: the request line, the fields and the blank
\\ line, each line within its limit and ended by CRLF.
(defgrammar http.<ws> B where (http.ows? B);)
(defgrammar http.<ows> (* http.<ws>);)
(defgrammar http.<vchar> B where (or (>= B 128) (and (> B 32) (< B 127)));)
(defgrammar http.<word> (+ http.<vchar>);)
(defgrammar http.<spaced-word> (+ http.<ws>) http.<word>;)
(defgrammar http.<field-value> http.<word> (* http.<spaced-word>); <e>;)
(defgrammar http.<field-line>
  (text http.<token>) (require ":" "invalid field name or whitespace before colon")
    http.<ows> (text http.<field-value>) http.<ows> := [(http.lower http.<token>) http.<field-value>];)
(defgrammar http.<eol>
  13 (require 10 "CR without LF");
  B (require (where false) (if (or (< B 32) (= B 127)) (if (= B 10) "bare LF" "control byte in head")
                               "invalid line"));)
(defgrammar (http.<fields> Count)
  13 (require 10 "CR without LF") := [];
  (require (where (< Count 100)) "too many fields")
    (at A) (require http.<field-line> "invalid field name or whitespace before colon") (at B)
    (require (where (<= (- B A) 8192)) "field line too long") http.<eol> (http.<fields> (+ Count 1))
    := [http.<field-line> | http.<fields>];)
(defgrammar http.<head>
  (at A) (require http.<request-line> "invalid request line") (at B)
    (require (where (<= (- B A) 8192)) "request line too long") http.<eol>
    (http.<fields> 0) := [http.<request-line> http.<fields>];)

(define http.fields
  B At End Count Acc ->
    (let Line (http.line-end B At End)
      (if (= At Line)
          (if (= (+ Line 2) End) (reverse Acc) (http.invalid "trailing bytes after head"))
          (if (>= Count 100)
              (http.invalid "too many fields")
              (http.fields B (+ Line 2) End (+ Count 1) [(http.field B At Line) | Acc])))))

(define http.field-values
  [] _ -> []
  [[Name Value] | Rest] Name -> [Value | (http.field-values Rest Name)]
  [_ | Rest] Name -> (http.field-values Rest Name))

\\ A conservative authority subset: DNS-style ASCII labels or hex IPv6, with an optional port.
(define http.host-labels?
  _ At At Count Last -> (and (> Count 0) (not (= Last 45)))
  B At End Count Last ->
    (let Byte (shen-jit.u8 B At)
      (if (= Byte 46)
          (and (> Count 0)
               (not (= Last 45))
               (or (= (+ At 1) End) (http.host-labels? B (+ At 1) End 0 0)))
          (and (< Count 63)
               (or (http.ascii-letter? Byte) (http.digit? Byte) (= Byte 45))
               (or (> Count 0) (not (= Byte 45)))
               (http.host-labels? B (+ At 1) End (+ Count 1) Byte)))))

(define http.ipv6?
  B Start End ->
    (and (> (- End Start) 1)
         (if (= (shen-jit.u8 B Start) 58)
             (and (< (+ Start 1) End)
                  (= (shen-jit.u8 B (+ Start 1)) 58)
                  (http.ipv6-groups? B (+ Start 2) End 0 0 true))
             (http.ipv6-groups? B Start End 0 0 false))))

(define http.ipv6-groups?
  _ At At Groups Width Compressed ->
    (let Total (+ Groups (if (> Width 0) 1 0))
      (if Compressed (< Total 8) (and (> Width 0) (= Total 8))))
  B At End Groups Width Compressed ->
    (let Byte (shen-jit.u8 B At)
      (cond ((http.hex? Byte)
              (and (< Width 4) (http.ipv6-groups? B (+ At 1) End Groups (+ Width 1) Compressed)))
            ((and (= Byte 58) (> Width 0))
              (if (and (< (+ At 1) End) (= (shen-jit.u8 B (+ At 1)) 58))
                  (and (not Compressed) (http.ipv6-groups? B (+ At 2) End (+ Groups 1) 0 true))
                  (and (< (+ At 1) End)
                       (http.ipv6-groups? B (+ At 1) End (+ Groups 1) 0 Compressed))))
            (true false))))

(define http.digits?
  _ At At -> true
  B At End -> (and (http.digit? (shen-jit.u8 B At)) (http.digits? B (+ At 1) End)))

\\ Split at 2^60 on the rare large-limit path: the kernel's mod doubles its divisor,
\\ which would overflow near the largest fixnum. Every intermediate here stays in range.
(define http.decimal-bound
  N ->
    (if (<= N 1152921504606846975)
        (let R (shen.mod N 10) (@p (/ (- N R) 10) R))
        (let Low (- N 1152921504606846976)
             R (shen.mod Low 10)
             Sum (+ R 6)
             Carry (if (>= Sum 10) 1 0)
          (@p (+ 115292150460684697 (/ (- Low R) 10) Carry)
              (if (= Carry 1) (- Sum 10) Sum)))))

(define http.decimal
  B Start End Limit ->
    (let Bound (http.decimal-bound Limit)
      (http.decimal-loop B Start End 0 (fst Bound) (snd Bound))))

(define http.decimal-loop
  _ At At N _ _ -> N
  B At End N Tens Remainder ->
    (let Digit (- (shen-jit.u8 B At) 48)
      (if (or (> N Tens) (and (= N Tens) (> Digit Remainder)))
          too-large
          (http.decimal-loop B (+ At 1) End (+ (* N 10) Digit) Tens Remainder))))

(define http.host-port?
  _ At At -> true
  B At End ->
    (and (= (shen-jit.u8 B At) 58)
         (< (+ At 1) End)
         (http.digits? B (+ At 1) End)
         (not (= (http.decimal B (+ At 1) End 65535) too-large))))

(define http.host?
  Text ->
    (let B (shen-jit.string->bytes Text)
         N (shen-jit.bytes-length B)
      (and (> N 0)
           (if (= (shen-jit.u8 B 0) 91)
               (let Close (http.find-byte B 1 N 93)
                 (and (< Close N)
                      (http.ipv6? B 1 Close)
                      (http.host-port? B (+ Close 1) N)))
               (let Colon (http.find-byte B 0 N 58)
                 (and (<= Colon 253)
                      (http.host-labels? B 0 Colon 0 0)
                      (http.host-port? B Colon N)))))))

(define http.token-list
  Values -> (http.token-values Values []))

(define http.token-values
  [] Acc -> (reverse Acc)
  [Value | Rest] Acc ->
    (let B (shen-jit.string->bytes Value)
         Tokens (http.token-parts B 0 (shen-jit.bytes-length B) Acc)
      (http.token-values Rest Tokens)))

(define http.token-parts
  B At End Acc ->
    (let Comma (http.find-byte B At End 44)
         Start (http.trim-start B At Comma)
         Finish (http.trim-end B Start Comma)
         _ (if (and (< Start Finish) (http.token-range? B Start Finish))
               true (http.invalid "invalid token list"))
         Next [(http.lower (http.text B Start Finish)) | Acc]
      (if (= Comma End) Next (http.token-parts B (+ Comma 1) End Next))))

(define http.connection-framing?
  [] -> false
  [Name | Rest] ->
    (or (element? Name ["host" "content-length" "transfer-encoding" "expect" "trailer"])
        (http.connection-framing? Rest)))

(define http.length
  [] _ -> 0
  [Value] Limit ->
    (let B (shen-jit.string->bytes Value)
         N (shen-jit.bytes-length B)
         _ (if (and (> N 0) (http.digits? B 0 N)) true (http.invalid "invalid Content-Length"))
      (http.decimal B 0 N Limit))
  _ _ -> (http.invalid "duplicate Content-Length"))

(define http.transfer
  [] -> fixed
  [Value] ->
    (let Codings (http.token-list [Value])
         Last (hd (reverse Codings))
         _ (if (http.chunked-once? Codings) true (http.invalid "repeated chunked coding"))
         _ (if (= Last "chunked") true (http.invalid "final request coding must be chunked"))
      (if (= Codings ["chunked"]) chunked unsupported))
  _ -> (http.invalid "duplicate Transfer-Encoding"))

(define http.chunked-once?
  [] -> true
  ["chunked" | Rest] -> (not (element? "chunked" Rest))
  [_ | Rest] -> (http.chunked-once? Rest))

(define http.forbidden-trailer?
  Name -> (element? Name ["host" "content-length" "transfer-encoding" "trailer" "connection"
                         "te" "keep-alive" "proxy-connection" "upgrade" "expect"
                         "content-encoding" "content-type" "content-range"
                         "authorization" "proxy-authorization" "cookie" "range" "cache-control"
                         "content-disposition" "set-cookie" "location" "retry-after" "vary"
                         "www-authenticate" "proxy-authenticate" "authentication-info"
                         "max-forwards" "if-match" "if-none-match" "if-modified-since"
                         "if-unmodified-since" "if-range"]))

(define http.trailer-names
  [] _ -> true
  [Name | Rest] Connection ->
    (if (or (http.forbidden-trailer? Name) (element? Name Connection))
        (http.invalid "forbidden trailer field")
        (http.trailer-names Rest Connection)))

(define http.validate-request
  [Method Target Version] Fields Limit ->
    (let Hosts (http.field-values Fields "host")
         _ (if (and (= (length Hosts) 1) (http.host? (hd Hosts)))
               true (http.invalid "one valid Host is required"))
         Lengths (http.field-values Fields "content-length")
         Coding (http.field-values Fields "transfer-encoding")
         Connection (http.token-list (http.field-values Fields "connection"))
         _ (if (http.connection-framing? Connection)
               (http.invalid "Connection nominates a framing field") true)
      (cond ((not (= Version "HTTP/1.1")) (http.problem 505 "only HTTP/1.1 is supported"))
            ((and (not (empty? Coding)) (not (empty? Lengths)))
              (http.problem 400 "Transfer-Encoding with Content-Length"))
            ((not (empty? (http.field-values Fields "expect")))
              (http.problem 417 "expectations are unsupported"))
            ((or (= Method "CONNECT")
                 (element? "upgrade" Connection)
                 (not (empty? (http.field-values Fields "upgrade"))))
              (http.problem 501 "tunnels and upgrades are unsupported"))
            (true
              (let Framing (http.transfer Coding)
                   Trailers (http.field-values Fields "trailer")
                   _ (if (and (not (empty? Trailers)) (not (= Framing chunked)))
                         (http.invalid "Trailer requires chunked framing") true)
                   _ (http.trailer-names (http.token-list Trailers) Connection)
                   N (if (= Framing chunked) chunked (http.length Lengths Limit))
                (cond ((= Framing unsupported) (http.problem 501 "transfer coding is unsupported"))
                      ((= N too-large) (http.problem 413 "request body exceeds limit"))
                      ((= Framing chunked)
                        [ok (io.record [http.request Method Target Version Fields N unread Limit [] chunked])])
                      ((and (= Method "TRACE") (> N 0)) (http.problem 400 "TRACE cannot have a body"))
                      (true
                        [ok (io.record [http.request Method Target Version Fields N unread Limit [] fixed])])))))))

(define http.syntax-error
  X ->
    (let Text (error-to-string X)
         B (shen-jit.string->bytes Text)
         N (shen-jit.bytes-length B)
      (if (and (>= N 13) (= (http.text B 0 13) "http syntax: "))
          (let Message (http.text B 13 N) (http.problem (http.head-status Message) Message))
          (simple-error Text))))

(define http.head-status
  "request line too long" -> 414
  "field line too long" -> 431
  "too many fields" -> 431
  "head exceeds byte limit" -> 431
  _ -> 400)

\\ A request read from R as its head arrives, in the reader's buffer: [ok Request], [eof] when the
\\ input ended before a head, or [error Error], with the statuses of http.parse-request.
(define http.read-request
  R HeadLimit BodyLimit ->
    (let Limit (buffer.index BodyLimit)
         Head (grammar.read-within http.<head> R HeadLimit (/. At Message [problem Message]))
      (http.read-head-result Head Limit)))

(define http.read-head-result
  [ok [Line Fields]] Limit -> (trap-error (http.validate-request Line Fields Limit) (function http.syntax-error))
  [problem "input ended"] _ -> (http.problem 400 "incomplete head")
  [problem "input exceeds the limit"] _ -> (http.problem 431 "head exceeds byte limit")
  [problem Message] _ -> (http.problem (http.head-status Message) Message)
  Result _ -> Result)

(define http.parse-request
  V BodyLimit ->
    (let Limit (buffer.index BodyLimit)
         B (buffer.owner V)
         At (buffer.offset V)
         End (buffer.end V)
      (if (> (- End At) 1048576)
          (http.problem 431 "request head exceeds limit")
          (trap-error
            (let Line (http.line-end B At End)
                 RequestLine (http.request-line B At Line)
                 Fields (http.fields B (+ Line 2) End 0 [])
              (http.validate-request RequestLine Fields Limit))
            (function http.syntax-error)))))

\\ Requests retain immutable metadata; a body read returns a new request with owned body bytes.
(define http.request-check
  Request -> (if (io.tag? Request http.request) Request (error "http: not a request")))

(define http.method
  Request -> (<-address (http.request-check Request) 1))

(define http.target
  Request -> (<-address (http.request-check Request) 2))

(define http.version
  Request -> (<-address (http.request-check Request) 3))

(define http.headers
  Request -> (<-address (http.request-check Request) 4))

(define http.content-length
  Request ->
    (let N (<-address (http.request-check Request) 5)
      (if (= N chunked) (error "http: chunked body length is not known until read") N)))

(define http.chunked?
  Request -> (= (<-address (http.request-check Request) 9) chunked))

(define http.trailers
  Request -> (do (http.body Request) (<-address Request 8)))

(define http.header-values
  Request Name -> (http.field-values (http.headers Request) (http.lower Name)))

(define http.body
  Request ->
    (let Body (<-address (http.request-check Request) 6)
      (if (= Body unread) (error "http: request body has not been read") (buffer.check Body))))

(define http.complete-request
  Request Body -> (http.completed-request Request Body []))

(define http.completed-request
  Request Body Trailers ->
    (io.record [http.request (http.method Request) (http.target Request) (http.version Request)
                (http.headers Request) (buffer.length Body) Body (<-address Request 7)
                Trailers (<-address Request 9)]))

(define http.body-reader
  R Request -> (http.body-reader-with R Request []))

(define http.body-reader-with
  R Request Options ->
    (let _ (io.reader-check R)
         _ (http.request-check Request)
         N (<-address Request 5)
         _ (if (= (<-address Request 6) unread) true (error "http: request already has a body"))
         Limits (http.chunk-options Options)
      (io.record [http.body-reader R Request N [] false [] 0 0 0 Limits])))

(define http.body-check
  B ->
    (let _ (if (io.tag? B http.body-reader) true (error "http: not a body reader"))
         _ (if (<-address B 5) (error "http: body read is already in flight") true)
         _ (io.reader-check (<-address B 1))
      B))

(define http.body-budget
  _ [] _ -> [ok]
  _ D Progress ->
    (if (deadline.expired? D)
        [error (io.progress (io.native-error read timeout 0 "HTTP body" "deadline expired") Progress)]
        [ok]))

(define http.read-body
  B -> (http.body-run B []))

(define http.read-body-until
  B D -> (do (deadline.check D) (http.body-run B D)))

(define http.body-run
  B D ->
    (let _ (http.body-check B)
         Saved (<-address B 4)
      (if (not (empty? Saved))
          Saved
          (do (address-> B 5 true)
              (let Result (trap-error (io.let-ok _ (http.body-budget B D 0) (http.body-ready B D))
                             (/. X (do (address-> B 5 false)
                                       (address-> B 6 [])
                                       (address-> B 4 (http.problem 400 "body read aborted"))
                                       (simple-error (error-to-string X)))))
                (do (address-> B 5 false) (address-> B 6 []) (address-> B 4 Result) Result))))))

(define http.body-ready
  B D ->
    (if (= (<-address B 3) chunked)
        (do (address-> B 6 (buffer.builder (<-address (<-address B 2) 7))) (http.chunk-next B D))
        (let V (buffer.new (<-address B 3))
          (http.body-read B D V (io.reader-exact (<-address B 1) V)))))

(define http.body-read
  _ _ _ [eof N] ->
    [error (io.progress (io.native-error http-body http 400 "HTTP body" "incomplete request body") N)]
  _ _ _ [error Error N] -> [error (io.progress Error N)]
  B D V [ok N] -> (io.let-ok _ (http.body-budget B D N) [ok (http.complete-request (<-address B 2) V)]))

(declare http.parse-request [buffer.view --> [number --> [io.result http.request]]])
(declare http.method [http.request --> string])
(declare http.target [http.request --> string])
(declare http.version [http.request --> string])
(declare http.headers [http.request --> [list [list string]]])
(declare http.content-length [http.request --> number])
(declare http.chunked? [http.request --> boolean])
(declare http.trailers [http.request --> [list [list string]]])
(declare http.header-values [http.request --> [string --> [list string]]])
(declare http.body [http.request --> buffer.view])
(declare http.body-reader [io.reader --> [http.request --> http.body-reader]])
(declare http.read-body [http.body-reader --> [io.result http.request]])
(declare http.read-body-until [http.body-reader --> [deadline --> [io.result http.request]]])

\\ Chunked decoding shares the fixed body's one-shot result and total deadline.
\\ Separate decoded/metadata bounds prevent tiny chunks or extensions defeating the body limit.
(define http.chunk-option-index
  chunk-line-limit -> 0
  chunk-metadata-limit -> 1
  trailer-limit -> 2
  trailer-fields-limit -> 3
  chunk-count-limit -> 4
  _ -> (error "http: unknown chunked body option"))

(define http.chunk-options
  Options -> (http.chunk-configure (io.record [8192 65536 16384 100 4096]) Options []))

(define http.chunk-configure
  Limits [] _ -> Limits
  Limits [[Name Value] | Rest] Seen ->
    (let I (http.chunk-option-index Name)
         _ (if (element? Name Seen) (error "http: duplicate chunked body option") true)
         N (buffer.index Value)
         _ (if (and (<= N 1048576) (or (not (element? I [0 4])) (> N 0)))
               true (error "http: invalid chunked body limit"))
         _ (address-> Limits I N)
      (http.chunk-configure Limits Rest [Name | Seen]))
  _ _ _ -> (error "http: chunked body options must be [Name Number] pairs"))

(define http.chunk-error
  B Status Message ->
    [error (io.progress (io.native-error http-body http Status "HTTP chunked body" Message) (<-address B 7))])

(define http.chunk-syntax
  B X -> (http.chunk-syntax-result B (http.syntax-error X)))

(define http.chunk-syntax-result
  B [error Error] -> (http.chunk-error B (io.error-code Error) (io.error-message Error)))

(define http.chunk-next
  B D ->
    (io.let-ok _ (http.body-budget B D (<-address B 7))
      (if (>= (<-address B 9) (<-address (<-address B 10) 4))
          (http.chunk-error B 413 "chunk count exceeds limit")
          (do (address-> B 9 (+ 1 (<-address B 9)))
              (io.let-ok V (http.chunk-line B D)
                N (trap-error [ok (http.chunk-size V (- (<-address (<-address B 2) 7) (<-address B 7)))]
                    (/. X (http.chunk-syntax B X)))
                (http.chunk-sized B D N))))))

(define http.chunk-sized
  B D too-large -> (http.chunk-error B 413 "request body exceeds limit")
  B D 0 -> (http.chunk-trailers B D 0 0 [])
  B D N ->
    (if (= (http.method (<-address B 2)) "TRACE")
        (http.chunk-error B 400 "TRACE cannot have a body")
        (let V (buffer.new N)
          (http.chunk-data B D V (io.reader-exact (<-address B 1) V)))))

(define http.chunk-data
  B _ _ [eof N] ->
    (do (address-> B 7 (+ (<-address B 7) N)) (http.chunk-error B 400 "incomplete chunk data"))
  B _ _ [error Error N] -> [error (io.progress Error (+ (<-address B 7) N))]
  B D V [ok N] ->
    (do (buffer.append! (<-address B 6) V)
        (address-> B 7 (+ (<-address B 7) N))
        (io.let-ok _ (http.body-budget B D (<-address B 7))
          (if (> 2 (- (<-address (<-address B 10) 1) (<-address B 8)))
              (http.chunk-error B 413 "chunk metadata exceeds limit")
              (let End (buffer.new 2)
                (http.chunk-end B D End (io.reader-exact (<-address B 1) End)))))))

(define http.chunk-end
  B _ _ [eof _] -> (http.chunk-error B 400 "incomplete chunk delimiter")
  B _ _ [error Error _] -> [error (io.progress Error (<-address B 7))]
  B D End [ok _] ->
    (do (address-> B 8 (+ 2 (<-address B 8)))
        (if (and (= (buffer.u8 End 0) 13) (= (buffer.u8 End 1) 10))
            (http.chunk-next B D)
            (http.chunk-error B 400 "invalid chunk delimiter"))))

(define http.chunk-line
  B D ->
    (http.chunk-line-more B D (buffer.builder (+ 2 (<-address (<-address B 10) 0))) false))

(define http.chunk-line-more
  B D Out CR ->
    (io.let-ok _ (http.body-budget B D (<-address B 7))
      (let Left (io.min (- (+ 2 (<-address (<-address B 10) 0)) (buffer.builder-length Out))
                       (- (<-address (<-address B 10) 1) (<-address B 8)))
        (if (= Left 0)
            (http.chunk-error B 413 "chunk metadata exceeds limit")
            (http.chunk-line-input B D Out CR (io.peek-up-to (<-address B 1) (io.min Left 64)))))))

(define http.chunk-line-input
  B _ _ _ [eof] -> (http.chunk-error B 400 "incomplete chunked body line")
  B _ _ _ [error Error] -> [error (io.progress Error (<-address B 7))]
  B D Out CR [ok V] ->
    (http.chunk-line-scanned B D Out V
      (http.chunk-line-scan (buffer.owner V) (buffer.offset V) (buffer.end V) CR)))

(define http.chunk-line-scan
  _ At At CR -> [more CR]
  Data At End true -> (if (= (shen-jit.u8 Data At) 10) [done (+ At 1)] [bad])
  Data At End false ->
    (let Byte (shen-jit.u8 Data At)
      (cond ((= Byte 13) (http.chunk-line-scan Data (+ At 1) End true))
            ((or (= Byte 10) (= Byte 127) (and (< Byte 32) (not (= Byte 9)))) [bad])
            (true (http.chunk-line-scan Data (+ At 1) End false)))))

(define http.chunk-line-copy
  B Out V N ->
    (do (buffer.append! Out (buffer.slice V 0 N))
        (address-> B 8 (+ (<-address B 8) N))
        (io.consume (<-address B 1) N)))

(define http.chunk-line-scanned
  B _ _ _ [bad] -> (http.chunk-error B 400 "invalid chunked body line")
  B D Out V [more CR] ->
    (do (http.chunk-line-copy B Out V (buffer.length V)) (http.chunk-line-more B D Out CR))
  B D Out V [done End] ->
    (let _ (http.chunk-line-copy B Out V (- End (buffer.offset V)))
         Line (buffer.finish Out)
      (io.let-ok _ (http.body-budget B D (<-address B 7)) [ok (buffer.slice Line 0 (- (buffer.length Line) 2))])))

(define http.chunk-hex-end
  Data At End ->
    (if (and (< At End) (http.hex? (shen-jit.u8 Data At)))
        (http.chunk-hex-end Data (+ At 1) End) At))

(define http.chunk-hex-value
  B -> (cond ((<= B 57) (- B 48)) ((<= B 70) (- B 55)) (true (- B 87))))

(define http.chunk-size
  V Limit ->
    (let Data (buffer.owner V)
         Start (buffer.offset V)
         End (buffer.end V)
         Stop (http.chunk-hex-end Data Start End)
         _ (if (> Stop Start) true (http.invalid "empty or invalid chunk size"))
         _ (if (= Stop End)
               true
               (grammar.parse-range http.<chunk-extensions> Data Stop End
                 (/. Position Message
                   (http.invalid (if (= Message "trailing input") "invalid chunk extension separator" Message)))))
      (http.chunk-hex Data Start Stop 0 (shen-jit.shift-right Limit 4) (shen-jit.bit-and Limit 15))))

(define http.chunk-hex
  _ At At N _ _ -> N
  Data At End N Tens Last ->
    (let Digit (http.chunk-hex-value (shen-jit.u8 Data At))
      (if (or (> N Tens) (and (= N Tens) (> Digit Last)))
          too-large
          (http.chunk-hex Data (+ At 1) End (+ (* N 16) Digit) Tens Last))))

(define http.text-byte?
  B -> (or (= B 9) (and (>= B 32) (not (= B 127)))))

\\ Extensions are named and ignored: ; name, or ; name = token or quoted string, with optional whitespace.
(defgrammar http.<text-byte> B where (http.text-byte? B);)
(defgrammar http.<qdtext> B where (and (http.text-byte? B) (not (= B 34)) (not (= B 92)));)
(defgrammar http.<quoted> 34 http.<quoted-rest>;)
(defgrammar http.<quoted-rest>
  (+ http.<qdtext>) http.<quoted-rest>; 92 http.<text-byte> http.<quoted-rest>;
  (require 34 "unterminated chunk extension string");)
(defgrammar http.<chunk-value-text> http.<token>; http.<quoted>;)
(defgrammar http.<chunk-value>
  http.<ows> "=" http.<ows> (require http.<chunk-value-text> "invalid chunk extension value");)
(defgrammar http.<chunk-extension>
  http.<ows> ";" http.<ows> (require http.<token> "invalid chunk extension name") (? http.<chunk-value>);)
(defgrammar http.<chunk-extensions> (* http.<chunk-extension>);)

(define http.chunk-trailers
  B D Bytes Count Acc ->
    (io.let-ok V (http.chunk-line B D)
     (let Total (+ Bytes (buffer.length V) 2)
      (cond ((> Total (<-address (<-address B 10) 2)) (http.chunk-error B 413 "trailers exceed byte limit"))
            ((= (buffer.length V) 0)
              [ok (http.completed-request (<-address B 2) (buffer.finish (<-address B 6)) (reverse Acc))])
            ((>= Count (<-address (<-address B 10) 3)) (http.chunk-error B 413 "trailers exceed field limit"))
            (true
              (let Field (trap-error
                            (let Pair (http.field (buffer.owner V) (buffer.offset V) (buffer.end V))
                                 _ (http.trailer-names [(hd Pair)]
                                     (http.token-list (http.header-values (<-address B 2) "connection")))
                              [ok Pair])
                            (/. X (http.chunk-syntax B X)))
                (io.let-ok Pair Field (http.chunk-trailers B D Total (+ Count 1) [Pair | Acc]))))))))

(datatype http-chunk-options
  N : number;
  ======================================
  [chunk-line-limit N] : http.chunk-option;

  N : number;
  ======================================
  [chunk-metadata-limit N] : http.chunk-option;

  N : number;
  ======================================
  [trailer-limit N] : http.chunk-option;

  N : number;
  ======================================
  [trailer-fields-limit N] : http.chunk-option;

  N : number;
  ======================================
  [chunk-count-limit N] : http.chunk-option;)

(declare http.body-reader-with
  [io.reader --> [http.request --> [[list http.chunk-option] --> http.body-reader]]])
