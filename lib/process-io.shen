\\ Concurrent subprocess communication, driven in Shen over nonblocking process pipes.
\\ Load process.shen first. No worker threads, native callbacks or unbounded handoff queues.

(shen.x.namespace process
  (use buffer)
  (use clock)
  (use deadline)
  (use io)
  (use shen-jit)
  (import struct defstruct)
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
    (append (keep (/. E (and (not (= E [])) (not (= (io.endpoint.state E) closed))))
              (map (/. I (<-address (subprocess.pipes Child) I)) [0 1 2]))
            (communication-pipes Rest)))

(define keep
  _ [] -> []
  F [X | Rest] -> (if (F X) [X | (keep F Rest)] (keep F Rest)))

(define check-pipes
  [] -> true
  [E | Rest] ->
    (do (io.check E (io.endpoint.mode E) [])
        (check-pipes Rest)))

(define lock-pipes
  [] Flag -> true
  [E | Rest] Flag ->
    (do (io.endpoint.busy-> E Flag) (lock-pipes Rest Flag)))

(define busy-children
  [] Flag -> true
  [Child | Rest] Flag ->
    (do (subprocess.busy-> Child Flag) (busy-children Rest Flag)))

(define close-active
  E ->
    (if (= (io.endpoint.state E) closed)
        (io.endpoint.close-result E)
        (do (io.endpoint.busy-> E false) (io.close E))))

(define close-active-pipes
  [] Result -> Result
  [E | Rest] Result ->
    (close-active-pipes Rest (finish-unit Result (close-active E))))

\\ Each output owns a bounded collector, or borrows an independent I/O sink ([] when it collects).
\\ Chunks are the collected views, latest first; index is the child's stream number, 1 or 2.
(define stream-name
  1 -> "stdout"
  _ -> "stderr")

(define show-collector
  O -> (make-string "#<process ~A ~A bytes>" (stream-name (collector.index O))
                    (collector.count O)))

(defstruct collector
  (printer show-collector)
  endpoint
  sink
  limit
  (mutable count)
  (mutable chunks)
  (mutable eof)
  child
  index)

(define output
  Child Index Sink Limit ->
    (let E (<-address (subprocess.pipes Child) Index)
      (if (or (= E []) (= (io.endpoint.state E) closed))
          []
          (collector.make E Sink Limit 0 [] false Child Index))))

(define outputs
  Children OutSink ErrSink Config ->
    (outputs-loop Children OutSink ErrSink Config []))

(define outputs-loop
  [] _ _ _ Acc -> (reverse Acc)
  [Child | Rest] OutSink ErrSink Config Acc ->
    (let Err (output Child 2 ErrSink (config.stderr-limit Config))
         Out (output Child 1 OutSink (config.stdout-limit Config))
         Next (if (= Err []) Acc [Err | Acc])
         Next (if (= Out []) Next [Out | Next])
      (outputs-loop Rest OutSink ErrSink Config Next)))

(define error-at
  Domain Resource Message -> (io.native-error communicate Domain 0 Resource Message))

\\ Input: its source, a staging buffer, the unwritten part of it from at to end, whether the
\\ source is exhausted, and the bytes written to the child.
(define show-feed
  F -> (make-string "#<process input ~A written>" (feed-state.written F)))

(defstruct feed-state
  (printer show-feed)
  source
  buffer
  (mutable at)
  (mutable end)
  (mutable eof)
  (mutable written))

\\ One exchange: whether the last round made progress, its budget, the children (the first is
\\ fed), the input feed, the outputs and the options.
(define show-session
  S -> (make-string "#<process session ~A children>" (length (session.children S))))

(defstruct session
  (printer show-session)
  (mutable progress)
  budget
  children
  feed
  outputs
  config)

(define first-stdin
  State -> (<-address (subprocess.pipes (hd (session.children State))) 0))

(define check-cancel
  State ->
    (cond ((thaw (config.cancel (session.config State)))
            [error (error-at cancelled "process" "process operation cancelled")])
          ((deadline.expired? (session.budget State))
            [error (error-at timeout "process" "process deadline expired")])
          (true [ok])))

(define feed
  State ->
    (let Feed (session.feed State)
         E (first-stdin State)
      (cond ((or (= E []) (= (io.endpoint.state E) closed)) [ok])
            ((< (feed-state.at Feed) (feed-state.end Feed)) (feed-write State E Feed))
            ((feed-state.eof Feed)
              (do (session.progress-> State true) (close-active E)))
            (true
              (feed-read State E Feed
                (io.read-some (feed-state.source Feed) (feed-state.buffer Feed) []))))))

