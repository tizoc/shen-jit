(set sd-test.passed 0)
(set sd-test.failed 0)

(define sd-test.check
  Name true -> (set sd-test.passed (+ (value sd-test.passed) 1))
  Name false -> (do (output "FAIL ~A~%" Name) (set sd-test.failed (+ (value sd-test.failed) 1))))

(define sd-test.ok
  [ok X] -> X
  X -> (error "source-deps test: ~S" X))

(define sd-test.domain
  [error E] -> (io.error-domain E)
  _ -> unexpected-success)

(define sd-test.read
  Text Capacity Limits ->
    (io.with-endpoint (io.input-buffer (buffer.from-string Text))
      (/. E (source-deps.read (io.reader E [[chunk-size Capacity]]) "memory" Limits))))

(define sd-test.file
  File Error -> [object ["kind" "file"] ["path" File] ["byte_count" 10000] ["syntax_error" Error]])

(define sd-test.site
  Kind File Name Owner Byte Error ->
    [object ["kind" Kind] ["path" File] ["name" Name] ["container" Owner]
            ["start_byte" Byte] ["end_byte" (+ Byte (shen-jit.bytes-length (shen-jit.string->bytes Name)))]
            ["row" 0] ["column" Byte] ["syntax_error" Error]])

(define sd-test.lines
  [] -> ""
  [Record | Rest] -> (cn (json.stringify Record []) (cn "c#13;c#10;" (sd-test.lines Rest))))

(define sd-test.extra
  [object | Fields] Extra -> [object | (append Fields Extra)])

(define sd-test.v2-file
  File -> (sd-test.extra (sd-test.file File false) [["schema_version" 2]]))

(define sd-test.definition
  File Name Byte Linkage ->
    (sd-test.extra (sd-test.site "definition" File Name Name Byte false)
      [["container_byte" Byte] ["linkage" Linkage]]))

(define sd-test.call
  File Name Owner OwnerByte Byte ->
    (sd-test.extra (sd-test.site "call" File Name Owner Byte false) [["container_byte" OwnerByte]]))

(define sd-test.analyze-records
  Records Query ->
    (io.let-ok Data (sd-test.read (sd-test.lines Records) 3 (source-deps.limits))
      (source-deps.analyze Data Query)))

(set sd-test.records
  [(sd-test.file "a.c" false) (sd-test.file "b.c" false) (sd-test.file "c.c" false)
   (sd-test.file "bad.c" true)
   (sd-test.site "definition" "a.c" "main" "main" 0 false)
   (sd-test.site "definition" "a.c" "helper" "helper" 10 false)
   (sd-test.site "definition" "b.c" "helper" "helper" 0 false)
   (sd-test.site "definition" "b.c" "leaf" "leaf" 10 false)
   (sd-test.site "definition" "c.c" "entry" "entry" 0 false)
   (sd-test.site "definition" "bad.c" "bad" "bad" 0 true)
   (sd-test.site "call" "a.c" "helper" "main" 30 false)
   (sd-test.site "call" "a.c" "leaf" "helper" 50 false)
   (sd-test.site "call" "b.c" "main" "leaf" 30 false)
   (sd-test.site "call" "c.c" "helper" "entry" 30 false)
   (sd-test.site "call" "c.c" "external" "entry" 50 false)
   (sd-test.site "call" "c.c" "bad" "entry" 70 false)
   (sd-test.site "call" "c.c" "main" "" 90 false)
   (sd-test.site "call" "bad.c" "main" "bad" 30 true)])
(set sd-test.text (sd-test.lines (value sd-test.records)))
(set sd-test.data (sd-test.ok (sd-test.read (value sd-test.text) 17 (source-deps.limits))))
(set sd-test.analysis (sd-test.ok (source-deps.analyze (value sd-test.data) [])))

(let Db (<-address (value sd-test.analysis) 2)
     Naive (datalog.run-naive source-deps.program (<-address (value sd-test.data) 1))
  (do (map (/. Rel (sd-test.check Rel (= (datalog.sorted Db Rel) (datalog.sorted Naive Rel))))
        [source-file source-format source-definition source-call usable-file excluded-file legacy-file
         raw-definition invalid-owner defined definition-linkage visible function
         call-file call local-count global-count unique-local unique-owner unique-global owned unowned
         resolved ambiguous unresolved edge file-edge])
      (sd-test.check "file/name identity and local preference"
        (datalog.holds? Db [edge [fn "a.c" "main" 0] [fn "a.c" "helper" 10]]))
      (sd-test.check "no edge to same-named function in another file"
        (not (datalog.holds? Db [edge [fn "a.c" "main" 0] [fn "b.c" "helper" 0]])))
      (sd-test.check "unique cross-file target"
        (datalog.holds? Db [edge [fn "a.c" "helper" 10] [fn "b.c" "leaf" 10]]))
      (sd-test.check "ambiguous global target" (= (datalog.count Db ambiguous) 1))
      (sd-test.check "unresolved and excluded targets" (= (datalog.count Db unresolved) 2))
      (sd-test.check "unscoped call" (= (datalog.count Db unowned) 1))
      (sd-test.check "syntax-error file excluded" (= (datalog.count Db function) 5))
      (sd-test.check "edge set" (= (datalog.count Db edge) 3))))

