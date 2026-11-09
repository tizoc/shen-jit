\\ Tree-sitter complete-input snapshots and structural queries. Load after ffi.shen and buffer.shen.
\\ Native trees are closed before returning; snapshots own managed source, records and name tables.

(shen.x.namespace treesitter
  (use buffer)
  (use shen-jit)
  (externals [capture-limit define-foreign define-foreign-procedure input-limit load-language
    match-limit native node-limit ok parse pointer predicate query query-limit result-limit
    timeout treesitter-error treesitter-options treesitter-results uint32])
  (export *adapter-files* capture-count capture-match capture-name capture-node capture-pattern
    child-by-field children end-byte end-point treesitter.error => error error-code error-domain
    error-message error-offset error-operation error-resource error? extra? field first-child
    fold has-error? kind treesitter.language => language language-name language-version
    treesitter.load-language => load-language match-count missing? named? next-sibling node-count
    option parent treesitter.parse => parse treesitter.query => query result root snapshot source
    start-byte start-point text)

(if (bound? *adapter-files*) true
    (set *adapter-files*
      ["./build/shen-tree-sitter.so" "./lib/shen-tree-sitter.so" "./shen-tree-sitter.so"
       "./build/shen-tree-sitter.dll" "./lib/shen-tree-sitter.dll" "./shen-tree-sitter.dll"]))

(shen-jit.library adapter (value *adapter-files*))
(define-foreign c-abi adapter "shen_treesitter_abi" () --> uint32)
(define-foreign-procedure c-language adapter "shen_treesitter_language" 1)
(define-foreign-procedure c-parse adapter "shen_treesitter_parse" 2)

(define record
  Fields -> (fill (absvector (length Fields)) 0 Fields))

(define fill
  V _ [] -> V
  V At [X | Rest] -> (fill (address-> V At X) (+ At 1) Rest))

(define tag?
  V Tag -> (trap-error (and (absvector? V) (= (<-address V 0) Tag)) (/. E false)))

(define abi
  -> (if (= (c-abi) 1) true (error "treesitter: incompatible adapter; rebuild it")))

(define text-argument
  Text ->
    (let _ (if (string? Text) true (error "treesitter: expected a string"))
         Bytes (shen-jit.string->bytes Text)
         N (shen-jit.bytes-length Bytes)
      (if (and (> N 0) (<= N 1048576) (no-nul? Bytes 0 N))
          Text
          (error "treesitter: expected 1..1048576 NUL-free bytes"))))

(define byte-length
  Text -> (shen-jit.bytes-length (shen-jit.string->bytes Text)))

(define no-nul?
  _ End End -> true
  Bytes At End ->
    (and (not (= (shen-jit.u8 Bytes At) 0)) (no-nul? Bytes (+ At 1) End)))

(define files
  [] -> []
  [File | Rest] -> [(text-argument File) | (files Rest)]
  _ -> (error "treesitter: grammar files must be a list of strings"))

(define treesitter.error
  Op Domain Code Offset Resource Message -> [treesitter-error Op Domain Code Offset Resource Message])

(define error-operation
  [treesitter-error Op _ _ _ _ _] -> Op)

(define error-domain
  [treesitter-error _ Domain _ _ _ _] -> Domain)

(define error-code
  [treesitter-error _ _ Code _ _ _] -> Code)

(define error-offset
  [treesitter-error _ _ _ Offset _ _] -> Offset)

(define error-resource
  [treesitter-error _ _ _ _ Resource _] -> Resource)

(define error-message
  [treesitter-error _ _ _ _ _ Message] -> Message)

(define domain
  1 -> native
  2 -> timeout
  3 -> limit
  4 -> query
  5 -> predicate
  6 -> language)

(define native-error
  Op Resource Raw ->
    [error (treesitter.error Op (domain (<-address Raw 0)) (<-address Raw 1)
                            (<-address Raw 2) Resource (<-address Raw 3))])

(define foreign-error
  Op Resource Exception ->
    [error (treesitter.error Op foreign 0 0 Resource (error-to-string Exception))])

\\ A language stores its FFI entry name, not a native address. It reopens correctly in saved images.
(define treesitter.load-language
  Name Files Entry ->
    (let _ (text-argument Name)
         Paths (files Files)
         _ (if (= Paths []) (error "treesitter: supply grammar library files") true)
         _ (text-argument Entry)
         Function (gensym grammar.)
         _ (shen-jit.library Function Paths)
         _ (shen-jit.ffi.define Function Function Entry [] pointer false 0)
      (trap-error
        (do (abi)
            (let Raw (c-language (eval-kl [Function]))
              (if (number? Raw)
                  [ok (record [treesitter.language Name Function Raw])]
                  (native-error load-language Name Raw))))
        (/. X (foreign-error load-language Name X)))))

(define language-check
  Language ->
    (if (tag? Language treesitter.language)
        Language
        (error "treesitter: not a language")))

(define language-name
  Language -> (<-address (language-check Language) 1))

(define language-version
  Language -> (<-address (language-check Language) 3))

(define treesitter.limit
  N Maximum Positive ->
    (let I (buffer.index N)
      (if (and (<= I Maximum) (or (not Positive) (> I 0)))
          I
          (error "treesitter: limit must be ~A..~A" (if Positive 1 0) Maximum))))

\\ Input bytes, nodes, captures, matches, result payload bytes, timeout ms, query bytes.
(define options
  Options ->
    (options-loop Options
      (record [8388608 262144 65536 65536 67108864 30000 1048576]) []))

(define options-loop
  [] Config _ -> Config
  [[Key Value] | Rest] Config Seen ->
    (if (element? Key Seen)
        (error "treesitter: repeated option ~A" Key)
        (options-loop Rest (option Key Value Config) [Key | Seen]))
  _ _ _ -> (error "treesitter: options must be [name value] pairs"))

(define option
  input-limit N C -> (address-> C 0 (treesitter.limit N 268435456 false))
  node-limit N C -> (address-> C 1 (treesitter.limit N 4194304 true))
  capture-limit N C -> (address-> C 2 (treesitter.limit N 1048576 false))
  match-limit N C -> (address-> C 3 (treesitter.limit N 1048576 true))
  result-limit N C -> (address-> C 4 (treesitter.limit N 536870912 false))
  timeout N C -> (address-> C 5 (treesitter.limit N 2147483647 false))
  query-limit N C -> (address-> C 6 (treesitter.limit N 16777216 false))
  Key _ _ -> (error "treesitter: unknown option ~A" Key))

(define treesitter.parse
  Language Input Options -> (analyze Language Input [] (options Options)))

(define treesitter.query
  Language Input Query Options ->
    (if (string? Query)
        (analyze Language Input Query (options Options))
        (error "treesitter: query must be a string")))

(define analyze
  Language Input Query Config ->
    (let Name (language-name Language)
         N (buffer.length Input)
      (cond ((> N (<-address Config 0))
              [error (treesitter.error parse limit 0 0 Name "source exceeds input byte limit")])
            ((and (string? Query) (> (byte-length Query) (<-address Config 6)))
              [error (treesitter.error query limit 0 0 Name "query exceeds query byte limit")])
            (true
              (let View (if (shen-jit.pointer? (buffer.owner Input))
                            (buffer.wrap (buffer.bytes Input)) Input)
                   Op (if (= Query []) parse query)
                (trap-error
                  (do (abi)
                      (let Raw (c-parse (eval-kl [(<-address Language 2)])
                                  (record [(buffer.owner View) (buffer.offset View)
                                                      N Query Config]))
                        (if (number? (<-address Raw 0))
                            (native-error Op Name Raw)
                            [ok (record [snapshot Name Raw])])))
                  (/. X (foreign-error Op Name X))))))))

(define snapshot-check
  Snapshot ->
    (if (tag? Snapshot snapshot)
        (<-address Snapshot 2)
        (error "treesitter: not a snapshot")))

(define node-count
  Snapshot -> (/ (shen-jit.bytes-length (<-address (snapshot-check Snapshot) 1)) 48))

(define root
  Snapshot -> (do (snapshot-check Snapshot) 1))

(define node-word
  Snapshot Node Field ->
    (let Raw (snapshot-check Snapshot)
         ID (buffer.index Node)
         Count (/ (shen-jit.bytes-length (<-address Raw 1)) 48)
      (if (and (> ID 0) (<= ID Count))
          (shen-jit.u32 (<-address Raw 1) (+ (* (- ID 1) 48) (* Field 4)))
          (error "treesitter: node ~A is outside this snapshot" ID))))

(define parent
  Snapshot Node -> (node-word Snapshot Node 0))

(define first-child
  Snapshot Node -> (node-word Snapshot Node 1))

(define next-sibling
  Snapshot Node -> (node-word Snapshot Node 2))

(define kind
  Snapshot Node ->
    (<-address (<-address (snapshot-check Snapshot) 2) (node-word Snapshot Node 3)))

(define field
  Snapshot Node ->
    (<-address (<-address (snapshot-check Snapshot) 3) (node-word Snapshot Node 4)))

(define flag?
  Snapshot Node Mask -> (not (= (shen-jit.bit-and (node-word Snapshot Node 5) Mask) 0)))

(define named?
  Snapshot Node -> (flag? Snapshot Node 1))

(define missing?
  Snapshot Node -> (flag? Snapshot Node 2))

(define error?
  Snapshot Node -> (flag? Snapshot Node 4))

(define has-error?
  Snapshot Node -> (flag? Snapshot Node 8))

(define extra?
  Snapshot Node -> (flag? Snapshot Node 16))

(define start-byte
  Snapshot Node -> (node-word Snapshot Node 6))

(define end-byte
  Snapshot Node -> (node-word Snapshot Node 7))

(define start-point
  Snapshot Node -> [(node-word Snapshot Node 8) (node-word Snapshot Node 9)])

(define end-point
  Snapshot Node -> [(node-word Snapshot Node 10) (node-word Snapshot Node 11)])

(define source
  Snapshot -> (buffer.wrap (buffer.bytes (buffer.wrap (<-address (snapshot-check Snapshot) 0)))))

(define text
  Snapshot Node ->
    (let Start (start-byte Snapshot Node)
         End (end-byte Snapshot Node)
      (shen-jit.bytes->string (<-address (snapshot-check Snapshot) 0) Start (- End Start))))

(define children
  Snapshot Node -> (siblings Snapshot (first-child Snapshot Node) []))

(define siblings
  _ 0 Acc -> (reverse Acc)
  Snapshot Node Acc -> (siblings Snapshot (next-sibling Snapshot Node) [Node | Acc]))

(define child-by-field
  Snapshot Node Field -> (find-field Snapshot (first-child Snapshot Node) Field))

(define find-field
  _ 0 _ -> 0
  Snapshot Node Field ->
    (if (= (field Snapshot Node) Field)
        Node
        (find-field Snapshot (next-sibling Snapshot Node) Field)))

(define fold
  F Acc Snapshot -> (fold-loop F Acc Snapshot 1 (node-count Snapshot)))

(define fold-loop
  _ Acc _ At End -> Acc where (> At End)
  F Acc Snapshot At End -> (fold-loop F (F Acc At) Snapshot (+ At 1) End))

\\ Captures are in match order; IDs within each snapshot are one-based, patterns are zero-based.
(define capture-count
  Snapshot -> (/ (shen-jit.bytes-length (<-address (snapshot-check Snapshot) 4)) 16))

(define match-count
  Snapshot -> (<-address (snapshot-check Snapshot) 6))

(define capture-word
  Snapshot Capture Field ->
    (let Raw (snapshot-check Snapshot)
         ID (buffer.index Capture)
         Count (/ (shen-jit.bytes-length (<-address Raw 4)) 16)
      (if (and (> ID 0) (<= ID Count))
          (shen-jit.u32 (<-address Raw 4) (+ (* (- ID 1) 16) (* Field 4)))
          (error "treesitter: capture ~A is outside this snapshot" ID))))

(define capture-match
  Snapshot Capture -> (capture-word Snapshot Capture 0))

(define capture-pattern
  Snapshot Capture -> (capture-word Snapshot Capture 1))

(define capture-name
  Snapshot Capture ->
    (<-address (<-address (snapshot-check Snapshot) 5)
               (capture-word Snapshot Capture 2)))

(define capture-node
  Snapshot Capture -> (capture-word Snapshot Capture 3))

(datatype treesitter-results
  X : A;
  ============================
  [ok X] : (result A);

  E : treesitter.error;
  ============================
  [error E] : (result A);)

(datatype treesitter-options
  Key : symbol; N : number;
  ============================
  [Key N] : option;)

(declare treesitter.load-language
  [string --> [[list string] --> [string --> [result treesitter.language]]]])
(declare language-name [treesitter.language --> string])
(declare language-version [treesitter.language --> number])
(declare treesitter.parse
  [treesitter.language --> [buffer.view --> [[list option] -->
    [result snapshot]]]])
(declare treesitter.query
  [treesitter.language --> [buffer.view --> [string --> [[list option] -->
    [result snapshot]]]]])
(declare node-count [snapshot --> number])
(declare root [snapshot --> number])
(declare parent [snapshot --> [number --> number]])
(declare first-child [snapshot --> [number --> number]])
(declare next-sibling [snapshot --> [number --> number]])
(declare kind [snapshot --> [number --> string]])
(declare field [snapshot --> [number --> string]])
(declare named? [snapshot --> [number --> boolean]])
(declare missing? [snapshot --> [number --> boolean]])
(declare error? [snapshot --> [number --> boolean]])
(declare has-error? [snapshot --> [number --> boolean]])
(declare extra? [snapshot --> [number --> boolean]])
(declare start-byte [snapshot --> [number --> number]])
(declare end-byte [snapshot --> [number --> number]])
(declare start-point [snapshot --> [number --> [list number]]])
(declare end-point [snapshot --> [number --> [list number]]])
(declare source [snapshot --> buffer.view])
(declare text [snapshot --> [number --> string]])
(declare children [snapshot --> [number --> [list number]]])
(declare child-by-field [snapshot --> [number --> [string --> number]]])
(declare fold [[A --> [number --> A]] --> [A --> [snapshot --> A]]])
(declare capture-count [snapshot --> number])
(declare match-count [snapshot --> number])
(declare capture-match [snapshot --> [number --> number]])
(declare capture-pattern [snapshot --> [number --> number]])
(declare capture-name [snapshot --> [number --> string]])
(declare capture-node [snapshot --> [number --> number]])
(declare error-operation [treesitter.error --> symbol])
(declare error-domain [treesitter.error --> symbol])
(declare error-code [treesitter.error --> number])
(declare error-offset [treesitter.error --> number])
(declare error-resource [treesitter.error --> string])
(declare error-message [treesitter.error --> string])

)
