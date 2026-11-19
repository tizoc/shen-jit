\\ Typed definitions of many shapes, module shapes, which tests/typed.shen loads under (optimise +):
\\ each compiles annotated to the code it makes without its annotations, but where it keeps floats in
\\ registers.
(datatype shape-pair
  X : float; Y : float;
  =====================
  [pt X Y] : shape-point;)

(define shape-norm {shape-point --> float}
  [pt X Y] -> (fl+ (fl* X X) (fl* Y Y)))

(define shape-sum {(list float) --> float --> float}
  [] Acc -> Acc
  [X | Xs] Acc -> (shape-sum Xs (fl+ Acc X)))

(define shape-count {(list A) --> fixnum}
  [] -> 0
  [_ | Xs] -> (fx+ 1 (shape-count Xs)))

(define shape-initial {string --> string}
  "" -> ""
  (@s C _) -> C)

(define shape-either {boolean --> symbol --> symbol --> symbol}
  true A _ -> A
  false _ B -> B)

(define shape-scale {float --> (list float) --> (list float)}
  K Xs -> (map (/. X (fl* K X)) Xs))

(define shape-local {fixnum --> fixnum}
  N -> (let M (fx* N N)
            K (fx- M 1)
         (if (fx> K 10) K (fx+ M N))))

(define shape-second {(A * B) --> B}
  (@p _ B) -> B)

(define shape-frozen {fixnum --> (lazy fixnum)}
  N -> (freeze (fx+ N 1)))
