(set dpt.checks 0)
(set dpt.failures 0)

(define dpt.check
  Label Got Want ->
    (do (set dpt.checks (+ (value dpt.checks) 1))
        (if (= Got Want) true
            (do (set dpt.failures (+ (value dpt.failures) 1))
                (output "FAIL ~S: ~S != ~S~%" Label Got Want)))))

(define dpt.error?
  F -> (trap-error (do (thaw F) false) (/. E true)))

(define dpt.same
  Label A B ->
    (let Rs (datalog.nth 3 (datalog.program (datalog.nth 2 A)))
      (map (/. R (dpt.check [Label (hd R)] (datalog.sorted A (hd R)) (datalog.sorted B (hd R)))) Rs)))

(define dpt.compare
  Name Facts Count ->
    (let Db (datalog.parallel.run Name Facts (value dpt.image) Count)
         Expected (datalog.run-naive Name Facts)
         Rs (datalog.nth 3 (datalog.program Name))
         _ (shen-jit.collect)
         _ (dpt.same [Name Count] Db Expected)
         _ (map (/. R (map (/. T
                    (do (dpt.check "holds after join" (datalog.holds? Db [(hd R) | T]) true)
                        (dpt.check "explanation after join" (cons? (datalog.explain Db [(hd R) | T])) true)))
                    (datalog.tuples Db (hd R)))) Rs)
      Db))

(defdatalog dpt.closure
  (relation edge [integer integer])
  (relation path [integer integer])
  (rule (path X Y) <-- (edge X Y))
  (rule (path X Z) <-- (path X Y) (edge Y Z)))

(defdatalog dpt.words
  (relation edge [symbol symbol])
  (relation label [symbol string])
  (relation path [symbol symbol string])
  (rule (path X Y T) <-- (edge X Y) (label Y T))
  (rule (path X Z T) <-- (path X Y _) (edge Y Z) (label Z T)))

(defdatalog dpt.derived
  (relation edge [integer integer])
  (relation path [integer integer])
  (relation cycle [integer])
  (rule (path X Y) <-- (edge X Y))
  (rule (path X Z) <-- (path X Y) (edge Y Z))
  (rule (cycle X) <-- (path X X)))

(defdatalog dpt.generated
  (relation seed [symbol integer])
  (relation made [symbol string integer])
  (rule (made X T N) <-- (seed X N) (= T (to-string N)))
  (rule (made X T M) <-- (made X _ N) (= M (+ N 1)) (< M 5) (= T (to-string M))))

(defdatalog dpt.strings
  (relation edge [string string])
  (relation path [string string])
  (rule (path X Y) <-- (edge X Y))
  (rule (path X Z) <-- (path X Y) (edge Y Z)))

(defdatalog dpt.vocabulary
  (relation source [symbol string integer])
  (relation result [symbol string integer])
  (rule (result K Text N) <-- (source K Text N)))

(define dpt.vocabulary-facts
  0 Acc -> Acc
  N Acc -> (dpt.vocabulary-facts (- N 1)
             [[source (intern (cn "key." (str N))) (cn "text." (str N)) (- 0 N)] | Acc]))

(define dpt.double-text
  0 Text -> Text
  N Text -> (dpt.double-text (- N 1) (cn Text Text)))

(define dpt.long-vocabulary-facts
  0 _ Acc -> Acc
  N Text Acc -> (dpt.long-vocabulary-facts (- N 1) Text
    [[source (intern (cn "long-key." (str N))) (cn (str N) Text) N] | Acc]))

(defdatalog dpt.constant
  (relation source [integer])
  (relation result [integer integer])
  (rule (result 42 7))
  (rule (result X Y) <-- (source X) (= Y (+ X 2))))

(defdatalog dpt.nonlinear
  (relation edge [integer integer])
  (relation path [integer integer])
  (rule (path X Y) <-- (edge X Y))
  (rule (path X Z) <-- (path X Y) (path Y Z)))

(defdatalog dpt.negative
  (relation source [integer])
  (relation excluded [integer])
  (relation result [integer])
  (rule (result X) <-- (source X) (not (excluded X))))

(defdatalog dpt.aggregate
  (relation source [integer integer])
  (relation result [integer integer])
  (rule (result X N) <-- (source X _) (= N (count (source X _)))))

(defdatalog dpt.records
  (type item [box integer])
  (relation source [item])
  (relation result [item])
  (rule (result X) <-- (source X)))

