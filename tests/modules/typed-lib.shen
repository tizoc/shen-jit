\\ A typed module (tests/modules.shen): its typechecked definitions compile with their types.
(defstruct tmod-point (x : number) (y : number))

(define tmod-x {tmod-point --> number}
  P -> (tmod-point.x P))
