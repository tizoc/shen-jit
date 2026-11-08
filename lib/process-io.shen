\\ Concurrent subprocess communication, driven in Shen over nonblocking process pipes.
\\ Load process.shen first. No worker threads, native callbacks or unbounded handoff queues.

(define process.view-read
  View Position Bytes ->
    (let At (<-address Position 0)
         Left (- (buffer.length View) At)
         N (io.min Left (shen-jit.bytes-length Bytes))
      (if (= N 0)
          [eof]
          (do (shen-jit.copy-bytes Bytes 0 (buffer.owner View) (+ (buffer.offset View) At) N)
              (address-> Position 0 (+ At N))
              [read N]))))

(define process.view-source
  View ->
    (let _ (buffer.check View)
         Position (io.record [0])
      (io.endpoint "process input bytes" read 65536
        (/. Bytes (process.view-read View Position Bytes))
        (function io.no-write) (freeze [ok]))))

(define process.communication-pipes
  [] -> []
  [Child | Rest] ->
    (append (process.keep (/. E (and (not (= E [])) (not (= (<-address E 7) closed))))
              (map (/. I (<-address (<-address Child 3) I)) [0 1 2]))
            (process.communication-pipes Rest)))

(define process.keep
  _ [] -> []
  F [X | Rest] -> (if (F X) [X | (process.keep F Rest)] (process.keep F Rest)))

(define process.check-pipes
  [] -> true
  [E | Rest] ->
    (do (io.check E (<-address E 2) [])
        (process.check-pipes Rest)))

(define process.lock-pipes
  [] Flag -> true
  [E | Rest] Flag ->
    (do (address-> E 11 Flag) (process.lock-pipes Rest Flag)))

(define process.busy-children
  [] Flag -> true
  [Child | Rest] Flag ->
    (do (address-> Child 6 Flag) (process.busy-children Rest Flag)))

(define process.close-active
  E ->
    (if (= (<-address E 7) closed)
        (<-address E 8)
        (do (address-> E 11 false) (io.close E))))

(define process.close-active-pipes
  [] Result -> Result
  [E | Rest] Result ->
    (process.close-active-pipes Rest (process.finish-unit Result (process.close-active E))))

\\ Each output owns a bounded collector, or borrows an independent I/O sink.
\\ endpoint, sink, limit, count, reversed chunks, eof, child, stream number.
(define process.output
  Child Index Sink Limit ->
    (let E (<-address (<-address Child 3) Index)
      (if (or (= E []) (= (<-address E 7) closed))
          []
          (io.record [E Sink Limit 0 [] false Child Index]))))

(define process.outputs
  Children OutSink ErrSink Config ->
    (process.outputs-loop Children OutSink ErrSink Config []))

(define process.outputs-loop
  [] _ _ _ Acc -> (reverse Acc)
  [Child | Rest] OutSink ErrSink Config Acc ->
    (let Err (process.output Child 2 ErrSink (<-address Config 9))
         Out (process.output Child 1 OutSink (<-address Config 8))
         Next (if (= Err []) Acc [Err | Acc])
         Next (if (= Out []) Next [Out | Next])
      (process.outputs-loop Rest OutSink ErrSink Config Next)))

(define process.error-at
  Domain Resource Message -> (io.native-error communicate Domain 0 Resource Message))

(define process.check-cancel
  State ->
    (cond ((thaw (<-address (<-address State 8) 11))
            [error (process.error-at cancelled "process" "process operation cancelled")])
          ((deadline.expired? (<-address State 1))
            [error (process.error-at timeout "process" "process deadline expired")])
          (true [ok])))

(define process.feed
  State ->
    (let Feed (<-address State 5)
         E (<-address (<-address (hd (<-address State 4)) 3) 0)
      (cond ((or (= E []) (= (<-address E 7) closed)) [ok])
            ((< (<-address Feed 2) (<-address Feed 3)) (process.feed-write State E Feed))
            ((<-address Feed 4)
              (do (address-> State 0 true) (process.close-active E)))
            (true
              (process.feed-read State E Feed
                (io.read-some (<-address Feed 0) (<-address Feed 1) []))))))

