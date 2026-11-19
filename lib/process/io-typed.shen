(shen.x.namespace process
  (import process exited)
  (export success?)

(define success?
  {report --> boolean}
  Report -> (= (status Report) (:exited 0)))

)
