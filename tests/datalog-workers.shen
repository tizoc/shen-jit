\\ Complete tuple comparisons, including seed IDB facts and empty partitions.
(set dwt.failed 0)
(set dwt.checked 0)

(define dwt.check
  Label Got Want ->
    (do (set dwt.checked (+ (value dwt.checked) 1))
      (if (= Got Want) true
          (do (set dwt.failed (+ (value dwt.failed) 1))
              (output "FAIL ~A: ~S != ~S~%" Label Got Want)))))

(define dwt.reject
  Name -> (dwt.check Name (trap-error (do (datalog.parallel.check Name) false) (/. E true)) true))

(define dwt.compare
  Name Facts Count ->
    (let Serial (datalog.run-naive Name Facts)
         Rs (datalog.nth 3 (datalog.program Name))
      (datalog.parallel.with-workers Name Facts Count (value dwt.image)
        (/. S (let _ (datalog.parallel.evaluate S)
                   _ (map (/. R (dwt.check [Name Count (hd R)]
                          (datalog.sort (datalog.parallel.scope-tuples S (hd R)))
                          (datalog.sorted Serial (hd R)))) Rs)
                (dwt.check [Name Count repeated] (datalog.parallel.evaluate S)
                  (map (/. R [(hd R) (datalog.count Serial (hd R))]) Rs)))))))

(defdatalog dwt.words
  (relation edge [symbol symbol])
  (relation reach [symbol symbol])
  (rule (reach X Y) <-- (edge X Y))
  (rule (reach X Z) <-- (reach X Y) (edge Y Z)))

(defdatalog dwt.text
  (relation edge [string string])
  (relation reach [string string])
  (rule (reach X Y) <-- (edge X Y))
  (rule (reach X Z) <-- (reach X Y) (edge Y Z)))

(defdatalog dwt.literal
  (relation source [integer])
  (relation result [integer integer])
  (rule (result 42 7))
  (rule (result X Y) <-- (source X) (= Y (+ X 2))))

(defdatalog dwt.computed
  (relation source [integer])
  (relation result [integer])
  (rule (result Y) <-- (source X) (= Y (+ X 1))))

(defdatalog dwt.aggregate
  (relation source [integer integer])
  (relation result [integer integer])
  (rule (result X N) <-- (source X _) (= N (count (source X _)))))

(defdatalog dwt.negative
  (relation source [integer])
  (relation excluded [integer])
  (relation result [integer])
  (rule (result X) <-- (source X) (not (excluded X))))

(map (/. P (dwt.compare db.closure
              [[edge -3 2] [edge 2 9] [edge 9 2] [edge -3 2] [path 17 -3]] P)) [1 2 3 4 16])
(map (/. P (dwt.compare db.skew
              [[edge 1 2] [edge 2 1] [edge 3 2] [edge 2 3] [two 77 77]] P)) [1 4])
(dwt.compare db.closure [] 4)
(dwt.compare dwt.words [[edge a b] [edge b c] [reach x a]] 3)
(dwt.compare dwt.text [[edge "a" "b"] [edge "b" "c"] [reach "x" "a"]] 2)
(dwt.compare dwt.literal [[source -4] [source 5]] 4)
(dwt.compare dwt.literal [] 2)
(map (function dwt.reject) [db.nonlinear db.mutual dwt.computed dwt.aggregate dwt.negative])
(output "~A checks, ~A failed~%" (value dwt.checked) (value dwt.failed))
