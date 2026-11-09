(set *hush* false)
(set library-ns.*passed* 0)
(set library-ns.*failed* 0)

(define library-ns.check
  _ X X -> (set library-ns.*passed* (+ 1 (value library-ns.*passed*)))
  Name Expected Actual ->
    (do (set library-ns.*failed* (+ 1 (value library-ns.*failed*)))
        (output "FAIL ~A: expected ~R, got ~R~%" Name Expected Actual)))

(define library-ns.refused?
  Source -> (trap-error (do (read-from-string Source) false) (/. E true)))

(library-ns.check "renamed re-exports" 3 (library-ns.client.length "abc"))
(library-ns.check "system length stays global" 2 (length [a b]))
(library-ns.check "imports and aliases" 65 (library-ns.client.first-byte "A"))
(library-ns.check "typed aliases" 65 (library-ns.typed.first-byte "A"))
(library-ns.check "renamed type imports" "A"
  (buffer.string (library-ns.typed.preserve (buffer.from-string "A"))))
(library-ns.check "JSON keeps its data vocabulary" "{c#34;answerc#34;:42}"
  (library-ns.client.round-trip "{c#34;answerc#34;:42}"))
(library-ns.check "imported data symbols" [ok 65] (library-ns.client.result))
(library-ns.check "namespaced grammar names" true (library-ns.client.digits? "123"))
(library-ns.check "namespaced grammar failure" false (library-ns.client.digits? "1a"))
(library-ns.check "scoped Datalog vocabulary and qualified relations" 3 (library-ns.client.rule-count))
(library-ns.check "scoped native instructions and qualified definition" 10 (library-ns.client.native-sum 5))

(library-ns.check "library helpers stay outside the interface" true
  (library-ns.refused? "(shen.x.namespace library-ns.private (use buffer => b) (define f -> b.storage-length))"))
(library-ns.check "unexported imports are refused" true
  (library-ns.refused? "(shen.x.namespace library-ns.private (import json scan-fail))"))
(library-ns.check "interfaces resolve on a subsequent read"
  [[define library-ns.later.size -> [buffer.length [buffer.from-string "abc"]]]]
  (read-from-string "(shen.x.namespace library-ns.later (use buffer => b) (define size -> (b.length (b.from-string c#34;abcc#34;))))"))

(output "~A passed, ~A failed (library namespaces)~%" (value library-ns.*passed*) (value library-ns.*failed*))
(if (= (value library-ns.*failed*) 0) true (simple-error "library namespace checks failed"))