(define feed-read
  State E Feed [read N] ->
    (do (feed-state.at-> Feed 0)
        (feed-state.end-> Feed N)
        (feed-write State E Feed))
  State E Feed [eof] ->
    (do (feed-state.eof-> Feed true)
        (session.progress-> State true)
        (close-active E))
  _ _ _ [error Error] -> [error Error])

(define feed-write
  State E Feed ->
    (let At (feed-state.at Feed)
         View (buffer.slice (feed-state.buffer Feed) At (- (feed-state.end Feed) At))
         Bytes (buffer.bytes View)
      (io.let-ok N (native write "process stdin"
                     (freeze (c-write (io.endpoint.guard E) Bytes)))
        (do (if (> N 0)
                (do (feed-state.at-> Feed (+ At N))
                    (feed-state.written-> Feed (+ (feed-state.written Feed) N))
                    (session.progress-> State true)) true)
            [ok]))))

(define capture-output
  Output View ->
    (let N (buffer.length View)
         Owned (buffer.wrap (buffer.bytes View))
         _ (collector.chunks-> Output [Owned | (collector.chunks Output)])
         _ (collector.count-> Output (+ (collector.count Output) N))
      [ok]))

(define sink-output
  _ _ End End -> [ok]
  Output View At End ->
    (let Result (io.write-some (collector.sink Output) (buffer.slice View At (- End At)) [])
      (sink-step Output View At End Result)))

(define sink-step
  Output View At End [written N] ->
    (do (collector.count-> Output (+ (collector.count Output) N))
        (sink-output Output View (+ At N) End))
  Output _ _ _ [error Error] -> [error (io.progress Error (collector.count Output))])

(define deliver-output
  _ _ 0 -> [ok]
  Output Chunk N ->
    (let View (buffer.slice Chunk 0 N)
      (if (= (collector.sink Output) [])
          (capture-output Output View)
          (sink-output Output View 0 N))))

(define read-output
  State Output Chunk ->
    (if (collector.eof Output)
        [ok]
        (let E (collector.endpoint Output)
          (io.let-ok N (native read "process output"
                         (freeze (c-read (io.endpoint.guard E) (buffer.owner Chunk))))
            (cond ((< N 0) [ok])
                  ((= N 0)
                    (do (session.progress-> State true)
                        (collector.eof-> Output true)
                        (close-active E)))
                  (true
                    (let Left (- (collector.limit Output) (collector.count Output))
                         Keep (io.min Left N)
                         _ (session.progress-> State true)
                      (io.let-ok _ (deliver-output Output Chunk Keep)
                        (if (> N Left)
                            [error (io.progress
                                     (error-at limit
                                       (stream-name (collector.index Output))
                                       "process output limit exceeded")
                                     (collector.count Output))]
                            [ok])))))))))

(define read-outputs
  _ [] _ -> [ok]
  State [Output | Rest] Chunk ->
    (io.let-ok _ (read-output State Output Chunk)
      (read-outputs State Rest Chunk)))

(define poll-children
  [] -> [ok]
  [Child | Rest] ->
    (io.let-ok _ (if (subprocess.closed Child) [ok done] (poll Child))
      (poll-children Rest)))

(define children-done?
  [] -> true
  [Child | Rest] ->
    (and (not (= (subprocess.status Child) [running])) (children-done? Rest)))

(define outputs-done?
  [] -> true
  [Output | Rest] -> (and (collector.eof Output) (outputs-done? Rest)))

(define input-done?
  State ->
    (let E (first-stdin State)
      (or (= E []) (= (io.endpoint.state E) closed))))

(define wait-pointers
  State ->
    (let Feed (session.feed State)
         Input (first-stdin State)
         Output (map (/. O (io.endpoint.guard (collector.endpoint O)))
                     (keep (/. O (not (collector.eof O))) (session.outputs State)))
      (if (and (not (= Input [])) (not (= (io.endpoint.state Input) closed))
               (< (feed-state.at Feed) (feed-state.end Feed)))
          [(io.endpoint.guard Input) | Output]
          Output)))

(define pump
  State Chunk ->
    (io.let-ok _ (check-cancel State)
               _ (do (session.progress-> State false) (feed State))
               _ (read-outputs State (session.outputs State) Chunk)
               _ (poll-children (session.children State))
      (if (and (input-done? State) (outputs-done? (session.outputs State))
               (children-done? (session.children State)))
          [ok]
          (do (if (session.progress State) true
                  (c-pause (wait-pointers State)
                    (deadline.slice (session.budget State) 20)))
              (pump State Chunk)))))

