(define udp-test.expect
  {string --> A --> A --> boolean}
  Name Expected Actual ->
    (if (= Expected Actual) true (error "~A: expected ~S, got ~S" Name Expected Actual)))

(define udp-test.expect-int
  {string --> fixnum --> fixnum --> boolean}
  Name Expected Actual -> (udp-test.expect Name Expected Actual))

(define udp-test.fill
  {buffer.view --> fixnum --> (list fixnum) --> buffer.view}
  B _ [] -> B
  B I [X | Rest] -> (udp-test.fill (buffer.u8-> B I X) (fx+ I 1) Rest))

(define udp-test.request
  {buffer.view --> buffer.view}
  B -> (udp-test.fill B 0
       [69 0 0 31 0 0 64 0 64 17 182 202 192 0 2 1 192 0 2 2 48 57 0 7 0 11 135 49 97 98 99]))

\\ Wire fixtures computed independently using Python struct and a one's complement sum.
(define udp-test.wire
  {--> boolean}
  -> (let L (udp.make-link 2 31 0 (freeze 0))
          Left (udp.left L) Right (udp.right L)
          A (udp.ipv4 192 0 2 1) B (udp.ipv4 192 0 2 2)
          Client (udp.bind Left A 12345) Server (udp.bind Right B 7)
          Payload (buffer.from-string "abc!")
          Request (udp-test.request (buffer.new 31))
          Reply (udp-test.fill (buffer.new 31) 0
                  [69 0 0 31 0 0 64 0 64 17 182 202 192 0 2 2 192 0 2 1 0 7 48 57 0 11 135 49 97 98 99])
          Wire (buffer.new 31)
       (do (udp-test.expect "send over MTU" udp.too-large (udp.send Client B 7 Payload 4))
           (udp-test.expect "send at MTU" udp.sent (udp.send Client B 7 Payload 3))
           (buffer.u8-> Payload 0 0)
           (udp-test.expect-int "short raw output" -2 (udp.packet-recv-into Right Payload))
           (udp-test.expect-int "request length" 31 (udp.packet-recv-into Right Wire))
           (udp-test.expect "exact request bytes" true (buffer.equal? Request Wire))
           (udp-test.expect "raw input" udp.sent (udp.packet-send Left Request 31))
           (buffer.u8-> Request 30 0)
           (udp-test.expect-int "echo fixture" 1 (udp.echo-step Server 2))
           (udp-test.expect-int "reply length" 31 (udp.packet-recv-into Left Wire))
           (udp-test.expect "exact reply bytes" true (buffer.equal? Reply Wire)))))

(define udp-test.checksum-edges
  {--> boolean}
  -> (let L (udp.make-link 2 32 0 (freeze 0))
          Left (udp.left L) Right (udp.right L)
          A (udp.ipv4 192 0 2 1) B (udp.ipv4 192 0 2 2)
          Client (udp.bind Left A 12345) Server (udp.bind Right B 7)
          Wire (buffer.new 30)
          Zero (udp-test.fill (buffer.new 28) 0
                 [69 0 0 28 0 0 64 0 64 17 182 205 192 0 2 1 192 0 2 2 48 57 0 7 0 8 0 0])
          ComputedZero (udp-test.fill (buffer.new 30) 0
                         [69 0 0 30 0 0 64 0 64 17 182 203 192 0 2 1 192 0 2 2 48 57 0 7 0 10 255 255 75 150])
          Payload (udp-test.fill (buffer.new 2) 0 [75 150])
          Out (buffer.new 0) Info (udp.make-recv-info)
       (do (udp-test.expect "checksum omission fixture" udp.sent (udp.packet-send Left Zero 28))
           (udp-test.expect-int "zero-byte echo" 1 (udp.echo-step Server 1))
           (udp-test.expect "empty datagram is delivered" udp.received (udp.recv-into Client Out Info 1))
           (udp-test.expect-int "empty datagram length" 0 (udp.recv-info.length Info))
           (udp-test.expect "computed zero send" udp.sent (udp.send Client B 7 Payload 2))
           (udp-test.expect-int "computed zero packet size" 30 (udp.packet-recv-into Right Wire))
           (udp-test.expect "zero checksum encoded as all ones" true (buffer.equal? ComputedZero Wire)))))