(map (/. Mode
       (let A (sd-test.ok (source-deps.analyze (value sd-test.data) [Mode "a.c" "main"]))
            Answers (datalog.sorted (<-address A 4) reached)
         (sd-test.check Mode
           (= Answers [[[fn "a.c" "helper" 10]] [[fn "a.c" "main" 0]] [[fn "b.c" "leaf" 10]]]))))
  [reach impact])

(map (/. Capacity
       (let Data (sd-test.ok (sd-test.read (value sd-test.text) Capacity (source-deps.limits)))
         (sd-test.check Capacity (= (<-address Data 1) (<-address (value sd-test.data) 1)))))
  [1 2 3 7 64 16384])

(sd-test.check "empty input" (= (<-address (sd-test.ok (sd-test.read "" 1 (source-deps.limits))) 1) []))
(sd-test.check "blank lines" (= (<-address (sd-test.ok (sd-test.read "c#10; c#9;c#13;c#10;" 1
                                                    (source-deps.limits))) 1) []))
(sd-test.check "final line without LF"
  (= (<-address (sd-test.ok (sd-test.read (json.stringify (sd-test.file "x" false) []) 1
                            (source-deps.limits))) 2) 1))

(map (/. Text
       (sd-test.check Text (= (sd-test.domain (sd-test.read Text 3 (source-deps.limits))) format)))
  ["{}" "[]" "null" "true" "{" "{} {}" "{c#34;kindc#34;:c#34;filec#34;}"
   "{c#34;kindc#34;:c#34;filec#34;,c#34;kindc#34;:c#34;callc#34;}" "c#255;"])

(map (/. Record
       (sd-test.check "bad schema"
         (= (sd-test.domain (sd-test.read (sd-test.lines [(sd-test.file "a.c" false) Record])
                             11 (source-deps.limits))) format)))
  [(sd-test.site "other" "a.c" "x" "x" 0 false)
   (sd-test.site "definition" "missing.c" "x" "x" 0 false)
   (sd-test.site "definition" "a.c" "x" "other" 0 false)
   (sd-test.site "call" "a.c" "x" "x" 0 true)
   (sd-test.site "call" "a.c" "x" "x" 10000 false)
   (sd-test.site "call" "a.c" "" "x" 0 false)
   (sd-test.site "call" "a.c" "x" "x" -1 false)])

(map (/. Slot
       (let Limits (address-> (source-deps.limits) Slot 0)
         (sd-test.check "input quota"
           (= (sd-test.domain (sd-test.read (value sd-test.text) 1 Limits)) limit))))
  [0 1 2 3])

(sd-test.check "duplicate file headers rejected"
  (= (sd-test.domain (sd-test.read (sd-test.lines [(sd-test.file "a.c" false) (sd-test.file "a.c" false)])
                      7 (source-deps.limits))) format))
(let Records [(sd-test.file "a.c" false) (sd-test.site "definition" "a.c" "x" "x" 0 false)
               (sd-test.site "definition" "a.c" "x" "x" 0 false)]
     Data (sd-test.ok (sd-test.read (sd-test.lines Records) 9 (source-deps.limits)))
  (sd-test.check "identical sites deduplicate" (and (= (<-address Data 2) 3) (= (length (<-address Data 1)) 3))))
(sd-test.check "conflicting sites rejected"
  (= (sd-test.domain (sd-test.read
       (sd-test.lines [(sd-test.file "a.c" false) (sd-test.site "call" "a.c" "x" "a" 5 false)
                      (sd-test.site "call" "a.c" "y" "a" 5 false)]) 13 (source-deps.limits))) format))

(let Extra [(sd-test.site "definition" "c.c" "twice" "twice" 100 false)
             (sd-test.site "definition" "c.c" "twice" "twice" 120 false)
             (sd-test.site "call" "c.c" "main" "twice" 150 false)
             (sd-test.site "call" "c.c" "twice" "entry" 170 false)]
     Data (sd-test.ok (sd-test.read (sd-test.lines (append (value sd-test.records) Extra))
                       23 (source-deps.limits)))
     A (sd-test.ok (source-deps.analyze Data []))
     Db (<-address A 2)
  (do (sd-test.check "ambiguous local target" (= (datalog.count Db ambiguous) 2))
      (sd-test.check "ambiguous owner" (= (datalog.count Db unowned) 2))
      (sd-test.check "ambiguous root rejected"
        (= (sd-test.domain (source-deps.analyze Data [reach "c.c" "twice"])) library))))

