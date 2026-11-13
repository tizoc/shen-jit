\\ Batch queries: the matched call graph as integer adjacency, selectors checked against it, and
\\ each query's BFS, in turn or in isolates that read the graph shared (lib/parallel.shen).
(define source-deps.ids
  [] _ _ _ -> true
  [[Fn] | Rest] At Names Ids ->
    (do (address-> Names (+ At 1) Fn) (shen.dict-> Ids Fn At)
        (source-deps.ids Rest (+ At 1) Names Ids)))

(define source-deps.edge-ids
  [] Bytes _ _ -> Bytes
  [[From To] | Rest] Bytes At Ids ->
    (do (shen-jit.u32! Bytes At (shen.<-dict Ids From))
        (shen-jit.u32! Bytes (+ At 4) (shen.<-dict Ids To))
        (source-deps.edge-ids Rest Bytes (+ At 8) Ids)))

(define source-deps.export
  Db ->
    (let Functions (datalog.sorted Db function) N (length Functions)
         Names (vector N) Ids (shen.dict (if (< N 16) 16 N))
         _ (source-deps.ids Functions 0 Names Ids)
         Edges (datalog.tuples Db edge)
         Bytes (source-deps.edge-ids Edges (shen-jit.bytes (* 8 (length Edges))) 0 Ids)
      (io.record [source-deps.graph-state (sdg.build N Bytes) Names Ids])))

(define source-deps.query-record
  [object | Members] ->
    (let _ (if (element? (length Members) [3 4]) true (error "expected 3 or 4 query fields"))
         _ (if (source-deps.allowed-keys Members ["mode" "file" "name" "definition_byte"])
               true (error "unsupported query field"))
         Mode (source-deps.member Members "mode")
         M (cond ((= Mode "reach") reach) ((= Mode "impact") impact)
                 (true (error "expected reach or impact")))
         File (source-deps.text (source-deps.member Members "file") false)
         Name (source-deps.text (source-deps.member Members "name") false)
      (if (= (length Members) 3) [M File Name]
          [M File Name (source-deps.uint (source-deps.member Members "definition_byte"))]))
  _ -> (error "expected a query object"))

(define source-deps.query-lines
  _ End End _ Reversed -> (reverse Reversed)
  Bytes At End Count Reversed ->
    (let LF (source-deps.find-lf (buffer.owner Bytes) At End)
         View (buffer.slice Bytes At (- LF At))
      (if (source-deps.blank? View 0 (buffer.length View))
          (source-deps.query-lines Bytes (io.min End (+ LF 1)) End Count Reversed)
          (if (or (>= Count 4096) (> (buffer.length View) 65536))
              (error "batch query limit exceeded")
              (source-deps.query-lines Bytes (io.min End (+ LF 1)) End (+ Count 1)
                [(source-deps.query-record (json.parse (buffer.string View) [])) | Reversed])))))

(define source-deps.read-queries
  Input ->
    (io.let-ok Bytes (io.with-input-file Input
                      (/. In (io.read-all (io.reader In [[chunk-size 16384]]) 1048576)))
      (trap-error [ok (source-deps.query-lines Bytes 0 (buffer.length Bytes) 0 [])]
        (/. E [error (io.native-error read-queries format 0 Input (error-to-string E))]))))

(define source-deps.resolve-queries
  _ _ [] -> [ok []]
  Db Export [Query | Rest] ->
    (io.let-ok Selected (source-deps.select Db Query)
      (io.let-ok More (source-deps.resolve-queries Db Export Rest)
        [ok [[(if (= (hd Selected) reach) 0 1)
              (shen.<-dict (<-address Export 3) (hd (tl Selected)))] | More]])))

(define source-deps.answer-ids
  _ _ End End _ Reversed -> (reverse Reversed)
  Bytes Names At End Previous Reversed ->
    (let ID (shen-jit.u32 Bytes At)
         _ (if (and (> ID Previous) (< ID (limit Names))) true (error "batch: invalid answer ID"))
      (source-deps.answer-ids Bytes Names (+ At 4) End ID [(<-address Names (+ ID 1)) | Reversed])))

