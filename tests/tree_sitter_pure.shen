(map (/. Options (ts-test.check Options (ts-test.raises? (freeze (treesitter.options Options)))))
  [[[other 1]] [[timeout -1]] [[timeout 2147483648]] [[node-limit 0]] [[input-limit -1]]
   [[node-limit 4194305]] [[capture-limit 1048577]] [[match-limit 0]] [[match-limit 1048577]]
   [[result-limit 536870913]] [[query-limit 16777217]] [[timeout 1] [timeout 2]]
   [[node-limit 1.5]] [[timeout "one"]] [timeout] [[timeout 1 2]]])

(ts-test.check "zero and maximum budgets accepted"
  (do (treesitter.options [[input-limit 0] [capture-limit 0] [result-limit 0] [timeout 0]
                          [node-limit 4194304] [query-limit 0] [match-limit 1048576]]) true))
(ts-test.check "language name validation"
  (ts-test.raises? (freeze (treesitter.load-language "" ["missing"] "entry"))))
(ts-test.check "grammar files required"
  (ts-test.raises? (freeze (treesitter.load-language "C" [] "entry"))))
(ts-test.check "grammar paths reject NUL"
  (ts-test.raises? (freeze (treesitter.load-language "C" ["badc#0;path"] "entry"))))
(ts-test.check "grammar entry required"
  (ts-test.raises? (freeze (treesitter.load-language "C" ["missing"] ""))))
(ts-test.check "snapshot rejects another object"
  (ts-test.raises? (freeze (treesitter.root []))))
(ts-test.check "parse rejects another language"
  (ts-test.raises? (freeze (treesitter.parse [] (buffer.new 0) []))))
(ts-test.check "query requires text"
  (ts-test.raises? (freeze (treesitter.query [] (buffer.new 0) [] []))))

(define ts-test.matched-operation
  (:treesitter.error operation <- Op ...) -> Op
  _ -> unexpected-error)

(let E (treesitter.error parse native 1 0 "example.c" "parse failed")
  (do (ts-test.check "error struct predicate" (treesitter.error? E))
      (ts-test.check "error struct predicate rejects another value" (not (treesitter.error? [])))
      (ts-test.check "labelled error pattern" (= (ts-test.matched-operation E) parse))))

(let E (io.error read "another library" "read failed")
  (map (/. Accessor (ts-test.check "error accessor rejects an I/O error"
                       (ts-test.raises? (freeze (Accessor E)))))
       [(function treesitter.error-operation) (function treesitter.error-domain)
        (function treesitter.error-code) (function treesitter.error-offset)
        (function treesitter.error-resource) (function treesitter.error-message)]))

\\ Limits precede native resolution, including on static builds.
(let Language (treesitter.language.make "unresolved" missing 15)
  (do (ts-test.check "input budget before native work"
        (= (ts-test.error-domain (treesitter.parse Language (buffer.new 2) [[input-limit 1]])) limit))
      (ts-test.check "query budget before native work"
        (= (ts-test.error-domain
             (treesitter.query Language (buffer.new 0) "long" [[query-limit 1]])) limit))))

(output "~A passed, ~A failed~%" (value ts-test.passed) (value ts-test.failed))
