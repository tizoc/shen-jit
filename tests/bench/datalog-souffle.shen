\* Writes each workload of tests/bench/datalog.shen and tests/bench/datalog-orders.shen for Soufflé:
   its program, and its facts as tab-separated files, then runs them here and writes what we get. See
   tests/bench/datalog-souffle.sh, which runs Soufflé on them and compares. *\

(define sf.name
  S -> (sf.dashes (str S)))

(define sf.dashes
  "" -> ""
  (@s "-" Rest) -> (cn "_" (sf.dashes Rest))
  (@s C Rest) -> (cn C (sf.dashes Rest)))

(define sf.type
  symbol -> "symbol"
  string -> "symbol"
  integer -> "number")

(define sf.join
  [] _ -> ""
  [X] _ -> X
  [X | Xs] Sep -> (cn X (cn Sep (sf.join Xs Sep))))

(define sf.columns
  [] _ -> []
  [T | Ts] I -> [(make-string "c~A:~A" I (sf.type T)) | (sf.columns Ts (+ I 1))])

(define sf.term
  [var V] -> V
  [any] -> "_"
  X -> (str X) where (number? X)
  X -> (cn (n->string 34) (cn (str X) (n->string 34))))

(define sf.atom
  [Rel | Terms] -> (make-string "~A(~A)" (sf.name Rel) (sf.join (map (function sf.term) Terms) ", ")))

(define sf.literal
  [Op A B] -> (make-string "~A ~A ~A" (sf.term A) Op (sf.term B)) where (datalog.comparison? Op)
  Atom -> (sf.atom Atom))

\* Atoms in the order written, as Soufflé joins them unless it is told otherwise. *\
(define sf.rule
  [Head []] -> (make-string "~A.c#10;" (sf.atom Head))
  [Head Body] -> (make-string "~A :- ~A.c#10;" (sf.atom Head) (sf.join (map (function sf.literal) Body) ", ")))

(define sf.write-all
  _ [] -> true
  S [Text | Texts] -> (do (pr Text S) (sf.write-all S Texts)))

\* Output is what differs: one program writes every relation to check it, and the other only prints
   sizes, so that it times evaluation. *\
(define sf.program
  Path Relations Rules Output
  -> (let S (open Path out)
          _ (sf.write-all S (map (/. R (make-string ".decl ~A(~A)c#10;.input ~A(IO=file, delimiter=c#34;\tc#34;)c#10;~Ac#10;"
                                                     (sf.name (hd R))
                                                     (sf.join (sf.columns (tl R) 1) ", ")
                                                     (sf.name (hd R))
                                                     (make-string Output (sf.name (hd R)))))
                                 Relations))
          _ (sf.write-all S (map (function sf.rule) Rules))
       (close S)))

(define sf.tsv
  Values -> (sf.join (map (function str) Values) "c#9;"))

\* A fact file for every relation, which an input directive needs even if it is empty. *\
(define sf.facts
  _ [] _ -> true
  Dir [[Rel | _] | Rs] Facts
  -> (let S (open (cn Dir (cn "/" (cn (sf.name Rel) ".facts"))) out)
          _ (sf.write-facts S Rel Facts)
          _ (close S)
       (sf.facts Dir Rs Facts)))

(define sf.write-facts
  _ _ [] -> true
  S Rel [[Rel | Values] | Fs] -> (do (pr (cn (sf.tsv Values) "c#10;") S) (sf.write-facts S Rel Fs))
  S Rel [_ | Fs] -> (sf.write-facts S Rel Fs))

(define sf.results
  _ _ [] -> true
  Dir Db [[Rel | _] | Rs]
  -> (let S (open (cn Dir (cn "/" (cn (sf.name Rel) ".ours"))) out)
          _ (sf.write-all S (map (/. T (cn (sf.tsv T) "c#10;")) (datalog.tuples Db Rel)))
          _ (close S)
       (sf.results Dir Db Rs)))

\* Best of three, each with the facts as a list, as a program would have them. *\
(define sf.best
  Name Facts 0 Best -> Best
  Name Facts N Best -> (let T (fst (db.seconds (freeze (datalog.run Name Facts))))
                         (sf.best Name Facts (- N 1) (if (< T Best) T Best))))

(define sf.case
  Base Tag Name Facts
  -> (let Program (datalog.program Name)
          Relations (datalog.nth 3 Program)
          Rules (datalog.nth 4 Program)
          Dir (cn Base (cn "/" Tag))
          _ (sf.program (cn Dir "/check.dl") Relations Rules ".output ~A(IO=file, delimiter=c#34;\tc#34;)")
          _ (sf.program (cn Dir "/time.dl") Relations Rules ".printsize ~A")
          _ (sf.facts Dir Relations Facts)
          _ (datalog.run Name Facts)
          Best (sf.best Name Facts 3 1000000)
          Db (datalog.run Name Facts)
          _ (sf.results Dir Db Relations)
          _ (output "OURS ~A ~A~%" Tag (db.ms Best))
          N (value sf.*parallel*)
       (if (> N 1)
           (let _ (datalog.run-parallel N Name Facts)
                Parallel (sf.best-parallel N Name Facts 3 1000000)
             (output "PARALLEL ~A ~A ~A~%" Tag (db.ms Parallel)
                     (if (= (sf.all-sorted (datalog.run-parallel N Name Facts) Relations) (sf.all-sorted Db Relations))
                         same
                         differ)))
           skip)))

(define sf.best-parallel
  N Name Facts 0 Best -> Best
  N Name Facts K Best -> (let T (fst (db.seconds (freeze (datalog.run-parallel N Name Facts))))
                           (sf.best-parallel N Name Facts (- K 1) (if (< T Best) T Best))))

(define sf.all-sorted
  Db Relations -> (map (/. R (datalog.sorted Db (hd R))) Relations))

(set sf.*parallel* 0)

(define sf.points-to
  Base Tag Items Facts
  -> (let Name (intern (cn "sf." Tag))
          _ (datalog.define Name Items)
       (sf.case Base Tag Name Facts)))

(define sf.main
  Base
  -> (let Sparse (db.random-edges 3000 2000 [])
          Dense (db.random-edges 1500 300 [])
          Parents (db.layered 6000 40 30 [])
          Skew (db.skewed 8000 5 3000 [])
          Calls (db.call-graph (db.kl-files ".deps/kernel/klambda") [])
       (do (sf.case Base "closure-sparse" db.closure Sparse)
           (sf.case Base "closure-dense" db.closure Dense)
           (sf.case Base "nonlinear" db.nonlinear Dense)
           (sf.case Base "same-generation" db.samegen Parents)
           (sf.case Base "mutual" db.mutual [[start 0] | Sparse])
           (sf.case Base "triangles" db.triangles Dense)
           (sf.case Base "skewed-join" db.skew Skew)
           (sf.case Base "call-graph" db.calls Calls)
           (set db.*seed* 2463534242)
           (let Small (do.small)
             (do (sf.points-to Base "points-to-small-a" (do.points-to-a) Small)
                 (sf.points-to Base "points-to-small-b" (do.points-to-b) Small)
                 (sf.points-to Base "points-to-small-c" (do.points-to-c) Small)))
           (set db.*seed* 2463534242)
           (let Large (do.large)
             (do (sf.points-to Base "points-to-large-a" (do.points-to-a) Large)
                 (sf.points-to Base "points-to-large-b" (do.points-to-b) Large)
                 (sf.points-to Base "points-to-large-c" (do.points-to-c) Large)))
           ok)))
