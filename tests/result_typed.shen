\\ Load the library with tc off, then this client with tc on. A namespace that uses result names its
\\ type, and imports let-ok, ok and err.
(shen.x.namespace result-typed
  (use result)
  (import result let-ok ok err)
  (export passes)

  (define positive
    {number --> (result.t (string * number))}
    N -> (if (> N 0) (ok N) (err "not positive")))

  \\ Each step a value of another type: a number, then a string.
  (define described
    {number --> number --> (result.t (string * string))}
    A B -> (let-ok X (positive A)
                   Y (positive B)
                   _ (positive 1)
             (ok (str (+ X Y)))))

  (define first
    {(result.t (string * (list number))) --> number}
    (:ok [X | _]) -> X
    _ -> 0)

  (define passes
    {--> boolean}
    -> (and (= (described 1 2) (:ok "3"))
            (and (= (described 1 -2) (:err "not positive"))
                 (= (first (:ok [5 6])) 5)))))

\\ io's results are of the type: (io.result A) is (result.t (io.error * A)).
(define result-typed.read
  {string --> (io.result string)}
  Path -> (result.let-ok View (io.read-file Path 4096) (result.ok (buffer.string View))))

\\ A stored member or one returned by another call can flow into an expected outcome.
(define result-typed.widen-ok
  {(result.ok number) --> (result.t (string * number))}
  X -> X)

(define result-typed.failure
  {string --> (result.err string)}
  Message -> (:result.err Message))

(define result-typed.widen-error
  {string --> (result.t (string * number))}
  Message -> (result-typed.failure Message))

(define result-typed.widen-eof
  {(result.ok (option.t fixnum)) --> (io.result (option.t fixnum))}
  End -> End)

(output "~A~%"
  (if (and (result-typed.passes)
           (= (result-typed.widen-ok (:result.ok 7)) (:result.ok 7))
           (= (result-typed.widen-error "bad") (:result.err "bad"))
           (= (result-typed.widen-eof (:result.ok [])) (:result.ok [])))
      "4 passed, 0 failed" "0 passed, 1 failed"))