(define process.feed-read
  State E Feed [read N] ->
    (do (address-> Feed 2 0)
        (address-> Feed 3 N)
        (process.feed-write State E Feed))
  State E Feed [eof] ->
    (do (address-> Feed 4 true)
        (address-> State 0 true)
        (process.close-active E))
  _ _ _ [error Error] -> [error Error])

(define process.feed-write
  State E Feed ->
    (let At (<-address Feed 2)
         View (buffer.slice (<-address Feed 1) At (- (<-address Feed 3) At))
         Bytes (buffer.bytes View)
      (io.let-ok N (process.native write "process stdin"
                     (freeze (process.c-write (<-address E 12) Bytes)))
        (do (if (> N 0)
                (do (address-> Feed 2 (+ At N))
                    (address-> Feed 5 (+ (<-address Feed 5) N))
                    (address-> State 0 true)) true)
            [ok]))))

(define process.capture-output
  Output View ->
    (let N (buffer.length View)
         Owned (buffer.wrap (buffer.bytes View))
         _ (address-> Output 4 [Owned | (<-address Output 4)])
         _ (address-> Output 3 (+ (<-address Output 3) N))
      [ok]))

(define process.sink-output
  _ _ End End -> [ok]
  Output View At End ->
    (let Result (io.write-some (<-address Output 1) (buffer.slice View At (- End At)) [])
      (process.sink-step Output View At End Result)))

(define process.sink-step
  Output View At End [written N] ->
    (do (address-> Output 3 (+ (<-address Output 3) N))
        (process.sink-output Output View (+ At N) End))
  Output _ _ _ [error Error] -> [error (io.progress Error (<-address Output 3))])

(define process.deliver-output
  _ _ 0 -> [ok]
  Output Chunk N ->
    (let View (buffer.slice Chunk 0 N)
      (if (= (<-address Output 1) [])
          (process.capture-output Output View)
          (process.sink-output Output View 0 N))))

(define process.read-output
  State Output Chunk ->
    (if (<-address Output 5)
        [ok]
        (let E (<-address Output 0)
          (io.let-ok N (process.native read "process output"
                         (freeze (process.c-read (<-address E 12) (buffer.owner Chunk))))
            (cond ((< N 0) [ok])
                  ((= N 0)
                    (do (address-> State 0 true)
                        (address-> Output 5 true)
                        (process.close-active E)))
                  (true
                    (let Left (- (<-address Output 2) (<-address Output 3))
                         Keep (io.min Left N)
                         _ (address-> State 0 true)
                      (io.let-ok _ (process.deliver-output Output Chunk Keep)
                        (if (> N Left)
                            [error (io.progress
                                     (process.error-at limit
                                       (if (= (<-address Output 7) 1) "stdout" "stderr")
                                       "process output limit exceeded")
                                     (<-address Output 3))]
                            [ok])))))))))

(define process.read-outputs
  _ [] _ -> [ok]
  State [Output | Rest] Chunk ->
    (io.let-ok _ (process.read-output State Output Chunk)
      (process.read-outputs State Rest Chunk)))

(define process.poll-children
  [] -> [ok]
  [Child | Rest] ->
    (io.let-ok _ (if (<-address Child 4) [ok done] (process.poll Child))
      (process.poll-children Rest)))

(define process.children-done?
  [] -> true
  [Child | Rest] ->
    (and (not (= (<-address Child 7) [running])) (process.children-done? Rest)))

(define process.outputs-done?
  [] -> true
  [Output | Rest] -> (and (<-address Output 5) (process.outputs-done? Rest)))

(define process.input-done?
  State ->
    (let E (<-address (<-address (hd (<-address State 4)) 3) 0)
      (or (= E []) (= (<-address E 7) closed))))

