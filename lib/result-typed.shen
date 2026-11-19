(shen.x.namespace result
  (shadow bind)
  (export bind ok err)

  (define ok
    {A --> (t (E * A))}
    X -> (:ok X))

  (define err
    {E --> (t (E * A))}
    X -> (:err X))

  (define bind
    {(t (E * A)) --> (A --> (t (E * B))) --> (t (E * B))}
    (:ok V) F -> (F V)
    (:err E) _ -> (err E)
    _ _ -> (error "result.bind: expected a result")))
