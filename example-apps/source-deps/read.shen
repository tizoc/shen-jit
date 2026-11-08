\\ Bounded NDJSON input over our I/O. No source files are opened while interpreting facts.
(define source-deps.limits
  -> (io.record [67108864 100000 65536 10000 67108864 300000]))

(define source-deps.get
  Dict Key -> (trap-error (shen.<-dict Dict Key) (/. E [])))

(define source-deps.intern-text
  Dict Text ->
    (let Found (source-deps.get Dict Text)
      (if (= Found []) (do (shen.dict-> Dict Text Text) Text) Found)))

(define source-deps.member
  [[Key Value] | _] Key -> Value
  [_ | Rest] Key -> (source-deps.member Rest Key)
  [] Key -> (error "missing field ~A" Key))

(define source-deps.keys
  Members Keys ->
    (if (and (= (length Members) (length Keys)) (source-deps.allowed-keys Members Keys))
        true
        (error "unsupported or missing fields")))

(define source-deps.allowed-keys
  [] _ -> true
  [[Key _] | Rest] Keys -> (and (element? Key Keys) (source-deps.allowed-keys Rest Keys)))

(define source-deps.text
  Text Empty ->
    (let _ (if (string? Text) true (error "expected text"))
         B (shen-jit.string->bytes Text)
         N (shen-jit.bytes-length B)
      (if (and (or Empty (> N 0)) (source-deps.no-nul B 0 N)) Text (error "invalid text field"))))

(define source-deps.no-nul
  _ End End -> true
  B At End -> (and (not (= (shen-jit.u8 B At) 0)) (source-deps.no-nul B (+ At 1) End)))

(define source-deps.uint
  Value ->
    (let N (json.integer Value)
      (if (and (>= N 0) (<= N 2147483647)) N (error "integer must be 0..2147483647"))))

(define source-deps.boolean
  true -> 1
  false -> 0
  _ -> (error "syntax_error must be boolean"))

(define source-deps.linkage
  "internal" -> internal
  "external" -> external
  "unknown" -> unknown
  _ -> (error "unsupported linkage hint"))

(define source-deps.owner-byte
  null -> -1
  Value -> (source-deps.uint Value))

\\ State: facts reversed, file metadata, canonical names, seen sites, bytes, records, line, builder, files.
(define source-deps.read
  Reader Name Limits ->
    (let State (io.record [[] (shen.dict 64) (shen.dict 128) (shen.dict 128) 0 0 1
                          (buffer.builder (<-address Limits 2)) 0])
      (source-deps.read-more Reader Name Limits State)))

(define source-deps.read-error
  State Name Domain Message ->
    [error (io.progress (io.native-error read-facts Domain 0 Name
                          (make-string "line ~A: ~A" (<-address State 6) Message)) (<-address State 4))])

(define source-deps.read-more
  Reader Name Limits State ->
    (source-deps.read-chunk Reader Name Limits State (io.read-chunk Reader)))

(define source-deps.read-chunk
  _ _ _ _ [error Error] -> [error Error]
  _ Name Limits State [eof] ->
    (io.let-ok _ (source-deps.line Name Limits State)
      [ok (io.record [source-deps.data (reverse (<-address State 0)) (<-address State 5)
                      (<-address State 4)])])
  Reader Name Limits State [chunk View] ->
    (let N (buffer.length View)
      (if (> N (- (<-address Limits 0) (<-address State 4)))
          (source-deps.read-error State Name limit "input byte limit exceeded")
          (do (address-> State 4 (+ (<-address State 4) N))
              (io.let-ok _ (source-deps.lines Name Limits State View 0 N)
                (source-deps.read-more Reader Name Limits State))))))

(define source-deps.find-lf
  _ End End -> End
  Data At End -> (if (= (shen-jit.u8 Data At) 10) At (source-deps.find-lf Data (+ At 1) End)))

(define source-deps.lines
  _ _ _ _ End End -> [ok done]
  Name Limits State View At End ->
    (let Data (buffer.owner View)
         Offset (buffer.offset View)
         LF (- (source-deps.find-lf Data (+ Offset At) (+ Offset End)) Offset)
         Part (buffer.slice View At (- LF At))
         Appended (trap-error
                    (do (buffer.append! (<-address State 7) Part) [ok done])
                    (/. E (source-deps.read-error State Name limit "line byte limit exceeded")))
      (io.let-ok _ Appended
        (if (= LF End)
            [ok done]
            (io.let-ok _ (source-deps.line Name Limits State)
              (do (address-> State 6 (+ (<-address State 6) 1))
                  (address-> State 7 (buffer.builder (<-address Limits 2)))
                  (source-deps.lines Name Limits State View (+ LF 1) End)))))))

(define source-deps.blank?
  _ End End -> true
  View At End ->
    (and (element? (buffer.u8 View At) [9 13 32]) (source-deps.blank? View (+ At 1) End)))