\\ A query's answer, the sorted IDs it reaches, as functions. An isolate reads the graph shared,
\\ by pointer.
(define source-deps.batch-job
  Graph [Mode Root] -> (sdg.query Graph Mode Root))

(define source-deps.named
  [] [] _ -> []
  [[Mode Root] | Queries] [Answer | Answers] Names
  -> [[(if (= Mode 0) reach impact) (<-address Names (+ Root 1))
       (source-deps.answer-ids Answer Names 0 (shen-jit.bytes-length Answer) -1 [])]
      | (source-deps.named Queries Answers Names)])

(define source-deps.batch-execute
  Export Queries 0 ->
    (source-deps.named Queries (map (/. Q (source-deps.batch-job (<-address Export 1) Q)) Queries)
                       (<-address Export 2))
  Export Queries Workers ->
    (source-deps.named Queries
                       (parallel.map Workers [source-deps.batch-job (isolate.share (<-address Export 1))] Queries)
                       (<-address Export 2)))

(define source-deps.batch-answer-report
  _ _ _ _ _ [] -> [ok done]
  Writer Limits State Ordinal Mode [Fn | Rest] ->
    (io.let-ok _ (source-deps.emit Writer Limits State
                  [object ["kind" (str Mode)] ["query_index" Ordinal]
                          ["function" (source-deps.function-value Fn)]])
      (source-deps.batch-answer-report Writer Limits State Ordinal Mode Rest)))

(define source-deps.batch-query-report
  _ _ _ _ [] -> [ok done]
  Writer Limits State Ordinal [[Mode Root Answer] | Rest] ->
    (io.let-ok _ (source-deps.emit Writer Limits State
                  [object ["kind" "query"] ["query_index" Ordinal] ["query" (str Mode)]
                          ["function" (source-deps.function-value Root)]])
      (io.let-ok _ (source-deps.batch-answer-report Writer Limits State Ordinal Mode Answer)
        (source-deps.batch-query-report Writer Limits State (+ Ordinal 1) Rest))))

(define source-deps.batch-report
  Analysis Answers Out Limits ->
    (let Writer (io.writer Out [[chunk-size 4096]]) State (io.record [0 0])
      (io.let-ok _ (source-deps.emit Writer Limits State (source-deps.summary Analysis))
        (io.let-ok _ (source-deps.relations Writer Limits State (<-address Analysis 2)
                      [source-context source-parse source-diagnostic excluded-file definition-linkage
                       edge file-edge resolved unresolved-reason ambiguous unowned])
          (io.let-ok _ (source-deps.batch-query-report Writer Limits State 0 Answers)
            [ok (<-address State 1)])))))

(define source-deps.batch-options
  [] -> 0
  ["--workers" N] -> (let Count (trap-error (source-deps.uint (json.parse N [])) (/. E -1))
                       (if (and (integer? Count) (>= Count 0) (<= Count 64))
                           Count
                           (error "expected --workers COUNT, from 0 to 64")))
  _ -> (error "expected --workers COUNT, from 0 to 64"))

(define source-deps.batch-run
  Input Output QueryFile Options Limits ->
    (let Workers (source-deps.batch-options Options)
      (io.let-ok Queries (source-deps.read-queries QueryFile)
        (io.let-ok Data (io.with-input-file Input
                         (/. In (source-deps.read (io.reader In [[chunk-size 16384]]) Input Limits)))
          (io.let-ok Analysis (source-deps.analyze Data [])
            (let Db (<-address Analysis 2) Export (source-deps.export Db)
              (io.let-ok Selected (source-deps.resolve-queries Db Export Queries)
                (let Answers (source-deps.batch-execute Export Selected Workers)
                  (fs.with-replacement Output
                    (/. Out (source-deps.batch-report Analysis Answers Out Limits)))))))))))
