\\ Tree-sitter complete-input snapshots and structural queries. Load after ffi.shen and buffer.shen.
\\ Native trees are closed before returning; snapshots own managed source, records and name tables.

(if (bound? treesitter.*adapter-files*) true
    (set treesitter.*adapter-files*
      ["./build/shen-tree-sitter.so" "./lib/shen-tree-sitter.so" "./shen-tree-sitter.so"
       "./build/shen-tree-sitter.dll" "./lib/shen-tree-sitter.dll" "./shen-tree-sitter.dll"]))

(shen-jit.library treesitter.adapter (value treesitter.*adapter-files*))
(define-foreign treesitter.c-abi treesitter.adapter "shen_treesitter_abi" () --> uint32)
(define-foreign-procedure treesitter.c-language treesitter.adapter "shen_treesitter_language" 1)
(define-foreign-procedure treesitter.c-parse treesitter.adapter "shen_treesitter_parse" 2)

(define treesitter.record
  Fields -> (treesitter.fill (absvector (length Fields)) 0 Fields))

(define treesitter.fill
  V _ [] -> V
  V At [X | Rest] -> (treesitter.fill (address-> V At X) (+ At 1) Rest))

(define treesitter.tag?
  V Tag -> (trap-error (and (absvector? V) (= (<-address V 0) Tag)) (/. E false)))

(define treesitter.abi
  -> (if (= (treesitter.c-abi) 1) true (error "treesitter: incompatible adapter; rebuild it")))

(define treesitter.text-argument
  Text ->
    (let _ (if (string? Text) true (error "treesitter: expected a string"))
         Bytes (shen-jit.string->bytes Text)
         N (shen-jit.bytes-length Bytes)
      (if (and (> N 0) (<= N 1048576) (treesitter.no-nul? Bytes 0 N))
          Text
          (error "treesitter: expected 1..1048576 NUL-free bytes"))))

(define treesitter.byte-length
  Text -> (shen-jit.bytes-length (shen-jit.string->bytes Text)))

(define treesitter.no-nul?
  _ End End -> true
  Bytes At End ->
    (and (not (= (shen-jit.u8 Bytes At) 0)) (treesitter.no-nul? Bytes (+ At 1) End)))

(define treesitter.files
  [] -> []
  [File | Rest] -> [(treesitter.text-argument File) | (treesitter.files Rest)]
  _ -> (error "treesitter: grammar files must be a list of strings"))

(define treesitter.error
  Op Domain Code Offset Resource Message -> [treesitter-error Op Domain Code Offset Resource Message])

(define treesitter.error-operation
  [treesitter-error Op _ _ _ _ _] -> Op)

(define treesitter.error-domain
  [treesitter-error _ Domain _ _ _ _] -> Domain)

(define treesitter.error-code
  [treesitter-error _ _ Code _ _ _] -> Code)

(define treesitter.error-offset
  [treesitter-error _ _ _ Offset _ _] -> Offset)

(define treesitter.error-resource
  [treesitter-error _ _ _ _ Resource _] -> Resource)

(define treesitter.error-message
  [treesitter-error _ _ _ _ _ Message] -> Message)

(define treesitter.domain
  1 -> native
  2 -> timeout
  3 -> limit
  4 -> query
  5 -> predicate
  6 -> language)

(define treesitter.native-error
  Op Resource Raw ->
    [error (treesitter.error Op (treesitter.domain (<-address Raw 0)) (<-address Raw 1)
                            (<-address Raw 2) Resource (<-address Raw 3))])

(define treesitter.foreign-error
  Op Resource Exception ->
    [error (treesitter.error Op foreign 0 0 Resource (error-to-string Exception))])

\\ A language stores its FFI entry name, not a native address. It reopens correctly in saved images.
(define treesitter.load-language
  Name Files Entry ->
    (let _ (treesitter.text-argument Name)
         Paths (treesitter.files Files)
         _ (if (= Paths []) (error "treesitter: supply grammar library files") true)
         _ (treesitter.text-argument Entry)
         Function (gensym treesitter.grammar.)
         _ (shen-jit.library Function Paths)
         _ (shen-jit.ffi.define Function Function Entry [] pointer false 0)
      (trap-error
        (do (treesitter.abi)
            (let Raw (treesitter.c-language (eval-kl [Function]))
              (if (number? Raw)
                  [ok (treesitter.record [treesitter.language Name Function Raw])]
                  (treesitter.native-error load-language Name Raw))))
        (/. X (treesitter.foreign-error load-language Name X)))))

