\* Datalog in isolates: a program the builder shares (datalog.share) runs in an isolate (datalog.use),
   which cannot compile, and gives what the plain definition does. Generated programs (load
   tests/datalog-generate.shen first) and programs of keyed relations and lattices, which it does
   not make. Everything is defined first, and each isolate has ended before the builder defines the
   next program. *\

(set dp.*checks* 0)
(set dp.*failures* 0)

(define dp.check
  Name Got Want -> (do (set dp.*checks* (+ 1 (value dp.*checks*)))
                       (if (= Got Want)
                           ok
                           (do (set dp.*failures* (+ 1 (value dp.*failures*)))
                               (output "FAIL ~A: got ~R, want ~R~%" Name Got Want)))))

(define dp.take
  0 _ -> []
  _ [] -> []
  N [X | Xs] -> [X | (dp.take (- N 1) Xs)])

(define dp.drop
  0 Xs -> Xs
  _ [] -> []
  N [_ | Xs] -> (dp.drop (- N 1) Xs))

(define dp.middle
  Facts -> (let Third (/ (- (length Facts) (shen.mod (length Facts) 3)) 3)
             (dp.take Third (dp.drop Third Facts))))

(define dp.without
  [] _ -> []
  [F | Fs] Gone -> (if (element? F Gone) (dp.without Fs Gone) [F | (dp.without Fs Gone)]))

(define dp.relations
  Name -> (map (function hd) (nth 3 (datalog.program Name))))

\* What an isolate gives for a program: every relation sorted after a run, after a removal, and after
   facts added in two parts, a query by demand, the same query on the database, and what a database
   by demand answers for it. *\
(define dp.answers
  Name Facts Pattern
  -> (let Db (datalog.run Name Facts)
          Middle (dp.middle Facts)
          Removed (datalog.remove (datalog.run Name Facts) Middle)
          Half (dp.take (/ (- (length Facts) (shen.mod (length Facts) 2)) 2) Facts)
          Added (datalog.add (datalog.run Name Half) (dp.drop (length Half) Facts))
          Kept (datalog.demand-db Name Half)
          _ (datalog.add Kept (dp.drop (length Half) Facts))
       [(map (/. R (datalog.sorted Db R)) (dp.relations Name))
        (map (/. R (datalog.sorted Removed R)) (dp.relations Name))
        (map (/. R (datalog.sorted Added R)) (dp.relations Name))
        (datalog.sort (datalog.solve Name Facts Pattern))
        (datalog.sort (datalog.match Db Pattern))
        (datalog.sort (datalog.match Kept Pattern))]))

\* The same from the plain definition, in the builder. *\
(define dp.expected
  Name Facts Pattern
  -> (let Reference (datalog.run-naive Name Facts)
          Left (datalog.run-naive Name (dp.without Facts (dp.middle Facts)))
          Answers (datalog.sort (datalog.match Reference Pattern))
       [(map (/. R (datalog.sorted Reference R)) (dp.relations Name))
        (map (/. R (datalog.sorted Left R)) (dp.relations Name))
        (map (/. R (datalog.sorted Reference R)) (dp.relations Name))
        Answers Answers Answers]))

(define dp.isolate
  [Shared Facts Pattern Out] -> (shen-jit.send Out (dp.answers (datalog.use Shared) Facts Pattern)))

\* Shares Name and runs it in an isolate, giving its answers, or [failed Reason] if it raised. *\
(define dp.in-isolate
  Name Facts Pattern
  -> (let Shared (datalog.share Name)
          R (shen-jit.channel 1)
          M (shen-jit.monitor (shen-jit.spawn dp.isolate [Shared Facts Pattern (shen-jit.sender R)]))
          Got (shen-jit.receive-any [R M])
          Down (if (= (hd Got) R) (shen-jit.receive M) skip)
       (if (= (hd Got) R) (hd (tl Got)) [failed (nth 3 (hd (tl Got)))])))

(define dp.term
  Type -> (let R (dtg.random 6)
            (cases (< R 3) (dtg.value Type)
                   (< R 5) [var (dtg.choose ["X" "Y"])]
                   true [any])))

\* Generated programs. The builder runs some first, adaptively, so that their plans come with the
   program, and asks some of their queries, so that the demand programs do. *\