(define process.wait-pointers
  State ->
    (let Feed (<-address State 5)
         Input (<-address (<-address (hd (<-address State 4)) 3) 0)
         Output (map (/. O (<-address (<-address O 0) 12))
                     (process.keep (/. O (not (<-address O 5))) (<-address State 6)))
      (if (and (not (= Input [])) (not (= (<-address Input 7) closed))
               (< (<-address Feed 2) (<-address Feed 3)))
          [(<-address Input 12) | Output]
          Output)))

(define process.pump
  State Chunk ->
    (io.let-ok _ (process.check-cancel State)
               _ (do (address-> State 0 false) (process.feed State))
               _ (process.read-outputs State (<-address State 6) Chunk)
               _ (process.poll-children (<-address State 4))
      (if (and (process.input-done? State) (process.outputs-done? (<-address State 6))
               (process.children-done? (<-address State 4)))
          [ok]
          (do (if (<-address State 0) true
                  (process.c-pause (process.wait-pointers State)
                    (deadline.slice (<-address State 1) 20)))
              (process.pump State Chunk)))))

(define process.signal-children
  [] _ Result -> Result
  [Child | Rest] Force Result ->
    (process.signal-children Rest Force
      (process.finish-unit Result (if (<-address Child 4) [ok] (process.signal Child Force)))))

\\ Read the budget once per round: a second reading could find it expired just after the first
\\ did not, and give up without forcing.
(define process.cleanup-wait
  State Budget Grace Forced Result ->
    (let Children (<-address State 4)
         Polled (process.poll-children Children)
         Result (process.finish-unit Result Polled)
         Late (deadline.expired? Budget)
      (cond ((and (process.children-done? Children)
                  (or Forced (not (process.groups? Children)))) Result)
            ((and (not Forced) (or Late (deadline.expired? Grace)))
              (process.cleanup-wait State Budget Grace true
                (process.signal-children Children true Result)))
            (Late
              (process.finish-unit Result
                [error (process.error-at timeout "process cleanup"
                         "cleanup deadline expired; retain the report's child handle")]))
            (true (do (process.c-pause [] (deadline.slice Budget 20))
                      (process.cleanup-wait State Budget Grace Forced Result))))))

(define process.groups?
  [] -> false
  [Child | Rest] -> (or (and (not (<-address Child 4)) (<-address Child 8))
                       (process.groups? Rest)))

(define process.cleanup-error
  State Error ->
    (let Config (<-address State 8)
         Budget (clock.deadline (<-address Config 7))
         Grace (deadline.within Budget (<-address Config 12))
         Signals (process.signal-children (<-address State 4) false [ok])
         Pipes (process.close-active-pipes (process.communication-pipes (<-address State 4)) Signals)
      (io.finish [error Error] (process.cleanup-wait State Budget Grace false Pipes))))

(define process.close-finished
  [] Result -> Result
  [Child | Rest] Result ->
    (process.close-finished Rest
      (if (= (<-address Child 7) [running])
          Result
          (process.finish-unit Result (process.close Child)))))

(define process.output-for
  [] _ _ -> []
  [Output | Rest] Child Index ->
    (if (and (shen-jit.same? (<-address Output 6) Child) (= (<-address Output 7) Index))
        Output
        (process.output-for Rest Child Index)))

(define process.collected-count
  [] -> 0
  Output -> (<-address Output 3))

(define process.collected-bytes
  [] -> (buffer.new 0)
  Output ->
    (if (= (<-address Output 1) [])
        (io.join (<-address Output 3) (reverse (<-address Output 4)))
        (buffer.new 0)))

(define process.reports
  [] _ _ -> []
  [Child | Rest] State First ->
    (let Out (process.output-for (<-address State 6) Child 1)
         Err (process.output-for (<-address State 6) Child 2)
         Report (io.record [process.report Child (<-address Child 7)
                            (if First (<-address (<-address State 5) 5) 0)
                            (process.collected-count Out) (process.collected-count Err)
                            (process.collected-bytes Out) (process.collected-bytes Err)
                            (if First (process.feed-pending (<-address State 5)) (buffer.new 0))
                            (not (= Out [])) (not (= Err []))])
      [Report | (process.reports Rest State false)]))

