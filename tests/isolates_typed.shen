\\ The isolate and channel namespaces from typed code, and from a namespace client. The builder runs
\\ this file; typed functions cross by their names, which typecheck as the functions they name.

(set it.passed 0)
(set it.failed 0)

(define it.check
  Name Expected Got -> (if (= Expected Got)
                           (set it.passed (+ 1 (value it.passed)))
                           (do (set it.failed (+ 1 (value it.failed)))
                               (output "FAIL ~A: wanted ~S, got ~S~%" Name Expected Got))))

(shen.x.namespace it.client
  (use channel => c)
  (use isolate => i)
  (export ping)
  (define echo [X Out] -> (c.send Out X))
  (define ping X -> (let R (c.new 1) _ (i.spawn echo [X (c.sender R)]) (c.receive R))))

(shen.x.namespace it.plain
  (export pong)
  (define echo [X Out] -> (channel.send Out X))
  (define pong X -> (let R (channel.new 1) _ (isolate.spawn echo [X (channel.sender R)]) (channel.receive R))))

(tc +)

(define it.double
  {number --> number}
  X -> (* 2 X))

(define it.reply
  {(number * (sender number)) --> number}
  (@p X Out) -> (channel.send Out (it.double X)))

(define it.ask
  {number --> number}
  X -> (let R (channel.new 1)
            _ (isolate.spawn it.reply (@p X (channel.sender R)))
          (channel.receive R)))

(define it.drain
  {(receiver A) --> (list A) --> (list A)}
  R Acc -> (it.drained R (channel.next R) Acc))

(define it.drained
  {(receiver A) --> (channel.next A) --> (list A) --> (list A)}
  R [ok X] Acc -> (it.drain R [X | Acc])
  _ [closed] Acc -> (reverse Acc))

(define it.stream
  {(list number) --> (list number)}
  Xs -> (let R (channel.new 4)
             S (channel.sender R)
             _ (map (/. X (channel.send S X)) Xs)
             _ (channel.close S)
          (it.drain R [])))

(define it.why
  {isolate.down --> string}
  [down _ Reason] -> (make-string "~A" Reason))

(define it.ended
  {number --> string}
  X -> (let I (isolate.spawn it.double X) (it.why (channel.receive (isolate.monitor I)))))

(define it.ready?
  {(channel.ready A) --> boolean}
  [ready _] -> true
  [timeout] -> false)

(define it.polls
  {number --> (list boolean)}
  X -> (let Empty (channel.new 1)
            Full (channel.new 1)
            _ (channel.send (channel.sender Full) X)
          [(it.ready? (channel.wait-any [Empty] 0)) (it.ready? (channel.wait-any [Empty Full] 0))]))

(define it.each
  {(list number) --> number}
  Xs -> (let Started (isolate.spawn-each it.double Xs)
          (if (isolate.stop-each Started) (length Started) 0)))

(define it.shared
  {(list number) --> (list number)}
  Xs -> (isolate.share Xs))

(tc -)

(it.check "a typed request and reply" 42 (it.ask 21))
(it.check "a typed stream, read to its end" [1 2 3] (it.stream [1 2 3]))
(it.check "a typed monitor" "normal" (it.ended 3))
(it.check "typed waits" [false true] (it.polls 5))
(it.check "typed spawn-each and stop-each" 3 (it.each [1 2 3]))
(it.check "typed sharing" [1 2] (it.shared [1 2]))
(it.check "a namespace client" hello (it.client.ping hello))
(it.check "a namespace that names them without a use" hello (it.plain.pong hello))
(it.check "a lambda typechecks, and does not cross"
  "isolate.spawn: #<procedure> is not a function of one argument that the builder defined"
  (trap-error (isolate.spawn (/. X X) 1) (/. E (error-to-string E))))

(output "~A passed, ~A failed (typed isolates)~%" (value it.passed) (value it.failed))
