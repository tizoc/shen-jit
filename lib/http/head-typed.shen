\\ The bounded head reader uses options for its accumulator, saved result and deadline.
(shen.x.namespace http
  (use result)
  (use buffer)
  (use deadline)
  (use io)
  (use option)
  (import result let-ok ok err)
  (use shen-jit)
  (externals [deadline http-head timeout])
  (export head-reader read-head read-head-until)

(define head-reader
  {io.reader --> fixnum --> head-reader}
  R Limit ->
    (let N (buffer.index Limit)
         _ (if (and (fx>= N 4) (fx<= N 1048576)) true
               (error "http: head limit must be 4..1048576 bytes"))
         _ (io.reader-check R)
      (:head-reader
        reader <- R
        limit <- N
        storage <- (option.some (buffer.new N))
        used <- 0
        crlf <- 0
        result <- (option.none)
        busy <- false)))

(define head-check
  {head-reader --> head-reader}
  F ->
    (let _ (if (head-reader? F) true (error "http: not a head reader"))
         _ (if (head-reader.busy F) (error "http: head read is already in flight") true)
         _ (io.reader-check (head-reader.reader F))
      F))

(define head-error
  {head-reader --> string --> (io.result (option.t buffer.view))}
  F Message -> (err (io.progress (io.error http-head "HTTP head" Message) (head-reader.used F))))

(define head-budget
  {head-reader --> (option.t deadline) --> (io.result result.empty)}
  _ [] -> (ok [])
  F [D] ->
    (if (deadline.expired? D)
        (err (io.progress (io.native-error read timeout 0 "HTTP head" "deadline expired")
                           (head-reader.used F)))
        (ok [])))

(define read-head
  {head-reader --> (io.result (option.t buffer.view))}
  F -> (head-run F (option.none)))

(define read-head-until
  {head-reader --> deadline --> (io.result (option.t buffer.view))}
  F D -> (head-run F (option.some (deadline.check D))))

(define head-run
  {head-reader --> (option.t deadline) --> (io.result (option.t buffer.view))}
  F D -> (head-run-saved (head-check F) D (head-reader.result F)))

(define head-run-saved
  {head-reader --> (option.t deadline) -->
   (option.t (io.result (option.t buffer.view))) --> (io.result (option.t buffer.view))}
  _ _ [Saved] -> Saved
  F D [] ->
    (do (head-reader.busy-> F true)
        (let Result (trap-error (head-loop F D)
                       (/. X (do (head-reader.busy-> F false)
                                 (head-finish F (head-error F (error-to-string X)))
                                 (simple-error (error-to-string X)))))
          (do (head-reader.busy-> F false) (head-finish F Result)))))

(define head-finish
  {head-reader --> (io.result (option.t buffer.view)) --> (io.result (option.t buffer.view))}
  F Result ->
    (do (head-reader.result-> F (option.some Result))
        (head-reader.storage-> F (option.none))
        Result))

(define head-loop
  {head-reader --> (option.t deadline) --> (io.result (option.t buffer.view))}
  F D -> (let-ok _ (head-budget F D)
           (if (= (head-reader.used F) (head-reader.limit F))
               (head-error F "head exceeds byte limit")
               (head-input F D (io.peek-some (head-reader.reader F))))))

(define head-input
  {head-reader --> (option.t deadline) --> (io.result (option.t buffer.view)) --> (io.result (option.t buffer.view))}
  F _ (:ok []) ->
    (if (= (head-reader.used F) 0) (ok (option.none)) (head-error F "incomplete head"))
  F _ (:err Error) -> (err (io.progress Error (head-reader.used F)))
  F D (:ok [V]) ->
    (let Result (head-scan (buffer.owner V) (buffer.offset V) (buffer.end V)
                                (head-reader.crlf F) (fx- (head-reader.limit F) (head-reader.used F)) 0)
      (head-scanned F D V Result)))

\\ Scan each new span once. A partial CR or CRLFCR is retained as state, never rescanned.
(define head-scan
  {buffer.storage --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum -->
   (fixnum * (result.t (string * (option.t fixnum))))}
  _ At At State _ Count -> (@p Count (ok (option.some State)))
  _ _ _ _ 0 Count -> (@p Count (err "head exceeds byte limit"))
  B At End State Left Count ->
    (let Byte (shen-jit.u8 B At)
         N (fx+ Count 1)
         Needs-LF (or (= State 1) (= State 3))
      (cases (and Needs-LF (not (= Byte 10))) (@p N (err "CR without LF"))
             (and (= Byte 10) (not Needs-LF)) (@p N (err "bare LF"))
             (or (= Byte 127) (and (fx< Byte 32) (not (element? Byte [9 10 13]))))
               (@p N (err "control byte in head"))
             (and (= State 3) (= Byte 10)) (@p N (ok (option.none)))
             true
               (let Next (type (cases (= Byte 13) (if (= State 2) 3 1)
                                      (= Byte 10) 2
                                      true 0)
                               fixnum)
                 (head-scan B (fx+ At 1) End Next (fx- Left 1) N)))))

(define head-storage
  {(option.t buffer.view) --> buffer.view}
  [Storage] -> Storage
  [] -> (error "http: head reader has no accumulator"))

(define head-copy
  {head-reader --> buffer.view --> fixnum --> head-reader}
  F V Count ->
    (let Used (head-reader.used F)
      (do (buffer.copy-into! (head-storage (head-reader.storage F)) Used V 0 Count)
          (io.consume (head-reader.reader F) Count)
          (head-reader.used-> F (fx+ Used Count))
          F)))

(define head-scanned
  {head-reader --> (option.t deadline) --> buffer.view -->
   (fixnum * (result.t (string * (option.t fixnum)))) --> (io.result (option.t buffer.view))}
  F D V (@p Count (:ok [State])) ->
    (do (head-copy F V Count)
        (head-reader.crlf-> F State)
        (head-loop F D))
  F _ V (@p Count (:err Message)) ->
    (do (head-copy F V Count) (head-error F Message))
  F D V (@p Count (:ok [])) ->
    (do (head-copy F V Count)
        (let-ok _ (head-budget F D)
          (let View (head-storage (head-reader.storage F))
               Head (buffer.slice View 0 (head-reader.used F))
            (ok (option.some (buffer.wrap (buffer.bytes Head))))))))

)
