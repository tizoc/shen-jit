\* depends: what calls what among Shen and KL source files, worked out by lib/datalog.shen.

   Build the executable from the repository root:
     build/shen-jit eval -q -l lib/native.shen -l lib/datalog.shen -l example-apps/depends/main.shen \
       -e '(shen-jit.save-executable "depends" depends.main)'
   Run it:
     ./depends [--root F]... [--why F G] [--reach F] [--out DIR] FILE...

   Each define of a .shen file, and each defun of a .kl file, defines a function; a symbol at the
   head of a form in its body is a call. Forms the language gives meaning to, such as let and if,
   are not calls, and a function no file defines is external. *\

(defdatalog depends.program
  (type place [at string integer])
  (relation defines [symbol place])
  (relation calls [symbol symbol])
  (relation root [symbol])
  (relation some-root [])
  (relation defined [symbol])
  (relation in-file [symbol string])
  (relation file-uses [string string])
  (relation file-depends [string string])
  (relation cycle [string string] equivalence)
  (relation cyclic [string])
  (relation reaches [symbol symbol])
  (relation recursive [symbol])
  (relation live [symbol])
  (relation dead [symbol])
  (relation external [symbol])
  (relation external-call [symbol symbol])
  (relation fan-in [symbol integer])
  (relation depth [symbol integer] min)
  (rule (defined F) <-- (defines F _))
  (rule (in-file F File) <-- (defines F [at File _]))
  (rule (file-uses A B) <-- (in-file F A) (calls F G) (in-file G B) (!= A B))
  (rule (file-depends A B) <-- (file-uses A B))
  (rule (file-depends A C) <-- (file-uses A B) (file-depends B C))
  (rule (cycle A B) <-- (file-depends A B) (file-depends B A))
  (rule (cyclic A) <-- (cycle A B) (!= A B))
  (rule (reaches F G) <-- (calls F G))
  (rule (reaches F H) <-- (calls F G) (reaches G H))
  (rule (recursive F) <-- (reaches F F))
  (rule (some-root) <-- (root _))
  (rule (live F) <-- (root F))
  (rule (live G) <-- (live F) (calls F G) (defined G))
  (rule (dead F) <-- (defined F) (some-root) (not (live F)))
  (rule (external G) <-- (calls _ G) (not (defined G)))
  (rule (external-call F G) <-- (calls F G) (external G))
  (rule (fan-in G N) <-- (defined G) (= N (count (calls _ G))))
  (rule (depth F 0) <-- (root F))
  (rule (depth G D) <-- (depth F D0) (calls F G) (defined G) (= D (+ D0 1))))

\* ---- Facts from source. *\

(define depends.special?
  S -> (element? S [define defun let lambda /. if cases cond do freeze trap-error and or where -> <-
                    package defmacro datatype type function fn]))

(define depends.file-facts
  File -> (depends.forms-facts File (read-file File) 0 []))

(define depends.forms-facts
  _ [] _ Acc -> Acc
  File [Form | Forms] I Acc -> (depends.forms-facts File Forms (+ I 1) (depends.form-facts File Form I Acc)))

(define depends.form-facts
  File [define F | Body] I Acc -> (depends.calls-of F Body [[defines F [at File I]] | Acc]) where (symbol? F)
  File [defun F _ Body] I Acc -> (depends.calls-of F Body [[defines F [at File I]] | Acc]) where (symbol? F)
  File [package _ _ | Forms] I Acc -> (depends.forms-facts File Forms I Acc)
  _ _ _ Acc -> Acc)

\* The calls in a body: each symbol heading a form, and what (function F) or (fn F) names. *\
(define depends.calls-of
  F Body Acc -> (depends.heads F Body Acc))

(define depends.heads
  F [Op G] Acc -> [[calls F G] | Acc] where (and (element? Op [function fn]) (symbol? G))
  F [Op | Args] Acc -> (depends.heads-of F Args (if (or (not (symbol? Op)) (variable? Op) (depends.special? Op))
                                                  Acc
                                                  [[calls F Op] | Acc]))
                       where (symbol? Op)
  F [X | Xs] Acc -> (depends.heads-of F [X | Xs] Acc)
  _ _ Acc -> Acc)

(define depends.heads-of
  _ [] Acc -> Acc
  F [X | Xs] Acc -> (depends.heads-of F Xs (depends.heads F X Acc))
  _ _ Acc -> Acc)

(define depends.facts
  Files Roots -> (append (map (/. R [root R]) Roots) (mapcan (function depends.file-facts) Files)))

\* ---- The command line. *\

(define depends.main
  -> (trap-error (depends.command (tl (value *argv*)) [] [] [] [] [])
                 (/. E (do (output "depends: ~A~%" (error-to-string E)) (shen-jit.exit 2)))))

(define depends.command
  ["--root" F | Args] Roots Why Reach Out Files -> (depends.command Args [(intern F) | Roots] Why Reach Out Files)
  ["--why" F G | Args] Roots _ Reach Out Files -> (depends.command Args Roots [(intern F) (intern G)] Reach Out Files)
  ["--reach" F | Args] Roots Why _ Out Files -> (depends.command Args Roots Why [(intern F)] Out Files)
  ["--out" Dir | Args] Roots Why Reach _ Files -> (depends.command Args Roots Why Reach [Dir] Files)
  [File | Args] Roots Why Reach Out Files -> (depends.command Args Roots Why Reach Out [File | Files])
      where (not (= (pos File 0) "-"))
  [Arg | _] _ _ _ _ _ -> (error "unknown option ~A; usage: depends [--root F]... [--why F G] [--reach F] [--out DIR] FILE..." Arg)
  [] _ _ _ _ [] -> (error "no files; usage: depends [--root F]... [--why F G] [--reach F] [--out DIR] FILE...")
  [] Roots Why Reach Out Files -> (depends.act (reverse Roots) Why Reach Out (reverse Files)))

