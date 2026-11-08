\* Datalog workloads: lib/datalog.shen over a generated graph of each shape, and an actual source
   analysis, the call graph of the kernel's KL. Each row is one run: the seconds of the first run,
   which compiles, of a later one, and what it derived.
   Usage: shen-jit eval -l lib/native.shen -l lib/datalog.shen -l tests/bench/datalog.shen -e '(db.main "KLAMBDA_DIR")' *\

(set db.*seed* 2463534242)

(define db.random
  N -> (let Next (shen-jit.bit-and (+ (* (value db.*seed*) 1103515) 12345) 1073741823)
            _ (set db.*seed* Next)
         (shen.mod (shen-jit.shift-right Next 8) N)))

(define db.seconds
  F -> (let T (get-time unix) R (thaw F) (@p (- (get-time unix) T) R)))

(defdatalog db.closure
  (relation edge [integer integer])
  (relation path [integer integer])
  (rule (path X Y) <-- (edge X Y))
  (rule (path X Z) <-- (path X Y) (edge Y Z)))

(defdatalog db.nonlinear
  (relation edge [integer integer])
  (relation path [integer integer])
  (rule (path X Y) <-- (edge X Y))
  (rule (path X Z) <-- (path X Y) (path Y Z)))

(defdatalog db.samegen
  (relation parent [integer integer])
  (relation same [integer integer])
  (rule (same X X) <-- (parent X _))
  (rule (same X X) <-- (parent _ X))
  (rule (same X Y) <-- (parent A X) (same A B) (parent B Y)))

(defdatalog db.mutual
  (relation edge [integer integer])
  (relation start [integer])
  (relation even [integer])
  (relation odd [integer])
  (rule (even X) <-- (start X))
  (rule (odd Y) <-- (even X) (edge X Y))
  (rule (even Y) <-- (odd X) (edge X Y)))

(defdatalog db.triangles
  (relation edge [integer integer])
  (relation triangle [integer integer integer])
  (rule (triangle X Y Z) <-- (edge X Y) (edge Y Z) (edge Z X) (< X Y) (< Y Z)))

\* Every edge's head is one of a few nodes, so that a join on it has many tuples per key. *\
(defdatalog db.skew
  (relation edge [integer integer])
  (relation two [integer integer])
  (relation count-two [integer])
  (rule (two X Z) <-- (edge X Y) (edge Y Z))
  (rule (count-two X) <-- (two X X)))

(defdatalog db.calls
  (relation defines [symbol])
  (relation calls [symbol symbol])
  (relation root [symbol])
  (relation reaches [symbol symbol])
  (relation recursive [symbol])
  (relation live [symbol])
  (relation errors [symbol])
  (rule (reaches F G) <-- (calls F G))
  (rule (reaches F H) <-- (calls F G) (reaches G H))
  (rule (recursive F) <-- (reaches F F))
  (rule (live F) <-- (root F))
  (rule (live G) <-- (live F) (calls F G) (defines G))
  (rule (errors F) <-- (reaches F simple-error) (defines F)))

\* The same call graph, asked what an analysis asks: what is dead, what calls nothing defined,
   what is called and never defined, fan-in and fan-out, the hubs, and each function's shortest
   call depth from a root, bounded. Negation, aggregates and arithmetic. *\
(defdatalog db.analysis
  (relation defines [symbol])
  (relation calls [symbol symbol])
  (relation root [symbol])
  (relation live [symbol])
  (relation dead [symbol])
  (relation leaf [symbol])
  (relation undefined [symbol])
  (relation fan-out [symbol integer])
  (relation fan-in [symbol integer])
  (relation hub [symbol])
  (relation depth [symbol integer])
  (relation shallowest [symbol integer])
  (rule (live F) <-- (root F))
  (rule (live G) <-- (live F) (calls F G) (defines G))
  (rule (dead F) <-- (defines F) (not (live F)))
  (rule (leaf F) <-- (defines F) (not (calls F _)))
  (rule (undefined G) <-- (calls _ G) (not (defines G)))
  (rule (fan-out F N) <-- (defines F) (= N (count (calls F _))))
  (rule (fan-in G N) <-- (defines G) (= N (count (calls _ G))))
  (rule (hub G) <-- (fan-in G N) (>= N 20))
  (rule (depth F 0) <-- (root F))
  (rule (depth G D) <-- (depth F D0) (calls F G) (defines G) (= D (+ D0 1)) (<= D 12))
  (rule (shallowest F M) <-- (live F) (= M (min D (depth F D)))))

(define db.random-edges
  0 _ Acc -> Acc
  M N Acc -> (db.random-edges (- M 1) N [[edge (db.random N) (db.random N)] | Acc]))

(define db.layered
  0 _ _ Acc -> Acc
  M Width Depth Acc
  -> (let Level (db.random Depth)
       (db.layered (- M 1) Width Depth
         [[parent (+ (* Level Width) (db.random Width)) (+ (* (+ Level 1) Width) (db.random Width))] | Acc])))

