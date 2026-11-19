\\ Warm the typed functions on every branch before the allocation measurement.
(define udp-alloc.cycle
  {udp.peer --> udp.peer --> (vector fixnum) --> buffer.view --> buffer.view --> udp.recv-info --> boolean}
  Client Server Time Payload Out Info ->
    (let Now (fx<-vector Time 1)
         A (udp.ipv4 192 0 2 2)
      (and (= (udp.recv-into Client Out Info 1) udp.empty)
           (= (udp.send Client A 7 Payload 3) udp.sent)
           (= (udp.send Client A 7 Payload 3) udp.would-block)
           (= (udp.echo-step Server 1) 0)
           (do (fxvector-> Time 1 (fx+ Now 1))
               (= (udp.echo-step Server 1) 1))
           (= (udp.send Client A 7 Payload 3) udp.sent)
           (do (fxvector-> Time 1 (fx+ Now 2))
               (= (udp.echo-step Server 1) 0))
           (= (udp.recv-into Client Out Info 1) udp.received)
           (= (udp.recv-info.source Info) A)
           (= (udp.recv-info.port Info) 7)
           (= (udp.recv-info.length Info) 3)
           (buffer.equal? Out Payload)
           (= (udp.echo-step Server 1) 1)
           (do (fxvector-> Time 1 (fx+ Now 3))
               (= (udp.recv-into Client Out Info 1) udp.received))
           (buffer.equal? Out Payload))))

(define udp-alloc.loop
  {fixnum --> boolean --> udp.peer --> udp.peer --> (vector fixnum) -->
   buffer.view --> buffer.view --> udp.recv-info --> boolean}
  0 _ _ _ _ _ _ _ -> true
  N Allocate Client Server Time Payload Out Info ->
    (let Input (if Allocate (buffer.slice Payload 0 3) Payload)
      (and (udp-alloc.cycle Client Server Time Input Out Info)
           (udp-alloc.loop (fx- N 1) Allocate Client Server Time Payload Out Info))))

(define udp-alloc.run
  {fixnum --> boolean --> boolean}
  Iterations Allocate ->
    (let Time (udp-test.clock 0)
         Link (udp.make-link 1 128 1 (freeze (fx<-vector Time 1)))
         Client (udp.bind (udp.left Link) (udp.ipv4 192 0 2 1) 12345)
         Server (udp.bind (udp.right Link) (udp.ipv4 192 0 2 2) 7)
         Payload (buffer.from-string "abc") Out (buffer.new 3) Info (udp.make-recv-info)
      (and (udp-alloc.loop 2 false Client Server Time Payload Out Info)
           (udp-alloc.loop 2 true Client Server Time Payload Out Info)
           (udp-alloc.loop Iterations Allocate Client Server Time Payload Out Info))))
