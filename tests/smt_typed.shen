\\ A typed client of lib/smt.shen, loaded under (tc +).

(define smt-typed.pigeons
  {--> (list smt.formula)}
  -> [[or p1 p2] [or [and p1 [not p2]] [not p1] [not p2]] [not [and p1 [< x 1]]] [<= [+ x [* 2 y]] 0] [>= y 0] [> x -5]])

(define smt-typed.describe
  {smt.result --> string}
  R -> "unsat" where (smt.unsat? R)
  R -> (make-string "x ~A, y ~A, p1 ~A" (smt.integer (smt.model R) x) (smt.integer (smt.model R) y) (smt.truth (smt.model R) p1))
    where (smt.sat? R)
  R -> (smt.reason R))

(define smt-typed.in-range?
  {string --> fixnum --> boolean}
  X N -> (smt.valid? [[<= 0 X] [< X N]] [< X [+ N 1]]))

(define smt-typed.checked?
  {(list smt.formula) --> boolean}
  Fs -> (let R (smt.check Fs)
          (if (smt.unsat? R) (smt.check-proof Fs (smt.proof R)) (and (smt.sat? R) (smt.check-model Fs (smt.model R))))))

(define smt-typed.main
  {--> string}
  -> (make-string "~A / ~A ~A ~A ~A" (smt-typed.describe (smt.check (smt-typed.pigeons))) (smt-typed.in-range? "i" 7)
                  (smt-typed.checked? (smt-typed.pigeons)) (smt-typed.checked? [[< x 1] [> x 0]])
                  (smt-typed.describe (smt.check [false]))))
