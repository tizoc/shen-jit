(let T (value ts-test.snapshot)
  (do (ts-test.check "language ABI" (= (treesitter.language-version (value ts-test.language)) 15))
      (ts-test.check "language name" (= (treesitter.language-name (value ts-test.language)) "C"))
      (ts-test.check "root kind" (= (treesitter.kind T (treesitter.root T)) "translation_unit"))
      (ts-test.check "root parent absent" (= (treesitter.parent T 1) 0))
      (ts-test.check "root named" (treesitter.named? T 1))
      (ts-test.check "valid syntax" (not (treesitter.has-error? T 1)))
      (ts-test.check "query matches" (= (treesitter.match-count T) 3))
      (ts-test.check "query captures" (= (treesitter.capture-count T) 3))
      (ts-test.check "capture name" (= (treesitter.capture-name T 1) "definition"))
      (ts-test.check "capture source" (= (treesitter.text T (treesitter.capture-node T 1)) "sum"))
      (ts-test.check "capture match ID" (= (treesitter.capture-match T 1) 1))
      (ts-test.check "capture pattern" (= (treesitter.capture-pattern T 1) 0))
      (ts-test.check "source snapshot" (= (buffer.string (treesitter.source T)) (value ts-test.code)))
      (ts-test.check "field traversal"
        (let Fn (treesitter.parent T (treesitter.parent T (treesitter.capture-node T 1)))
             Decl (treesitter.child-by-field T Fn "declarator")
          (= (treesitter.kind T Decl) "function_declarator")))
      (ts-test.check "absent field" (= (treesitter.child-by-field T 1 "missing") 0))
      (ts-test.check "preorder fold visits each node"
        (= (treesitter.fold (/. N ID (+ N 1)) 0 T) (treesitter.node-count T)))
      (ts-test.check "anonymous punctuation preserved"
        (ts-test.any T (/. ID (and (= (treesitter.kind T ID) "(") (not (treesitter.named? T ID))))))
      (ts-test.check "extra comments preserved"
        (ts-test.any T (/. ID (and (= (treesitter.kind T ID) "comment") (treesitter.extra? T ID)))))))

(let Empty (ts-test.parse "")
  (do (ts-test.check "empty source tree" (= (treesitter.node-count Empty) 1))
      (ts-test.check "empty root range" (= (treesitter.end-byte Empty 1) 0))
      (ts-test.check "empty root children" (= (treesitter.children Empty 1) []))))

(let Missing (ts-test.parse "int f(void) { return 1 }")
     Invalid (ts-test.parse "int x = @@@;")
     Nul (ts-test.parse "int x;c#0;int y;")
  (do (ts-test.check "missing tokens retained" (ts-test.any Missing (/. ID (treesitter.missing? Missing ID))))
      (ts-test.check "syntax errors are trees" (treesitter.has-error? Invalid 1))
      (ts-test.check "ERROR kind table"
        (ts-test.any Invalid (/. ID (and (treesitter.error? Invalid ID)
                                       (= (treesitter.kind Invalid ID) "ERROR")))))
      (ts-test.check "NUL source is length counted" (= (buffer.length (treesitter.source Nul)) 13))))

(let Input (buffer.from-string "int original;")
     T (ts-test.ok (treesitter.parse (value ts-test.language) Input []))
     Copy (treesitter.source T)
     _ (buffer.u8! Input 4 88)
     _ (buffer.u8! Copy 4 89)
  (ts-test.check "input and exported source cannot mutate snapshot" (= (treesitter.text T 1) "int original;")))

(let Input (buffer.from-string "prefixint bounded;suffix")
     T (ts-test.ok (treesitter.parse (value ts-test.language) (buffer.slice Input 6 12) []))
  (ts-test.check "source view bounds" (= (treesitter.text T 1) "int bounded;")))

(map (/. ID (ts-test.check "node index checked"
             (ts-test.raises? (freeze (treesitter.text (value ts-test.snapshot) ID)))))
     [0 -1 999999 1.5])
(map (/. ID (ts-test.check "capture index checked"
             (ts-test.raises? (freeze (treesitter.capture-node (value ts-test.snapshot) ID)))))
     [0 -1 999999 1.5])

(map (/. Options
       (ts-test.check Options
         (= (ts-test.error-domain (ts-test.query "int x; int y;" "(identifier) @id" Options)) limit)))
  [[[input-limit 1]] [[node-limit 1]] [[capture-limit 1]] [[match-limit 1]]
   [[result-limit 1]] [[query-limit 1]]])
(ts-test.check "zero timeout"
  (= (ts-test.error-domain (ts-test.query "int x;" "(identifier) @id" [[timeout 0]])) timeout))
