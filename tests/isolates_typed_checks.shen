(set it.passed 0)
(set it.failed 0)

(define it.check
  Name Expected Got -> (if (= Expected Got)
                           (set it.passed (+ 1 (value it.passed)))
                           (do (set it.failed (+ 1 (value it.failed)))
                               (output "FAIL ~A: wanted ~S, got ~S~%" Name Expected Got))))

(it.check "a typed request and reply" 42 (it.ask 21))
(it.check "a typed stream, read to its end" [1 2 3] (it.stream [1 2 3]))
(it.check "a typed monitor" "normal" (it.ended 3))
(it.check "typed waits" [false true] (it.polls 5))
(it.check "typed spawn-each and stop-each" 3 (it.each [1 2 3]))
(it.check "a typed scope" 3 (it.scoped [1 2 3]))
(it.check "a scope in a namespace client" 2 (it.client.spread it.double [4 5]))
(it.check "typed sharing" [1 2] (it.shared [1 2]))
(it.check "a namespace client" hello (it.client.ping hello))
(it.check "a namespace that names them without a use" hello (it.plain.pong hello))
(it.check "untyped spawn refuses a closure at run time"
  "isolate.spawn: #<procedure> is not a function of one argument that the builder defined"
  (trap-error (isolate.spawn (/. X X) 1) (/. E (error-to-string E))))

(output "~A passed, ~A failed (typed isolates)~%" (value it.passed) (value it.failed))