(define signal-children
  [] _ Result -> Result
  [Child | Rest] Force Result ->
    (signal-children Rest Force
      (finish-unit Result (if (subprocess.closed Child) [ok] (signal Child Force)))))

\\ Read the budget once per round: a second reading could find it expired just after the first
\\ did not, and give up without forcing.
(define cleanup-wait
  State Budget Grace Forced Result ->
    (let Children (session.children State)
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
  [Child | Rest] -> (or (and (not (subprocess.closed Child)) (subprocess.group Child))
                       (groups? Rest)))

(define cleanup-error
  State Error ->
    (let Config (session.config State)
         Budget (clock.deadline (config.cleanup-timeout Config))
         Grace (deadline.within Budget (config.terminate-grace Config))
         Signals (signal-children (session.children State) false [ok])
         Pipes (close-active-pipes (communication-pipes (session.children State)) Signals)
      (io.finish [error Error] (cleanup-wait State Budget Grace false Pipes))))

(define close-finished
  [] Result -> Result
  [Child | Rest] Result ->
    (close-finished Rest
      (if (= (subprocess.status Child) [running])
          Result
          (finish-unit Result (close Child)))))

(define output-for
  [] _ _ -> []
  [Output | Rest] Child Index ->
    (if (and (shen-jit.same? (collector.child Output) Child) (= (collector.index Output) Index))
        Output
        (output-for Rest Child Index)))

(define collected-count
  [] -> 0
  Output -> (collector.count Output))

(define collected-bytes
  [] -> (buffer.new 0)
  Output ->
    (if (= (collector.sink Output) [])
        (io.join (collector.count Output) (reverse (collector.chunks Output)))
        (buffer.new 0)))

(define reports
  [] _ _ -> []
  [Child | Rest] State First ->
    (let Out (output-for (session.outputs State) Child 1)
         Err (output-for (session.outputs State) Child 2)
         Report (report.make Child (subprocess.status Child)
                  (if First (feed-state.written (session.feed State)) 0)
                  (collected-count Out) (collected-count Err)
                  (collected-bytes Out) (collected-bytes Err)
                  (if First (feed-pending (session.feed State)) (buffer.new 0))
                  (not (= Out [])) (not (= Err [])))
      [Report | (reports Rest State false)]))

(define exchange
  Children Source OutSink ErrSink Config Budget Own ->
    (let Pipes (communication-pipes Children)
         _ (check-children Children)
         Input (<-address (subprocess.pipes (hd Children)) 0)
         _ (if (and (not (= Input [])) (= (io.endpoint.state Input) open))
               true (error "process: communication requires an open stdin pipe"))
         _ (check-pipes Pipes)
         _ (io.check Source read [])
         _ (if (= OutSink []) true (io.check OutSink write []))
         _ (if (= ErrSink []) true (io.check ErrSink write []))
         _ (if (or (shen-jit.same? Source OutSink) (shen-jit.same? Source ErrSink))
               (error "process: input source and output sinks must differ") true)
         Feed (feed-state.make Source (buffer.new (config.chunk-size Config)) 0 0 false 0)
         Outputs (outputs Children OutSink ErrSink Config)
         Chunk (buffer.new (config.chunk-size Config))
         State (session.make false Budget Children Feed Outputs Config)
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
        (if (subprocess.busy Child) (error "process: communication is already in progress") true)
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
         Budget (clock.deadline (config.timeout Config))
      (single-result (exchange [Child] Source [] [] Config Budget false))))

(define communicate-to
  Child Source OutSink ErrSink Options ->
    (let _ (stream-arguments Source OutSink ErrSink)
         Config (communication-options Options)
         Budget (clock.deadline (config.timeout Config))
      (single-result (exchange [Child] Source OutSink ErrSink Config Budget false))))

(define run
  Program Args Input Options ->
    (let Config (options Options true)
         _ (capture-limits Config)
         Source (view-source Input)
         Budget (clock.deadline (config.timeout Config))
      (io.let-ok Child (spawn-config Program Args Config)
        (single-result (owned-exchange [Child] Source [] [] Config Budget)))))

(define run-to
  Program Args Source OutSink ErrSink Options ->
    (let Config (options Options true)
         _ (stream-arguments Source OutSink ErrSink)
         Budget (clock.deadline (config.timeout Config))
      (io.let-ok Child (spawn-config Program Args Config)
        (single-result (owned-exchange [Child] Source OutSink ErrSink Config Budget)))))

\\ An execution report. Its child handle stays valid after the report is made.
(define show-report
  R -> (make-string "#<report ~A>" (status-text (report.status R))))

(defstruct report
  (printer show-report)
  child
  status
  input-count
  output-count
  error-count
  output-bytes
  error-bytes
  pending-input
  output-observed
  error-observed)

(define report-check
  Report -> (if (report? Report) Report (error "process: not an execution report")))

(define child
  Report -> (report.child (report-check Report)))

(define status
  Report -> (report.status (report-check Report)))

(define input-count
  Report -> (report.input-count (report-check Report)))

(define output-count
  Report -> (report.output-count (report-check Report)))

(define error-count
  Report -> (report.error-count (report-check Report)))

(define output-bytes
  Report -> (report.output-bytes (report-check Report)))

(define error-bytes
  Report -> (report.error-bytes (report-check Report)))

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

\\ The children a pipeline has started, latest first, and the list including the one being
\\ spawned, which becomes the started list once its spawn succeeds.
(defstruct registry
  (mutable started)
  (mutable spawning))

(define pipeline-start
  [] _ _ _ _ Registry -> [ok (reverse (registry.started Registry))]
  [[Program Args] | Rest] Config Home Env Previous Registry ->
    (let _ (if (= Previous []) true
               (address-> (config.streams Config) 0
                 (io.record [6 (io.endpoint.guard (stdout Previous))])))
         Result (spawn-with Program Args Config Home Env
                  (/. Raw
                    (let Child (child-new Program (config.group Config) Raw)
                         Node [Child | (registry.started Registry)]
                         _ (registry.spawning-> Registry Node)
                      [ok Child])))
      (pipeline-started Result Rest Config Home Env Previous Registry)))

(define pipeline-started
  [ok Child] Rest Config Home Env Previous Registry ->
    (let _ (registry.started-> Registry (registry.spawning Registry))
         _ (registry.spawning-> Registry [])
         Closed (if (= Previous []) [ok] (io.close (stdout Previous)))
      (if (= Closed [ok])
          (pipeline-start Rest Config Home Env Child Registry)
          [error (hd (tl Closed)) (reverse (registry.started Registry))]))
  [error Error] _ _ _ _ _ Registry ->
    (do (registry.spawning-> Registry []) [error Error (reverse (registry.started Registry))]))

(define abort-reports
  [] -> []
  [Child | Rest] ->
    [(report.make Child (subprocess.status Child) 0 0 0
                  (buffer.new 0) (buffer.new 0) (buffer.new 0) false false)
     | (abort-reports Rest)])

(define abort
  [] Error _ -> [error Error []]
  Children Error Config ->
    (let State (session.make false [] Children [] [] Config)
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
         Budget (clock.deadline (config.timeout Config))
         Home (value *home-directory*)
      (io.let-ok _ (ready)
                 Env (environment Config)
        (build-pipeline Commands Config Home Env Source [] [] Budget))))

(define pipeline-to
  Commands Source OutSink ErrSink Options ->
    (let _ (commands Commands 0)
         _ (stream-arguments Source OutSink ErrSink)
         Config (options Options true)
         Budget (clock.deadline (config.timeout Config))
         Home (value *home-directory*)
      (io.let-ok _ (ready)
                 Env (environment Config)
        (build-pipeline Commands Config Home Env Source OutSink ErrSink Budget))))

(define build-pipeline
  Commands Config Home Env Source OutSink ErrSink Budget ->
    (let Registry (registry.make [] [])
      (trap-error
        (let Started (pipeline-start Commands Config Home Env [] Registry)
          (pipeline-exchange Started Source OutSink ErrSink Config Budget))
        (/. X (abort (reverse (registry.started Registry))
                (error-at shen "pipeline setup" (error-to-string X)) Config)))))

(define pipeline-exchange
  [ok Children] Source OutSink ErrSink Config Budget ->
    (owned-exchange Children Source OutSink ErrSink Config Budget)
  [error Error Children] _ _ _ Config _ -> (abort Children Error Config))

(define capture-limits
  Config ->
    (do (process.limit (config.stdout-limit Config) 268435456 false)
        (process.limit (config.stderr-limit Config) 268435456 false)))

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
      (buffer.slice (feed-state.buffer Feed) (feed-state.at Feed)
                    (- (feed-state.end Feed) (feed-state.at Feed))))))

(define pending-input
  Report -> (report.pending-input (report-check Report)))

(define input-read-count
  Report -> (+ (input-count Report) (buffer.length (pending-input Report))))

(declare pending-input [report --> buffer.view])
(declare input-read-count [report --> number])

(define output-observed?
  Report -> (report.output-observed (report-check Report)))

(define error-observed?
  Report -> (report.error-observed (report-check Report)))

(declare output-observed? [report --> boolean])
(declare error-observed? [report --> boolean])

)