(define db.skewed
  0 _ _ Acc -> Acc
  M Hubs N Acc -> (db.skewed (- M 1) Hubs N
                    [(if (= 0 (db.random 2))
                         [edge (db.random N) (db.random Hubs)]
                         [edge (db.random Hubs) (db.random N)])
                     | Acc]))

\* The facts of the call graph: each defun, and each symbol that heads a form in its body. *\
(define db.heads
  [F | Args] Acc -> (db.heads-of Args (if (symbol? F) (adjoin F Acc) (db.heads F Acc)))
  _ Acc -> Acc)

(define db.heads-of
  [] Acc -> Acc
  [X | Xs] Acc -> (db.heads-of Xs (db.heads X Acc))
  _ Acc -> Acc)

(define db.not-form
  S -> (element? S [let lambda if do cons]))

(define db.form-facts
  [defun F _ Body] Acc
  -> (db.call-facts F (db.heads Body []) [[defines F] | Acc])
  _ Acc -> Acc)

(define db.call-facts
  _ [] Acc -> Acc
  F [G | Gs] Acc -> (db.call-facts F Gs (if (db.not-form G) Acc [[calls F G] | Acc])))

(define db.file-facts
  [] Acc -> Acc
  [Form | Forms] Acc -> (db.file-facts Forms (db.form-facts Form Acc)))

(define db.kl-files
  Dir -> (map (/. F (cn Dir (cn "/" F)))
              ["core.kl" "declarations.kl" "dict.kl" "load.kl" "macros.kl" "prolog.kl" "reader.kl"
               "sequent.kl" "sys.kl" "t-star.kl" "toplevel.kl" "track.kl" "types.kl" "writer.kl" "yacc.kl"]))

(define db.call-graph
  [] Acc -> [[root shen.shen] [root eval] | Acc]
  [File | Files] Acc -> (db.call-graph Files (db.file-facts (read-file File) Acc)))

(define db.row
  Label Name Facts Rel
  -> (let _ (datalog.forget-code Name)
          First (db.seconds (freeze (datalog.run Name Facts)))
          Second (db.seconds (freeze (datalog.run Name Facts)))
          Third (db.seconds (freeze (datalog.run Name Facts)))
          Db (snd First)
       (output "~A | first ~A | then ~A ~A | ~A tuples | ~A~%"
               Label (db.ms (fst First)) (db.ms (fst Second)) (db.ms (fst Third))
               (datalog.count Db Rel) (datalog.stats Db))))

\* A query by demand: the first, which rewrites the program for its pattern and compiles, and two
   more. *\
(define db.query-row
  Label Name Facts Pattern
  -> (let _ (put Name datalog.demands [])
          First (db.seconds (freeze (datalog.solve Name Facts Pattern)))
          Second (db.seconds (freeze (datalog.solve Name Facts Pattern)))
          Third (db.seconds (freeze (datalog.solve Name Facts Pattern)))
       (output "~A | first ~A | then ~A ~A | ~A answers~%"
               Label (db.ms (fst First)) (db.ms (fst Second)) (db.ms (fst Third)) (length (snd First)))))

(define db.ms
  S -> (/ (db.floor (* S 10000) 0) 10))

(define db.floor
  X I -> (if (> (+ I 1) X) I (db.floor X (+ I 1))))

(define db.naive
  Label Name Facts Rel
  -> (let R (db.seconds (freeze (datalog.run-naive Name Facts)))
       (output "~A | naive | ~A ms | ~A tuples~%" Label (db.ms (fst R)) (datalog.count (snd R) Rel))))

(define db.main
  Klambda
  -> (let Sparse (db.random-edges 3000 2000 [])
          Dense (db.random-edges 1500 300 [])
          Parents (db.layered 6000 40 30 [])
          Skew (db.skewed 8000 5 3000 [])
          Calls (db.call-graph (db.kl-files Klambda) [])
       (do (output "facts: calls ~A~%" (length Calls))
           (db.row "closure, sparse" db.closure Sparse path)
           (db.row "closure, dense" db.closure Dense path)
           (db.row "nonlinear, dense" db.nonlinear Dense path)
           (db.row "same generation" db.samegen Parents same)
           (db.row "mutual" db.mutual [[start 0] | Sparse] even)
           (db.row "triangles" db.triangles Dense triangle)
           (db.row "skewed join" db.skew Skew two)
           (db.row "kernel call graph" db.calls Calls reaches)
           (db.row "kernel analysis" db.analysis Calls depth)
           (db.query-row "closure, demand (path 1774 X)" db.closure Sparse [path 1774 [var "X"]])
           (db.query-row "closure, demand (path X 7)" db.closure Sparse [path [var "X"] 7])
           (db.query-row "call graph, demand (reaches X =)" db.calls Calls [reaches [var "X"] =])
           (db.naive "closure, 300 edges" db.closure (db.random-edges 300 200 []) path)
           ok)))