(define treesitter.language-check
  Language ->
    (if (treesitter.tag? Language treesitter.language)
        Language
        (error "treesitter: not a language")))

(define treesitter.language-name
  Language -> (<-address (treesitter.language-check Language) 1))

(define treesitter.language-version
  Language -> (<-address (treesitter.language-check Language) 3))

(define treesitter.limit
  N Maximum Positive ->
    (let I (buffer.index N)
      (if (and (<= I Maximum) (or (not Positive) (> I 0)))
          I
          (error "treesitter: limit must be ~A..~A" (if Positive 1 0) Maximum))))

\\ Input bytes, nodes, captures, matches, result payload bytes, timeout ms, query bytes.
(define treesitter.options
  Options ->
    (treesitter.options-loop Options
      (treesitter.record [8388608 262144 65536 65536 67108864 30000 1048576]) []))

(define treesitter.options-loop
  [] Config _ -> Config
  [[Key Value] | Rest] Config Seen ->
    (if (element? Key Seen)
        (error "treesitter: repeated option ~A" Key)
        (treesitter.options-loop Rest (treesitter.option Key Value Config) [Key | Seen]))
  _ _ _ -> (error "treesitter: options must be [name value] pairs"))

(define treesitter.option
  input-limit N C -> (address-> C 0 (treesitter.limit N 268435456 false))
  node-limit N C -> (address-> C 1 (treesitter.limit N 4194304 true))
  capture-limit N C -> (address-> C 2 (treesitter.limit N 1048576 false))
  match-limit N C -> (address-> C 3 (treesitter.limit N 1048576 true))
  result-limit N C -> (address-> C 4 (treesitter.limit N 536870912 false))
  timeout N C -> (address-> C 5 (treesitter.limit N 2147483647 false))
  query-limit N C -> (address-> C 6 (treesitter.limit N 16777216 false))
  Key _ _ -> (error "treesitter: unknown option ~A" Key))

(define treesitter.parse
  Language Input Options -> (treesitter.analyze Language Input [] (treesitter.options Options)))

(define treesitter.query
  Language Input Query Options ->
    (if (string? Query)
        (treesitter.analyze Language Input Query (treesitter.options Options))
        (error "treesitter: query must be a string")))

(define treesitter.analyze
  Language Input Query Config ->
    (let Name (treesitter.language-name Language)
         N (buffer.length Input)
      (cond ((> N (<-address Config 0))
              [error (treesitter.error parse limit 0 0 Name "source exceeds input byte limit")])
            ((and (string? Query) (> (treesitter.byte-length Query) (<-address Config 6)))
              [error (treesitter.error query limit 0 0 Name "query exceeds query byte limit")])
            (true
              (let View (if (shen-jit.pointer? (buffer.owner Input))
                            (buffer.wrap (buffer.bytes Input)) Input)
                   Op (if (= Query []) parse query)
                (trap-error
                  (do (treesitter.abi)
                      (let Raw (treesitter.c-parse (eval-kl [(<-address Language 2)])
                                  (treesitter.record [(buffer.owner View) (buffer.offset View)
                                                      N Query Config]))
                        (if (number? (<-address Raw 0))
                            (treesitter.native-error Op Name Raw)
                            [ok (treesitter.record [treesitter.snapshot Name Raw])])))
                  (/. X (treesitter.foreign-error Op Name X))))))))

(define treesitter.snapshot-check
  Snapshot ->
    (if (treesitter.tag? Snapshot treesitter.snapshot)
        (<-address Snapshot 2)
        (error "treesitter: not a snapshot")))

(define treesitter.node-count
  Snapshot -> (/ (shen-jit.bytes-length (<-address (treesitter.snapshot-check Snapshot) 1)) 48))

(define treesitter.root
  Snapshot -> (do (treesitter.snapshot-check Snapshot) 1))