(defdatalog dpt.keyed
  (relation source [integer integer])
  (relation result [integer integer] min)
  (rule (result X Y) <-- (source X Y)))

(defdatalog dpt.equivalence
  (relation source [integer integer])
  (relation result [integer integer] equivalence)
  (rule (result X Y) <-- (source X Y)))

(defdatalog dpt.computed
  (relation source [integer])
  (relation result [integer])
  (rule (result Y) <-- (source X) (= Y (+ X 1))))

(define dpt.fallback
  Name Facts ->
    (do (dpt.check "sequential plan" (hd (datalog.parallel.plan Name)) sequential)
        (dpt.same Name (datalog.parallel.run Name Facts "does-not-exist" 4)
                      (datalog.run-naive Name Facts))))

(dpt.check "parallel plan" (datalog.parallel.plan dpt.closure) [parallel integer [path]])
(map (/. P (dpt.compare dpt.closure
               [[edge -3 2] [edge 2 9] [edge 9 2] [edge -3 2] [path 17 -3]] P)) [1 2 3 4 16])
(dpt.compare dpt.derived [[edge 1 2] [edge 2 1] [edge 9 10] [path 5 1]] 3)
(dpt.compare dpt.words
  [[edge a b] [edge b c] [edge c b] [path x a "first"]
   [label a "first"] [label b "c#99;aféc#0;"] [label c "third"]] 3)
(dpt.compare dpt.strings [[edge "a" "b"] [edge "b" "c"] [path "x" "a"]] 4)
(dpt.compare dpt.generated [[seed a -3] [seed b 2]] 2)
(let Facts (dpt.vocabulary-facts 300 [])
     Db (datalog.parallel.run dpt.vocabulary Facts (value dpt.image) 3)
  (dpt.check "vocabulary spans multiple packets"
    (datalog.sorted Db result) (datalog.sort (map (function tl) Facts))))
(let Facts (dpt.long-vocabulary-facts 130 (dpt.double-text 10 "0123456789") [])
     Expected (datalog.sort (map (function tl) Facts))
     Db (datalog.parallel.with-db dpt.vocabulary Facts (value dpt.image) 2
          (/. V (do
            (dpt.check "long input tuples exceed one MiB"
              (datalog.sort (datalog.parallel.tuples V source)) Expected)
            (dpt.check "large query replies use worker budget"
              (map (function datalog.sort)
                (datalog.parallel.match-many V [[source [any] [any] [any]]])) [Expected])
            (datalog.parallel.materialize V))))
     _ (shen-jit.collect)
  (dpt.check "long vocabulary pages materialize correctly" (datalog.sorted Db result) Expected))
(dpt.compare dpt.constant [[source -4] [source 5]] 4)
(dpt.compare dpt.closure [] 4)
(dpt.compare dpt.constant [] 4)

(let Facts [[edge -3 2] [edge 2 9] [path 17 -3]]
     Db (datalog.parallel.run dpt.closure Facts (value dpt.image) 4)
     More [[edge 9 12] [edge 99 100]]
     Added (datalog.add Db More)
     _ (dpt.same "add new keys after join" Added (datalog.run-naive dpt.closure (append Facts More)))
     _ (dpt.check "indexed query after join" (datalog.sort (datalog.match Added [path -3 [var "Y"]])) [[-3 2] [-3 9] [-3 12]])
     Removed (datalog.remove Added [[edge 2 9] [path 17 -3]])
     _ (dpt.same "remove after join" Removed
           (datalog.run-naive dpt.closure [[edge -3 2] [edge 9 12] [edge 99 100]]))
  (set dpt.saved Removed))

(let Db (datalog.parallel.run dpt.words
           [[edge a b] [label b "one"] [edge x y] [label y "two"]] (value dpt.image) 2)
     Added (datalog.add Db [[edge b c] [label c "new"] [edge z q] [label q "last"]])
  (dpt.check "new interned values after join" (datalog.holds? Added [path a c "new"]) true))

(dpt.fallback dpt.nonlinear [[edge 1 2] [edge 2 3]])
(dpt.fallback dpt.negative [[source 1] [source 2] [excluded 2]])
(dpt.fallback dpt.aggregate [[source 1 2] [source 1 3] [source 2 4]])
(dpt.fallback dpt.records [[source [box 1]] [source [box 2]]])
(dpt.fallback dpt.keyed [[source 1 2] [source 1 3] [source 2 4]])
(dpt.fallback dpt.equivalence [[source 1 2] [source 2 3]])
(dpt.fallback dpt.computed [[source 1] [source 2]])
(dpt.check "explicit structural refusal"
  (datalog.parallel.plan dpt.negative)
  [sequential "negation and aggregates are not partitioned"])
