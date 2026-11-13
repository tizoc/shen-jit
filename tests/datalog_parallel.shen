\* Datalog runs in parts (datalog.run-parallel), against datalog.run: programs that run in parts,
   with integer, symbol and string keys, constants and derived facts given; programs that do not,
   whose joins run in isolates, and generated ones (load tests/datalog-generate.shen first); and
   programs that run whole, as datalog.run does. Each run has ended before the next definition. *\

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

\* Whether stats agree but for how many indexes each relation has started, which a database that
   crossed has not, and derivations to within 1%: a plan whose relation grows derives its outer
   tuple's again, and each isolate grows its relations at other times. *\
(define dpp.counted
  [Rounds Plans | Rs] [Rounds Plans | Ss] -> (dpp.counted-h Rs Ss)
  _ _ -> false)

(define dpp.counted-h
  [] [] -> true
  [[R N D | _] | Rs] [[R N E | _] | Ss] -> (and (<= (* 100 (if (> D E) (- D E) (- E D))) E) (dpp.counted-h Rs Ss))
  _ _ -> false)

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

\* Two recursive components, the second reading the negation of the first, of symbols and strings. *\
(defdatalog dpp.layers
  (relation edge [symbol symbol])
  (relation label [symbol string])
  (relation reach [symbol symbol])
  (relation alone [symbol])
  (relation tagged [symbol string])
  (rule (reach X Y) <-- (edge X Y))
  (rule (reach X Z) <-- (reach X Y) (reach Y Z))
  (rule (alone X) <-- (edge X _) (not (reach X X)))
  (rule (tagged X L) <-- (label X L))
  (rule (tagged Y L) <-- (tagged X L) (reach X Y) (alone Y)))

\* Mutual recursion, each relation read at another key. *\
(defdatalog dpp.mutual
  (relation edge [integer integer])
  (relation even [integer integer])
  (relation odd [integer integer])
  (rule (odd X Y) <-- (edge X Y))
  (rule (even X Z) <-- (odd X Y) (edge Y Z))
  (rule (odd X Z) <-- (even X Y) (odd Y Z) (< X 30)))

\* Tuples wider than a kernel has registers for, and a variant with no lookup after its new tuples,
   which go to isolates by every column. *\
(defdatalog dpp.wide
  (relation edge [integer integer])
  (relation row [integer integer integer integer integer integer integer integer])
  (rule (row X Y 1 2 3 4 5 6) <-- (edge X Y))
  (rule (row X Z A B C D E F) <-- (row X Y A B C D E F) (row Y Z _ _ _ _ _ _))
  (rule (row Y X F E D C B A) <-- (row X Y A B C D E F)))

(defdatalog dpp.strings
  (relation word [string])
  (relation longer [string])
  (rule (longer W) <-- (word W))
  (rule (longer V) <-- (longer W) (= V (cat W "a")) (< (strlen W) 4)))

(defdatalog dpp.keyed
  (relation edge [integer integer])
  (relation dist [integer integer] min)
  (rule (dist X 0) <-- (edge X _))
  (rule (dist Y D) <-- (dist X D0) (edge X Y) (= D (+ D0 1))))

(dpp.check "a program that runs in parts" [parts integer [path two home]] (datalog.partition dpp.paths))
(dpp.check "a key that changes runs its joins in isolates" [joins "a derived atom of a body changes the key"]
  (datalog.partition dpp.nonlinear))
(dpp.check "and so does one with negation" joins (hd (datalog.partition dpp.layers)))
(dpp.check "a program with no recursive rule runs whole" [sequential "no rule is recursive"] (datalog.partition dpp.negated))
(dpp.check "as does one that makes strings" [sequential "a rule that makes a string is not run in isolates"]
  (datalog.partition dpp.strings))
(dpp.check "or keeps one tuple a key" sequential (hd (datalog.partition dpp.keyed)))

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
(dpp.compare "a program that runs whole" 4 dpp.negated (dpp.edges 120 40 []) [leaf inner] [[leaf [var "X"]]])
(dpp.compare "and one that makes strings" 3 dpp.strings [[word "b"] [word "cc"]] [longer] [[longer [var "W"]]])
(dpp.compare "or keeps one tuple a key" 3 dpp.keyed (dpp.edges 120 40 []) [dist] [[dist 1 [var "D"]]])

