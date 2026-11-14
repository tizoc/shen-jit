(shen.x.namespace source-deps
  (use buffer)
  (use datalog)
  (use io)
  (use json)
  (use source-deps)
  (externals [accepted ambiguous at byte-limit chunk-size definition-linkage done edge excluded-file file-edge
    legacy-file object ok reached report resolved source-call source-context source-declaration source-definition
    source-diagnostic source-file source-parse unowned unresolved unresolved-reason])

(define function-value
  [fn File Name Byte] -> [object ["file" File] ["name" Name] ["definition_byte" Byte]])

(define site-value
  [at File Start End Row Column] ->
    [object ["file" File] ["start_byte" Start] ["end_byte" End] ["row" Row] ["column" Column]])

(define summary
  Analysis ->
    (let Db (<-address Analysis 2)
         Data (<-address Analysis 1)
      [object ["kind" "summary"]
              ["matching" (if (= (datalog.count Db source-context) 0)
                              "caller-id-local-then-visible-name" "caller-id-local-then-declared-external")]
              ["syntax_errors" "exclude-files"]
              ["legacy_files" (datalog.count Db legacy-file)]
              ["configured_units" (datalog.count Db source-context)]
              ["parse_metadata_files" (datalog.count Db source-parse)]
              ["diagnostic_samples" (datalog.count Db source-diagnostic)]
              ["input_records" (<-address Data 2)] ["input_bytes" (<-address Data 3)]
              ["files" (datalog.count Db source-file)] ["excluded_files" (datalog.count Db excluded-file)]
              ["input_definitions" (datalog.count Db source-definition)]
              ["input_declarations" (datalog.count Db source-declaration)]
              ["functions" (datalog.count Db function)] ["input_calls" (datalog.count Db source-call)]
              ["calls" (datalog.count Db call)] ["resolved_calls" (datalog.count Db resolved)]
              ["unresolved_calls" (datalog.count Db unresolved)]
              ["ambiguous_calls" (datalog.count Db ambiguous)] ["unowned_calls" (datalog.count Db unowned)]
              ["edges" (datalog.count Db edge)] ["file_edges" (datalog.count Db file-edge)]]))

(define row
  source-parse [File Profile Errors Attributes Nullability Blocks Annotation Preprocessor] ->
    [object ["kind" "parse"] ["file" File] ["profile" Profile] ["error_count" Errors]
            ["normalizations" [object ["attributes" Attributes] ["nullability" Nullability] ["block_pointers" Blocks]]]
            ["ignored_captures" [object ["annotation" Annotation] ["preprocessor" Preprocessor]]]]
  source-diagnostic [Site Kind Node Text] ->
    [object ["kind" "parse_diagnostic"] ["site" (site-value Site)]
            ["diagnostic" (str Kind)] ["node_kind" Node] ["excerpt" Text]]
  source-context [File Configuration Coordinates] ->
    [object ["kind" "context"] ["file" File] ["configuration" Configuration] ["coordinates" (str Coordinates)]]
  excluded-file [File] -> [object ["kind" "excluded_file"] ["file" File] ["reason" "syntax_error"]]
  definition-linkage [File Name Byte Linkage] ->
    [object ["kind" "function"] ["function" (function-value [fn File Name Byte])]
            ["linkage" (str Linkage)]]
  edge [From To] ->
    [object ["kind" "edge"] ["from" (function-value From)] ["to" (function-value To)]]
  file-edge [From To] -> [object ["kind" "file_edge"] ["from" From] ["to" To]]
  resolved [Site From To] ->
    [object ["kind" "resolved_call"] ["site" (site-value Site)]
            ["from" (function-value From)] ["to" (function-value To)]]
  unresolved-reason [Site From Name Reason] ->
    [object ["kind" "unresolved_call"] ["site" (site-value Site)]
            ["from" (function-value From)] ["target" Name] ["reason" (str Reason)]]
  ambiguous [Site From Name Count Scope] ->
    [object ["kind" "ambiguous_call"] ["site" (site-value Site)]
            ["from" (function-value From)] ["target" Name]
            ["candidates" Count] ["scope" (str Scope)]]
  unowned [Site Owner Name Count] ->
    [object ["kind" "unowned_call"] ["site" (site-value Site)]
            ["container" Owner] ["target" Name] ["owner_candidates" Count]
            ["reason" (if (= Owner "") "outside-function" "missing-or-ambiguous-owner")]])

(define write-result
  [accepted _] -> [ok done]
  [error Error _] -> [error Error])

\\ The graph stays in its database; only one encoded report record is buffered here.
(define emit
  Writer Limits State Value ->
    (let Bytes (json.encode Value [[byte-limit 1048576]])
         N (+ (buffer.length Bytes) 1)
      (if (or (>= (<-address State 1) (<-address Limits 5))
              (> N (- (<-address Limits 4) (<-address State 0))))
          [error (io.native-error report limit 0 "source dependencies" "report limit exceeded")]
          (io.let-ok _ (write-result (io.write Writer Bytes))
            (io.let-ok _ (write-result (io.write Writer (buffer.from-string "c#10;")))
              (do (address-> State 0 (+ (<-address State 0) N))
                  (address-> State 1 (+ (<-address State 1) 1))
                  [ok done]))))))

(define rows
  _ _ _ _ [] -> [ok done]
  Writer Limits State Relation [Tuple | Rest] ->
    (io.let-ok _ (emit Writer Limits State (row Relation Tuple))
      (rows Writer Limits State Relation Rest)))

(define relations
  _ _ _ _ [] -> [ok done]
  Writer Limits State Db [Relation | Rest] ->
    (io.let-ok _ (rows Writer Limits State Relation (datalog.sorted Db Relation))
      (relations Writer Limits State Db Rest)))

(define answers
  _ _ _ _ [] -> [ok done]
  Writer Limits State Mode [[Function] | Rest] ->
    (io.let-ok _ (emit Writer Limits State
                  [object ["kind" (str Mode)] ["function" (function-value Function)]])
      (answers Writer Limits State Mode Rest)))

(define query-report
  _ _ _ _ [] -> [ok done]
  Writer Limits State Walk [Mode Function] ->
    (io.let-ok _ (emit Writer Limits State
                  [object ["kind" "query"] ["query" (str Mode)]
                          ["function" (function-value Function)]])
      (answers Writer Limits State Mode (datalog.sorted Walk reached))))

(define source-deps.report
  Analysis Out Limits ->
    (let Writer (io.writer Out [[chunk-size 4096]])
         State (io.record [0 0])
      (io.let-ok _ (emit Writer Limits State (summary Analysis))
        (io.let-ok _ (relations Writer Limits State (<-address Analysis 2)
                      [source-context source-parse source-diagnostic excluded-file definition-linkage
                       edge file-edge resolved unresolved-reason ambiguous unowned])
          (io.let-ok _ (query-report Writer Limits State (<-address Analysis 4)
                        (<-address Analysis 3))
            [ok (<-address State 1)])))))

)
