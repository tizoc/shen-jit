\\ Library consumers resolve aliases, imports, types and DSL names before macro expansion.
(shen.x.namespace library-ns.bytes
  (use buffer => b)
  (export b.from-string => from-string b.length => size))

(shen.x.namespace library-ns.client
  (use buffer => b)
  (use cursor => c)
  (use datalog => d)
  (use grammar => g)
  (use io)
  (use json)
  (use library-ns.bytes => bytes)
  (import buffer from-string)
  (import datalog defdatalog)
  (import grammar defgrammar)
  (import io ok)
  (shadow length)
  (export length first-byte round-trip rule-count native-sum result digits?)

  (define length Text -> (bytes.size (bytes.from-string Text)))
  (define first-byte Text -> (c.read (c.new (from-string Text))))
  (define round-trip Text -> (json.stringify (json.parse Text []) []))
  (define result -> [ok (first-byte "A")])

  (defgrammar <digit> B where (and (>= B 48) (<= B 57));)
  (with-externals [require]
    (defgrammar <digits> (require (+ <digit>) "expected digits");))
  (define digits? Text -> (g.match? <digits> (from-string Text)))

  (with-externals [relation rule]
    (defdatalog paths
      (relation edge [symbol symbol])
      (relation path [symbol symbol])
      (rule (path X Y) <-- (edge X Y))
      (rule (path X Z) <-- (edge X Y) (path Y Z))))

  (define rule-count
    -> (d.count (d.run paths [[edge a b] [edge b c]]) path))

  (with-externals [define-native word for return-word]
    (define-native native-sum (N)
      (word Acc 0)
      (for I 0 N (word Acc (+ Acc I)))
      (return-word Acc)))
)
