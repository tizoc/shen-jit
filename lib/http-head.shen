\\ One bounded HTTP head through CRLFCRLF, over our own reader. Load buffer.shen and io.shen.
\\ This frames bytes; request-line/field semantics and body framing belong to a complete parser.
\\ deadline.shen is needed only by http.read-head-until.

(shen.x.namespace http
  (use buffer)
  (use deadline)
  (use io)
  (use shen-jit)
  (import struct defstruct)
  (externals [deadline done eof http-head invalid more ok timeout])
  (export head-reader head-result read-head read-head-until)

\\ A head reader: its borrowed reader, byte limit, accumulator, used count, CRLF state, saved
\\ result and busy flag.
(define show-head
  F -> (make-string "#<head-reader ~A/~A bytes>" (head-state.used F) (head-state.limit F)))

(defstruct head-state
  (printer show-head)
  reader
  limit
  (mutable storage)
  (mutable used)
  (mutable crlf)
  (mutable result)
  (mutable busy))

(define head-reader
  R Limit ->
    (let N (buffer.index Limit)
         _ (if (and (>= N 4) (<= N 1048576)) true
               (error "http: head limit must be 4..1048576 bytes"))
         _ (io.reader-check R)
      (:head-state
        reader <- R
        limit <- N
        storage <- (buffer.new N)
        used <- 0
        crlf <- 0
        result <- []
        busy <- false)))

(define head-check
  F ->
    (let _ (if (head-state? F) true (error "http: not a head reader"))
         _ (if (head-state.busy F) (error "http: head read is already in flight") true)
         _ (io.reader-check (head-state.reader F))
      F))

(define head-error
  F Message -> [error (io.progress (io.error http-head "HTTP head" Message) (head-state.used F))])

(define head-budget
  _ [] -> [ok]
  F D ->
    (if (deadline.expired? D)
        [error (io.progress (io.native-error read timeout 0 "HTTP head" "deadline expired")
                           (head-state.used F))]
        [ok]))

(define read-head
  F -> (head-run F []))

(define read-head-until
  F D -> (do (deadline.check D) (head-run F D)))

(define head-run
  F D ->
    (let _ (head-check F)
         Saved (head-state.result F)
      (if (not (empty? Saved))
          Saved
          (do (head-state.busy-> F true)
              (let Result (trap-error (head-loop F D)
                             (/. X (do (head-state.busy-> F false)
                                       (head-finish F (head-error F (error-to-string X)))
                                       (simple-error (error-to-string X)))))
                (do (head-state.busy-> F false) (head-finish F Result)))))))

(define head-finish
  F Result ->
    (do (head-state.result-> F Result)
        (head-state.storage-> F [])
        Result))

(define head-loop
  F D -> (io.let-ok _ (head-budget F D)
           (if (= (head-state.used F) (head-state.limit F))
               (head-error F "head exceeds byte limit")
               (head-input F D (io.peek-some (head-state.reader F))))))

(define head-input
  F _ [eof] ->
    (if (= (head-state.used F) 0) [eof] (head-error F "incomplete head"))
  F _ [error Error] -> [error (io.progress Error (head-state.used F))]
  F D [ok V] ->
    (let Result (head-scan (buffer.owner V) (buffer.offset V) (buffer.end V)
                                (head-state.crlf F) (- (head-state.limit F) (head-state.used F)) 0)
      (head-scanned F D V Result)))

\\ Scan each new span once. A partial CR or CRLFCR is retained as state, never rescanned.
(define head-scan
  _ At At State _ Count -> [more Count State]
  _ _ _ _ 0 Count -> [limit Count]
  B At End State Left Count ->
    (let Byte (shen-jit.u8 B At)
         N (+ Count 1)
      (cond ((and (element? State [1 3]) (not (= Byte 10))) [invalid N "CR without LF"])
            ((and (= Byte 10) (not (element? State [1 3]))) [invalid N "bare LF"])
            ((or (= Byte 127) (and (< Byte 32) (not (element? Byte [9 10 13]))))
              [invalid N "control byte in head"])
            ((and (= State 3) (= Byte 10)) [done N])
            (true
              (let Next (cond ((= Byte 13) (if (= State 2) 3 1))
                               ((= Byte 10) 2)
                               (true 0))
                (head-scan B (+ At 1) End Next (- Left 1) N))))))

(define head-copy
  F V Count ->
    (let Used (head-state.used F)
      (do (buffer.copy! (head-state.storage F) Used V 0 Count)
          (io.consume (head-state.reader F) Count)
          (head-state.used-> F (+ Used Count))
          F)))

(define head-scanned
  F D V [more Count State] ->
    (do (head-copy F V Count)
        (head-state.crlf-> F State)
        (head-loop F D))
  F _ V [limit Count] ->
    (do (head-copy F V Count) (head-error F "head exceeds byte limit"))
  F _ V [invalid Count Message] ->
    (do (head-copy F V Count) (head-error F Message))
  F D V [done Count] ->
    (do (head-copy F V Count)
        (io.let-ok _ (head-budget F D)
          [head (buffer.wrap (buffer.bytes (buffer.slice (head-state.storage F) 0 (head-state.used F))))])))

\\ The rules for all of http's types. They are here, as every other file of http loads this one
\\ first, and a datatype of the same name in a later file would replace this one. The tags of the
\\ other files' options stay bare in their rules, as clients write them.
(with-externals [body-limit body-timeout chunk-count-limit chunk-line-limit chunk-metadata-limit chunked
    connection-timeout head-limit head-timeout idle-timeout max-connections read-buffer-size
    request-limit response-body-limit response-chunk-count-limit response-chunk-size response-head-limit
    shutdown-grace trailer-fields-limit trailer-limit write-timeout]
  (datatype t
    V : buffer.view;
    ===========================
    [head V] : head-result;

    _______________________
    [eof] : head-result;

    Error : io.error;
    ================================
    [error Error] : head-result;

    N : number;
    ======================================
    [chunk-line-limit N] : chunk-option;

    N : number;
    ======================================
    [chunk-metadata-limit N] : chunk-option;

    N : number;
    ======================================
    [trailer-limit N] : chunk-option;

    N : number;
    ======================================
    [trailer-fields-limit N] : chunk-option;

    N : number;
    ======================================
    [chunk-count-limit N] : chunk-option;

    N : number;
    ==============================
    [length N] : response-framing;

    ______________________________
    [chunked] : response-framing;

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
    [response-chunk-count-limit N] : response-option;

    N : number;
    ===========================
    [read-buffer-size N] : option;

    Option : response-option;
    ___________________________
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
    ___________________________
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
    [write-timeout N] : option;

    ___________________________
    [ok] : wait-result;

    Error : io.error;
    ===========================
    [error Error] : wait-result;

    N : number;
    =================================
    [max-connections N] : listener-option;

    N : number;
    =================================
    [shutdown-grace N] : listener-option;

    Option : option;
    _________________________________
    Option : listener-option;

    F : symbol;
    _________________________________
    F : handler;

    F : symbol; Args : (list A);
    _________________________________
    [F | Args] : handler;))

(declare head-reader [io.reader --> [number --> head-reader]])
(declare read-head [head-reader --> head-result])
(declare read-head-until [head-reader --> [deadline --> head-result]])

)
