\\ Generated formulas as SMT-LIB, for tests/smt-z3.sh, with lib/smt.shen's answers beside them.

(define smt-z3.text
  N -> (str N) where (and (number? N) (>= N 0))
  N -> (@s "(- " (str (- 0 N)) ")") where (number? N)
  [and] -> "true"
  [or] -> "false"
  [F | Args] -> (@s "(" (str F) (smt-z3.texts Args) ")")
  X -> (str X))

(define smt-z3.texts
  [] -> ""
  [X | Xs] -> (@s " " (smt-z3.text X) (smt-z3.texts Xs)))

(define smt-z3.each
  _ [] -> ""
  F [X | Xs] -> (@s (F X) (smt-z3.each F Xs)))

(define smt-z3.query
  Us Fs -> (@s "(push 1)" (smt-z3.each (/. U (@s "(declare-const " (str U) " Int)")) Us)
               "(declare-const p Bool)(declare-const q Bool)"
               (smt-z3.each (/. F (@s "(assert " (smt-z3.text F) ")")) Fs) "(check-sat)(pop 1)
"))

(define smt-z3.answer
  R -> "sat" where (smt.sat? R)
  R -> "unsat" where (smt.unsat? R)
  R -> (@s "unknown: " (smt.reason R)))

\\ Dir gets the queries, the answers, and the formulas.
(define smt-z3.generated
  Dir Seed N -> (let _ (set smt-generate.*seed* Seed)
                     Queries (open (@s Dir "/queries.smt2") out)
                     Answers (open (@s Dir "/answers") out)
                     _ (smt-z3.write N Queries Answers)
                     _ (close Queries)
                  (close Answers)))

(define smt-z3.write
  0 _ _ -> done
  N Queries Answers
  -> (let Us (smt-generate.pick [[x y] [x y z] [x y z u] [x y z u v]])
          Fs (smt-generate.formulas Us [p q] (smt-generate.pick [1 3 9]) (smt-generate.pick [1 2 3]) (smt-generate.between 3 8))
          _ (pr (smt-z3.query Us Fs) Queries)
          _ (pr (@s (smt-z3.answer (smt.check Fs)) "
") Answers)
       (smt-z3.write (- N 1) Queries Answers)))
