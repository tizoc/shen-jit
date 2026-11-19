\\ Bounded NDJSON input over our I/O. No source files are opened while interpreting facts.

(shen.x.namespace source-deps
  (use buffer)
  (use io)
  (import result let-ok ok err)
  (use json)
  (use shen-jit)
  (use source-deps)
  (shadow boolean get read)
  (externals [at byte-limit configured depth-limit done format legacy missing object preprocessed raw
    read-facts source-call source-context source-declaration source-definition source-diagnostic source-file
    source-format source-parse unknown])

(define limits
  -> (io.record [67108864 100000 65536 10000 67108864 300000]))

(define get
  Dict Key -> (trap-error (shen.<-dict Dict Key) (/. E [])))

(define intern-text
  Dict Text ->
    (let Found (get Dict Text)
      (if (= Found []) (do (shen.dict-> Dict Text Text) Text) Found)))

(define member
  [[Key Value] | _] Key -> Value
  [_ | Rest] Key -> (member Rest Key)
  [] Key -> (error "missing field ~A" Key))

(define keys
  Members Keys ->
    (if (and (= (length Members) (length Keys)) (allowed-keys Members Keys))
        true
        (error "unsupported or missing fields")))

(define allowed-keys
  [] _ -> true
  [[Key _] | Rest] Keys -> (and (element? Key Keys) (allowed-keys Rest Keys)))

(define text
  Text Empty ->
    (let _ (if (string? Text) true (error "expected text"))
         B (shen-jit.string->bytes Text)
         N (shen-jit.bytes-length B)
      (if (and (or Empty (> N 0)) (no-nul B 0 N)) Text (error "invalid text field"))))

(define no-nul
  _ End End -> true
  B At End -> (and (not (= (shen-jit.u8 B At) 0)) (no-nul B (+ At 1) End)))

(define uint
  Value ->
    (let N (json.integer Value)
      (if (and (>= N 0) (<= N 2147483647)) N (error "integer must be 0..2147483647"))))

(define boolean
  true -> 1
  false -> 0
  _ -> (error "syntax_error must be boolean"))

(define linkage
  "internal" -> internal
  "external" -> external
  "unknown" -> unknown
  _ -> (error "unsupported linkage hint"))

(define owner-byte
  null -> -1
  Value -> (uint Value))

\\ State: facts reversed, file metadata, canonical names, seen sites, bytes, records, line, builder, files.
(define read
  Reader Name Limits ->
    (let State (io.record [[] (shen.dict 64) (shen.dict 128) (shen.dict 128) 0 0 1
                          (buffer.builder (<-address Limits 2)) 0 []])
      (read-more Reader Name Limits State)))

(define read-error
  State Name Domain Message ->
    (:err (io.progress (io.native-error read-facts Domain 0 Name
                          (make-string "line ~A: ~A" (<-address State 6) Message)) (<-address State 4))))

(define read-more
  Reader Name Limits State ->
    (read-chunk Reader Name Limits State (io.read-chunk Reader)))

(define read-chunk
  _ _ _ _ (:err Error) -> (:err Error)
  _ Name Limits State (:ok []) ->
    (let-ok _ (line Name Limits State)
      (:ok (io.record [data (reverse (<-address State 0)) (<-address State 5)
                      (<-address State 4)])))
  Reader Name Limits State (:ok [View]) ->
    (let N (buffer.length View)
      (if (> N (- (<-address Limits 0) (<-address State 4)))
          (read-error State Name limit "input byte limit exceeded")
          (do (address-> State 4 (+ (<-address State 4) N))
              (let-ok _ (lines Name Limits State View 0 N)
                (read-more Reader Name Limits State))))))

(define find-lf
  _ End End -> End
  Data At End -> (if (= (shen-jit.u8 Data At) 10) At (find-lf Data (+ At 1) End)))

(define lines
  _ _ _ _ End End -> (:ok done)
  Name Limits State View At End ->
    (let Data (buffer.owner View)
         Offset (buffer.offset View)
         LF (- (find-lf Data (+ Offset At) (+ Offset End)) Offset)
         Part (buffer.slice View At (- LF At))
         Appended (trap-error
                    (do (buffer.append! (<-address State 7) Part) (:ok done))
                    (/. E (read-error State Name limit "line byte limit exceeded")))
      (let-ok _ Appended
        (if (= LF End)
            (:ok done)
            (let-ok _ (line Name Limits State)
              (do (address-> State 6 (+ (<-address State 6) 1))
                  (address-> State 7 (buffer.builder (<-address Limits 2)))
                  (lines Name Limits State View (+ LF 1) End)))))))

(define blank?
  _ End End -> true
  View At End ->
    (and (element? (buffer.u8 View At) [9 13 32]) (blank? View (+ At 1) End)))

(define line
  Name Limits State ->
    (let View (buffer.finish (<-address State 7))
      (cond ((blank? View 0 (buffer.length View)) (:ok done))
            ((>= (<-address State 5) (<-address Limits 1))
              (read-error State Name limit "record limit exceeded"))
            (true
              (trap-error
                (do (record State Limits
                      (json.decode View [[byte-limit (<-address Limits 2)] [depth-limit 16]]))
                    (address-> State 5 (+ (<-address State 5) 1))
                    (:ok done))
                (/. E (read-error State Name
                        (if (= (error-to-string E) "file count limit exceeded") limit format)
                        (error-to-string E))))))))

(define record
  State Limits [object | Members] ->
    (let Kind (member Members "kind")
      (if (= Kind "file")
          (file-record State Limits Members)
          (site-record State Kind Members)))
  _ _ _ -> (error "fact must be a JSON object"))

(define fact
  State Fact -> (address-> State 0 [Fact | (<-address State 0)]))

(define source-deps.object
  [object | Members] Keys -> (do (keys Members Keys) Members)
  _ _ -> (error "expected metadata object"))

(define valid-range?
  Bytes Start End Row Column ->
    (and (<= Start End) (<= End Bytes) (<= Row Start) (<= Column (- Start Row))
         (or (> Row 0) (= Column Start))))

(define diagnostic
  State Path Bytes Value ->
    (let Fields (source-deps.object Value ["kind" "node_kind" "start_byte" "end_byte" "row" "column" "excerpt"])
         Kind (member Fields "kind")
         _ (if (element? Kind ["error" "missing"]) true (error "invalid parse diagnostic kind"))
         Node (text (member Fields "node_kind") false)
         Start (uint (member Fields "start_byte"))
         End (uint (member Fields "end_byte"))
         Row (uint (member Fields "row"))
         Column (uint (member Fields "column"))
         Text (text (member Fields "excerpt") true)
         _ (if (and (valid-range? Bytes Start End Row Column)
                    (or (= Kind "error") (= Start End))
                    (<= (shen-jit.bytes-length (shen-jit.string->bytes Text)) 480)) true
               (error "invalid parse diagnostic range or excerpt"))
      (fact State [source-diagnostic [at Path Start End Row Column]
                              (if (= Kind "error") error missing) Node Text])))

(define parse-record
  State Path Bytes Error Value ->
    (let Fields (source-deps.object Value ["profile" "normalizations" "error_count" "errors" "ignored_captures"])
         Profile (member Fields "profile")
         _ (if (element? Profile ["c" "c-facts-v1"]) true (error "unsupported parser profile"))
         Counts (source-deps.object (member Fields "normalizations")
                  ["attributes" "nullability" "block_pointers"])
         Attributes (uint (member Counts "attributes"))
         Nullability (uint (member Counts "nullability"))
         Blocks (uint (member Counts "block_pointers"))
         _ (if (or (= Profile "c-facts-v1") (and (= Attributes 0) (= Nullability 0) (= Blocks 0)))
               true (error "raw parser profile cannot normalize syntax"))
         N (uint (member Fields "error_count"))
         Errors (member Fields "errors")
         _ (if (and (= Error (if (= N 0) 0 1)) (= (length Errors) (io.min N 8))) true
               (error "parse diagnostics disagree with syntax_error"))
         Ignored (source-deps.object (member Fields "ignored_captures") ["annotation" "preprocessor"])
         Annotation (uint (member Ignored "annotation"))
         Preprocessor (uint (member Ignored "preprocessor"))
         _ (map (/. Diagnostic (diagnostic State Path Bytes Diagnostic)) Errors)
      (fact State [source-parse Path Profile N Attributes Nullability Blocks Annotation Preprocessor])))

(define context
  State Version Path Members ->
    (let Context (if (< Version 3) [raw]
                     (let Configuration (text (member Members "configuration") false)
                          _ (if (= (member Members "coordinates") "preprocessed") true
                                (error "configured coordinates must be preprocessed"))
                          _ (text (member Members "directory") false)
                          Args (member Members "arguments")
                          _ (if (and (cons? Args) (<= (length Args) 264)) true (error "invalid compiler arguments"))
                          _ (map (/. Arg (text Arg true)) Args)
                          _ (fact State [source-context Path Configuration preprocessed])
                       [configured Configuration]))
         Previous (<-address State 9)
      (if (or (= Previous []) (= Previous Context))
          (address-> State 9 Context)
          (error "cannot mix raw facts or different build configurations"))))

(define file-record
  State Limits Members ->
    (let Version (if (element? "schema_version" (map (function hd) Members))
                    (uint (member Members "schema_version")) 1)
         _ (if (element? Version [1 2 3]) true (error "unsupported source-fact schema version"))
         Keys ["kind" "path" "byte_count" "syntax_error"]
         Keys (if (= Version 1) Keys ["schema_version" | Keys])
         Keys (if (= Version 3) (append Keys ["configuration" "coordinates" "directory" "arguments"]) Keys)
         Detailed (and (> Version 1) (element? "parse" (map (function hd) Members)))
         Keys (if Detailed ["parse" | Keys] Keys)
         _ (keys Members Keys)
         Path (text (member Members "path") false)
         Bytes (uint (member Members "byte_count"))
         Error (boolean (member Members "syntax_error"))
         _ (if (= (get (<-address State 1) Path) []) true
                (error "duplicate file record: ~A" Path))
         _ (if (< (<-address State 8) (<-address Limits 3)) true (error "file count limit exceeded"))
         _ (context State Version Path Members)
         _ (if Detailed (parse-record State Path Bytes Error (member Members "parse")) true)
         _ (shen.dict-> (<-address State 1) Path (io.record [Path Bytes Error Version]))
         _ (address-> State 8 (+ (<-address State 8) 1))
      (do (fact State [source-file Path Bytes Error])
          (fact State [source-format Path Version]))))

(define site-record
  State Kind Members ->
    (let _ (if (element? Kind ["definition" "call" "declaration"]) true (error "unknown fact kind ~A" Kind))
         Path (text (member Members "path") false)
         Meta (get (<-address State 1) Path)
         _ (if (= Meta []) (error "file record must precede its sites: ~A" Path) true)
         Path (<-address Meta 0)
         Version (<-address Meta 3)
         _ (if (and (= Kind "declaration") (< Version 3)) (error "declarations require schema version 3") true)
         Keys ["kind" "path" "name" "container" "start_byte" "end_byte" "row" "column" "syntax_error"]
         Keys (if (= Version 1) Keys ["container_byte" | Keys])
         Keys (if (and (>= Version 2) (not (= Kind "call"))) ["linkage" | Keys] Keys)
         _ (keys Members Keys)
         Name (intern-text (<-address State 2)
                (text (member Members "name") false))
         Owner (intern-text (<-address State 2)
                 (text (member Members "container") true))
         Start (uint (member Members "start_byte"))
         End (uint (member Members "end_byte"))
         Row (uint (member Members "row"))
         Column (uint (member Members "column"))
         Error (boolean (member Members "syntax_error"))
         OwnerByte (if (= Version 1) -2
                       (owner-byte (member Members "container_byte")))
         Linkage (if (= Version 1) legacy
                     (if (not (= Kind "call"))
                         (linkage (member Members "linkage")) unknown))
         _ (if (and (valid-range? (<-address Meta 1) Start End Row Column)
                    (= (- End Start) (shen-jit.bytes-length (shen-jit.string->bytes Name)))
                    (= Error (<-address Meta 2))) true (error "inconsistent site range or syntax_error"))
         _ (if (and (= Kind "definition") (not (= Name Owner)))
               (error "definition container must be its name") true)
         _ (if (or (= Version 1)
                   (and (= Kind "definition") (= OwnerByte Start))
                   (and (= Kind "declaration") (= Owner "") (= OwnerByte -1) (not (= Linkage unknown)))
                   (and (= Kind "call")
                        (or (and (= Owner "") (= OwnerByte -1))
                            (and (not (= Owner "")) (>= OwnerByte 0) (< OwnerByte (<-address Meta 1))))))
               true (error "inconsistent caller identity"))
         Site [at Path Start End Row Column]
         Fact (cond ((= Kind "definition") [source-definition Site Name Linkage])
                    ((= Kind "declaration") [source-declaration Site Name Linkage])
                    (true [source-call Site Owner OwnerByte Name]))
         Key [Kind Path Start]
         Previous (get (<-address State 3) Key)
      (cond ((= Previous [])
              (do (shen.dict-> (<-address State 3) Key Fact) (fact State Fact)))
            ((= Previous Fact) true)
            (true (error "conflicting records at ~A byte ~A" Path Start)))))

)
