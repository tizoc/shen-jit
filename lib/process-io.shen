\\ Concurrent subprocess communication, driven in Shen over nonblocking process pipes.
\\ Load process.shen first. No worker threads, native callbacks or unbounded handoff queues.

(shen.x.namespace process
  (use buffer)
  (use clock)
  (use deadline)
  (use io)
  (use shen-jit)
  (externals [cancel cancelled chunk-size cleanup-timeout closed communicate done eof exited ok
    process-commands running shen stderr-limit stdout-limit terminate-grace timeout write written])
  (shadow abort close output run)
  (export child command process.communicate => communicate communicate-to error-bytes error-count
    error-observed? input-count input-read-count option output-bytes output-count
    output-observed? pending-input pipeline pipeline-to report result run run-to status success?)

(define view-read
  View Position Bytes ->
    (let At (<-address Position 0)
         Left (- (buffer.length View) At)
         N (io.min Left (shen-jit.bytes-length Bytes))
      (if (= N 0)
          [eof]
          (do (shen-jit.copy-bytes Bytes 0 (buffer.owner View) (+ (buffer.offset View) At) N)
              (address-> Position 0 (+ At N))
              [read N]))))

(define view-source
  View ->
    (let _ (buffer.check View)
         Position (io.record [0])
      (io.endpoint "process input bytes" read 65536
        (/. Bytes (view-read View Position Bytes))
        (function io.no-write) (freeze [ok]))))

(define communication-pipes
  [] -> []
  [Child | Rest] ->
    (append (keep (/. E (and (not (= E [])) (not (= (<-address E 7) closed))))
              (map (/. I (<-address (<-address Child 3) I)) [0 1 2]))
            (communication-pipes Rest)))

(define keep
  _ [] -> []
  F [X | Rest] -> (if (F X) [X | (keep F Rest)] (keep F Rest)))

(define check-pipes
  [] -> true
  [E | Rest] ->
    (do (io.check E (<-address E 2) [])
        (check-pipes Rest)))

(define lock-pipes
  [] Flag -> true
  [E | Rest] Flag ->
    (do (address-> E 11 Flag) (lock-pipes Rest Flag)))

(define busy-children
  [] Flag -> true
  [Child | Rest] Flag ->
    (do (address-> Child 6 Flag) (busy-children Rest Flag)))

(define close-active
  E ->
    (if (= (<-address E 7) closed)
        (<-address E 8)
        (do (address-> E 11 false) (io.close E))))

(define close-active-pipes
  [] Result -> Result
  [E | Rest] Result ->
    (close-active-pipes Rest (finish-unit Result (close-active E))))

\\ Each output owns a bounded collector, or borrows an independent I/O sink.
\\ endpoint, sink, limit, count, reversed chunks, eof, child, stream number.
(define output
  Child Index Sink Limit ->
    (let E (<-address (<-address Child 3) Index)
      (if (or (= E []) (= (<-address E 7) closed))
          []
          (io.record [E Sink Limit 0 [] false Child Index]))))

(define outputs
  Children OutSink ErrSink Config ->
    (outputs-loop Children OutSink ErrSink Config []))

(define outputs-loop
  [] _ _ _ Acc -> (reverse Acc)
  [Child | Rest] OutSink ErrSink Config Acc ->
    (let Err (output Child 2 ErrSink (<-address Config 9))
         Out (output Child 1 OutSink (<-address Config 8))
         Next (if (= Err []) Acc [Err | Acc])
         Next (if (= Out []) Next [Out | Next])
      (outputs-loop Rest OutSink ErrSink Config Next)))

(define error-at
  Domain Resource Message -> (io.native-error communicate Domain 0 Resource Message))

(define check-cancel
  State ->
    (cond ((thaw (<-address (<-address State 8) 11))
            [error (error-at cancelled "process" "process operation cancelled")])
          ((deadline.expired? (<-address State 1))
            [error (error-at timeout "process" "process deadline expired")])
          (true [ok])))

(define feed
  State ->
    (let Feed (<-address State 5)
         E (<-address (<-address (hd (<-address State 4)) 3) 0)
      (cond ((or (= E []) (= (<-address E 7) closed)) [ok])
            ((< (<-address Feed 2) (<-address Feed 3)) (feed-write State E Feed))
            ((<-address Feed 4)
              (do (address-> State 0 true) (close-active E)))
            (true
              (feed-read State E Feed
                (io.read-some (<-address Feed 0) (<-address Feed 1) []))))))

(define feed-read
  State E Feed [read N] ->
    (do (address-> Feed 2 0)
        (address-> Feed 3 N)
        (feed-write State E Feed))
  State E Feed [eof] ->
    (do (address-> Feed 4 true)
        (address-> State 0 true)
        (close-active E))
  _ _ _ [error Error] -> [error Error])

(define feed-write
  State E Feed ->
    (let At (<-address Feed 2)
         View (buffer.slice (<-address Feed 1) At (- (<-address Feed 3) At))
         Bytes (buffer.bytes View)
      (io.let-ok N (native write "process stdin"
                     (freeze (c-write (<-address E 12) Bytes)))
        (do (if (> N 0)
                (do (address-> Feed 2 (+ At N))
                    (address-> Feed 5 (+ (<-address Feed 5) N))
                    (address-> State 0 true)) true)
            [ok]))))

(define capture-output
  Output View ->
    (let N (buffer.length View)
         Owned (buffer.wrap (buffer.bytes View))
         _ (address-> Output 4 [Owned | (<-address Output 4)])
         _ (address-> Output 3 (+ (<-address Output 3) N))
      [ok]))

(define sink-output
  _ _ End End -> [ok]
  Output View At End ->
    (let Result (io.write-some (<-address Output 1) (buffer.slice View At (- End At)) [])
      (sink-step Output View At End Result)))

(define sink-step
  Output View At End [written N] ->
    (do (address-> Output 3 (+ (<-address Output 3) N))
        (sink-output Output View (+ At N) End))
  Output _ _ _ [error Error] -> [error (io.progress Error (<-address Output 3))])

(define deliver-output
  _ _ 0 -> [ok]
  Output Chunk N ->
    (let View (buffer.slice Chunk 0 N)
      (if (= (<-address Output 1) [])
          (capture-output Output View)
          (sink-output Output View 0 N))))

(define read-output
  State Output Chunk ->
    (if (<-address Output 5)
        [ok]
        (let E (<-address Output 0)
          (io.let-ok N (native read "process output"
                         (freeze (c-read (<-address E 12) (buffer.owner Chunk))))
            (cond ((< N 0) [ok])
                  ((= N 0)
                    (do (address-> State 0 true)
                        (address-> Output 5 true)
                        (close-active E)))
                  (true
                    (let Left (- (<-address Output 2) (<-address Output 3))
                         Keep (io.min Left N)
                         _ (address-> State 0 true)
                      (io.let-ok _ (deliver-output Output Chunk Keep)
                        (if (> N Left)
                            [error (io.progress
                                     (error-at limit
                                       (if (= (<-address Output 7) 1) "stdout" "stderr")
                                       "process output limit exceeded")
                                     (<-address Output 3))]
                            [ok])))))))))

(define read-outputs
  _ [] _ -> [ok]
  State [Output | Rest] Chunk ->
    (io.let-ok _ (read-output State Output Chunk)
      (read-outputs State Rest Chunk)))

(define poll-children
  [] -> [ok]
  [Child | Rest] ->
    (io.let-ok _ (if (<-address Child 4) [ok done] (poll Child))
      (poll-children Rest)))

(define children-done?
  [] -> true
  [Child | Rest] ->
    (and (not (= (<-address Child 7) [running])) (children-done? Rest)))

(define outputs-done?
  [] -> true
  [Output | Rest] -> (and (<-address Output 5) (outputs-done? Rest)))

(define input-done?
  State ->
    (let E (<-address (<-address (hd (<-address State 4)) 3) 0)
      (or (= E []) (= (<-address E 7) closed))))

(define wait-pointers
  State ->
    (let Feed (<-address State 5)
         Input (<-address (<-address (hd (<-address State 4)) 3) 0)
         Output (map (/. O (<-address (<-address O 0) 12))
                     (keep (/. O (not (<-address O 5))) (<-address State 6)))
      (if (and (not (= Input [])) (not (= (<-address Input 7) closed))
               (< (<-address Feed 2) (<-address Feed 3)))
          [(<-address Input 12) | Output]
          Output)))

(define pump
  State Chunk ->
    (io.let-ok _ (check-cancel State)
               _ (do (address-> State 0 false) (feed State))
               _ (read-outputs State (<-address State 6) Chunk)
               _ (poll-children (<-address State 4))
      (if (and (input-done? State) (outputs-done? (<-address State 6))
               (children-done? (<-address State 4)))
          [ok]
          (do (if (<-address State 0) true
                  (c-pause (wait-pointers State)
                    (deadline.slice (<-address State 1) 20)))
              (pump State Chunk)))))

(define signal-children
  [] _ Result -> Result
  [Child | Rest] Force Result ->
    (signal-children Rest Force
      (finish-unit Result (if (<-address Child 4) [ok] (signal Child Force)))))

\\ Read the budget once per round: a second reading could find it expired just after the first
\\ did not, and give up without forcing.
(define cleanup-wait
  State Budget Grace Forced Result ->
    (let Children (<-address State 4)
         Polled (poll-children Children)
         Result (finish-unit Result Polled)
         Late (deadline.expired? Budget)
      (cond ((and (children-done? Children)
                  (or Forced (not (groups? Children)))) Result)
            ((and (not Forced) (or Late (deadline.expired? Grace)))
              (cleanup-wait State Budget Grace true
                (signal-children Children true Result)))
            (Late
              (finish-unit Result
                [error (error-at timeout "process cleanup"
                         "cleanup deadline expired; retain the report's child handle")]))
            (true (do (c-pause [] (deadline.slice Budget 20))
                      (cleanup-wait State Budget Grace Forced Result))))))

(define groups?
  [] -> false
  [Child | Rest] -> (or (and (not (<-address Child 4)) (<-address Child 8))
                       (groups? Rest)))

(define cleanup-error
  State Error ->
    (let Config (<-address State 8)
         Budget (clock.deadline (<-address Config 7))
         Grace (deadline.within Budget (<-address Config 12))
         Signals (signal-children (<-address State 4) false [ok])
         Pipes (close-active-pipes (communication-pipes (<-address State 4)) Signals)
      (io.finish [error Error] (cleanup-wait State Budget Grace false Pipes))))

(define close-finished
  [] Result -> Result
  [Child | Rest] Result ->
    (close-finished Rest
      (if (= (<-address Child 7) [running])
          Result
          (finish-unit Result (close Child)))))

(define output-for
  [] _ _ -> []
  [Output | Rest] Child Index ->
    (if (and (shen-jit.same? (<-address Output 6) Child) (= (<-address Output 7) Index))
        Output
        (output-for Rest Child Index)))

(define collected-count
  [] -> 0
  Output -> (<-address Output 3))

(define collected-bytes
  [] -> (buffer.new 0)
  Output ->
    (if (= (<-address Output 1) [])
        (io.join (<-address Output 3) (reverse (<-address Output 4)))
        (buffer.new 0)))

(define reports
  [] _ _ -> []
  [Child | Rest] State First ->
    (let Out (output-for (<-address State 6) Child 1)
         Err (output-for (<-address State 6) Child 2)
         Report (io.record [report Child (<-address Child 7)
                            (if First (<-address (<-address State 5) 5) 0)
                            (collected-count Out) (collected-count Err)
                            (collected-bytes Out) (collected-bytes Err)
                            (if First (feed-pending (<-address State 5)) (buffer.new 0))
                            (not (= Out [])) (not (= Err []))])
      [Report | (reports Rest State false)]))

(define exchange
  Children Source OutSink ErrSink Config Budget Own ->
    (let Pipes (communication-pipes Children)
         _ (check-children Children)
         Input (<-address (<-address (hd Children) 3) 0)
         _ (if (and (not (= Input [])) (= (<-address Input 7) open))
               true (error "process: communication requires an open stdin pipe"))
         _ (check-pipes Pipes)
         _ (io.check Source read [])
         _ (if (= OutSink []) true (io.check OutSink write []))
         _ (if (= ErrSink []) true (io.check ErrSink write []))
         _ (if (or (shen-jit.same? Source OutSink) (shen-jit.same? Source ErrSink))
               (error "process: input source and output sinks must differ") true)
         Feed (io.record [Source (buffer.new (<-address Config 10)) 0 0 false 0])
         Outputs (outputs Children OutSink ErrSink Config)
         Chunk (buffer.new (<-address Config 10))
         State (io.record [false Budget [] [] Children Feed Outputs Own Config])
         _ (lock-pipes Pipes true)
         _ (busy-children Children true)
         Result (trap-error (pump State Chunk)
                   (/. X [error (error-at shen "process communication" (error-to-string X))]))
         Result (if (= Result [ok])
                    (close-active-pipes Pipes [ok])
                    (cleanup-error State (hd (tl Result))))
         _ (lock-pipes Pipes false)
         _ (busy-children Children false)
         Closed (if Own (close-finished Children [ok]) [ok])
         Final (finish-unit Result Closed)
         Reports (reports Children State true)
      (if (= Final [ok]) [ok Reports] [error (hd (tl Final)) Reports])))

(define check-children
  [] -> true
  [Child | Rest] ->
    (do (live Child)
        (if (<-address Child 6) (error "process: communication is already in progress") true)
        (check-children Rest)))

(define single-result
  [ok [Report]] -> [ok Report]
  [error Error [Report]] -> [error Error Report]
  Other -> Other)

(define process.communicate
  Child Input Options ->
    (let Config (communication-options Options)
         _ (capture-limits Config)
         Source (view-source Input)
         Budget (clock.deadline (<-address Config 6))
      (single-result (exchange [Child] Source [] [] Config Budget false))))

(define communicate-to
  Child Source OutSink ErrSink Options ->
    (let _ (stream-arguments Source OutSink ErrSink)
         Config (communication-options Options)
         Budget (clock.deadline (<-address Config 6))
      (single-result (exchange [Child] Source OutSink ErrSink Config Budget false))))

(define run
  Program Args Input Options ->
    (let Config (options Options true)
         _ (capture-limits Config)
         Source (view-source Input)
         Budget (clock.deadline (<-address Config 6))
      (io.let-ok Child (spawn-config Program Args Config)
        (single-result (owned-exchange [Child] Source [] [] Config Budget)))))

(define run-to
  Program Args Source OutSink ErrSink Options ->
    (let Config (options Options true)
         _ (stream-arguments Source OutSink ErrSink)
         Budget (clock.deadline (<-address Config 6))
      (io.let-ok Child (spawn-config Program Args Config)
        (single-result (owned-exchange [Child] Source OutSink ErrSink Config Budget)))))

(define report-check
  Report -> (if (io.tag? Report report) Report (error "process: not an execution report")))

(define child
  Report -> (<-address (report-check Report) 1))

(define status
  Report -> (<-address (report-check Report) 2))

(define input-count
  Report -> (<-address (report-check Report) 3))

(define output-count
  Report -> (<-address (report-check Report) 4))

(define error-count
  Report -> (<-address (report-check Report) 5))

(define output-bytes
  Report -> (<-address (report-check Report) 6))

(define error-bytes
  Report -> (<-address (report-check Report) 7))

(define success?
  Report -> (= (status Report) [exited 0]))

\\ Pipelines connect child handles directly: intermediate stdout never enters a Shen buffer.
(define commands
  [] _ -> (error "process: pipeline requires 1..32 commands")
  Commands Count -> (commands-rest Commands Count))

(define commands-rest
  [] _ -> true
  [[Program Args] | Rest] Count ->
    (do (if (< Count 32) true (error "process: pipeline exceeds 32 commands"))
        (text Program false)
        (strings Args 1 8388608)
        (commands-rest Rest (+ Count 1)))
  _ _ -> (error "process: pipeline commands must be [Program Args] pairs"))

(define pipeline-start
  [] _ _ _ _ Registry -> [ok (reverse (<-address Registry 0))]
  [[Program Args] | Rest] Config Home Env Previous Registry ->
    (let _ (if (= Previous []) true
               (address-> (<-address Config 3) 0
                 (io.record [6 (<-address (stdout Previous) 12)])))
         Result (spawn-with Program Args Config Home Env
                  (/. Raw
                    (let Child (child-new Program (<-address Config 4) Raw)
                         Node [Child | (<-address Registry 0)]
                         _ (address-> Registry 1 Node)
                      [ok Child])))
      (pipeline-started Result Rest Config Home Env Previous Registry)))

(define pipeline-started
  [ok Child] Rest Config Home Env Previous Registry ->
    (let _ (address-> Registry 0 (<-address Registry 1))
         _ (address-> Registry 1 [])
         Closed (if (= Previous []) [ok] (io.close (stdout Previous)))
      (if (= Closed [ok])
          (pipeline-start Rest Config Home Env Child Registry)
          [error (hd (tl Closed)) (reverse (<-address Registry 0))]))
  [error Error] _ _ _ _ _ Registry ->
    (do (address-> Registry 1 []) [error Error (reverse (<-address Registry 0))]))

(define abort-reports
  [] -> []
  [Child | Rest] ->
    [(io.record [report Child (<-address Child 7) 0 0 0
                 (buffer.new 0) (buffer.new 0) (buffer.new 0) false false])
     | (abort-reports Rest)])

(define abort
  [] Error _ -> [error Error []]
  Children Error Config ->
    (let State (io.record [false [] [] [] Children [] [] true Config])
         _ (busy-children Children true)
         Result (cleanup-error State Error)
         _ (busy-children Children false)
         Closed (close-finished Children [ok])
         Final (io.finish Result Closed)
      [error (hd (tl Final)) (abort-reports Children)]))

(define owned-exchange
  Children Source OutSink ErrSink Config Budget ->
    (trap-error (exchange Children Source OutSink ErrSink Config Budget true)
      (/. X (abort Children
              (error-at shen "process setup" (error-to-string X)) Config))))

(define pipeline
  Commands Input Options ->
    (let _ (commands Commands 0)
         Config (options Options true)
         _ (capture-limits Config)
         Source (view-source Input)
         Budget (clock.deadline (<-address Config 6))
         Home (value *home-directory*)
      (io.let-ok _ (ready)
                 Env (environment Config)
        (build-pipeline Commands Config Home Env Source [] [] Budget))))

(define pipeline-to
  Commands Source OutSink ErrSink Options ->
    (let _ (commands Commands 0)
         _ (stream-arguments Source OutSink ErrSink)
         Config (options Options true)
         Budget (clock.deadline (<-address Config 6))
         Home (value *home-directory*)
      (io.let-ok _ (ready)
                 Env (environment Config)
        (build-pipeline Commands Config Home Env Source OutSink ErrSink Budget))))

(define build-pipeline
  Commands Config Home Env Source OutSink ErrSink Budget ->
    (let Registry (io.record [[] []])
      (trap-error
        (let Started (pipeline-start Commands Config Home Env [] Registry)
          (pipeline-exchange Started Source OutSink ErrSink Config Budget))
        (/. X (abort (reverse (<-address Registry 0))
                (error-at shen "pipeline setup" (error-to-string X)) Config)))))

(define pipeline-exchange
  [ok Children] Source OutSink ErrSink Config Budget ->
    (owned-exchange Children Source OutSink ErrSink Config Budget)
  [error Error Children] _ _ _ Config _ -> (abort Children Error Config))

(define capture-limits
  Config ->
    (do (process.limit (<-address Config 8) 268435456 false)
        (process.limit (<-address Config 9) 268435456 false)))

(define io-arguments
  Source OutSink ErrSink ->
    (do (io.check Source read [])
        (if (= OutSink []) true (io.check OutSink write []))
        (if (= ErrSink []) true (io.check ErrSink write []))
        (if (or (shen-jit.same? Source OutSink) (shen-jit.same? Source ErrSink))
            (error "process: input source and output sinks must differ") true)))

(define communication-options
  Options ->
    (do (only-communication Options)
        (options Options true)))

(define only-communication
  [] -> true
  [[Name _] | Rest] ->
    (if (element? Name [timeout cleanup-timeout stdout-limit stderr-limit chunk-size cancel terminate-grace])
        (only-communication Rest)
        (error "process: option ~A cannot be changed after spawning" Name))
  _ -> (error "process: options must be [Name Value] pairs"))

(datatype process-commands
  Program : string; Args : (list string);
  ============================
  [Program Args] : command;)

(declare process.communicate
  [child --> [buffer.view --> [[list option] --> [result report]]]])
(declare communicate-to
  [child --> [io.endpoint --> [io.endpoint --> [io.endpoint -->
    [[list option] --> [result report]]]]]])
(declare run
  [string --> [[list string] --> [buffer.view -->
    [[list option] --> [result report]]]]])
(declare run-to
  [string --> [[list string] --> [io.endpoint --> [io.endpoint --> [io.endpoint -->
    [[list option] --> [result report]]]]]]])
(declare pipeline
  [[list command] --> [buffer.view -->
    [[list option] --> [result [list report]]]]])
(declare pipeline-to
  [[list command] --> [io.endpoint --> [io.endpoint --> [io.endpoint -->
    [[list option] --> [result [list report]]]]]]])
(declare child [report --> child])
(declare status [report --> status])
(declare input-count [report --> number])
(declare output-count [report --> number])
(declare error-count [report --> number])
(declare output-bytes [report --> buffer.view])
(declare error-bytes [report --> buffer.view])
(declare success? [report --> boolean])

(define stream-arguments
  Source OutSink ErrSink ->
    (do (io.check OutSink write [])
        (io.check ErrSink write [])
        (io-arguments Source OutSink ErrSink)))

(define feed-pending
  Feed ->
    (buffer.wrap (buffer.bytes
      (buffer.slice (<-address Feed 1) (<-address Feed 2) (- (<-address Feed 3) (<-address Feed 2))))))

(define pending-input
  Report -> (<-address (report-check Report) 8))

(define input-read-count
  Report -> (+ (input-count Report) (buffer.length (pending-input Report))))

(declare pending-input [report --> buffer.view])
(declare input-read-count [report --> number])

(define output-observed?
  Report -> (<-address (report-check Report) 9))

(define error-observed?
  Report -> (<-address (report-check Report) 10))

(declare output-observed? [report --> boolean])
(declare error-observed? [report --> boolean])

)