(sd-test.check "unknown root rejected"
  (= (sd-test.domain (source-deps.analyze (value sd-test.data) [reach "none.c" "main"])) library))

(let View (buffer.new 32768)
     Result (io.with-endpoint (io.output-buffer View)
              (/. E (source-deps.report (value sd-test.analysis) E (source-deps.limits))))
  (sd-test.check "report through own I/O" (> (sd-test.ok Result) 1)))
(map (/. Slot
       (let Limits (address-> (source-deps.limits) Slot 0)
             Result (io.with-endpoint (io.output-buffer (buffer.new 32768))
                      (/. E (source-deps.report (value sd-test.analysis) E Limits)))
         (sd-test.check "report quota" (= (sd-test.domain Result) limit))))
  [4 5])

(set sd-test.v2-records
  [(sd-test.v2-file "a.c") (sd-test.v2-file "b.c") (sd-test.v2-file "c.c")
   (sd-test.definition "a.c" "twice" 0 "external")
   (sd-test.definition "a.c" "twice" 20 "external")
   (sd-test.definition "a.c" "private" 40 "internal")
   (sd-test.definition "a.c" "shared" 60 "internal")
   (sd-test.definition "a.c" "nested" 80 "unknown")
   (sd-test.definition "b.c" "private" 0 "internal")
   (sd-test.definition "b.c" "shared" 20 "external")
   (sd-test.definition "c.c" "entry" 0 "external")
   (sd-test.call "a.c" "private" "twice" 0 100)
   (sd-test.call "a.c" "shared" "twice" 20 120)
   (sd-test.call "a.c" "nested" "twice" 0 140)
   (sd-test.call "c.c" "private" "entry" 0 100)
   (sd-test.call "c.c" "shared" "entry" 0 120)
   (sd-test.call "c.c" "nested" "entry" 0 140)
   (sd-test.call "c.c" "twice" "entry" 0 160)
   (sd-test.call "c.c" "shared" "" null 180)])

(let Data (sd-test.ok (sd-test.read (sd-test.lines (value sd-test.v2-records)) 1 (source-deps.limits)))
     A (sd-test.ok (source-deps.analyze Data []))
     Db (<-address A 2)
     Naive (datalog.run-naive source-deps.program (<-address Data 1))
  (do (map (/. Rel (sd-test.check Rel (= (datalog.sorted Db Rel) (datalog.sorted Naive Rel))))
        [invalid-owner defined visible owned unowned resolved ambiguous unresolved edge file-edge])
      (sd-test.check "duplicate names retain exact callers"
        (and (datalog.holds? Db [edge [fn "a.c" "twice" 0] [fn "a.c" "private" 40]])
             (datalog.holds? Db [edge [fn "a.c" "twice" 20] [fn "a.c" "shared" 60]])))
      (sd-test.check "private duplicates do not hide an external target"
        (datalog.holds? Db [edge [fn "c.c" "entry" 0] [fn "b.c" "shared" 20]]))
      (sd-test.check "private and unknown targets stay unresolved" (= (datalog.count Db unresolved) 3))
      (sd-test.check "explicit unscoped call" (= (datalog.count Db unowned) 1))
      (sd-test.check "versioned files are not legacy" (= (datalog.count Db legacy-file) 0))))

(map (/. Byte
       (let A (sd-test.ok (sd-test.analyze-records (value sd-test.v2-records) [reach "a.c" "twice" Byte]))
         (sd-test.check "select caller by byte" (= (datalog.count (<-address A 4) reached) 1))))
  [0 20])

(map (/. BadCall
       (sd-test.check "invalid caller identity rejected"
         (= (sd-test.domain
              (sd-test.analyze-records
                [(sd-test.v2-file "a.c") (sd-test.definition "a.c" "f" 0 "external") BadCall] []))
            format)))
  [(sd-test.call "a.c" "f" "f" null 20)
   (sd-test.call "a.c" "f" "f" -1 20)
   (sd-test.call "a.c" "f" "f" 1 20)
   (sd-test.call "a.c" "f" "other" 0 20)
   (sd-test.call "a.c" "f" "" 0 20)
   (sd-test.site "call" "a.c" "f" "f" 20 false)])

(map (/. Record
       (sd-test.check "versioned schema validated"
         (= (sd-test.domain (sd-test.read (sd-test.lines [(sd-test.v2-file "a.c") Record])
                             1 (source-deps.limits))) format)))
  [(sd-test.definition "a.c" "f" 0 "legacy")
   (sd-test.definition "a.c" "f" 0 "static")
   (sd-test.site "definition" "a.c" "f" "f" 0 false)
   (sd-test.extra (sd-test.site "definition" "a.c" "f" "f" 0 false)
     [["container_byte" 1] ["linkage" "external"]])])

(output "~A passed, ~A failed~%" (value sd-test.passed) (value sd-test.failed))
