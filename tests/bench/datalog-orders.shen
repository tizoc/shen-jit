\* What the order of a rule's atoms costs, under fixed plans and plans made from sizes as it runs.
   Each program comes in more than one order: the same rules with the atoms in another order.
   Usage: shen-jit eval -m datalog -l tests/bench/datalog.shen -l tests/bench/datalog-orders.shen -e '(do.run chain-a true)' *\

\* A chain of joins where one relation is small, written from either end. *\
(define do.chain-items
  Body -> [[relation big1 [integer integer]] [relation big2 [integer integer]]
           [relation small [integer integer]] [relation big3 [integer integer]]
           [relation out [integer integer]]
           [rule [out [var "A"] [var "E"]] Body]])

(define do.chain-a
  -> (do.chain-items [[small [var "C"] [var "D"]] [big2 [var "B"] [var "C"]] [big3 [var "D"] [var "E"]] [big1 [var "A"] [var "B"]]]))

(define do.chain-b
  -> (do.chain-items [[big1 [var "A"] [var "B"]] [big2 [var "B"] [var "C"]] [small [var "C"] [var "D"]] [big3 [var "D"] [var "E"]]]))

(define do.pairs
  _ 0 _ Acc -> Acc
  Rel M N Acc -> (do.pairs Rel (- M 1) N [[Rel (db.random N) (db.random N)] | Acc]))

(define do.chain-facts
  -> (append (do.pairs big1 20000 2000 [])
      (append (do.pairs big2 20000 2000 [])
       (append (do.pairs big3 20000 2000 [])
               (do.pairs small 3 2000 [])))))

\* Andersen's points-to analysis over generated statements. *\
(define do.points-to-relations
  -> [[relation alloc [integer integer]] [relation assign [integer integer]]
      [relation load [integer integer integer]] [relation store [integer integer integer]]
      [relation vpt [integer integer]] [relation hpt [integer integer integer]]
      [rule [vpt [var "V"] [var "H"]] [[alloc [var "V"] [var "H"]]]]
      [rule [vpt [var "V"] [var "H"]] [[assign [var "V"] [var "W"]] [vpt [var "W"] [var "H"]]]]])

(define do.points-to-a
  -> (append (do.points-to-relations)
       [[rule [vpt [var "V"] [var "H"]] [[vpt [var "B"] [var "O"]] [hpt [var "O"] [var "F"] [var "H"]] [load [var "V"] [var "B"] [var "F"]]]]
        [rule [hpt [var "O"] [var "F"] [var "H"]] [[vpt [var "B"] [var "O"]] [store [var "B"] [var "F"] [var "W"]] [vpt [var "W"] [var "H"]]]]]))

(define do.points-to-b
  -> (append (do.points-to-relations)
       [[rule [vpt [var "V"] [var "H"]] [[load [var "V"] [var "B"] [var "F"]] [hpt [var "O"] [var "F"] [var "H"]] [vpt [var "B"] [var "O"]]]]
        [rule [hpt [var "O"] [var "F"] [var "H"]] [[vpt [var "W"] [var "H"]] [vpt [var "B"] [var "O"]] [store [var "B"] [var "F"] [var "W"]]]]]))

\* As points-to analyses are usually written: each statement first, then what it reaches. *\
(define do.points-to-c
  -> (append (do.points-to-relations)
       [[rule [vpt [var "V"] [var "H"]] [[load [var "V"] [var "B"] [var "F"]] [vpt [var "B"] [var "O"]] [hpt [var "O"] [var "F"] [var "H"]]]]
        [rule [hpt [var "O"] [var "F"] [var "H"]] [[store [var "B"] [var "F"] [var "W"]] [vpt [var "B"] [var "O"]] [vpt [var "W"] [var "H"]]]]]))

(define do.triples
  _ 0 _ _ Acc -> Acc
  Rel M N F Acc -> (do.triples Rel (- M 1) N F [[Rel (db.random N) (db.random N) (db.random F)] | Acc]))

(define do.statements
  Vars Heap Assigns Fields Loads
  -> (append (do.alloc Vars Heap [])
      (append (do.pairs assign Assigns Vars [])
       (append (do.triples load Loads Vars Fields [])
               (do.stores Loads Vars Fields [])))))

\* store(B, F, W): field F of what B points to gets what W points to. *\
(define do.stores
  0 _ _ Acc -> Acc
  M N F Acc -> (do.stores (- M 1) N F [[store (db.random N) (db.random F) (db.random N)] | Acc]))

(define do.alloc
  0 _ Acc -> Acc
  N Heap Acc -> (do.alloc (- N 1) Heap (if (= 0 (db.random 3)) [[alloc N (db.random Heap)] | Acc] Acc)))

\* One process runs one case, so that a slow order can be timed out on its own. The first run
   compiles, and the time is the best of two after it. *\
(define do.least
  A B -> (if (< A B) A B))

(define do.case
  Label Items Facts Rel Adaptive
  -> (let _ (set datalog.*adaptive* Adaptive)
          _ (datalog.define do.program Items)
          First (db.seconds (freeze (datalog.run do.program Facts)))
          A (fst (db.seconds (freeze (datalog.run do.program Facts))))
          B (fst (db.seconds (freeze (datalog.run do.program Facts))))
          Db (snd First)
       (output "~A | ~A | ~A ms | first ~A ms | ~A tuples | ~A~%"
               Label (if Adaptive "adaptive" "fixed") (db.ms (do.least A B)) (db.ms (fst First))
               (datalog.count Db Rel) (tl (datalog.stats Db)))))

(define do.small
  -> (do.statements 800 200 1200 5 300))

(define do.large
  -> (do.statements 1500 300 1800 20 500))

(define do.run
  chain-a A -> (do.case "chain, order a" (do.chain-a) (do.chain-facts) out A)
  chain-b A -> (do.case "chain, order b" (do.chain-b) (do.chain-facts) out A)
  small-a A -> (do.case "points-to small, order a" (do.points-to-a) (do.small) vpt A)
  small-b A -> (do.case "points-to small, order b" (do.points-to-b) (do.small) vpt A)
  large-a A -> (do.case "points-to large, order a" (do.points-to-a) (do.large) vpt A)
  large-b A -> (do.case "points-to large, order b" (do.points-to-b) (do.large) vpt A)
  small-c A -> (do.case "points-to small, order c" (do.points-to-c) (do.small) vpt A)
  large-c A -> (do.case "points-to large, order c" (do.points-to-c) (do.large) vpt A))
