(define ts-typed.query
  {treesitter.language --> (treesitter.result string)}
  Language ->
    (ts-typed.name (treesitter.query Language (buffer.from-string "int typed(void) {}")
      "(function_definition declarator: (function_declarator declarator: (identifier) @name))"
      [[input-limit 1024] [capture-limit 10] [timeout 2000]])))

(define ts-typed.name
  {(treesitter.result treesitter.snapshot) --> (treesitter.result string)}
  [ok T] -> [ok (treesitter.text T (treesitter.capture-node T 1))]
  [error E] -> [error E])

(define ts-typed.count
  {treesitter.snapshot --> number}
  T -> (treesitter.fold (/. N ID (+ N 1)) 0 T))

(define ts-typed.check
  {treesitter.language --> treesitter.snapshot --> boolean}
  Language Snapshot ->
    (and (= (ts-typed.query Language) [ok "typed"]) (> (ts-typed.count Snapshot) 1)))