(define process.exchange
  Children Source OutSink ErrSink Config Budget Own ->
    (let Pipes (process.communication-pipes Children)
         _ (process.check-children Children)
         Input (<-address (<-address (hd Children) 3) 0)
         _ (if (and (not (= Input [])) (= (<-address Input 7) open))
               true (error "process: communication requires an open stdin pipe"))
         _ (process.check-pipes Pipes)
         _ (io.check Source read [])
         _ (if (= OutSink []) true (io.check OutSink write []))
         _ (if (= ErrSink []) true (io.check ErrSink write []))
         _ (if (or (shen-jit.same? Source OutSink) (shen-jit.same? Source ErrSink))
               (error "process: input source and output sinks must differ") true)
         Feed (io.record [Source (buffer.new (<-address Config 10)) 0 0 false 0])
         Outputs (process.outputs Children OutSink ErrSink Config)
         Chunk (buffer.new (<-address Config 10))
         State (io.record [false Budget [] [] Children Feed Outputs Own Config])
         _ (process.lock-pipes Pipes true)
         _ (process.busy-children Children true)
         Result (trap-error (process.pump State Chunk)
                   (/. X [error (process.error-at shen "process communication" (error-to-string X))]))
         Result (if (= Result [ok])
                    (process.close-active-pipes Pipes [ok])
                    (process.cleanup-error State (hd (tl Result))))
         _ (process.lock-pipes Pipes false)
         _ (process.busy-children Children false)
         Closed (if Own (process.close-finished Children [ok]) [ok])
         Final (process.finish-unit Result Closed)
         Reports (process.reports Children State true)
      (if (= Final [ok]) [ok Reports] [error (hd (tl Final)) Reports])))

(define process.check-children
  [] -> true
  [Child | Rest] ->
    (do (process.live Child)
        (if (<-address Child 6) (error "process: communication is already in progress") true)
        (process.check-children Rest)))

(define process.single-result
  [ok [Report]] -> [ok Report]
  [error Error [Report]] -> [error Error Report]
  Other -> Other)

(define process.communicate
  Child Input Options ->
    (let Config (process.communication-options Options)
         _ (process.capture-limits Config)
         Source (process.view-source Input)
         Budget (clock.deadline (<-address Config 6))
      (process.single-result (process.exchange [Child] Source [] [] Config Budget false))))

(define process.communicate-to
  Child Source OutSink ErrSink Options ->
    (let _ (process.stream-arguments Source OutSink ErrSink)
         Config (process.communication-options Options)
         Budget (clock.deadline (<-address Config 6))
      (process.single-result (process.exchange [Child] Source OutSink ErrSink Config Budget false))))

(define process.run
  Program Args Input Options ->
    (let Config (process.options Options true)
         _ (process.capture-limits Config)
         Source (process.view-source Input)
         Budget (clock.deadline (<-address Config 6))
      (io.let-ok Child (process.spawn-config Program Args Config)
        (process.single-result (process.owned-exchange [Child] Source [] [] Config Budget)))))

(define process.run-to
  Program Args Source OutSink ErrSink Options ->
    (let Config (process.options Options true)
         _ (process.stream-arguments Source OutSink ErrSink)
         Budget (clock.deadline (<-address Config 6))
      (io.let-ok Child (process.spawn-config Program Args Config)
        (process.single-result (process.owned-exchange [Child] Source OutSink ErrSink Config Budget)))))

(define process.report-check
  Report -> (if (io.tag? Report process.report) Report (error "process: not an execution report")))

(define process.child
  Report -> (<-address (process.report-check Report) 1))

(define process.status
  Report -> (<-address (process.report-check Report) 2))

(define process.input-count
  Report -> (<-address (process.report-check Report) 3))

(define process.output-count
  Report -> (<-address (process.report-check Report) 4))

(define process.error-count
  Report -> (<-address (process.report-check Report) 5))

(define process.output-bytes
  Report -> (<-address (process.report-check Report) 6))

