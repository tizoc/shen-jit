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

\\ Limits precede native resolution, including on static builds.
(let Language (treesitter.record [treesitter.language "unresolved" missing 15])
  (do (ts-test.check "input budget before native work"
        (= (ts-test.error-domain (treesitter.parse Language (buffer.new 2) [[input-limit 1]])) limit))
      (ts-test.check "query budget before native work"
        (= (ts-test.error-domain
             (treesitter.query Language (buffer.new 0) "long" [[query-limit 1]])) limit))))

(output "~A passed, ~A failed~%" (value ts-test.passed) (value ts-test.failed))