(define dp.generated
  0 -> ok
  N -> (let Program (dtg.program)
            Relations (hd Program)
            Facts (hd (tl (tl Program)))
            Name (dtg.numbered "dp.g" N)
            _ (datalog.define Name (dtg.items Relations (hd (tl Program))))
            Rel (dtg.choose Relations)
            Pattern [(hd Rel) | (dtg.map (function dp.term) (tl Rel))]
            _ (if (= 0 (shen.mod N 2)) (datalog.run Name Facts) skip)
            _ (if (= 0 (shen.mod N 3)) (datalog.solve Name Facts Pattern) skip)
            _ (dp.check (make-string "generated ~A in an isolate" N)
                (dp.in-isolate Name Facts Pattern) (dp.expected Name Facts Pattern))
         (dp.generated (- N 1))))

(dp.generated 60)

\* Keyed relations: the least, the greatest and any one value for a key. *\
(defdatalog dp.paths
  (relation edge [integer integer integer])
  (relation start [integer])
  (relation dist [integer integer] min)
  (relation widest [integer integer] max)
  (relation via [integer integer] choice)
  (rule (dist X 0) <-- (start X))
  (rule (dist Y D) <-- (dist X D0) (edge X Y W) (= D (+ D0 W)))
  (rule (widest X 1000) <-- (start X))
  (rule (widest Y W) <-- (widest X B0) (edge X Y W) (< W B0))
  (rule (via Y X) <-- (dist X _) (edge X Y _)))

(set dp.path-facts [[start 1] [edge 1 2 5] [edge 2 3 5] [edge 1 4 1] [edge 4 2 1] [edge 3 1 2] [edge 4 3 9]])

(define dp.keyed
  [Shared Facts Out] -> (let Name (datalog.use Shared)
                             Db (datalog.run Name Facts)
                    (shen-jit.send Out [(datalog.sorted Db dist) (datalog.sorted Db widest) (datalog.count Db via)
                                        (datalog.holds? Db [dist 3 7]) (datalog.ask Db (dist 3 D))])))

\* Lattices, joined by functions the program defines. *\
(define dp.union A B -> (shen-jit.bit-or A B))
(define dp.flat A A -> A _ _ -> 2147483647)
(defdatalog dp.lattices
  (relation edge [integer integer])
  (relation start [integer integer])
  (relation reached-by [integer integer] (lattice dp.union))
  (relation assign [integer integer])
  (relation copy [integer integer])
  (relation const [integer integer] (lattice dp.flat))
  (relation known [integer])
  (rule (reached-by X M) <-- (start X I) (= M (bshl 1 I)))
  (rule (reached-by Y M) <-- (reached-by X M) (edge X Y))
  (rule (const X C) <-- (assign X C))
  (rule (const Y C) <-- (copy X Y) (const X C))
  (rule (known X) <-- (const X C) (!= C 2147483647)))

(set dp.lattice-facts [[start 1 0] [start 4 1] [edge 1 2] [edge 2 3] [edge 4 3] [edge 3 5] [edge 5 3]
                       [assign 10 7] [copy 10 11] [assign 12 7] [copy 12 11] [assign 13 8] [copy 13 14]
                       [copy 11 14]])

(define dp.lattice
  [Shared Facts Out] -> (let Name (datalog.use Shared)
                             Db (datalog.run Name Facts)
                    (shen-jit.send Out [(datalog.sorted Db reached-by) (datalog.sorted Db const)
                                        (datalog.sorted Db known)])))

(define dp.ask
  F Shared Facts -> (let R (shen-jit.channel 1)
                   M (shen-jit.monitor (shen-jit.spawn F [Shared Facts (shen-jit.sender R)]))
                   Got (shen-jit.receive-any [R M])
                   _ (if (= (hd Got) R) (shen-jit.receive M) skip)
                (if (= (hd Got) R) (hd (tl Got)) [failed (nth 3 (hd (tl Got)))])))

(set dp.path-db (datalog.run dp.paths (value dp.path-facts)))
(dp.check "keyed relations in an isolate"
  (dp.ask dp.keyed (datalog.share dp.paths) (value dp.path-facts))
  [(datalog.sorted (value dp.path-db) dist) (datalog.sorted (value dp.path-db) widest)
   (datalog.count (value dp.path-db) via) (datalog.holds? (value dp.path-db) [dist 3 7])
   (datalog.ask (value dp.path-db) (dist 3 D))])

(set dp.lattice-db (datalog.run dp.lattices (value dp.lattice-facts)))
(dp.check "lattices in an isolate"
  (dp.ask dp.lattice (datalog.share dp.lattices) (value dp.lattice-facts))
  [(datalog.sorted (value dp.lattice-db) reached-by) (datalog.sorted (value dp.lattice-db) const)
   (datalog.sorted (value dp.lattice-db) known)])

(dp.check "only a shared program is used" true
  (trap-error (do (datalog.use [dp.paths]) false) (/. E true)))

(output "~A checks, ~A failed~%" (value dp.*checks*) (value dp.*failures*))