(define source-deps.line
  Name Limits State ->
    (let View (buffer.finish (<-address State 7))
      (cond ((source-deps.blank? View 0 (buffer.length View)) [ok done])
            ((>= (<-address State 5) (<-address Limits 1))
              (source-deps.read-error State Name limit "record limit exceeded"))
            (true
              (trap-error
                (do (source-deps.record State Limits
                      (json.decode View [[byte-limit (<-address Limits 2)] [depth-limit 16]]))
                    (address-> State 5 (+ (<-address State 5) 1))
                    [ok done])
                (/. E (source-deps.read-error State Name
                        (if (= (error-to-string E) "file count limit exceeded") limit format)
                        (error-to-string E))))))))

(define source-deps.record
  State Limits [object | Members] ->
    (let Kind (source-deps.member Members "kind")
      (if (= Kind "file")
          (source-deps.file-record State Limits Members)
          (source-deps.site-record State Kind Members)))
  _ _ _ -> (error "fact must be a JSON object"))

(define source-deps.fact
  State Fact -> (address-> State 0 [Fact | (<-address State 0)]))

(define source-deps.file-record
  State Limits Members ->
    (let Version (if (element? "schema_version" (map (function hd) Members))
                    (source-deps.uint (source-deps.member Members "schema_version")) 1)
         _ (if (or (= Version 1) (= Version 2)) true (error "unsupported source-fact schema version"))
         Keys ["kind" "path" "byte_count" "syntax_error"]
         _ (source-deps.keys Members (if (= Version 2) ["schema_version" | Keys] Keys))
         Path (source-deps.text (source-deps.member Members "path") false)
         Bytes (source-deps.uint (source-deps.member Members "byte_count"))
         Error (source-deps.boolean (source-deps.member Members "syntax_error"))
         _ (if (= (source-deps.get (<-address State 1) Path) []) true
                (error "duplicate file record: ~A" Path))
         _ (if (< (<-address State 8) (<-address Limits 3)) true (error "file count limit exceeded"))
         _ (shen.dict-> (<-address State 1) Path (io.record [Path Bytes Error Version]))
         _ (address-> State 8 (+ (<-address State 8) 1))
      (do (source-deps.fact State [source-file Path Bytes Error])
          (source-deps.fact State [source-format Path Version]))))

(define source-deps.site-record
  State Kind Members ->
    (let _ (if (element? Kind ["definition" "call"]) true (error "unknown fact kind ~A" Kind))
         Path (source-deps.text (source-deps.member Members "path") false)
         Meta (source-deps.get (<-address State 1) Path)
         _ (if (= Meta []) (error "file record must precede its sites: ~A" Path) true)
         Path (<-address Meta 0)
         Version (<-address Meta 3)
         Keys ["kind" "path" "name" "container" "start_byte" "end_byte" "row" "column" "syntax_error"]
         Keys (if (= Version 1) Keys ["container_byte" | Keys])
         Keys (if (and (= Version 2) (= Kind "definition")) ["linkage" | Keys] Keys)
         _ (source-deps.keys Members Keys)
         Name (source-deps.intern-text (<-address State 2)
                (source-deps.text (source-deps.member Members "name") false))
         Owner (source-deps.intern-text (<-address State 2)
                 (source-deps.text (source-deps.member Members "container") true))
         Start (source-deps.uint (source-deps.member Members "start_byte"))
         End (source-deps.uint (source-deps.member Members "end_byte"))
         Row (source-deps.uint (source-deps.member Members "row"))
         Column (source-deps.uint (source-deps.member Members "column"))
         Error (source-deps.boolean (source-deps.member Members "syntax_error"))
         OwnerByte (if (= Version 1) -2
                       (source-deps.owner-byte (source-deps.member Members "container_byte")))
         Linkage (if (= Version 1) legacy
                     (if (= Kind "definition")
                         (source-deps.linkage (source-deps.member Members "linkage")) unknown))
         _ (if (and (<= Start End) (<= End (<-address Meta 1))
                    (= (- End Start) (shen-jit.bytes-length (shen-jit.string->bytes Name)))
                    (<= Row Start) (<= Column (- Start Row)) (or (> Row 0) (= Column Start))
                    (= Error (<-address Meta 2))) true (error "inconsistent site range or syntax_error"))
         _ (if (and (= Kind "definition") (not (= Name Owner)))
               (error "definition container must be its name") true)
         _ (if (or (= Version 1)
                   (and (= Kind "definition") (= OwnerByte Start))
                   (and (= Kind "call")
                        (or (and (= Owner "") (= OwnerByte -1))
                            (and (not (= Owner "")) (>= OwnerByte 0) (< OwnerByte (<-address Meta 1))))))
               true (error "inconsistent caller identity"))
         Site [at Path Start End Row Column]
         Fact (if (= Kind "definition") [source-definition Site Name Linkage]
                  [source-call Site Owner OwnerByte Name])
         Key [Kind Path Start]
         Previous (source-deps.get (<-address State 3) Key)
      (cond ((= Previous [])
              (do (shen.dict-> (<-address State 3) Key Fact) (source-deps.fact State Fact)))
            ((= Previous Fact) true)
            (true (error "conflicting records at ~A byte ~A" Path Start)))))