(define treesitter.node-word
  Snapshot Node Field ->
    (let Raw (treesitter.snapshot-check Snapshot)
         ID (buffer.index Node)
         Count (/ (shen-jit.bytes-length (<-address Raw 1)) 48)
      (if (and (> ID 0) (<= ID Count))
          (shen-jit.u32 (<-address Raw 1) (+ (* (- ID 1) 48) (* Field 4)))
          (error "treesitter: node ~A is outside this snapshot" ID))))

(define treesitter.parent
  Snapshot Node -> (treesitter.node-word Snapshot Node 0))

(define treesitter.first-child
  Snapshot Node -> (treesitter.node-word Snapshot Node 1))

(define treesitter.next-sibling
  Snapshot Node -> (treesitter.node-word Snapshot Node 2))

(define treesitter.kind
  Snapshot Node ->
    (<-address (<-address (treesitter.snapshot-check Snapshot) 2) (treesitter.node-word Snapshot Node 3)))

(define treesitter.field
  Snapshot Node ->
    (<-address (<-address (treesitter.snapshot-check Snapshot) 3) (treesitter.node-word Snapshot Node 4)))

(define treesitter.flag?
  Snapshot Node Mask -> (not (= (shen-jit.bit-and (treesitter.node-word Snapshot Node 5) Mask) 0)))

(define treesitter.named?
  Snapshot Node -> (treesitter.flag? Snapshot Node 1))

(define treesitter.missing?
  Snapshot Node -> (treesitter.flag? Snapshot Node 2))

(define treesitter.error?
  Snapshot Node -> (treesitter.flag? Snapshot Node 4))

(define treesitter.has-error?
  Snapshot Node -> (treesitter.flag? Snapshot Node 8))

(define treesitter.extra?
  Snapshot Node -> (treesitter.flag? Snapshot Node 16))

(define treesitter.start-byte
  Snapshot Node -> (treesitter.node-word Snapshot Node 6))

(define treesitter.end-byte
  Snapshot Node -> (treesitter.node-word Snapshot Node 7))

(define treesitter.start-point
  Snapshot Node -> [(treesitter.node-word Snapshot Node 8) (treesitter.node-word Snapshot Node 9)])

(define treesitter.end-point
  Snapshot Node -> [(treesitter.node-word Snapshot Node 10) (treesitter.node-word Snapshot Node 11)])

(define treesitter.source
  Snapshot -> (buffer.wrap (buffer.bytes (buffer.wrap (<-address (treesitter.snapshot-check Snapshot) 0)))))

(define treesitter.text
  Snapshot Node ->
    (let Start (treesitter.start-byte Snapshot Node)
         End (treesitter.end-byte Snapshot Node)
      (shen-jit.bytes->string (<-address (treesitter.snapshot-check Snapshot) 0) Start (- End Start))))

(define treesitter.children
  Snapshot Node -> (treesitter.siblings Snapshot (treesitter.first-child Snapshot Node) []))

(define treesitter.siblings
  _ 0 Acc -> (reverse Acc)
  Snapshot Node Acc -> (treesitter.siblings Snapshot (treesitter.next-sibling Snapshot Node) [Node | Acc]))

(define treesitter.child-by-field
  Snapshot Node Field -> (treesitter.find-field Snapshot (treesitter.first-child Snapshot Node) Field))

(define treesitter.find-field
  _ 0 _ -> 0
  Snapshot Node Field ->
    (if (= (treesitter.field Snapshot Node) Field)
        Node
        (treesitter.find-field Snapshot (treesitter.next-sibling Snapshot Node) Field)))

(define treesitter.fold
  F Acc Snapshot -> (treesitter.fold-loop F Acc Snapshot 1 (treesitter.node-count Snapshot)))

(define treesitter.fold-loop
  _ Acc _ At End -> Acc where (> At End)
  F Acc Snapshot At End -> (treesitter.fold-loop F (F Acc At) Snapshot (+ At 1) End))

\\ Captures are in match order; IDs within each snapshot are one-based, patterns are zero-based.
(define treesitter.capture-count
  Snapshot -> (/ (shen-jit.bytes-length (<-address (treesitter.snapshot-check Snapshot) 4)) 16))

(define treesitter.match-count
  Snapshot -> (<-address (treesitter.snapshot-check Snapshot) 6))

