\\ Read under (tc +): typed declarations, typed clients and namespaced field types.
(defstruct struct-test.tpoint (x : number) (mutable y : number))
(defstruct struct-test.tempty)
(defstruct (struct-test.anonymous-pair (A * B)) (_ : A) (_ : B))
(define struct-test.anonymous-swap
  {(struct-test.anonymous-pair (A * B)) --> (struct-test.anonymous-pair (B * A))}
  (:struct-test.anonymous-pair X Y) -> (:struct-test.anonymous-pair Y X))

(define struct-test.tnorm {struct-test.tpoint --> number}
  P -> (+ (struct-test.tpoint.x P) (struct-test.tpoint.y P)))

(define struct-test.tbump {struct-test.tpoint --> struct-test.tpoint}
  P -> (struct-test.tpoint.y-> P (+ 1 (struct-test.tpoint.y P))))

(define struct-test.tbuild {number --> struct-test.tpoint}
  N -> (struct.make struct-test.tpoint y <- N x <- 1))

\\ A struct declared under (tc -) with field types, in tests/structs-client.shen, is declared for typed clients.
(define struct-test.tuntyped-client {struct-test.declared --> string}
  D -> (struct-test.declared.name D))

(shen.x.namespace struct-test.tns
  (import struct defstruct)
  (export cell cell.make cell.value wrapper wrapper.make wrapper.inner unwrap)

  \\ A field's type resolves in the namespace, as a signature's does.
  (defstruct cell (value : number) (mutable rest : (list number)))
  (defstruct wrapper (inner : cell))
  (define unwrap {wrapper --> number} W -> (cell.value (wrapper.inner W))))

(defstruct struct-test.tseg (from : struct-test.tpoint) (to : struct-test.tpoint))

(define struct-test.tcolon {number --> struct-test.tpoint}
  N -> (:struct-test.tpoint y <- N x <- (+ N 1)))

(define struct-test.tmatch-x {struct-test.tpoint --> number}
  (:struct-test.tpoint x <- X ...) -> X)

(define struct-test.tvertical? {struct-test.tseg --> boolean}
  (:struct-test.tseg from <- (:struct-test.tpoint x <- X ...) to <- (:struct-test.tpoint x <- X ...)) -> true
  _ -> false)

(define struct-test.tdeclared-name {struct-test.declared --> string}
  (:struct-test.declared name <- N ...) -> N)

\\ Several structs as one type.
(defstruct struct-test.circle (radius : number))
(defstruct struct-test.rect (width : number) (height : number))
(struct.union struct-test.shape struct-test.circle struct-test.rect)

(define struct-test.area {struct-test.shape --> number}
  (:struct-test.circle radius <- R) -> (* 3 (* R R))
  (:struct-test.rect width <- W height <- H) -> (* W H))

(define struct-test.shapes {number --> (list struct-test.shape)}
  N -> [(:struct-test.circle radius <- N) (:struct-test.rect width <- N height <- 2)])

\\ The union stays open: a struct declared later joins it, and a later function matches it.
(defstruct struct-test.square (side : number))
(struct.union struct-test.shape struct-test.square)

(define struct-test.area2 {struct-test.shape --> number}
  (:struct-test.square side <- S) -> (* S S)
  Shape -> (struct-test.area Shape))

\\ Structs with type parameters, and a union of them.
(defstruct (struct-test.box A) (mutable value : A))
(defstruct (struct-test.pair (A * B)) (first : A) (second : B))

(define struct-test.box-bump {(struct-test.box number) --> (struct-test.box number)}
  B -> (struct-test.box.value-> B (+ 1 (struct-test.box.value B))))

(define struct-test.swap {(struct-test.pair (A * B)) --> (struct-test.pair (B * A))}
  (:struct-test.pair first <- X second <- Y) -> (struct-test.pair.make Y X))

(struct.union (struct-test.product (A * B)) (struct-test.pair (A * B)))

(define struct-test.product-second
  {(struct-test.product (A * B)) --> B}
  (:struct-test.pair second <- Y ...) -> Y)

(defstruct (struct-test.ok A) (_ : A))
(defstruct (struct-test.err E) (_ : E))
(struct.union (struct-test.result (E * A)) (struct-test.ok A) (struct-test.err E))

(define struct-test.bind
  {(struct-test.result (E * A)) --> (A --> (struct-test.result (E * B))) --> (struct-test.result (E * B))}
  (:struct-test.ok V) F -> (F V)
  (:struct-test.err E) _ -> (struct-test.err.make E))

(define struct-test.positive {number --> (struct-test.result (string * number))}
  N -> (if (> N 0) (struct-test.ok.make N) (struct-test.err.make "not positive")))

(define struct-test.shown {(struct-test.result (string * number)) --> string}
  (:struct-test.ok V) -> (str V)
  (:struct-test.err E) -> E)

\\ The last constructor forces a common element type. Retrying every combination
\\ of proofs for the preceding ok values used to exceed the default inference limit.
(define struct-test.mixed-count {number --> number}
  N -> (length [(:struct-test.ok N) (:struct-test.ok N) (:struct-test.ok N)
                (:struct-test.ok N) (:struct-test.ok N) (:struct-test.ok N)
                (:struct-test.ok N) (:struct-test.ok N) (:struct-test.ok N)
                (:struct-test.err "last")]))

(shen.x.namespace struct-test.geometry
  (use struct)
  (import struct defstruct)
  (export dot line figure length-of)
  (defstruct dot (x : number))
  (defstruct line (from : number) (to : number))
  (struct.union figure dot line)
  (define length-of {figure --> number}
    (:dot ...) -> 0
    (:line from <- F to <- T) -> (- T F)))
