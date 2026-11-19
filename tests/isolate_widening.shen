\\ Load under (tc +) so the inferred uses of the three widening rules are checked.
(define widening.close-receiver
  {(receiver A) --> (channel.endpoint A)}
  R -> (channel.close R))

(define widening.close-sender
  {(sender A) --> (channel.endpoint A)}
  S -> (channel.close S))

(define widening.endpoints
  {(receiver A) --> (sender A) --> (list (channel.endpoint A))}
  R S -> [R S])

(define widening.down
  {isolate --> string --> isolate.down}
  I Message -> [down I Message])

(define widening.check
  {(receiver number) --> (sender number) --> boolean}
  R S ->
    (let Ends (widening.endpoints R S)
         I (isolate.self)
      (and (= (length Ends) 2)
           (= (widening.close-sender S) (head (tail Ends)))
           (= (widening.close-receiver R) (head Ends))
           (= (widening.down I "worker failed") [down I "worker failed"]))))

(define widening.run
  {--> boolean}
  -> (let R (channel.new 1) (widening.check R (channel.sender R))))

(output "~A~%" (if (widening.run) "4 passed, 0 failed" "0 passed, 1 failed"))