\\ A damaged internal program is an unexpected failure, not an unsupported
\\ feature. In particular, plan must not catch it and report sequential.
(put dpt.broken datalog.program
  [program dpt.broken [[source integer] [result integer]] [broken] [] [] [] [] []])
(dpt.check "unexpected planning failure propagates"
  (dpt.error? (freeze (datalog.parallel.plan dpt.broken))) true)
(dpt.same "one worker uses sequential engine"
  (datalog.parallel.run dpt.closure [[edge 1 2] [edge 2 3]] "does-not-exist" 1)
  (datalog.run-naive dpt.closure [[edge 1 2] [edge 2 3]]))
(dpt.same "one key uses sequential engine"
  (datalog.parallel.run dpt.constant [] "does-not-exist" 4) (datalog.run-naive dpt.constant []))

(define dpt.repeat
  0 Acc -> Acc
  N Acc -> (dpt.repeat (- N 1) [[edge 1 2] | Acc]))
(dpt.check "codec limit falls back before opening image"
  (datalog.count (datalog.parallel.run dpt.closure (dpt.repeat 70000 []) "does-not-exist" 4) path) 1)
(map (/. N (dpt.check "invalid worker count"
  (dpt.error? (freeze (datalog.parallel.run dpt.closure [] "does-not-exist" N))) true)) [0 -1 1.5 65])
(dpt.check "invalid facts raise"
  (dpt.error? (freeze (datalog.parallel.run dpt.closure [[edge a 2]] (value dpt.image) 4))) true)
(dpt.check "unknown program raises"
  (dpt.error? (freeze (datalog.parallel.plan dpt.missing))) true)
(dpt.check "missing worker image is not silently retried"
  (dpt.error? (freeze (datalog.parallel.run dpt.closure [[edge 1 2] [edge 2 3]] "does-not-exist" 4))) true)
(dpt.check "worker failure is not silently retried"
  (dpt.error? (freeze (datalog.parallel.run dpt.closure [[edge 1 2] [edge 2 3]] (value dpt.bad-image) 4))) true)

(shen.x.namespace dpt.client
  (use datalog.parallel => dp)
  (externals [dpt.closure])
  (define plan -> (dp.plan dpt.closure)))
(dpt.check "namespaced public API" (dpt.client.plan) [parallel integer [path]])

(map (/. P
  (let Facts [[edge 1 2] [edge 2 3] [edge 9 10]]
       Owned (datalog.parallel.with-db dpt.closure Facts (value dpt.image) P
         (/. V (do (set dpt.escaped V)
                    (dpt.check "scoped count" (datalog.parallel.count V path) 4)
                    (dpt.check "scoped membership" (datalog.parallel.holds? V [path 1 3]) true)
                    (dpt.check "scoped missing membership" (datalog.parallel.holds? V [path 1 99]) false)
                    (dpt.check "scoped query" (datalog.sort (datalog.parallel.match V [path 1 [var "Y"]])) [[1 2] [1 3]])
                    (dpt.check "unbound partition key searches all workers"
                      (datalog.sort (datalog.parallel.match V [path [any] 3])) [[1 3] [2 3]])
                    (dpt.check "reused query" (datalog.sort (datalog.parallel.match V [path 1 [var "Y"]])) [[1 2] [1 3]])
                    (dpt.check "batch query order and EDB uniqueness"
                      (map (function datalog.sort)
                        (datalog.parallel.match-many V [[path 1 [var "Y"]] [edge [any] [any]] [path 99 [any]]]))
                      [[[1 2] [1 3]] [[1 2] [2 3] [9 10]] []])
                    (dpt.check "empty query batch" (datalog.parallel.match-many V []) [])
                    (dpt.check "EDB query is not duplicated" (length (datalog.parallel.match V [edge [any] [any]])) 3)
                    (dpt.check "scoped tuples" (datalog.sort (datalog.parallel.tuples V path)) [[1 2] [1 3] [2 3] [9 10]])
                    (let Db (datalog.parallel.materialize V)
                      (do (dpt.check "materialization consumes view"
                            (dpt.error? (freeze (datalog.parallel.count V path))) true) Db)))))
       _ (shen-jit.collect)
       _ (dpt.same "owned materialization" Owned (datalog.run-naive dpt.closure Facts))
       _ (dpt.check "escaped view rejects cached reads"
            (dpt.error? (freeze (datalog.parallel.count (value dpt.escaped) path))) true)
    (dpt.check "materialized database still updates"
      (datalog.holds? (datalog.add Owned [[edge 3 4]]) [path 1 4]) true))) [1 3])

