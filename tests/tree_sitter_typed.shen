(define ts-typed.query
  {treesitter.language --> (treesitter.result string)}
  Language ->
    (ts-typed.name (treesitter.query Language (buffer.from-string "int typed(void) {}")
      "(function_definition declarator: (function_declarator declarator: (identifier) @name))"
      [[input-limit 1024] [capture-limit 10] [timeout 2000]])))

(define ts-typed.name
  {(treesitter.result treesitter.snapshot) --> (treesitter.result string)}
  (:result.ok T) -> (:result.ok (treesitter.text T (treesitter.capture-node T 1)))
  (:result.err E) -> (:result.err E))

(define ts-typed.count
  {treesitter.snapshot --> number}
  T -> (treesitter.fold (/. N ID (+ N 1)) 0 T))

(define ts-typed.parse-limit?
  {(treesitter.result treesitter.snapshot) --> boolean}
  (:result.err (:treesitter.error operation <- Op domain <- Domain ...)) ->
    (and (= Op parse) (= Domain limit))
  _ -> false)

(define ts-typed.check
  {treesitter.language --> treesitter.snapshot --> boolean}
  Language Snapshot ->
    (and (= (ts-typed.query Language) (:result.ok "typed"))
         (> (ts-typed.count Snapshot) 1)
         (ts-typed.parse-limit? (treesitter.parse Language (buffer.new 2) [[input-limit 1]]))))
