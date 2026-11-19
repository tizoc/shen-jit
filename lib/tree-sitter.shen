\\ Tree-sitter complete-input snapshots and structural queries. Module tree-sitter.
\\ Native trees are closed before returning; snapshots own managed source, records and name tables.

(shen.x.namespace treesitter
  (use buffer)
  (use result)
  (import result ok err)
  (use shen-jit)
  (import struct defstruct)
  (externals [capture-limit define-foreign define-foreign-procedure input-limit load-language
    match-limit native node-limit parse pointer predicate query query-limit result-limit timeout
    uint32])
  (export *adapter-files* capture-count capture-match capture-name capture-node capture-pattern
    child-by-field children end-byte end-point treesitter.error => error error-code error-domain
    error-message error-offset error-operation error-resource error? extra? field first-child
    fold has-error? kind treesitter.language => language language-name language-version
    treesitter.load-language => load-language match-count missing? named? next-sibling node-count node-error?
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

\\ The adapter reads a configuration and a parse's input by position: they stay vectors.
(define record
  Fields -> (fill (absvector (length Fields)) 0 Fields))

(define fill
  V _ [] -> V
  V At [X | Rest] -> (fill (address-> V At X) (+ At 1) Rest))

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

(defstruct treesitter.error
  (operation : symbol)
  (domain : symbol)
  (code : number)
  (offset : fixnum)
  (resource : string)
  (message : string))

(define domain
  1 -> native
  2 -> timeout
  3 -> limit
  4 -> query
  5 -> predicate
  6 -> language)

(define native-error
  Op Resource Raw ->
    (:err (treesitter.error Op (domain (<-address Raw 0)) (<-address Raw 1)
                            (<-address Raw 2) Resource (<-address Raw 3))))

(define foreign-error
  Op Resource Exception ->
    (:err (treesitter.error Op foreign 0 0 Resource (error-to-string Exception))))

\\ A language stores its FFI entry name, not a native address. It reopens correctly in saved images,
\\ and crosses to isolates, which call the entry by its name, as they cannot evaluate.
(defstruct treesitter.language
  (name : string)
  (entry : symbol)
  (version : number))

(preclude [treesitter.language.%match])

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
            (let Raw (c-language (shen-jit.apply Function []))
              (if (number? Raw)
                  (:ok (language.make Name Function Raw))
                  (native-error load-language Name Raw))))
        (/. X (foreign-error load-language Name X)))))

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

\\ A snapshot: its language's name, and what the adapter gave: the source, nodes, kind and field
\\ names, captures, capture names and the match count.
(define show-snapshot
  S -> (make-string "#<snapshot ~S>" (snapshot.language S)))

(defstruct snapshot
  (printer show-snapshot)
  (language : string)
  (source-bytes : buffer.storage)
  (nodes : buffer.storage)
  (node-count : fixnum)
  (kinds : name-table)
  (fields : name-table)
  (captures : buffer.storage)
  (capture-count : fixnum)
  (capture-names : name-table)
  (matches : number))

(preclude [snapshot.%match])

\\ Decode the fixed native result once and keep the managed byte and name tables.
(define read-snapshot
  Name Raw ->
    (let Nodes (<-address Raw 1)
         Captures (<-address Raw 4)
      (:snapshot
        language <- Name
        source-bytes <- (<-address Raw 0)
        nodes <- Nodes
        node-count <- (fxquotient (shen-jit.bytes-length Nodes) 48)
        kinds <- (<-address Raw 2)
        fields <- (<-address Raw 3)
        captures <- Captures
        capture-count <- (fxquotient (shen-jit.bytes-length Captures) 16)
        capture-names <- (<-address Raw 5)
        matches <- (<-address Raw 6))))

\\ Names remain in the zero-based vector the native adapter populated with strings.
(define name-at
  Table Index -> (<-address Table Index))

(declare name-at [name-table --> [fixnum --> string]])

(define analyze
  Language Input Query Config ->
    (let Name (language-name Language)
         N (buffer.length Input)
      (cond ((> N (<-address Config 0))
              (:err (treesitter.error parse limit 0 0 Name "source exceeds input byte limit")))
            ((and (string? Query) (> (byte-length Query) (<-address Config 6)))
              (:err (treesitter.error query limit 0 0 Name "query exceeds query byte limit")))
            (true
              (let View (if (shen-jit.pointer? (buffer.owner Input))
                            (buffer.wrap (buffer.bytes Input)) Input)
                   Op (if (= Query []) parse query)
                (trap-error
                  (do (abi)
                      (let Raw (c-parse (shen-jit.apply (language.entry Language) [])
                                  (record [(buffer.owner View) (buffer.offset View)
                                                      N Query Config]))
                        (if (number? (<-address Raw 0))
                            (native-error Op Name Raw)
                            (:ok (read-snapshot Name Raw)))))
                  (/. X (foreign-error Op Name X))))))))

\\ A result, (result A), is (result.t (treesitter.error * A)), which the library declares in the long
\\ form, as declare keeps a type as it is written.
(synonyms (result A) (result.t (treesitter.error * A)))

(datatype t
  if (element? Key [input-limit result-limit query-limit])
  Key : symbol; N : fixnum;
  ____________________________
  [Key N] : option;

  if (element? Key [node-limit capture-limit match-limit timeout])
  Key : symbol; N : number;
  ____________________________
  [Key N] : option;)

(declare treesitter.load-language
  [string --> [[list string] --> [string --> [result.t [treesitter.error * treesitter.language]]]]])
(declare treesitter.parse
  [treesitter.language --> [buffer.view --> [[list option] -->
    [result.t [treesitter.error * snapshot]]]]])
(declare treesitter.query
  [treesitter.language --> [buffer.view --> [string --> [[list option] -->
    [result.t [treesitter.error * snapshot]]]]]])

)
