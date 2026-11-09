\\ Sequential HTTP/1.1 requests per owned socket. Load clock/deadline/socket I/O and HTTP modules first.
\\ The application receives a complete request and returns a response value, without writing bytes.

(shen.x.namespace http
  (use buffer)
  (use clock)
  (use deadline)
  (use grammar)
  (use io)
  (use shen-jit)
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
         Fields (<-address Response 2)
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

(define server-options
  Options ->
    (configure (io.record [16384 1048576 16384 1048576 5000 5000 5000
                               8192 65536 16384 100 4096 16384 4096 100 5000 60000 16384]) Options []))

(define configure
  Config [] _ -> Config
  Config [[Name Value] | Rest] Seen ->
    (let I (option-index Name)
         _ (if (element? Name Seen) (error "http: duplicate server option") true)
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
         _ (address-> Config I N)
      (configure Config Rest [Name | Seen]))
  _ _ _ -> (error "http: server options must be [Name Number] pairs"))

(define serve-one
  E Handler Options ->
    (let Config (server-options Options)
         _ (address-> Config 14 1)
      (connection E Handler Config (freeze false))))

(define serve-connection
  E Handler Options -> (serve-controlled E Handler Options (freeze false)))

(define serve-controlled
  E Handler Options Stop -> (connection E Handler (server-options Options) Stop))

\\ One task owns the socket, its single reader and every source returned by its handler.
\\ Connection slots: endpoint, reader, handler, config, stop thunk, total deadline,
\\ completed request count and acknowledged wire bytes.
(define connection
  E Handler Config Stop ->
    (do (io.socket-check E)
        (grammar.prepare <head>)
        (io.with-endpoint E
          (/. Peer (let R (io.reader Peer [[chunk-size (<-address Config 17)]])
                       C (io.record [Peer R Handler Config Stop
                                     (clock.deadline (<-address Config 16)) 0 0])
                    (connection-read C))))))

\\ A head that fits the reader is read in place as it arrives; a larger limit frames it first.
(define connection-read
  C ->
    (if (thaw (<-address C 4))
        [ok (<-address C 7)]
        (let Config (<-address C 3)
             R (<-address C 1)
             D (deadline.within (<-address C 5) (<-address Config 4))
             _ (io.socket-deadline (<-address C 0) D)
          (if (<= (<-address Config 0) (io.window-size R))
              (connection-parsed C (read-request R (<-address Config 0) (<-address Config 1)))
              (connection-head C (read-head-until (head-reader R (<-address Config 0)) D))))))

(define connection-head
  C [eof] -> [ok (<-address C 7)]
  C [error Error] -> (connection-fail C Error)
  C [head V] ->
    (connection-parsed C (parse-request V (<-address (<-address C 3) 1))))

(define connection-parsed
  C [eof] -> [ok (<-address C 7)]
  C [error Error] -> (connection-fail C Error)
  C [ok Q] ->
    (let Config (<-address C 3)
         D (deadline.within (<-address C 5) (<-address Config 5))
         _ (io.socket-deadline (<-address C 0) D)
         B (body-reader-with (<-address C 1) Q (server-body-options Config))
      (connection-body C (read-body-until B D))))

(define server-body-options
  Config -> [[chunk-line-limit (<-address Config 7)] [chunk-metadata-limit (<-address Config 8)]
             [trailer-limit (<-address Config 9)] [trailer-fields-limit (<-address Config 10)]
             [chunk-count-limit (<-address Config 11)]])

(define server-output-limits
  Config -> (io.record [(<-address Config 2) (<-address Config 3)
                       (<-address Config 12) (<-address Config 13)]))

(define connection-body
  C [error Error] -> (connection-fail C Error)
  C [ok Q] ->
    (let Handler (<-address C 2)
         Result (trap-error [ok (Handler Q)]
                  (/. X [error (output-error (error-to-string X))]))
      (connection-handled C Q Result)))

(define connection-handled
  C _ [error Error] -> (connection-fail C Error)
  C Q [ok Response] ->
    (let Config (<-address C 3)
         D (deadline.within (<-address C 5) (<-address Config 6))
         _ (io.socket-deadline (<-address C 0) D)
         Prepared (trap-error
                    (let R (server-response Response)
                         Close (or (response-closes? R)
                                   (element? "close" (token-list (header-values Q "connection")))
                                   (>= (+ (<-address C 6) 1) (<-address Config 14))
                                   (thaw (<-address C 4)))
                         Plan (prepare-response (method Q) R
                                (server-output-limits Config) Close D)
                      (@p Close Plan))
                    (/. X (@p true (finish-source
                                     [error (output-error (error-to-string X))]
                                     (response-source Response)))))
      (connection-prepared C D (fst Prepared) (snd Prepared))))

(define connection-prepared
  C _ _ [error Error] -> (connection-fail C Error)
  C D Close [ok Plan] ->
    (io.let-ok N (send-plan (<-address C 0) D Plan)
      (let _ (address-> C 6 (+ (<-address C 6) 1))
           _ (address-> C 7 (+ (<-address C 7) N))
        (if (or Close (thaw (<-address C 4)) (deadline.expired? (<-address C 5)))
            [ok (<-address C 7)]
            (connection-idle C (deadline.within (<-address C 5) (<-address (<-address C 3) 15)))))))

\\ Idle time starts after the response. Short bounded waits observe shutdown without
\\ cancelling an active request or renewing the idle/connection deadline.
(define connection-idle
  C D ->
    (if (or (thaw (<-address C 4)) (deadline.expired? D))
        [ok (<-address C 7)]
        (let _ (io.socket-deadline (<-address C 0) (deadline.within D 50))
          (connection-available C D (io.peek-up-to (<-address C 1) 1)))))

(define connection-available
  C _ [eof] -> [ok (<-address C 7)]
  C _ [ok _] -> (connection-read C)
  C D [error Error] ->
    (if (= (io.error-domain Error) timeout)
        (connection-idle C D)
        [error Error]))

(define connection-fail
  C Error ->
    (server-fail-until (<-address C 0) (<-address C 3) Error
      (deadline.within (<-address C 5) (<-address (<-address C 3) 6))))

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
               Wire (encode-for "GET" Response (<-address Config 2) (<-address Config 3))
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
