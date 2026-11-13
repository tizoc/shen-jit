\* Datalog runs in parts (datalog.run-parallel), against datalog.run: programs that run in parts,
   with integer, symbol and string keys, constants and derived facts given, and programs that do
   not, which run as datalog.run does. Everything is defined first. *\

(set dpp.*checks* 0)
(set dpp.*failures* 0)

(define dpp.check
  Name Got Want -> (do (set dpp.*checks* (+ 1 (value dpp.*checks*)))
                       (if (= Got Want)
                           ok
                           (do (set dpp.*failures* (+ 1 (value dpp.*failures*)))
                               (output "FAIL ~A: got ~R, want ~R~%" Name Got Want)))))

(define dpp.raises?
  F -> (trap-error (do (thaw F) false) (/. E true)))

(set dpp.*seed* 7)

(define dpp.random
  N -> (let S (shen.mod (* (value dpp.*seed*) 48271) 2147483647)
            _ (set dpp.*seed* S)
         (shen.mod S N)))

(define dpp.edges
  0 _ Acc -> Acc
  N Nodes Acc -> (dpp.edges (- N 1) Nodes [[edge (dpp.random Nodes) (dpp.random Nodes)] | Acc]))

(define dpp.symbol
  N -> (intern (cn "n" (str N))))

(define dpp.named
  [] -> []
  [[Rel A B] | Fs] -> [[Rel (dpp.symbol A) (cn "s" (str B))] | (dpp.named Fs)])

\* What a database answers: every relation sorted and counted, membership, and queries by key, by a
   later column and by none. *\
(define dpp.answers
  Db Relations Probes
  -> [(map (/. R (datalog.sorted Db R)) Relations)
      (map (/. R (datalog.count Db R)) Relations)
      (map (/. P (datalog.holds? Db P)) Probes)
      (map (/. P (datalog.sort (datalog.match Db P))) Probes)])

(define dpp.compare
  Label N Name Facts Relations Probes
  -> (dpp.check Label (dpp.answers (datalog.run-parallel N Name Facts) Relations Probes)
                      (dpp.answers (datalog.run Name Facts) Relations Probes)))

(defdatalog dpp.paths
  (relation edge [integer integer])
  (relation path [integer integer])
  (relation two [integer integer])
  (relation home [integer integer])
  (rule (path X Y) <-- (edge X Y))
  (rule (path X Z) <-- (path X Y) (edge Y Z))
  (rule (two X Z) <-- (edge X Y) (edge Y Z) (!= X Z))
  (rule (home 0 Y) <-- (edge Y 0)))

(defdatalog dpp.names
  (relation edge [symbol string])
  (relation link [string symbol])
  (relation reach [symbol string])
  (rule (reach X Y) <-- (edge X Y))
  (rule (reach X Z) <-- (reach X Y) (link Y W) (edge W Z)))

(defdatalog dpp.nonlinear
  (relation edge [integer integer])
  (relation path [integer integer])
  (rule (path X Y) <-- (edge X Y))
  (rule (path X Z) <-- (path X Y) (path Y Z)))

(defdatalog dpp.negated
  (relation edge [integer integer])
  (relation leaf [integer])
  (relation inner [integer])
  (rule (inner X) <-- (edge X _))
  (rule (leaf Y) <-- (edge _ Y) (not (inner Y))))

(dpp.check "a program that runs in parts" [parallel integer [path two home]] (datalog.partition dpp.paths))
(dpp.check "a key that changes runs whole" sequential (hd (datalog.partition dpp.nonlinear)))
(dpp.check "negation runs whole" sequential (hd (datalog.partition dpp.negated)))

(set dpp.facts (dpp.edges 300 120 [[path 500 501] [edge 7 0]]))
(set dpp.probes [[path 7 0] [path 3 [var "Y"]] [path [var "X"] 4] [two [var "X"] [var "Y"]] [home 0 7]
                 [edge 7 [var "Y"]] [path 500 501]])

(map (/. N (dpp.compare (make-string "integer keys in ~A parts" N) N dpp.paths (value dpp.facts)
             [edge path two home] (value dpp.probes)))
     [2 3 8 64])

(dpp.compare "symbol keys and string columns" 4 dpp.names
  (append (dpp.named (dpp.edges 200 60 [])) (map (/. F [link (cn "s" (str (hd (tl F)))) (dpp.symbol (hd (tl (tl F))))])
                                                (dpp.edges 80 60 [])))
  [edge link reach] [[reach n1 [var "Y"]] [reach [var "X"] "s2"]])

(dpp.compare "one part runs whole" 1 dpp.paths (value dpp.facts) [path] [[path 1 [var "Y"]]])
(dpp.compare "no facts" 4 dpp.paths [] [path two] [[path 1 2]])
(dpp.compare "fewer keys than parts" 8 dpp.paths [[edge 1 2]] [path] [[path 1 2]])
(dpp.compare "a program that runs whole" 4 dpp.nonlinear (dpp.edges 120 40 []) [path] [[path 1 [var "Y"]]])
(dpp.compare "and with negation" 4 dpp.negated (dpp.edges 120 40 []) [leaf inner] [[leaf [var "X"]]])

(dpp.check "a fact of no relation raises in the builder" true
  (dpp.raises? (freeze (datalog.run-parallel 4 dpp.paths [[nope 1 2]]))))

(let Db (datalog.run-parallel 4 dpp.paths (value dpp.facts))
  (do (dpp.check "a database in parts does not take facts" true (dpp.raises? (freeze (datalog.add Db [[edge 1 2]]))))
      (dpp.check "nor explain" true (dpp.raises? (freeze (datalog.explain Db [path 7 0]))))))

\* The program is defined, and can change, once a run in parts has ended. *\
(defdatalog dpp.later
  (relation a [integer])
  (relation b [integer])
  (rule (b X) <-- (a X)))
(dpp.check "defining after a run in parts" [[1]] (datalog.sorted (datalog.run-parallel 2 dpp.later [[a 1]]) b))

(output "~A checks, ~A failed~%" (value dpp.*checks*) (value dpp.*failures*))
