(shen.x.namespace option
  (export t some none)

(define some
  {A --> (t A)}
  Value -> [Value])

(define none
  {--> (t A)}
  -> [])

)
