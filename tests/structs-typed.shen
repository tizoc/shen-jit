\\ Read under (tc +): typed declarations, typed clients and namespaced field types.
(defstruct struct-test.tpoint (x : number) (mutable y : number))
(defstruct struct-test.tempty)

(define struct-test.tnorm {struct-test.tpoint --> number}
  P -> (+ (struct-test.tpoint.x P) (struct-test.tpoint.y P)))

(define struct-test.tbump {struct-test.tpoint --> struct-test.tpoint}
  P -> (struct-test.tpoint.y-> P (+ 1 (struct-test.tpoint.y P))))

(define struct-test.tbuild {number --> struct-test.tpoint}
  N -> (struct.make struct-test.tpoint y <- N; x <- 1;))

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