(define process.error-bytes
  Report -> (<-address (process.report-check Report) 7))

(define process.success?
  Report -> (= (process.status Report) [exited 0]))

\\ Pipelines connect child handles directly: intermediate stdout never enters a Shen buffer.
(define process.commands
  [] _ -> (error "process: pipeline requires 1..32 commands")
  Commands Count -> (process.commands-rest Commands Count))

(define process.commands-rest
  [] _ -> true
  [[Program Args] | Rest] Count ->
    (do (if (< Count 32) true (error "process: pipeline exceeds 32 commands"))
        (process.text Program false)
        (process.strings Args 1 8388608)
        (process.commands-rest Rest (+ Count 1)))
  _ _ -> (error "process: pipeline commands must be [Program Args] pairs"))

(define process.pipeline-start
  [] _ _ _ _ Registry -> [ok (reverse (<-address Registry 0))]
  [[Program Args] | Rest] Config Home Env Previous Registry ->
    (let _ (if (= Previous []) true
               (address-> (<-address Config 3) 0
                 (io.record [6 (<-address (process.stdout Previous) 12)])))
         Result (process.spawn-with Program Args Config Home Env
                  (/. Raw
                    (let Child (process.child-new Program (<-address Config 4) Raw)
                         Node [Child | (<-address Registry 0)]
                         _ (address-> Registry 1 Node)
                      [ok Child])))
      (process.pipeline-started Result Rest Config Home Env Previous Registry)))

(define process.pipeline-started
  [ok Child] Rest Config Home Env Previous Registry ->
    (let _ (address-> Registry 0 (<-address Registry 1))
         _ (address-> Registry 1 [])
         Closed (if (= Previous []) [ok] (io.close (process.stdout Previous)))
      (if (= Closed [ok])
          (process.pipeline-start Rest Config Home Env Child Registry)
          [error (hd (tl Closed)) (reverse (<-address Registry 0))]))
  [error Error] _ _ _ _ _ Registry ->
    (do (address-> Registry 1 []) [error Error (reverse (<-address Registry 0))]))

(define process.abort-reports
  [] -> []
  [Child | Rest] ->
    [(io.record [process.report Child (<-address Child 7) 0 0 0
                 (buffer.new 0) (buffer.new 0) (buffer.new 0) false false])
     | (process.abort-reports Rest)])

(define process.abort
  [] Error _ -> [error Error []]
  Children Error Config ->
    (let State (io.record [false [] [] [] Children [] [] true Config])
         _ (process.busy-children Children true)
         Result (process.cleanup-error State Error)
         _ (process.busy-children Children false)
         Closed (process.close-finished Children [ok])
         Final (io.finish Result Closed)
      [error (hd (tl Final)) (process.abort-reports Children)]))

(define process.owned-exchange
  Children Source OutSink ErrSink Config Budget ->
    (trap-error (process.exchange Children Source OutSink ErrSink Config Budget true)
      (/. X (process.abort Children
              (process.error-at shen "process setup" (error-to-string X)) Config))))

(define process.pipeline
  Commands Input Options ->
    (let _ (process.commands Commands 0)
         Config (process.options Options true)
         _ (process.capture-limits Config)
         Source (process.view-source Input)
         Budget (clock.deadline (<-address Config 6))
         Home (value *home-directory*)
      (io.let-ok _ (process.ready)
                 Env (process.environment Config)
        (process.build-pipeline Commands Config Home Env Source [] [] Budget))))

(define process.pipeline-to
  Commands Source OutSink ErrSink Options ->
    (let _ (process.commands Commands 0)
         _ (process.stream-arguments Source OutSink ErrSink)
         Config (process.options Options true)
         Budget (clock.deadline (<-address Config 6))
         Home (value *home-directory*)
      (io.let-ok _ (process.ready)
                 Env (process.environment Config)
        (process.build-pipeline Commands Config Home Env Source OutSink ErrSink Budget))))

