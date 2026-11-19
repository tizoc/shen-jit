\\ Batch queries: the matched call graph as integer adjacency, selectors checked against it, and
\\ each query's BFS, in turn or in isolates that read the graph shared (lib/parallel.shen).

(shen.x.namespace source-deps
  (use buffer)
  (use datalog)
  (use fs)
  (use io)
  (import result let-ok ok err)
  (use json)
  (use parallel)
  (use sdg)
  (use shen-jit)
  (use source-deps)
  (shadow read)
  (externals [ambiguous chunk-size definition-linkage done edge excluded-file file-edge format impact object reach
    read-queries resolved source-context source-diagnostic source-parse unowned unresolved-reason])

(define ids
  [] _ _ _ -> true
  [[Fn] | Rest] At Names Ids ->
    (do (address-> Names (+ At 1) Fn) (shen.dict-> Ids Fn At)
        (ids Rest (+ At 1) Names Ids)))

(define edge-ids
  [] Bytes _ _ -> Bytes
  [[From To] | Rest] Bytes At Ids ->
    (do (shen-jit.u32! Bytes At (shen.<-dict Ids From))
        (shen-jit.u32! Bytes (+ At 4) (shen.<-dict Ids To))
        (edge-ids Rest Bytes (+ At 8) Ids)))

(define export
  Db ->
    (let Functions (datalog.sorted Db function) N (length Functions)
         Names (vector N) Ids (shen.dict (if (< N 16) 16 N))
         _ (ids Functions 0 Names Ids)
         Edges (datalog.tuples Db edge)
         Bytes (edge-ids Edges (shen-jit.bytes (* 8 (length Edges))) 0 Ids)
      (io.record [graph-state (sdg.build N Bytes) Names Ids])))

(define query-record
  [object | Members] ->
    (let _ (if (element? (length Members) [3 4]) true (error "expected 3 or 4 query fields"))
         _ (if (allowed-keys Members ["mode" "file" "name" "definition_byte"])
               true (error "unsupported query field"))
         Mode (member Members "mode")
         M (cond ((= Mode "reach") reach) ((= Mode "impact") impact)
                 (true (error "expected reach or impact")))
         File (text (member Members "file") false)
         Name (text (member Members "name") false)
      (if (= (length Members) 3) [M File Name]
          [M File Name (uint (member Members "definition_byte"))]))
  _ -> (error "expected a query object"))

(define query-lines
  _ End End _ Reversed -> (reverse Reversed)
  Bytes At End Count Reversed ->
    (let LF (find-lf (buffer.owner Bytes) At End)
         View (buffer.slice Bytes At (- LF At))
      (if (blank? View 0 (buffer.length View))
          (query-lines Bytes (io.min End (+ LF 1)) End Count Reversed)
          (if (or (>= Count 4096) (> (buffer.length View) 65536))
              (error "batch query limit exceeded")
              (query-lines Bytes (io.min End (+ LF 1)) End (+ Count 1)
                [(query-record (json.parse (buffer.string View) [])) | Reversed])))))

(define source-deps.read-queries
  Input ->
    (let-ok Bytes (io.with-input-file Input
                      (/. In (io.read-all (io.reader In [[chunk-size 16384]]) 1048576)))
      (trap-error (:ok (query-lines Bytes 0 (buffer.length Bytes) 0 []))
        (/. E (:err (io.native-error read-queries format 0 Input (error-to-string E)))))))

(define resolve-queries
  _ _ [] -> (:ok [])
  Db Export [Query | Rest] ->
    (let-ok Selected (source-deps.select Db Query)
            More (resolve-queries Db Export Rest)
      (:ok [[(if (= (hd Selected) reach) 0 1)
            (shen.<-dict (<-address Export 3) (hd (tl Selected)))] | More])))

(define answer-ids
  _ _ End End _ Reversed -> (reverse Reversed)
  Bytes Names At End Previous Reversed ->
    (let ID (shen-jit.u32 Bytes At)
         _ (if (and (> ID Previous) (< ID (limit Names))) true (error "batch: invalid answer ID"))
      (answer-ids Bytes Names (+ At 4) End ID [(<-address Names (+ ID 1)) | Reversed])))

\\ A query's answer, the sorted IDs it reaches, as functions. An isolate reads the graph shared,
\\ by pointer.
(define batch-job
  Graph [Mode Root] -> (sdg.query Graph Mode Root))

(define named
  [] [] _ -> []
  [[Mode Root] | Queries] [Answer | Answers] Names
  -> [[(if (= Mode 0) reach impact) (<-address Names (+ Root 1))
       (answer-ids Answer Names 0 (shen-jit.bytes-length Answer) -1 [])]
      | (named Queries Answers Names)])

(define batch-execute
  Export Queries 0 ->
    (named Queries (map (/. Q (batch-job (<-address Export 1) Q)) Queries)
                       (<-address Export 2))
  Export Queries Workers ->
    (named Queries
                       (parallel.map Workers [batch-job (isolate.share (<-address Export 1))] Queries)
                       (<-address Export 2)))

(define batch-answer-report
  _ _ _ _ _ [] -> (:ok done)
  Writer Limits State Ordinal Mode [Fn | Rest] ->
    (let-ok _ (emit Writer Limits State
                  [object ["kind" (str Mode)] ["query_index" Ordinal]
                          ["function" (function-value Fn)]])
      (batch-answer-report Writer Limits State Ordinal Mode Rest)))

(define batch-query-report
  _ _ _ _ [] -> (:ok done)
  Writer Limits State Ordinal [[Mode Root Answer] | Rest] ->
    (let-ok _ (emit Writer Limits State
                  [object ["kind" "query"] ["query_index" Ordinal] ["query" (str Mode)]
                          ["function" (function-value Root)]])
            _ (batch-answer-report Writer Limits State Ordinal Mode Answer)
      (batch-query-report Writer Limits State (+ Ordinal 1) Rest)))

(define batch-report
  Analysis Answers Out Limits ->
    (let Writer (io.writer Out [[chunk-size 4096]]) State (io.record [0 0])
      (let-ok _ (emit Writer Limits State (summary Analysis))
              _ (relations Writer Limits State (<-address Analysis 2)
                  [source-context source-parse source-diagnostic excluded-file definition-linkage
                   edge file-edge resolved unresolved-reason ambiguous unowned])
              _ (batch-query-report Writer Limits State 0 Answers)
        (:ok (<-address State 1)))))

(define batch-options
  [] -> 0
  ["--workers" N] -> (let Count (trap-error (uint (json.parse N [])) (/. E -1))
                       (if (and (integer? Count) (>= Count 0) (<= Count 64))
                           Count
                           (error "expected --workers COUNT, from 0 to 64")))
  _ -> (error "expected --workers COUNT, from 0 to 64"))

(define batch-run
  Input Output QueryFile Options Limits ->
    (let Workers (batch-options Options)
      (let-ok Queries (source-deps.read-queries QueryFile)
              Data (io.with-input-file Input
                     (/. In (read (io.reader In [[chunk-size 16384]]) Input Limits)))
              Analysis (source-deps.analyze Data [])
        (let Db (<-address Analysis 2) Export (export Db)
          (let-ok Selected (resolve-queries Db Export Queries)
            (let Answers (batch-execute Export Selected Workers)
              (fs.with-replacement Output
                (/. Out (batch-report Analysis Answers Out Limits)))))))))

)
