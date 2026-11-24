\\ What is no formula, and what is no result.
(define smt-refused.op {--> smt.formula} -> [xor p q])
\\ next
(define smt-refused.arity {--> smt.formula} -> [<= x])
\\ next
(define smt-refused.number {--> smt.formula} -> 3)
\\ next
(define smt-refused.float {--> smt.formula} -> [< x 1.5])
\\ next
(define smt-refused.term {--> smt.formula} -> [< x [and p q]])
\\ next
(define smt-refused.result {--> boolean} -> (smt.check [p]))
\\ next
(define smt-refused.model {--> fixnum} -> (smt.integer (smt.check [p]) p))