(define process.build-pipeline
  Commands Config Home Env Source OutSink ErrSink Budget ->
    (let Registry (io.record [[] []])
      (trap-error
        (let Started (process.pipeline-start Commands Config Home Env [] Registry)
          (process.pipeline-exchange Started Source OutSink ErrSink Config Budget))
        (/. X (process.abort (reverse (<-address Registry 0))
                (process.error-at shen "pipeline setup" (error-to-string X)) Config)))))

(define process.pipeline-exchange
  [ok Children] Source OutSink ErrSink Config Budget ->
    (process.owned-exchange Children Source OutSink ErrSink Config Budget)
  [error Error Children] _ _ _ Config _ -> (process.abort Children Error Config))

(define process.capture-limits
  Config ->
    (do (process.limit (<-address Config 8) 268435456 false)
        (process.limit (<-address Config 9) 268435456 false)))

(define process.io-arguments
  Source OutSink ErrSink ->
    (do (io.check Source read [])
        (if (= OutSink []) true (io.check OutSink write []))
        (if (= ErrSink []) true (io.check ErrSink write []))
        (if (or (shen-jit.same? Source OutSink) (shen-jit.same? Source ErrSink))
            (error "process: input source and output sinks must differ") true)))

(define process.communication-options
  Options ->
    (do (process.only-communication Options)
        (process.options Options true)))

(define process.only-communication
  [] -> true
  [[Name _] | Rest] ->
    (if (element? Name [timeout cleanup-timeout stdout-limit stderr-limit chunk-size cancel terminate-grace])
        (process.only-communication Rest)
        (error "process: option ~A cannot be changed after spawning" Name))
  _ -> (error "process: options must be [Name Value] pairs"))

(datatype process-commands
  Program : string; Args : (list string);
  ============================
  [Program Args] : process.command;)

(declare process.communicate
  [process.child --> [buffer.view --> [[list process.option] --> [process.result process.report]]]])
(declare process.communicate-to
  [process.child --> [io.endpoint --> [io.endpoint --> [io.endpoint -->
    [[list process.option] --> [process.result process.report]]]]]])
(declare process.run
  [string --> [[list string] --> [buffer.view -->
    [[list process.option] --> [process.result process.report]]]]])
(declare process.run-to
  [string --> [[list string] --> [io.endpoint --> [io.endpoint --> [io.endpoint -->
    [[list process.option] --> [process.result process.report]]]]]]])
(declare process.pipeline
  [[list process.command] --> [buffer.view -->
    [[list process.option] --> [process.result [list process.report]]]]])
(declare process.pipeline-to
  [[list process.command] --> [io.endpoint --> [io.endpoint --> [io.endpoint -->
    [[list process.option] --> [process.result [list process.report]]]]]]])
(declare process.child [process.report --> process.child])
(declare process.status [process.report --> process.status])
(declare process.input-count [process.report --> number])
(declare process.output-count [process.report --> number])
(declare process.error-count [process.report --> number])
(declare process.output-bytes [process.report --> buffer.view])
(declare process.error-bytes [process.report --> buffer.view])
(declare process.success? [process.report --> boolean])

(define process.stream-arguments
  Source OutSink ErrSink ->
    (do (io.check OutSink write [])
        (io.check ErrSink write [])
        (process.io-arguments Source OutSink ErrSink)))

(define process.feed-pending
  Feed ->
    (buffer.wrap (buffer.bytes
      (buffer.slice (<-address Feed 1) (<-address Feed 2) (- (<-address Feed 3) (<-address Feed 2))))))

(define process.pending-input
  Report -> (<-address (process.report-check Report) 8))

(define process.input-read-count
  Report -> (+ (process.input-count Report) (buffer.length (process.pending-input Report))))

(declare process.pending-input [process.report --> buffer.view])
(declare process.input-read-count [process.report --> number])

(define process.output-observed?
  Report -> (<-address (process.report-check Report) 9))

(define process.error-observed?
  Report -> (<-address (process.report-check Report) 10))

(declare process.output-observed? [process.report --> boolean])
(declare process.error-observed? [process.report --> boolean])
