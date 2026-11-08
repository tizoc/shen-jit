(set ts-test.passed 0)
(set ts-test.failed 0)
(set ts-test.language
  (ts-test.ok (treesitter.load-language "C" (value ts-test.grammar-files) "tree_sitter_c")))

(define ts-test.parse
  Text -> (ts-test.ok (treesitter.parse (value ts-test.language) (buffer.from-string Text) [])))

(define ts-test.query
  Text Query Options ->
    (treesitter.query (value ts-test.language) (buffer.from-string Text) Query Options))

(define ts-test.any
  Snapshot Predicate ->
    (treesitter.fold (/. Found ID (or Found (Predicate ID))) false Snapshot))

(set ts-test.code "// cafc#195;c#169; c#206;c#187;c#13;c#10;int sum(int a) { return helper(a); }c#13;c#10;int empty(void) {}c#13;c#10;")
(set ts-test.query-text
  "(function_definition declarator: (function_declarator declarator: (identifier) @definition))
   (call_expression function: (identifier) @call)")
(set ts-test.snapshot
  (ts-test.ok (ts-test.query (value ts-test.code) (value ts-test.query-text) [])))
