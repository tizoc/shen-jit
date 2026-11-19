\\ Checked error accessors and interpretation of the native snapshot tables.
(shen.x.namespace treesitter
  (use buffer)
  (use result)
  (import result ok err)
  (use shen-jit)
  (import struct defstruct)
  (externals [capture-limit define-foreign define-foreign-procedure input-limit load-language
    match-limit native node-limit parse pointer predicate query query-limit result-limit timeout
    uint32])
  (export treesitter.error => error error-operation error-domain error-code error-offset
    error-resource error-message parent first-child next-sibling named? missing? node-error?
    has-error? extra? start-byte end-byte start-point end-point children child-by-field fold
    capture-match capture-pattern capture-node capture-count capture-name field kind
    language-name language-version match-count node-count root source text)

(define treesitter.error
  {symbol --> symbol --> number --> fixnum --> string --> string --> treesitter.error}
  Op Domain Code Offset Resource Message ->
    (treesitter.error.make Op Domain Code Offset Resource Message))

(define error-check
  {treesitter.error --> treesitter.error}
  Error -> (if (treesitter.error? Error) Error (error "treesitter: not an error")))

(define error-operation
  {treesitter.error --> symbol}
  Error -> (treesitter.error.operation (error-check Error)))

(define error-domain
  {treesitter.error --> symbol}
  Error -> (treesitter.error.domain (error-check Error)))

(define error-code
  {treesitter.error --> number}
  Error -> (treesitter.error.code (error-check Error)))

(define error-offset
  {treesitter.error --> fixnum}
  Error -> (treesitter.error.offset (error-check Error)))

(define error-resource
  {treesitter.error --> string}
  Error -> (treesitter.error.resource (error-check Error)))

(define error-message
  {treesitter.error --> string}
  Error -> (treesitter.error.message (error-check Error)))

(define language-check
  {treesitter.language --> treesitter.language}
  Language ->
    (if (language? Language) Language (error "treesitter: not a language")))

(define language-name
  {treesitter.language --> string}
  Language -> (language.name (language-check Language)))

(define language-version
  {treesitter.language --> number}
  Language -> (language.version (language-check Language)))

(define snapshot-check
  {snapshot --> snapshot}
  Snapshot ->
    (if (snapshot? Snapshot) Snapshot (error "treesitter: not a snapshot")))

(define node-count
  {snapshot --> number}
  Snapshot -> (fx->number (snapshot.node-count (snapshot-check Snapshot))))

(define root
  {snapshot --> number}
  Snapshot -> (do (snapshot-check Snapshot) 1))

\\ Check the one-based row before reading a little-endian word.
(define node-word
  {snapshot --> number --> fixnum --> fixnum}
  Snapshot Node Field ->
    (node-word-at (snapshot-check Snapshot) Node Field))

(define node-word-at
  {snapshot --> number --> fixnum --> fixnum}
  S Node Field ->
    (let ID (fixnum Node)
      (if (and (fx> ID 0) (fx<= ID (snapshot.node-count S)))
          (shen-jit.u32 (snapshot.nodes S) (fx+ (fx* (fx- ID 1) 48) (fx* Field 4)))
          (error "treesitter: node ~A is outside this snapshot" ID))))

(define kind
  {snapshot --> number --> string}
  Snapshot Node ->
    (let S (snapshot-check Snapshot)
      (name-at (snapshot.kinds S) (node-word-at S Node 3))))

(define field
  {snapshot --> number --> string}
  Snapshot Node ->
    (let S (snapshot-check Snapshot)
      (name-at (snapshot.fields S) (node-word-at S Node 4))))

(define source
  {snapshot --> buffer.view}
  Snapshot ->
    (buffer.wrap (buffer.bytes (buffer.wrap (snapshot.source-bytes (snapshot-check Snapshot))))))

(define text
  {snapshot --> number --> string}
  Snapshot Node ->
    (let S (snapshot-check Snapshot)
         Start (node-word-at S Node 6)
         End (node-word-at S Node 7)
      (shen-jit.bytes->string (snapshot.source-bytes S) Start (fx- End Start))))

\\ Captures are in match order. Row IDs are one-based, and patterns are zero-based.
(define capture-count
  {snapshot --> number}
  Snapshot -> (fx->number (snapshot.capture-count (snapshot-check Snapshot))))

(define match-count
  {snapshot --> number}
  Snapshot -> (snapshot.matches (snapshot-check Snapshot)))

(define capture-word
  {snapshot --> number --> fixnum --> fixnum}
  Snapshot Capture Field ->
    (capture-word-at (snapshot-check Snapshot) Capture Field))

(define capture-word-at
  {snapshot --> number --> fixnum --> fixnum}
  S Capture Field ->
    (let ID (fixnum Capture)
      (if (and (fx> ID 0) (fx<= ID (snapshot.capture-count S)))
          (shen-jit.u32 (snapshot.captures S) (fx+ (fx* (fx- ID 1) 16) (fx* Field 4)))
          (error "treesitter: capture ~A is outside this snapshot" ID))))

(define capture-name
  {snapshot --> number --> string}
  Snapshot Capture ->
    (let S (snapshot-check Snapshot)
      (name-at (snapshot.capture-names S) (capture-word-at S Capture 2))))

(define parent
  {snapshot --> number --> number}
  Snapshot Node -> (fx->number (node-word Snapshot Node 0)))

(define first-child
  {snapshot --> number --> number}
  Snapshot Node -> (fx->number (node-word Snapshot Node 1)))

(define next-sibling
  {snapshot --> number --> number}
  Snapshot Node -> (fx->number (node-word Snapshot Node 2)))

(define named?
  {snapshot --> number --> boolean}
  Snapshot Node -> (flag? Snapshot Node 1))

(define missing?
  {snapshot --> number --> boolean}
  Snapshot Node -> (flag? Snapshot Node 2))

(define node-error?
  {snapshot --> number --> boolean}
  Snapshot Node -> (flag? Snapshot Node 4))

(define has-error?
  {snapshot --> number --> boolean}
  Snapshot Node -> (flag? Snapshot Node 8))

(define extra?
  {snapshot --> number --> boolean}
  Snapshot Node -> (flag? Snapshot Node 16))

(define start-byte
  {snapshot --> number --> fixnum}
  Snapshot Node -> (node-word Snapshot Node 6))

(define end-byte
  {snapshot --> number --> fixnum}
  Snapshot Node -> (node-word Snapshot Node 7))

(define start-point
  {snapshot --> number --> (list number)}
  Snapshot Node -> [(fx->number (node-word Snapshot Node 8)) (fx->number (node-word Snapshot Node 9))])

(define end-point
  {snapshot --> number --> (list number)}
  Snapshot Node -> [(fx->number (node-word Snapshot Node 10)) (fx->number (node-word Snapshot Node 11))])

(define children
  {snapshot --> number --> (list number)}
  Snapshot Node -> (siblings Snapshot (first-child Snapshot Node) []))

(define capture-match
  {snapshot --> number --> number}
  Snapshot Capture -> (fx->number (capture-word Snapshot Capture 0)))

(define capture-pattern
  {snapshot --> number --> number}
  Snapshot Capture -> (fx->number (capture-word Snapshot Capture 1)))

(define capture-node
  {snapshot --> number --> number}
  Snapshot Capture -> (fx->number (capture-word Snapshot Capture 3)))

(define flag?
  {snapshot --> number --> fixnum --> boolean}
  Snapshot Node Mask -> (not (= (shen-jit.bit-and (node-word Snapshot Node 5) Mask) 0)))

(define siblings
  {snapshot --> number --> (list number) --> (list number)}
  _ 0 Acc -> (reverse Acc)
  Snapshot Node Acc -> (siblings Snapshot (next-sibling Snapshot Node) [Node | Acc]))

(define child-by-field
  {snapshot --> number --> string --> number}
  Snapshot Node Field -> (find-field Snapshot (first-child Snapshot Node) Field))

(define find-field
  {snapshot --> number --> string --> number}
  _ 0 _ -> 0
  Snapshot Node Field ->
    (if (= (field Snapshot Node) Field)
        Node
        (find-field Snapshot (next-sibling Snapshot Node) Field)))

(define fold
  {(A --> number --> A) --> A --> snapshot --> A}
  F Acc Snapshot -> (fold-loop F Acc Snapshot 1 (node-count Snapshot)))

(define fold-loop
  {(A --> number --> A) --> A --> snapshot --> number --> number --> A}
  _ Acc _ At End -> Acc where (> At End)
  F Acc Snapshot At End -> (fold-loop F (F Acc At) Snapshot (+ At 1) End))

)
