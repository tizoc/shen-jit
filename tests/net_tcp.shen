(shen.x.namespace tcp-test
  (use tcp)
  (use buffer)
  (use net-link)
  (use net-ipv4)
  (import struct defstruct)
  (export setup checks verify exercise)

(defstruct pair
  (time : (vector fixnum))
  (left : net-link.device)
  (right : net-link.device)
  (client : tcp.peer)
  (server : tcp.peer)
  (payload : buffer.view)
  (server-out : buffer.view)
  (client-out : buffer.view)
  (original : buffer.view)
  (wire : buffer.view))

(define clock
  {fixnum --> (vector fixnum)}
  Now -> (fxvector-> (vector 1) 1 Now))

(define setup
  {fixnum --> pair}
  Mtu ->
    (let Time (clock 0)
         L (net-link.make 2 Mtu 0 (freeze (fx<-vector Time 1)))
         Left (net-link.left L)
         Right (net-link.right L)
         A (net-ipv4.address 192 0 2 1)
         B (net-ipv4.address 192 0 2 2)
      (:pair
        time <- Time
        left <- Left
        right <- Right
        client <- (tcp.make-peer Left A 12345 B 7)
        server <- (tcp.make-peer Right B 7 A 12345)
        payload <- (buffer.from-string "abc")
        server-out <- (buffer.new 3)
        client-out <- (buffer.new 3)
        original <- (buffer.new 43)
        wire <- (buffer.new 43))))

(define expect
  {boolean --> string --> boolean}
  true _ -> true
  false Name -> (error "TCP test failed at ~A" Name))

(define fill
  {buffer.view --> fixnum --> (list fixnum) --> buffer.view}
  B _ [] -> B
  B I [X | Rest] -> (fill (buffer.u8-> B I X) (fx+ I 1) Rest))

\\ SYN bytes computed independently with Python struct and a one's complement sum.
(define fixture
  {fixnum --> boolean}
  Mtu ->
    (let F (setup Mtu)
         C (pair.client F)
         Packet (buffer.new 40)
         Expected (fill (buffer.new 40) 0
                     [69 0 0 40 0 0 64 0 64 6 182 204 192 0 2 1 192 0 2 2
                      48 57 0 7 255 255 255 254 0 0 0 0 80 2 0 88 251 71 0 0])
      (and (expect (tcp.connect C 4294967294) "queue SYN")
           (expect (= (tcp.poll C 0) 0) "poll with zero ingress budget")
           (expect (= (net-link.packet-recv-into (pair.right F) Packet) 40) "SYN wire length")
           (expect (buffer.equal? Packet Expected) "independent SYN fixture"))))

\\ The malformed fixture has a valid checksum, so the option parser must reject it.
(define option-fixtures
  {fixnum --> boolean}
  Mtu ->
    (let F (setup Mtu)
         C (pair.client F) S (pair.server F)
         Left (pair.left F) Right (pair.right F)
         Malformed (fill (buffer.new 48) 0
                      [69 0 0 48 0 0 64 0 64 6 182 196 192 0 2 1 192 0 2 2
                       48 57 0 7 255 255 255 254 0 0 0 0 112 194 0 88 213 120 0 0 2 1 0 2 1 4 2 0])
         Valid (fill (buffer.new 48) 0
                  [69 0 0 48 0 0 64 0 64 6 182 196 192 0 2 1 192 0 2 2
                   48 57 0 7 255 255 255 254 0 0 0 0 112 194 0 88 213 117 0 0 2 4 0 2 1 4 2 0])
      (do (expect (tcp.listen S 100) "listen for SYN with options")
          (expect (tcp.connect C 4294967294) "start client for option fixtures")
          (tcp.poll C 2)
          (expect (= (net-link.packet-recv-into Right (pair.wire F)) 40) "replace ordinary SYN")
          (expect (= (net-link.packet-send Left Malformed 48) net-link.sent) "queue malformed option")
          (expect (= (tcp.poll S 2) 1) "examine malformed option")
          (expect (= (tcp.state S) tcp.listen-state) "reject malformed option")
          (expect (= (net-link.packet-send Left Valid 48) net-link.sent) "queue SYN with options")
          (tcp.poll S 2)
          (tcp.poll C 2)
          (tcp.poll S 2)
          (expect (= (tcp.state S) tcp.established) "complete handshake with inbound SYN options")
          (expect (= (tcp.send S (pair.payload F) 3) 2) "honor advertised two-byte MSS"))))

(define open-pair
  {tcp.peer --> tcp.peer --> boolean}
  C S ->
    (do (expect (tcp.listen S 100) "listen")
        (expect (tcp.connect C 4294967294) "connect near sequence wrap")
        (tcp.poll C 2)
        (tcp.poll S 2)
        (tcp.poll C 2)
        (tcp.poll S 2)
        (expect (and (= (tcp.state C) tcp.established) (= (tcp.state S) tcp.established))
                "connection established")))

(define advance
  {pair --> fixnum --> (vector fixnum)}
  F Delta -> (let Time (pair.time F) (fxvector-> Time 1 (fx+ (fx<-vector Time 1) Delta))))

(define drop-first
  {pair --> boolean --> boolean}
  F DropAck ->
    (let Left (pair.left F) Right (pair.right F)
         Original (pair.original F) Wire (pair.wire F)
         S (pair.server F)
      (do (expect (= (net-link.packet-recv-into Right Original) 43) "capture first data segment")
          (expect (= (buffer.u32-be Original 24) 4294967295) "payload starts one byte before wrap")
          (if DropAck
              (do (expect (= (net-link.packet-send Left Original 43) net-link.sent) "deliver initial segment")
                  (expect (= (tcp.poll S 2) 1) "server receives initial segment")
                  (expect (= (net-link.packet-recv-into Left Wire) 40) "drop standalone ACK")
                  (expect (= (buffer.u8 Wire 33) 16) "dropped packet is a pure ACK")
                  (expect (= (buffer.u32-be Wire 28) 2) "ACK crosses sequence wrap")
                  (expect (= (tcp.recv-into S (pair.server-out F) 3) 3) "read first delivery"))
              (expect (= (tcp.recv-into S (pair.server-out F) 3) 0) "dropped segment is absent")))))

(define retry-data
  {pair --> boolean --> boolean}
  F DropAck ->
    (let C (pair.client F) S (pair.server F)
         Left (pair.left F) Right (pair.right F) Wire (pair.wire F)
      (do (advance F 999)
          (tcp.poll C 2)
          (expect (= (net-link.packet-recv-into Right Wire) -1) "no retry before the timer")
          (advance F 1)
          (tcp.poll C 2)
          (expect (= (net-link.packet-recv-into Right Wire) 43) "retry at the timer boundary")
          (expect (buffer.equal? Wire (pair.original F)) "same data and sequence on retry")
          (expect (= (net-link.packet-send Left Wire 43) net-link.sent) "deliver retransmission")
          (expect (= (tcp.poll S 2) 1) "process retry")
          (expect (= (tcp.recv-into S (pair.server-out F) 3) (if DropAck 0 3))
                  "retry delivers the bytes exactly once")
          (tcp.poll C 2)
          (expect (buffer.equal? (pair.payload F) (pair.server-out F)) "server bytes"))))

(define echo-and-close
  {pair --> boolean --> boolean}
  F DropAck ->
    (let C (pair.client F) S (pair.server F) A (pair.client-out F) B (pair.server-out F)
      (do (expect (= (tcp.send S B 3) 3) "queue the echo")
          (tcp.poll S 2)
          (tcp.poll C 2)
          (expect (= (tcp.recv-into C A 3) 3) "read the echo")
          (expect (buffer.equal? A (pair.payload F)) "echo bytes")
          (tcp.poll S 2)
          (expect (tcp.shutdown-write C) "client FIN")
          (tcp.poll C 2)
          (tcp.poll S 2)
          (expect (= (tcp.state S) tcp.close-wait) "server half-close")
          (expect (= (tcp.recv-into S B 3) -1) "server EOF")
          (tcp.poll C 2)
          (expect (= (tcp.state C) tcp.fin-wait-2) "client FIN acknowledged")
          (expect (tcp.shutdown-write S) "server FIN")
          (tcp.poll S 2)
          (tcp.poll C 2)
          (expect (= (tcp.state C) tcp.time-wait) "client TIME-WAIT")
          (expect (= (tcp.recv-into C A 3) -1) "client EOF")
          (if DropAck
              (do (expect (= (net-link.packet-recv-into (pair.right F) (pair.wire F)) 40) "drop final ACK")
                  (advance F 1000)
                  (tcp.poll S 2)
                  (expect (= (tcp.state S) tcp.last-ack) "server resends FIN")
                  (expect (= (tcp.poll C 2) 1) "TIME-WAIT answers duplicate FIN"))
              true)
          (tcp.poll S 2)
          (expect (= (tcp.state S) tcp.closed) "server FIN acknowledged")
          (advance F 120000)
          (tcp.poll C 2)
          (expect (= (tcp.state C) tcp.closed) "TIME-WAIT expires"))))

(define loss-cycle
  {pair --> buffer.view --> boolean --> boolean}
  F Payload DropAck ->
    (let C (pair.client F) S (pair.server F)
      (do (open-pair C S)
          (expect (= (tcp.send C Payload 3) 3) "send three bytes")
          (expect (= (tcp.send C Payload 3) 0) "one segment can await an ACK")
          (tcp.poll C 2)
          (drop-first F DropAck)
          (retry-data F DropAck)
          (echo-and-close F DropAck))))

(define exercise
  {pair --> fixnum --> boolean --> boolean}
  _ 0 _ -> true
  F N Allocate ->
    (let P (pair.payload F)
         Input (if Allocate (buffer.slice P 0 3) P)
      (and (loss-cycle F Input false) (loss-cycle F Input true)
           (exercise F (fx- N 1) Allocate))))

(define verify
  {fixnum --> boolean --> boolean}
  Iterations Allocate ->
    (let F (setup 128)
      (and (exercise F 1 false) (exercise F 1 true) (exercise F Iterations Allocate))))

(define receive-window
  {fixnum --> boolean}
  Mtu ->
    (let F (setup Mtu)
         C (pair.client F) S (pair.server F)
         P (pair.payload F) Out (pair.server-out F)
      (do (open-pair C S)
          (expect (= (tcp.send C P 3) 3) "fill receive buffer")
          (tcp.poll C 2)
          (tcp.poll S 2)
          (tcp.poll C 2)
          (expect (= (tcp.send C P 3) 1) "one-byte zero-window probe")
          (expect (= (tcp.send C P 3) 0) "backpressure with one pending probe")
          (tcp.poll C 2)
          (tcp.poll S 2)
          (tcp.poll C 2)
          (expect (= (tcp.recv-into S Out 3) 3) "original bytes survived the probe")
          (expect (buffer.equal? P Out) "original window contents")
          (expect (= (tcp.recv-into S Out 3) 0) "full receiver did not accept the probe")
          (tcp.poll S 2)
          (expect (= (net-link.packet-recv-into (pair.left F) (pair.wire F)) 40) "drop window update")
          (advance F 1000)
          (tcp.poll C 2)
          (tcp.poll S 2)
          (tcp.poll C 2)
          (expect (= (tcp.recv-into S Out 3) 1) "probe recovers a lost window update")
          (expect (= (buffer.u8 Out 0) 97) "probe byte")
          (expect (= (tcp.recv-into S Out 3) 0) "probe delivered once"))))

(define partial-read
  {fixnum --> boolean}
  Mtu ->
    (let F (setup Mtu)
         C (pair.client F) S (pair.server F) P (pair.payload F)
         Out (buffer.new 5)
      (do (open-pair C S)
          (expect (= (tcp.send C P 3) 3) "queue first stream write")
          (tcp.poll C 2)
          (tcp.poll S 2)
          (tcp.poll C 2)
          (expect (= (tcp.recv-into S Out 1) 1) "partial stream read")
          (tcp.poll S 2)
          (tcp.poll C 2)
          (expect (= (tcp.send C P 3) 3) "new window includes consumed byte")
          (tcp.poll C 2)
          (tcp.poll S 2)
          (expect (= (tcp.recv-into S Out 5) 5) "two writes form one byte stream")
          (expect (= (buffer.string Out) "bcabc") "receive buffer compaction preserves order"))))

(define listener-reuse
  {fixnum --> boolean}
  Mtu ->
    (let Time (clock 0)
         Link (net-link.make 2 Mtu 0 (freeze (fx<-vector Time 1)))
         Left (net-link.left Link)
         A (net-ipv4.address 192 0 2 1)
         B (net-ipv4.address 192 0 2 2)
         L (tcp.make-listener (net-link.right Link) B 7 1 100)
         First (tcp.make-peer Left A 12345 B 7)
         Second (tcp.make-peer Left A 12346 B 7)
         Payload (buffer.from-string "abc")
         Out (buffer.new 3)
         Packet (buffer.new 40)
         _ (expect (tcp.connect First 4294967294) "first listener SYN")
         _ (tcp.poll First 2)
         _ (tcp.listener-poll L 2)
         _ (expect (= (tcp.accept L) 0) "do not accept half-open connections")
         _ (tcp.poll First 2)
         _ (tcp.listener-poll L 2)
         Old (tcp.accept L)
      (do (expect (fx> Old 0) "first listener accept")
          (expect (= (tcp.connection-index L Old) 1) "first connection slot")
          (expect (not (tcp.release L Old)) "release refuses a live connection")
          (expect (tcp.connect Second 133) "second listener SYN")
          (tcp.poll Second 0)
          (expect (= (tcp.listener-poll L 2) 1) "full listener consumes extra SYN")
          (expect (= (net-link.packet-recv-into Left Packet) -1) "full listener does not admit another peer")
          (expect (= (tcp.send First Payload 3) 3) "first client writes")
          (tcp.poll First 2)
          (tcp.listener-poll L 2)
          (expect (= (tcp.connection-recv-into L Old Out 3) 3) "listener receives first stream")
          (expect (buffer.equal? Out Payload) "first listener bytes")
          (expect (= (tcp.connection-send L Old Out 3) 3) "first echo queued")
          (tcp.listener-poll L 2)
          (tcp.poll First 2)
          (expect (= (tcp.recv-into First Out 3) 3) "first echo arrives")
          (tcp.listener-poll L 2)
          (expect (tcp.shutdown-write First) "client FIN")
          (tcp.poll First 2)
          (tcp.listener-poll L 2)
          (tcp.poll First 2)
          (expect (= (tcp.connection-recv-into L Old Out 3) -1) "listener sees EOF")
          (expect (tcp.connection-shutdown-write L Old) "listener FIN")
          (tcp.listener-poll L 2)
          (tcp.poll First 2)
          (tcp.listener-poll L 2)
          (expect (= (tcp.connection-state L Old) tcp.closed) "closed token remains leased")
          (expect (tcp.release L Old) "release the closed listener slot")
          (fxvector-> Time 1 1000)
          (tcp.poll Second 0)
          (tcp.listener-poll L 2)
          (tcp.poll Second 2)
          (tcp.listener-poll L 2)
          (let New (tcp.accept L)
            (and (expect (and (fx> New 0) (not (= New Old))) "generation changes on reuse")
                 (expect (= (tcp.connection-index L New) 1) "reuse the same backing slot")
                 (expect (trap-error (do (tcp.connection-state L Old) false) (/. E true)) "reject stale token")
                 (expect (= (tcp.connection-recv-into L New Out 3) 0) "reused slot starts with an empty receive buffer"))))))

(define listener-fairness
  {fixnum --> boolean}
  Mtu ->
    (let Time (clock 0)
         Link (net-link.make 1 Mtu 0 (freeze (fx<-vector Time 1)))
         Left (net-link.left Link)
         A (net-ipv4.address 192 0 2 1)
         B (net-ipv4.address 192 0 2 2)
         L (tcp.make-listener (net-link.right Link) B 7 2 100)
         First (tcp.make-peer Left A 12345 B 7)
         Second (tcp.make-peer Left A 12346 B 7)
         Wire (buffer.new 40)
      (do (expect (tcp.connect First 71) "first SYN")
          (tcp.poll First 0)
          (tcp.listener-poll L 2)
          (expect (tcp.connect Second 72) "second SYN")
          (tcp.poll Second 0)
          (tcp.listener-poll L 2)
          (fxvector-> Time 1 1000)
          (tcp.listener-poll L 0)
          (tcp.listener-poll L 0)
          (expect (= (net-link.packet-recv-into Left Wire) 40) "drain the full output ring")
          (expect (= (buffer.u16-be Wire 22) 12345) "first SYN-ACK")
          (tcp.listener-poll L 0)
          (expect (= (net-link.packet-recv-into Left Wire) 40) "waiting peer gets next output slot")
          (expect (= (buffer.u16-be Wire 22) 12346) "blocked polls preserve send rotation")
          (tcp.listener-poll L 0)
          (expect (= (net-link.packet-recv-into Left Wire) 40) "first peer still retransmits")
          (expect (= (buffer.u16-be Wire 22) 12345) "first SYN-ACK retry"))))

(define discard-syn-acks
  {(list fixnum) --> (vector fixnum) --> tcp.listener --> net-link.device --> buffer.view --> boolean}
  [] _ _ _ _ -> true
  [Now | Rest] Time L D Wire ->
    (do (fxvector-> Time 1 Now)
        (tcp.listener-poll L 2)
        (expect (= (net-link.packet-recv-into D Wire) 40) "discard a SYN-ACK before accepting")
        (expect (= (tcp.accept L) 0) "unacknowledged SYN-ACK does not create a lease")
        (discard-syn-acks Rest Time L D Wire)))

(define listener-half-open-timeout
  {fixnum --> boolean}
  Mtu ->
    (let Time (clock 0)
         Link (net-link.make 1 Mtu 0 (freeze (fx<-vector Time 1)))
         Left (net-link.left Link)
         A (net-ipv4.address 192 0 2 1)
         B (net-ipv4.address 192 0 2 2)
         L (tcp.make-listener (net-link.right Link) B 7 1 100)
         First (tcp.make-peer Left A 12345 B 7)
         Second (tcp.make-peer Left A 12346 B 7)
         Wire (buffer.new 40)
      (do (expect (tcp.connect First 71) "SYN that stalls during handshake")
          (tcp.poll First 0)
          (discard-syn-acks [0 1000 3000 7000 15000 31000 63000] Time L Left Wire)
          (fxvector-> Time 1 123000)
          (tcp.listener-poll L 2)
          (expect (= (net-link.packet-recv-into Left Wire) -1) "no SYN-ACK after timeout")
          (expect (tcp.connect Second 72) "new SYN after timeout")
          (tcp.poll Second 0)
          (tcp.listener-poll L 2)
          (tcp.poll Second 2)
          (tcp.listener-poll L 2)
          (expect (fx> (tcp.accept L) 0) "half-open timeout returns its slot to the listener"))))

(define checks
  {fixnum --> boolean}
  Mtu -> (and (fixture Mtu) (option-fixtures Mtu) (receive-window 43) (partial-read 45)
              (listener-reuse Mtu) (listener-fairness Mtu) (listener-half-open-timeout Mtu) (verify 1 false)))

(preclude [pair.%match])
)