\* Joins in isolates: the same tuples, rounds and derivations as datalog.run, in any number of
   isolates, with more isolates than new tuples too. *\
(set dpp.dense (dpp.edges 300 60 []))
(map (/. N (do (dpp.compare (make-string "joins in ~An isolates" N) N dpp.nonlinear (value dpp.dense) [edge path]
                 [[path 3 [var "Y"]] [path [var "X"] 4] [path 5 5] [path 1000 1]])
               (dpp.check (make-string "with the rounds, plans and about the derivations of a run, in ~A" N)
                 (dpp.counted (datalog.stats (datalog.run-parallel N dpp.nonlinear (value dpp.dense)))
                   (datalog.stats (datalog.run dpp.nonlinear (value dpp.dense))))
                 true)))
     [2 3 8])
(dpp.compare "joins for one edge" 6 dpp.nonlinear [[edge 1 2]] [path] [[path 1 2]])
(dpp.compare "joins for no facts" 3 dpp.nonlinear [] [path] [[path 1 2]])

(dpp.compare "two components, symbols and strings" 4 dpp.layers
  (append (map (/. F [edge (dpp.symbol (hd (tl F))) (dpp.symbol (hd (tl (tl F))))]) (dpp.edges 90 50 []))
          (map (/. F [label (dpp.symbol (hd (tl F))) (cn "s" (str (hd (tl (tl F)))))]) (dpp.edges 20 50 [])))
  [reach alone tagged] [[tagged [var "X"] "s1"] [alone [var "X"]] [reach n1 [var "Y"]]])
(dpp.compare "mutual recursion" 5 dpp.mutual (dpp.edges 200 50 []) [even odd] [[odd 1 [var "Y"]] [even [var "X"] 2]])
(dpp.compare "wide tuples" 4 dpp.wide (dpp.edges 60 30 []) [row] [[row 1 [var "Y"] 1 2 3 4 5 6]])

\* A database from joins in isolates takes facts, removes them and explains, as one from a run does;
   both change in place. *\
(let Facts (dpp.edges 150 50 [])
     More (dpp.edges 20 50 [])
     Db (datalog.run-parallel 4 dpp.nonlinear Facts)
     Run (datalog.run dpp.nonlinear Facts)
  (do (dpp.check "adding to joins" (datalog.sorted (datalog.add Db More) path) (datalog.sorted (datalog.add Run More) path))
      (dpp.check "removing from joins" (datalog.sorted (datalog.remove Db More) path)
                 (datalog.sorted (datalog.remove Run More) path))
      (dpp.check "explaining joins" true (cons? (datalog.explain Db [path | (hd (datalog.tuples Db path))])))))

(dpp.check "a fact of no relation raises as in a run"
  (trap-error (datalog.run-parallel 4 dpp.nonlinear [[edge 1 2] [nope 1 2]]) (/. E (error-to-string E)))
  (trap-error (datalog.run dpp.nonlinear [[edge 1 2] [nope 1 2]]) (/. E (error-to-string E))))

\* Generated programs, against datalog.run, all of whose relations it gives: those whose joins run
   in isolates are counted. *\
(set dpp.joined 0)
(define dpp.generated
  0 -> ok
  N -> (let Program (dtg.program)
            Relations (hd Program)
            Facts (hd (tl (tl Program)))
            Name (dtg.numbered "dpp.g" N)
            _ (datalog.define Name (dtg.items Relations (hd (tl Program))))
            _ (if (= (hd (datalog.partition Name)) joins) (set dpp.joined (+ 1 (value dpp.joined))) skip)
            Names (map (function hd) Relations)
            _ (dpp.check (make-string "generated ~A" N)
                (map (/. R (datalog.sorted (datalog.run-parallel 3 Name Facts) R)) Names)
                (map (/. R (datalog.sorted (datalog.run Name Facts) R)) Names))
         (dpp.generated (- N 1))))
(dpp.generated 100)
(dpp.check "some generated programs ran their joins in isolates" true (> (value dpp.joined) 20))

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