(define treesitter.capture-word
  Snapshot Capture Field ->
    (let Raw (treesitter.snapshot-check Snapshot)
         ID (buffer.index Capture)
         Count (/ (shen-jit.bytes-length (<-address Raw 4)) 16)
      (if (and (> ID 0) (<= ID Count))
          (shen-jit.u32 (<-address Raw 4) (+ (* (- ID 1) 16) (* Field 4)))
          (error "treesitter: capture ~A is outside this snapshot" ID))))

(define treesitter.capture-match
  Snapshot Capture -> (treesitter.capture-word Snapshot Capture 0))

(define treesitter.capture-pattern
  Snapshot Capture -> (treesitter.capture-word Snapshot Capture 1))

(define treesitter.capture-name
  Snapshot Capture ->
    (<-address (<-address (treesitter.snapshot-check Snapshot) 5)
               (treesitter.capture-word Snapshot Capture 2)))

(define treesitter.capture-node
  Snapshot Capture -> (treesitter.capture-word Snapshot Capture 3))

(datatype treesitter-results
  X : A;
  ============================
  [ok X] : (treesitter.result A);

  E : treesitter.error;
  ============================
  [error E] : (treesitter.result A);)

(datatype treesitter-options
  Key : symbol; N : number;
  ============================
  [Key N] : treesitter.option;)

(declare treesitter.load-language
  [string --> [[list string] --> [string --> [treesitter.result treesitter.language]]]])
(declare treesitter.language-name [treesitter.language --> string])
(declare treesitter.language-version [treesitter.language --> number])
(declare treesitter.parse
  [treesitter.language --> [buffer.view --> [[list treesitter.option] -->
    [treesitter.result treesitter.snapshot]]]])
(declare treesitter.query
  [treesitter.language --> [buffer.view --> [string --> [[list treesitter.option] -->
    [treesitter.result treesitter.snapshot]]]]])
(declare treesitter.node-count [treesitter.snapshot --> number])
(declare treesitter.root [treesitter.snapshot --> number])
(declare treesitter.parent [treesitter.snapshot --> [number --> number]])
(declare treesitter.first-child [treesitter.snapshot --> [number --> number]])
(declare treesitter.next-sibling [treesitter.snapshot --> [number --> number]])
(declare treesitter.kind [treesitter.snapshot --> [number --> string]])
(declare treesitter.field [treesitter.snapshot --> [number --> string]])
(declare treesitter.named? [treesitter.snapshot --> [number --> boolean]])
(declare treesitter.missing? [treesitter.snapshot --> [number --> boolean]])
(declare treesitter.error? [treesitter.snapshot --> [number --> boolean]])
(declare treesitter.has-error? [treesitter.snapshot --> [number --> boolean]])
(declare treesitter.extra? [treesitter.snapshot --> [number --> boolean]])
(declare treesitter.start-byte [treesitter.snapshot --> [number --> number]])
(declare treesitter.end-byte [treesitter.snapshot --> [number --> number]])
(declare treesitter.start-point [treesitter.snapshot --> [number --> [list number]]])
(declare treesitter.end-point [treesitter.snapshot --> [number --> [list number]]])
(declare treesitter.source [treesitter.snapshot --> buffer.view])
(declare treesitter.text [treesitter.snapshot --> [number --> string]])
(declare treesitter.children [treesitter.snapshot --> [number --> [list number]]])
(declare treesitter.child-by-field [treesitter.snapshot --> [number --> [string --> number]]])
(declare treesitter.fold [[A --> [number --> A]] --> [A --> [treesitter.snapshot --> A]]])
(declare treesitter.capture-count [treesitter.snapshot --> number])
(declare treesitter.match-count [treesitter.snapshot --> number])
(declare treesitter.capture-match [treesitter.snapshot --> [number --> number]])
(declare treesitter.capture-pattern [treesitter.snapshot --> [number --> number]])
(declare treesitter.capture-name [treesitter.snapshot --> [number --> string]])
(declare treesitter.capture-node [treesitter.snapshot --> [number --> number]])
(declare treesitter.error-operation [treesitter.error --> symbol])
(declare treesitter.error-domain [treesitter.error --> symbol])
(declare treesitter.error-code [treesitter.error --> number])
(declare treesitter.error-offset [treesitter.error --> number])
(declare treesitter.error-resource [treesitter.error --> string])
(declare treesitter.error-message [treesitter.error --> string])
