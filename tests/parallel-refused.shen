\\ A copied value needs a checked accessor before it can claim one member type.
(define parallel-refused.number {parallel.value --> number} X -> X)
\\ next
(define parallel-refused.boolean {parallel.value --> boolean} X -> X)
\\ next
(define parallel-refused.string {parallel.value --> string} X -> X)
\\ next
(define parallel-refused.symbol {parallel.value --> symbol} X -> X)
\\ next
(define parallel-refused.list {parallel.value --> (list parallel.value)} X -> X)
\\ next
(define parallel-refused.elements {parallel.value --> (list number)} X -> (parallel.list X))