(define udp-test.checksum-span
  {--> boolean}
  -> (let Bytes (udp-test.fill (buffer.new 7) 0 [222 1 2 3 4 5 223])
          Span (buffer.slice Bytes 1 5)
       (do (udp-test.expect-int "odd span at an unaligned view offset" 2317 (net-ipv4.sum16 Span 0 5 7))
           (udp-test.expect-int "even span with an additional offset" 1551 (net-ipv4.sum16 Span 1 4 7))
           (udp-test.expect-int "zero-length checksum preserves the seed" 7 (net-ipv4.sum16 Span 5 0 7))
           (udp-test.expect "checksum span cannot cross the view boundary" true
             (trap-error (do (net-ipv4.sum16 Span 4 2 0) false) (/. E true))))))

(define udp-test.discards
  {--> boolean}
  -> (let L (udp.make-link 8 32 0 (freeze 0))
          Left (udp.left L) Right (udp.right L)
          A (udp.ipv4 192 0 2 1) B (udp.ipv4 192 0 2 2)
          Client (udp.bind Left A 12345) Server (udp.bind Right B 7)
          Request (udp-test.request (buffer.new 31)) Payload (buffer.from-string "abc")
          Fragment (udp-test.fill (buffer.new 31) 0
                     [69 0 0 31 0 0 32 0 64 17 214 202 192 0 2 1 192 0 2 2 48 57 0 7 0 11 135 49 97 98 99])
          Wire (buffer.new 32) Info (udp.make-recv-info)
       (do (udp-test.expect "queue truncated header" udp.sent (udp.packet-send Left Request 19))
           (udp-test.expect "queue truncated payload" udp.sent (udp.packet-send Left Request 30))
           (udp-test.expect "queue fragment" udp.sent (udp.packet-send Left Fragment 31))
           (buffer.u8-> Request 10 0)
           (udp-test.expect "queue bad IP checksum" udp.sent (udp.packet-send Left Request 31))
           (buffer.u8-> Request 10 182)
           (buffer.u8-> Request 25 12)
           (udp-test.expect "queue bad UDP length" udp.sent (udp.packet-send Left Request 31))
           (buffer.u8-> Request 25 11)
           (buffer.u8-> Request 30 0)
           (udp-test.expect "queue bad UDP checksum" udp.sent (udp.packet-send Left Request 31))
           (udp-test.expect "queue wrong destination port" udp.sent (udp.send Client B 8 Payload 3))
           (udp-test.expect "queue wrong destination IP" udp.sent (udp.send Client A 7 Payload 3))
           (udp-test.expect "reject raw packet over MTU" udp.too-large
                            (udp.packet-send Left (buffer.new 33) 33))
           (udp-test.expect "discard counts towards receive budget" udp.budget-exhausted
                            (udp.recv-into Server Wire Info 3))
           (udp-test.expect-int "no result for malformed traffic" 0 (udp.recv-info.port Info))
           (udp-test.expect-int "remaining discards count as work" 5 (udp.echo-step Server 8))
           (udp-test.expect-int "malformed traffic produced no reply" -1 (udp.packet-recv-into Left Wire))
           (udp-test.expect "queue intact datagram after drops" udp.sent (udp.send Client B 7 Payload 3))
           (udp-test.expect "zero budget" udp.budget-exhausted (udp.recv-into Server Wire Info 0))
           (udp-test.expect "short UDP output" udp.too-small
                            (udp.recv-into Server (buffer.new 2) Info 1))
           (udp-test.expect-int "short output leaves metadata alone" 0 (udp.recv-info.port Info))
           (udp-test.expect "retry UDP receive" udp.received (udp.recv-into Server Wire Info 1))
           (udp-test.expect "received sender IP" A (udp.recv-info.source Info))
           (udp-test.expect-int "received sender port" 12345 (udp.recv-info.port Info))
           (udp-test.expect-int "received payload length" 3 (udp.recv-info.length Info))
           (udp-test.expect "received payload" "abc" (buffer.string (buffer.slice Wire 0 3))))))

