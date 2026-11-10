\\ Sequential HTTP/1.1 requests per owned socket. Load clock/deadline/socket I/O and HTTP modules first.
\\ The application receives a complete request and returns a response value, without writing bytes.

(shen.x.namespace http
  (use buffer)
  (use clock)
  (use deadline)
  (use grammar)
  (use io)
  (use shen-jit)
  (import struct defstruct)
  (externals [application body-limit body-timeout chunk-count-limit chunk-line-limit
    chunk-metadata-limit chunk-size connection-timeout define-foreign eof head-limit head-timeout
    http http-head http-server-options idle-timeout int64 library ok pointer read-buffer-size
    request-limit response-body-limit response-chunk-count-limit response-chunk-size
    response-head-limit timeout trailer-fields-limit trailer-limit write-timeout])
  (export chunk-option option request response response-option serve-connection serve-one)

(shen-jit.library time-lib ["libc.so.6" "libSystem.dylib" "ucrtbase.dll"])
(define-foreign c-time time-lib
  (if (= (value *os*) "Windows") "_time64" "time") (pointer) --> int64)

(define quotient
  N Divisor -> (/ (- N (shen.mod N Divisor)) Divisor))

(define leap?
  Year -> (and (= (shen.mod Year 4) 0)
               (or (not (= (shen.mod Year 100) 0)) (= (shen.mod Year 400) 0))))

(define calendar-year
  Days Year ->
    (let Count (if (leap? Year) 366 365)
      (if (< Days Count) (@p Year Days) (calendar-year (- Days Count) (+ Year 1)))))

(define calendar-month
  Days Year Month ->
    (let Count (cond ((= Month 2) (if (leap? Year) 29 28))
                      ((element? Month [4 6 9 11]) 30)
                      (true 31))
      (if (< Days Count) (@p Month (+ Days 1)) (calendar-month (- Days Count) Year (+ Month 1)))))

(define list-at
  [X | _] 0 -> X
  [_ | Rest] N -> (list-at Rest (- N 1)))

(define two-digits
  N -> (if (< N 10) (cn "0" (str N)) (str N)))

(define date-value
  Seconds ->
    (let N (buffer.index Seconds)
         _ (if (< N 253402300800) true (error "http: date is outside years 1970..9999"))
         Days (quotient N 86400)
         Time (shen.mod N 86400)
         Calendar (calendar-year Days 1970)
         Year (fst Calendar)
         MonthDay (calendar-month (snd Calendar) Year 1)
         Month (list-at ["Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"]
                             (- (fst MonthDay) 1))
         Weekday (list-at ["Sun" "Mon" "Tue" "Wed" "Thu" "Fri" "Sat"] (shen.mod (+ Days 4) 7))
      (make-string "~A, ~A ~A ~A ~A:~A:~A GMT"
        Weekday (two-digits (snd MonthDay)) Month Year
        (two-digits (quotient Time 3600))
        (two-digits (quotient (shen.mod Time 3600) 60))
        (two-digits (shen.mod Time 60)))))

(define has-date?
  [] -> false
  [[Name _] | Rest] -> (or (= (lower Name) "date") (has-date? Rest))
  _ -> (error "http: response fields must be pairs"))

(define server-response
  Response ->
    (let _ (response-check Response)
         Fields (response-field-list Response)
      (if (has-date? Fields)
          Response
          (let Date (trap-error (date-value (c-time [])) (/. X []))
            (if (empty? Date)
                Response
                (response-copy-fields Response [["Date" Date] | Fields]
                                           (response-closes? Response)))))))

(define option-index
  head-limit -> 0
  body-limit -> 1
  response-head-limit -> 2
  response-body-limit -> 3
  head-timeout -> 4
  body-timeout -> 5
  write-timeout -> 6
  chunk-line-limit -> 7
  chunk-metadata-limit -> 8
  trailer-limit -> 9
  trailer-fields-limit -> 10
  chunk-count-limit -> 11
  response-chunk-size -> 12
  response-chunk-count-limit -> 13
  request-limit -> 14
  idle-timeout -> 15
  connection-timeout -> 16
  read-buffer-size -> 17
  _ -> (error "http: unknown server option"))

\\ A server's configuration, with the limits its body readers and responses take built once.
(defstruct server-config
  head-limit
  body-limit
  output
  head-timeout
  body-timeout
  write-timeout
  chunk
  (mutable request-limit)
  idle-timeout
  connection-timeout
  read-buffer-size)

(define server-options
  Options ->
    (let Set (configure Options [])
      (:server-config
        head-limit <- (option-value head-limit Set 16384)
        body-limit <- (option-value body-limit Set 1048576)
        output <- (:output-limits
                    head-limit <- (option-value response-head-limit Set 16384)
                    body-limit <- (option-value response-body-limit Set 1048576)
                    chunk-size <- (option-value response-chunk-size Set 16384)
                    chunk-count-limit <- (option-value response-chunk-count-limit Set 4096))
        head-timeout <- (option-value head-timeout Set 5000)
        body-timeout <- (option-value body-timeout Set 5000)
        write-timeout <- (option-value write-timeout Set 5000)
        chunk <- (:chunk-limits
                   line-limit <- (option-value chunk-line-limit Set 8192)
                   metadata-limit <- (option-value chunk-metadata-limit Set 65536)
                   trailer-limit <- (option-value trailer-limit Set 16384)
                   trailer-fields-limit <- (option-value trailer-fields-limit Set 100)
                   count-limit <- (option-value chunk-count-limit Set 4096))
        request-limit <- (option-value request-limit Set 100)
        idle-timeout <- (option-value idle-timeout Set 5000)
        connection-timeout <- (option-value connection-timeout Set 60000)
        read-buffer-size <- (option-value read-buffer-size Set 16384))))

(define configure
  [] Set -> Set
  [[Name Value] | Rest] Set ->
    (let I (option-index Name)
         _ (if (empty? (assoc Name Set)) true (error "http: duplicate server option"))
         N (buffer.index Value)
         _ (if (element? I [0 2])
               (if (and (>= N (if (= I 2) 128 4)) (<= N 1048576))
                   true (error "http: invalid server head limit"))
               true)
         _ (if (and (>= I 7) (<= I 11)) (chunk-options [[Name N]]) true)
         _ (if (and (>= I 12) (<= I 14))
               (if (and (> N 0) (<= N 1048576)) true
                   (error "http: chunk size, chunk count and request limit must be 1..1048576")) true)
         _ (if (= I 17)
               (if (and (> N 0) (<= N 65536)) true
                   (error "http: read buffer size must be 1..65536")) true)
      (configure Rest [[Name N] | Set]))
  _ _ -> (error "http: server options must be [Name Number] pairs"))

(define serve-one
  E Handler Options ->
    (let Config (server-options Options)
         _ (server-config.request-limit-> Config 1)
      (connection E Handler Config (freeze false))))

(define serve-connection
  E Handler Options -> (serve-controlled E Handler Options (freeze false)))

(define serve-controlled
  E Handler Options Stop -> (connection E Handler (server-options Options) Stop))

\\ One task owns the socket, its single reader and every source returned by its handler.
\\ A session: endpoint, reader, handler, config, stop thunk, total deadline,
\\ completed request count and acknowledged wire bytes.
(define show-session
  C -> (make-string "#<http connection ~A requests>" (session.requests C)))

(defstruct session
  (printer show-session)
  endpoint
  reader
  handler
  config
  stop
  deadline
  (mutable requests)
  (mutable written))

(define connection
  E Handler Config Stop ->
    (do (io.socket-check E)
        (grammar.prepare <head>)
        (io.with-endpoint E
          (/. Peer (let R (io.reader Peer [[chunk-size (server-config.read-buffer-size Config)]])
                       C (:session
                           endpoint <- Peer
                           reader <- R
                           handler <- Handler
                           config <- Config
                           stop <- Stop
                           deadline <- (clock.deadline (server-config.connection-timeout Config))
                           requests <- 0
                           written <- 0)
                    (connection-read C))))))

\\ A head that fits the reader is read in place as it arrives; a larger limit frames it first.
(define connection-read
  C ->
    (if (thaw (session.stop C))
        [ok (session.written C)]
        (let Config (session.config C)
             R (session.reader C)
             Limit (server-config.head-limit Config)
             D (deadline.within (session.deadline C) (server-config.head-timeout Config))
             _ (io.socket-deadline (session.endpoint C) D)
          (if (<= Limit (io.window-size R))
              (connection-parsed C (read-request R Limit (server-config.body-limit Config)))
              (connection-head C (read-head-until (head-reader R Limit) D))))))

(define connection-head
  C [eof] -> [ok (session.written C)]
  C [error Error] -> (connection-fail C Error)
  C [head V] ->
    (connection-parsed C (parse-request V (server-config.body-limit (session.config C)))))

(define connection-parsed
  C [eof] -> [ok (session.written C)]
  C [error Error] -> (connection-fail C Error)
  C [ok Q] ->
    (let Config (session.config C)
         D (deadline.within (session.deadline C) (server-config.body-timeout Config))
         _ (io.socket-deadline (session.endpoint C) D)
         B (body-reader-limits (session.reader C) Q (server-config.chunk Config))
      (connection-body C (read-body-until B D))))

(define connection-body
  C [error Error] -> (connection-fail C Error)
  C [ok Q] ->
    (let Handler (session.handler C)
         Result (trap-error [ok (Handler Q)]
                  (/. X [error (output-error (error-to-string X))]))
      (connection-handled C Q Result)))

(define connection-handled
  C _ [error Error] -> (connection-fail C Error)
  C Q [ok Response] ->
    (let Config (session.config C)
         D (deadline.within (session.deadline C) (server-config.write-timeout Config))
         _ (io.socket-deadline (session.endpoint C) D)
         Prepared (trap-error
                    (let R (server-response Response)
                         Close (or (response-closes? R)
                                   (element? "close" (token-list (header-values Q "connection")))
                                   (>= (+ (session.requests C) 1) (server-config.request-limit Config))
                                   (thaw (session.stop C)))
                         Plan (prepare-response (method Q) R
                                (server-config.output Config) Close D)
                      (@p Close Plan))
                    (/. X (@p true (finish-source
                                     [error (output-error (error-to-string X))]
                                     (response-source Response)))))
      (connection-prepared C D (fst Prepared) (snd Prepared))))

(define connection-prepared
  C _ _ [error Error] -> (connection-fail C Error)
  C D Close [ok Plan] ->
    (io.let-ok N (send-plan (session.endpoint C) D Plan)
      (let _ (session.requests-> C (+ (session.requests C) 1))
           _ (session.written-> C (+ (session.written C) N))
        (if (or Close (thaw (session.stop C)) (deadline.expired? (session.deadline C)))
            [ok (session.written C)]
            (connection-idle C (deadline.within (session.deadline C)
                                                 (server-config.idle-timeout (session.config C))))))))

\\ Idle time starts after the response. Short bounded waits observe shutdown without
\\ cancelling an active request or renewing the idle/connection deadline.
(define connection-idle
  C D ->
    (if (or (thaw (session.stop C)) (deadline.expired? D))
        [ok (session.written C)]
        (let _ (io.socket-deadline (session.endpoint C) (deadline.within D 50))
          (connection-available C D (io.peek-up-to (session.reader C) 1)))))

(define connection-available
  C _ [eof] -> [ok (session.written C)]
  C _ [ok _] -> (connection-read C)
  C D [error Error] ->
    (if (= (io.error-domain Error) timeout)
        (connection-idle C D)
        [error Error]))

(define connection-fail
  C Error ->
    (server-fail-until (session.endpoint C) (session.config C) Error
      (deadline.within (session.deadline C) (server-config.write-timeout (session.config C)))))

(define server-status
  Error ->
    (let Domain (io.error-domain Error)
      (cond ((= Domain http) (io.error-code Error))
            ((= Domain application) 500)
            ((= Domain timeout) 408)
            ((and (= Domain library) (= (io.error-operation Error) http-head))
              (if (= (io.error-message Error) "head exceeds byte limit") 431 400))
            (true 0))))

(define server-fail-until
  E Config Error D ->
    (let Status (server-status Error)
      (if (= Status 0)
          [error Error]
          (let Response (server-response (response Status [] (buffer.new 0)))
               Wire (encode-for "GET" Response (output-limits.head-limit (server-config.output Config))
                                (output-limits.body-limit (server-config.output Config)))
               _ (io.socket-deadline E D)
            (server-rejected Error (io.write-all E Wire []))))))

(define server-rejected
  Error [ok _] -> [error Error]
  Error [error Other N] -> [error (io.secondary Error (io.progress Other N))])

(datatype http-server-options
  N : number;
  ===========================
  [read-buffer-size N] : option;

  Option : response-option;
  ===========================
  Option : option;

  N : number;
  ===========================
  [request-limit N] : option;

  N : number;
  ===========================
  [idle-timeout N] : option;

  N : number;
  ===========================
  [connection-timeout N] : option;

  Option : chunk-option;
  ===========================
  Option : option;

  N : number;
  ===========================
  [head-limit N] : option;

  N : number;
  ===========================
  [body-limit N] : option;

  N : number;
  =============================
  [head-timeout N] : option;

  N : number;
  =============================
  [body-timeout N] : option;

  N : number;
  ==============================
  [write-timeout N] : option;)

(declare serve-one
  [io.endpoint --> [[request --> response] --> [[list option] --> [io.result number]]]])

(declare serve-connection
  [io.endpoint --> [[request --> response] --> [[list option] --> [io.result number]]]])

)
