(define bad-payload
  {string --> isolate}
  X -> (isolate.spawn n->string X))
\\ next
(define bad-payloads
  {(list string) --> number}
  Xs -> (isolate.spawn-each n->string Xs (/. Started (length Started))))
\\ next
(define function-value
  {number --> isolate}
  X -> (isolate.spawn (fn n->string) X))
\\ next
(define captured-worker
  {number --> isolate}
  N -> (isolate.spawn (/. X (+ X N)) 1))
\\ next
(define captured-batch-worker
  {number --> number}
  N -> (isolate.spawn-each (/. X (+ X N)) [1] (/. Started (length Started))))
\\ next
(define binary-worker
  {number --> isolate}
  X -> (isolate.spawn + X))