\\ RFC 1122 3.2.1.7: a host takes a datagram whatever its TTL. The request with a TTL of 0, and the
\\ header checksum that gives, 0xF6CA.
(define udp-test.time-to-live
  {--> boolean}
  -> (let L (udp.make-link 2 31 0 (freeze 0))
          Server (udp.bind (udp.right L) (udp.ipv4 192 0 2 2) 7)
          Request (udp-test.request (buffer.new 31))
          Out (buffer.new 3) Info (udp.make-recv-info)
       (do (buffer.u8-> Request 8 0)
           (buffer.u8-> Request 10 246)
           (udp-test.expect "queue a datagram with a TTL of 0" udp.sent (udp.packet-send (udp.left L) Request 31))
           (udp-test.expect "take a datagram with a TTL of 0" udp.received (udp.recv-into Server Out Info 1)))))

\\ A group's datagrams go out with a TTL of 1; the exact bytes in udp-test.wire show others' 64.
(define udp-test.group-ttl
  {--> boolean}
  -> (let L (udp.make-link 2 31 0 (freeze 0))
          Client (udp.bind (udp.left L) (udp.ipv4 192 0 2 1) 12345)
          Wire (buffer.new 31)
       (do (udp-test.expect "send to a group" udp.sent (udp.send Client (udp.ipv4 239 1 2 3) 7 (buffer.from-string "abc") 3))
           (udp-test.expect-int "a group's datagram" 31 (udp.packet-recv-into (udp.right L) Wire))
           (udp-test.expect-int "a group's TTL" 1 (buffer.u8 Wire 8))
           (udp-test.expect-int "a group's header checksum" 0 (net-ipv4.packet-checksum Wire 0 20)))))

(define udp-test.clock
  {fixnum --> (vector fixnum)}
  Now -> (fxvector-> (vector 1) 1 Now))

(define udp-test.fifo
  {--> boolean}
  -> (let Time (udp-test.clock 10)
          L (udp.make-link 2 30 3 (freeze (fx<-vector Time 1)))
          Left (udp.left L) Right (udp.right L)
          Client (udp.bind Left (udp.ipv4 192 0 2 1) 12345)
          B (udp.ipv4 192 0 2 2) Server (udp.bind Right B 7)
          First (buffer.from-string "a") Second (buffer.from-string "b") Third (buffer.from-string "c")
          Out (buffer.new 1) Info (udp.make-recv-info)
       (do (udp-test.expect "enqueue first at t=10" udp.sent (udp.send Client B 7 First 1))
           (fxvector-> Time 1 11)
           (udp-test.expect "enqueue second at t=11" udp.sent (udp.send Client B 7 Second 1))
           (udp-test.expect "forward queue full" udp.would-block (udp.send Client B 7 Third 1))
           (fxvector-> Time 1 12)
           (udp-test.expect-int "first not yet ready" 0 (udp.echo-step Server 2))
           (fxvector-> Time 1 13)
           (udp-test.expect-int "only first at its delivery time" 1 (udp.echo-step Server 2))
           (udp-test.expect "reuse wrapped slot" udp.sent (udp.send Client B 7 Third 1))
           (fxvector-> Time 1 14)
           (udp-test.expect-int "second next" 1 (udp.echo-step Server 2))
           (fxvector-> Time 1 16)
           (udp-test.expect-int "full reply queue preserves third request" 0 (udp.echo-step Server 2))
           (udp-test.expect "receive first" udp.received (udp.recv-into Client Out Info 1))
           (udp-test.expect "first payload" "a" (buffer.string Out))
           (udp-test.expect-int "space to echo third" 1 (udp.echo-step Server 2))
           (udp-test.expect "second reply not ready yet" udp.empty (udp.recv-into Client Out Info 1))
           (fxvector-> Time 1 17)
           (udp-test.expect "receive second" udp.received (udp.recv-into Client Out Info 1))
           (udp-test.expect "second payload" "b" (buffer.string Out))
           (fxvector-> Time 1 19)
           (udp-test.expect "receive third" udp.received (udp.recv-into Client Out Info 1))
           (udp-test.expect "third payload" "c" (buffer.string Out))
           (fxvector-> Time 1 18)
           (udp-test.expect "reject backwards clock" true
              (trap-error (do (udp.echo-step Server 1) false) (/. E true)))
           (fxvector-> Time 1 19)
           (udp-test.expect "clock recovers" udp.empty (udp.recv-into Client Out Info 1)))))

(define udp-test.run
  {--> boolean}
  -> (and (udp-test.wire) (udp-test.checksum-edges) (udp-test.checksum-span)
          (udp-test.discards) (udp-test.time-to-live) (udp-test.group-ttl) (udp-test.fifo)))