\* A question about one function asks by demand, and computes only what bears on it. The pattern is
   data, as F is a value here: datalog.query would read it as a Datalog variable. *\
(define depends.act
  Roots [] [F] _ Files -> (depends.print-reach F (datalog.solve depends.program (depends.facts Files Roots) [reaches F [var "X"]]))
  Roots Why _ Out Files
  -> (let Db (datalog.run depends.program (depends.facts Files Roots))
       (cases (cons? Why) (depends.print-why (datalog.explain Db [reaches | Why]) Why)
              (cons? Out) (depends.write-all Db (hd Out))
              true (depends.report Db Roots))))

(define depends.print-reach
  F Tuples -> (do (output "~A reaches ~A functions~%" F (length Tuples))
                  (map (/. T (output "  ~A~%" (hd (tl T)))) (datalog.sort Tuples))
                  ok))

(define depends.print-why
  [] [F G] -> (output "~A does not reach ~A~%" F G)
  Proof _ -> (depends.print-proof Proof ""))

(define depends.print-proof
  [[Rel | Values] fact] Indent -> (output "~A~A~%" Indent (depends.tuple [Rel | Values]))
  [[Rel | Values] _ | Proofs] Indent
  -> (do (output "~A~A, as~%" Indent (depends.tuple [Rel | Values]))
         (map (/. P (depends.print-proof P (cn Indent "  "))) Proofs)
         ok))

(define depends.tuple
  [calls F G] -> (make-string "~A calls ~A" F G)
  [reaches F G] -> (make-string "~A reaches ~A" F G)
  Tuple -> (make-string "~S" Tuple))

(define depends.write-all
  Db Dir -> (map (/. R (output "~A: ~A~%" R (datalog.write-facts Db R (cn Dir (cn "/" (cn (str R) ".tsv"))))))
                 [defines calls in-file file-uses file-depends cyclic reaches recursive live dead external fan-in depth]))

(define depends.report
  Db Roots
  -> (let Files (datalog.unique (map (/. T (hd (tl T))) (datalog.tuples Db in-file)) [])
       (do (output "~A files, ~A functions, ~A calls, ~A to ~A external functions~%"
                   (length Files) (datalog.count Db defined) (datalog.count Db calls)
                   (datalog.count Db external-call) (datalog.count Db external))
           (output "~A file dependencies, ~A files in cycles~%" (datalog.count Db file-uses) (datalog.count Db cyclic))
           (map (/. Group (output "  cycle: ~A~%" (depends.words Group))) (depends.cycles Db))
           (output "~A recursive functions~%" (datalog.count Db recursive))
           (output "most called: ~A~%" (depends.words (map (/. T (make-string "~A (~A)" (hd T) (hd (tl T))))
                                                          (depends.take 5 (depends.by-count (datalog.tuples Db fan-in))))))
           (if (empty? Roots)
               ok
               (do (output "from ~A: ~A live, ~A dead, ~A deepest at ~A calls~%"
                           (depends.words Roots) (datalog.count Db live) (datalog.count Db dead)
                           (length (depends.deepest (datalog.tuples Db depth))) (depends.max-depth (datalog.tuples Db depth) 0))
                   (map (/. T (output "  dead: ~A~%" (hd T))) (datalog.sorted Db dead))
                   ok)))))

\* Files in a cycle, each group once, from the equivalence. *\
(define depends.cycles
  Db -> (depends.groups (datalog.sorted Db cyclic) Db []))

(define depends.groups
  [] _ Acc -> (reverse Acc)
  [[File] | Files] Db Acc
  -> (if (some? (/. G (element? File G)) Acc)
         (depends.groups Files Db Acc)
         (depends.groups Files Db [(map (/. T (hd (tl T))) (datalog.sort (datalog.match Db [cycle File [var "B"]]))) | Acc])))

(define some?
  _ [] -> false
  F [X | Xs] -> (or (F X) (some? F Xs)))

(define depends.words
  [] -> ""
  [X] -> (make-string "~A" X)
  [X | Xs] -> (make-string "~A, ~A" X (depends.words Xs)))

(define depends.by-count
  Tuples -> (reverse (depends.sort-by-count Tuples)))

(define depends.sort-by-count
  [] -> []
  [X | Xs] -> (let Smaller (depends.filter (/. Y (depends.before? Y X)) Xs)
                   Larger (depends.filter (/. Y (not (depends.before? Y X))) Xs)
                (append (depends.sort-by-count Smaller) [X | (depends.sort-by-count Larger)])))

(define depends.before?
  [F N] [G M] -> (or (< N M) (and (= N M) (datalog.value< G F))))

(define depends.filter
  _ [] -> []
  F [X | Xs] -> (if (F X) [X | (depends.filter F Xs)] (depends.filter F Xs)))

(define depends.take
  0 _ -> []
  _ [] -> []
  N [X | Xs] -> [X | (depends.take (- N 1) Xs)])

(define depends.max-depth
  [] M -> M
  [[_ D] | Ds] M -> (depends.max-depth Ds (if (> D M) D M)))

(define depends.deepest
  Depths -> (let M (depends.max-depth Depths 0) (depends.filter (/. T (= (hd (tl T)) M)) Depths)))