(ts-test.check "empty query"
  (= (treesitter.capture-count (ts-test.ok (ts-test.query "int x;" "" [[capture-limit 0]]))) 0))
(let T (ts-test.ok (ts-test.query "int x; int y;" "(identifier)" [[capture-limit 0]]))
  (ts-test.check "matches without captures" (and (= (treesitter.match-count T) 2)
                                                (= (treesitter.capture-count T) 0))))

(let Input (buffer.from-string "int x;")
     First (ts-test.ok (treesitter.parse (value ts-test.language) Input []))
     Exact (treesitter.parse (value ts-test.language) Input
             [[input-limit 6] [node-limit (treesitter.node-count First)]])
     Captured (ts-test.ok (ts-test.query "int x;" "(identifier) @one @two"
                          [[capture-limit 2] [match-limit 1]]))
  (do (ts-test.check "inclusive source and node limits" (= (hd Exact) ok))
      (ts-test.check "multiple captures in one match"
        (and (= (treesitter.capture-count Captured) 2) (= (treesitter.match-count Captured) 1)))
      (ts-test.check "repeated capture node identity"
        (= (treesitter.capture-node Captured 1) (treesitter.capture-node Captured 2)))
      (ts-test.check "capture names retain order"
        (and (= (treesitter.capture-name Captured 1) "one")
             (= (treesitter.capture-name Captured 2) "two")))))

(map (/. Query (ts-test.check Query (= (ts-test.error-domain (ts-test.query "int x;" Query [])) query)))
  ["(" "(nonexistent_node) @x" "(declaration wrong_field: (identifier))"])
(let R (ts-test.query "int x;" "(not_a_kind)" [])
     E (hd (tl R))
  (do (ts-test.check "query error category" (= (treesitter.error-code E) 2))
      (ts-test.check "query error byte offset" (= (treesitter.error-offset E) 1))))
(map (/. Query (ts-test.check "predicates are never silently ignored"
                (= (ts-test.error-domain (ts-test.query "int x;" Query [])) predicate)))
  ["((identifier) @x (#eq? @x c#34;y c#34;))"
   "((identifier) @x (#set! role c#34;namec#34;))"])

(ts-test.check "missing grammar structured error"
  (= (ts-test.error-domain (treesitter.load-language "missing" ["./no-such-grammar.so"] "entry")) foreign))
(ts-test.check "missing grammar symbol structured error"
  (= (ts-test.error-domain (treesitter.load-language "C" (value ts-test.grammar-files) "no_such_entry")) foreign))
(ts-test.check "incompatible ABI rejected"
  (= (ts-test.error-domain
       (treesitter.load-language "bad" (value ts-test.fixture-files) "ts_fixture_bad_language")) language))
(ts-test.check "null language rejected"
  (= (ts-test.error-domain
       (treesitter.load-language "null" (value ts-test.fixture-files) "ts_fixture_null_language")) language))

(shen-jit.library ts-test.memory ["libc.so.6" "libSystem.dylib" "ucrtbase.dll"])
(define-foreign ts-test.malloc ts-test.memory "malloc" (int64) --> pointer)
(define-foreign ts-test.free ts-test.memory "free" (pointer) --> void)
(let Pointer (shen-jit.pointer-sized (ts-test.malloc 6) 6)
     View (buffer.wrap Pointer)
     _ (buffer.copy! View 0 (buffer.from-string "int x;") 0 6)
     T (ts-test.ok (treesitter.parse (value ts-test.language) View []))
     _ (ts-test.free Pointer)
     _ (shen-jit.pointer-kill Pointer)
  (do (ts-test.check "foreign input copied" (= (treesitter.text T 1) "int x;"))
      (ts-test.check "closed foreign input rejected"
        (ts-test.raises? (freeze (treesitter.parse (value ts-test.language) View []))))))

\\ A language loaded in the builder parses in an isolate, which makes its own parser.
(define ts-test.in-isolate
  [Language Text Out] ->
    (channel.send Out (let T (ts-test.ok (treesitter.parse Language (buffer.from-string Text) []))
                         [(treesitter.kind T (treesitter.root T)) (treesitter.node-count T)])))

(let R (channel.new 1)
     P (isolate.spawn ts-test.in-isolate [(value ts-test.language) "int x; int f(void) { return 1; }"
                                           (channel.sender R)])
     M (isolate.monitor P)
     Got (channel.receive-any [R M])
     _ (channel.receive M)
     T (ts-test.parse "int x; int f(void) { return 1; }")
  (ts-test.check "an isolate parses with a language loaded in the builder"
    (= Got [R ["translation_unit" (treesitter.node-count T)]])))

(output "~A passed, ~A failed~%" (value ts-test.passed) (value ts-test.failed))
