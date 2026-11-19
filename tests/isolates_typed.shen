\\ Load under (tc +) so worker names and their payloads are checked before spawning.

(shen.x.namespace it.client
  (use channel => c)
  (use isolate => i)
  (externals [sender isolate])
  (export ping)

  (define echo
    {(A * (sender A)) --> A}
    (@p X Out) -> (c.send Out X))

  (define start
    {(i.worker A) --> A --> isolate}
    Worker X -> (i.spawn Worker X))

  (define ping
    {A --> A}
    X -> (let R (c.new 1)
              _ (start echo (@p X (c.sender R)))
            (c.receive R))))

(shen.x.namespace it.plain
  (externals [sender])
  (export pong)

  (define echo
    {(A * (sender A)) --> A}
    (@p X Out) -> (channel.send Out X))

  (define pong
    {A --> A}
    X -> (let R (channel.new 1)
              _ (isolate.spawn echo (@p X (channel.sender R)))
            (channel.receive R))))

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
  X -> (let Worker it.double
            I (isolate.spawn Worker X)
          (it.why (channel.receive (isolate.monitor I)))))

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
  Xs -> (isolate.spawn-each it.double Xs (/. Started (if (isolate.stop-each Started) (length Started) 0))))

(define it.shared
  {(list number) --> (list number)}
  Xs -> (isolate.share Xs))