(let Rows (datalog.parallel.with-db dpt.words
             [[edge a b] [label b "c#99;afé λc#0;"] [edge x y] [label y "two"]]
             (value dpt.image) 2
             (/. V (do (set dpt.escaped V) (datalog.parallel.match V [path a [any] [any]]))))
     _ (shen-jit.collect)
  (dpt.check "query values survive joining" Rows [[a b "c#99;afé λc#0;"]]))
(datalog.parallel.with-db dpt.strings [[edge "a" "b"] [edge "b" "c"]]
  (value dpt.image) 3
  (/. V (dpt.check "string partition key and missing key"
    (map (function datalog.sort)
      (datalog.parallel.match-many V [[path "a" [any]] [path "missing" [any]]]))
    [[["a" "b"] ["a" "c"]] []])))
(let Facts (dpt.vocabulary-facts 1025 []) Expected (datalog.run dpt.vocabulary Facts)
  (datalog.parallel.with-db dpt.vocabulary Facts (value dpt.image) 3
    (/. V (map (/. Rel (dpt.check "tuple collection across chunks"
                         (datalog.sort (datalog.parallel.tuples V Rel)) (datalog.sorted Expected Rel)))
               [source result]))))
(dpt.check "escaped query view raises"
  (dpt.error? (freeze (datalog.parallel.match (value dpt.escaped) [path a [any] [any]]))) true)
(dpt.check "empty batch checks view lifetime"
  (dpt.error? (freeze (datalog.parallel.match-many (value dpt.escaped) []))) true)
(map (/. P
  (do (dpt.check "callback failure closes view"
        (dpt.error? (freeze (datalog.parallel.with-db dpt.closure [[edge 1 2] [edge 2 3]] (value dpt.image) P
          (/. V (do (set dpt.escaped V) (error "deliberate callback failure")))))) true)
      (dpt.check "failed callback invalidates view"
        (dpt.error? (freeze (datalog.parallel.count (value dpt.escaped) path))) true))) [1 2])
(dpt.check "worker query errors remain sticky"
  (dpt.error? (freeze (datalog.parallel.with-db dpt.closure [[edge 1 2] [edge 2 3]] (value dpt.image) 2
    (/. V (do (trap-error (datalog.parallel.match V [dpt.missing 1]) (/. E [])) true))))) true)
(dpt.check "vocabulary reply must advance"
  (dpt.error? (freeze (datalog.parallel.fill-vocabulary [[0]] [(shen-jit.bytes 4)] [[1]]
                        (shen.dict 8) [0]))) true)
(dpt.check "vocabulary reply length is checked"
  (dpt.error? (freeze (datalog.parallel.fill-vocabulary [[1]] [(shen-jit.bytes 4)] [[1]]
                        (shen.dict 8) [0]))) true)
(datalog.parallel.with-db dpt.records [[source [box 1]]] "does-not-exist" 4
  (/. V (dpt.check "scoped unsupported program falls back" (datalog.parallel.tuples V result) [[[box 1]]])))

(define dpt.copy-view
  (:datalog.parallel.view name <- N facts <- F source <- S shared <- B active <- A) ->
    (:datalog.parallel.view name <- N facts <- F source <- S shared <- B active <- true))
(let Copy (datalog.parallel.with-db dpt.closure [[edge 1 2] [edge 2 3]]
             (value dpt.image) 2 (function dpt.copy-view))
  (do (dpt.check "copied view has independent active flag" (datalog.parallel.view.active Copy) true)
      (dpt.check "shared lifetime rejects copied closed view"
        (dpt.error? (freeze (datalog.parallel.count Copy path))) true)))

(output "~A checks, ~A failed (parallel Datalog)~%" (value dpt.checks) (value dpt.failures))
(if (= (value dpt.failures) 0) true (error "parallel Datalog checks failed"))
