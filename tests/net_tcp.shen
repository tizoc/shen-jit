(shen.x.namespace tcp-test
  (use tcp)
  (use buffer)
  (use net-link)
  (use net-ipv4)
  (import struct defstruct)
  (export setup checks verify exercise window-case make-window-case exercise-window)

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

(defstruct sack-case
  (peers : pair)
  (packet : buffer.view)
  (payload : buffer.view)
  (short : buffer.view)
  (suffix : buffer.view)
  (output : buffer.view))

(defstruct window-case
  (peers : pair)
  (payload : buffer.view)
  (suffix : buffer.view)
  (output : buffer.view)
  (fast-output : buffer.view)
  (congestion-payload : buffer.view)
  (congestion-output : buffer.view)
  (congestion-ack : buffer.view)
  (sack : sack-case))

(define clock
  {fixnum --> (vector fixnum)}
  Now -> (fxvector-> (vector 1) 1 Now))

(define setup-link
  {fixnum --> fixnum --> pair}
  Mtu Slots ->
    (let Time (clock 0)
         L (net-link.make Slots Mtu 0 (freeze (fx<-vector Time 1)))
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

(define setup
  {fixnum --> pair}
  Mtu -> (setup-link Mtu 2))

(define expect
  {boolean --> string --> boolean}
  true _ -> true
  false Name -> (error "TCP test failed at ~A" Name))

(define fill
  {buffer.view --> fixnum --> (list fixnum) --> buffer.view}
  B _ [] -> B
  B I [X | Rest] -> (fill (buffer.u8-> B I X) (fx+ I 1) Rest))

(define checksum-segment
  {buffer.view --> fixnum --> buffer.view}
  B Size ->
    (do (buffer.u16-be-> B 36 0)
        (buffer.u16-be-> B 36 (net-ipv4.transport-checksum B 0 6 Size))))

\\ SYN bytes computed independently with Python struct and a one's complement sum.
(define fixture
  {fixnum --> boolean}
  Mtu ->
    (let F (setup Mtu)
         C (pair.client F)
         Packet (buffer.new 44)
         Expected (fill (buffer.new 44) 0
                     [69 0 0 44 0 0 64 0 64 6 182 200 192 0 2 1 192 0 2 2
                      48 57 0 7 255 255 255 254 0 0 0 0 96 2 2 192 228 217 0 0 4 2 0 0])
      (and (expect (tcp.connect C 4294967294) "queue SYN")
           (expect (= (tcp.poll C 0) 0) "poll with zero ingress budget")
           (expect (= (net-link.packet-recv-into (pair.right F) Packet) 44) "SYN wire length")
           (expect (buffer.equal? Packet Expected) "independent SYN fixture"))))

\\ The malformed fixture has a valid checksum, so the option parser must reject it.
(define option-fixtures
  {fixnum --> boolean}
  Mtu ->
    (let F (setup Mtu)
         C (pair.client F) S (pair.server F)
         Left (pair.left F) Right (pair.right F)
         Syn (buffer.new 44)
         Malformed (fill (buffer.new 48) 0
                      [69 0 0 48 0 0 64 0 64 6 182 196 192 0 2 1 192 0 2 2
                       48 57 0 7 255 255 255 254 0 0 0 0 112 194 0 88 213 120 0 0 2 1 0 2 1 4 2 0])
         Valid (fill (buffer.new 48) 0
                  [69 0 0 48 0 0 64 0 64 6 182 196 192 0 2 1 192 0 2 2
                   48 57 0 7 255 255 255 254 0 0 0 0 112 194 0 88 213 117 0 0 2 4 0 2 1 4 2 0])
      (do (expect (tcp.listen S 100) "listen for SYN with options")
          (expect (tcp.connect C 4294967294) "start client for option fixtures")
          (tcp.poll C 2)
          (expect (= (net-link.packet-recv-into Right Syn) 44) "replace ordinary SYN")
          (expect (= (net-link.packet-send Left Malformed 48) net-link.sent) "queue malformed option")
          (expect (= (tcp.poll S 2) 1) "examine malformed option")
          (expect (= (tcp.state S) tcp.listen-state) "reject malformed option")
          (buffer.u16-be-> Valid 45 0) \\ Replace the SACK-Permitted option with EOL and padding.
          (checksum-segment Valid 28)
          (expect (= (net-link.packet-send Left Valid 48) net-link.sent) "queue SYN with options")
          (tcp.poll S 2)
          (expect (= (net-link.packet-recv-into Left Syn) 40) "SYN-ACK omits SACK when the SYN did not offer it")
          (expect (= (net-link.packet-send Right Syn 40) net-link.sent) "deliver legacy SYN-ACK")
          (tcp.poll C 2)
          (tcp.poll S 2)
          (expect (= (tcp.state S) tcp.established) "complete handshake with inbound SYN options")
          (expect (= (tcp.send S (pair.payload F) 3) 3) "queue a write larger than the MSS")
          (tcp.poll S 0)
          (tcp.poll S 0)
          (expect (= (net-link.packet-recv-into Left (pair.original F)) 42) "honor advertised two-byte MSS")
          (expect (= (net-link.packet-recv-into Left (pair.wire F)) 41) "send the rest before the ACK")
          (expect (= (net-link.packet-send Right (pair.wire F) 41) net-link.sent) "deliver the later byte first")
          (tcp.poll C 2)
          (expect (= (net-link.packet-recv-into Right (pair.wire F)) 40) "legacy peer ACKs the gap without SACK"))))

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

(define close-pair
  {pair --> boolean --> boolean}
  F DropAck ->
    (let C (pair.client F) S (pair.server F) A (pair.client-out F) B (pair.server-out F)
      (do (expect (tcp.shutdown-write C) "client FIN")
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
          (close-pair F DropAck))))

(define loss-cycle
  {pair --> buffer.view --> boolean --> boolean}
  F Payload DropAck ->
    (let C (pair.client F) S (pair.server F)
      (do (open-pair C S)
          (expect (= (tcp.send C Payload 3) 3) "send three bytes")
          (expect (not (tcp.shutdown-write C)) "FIN waits for queued data")
          (tcp.poll C 2)
          (drop-first F DropAck)
          (retry-data F DropAck)
          (echo-and-close F DropAck))))

(define window-loss
  {pair --> buffer.view --> buffer.view --> buffer.view --> boolean}
  F Payload Suffix Out ->
    (let C (pair.client F) S (pair.server F)
         Left (pair.left F) Right (pair.right F)
         Wire (pair.wire F)
      (do (open-pair C S)
          (expect (= (tcp.send C Payload 9) 9) "queue three segments")
          (tcp.poll C 0)
          (tcp.poll S 2)
          (tcp.poll C 0)
          (expect (= (net-link.packet-recv-into Right Wire) 43) "drop second segment before any ACK")
          (expect (= (buffer.u32-be Wire 24) 2) "second segment sequence wraps")
          (tcp.poll C 0)
          (expect (= (tcp.poll S 2) 1) "third segment arrives above the gap")
          (expect (= (tcp.recv-into S (pair.server-out F) 3) 3) "read the first segment")
          (expect (buffer.equal? (pair.server-out F) (pair.payload F)) "first segment content")
          (expect (= (tcp.recv-into S Out 6) 0) "out-of-order data is not delivered")
          (expect (= (tcp.poll C 2) 2) "read the partial and duplicate cumulative ACKs")
          (advance F 999)
          (tcp.poll C 0)
          (expect (= (net-link.packet-recv-into Right Wire) -1) "no premature flight replay")
          (advance F 1)
          (tcp.poll C 0)
          (expect (= (net-link.packet-recv-into Right Wire) 43) "replay the missing segment")
          (expect (= (buffer.u32-be Wire 24) 2) "replay starts at the oldest unacknowledged byte")
          (expect (= (net-link.packet-send Left Wire 43) net-link.sent) "deliver the missing segment")
          (expect (= (tcp.poll S 2) 1) "only the missing segment is replayed")
          (expect (= (tcp.recv-into S Out 6) 6) "exactly six bytes remain")
          (expect (buffer.equal? Out Suffix) "filling the gap releases the retained suffix")
          (expect (= (tcp.recv-into S Out 6) 0) "retries do not duplicate delivery")
          (expect (= (tcp.poll C 2) 1) "one cumulative ACK retires both remaining segments")
          (expect (= (net-link.packet-recv-into Right Wire) -1) "the cumulative ACK cancels suffix replay")
          (close-pair F false))))

(define reorder-window
  {pair --> buffer.view --> buffer.view --> buffer.view --> boolean}
  F Payload Suffix Out ->
    (let C (pair.client F) S (pair.server F)
         Left (pair.left F) Right (pair.right F)
         Held (pair.original F) Ack (pair.wire F)
      (do (open-pair C S)
          (expect (= (tcp.send C Payload 9) 9) "queue three segments for reordering")
          (tcp.poll C 0)
          (expect (= (net-link.packet-recv-into Right Held) 43) "delay the first segment")
          (tcp.poll C 0)
          (tcp.poll C 0)
          (expect (= (tcp.poll S 2) 2) "receive two later segments")
          (expect (= (tcp.recv-into S Out 6) 0) "the application cannot read above the gap")
          (expect (= (net-link.packet-recv-into Left Ack) 40) "ACK the gap")
          (expect (= (buffer.u32-be Ack 28) 4294967295) "ACK stays at the missing byte")
          (expect (= (buffer.u16-be Ack 34) 24) "staging bytes preserves the right edge")
          (expect (= (net-link.packet-send Left Held 43) net-link.sent) "release the delayed segment")
          (expect (= (tcp.poll S 2) 1) "fill the gap without advancing the clock")
          (expect (= (net-link.packet-recv-into Left Ack) 40) "emit one cumulative ACK")
          (expect (= (buffer.u32-be Ack 28) 8) "the ACK crosses sequence wrap and covers all segments")
          (expect (= (buffer.u16-be Ack 34) 15) "all nine contiguous bytes occupy the window")
          (expect (= (net-link.packet-send Right Ack 40) net-link.sent) "deliver the cumulative ACK")
          (expect (= (tcp.poll C 2) 1) "retire the flight on the sender")
          (expect (= (net-link.packet-recv-into Right Ack) -1) "no retransmission is needed")
          (expect (= (tcp.recv-into S (pair.server-out F) 3) 3) "read the formerly delayed prefix")
          (expect (buffer.equal? (pair.server-out F) (pair.payload F)) "prefix bytes")
          (expect (= (tcp.recv-into S Out 6) 6) "read the staged suffix")
          (expect (buffer.equal? Out Suffix) "suffix bytes remain ordered")
          (expect (= (tcp.recv-into S Out 6) 0) "reordering delivers each byte once")
          (close-pair F false))))

(define send-window-update
  {net-link.device --> buffer.view --> fixnum --> boolean}
  R Ack Window ->
    (do (buffer.u16-be-> Ack 34 Window)
        (checksum-segment Ack 20)
        (expect (= (net-link.packet-send R Ack 40) net-link.sent) "queue a window-only update")))

(define below-fast-threshold
  {pair --> buffer.view --> fixnum --> boolean}
  _ _ 0 -> true
  F Wire N ->
    (do (tcp.poll (pair.server F) 0)
        (expect (= (tcp.poll (pair.client F) 1) 1) "process one duplicate ACK")
        (expect (= (net-link.packet-recv-into (pair.right F) Wire) -1) "fewer than three duplicate ACKs do not retransmit")
        (below-fast-threshold F Wire (fx- N 1))))

(define queue-padding
  {net-link.device --> buffer.view --> fixnum --> boolean}
  _ _ 0 -> true
  D Wire N ->
    (do (expect (= (net-link.packet-send D Wire 0) net-link.sent) "fill the egress ring")
        (queue-padding D Wire (fx- N 1))))

(define drain-padding
  {net-link.device --> buffer.view --> fixnum --> boolean}
  _ _ 0 -> true
  D Wire N ->
    (do (expect (= (net-link.packet-recv-into D Wire) 0) "free a slot in the egress ring")
        (drain-padding D Wire (fx- N 1))))

(define fast-flight
  {pair --> buffer.view --> buffer.view --> fixnum --> boolean --> boolean}
  F Payload Out Gap DropFast ->
    (let C (pair.client F) S (pair.server F)
         Left (pair.left F) Right (pair.right F)
         Retry (pair.original F) Ack (pair.wire F)
         Start (fx<-vector (pair.time F) 1)
      (do (expect (= (tcp.send C Payload 15) 15) "queue five segments")
          (tcp.poll C 0)
          (tcp.poll C 0)
          (expect (= (net-link.packet-recv-into Right Retry) 43) "capture the first segment")
          (expect (= (net-link.packet-recv-into Right Ack) 43) "lose the second segment")
          (expect (= (buffer.u32-be Ack 24) Gap) "missing segment's sequence")
          (expect (= (net-link.packet-send Left Retry 43) net-link.sent) "restore the first segment")
          (tcp.poll C 0)
          (tcp.poll C 0)
          (tcp.poll C 0)
          (expect (= (tcp.poll S 4) 4) "receive all later segments in one batch")
          (expect (= (net-link.packet-recv-into Left Ack) 40) "capture the first advancing ACK")
          (expect (= (buffer.u32-be Ack 28) Gap) "first ACK reaches the gap")
          (expect (= (buffer.u16-be Ack 34) 21) "first ACK advertises space after three bytes")
          (expect (= (net-link.packet-send Right Ack 40) net-link.sent) "deliver the advancing ACK")
          (expect (= (tcp.poll C 1) 1) "consume the advancing ACK")
          (send-window-update Right Ack 22)
          (send-window-update Right Ack 23)
          (send-window-update Right Ack 24)
          (send-window-update Right Ack 21)
          (expect (= (tcp.poll C 4) 4) "consume window-only updates")
          (expect (= (net-link.packet-recv-into Right Retry) -1) "window changes do not count as duplicates")
          (advance F 25)
          (below-fast-threshold F Retry 2)
          (tcp.poll S 0)
          (expect (= (net-link.packet-recv-into Left Ack) 40) "capture the third duplicate ACK")
          (expect (and (= (buffer.u32-be Ack 28) Gap) (= (buffer.u8 Ack 33) 16)
                       (= (buffer.u16-be Ack 34) 21)) "the third duplicate is a pure ACK for the gap")
          (expect (= (net-link.packet-send Right Ack 40) net-link.sent) "deliver the third duplicate ACK")
          (if DropFast
              (expect (= (tcp.poll C 1) 1) "process the third duplicate with space available")
              (do (queue-padding Left Retry 8)
                  (expect (= (tcp.poll C 1) 1) "process the third duplicate while egress is full")
                  (drain-padding Right Retry 8)
                  (tcp.poll C 0)
                  true))
          (expect (= (net-link.packet-recv-into Right Retry) 43) "fast retransmission before timeout")
          (expect (and (= (buffer.u32-be Retry 24) Gap) (= (buffer.u8 Retry 40) 100)
                       (= (buffer.u8 Retry 41) 101) (= (buffer.u8 Retry 42) 102)) "retransmit only the missing segment")
          (expect (= (fx- (fx<-vector (pair.time F) 1) Start) 25) "fast retransmit fires at 25 ms")
          (expect (= (net-link.packet-send Right Ack 40) net-link.sent) "repeat the duplicate ACK")
          (expect (= (net-link.packet-send Right Ack 40) net-link.sent) "repeat again")
          (expect (= (net-link.packet-send Right Ack 40) net-link.sent) "repeat a third time")
          (expect (= (tcp.poll C 4) 3) "consume extra duplicates for the same gap")
          (expect (= (net-link.packet-recv-into Right Ack) -1) "fast retransmit is latched until the ACK advances")
          (if DropFast
              (do (advance F 974)
                  (tcp.poll C 0)
                  (expect (= (net-link.packet-recv-into Right Ack) -1) "lost fast retry waits for the original deadline")
                  (advance F 1)
                  (tcp.poll C 0)
                  (expect (= (net-link.packet-recv-into Right Retry) 43) "timeout recovers a lost fast retry")
                  (expect (= (buffer.u32-be Retry 24) Gap) "timeout restarts at the same oldest byte"))
              true)
          (expect (= (net-link.packet-send Left Retry 43) net-link.sent) "deliver the retry")
          (expect (= (tcp.poll S 4) 1) "fill the gap with one segment")
          (expect (= (tcp.recv-into S Out 15) 15) "the entire flight becomes readable")
          (expect (buffer.equal? Out Payload) "recovered bytes remain ordered")
          (expect (= (tcp.recv-into S Out 15) 0) "no duplicate delivery")
          (expect (= (tcp.poll C 4) 1) "cumulative ACK retires the flight")
          (expect (= (net-link.packet-recv-into Right Ack) -1) "no suffix is replayed")
          (tcp.poll S 0)
          (expect (= (tcp.poll C 4) 1) "advertise the full window after reading"))))

(define open-with-rtt
  {pair --> fixnum --> boolean}
  F Half ->
    (let C (pair.client F) S (pair.server F)
      (do (expect (tcp.listen S 100) "listen for RTT measurement")
          (expect (tcp.connect C 4294967294) "open near sequence wrap")
          (tcp.poll C 0)
          (advance F Half)
          (expect (= (tcp.poll S 2) 1) "SYN arrives after half an RTT")
          (advance F Half)
          (expect (= (tcp.poll C 2) 1) "SYN-ACK completes the first RTT sample")
          (advance F Half)
          (expect (= (tcp.poll S 2) 1) "complete the delayed handshake")
          (expect (and (= (tcp.state C) tcp.established) (= (tcp.state S) tcp.established))
                  "both peers are established"))))

(define send-timed-data
  {pair --> boolean}
  F ->
    (let C (pair.client F)
      (do (expect (= (tcp.send C (pair.payload F) 3) 3) "queue a timed exchange")
          (tcp.poll C 0)
          true)))

(define receive-timed-data
  {pair --> fixnum --> boolean}
  F Rtt ->
    (let C (pair.client F) S (pair.server F)
         Out (pair.server-out F)
         Half (fxquotient Rtt 2)
      (do (advance F Half)
          (expect (= (tcp.poll S 2) 1) "receive the timed data")
          (expect (= (tcp.recv-into S Out 3) 3) "read the timed data once")
          (expect (buffer.equal? Out (pair.payload F)) "timed data is intact")
          (advance F (fx- Rtt Half))
          (expect (= (tcp.poll C 2) 1) "ACK arrives after the selected RTT"))))

(define train-rtt
  {pair --> fixnum --> fixnum --> boolean}
  _ _ 0 -> true
  F Rtt N ->
    (do (send-timed-data F)
        (receive-timed-data F Rtt)
        (train-rtt F Rtt (fx- N 1))))

(define poll-burst
  {tcp.peer --> fixnum --> boolean}
  _ 0 -> true
  P N -> (do (tcp.poll P 0) (poll-burst P (fx- N 1))))

(define read-flight
  {pair --> buffer.view --> fixnum --> boolean}
  F Out Packets ->
    (let C (pair.client F) S (pair.server F)
      (do (poll-burst C 8)
          (expect (= (tcp.poll S 8) Packets) "congestion window bounds the flight")
          (expect (= (tcp.recv-into S Out (buffer.length Out)) (fx* Packets 3)) "receive each flight once"))))

(define receive-flight
  {pair --> buffer.view --> fixnum --> boolean}
  F Out Packets ->
    (do (read-flight F Out Packets)
        (tcp.poll (pair.server F) 0)
        (expect (= (tcp.poll (pair.client F) 8) 2) "read the cumulative ACK and window update")))

(define fast-loss
  {pair --> buffer.view --> buffer.view --> boolean}
  F Payload Out ->
    (let C (pair.client F)
      (do (open-pair C (pair.server F))
          (train-rtt F 0 1) \\ Grow the initial window to five segments.
          (fast-flight F Payload Out 5 false)
          (expect (= (tcp.send C Payload 12) 12) "queue data after fast recovery")
          (receive-flight F Out 2) \\ Four unacknowledged segments halved on fast loss.
          (receive-flight F Out 2)
          (train-rtt F 0 5) \\ Grow additively until the next loss can elicit three duplicate ACKs.
          (fast-flight F Payload Out 47 true)
          (close-pair F false))))

(define timeout-congestion-flight
  {pair --> buffer.view --> boolean}
  F Out ->
    (let C (pair.client F) S (pair.server F)
         Left (pair.left F) Right (pair.right F) Wire (pair.wire F)
      (do (poll-burst C 8)
          (expect (= (net-link.packet-recv-into Right Wire) 43) "lose the first segment of a six-segment flight")
          (expect (= (tcp.poll S 8) 5) "buffer the five later segments")
          (expect (= (net-link.packet-recv-into Left Wire) 40) "discard the first duplicate ACK")
          (advance F 999)
          (tcp.poll C 0)
          (expect (= (net-link.packet-recv-into Right Wire) -1) "the retransmission timer has not expired")
          (advance F 1)
          (poll-burst C 8)
          (expect (= (net-link.packet-recv-into Right Wire) 43) "timeout retransmits the missing segment")
          (expect (= (net-link.packet-recv-into Right Wire) -1) "timeout permits only one MSS before an ACK")
          (expect (= (net-link.packet-send Left Wire 43) net-link.sent) "deliver the missing segment")
          (expect (= (tcp.poll S 8) 1) "fill the gap with one retransmission")
          (expect (= (tcp.recv-into S Out 24) 18) "the entire original flight becomes readable")
          (tcp.poll S 0)
          (expect (= (tcp.poll C 8) 2) "the recovery ACK frees the flight"))))

(define send-partial-ack
  {pair --> buffer.view --> fixnum --> boolean}
  F Ack Sequence ->
    (do (buffer.u32-be-> Ack 28 Sequence)
        (checksum-segment Ack 20)
        (expect (= (net-link.packet-send (pair.right F) Ack 40) net-link.sent) "send a partial cumulative ACK")
        (expect (= (tcp.poll (pair.client F) 1) 1) "process the partial cumulative ACK")))

(define avoidance-flight
  {pair --> buffer.view --> buffer.view --> boolean}
  F Out Ack ->
    (let Left (pair.left F) Wire (pair.wire F)
         _ (read-flight F Out 3)
         _ (expect (= (net-link.packet-recv-into Left Ack) 40) "hold the ACK for all three segments")
         End (buffer.u32-be Ack 28)
      (do (send-partial-ack F Ack (fx- End 6))
          (read-flight F Out 1)
          (expect (= (net-link.packet-recv-into Left Wire) 40) "hold the receiver's newer ACK")
          (send-partial-ack F Ack (fx- End 3))
          (read-flight F Out 1)
          (expect (= (net-link.packet-recv-into Left Wire) 40) "hold the receiver's newer ACK again")
          (send-partial-ack F Ack End)
          (receive-flight F Out 2))))

(define congestion-growth
  {pair --> buffer.view --> buffer.view --> buffer.view --> boolean}
  F Payload Out Ack ->
    (let C (pair.client F)
      (do (open-pair C (pair.server F))
          (expect (= (tcp.send C Payload 24) 24) "queue a full send ring")
          (receive-flight F Out 4) \\ Initial congestion window.
          (expect (= (tcp.send C Payload 12) 12) "replenish the send ring")
          (receive-flight F Out 5) \\ A cumulative ACK adds one MSS in slow start.
          (expect (= (tcp.send C Payload 15) 15) "replenish after the next flight")
          (timeout-congestion-flight F Out)
          (expect (= (tcp.send C Payload 18) 18) "replenish after timeout")
          (receive-flight F Out 2) \\ Slow start resumes from one MSS.
          (expect (= (tcp.send C Payload 3) 3) "queue enough to test additive growth")
          (avoidance-flight F Out Ack) \\ After halving six MSS, grow once per three MSS acknowledged.
          (close-pair F false))))

(define drop-timed-data
  {pair --> boolean}
  F ->
    (do (send-timed-data F)
        (expect (= (net-link.packet-recv-into (pair.right F) (pair.wire F)) 43) "drop the timed data")))

(define expect-data-timeout
  {pair --> fixnum --> boolean}
  F Interval ->
    (let C (pair.client F) Right (pair.right F) Wire (pair.wire F)
      (do (advance F (fx- Interval 1))
          (tcp.poll C 0)
          (expect (= (net-link.packet-recv-into Right Wire) -1) "no retransmit before the adaptive deadline")
          (advance F 1)
          (tcp.poll C 0)
          (expect (= (net-link.packet-recv-into Right Wire) 43) "retransmit at the adaptive deadline"))))

(define deliver-timed-retry
  {pair --> boolean}
  F ->
    (do (expect (= (net-link.packet-send (pair.left F) (pair.wire F) 43) net-link.sent) "deliver the retry")
        (receive-timed-data F 50)))

(define adaptive-rto
  {pair --> boolean}
  F ->
    (do (open-with-rtt F 200)
        (train-rtt F 900 1)
        (drop-timed-data F)
        (expect-data-timeout F 1563) \\ SRTT 462.5 ms plus four times RTTVAR 275 ms.
        (expect-data-timeout F 3126) \\ The first retry is also lost.
        (deliver-timed-retry F)
        (drop-timed-data F)
        (expect-data-timeout F 6252) \\ An ambiguous ACK leaves exponential backoff in place.
        (deliver-timed-retry F)
        (train-rtt F 100 4)
        (drop-timed-data F)
        (expect-data-timeout F 1442) \\ Clean, shorter RTTs replace the backed-off timer.
        (deliver-timed-retry F)
        (train-rtt F 100 5)
        (drop-timed-data F)
        (expect-data-timeout F 1000) \\ The computed RTO reaches the one-second floor.
        (deliver-timed-retry F)
        (close-pair F false)))

(define timeout-after-syn-loss
  {fixnum --> boolean}
  Mtu ->
    (let F (setup Mtu)
         C (pair.client F) S (pair.server F)
         Syn (buffer.new 44)
      (do (expect (tcp.listen S 100) "listen after SYN loss")
          (expect (tcp.connect C 4294967294) "queue the original SYN")
          (tcp.poll C 0)
          (expect (= (net-link.packet-recv-into (pair.right F) Syn) 44) "drop the original SYN")
          (advance F 1000)
          (tcp.poll C 0)
          (advance F 50)
          (expect (= (tcp.poll S 2) 1) "receive the retransmitted SYN")
          (advance F 50)
          (expect (= (tcp.poll C 2) 1) "receive the ambiguous SYN-ACK")
          (expect (= (tcp.poll S 2) 1) "complete the handshake")
          (drop-timed-data F)
          (expect-data-timeout F 3000)
          (deliver-timed-retry F)
          (close-pair F false))))

(define exercise
  {pair --> fixnum --> boolean --> boolean}
  _ 0 _ -> true
  F N Allocate ->
    (let P (pair.payload F)
         Input (if Allocate (buffer.slice P 0 3) P)
      (and (loss-cycle F Input false) (loss-cycle F Input true)
           (exercise F (fx- N 1) Allocate))))

(define fill-sack-payload
  {buffer.view --> fixnum --> buffer.view}
  B 192 -> B
  B I -> (fill-sack-payload (buffer.u8-> B I I) (fx+ I 1)))

(define make-sack-case
  {fixnum --> sack-case}
  Mtu ->
    (let Payload (fill-sack-payload (buffer.new 192) 0)
      (:sack-case
        peers <- (setup-link Mtu 8)
        packet <- (buffer.new Mtu)
        payload <- Payload
        short <- (buffer.slice Payload 72 12)
        suffix <- (buffer.slice Payload 84 108)
        output <- (buffer.new 192))))

(define open-sack
  {pair --> buffer.view --> boolean}
  F Wire ->
    (let C (pair.client F) S (pair.server F)
         L (pair.left F) R (pair.right F)
      (do (expect (tcp.listen S 100) "listen for SACK negotiation")
          (expect (tcp.connect C 4294967150) "open near sequence wrap")
          (tcp.poll C 0)
          (expect (= (net-link.packet-recv-into R Wire) 44) "capture SYN with options")
          (expect (= (buffer.u16-be Wire 40) 1026) "SYN carries SACK-Permitted")
          (expect (= (net-link.packet-send L Wire 44) net-link.sent) "deliver the offer")
          (tcp.poll S 2)
          (expect (= (net-link.packet-recv-into L Wire) 44) "capture SYN-ACK with options")
          (expect (= (buffer.u16-be Wire 40) 1026) "SYN-ACK carries SACK-Permitted")
          (expect (= (net-link.packet-send R Wire 44) net-link.sent) "deliver the reply")
          (tcp.poll C 2)
          (tcp.poll S 2)
          (expect (and (= (tcp.state C) tcp.established) (= (tcp.state S) tcp.established))
                  "complete SACK negotiation"))))

(define drop-sack-gaps
  {pair --> buffer.view --> fixnum --> boolean}
  _ _ 6 -> true
  F Wire I ->
    (let Size (if (= I 2) (type 52 fixnum) 76)
      (do (expect (= (net-link.packet-recv-into (pair.right F) Wire) Size) "capture a segment of the six-segment flight")
          (if (or (= I 0) (= I 2)) true
              (expect (= (net-link.packet-send (pair.left F) Wire Size) net-link.sent) "deliver a later segment"))
          (drop-sack-gaps F Wire (fx+ I 1)))))

(define sack-retry
  {pair --> buffer.view --> fixnum --> fixnum --> boolean}
  F Wire Sequence Size ->
    (do (expect (= (net-link.packet-recv-into (pair.right F) Wire) Size) "one retransmission limited to the gap before timeout")
        (expect (= (buffer.u32-be Wire 24) Sequence) "retransmit the missing sequence")
        (tcp.poll (pair.client F) 0)
        (expect (= (net-link.packet-recv-into (pair.right F) Wire) -1) "no extra retransmission")
        (expect (= (net-link.packet-send (pair.left F) Wire Size) net-link.sent) "deliver just the missing segment")
        (expect (= (tcp.poll (pair.server F) 8) 1) "accept the repair")))

(define sack-loss
  {sack-case --> boolean}
  T ->
    (let F (sack-case.peers T)
         C (pair.client F) S (pair.server F)
         L (pair.left F) R (pair.right F)
         Wire (sack-case.packet T)
         Payload (sack-case.payload T)
         Out (sack-case.output T)
      (do (open-sack F Wire)
          (expect (= (tcp.send C Payload 36) 36) "queue slow-start data")
          (do (tcp.poll C 0) (tcp.poll S 1) (tcp.poll C 1))
          (expect (= (tcp.send C Payload 36) 36) "queue another slow-start segment")
          (do (tcp.poll C 0) (tcp.poll S 1) (tcp.poll C 1))
          (expect (= (tcp.recv-into S Out 192) 72) "drain the slow-start data")
          (tcp.poll S 0)
          (tcp.poll C 2)
          (expect (= (tcp.send C Payload 72) 72) "queue the first two segments")
          (tcp.poll C 0)
          (tcp.poll C 0)
          (expect (= (tcp.send C (sack-case.short T) 12) 12) "queue a short third segment")
          (tcp.poll C 0)
          (expect (= (tcp.send C (sack-case.suffix T) 108) 108) "queue the last three segments")
          (poll-burst C 8)
          (drop-sack-gaps F Wire 0)
          (advance F 25)
          (expect (= (tcp.poll S 8) 4) "receive four segments above two gaps")
          (expect (= (tcp.recv-into S Out 192) 0) "the first gap holds all later bytes")
          (expect (= (net-link.packet-recv-into L Wire) 60) "emit an ACK with two SACK blocks")
          (expect (= (buffer.u32-be Wire 28) 4294967223) "the cumulative ACK stays at the first loss")
          (expect (= (buffer.u32-be Wire 40) 16844050) "two NOPs and a SACK option of length 18")
          (expect (and (= (buffer.u32-be Wire 44) 11) (= (buffer.u32-be Wire 48) 119))
                  "most recent contiguous range is reported first")
          (expect (and (= (buffer.u32-be Wire 52) 4294967259) (= (buffer.u32-be Wire 56) 4294967295))
                  "the second block excludes the second loss")
          (buffer.u8-> Wire 33 24) \\ Avoid counting this ACK toward the fast-retransmit threshold.
          (buffer.u32-be-> Wire 44 4294967224)
          (buffer.u32-be-> Wire 48 120) \\ This range extends one byte beyond SND.NXT.
          (checksum-segment Wire 40)
          (expect (= (net-link.packet-send R Wire 60) net-link.sent) "deliver an out-of-flight SACK block")
          (expect (= (tcp.poll C 1) 1) "ignore the invalid block")
          (buffer.u8-> Wire 33 16)
          (buffer.u32-be-> Wire 44 11)
          (buffer.u32-be-> Wire 48 119)
          (checksum-segment Wire 40)
          (expect (= (net-link.packet-send R Wire 60) net-link.sent) "deliver the first SACK ACK")
          (tcp.poll C 1)
          (tcp.poll S 0)
          (tcp.poll C 1)
          (tcp.poll S 0)
          (tcp.poll C 1)
          (sack-retry F Wire 4294967223 76)
          (expect (= (net-link.packet-recv-into L Wire) 52) "partial ACK carries one remaining SACK block")
          (expect (= (buffer.u32-be Wire 28) 4294967295) "partial ACK reaches the second gap")
          (expect (and (= (buffer.u32-be Wire 44) 11) (= (buffer.u32-be Wire 48) 119))
                  "the delivered suffix remains selectively acknowledged")
          (expect (= (net-link.packet-send R Wire 52) net-link.sent) "deliver partial ACK")
          (tcp.poll C 1)
          (sack-retry F Wire 4294967295 52)
          (expect (= (tcp.recv-into S Out 192) 192) "both gaps repaired before advancing the clock again")
          (expect (buffer.equal? Out Payload) "entire window recovered in order")
          (expect (= (tcp.recv-into S Out 192) 0) "no duplicate delivery")
          (expect (= (tcp.poll C 2) 1) "cumulative ACK retires the recovered flight")
          (expect (= (net-link.packet-recv-into R Wire) -1) "selectively acknowledged data was never replayed")
          (close-pair F false))))

(define make-window-case
  {fixnum --> window-case}
  Mtu ->
    (:window-case
      peers <- (setup-link Mtu 8)
      payload <- (buffer.from-string "abcdefghijklmno")
      suffix <- (buffer.from-string "defghi")
      output <- (buffer.new 6)
      fast-output <- (buffer.new 15)
      congestion-payload <- (buffer.new 24)
      congestion-output <- (buffer.new 24)
      congestion-ack <- (buffer.new 40)
      sack <- (make-sack-case 76)))

(define exercise-window
  {window-case --> fixnum --> boolean}
  _ 0 -> true
  W N ->
    (and (window-loss (window-case.peers W) (window-case.payload W) (window-case.suffix W) (window-case.output W))
         (reorder-window (window-case.peers W) (window-case.payload W) (window-case.suffix W) (window-case.output W))
         (fast-loss (window-case.peers W) (window-case.payload W) (window-case.fast-output W))
         (adaptive-rto (window-case.peers W))
         (congestion-growth (window-case.peers W) (window-case.congestion-payload W)
                            (window-case.congestion-output W) (window-case.congestion-ack W))
         (sack-loss (window-case.sack W))
         (exercise-window W (fx- N 1))))

(define verify
  {fixnum --> boolean --> boolean}
  Iterations Allocate ->
    (let F (setup 128)
         W (make-window-case 43)
      (and (exercise F 1 false) (exercise F 1 true) (exercise-window W 1)
           (exercise F Iterations Allocate) (exercise-window W Iterations))))

(define exchange-polls
  {tcp.peer --> tcp.peer --> fixnum --> boolean}
  _ _ 0 -> true
  C S N -> (do (tcp.poll C 2) (tcp.poll S 2) (exchange-polls C S (fx- N 1))))

(define receive-window
  {fixnum --> boolean}
  Mtu ->
    (let F (setup Mtu)
         C (pair.client F) S (pair.server F)
         P (pair.payload F)
         Full (buffer.from-string "abcdefgh")
         Out (buffer.new 8)
      (do (open-pair C S)
          (expect (= (tcp.send C Full 8) 8) "queue a receive window's worth of data")
          (expect (= (tcp.send C P 3) 0) "a full local send ring applies backpressure")
          (exchange-polls C S 8)
          (tcp.poll C 2)
          (expect (= (tcp.send C P 3) 3) "buffer writes while the advertised window is closed")
          (tcp.poll C 2)
          (tcp.poll C 0)
          (expect (= (net-link.packet-recv-into (pair.right F) (pair.wire F)) 41) "one-byte zero-window probe")
          (expect (= (net-link.packet-recv-into (pair.right F) (pair.wire F)) -1) "only one probe in flight")
          (expect (= (net-link.packet-send (pair.left F) (pair.wire F) 41) net-link.sent) "deliver zero-window probe")
          (tcp.poll S 2)
          (tcp.poll C 2)
          (expect (= (tcp.recv-into S Out 8) 8) "original bytes survived the probe")
          (expect (buffer.equal? Full Out) "original window contents")
          (expect (= (tcp.recv-into S Out 3) 0) "full receiver did not accept the probe")
          (tcp.poll S 2)
          (expect (= (net-link.packet-recv-into (pair.left F) (pair.wire F)) 40) "drop window update")
          (advance F 1000)
          (tcp.poll C 2)
          (tcp.poll S 2)
          (expect (= (tcp.recv-into S Out 3) 1) "probe recovers a lost window update")
          (expect (= (buffer.u8 Out 0) 97) "probe byte")
          (expect (= (tcp.recv-into S Out 3) 0) "probe delivered once")
          (exchange-polls C S 2)
          (expect (= (tcp.recv-into S Out 3) 2) "the reopened window delivers queued bytes")
          (expect (and (= (buffer.u8 Out 0) 98) (= (buffer.u8 Out 1) 99)) "remaining bytes"))))

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
          (expect (= (buffer.string Out) "bcabc") "partial reads preserve stream order"))))

(define ring-wrap
  {fixnum --> boolean}
  Mtu -> (let F (setup Mtu)
          C (pair.client F)
          S (pair.server F)
          Prefix (buffer.from-string "abcdefghijklmnopqrstuvw")
          Suffix (buffer.from-string "xyz012")
          Out (buffer.new 23)
          Tail (buffer.new 6)
       (do (open-pair C S)
           (expect (= (tcp.send C Prefix 23) 23) "queue all but the final ring byte")
           (exchange-polls C S 8)
           (expect (= (tcp.recv-into S Out 23) 23) "advance the receive head")
           (expect (buffer.equal? Out Prefix) "first window content")
           (tcp.poll S 0)
           (tcp.poll C 2)
           (expect (= (tcp.send C Suffix 6) 6) "write across the send ring boundary")
           (tcp.poll C 0)
           (expect (= (net-link.packet-recv-into (pair.right F) (pair.original F)) 43) "delay ring-wrapping segment")
           (tcp.poll C 0)
           (tcp.poll S 2)
           (expect (= (tcp.recv-into S Tail 6) 0) "later bytes wait across a ring wrap")
           (expect (= (net-link.packet-send (pair.left F) (pair.original F) 43) net-link.sent) "fill the ring gap")
           (tcp.poll S 2)
           (expect (= (tcp.recv-into S Tail 6) 6) "read across the receive ring boundary")
           (expect (buffer.equal? Tail Suffix) "ring wrap preserves bytes"))))

(define overlapping-replay
  {fixnum --> boolean}
  Mtu -> (let F (setup Mtu)
              C (pair.client F)
              S (pair.server F)
              Left (pair.left F)
              Right (pair.right F)
              Wire (pair.wire F)
              Rest (buffer.from-string "bcdef")
              Out (buffer.new 6)
          (do (open-pair C S)
              (expect (= (tcp.send C (pair.payload F) 1) 1) "send a short first segment")
              (tcp.poll C 0)
              (tcp.poll S 2)
              (expect (= (net-link.packet-recv-into Left Wire) 40) "lose the short segment's ACK")
              (expect (= (tcp.send C Rest 5) 5) "append while the short segment is in flight")
              (tcp.poll C 0)
              (tcp.poll C 0)
              (expect (= (net-link.packet-recv-into Right Wire) 43) "lose following segment")
              (expect (= (tcp.poll S 2) 1) "retain the final segment above the gap")
              (advance F 1000)
              (tcp.poll C 0)
              (expect (= (net-link.packet-recv-into Right Wire) 43) "capture the first replay")
              (expect (= (net-link.packet-send Left Wire 43) net-link.sent) "send first replay")
              (expect (= (tcp.poll S 2) 1) "receive the first retransmission")
              (expect (= (tcp.poll C 2) 2) "ACK progress permits the next replay")
              (expect (= (net-link.packet-recv-into Right (pair.original F)) 43) "capture the second replay")
              (buffer.u16-be-> (pair.original F) 41 22616) \\ Two conflicting duplicate bytes, both X.
              (checksum-segment (pair.original F) 23)
              (expect (= (net-link.packet-send Left (pair.original F) 43) net-link.sent) "send overlapping replay")
              (expect (= (tcp.poll S 2) 1) "receive replay with different segment boundaries")
              (expect (= (tcp.recv-into S Out 6) 6) "trim the replay's duplicate prefix")
              (expect (= (buffer.string Out) "abcdef") "deliver only new bytes from the overlap")
              (expect (= (tcp.recv-into S Out 6) 0) "all bytes delivered exactly once")
              (tcp.poll C 2)
              (close-pair F false))))

(define receive-window-edge
  {fixnum --> boolean}
  Mtu ->
    (let F (setup Mtu)
         C (pair.client F) S (pair.server F)
         Left (pair.left F) Right (pair.right F)
         Held (pair.original F) Wire (pair.wire F)
         Payload (buffer.from-string "abcdefghijklmnopqrstuvwx")
         Out (buffer.new 24)
      (do (open-pair C S)
          (expect (= (tcp.send C Payload 24) 24) "queue an entire window")
          (tcp.poll C 0)
          (expect (= (net-link.packet-recv-into Right Held) 43) "hold the first segment at the left edge")
          (buffer.copy-into! Wire 0 Held 0 43)
          (buffer.u32-be-> Wire 24 21)
          (buffer.u8-> Wire 40 119)
          (buffer.u8-> Wire 41 120)
          (buffer.u8-> Wire 42 122)
          (checksum-segment Wire 23)
          (expect (= (net-link.packet-send Left Wire 43) net-link.sent) "send two in-window bytes and one past the edge")
          (tcp.poll S 2)
          (expect (= (net-link.packet-recv-into Left Wire) 40) "ACK the gap with the window unchanged")
          (expect (= (buffer.u16-be Wire 34) 24) "clipped segment does not shrink the window")
          (expect (= (net-link.packet-send Left Held 43) net-link.sent) "restore the first segment")
          (exchange-polls C S 8)
          (expect (= (tcp.recv-into S Out 24) 24) "read exactly the bounded window")
          (expect (buffer.equal? Out Payload) "the byte outside the window did not overwrite ring data")
          (expect (= (tcp.recv-into S Out 24) 0) "the clipped byte was discarded")
          (tcp.poll S 0)
          (tcp.poll C 2)
          (close-pair F false))))

\\ Build a FIN from a captured header to model a peer that sends it before data is acknowledged.
(define reordered-fin
  {fixnum --> boolean}
  Mtu ->
    (let F (setup Mtu)
         C (pair.client F) S (pair.server F)
         Left (pair.left F) Right (pair.right F)
         Held (pair.original F) Fin (pair.wire F)
         Out (pair.server-out F)
      (do (open-pair C S)
          (expect (= (tcp.send C (pair.payload F) 3) 3) "queue bytes preceding FIN")
          (tcp.poll C 0)
          (expect (= (net-link.packet-recv-into Right Held) 43) "hold data preceding FIN")
          (buffer.copy-into! Fin 0 Held 0 40)
          (net-ipv4.write-header Fin 0 40 6 (buffer.u32-be Held 12) (buffer.u32-be Held 16))
          (buffer.u32-be-> Fin 24 2)
          (buffer.u8-> Fin 33 17)
          (checksum-segment Fin 20)
          (expect (= (net-link.packet-send Left Fin 40) net-link.sent) "deliver FIN ahead of data")
          (expect (= (tcp.poll S 2) 1) "remember out-of-order FIN")
          (expect (= (tcp.state S) tcp.established) "FIN waits for the gap")
          (expect (= (tcp.recv-into S Out 3) 0) "EOF is hidden while bytes are missing")
          (expect (= (net-link.packet-recv-into Left Fin) 40) "ACK the gap before FIN")
          (expect (= (buffer.u32-be Fin 28) 4294967295) "early FIN does not advance the ACK")
          (expect (= (net-link.packet-send Left Held 43) net-link.sent) "deliver the data before FIN")
          (expect (= (tcp.poll S 2) 1) "process data and the staged FIN")
          (expect (= (tcp.state S) tcp.close-wait) "FIN is consumed once the gap closes")
          (expect (= (net-link.packet-recv-into Left Fin) 40) "ACK data and FIN")
          (expect (= (buffer.u32-be Fin 28) 3) "ACK includes FIN sequence space")
          (expect (= (tcp.recv-into S Out 3) 3) "read data before EOF")
          (expect (buffer.equal? Out (pair.payload F)) "data before EOF remains intact")
          (expect (= (tcp.recv-into S Out 3) -1) "EOF follows the last byte"))))

(define open-listener
  {tcp.peer --> tcp.listener --> fixnum --> fixnum}
  C L Seq ->
    (do (expect (tcp.connect C Seq) "connect to the listener")
        (tcp.poll C 0)
        (tcp.listener-poll L 2)
        (tcp.poll C 2)
        (tcp.listener-poll L 2)
        (tcp.accept L)))

(define reset-staged-slot
  {fixnum --> boolean}
  Mtu ->
    (let Link (net-link.make 2 Mtu 0 (freeze 0))
         Left (net-link.left Link) Right (net-link.right Link)
         A (net-ipv4.address 192 0 2 1) B (net-ipv4.address 192 0 2 2)
         L (tcp.make-listener Right B 7 1 1000)
         First (tcp.make-peer Left A 12345 B 7)
         Second (tcp.make-peer Left A 12346 B 7)
         Packet (buffer.new 43)
         Out (buffer.new 6)
         Stale (buffer.from-string "abcdef")
         Fresh (buffer.from-string "012345")
         Old (open-listener First L 10)
      (do (expect (fx> Old 0) "accept the first connection")
          (expect (= (tcp.send First Stale 6) 6) "queue data before reset")
          (tcp.poll First 0)
          (expect (= (net-link.packet-recv-into Right Packet) 43) "hold the first segment before reset")
          (tcp.poll First 0)
          (tcp.listener-poll L 2)
          (expect (= (tcp.connection-recv-into L Old Out 6) 0) "the old slot holds a gap")
          (net-ipv4.write-header Packet 0 40 6 A B)
          (buffer.u8-> Packet 33 4)
          (checksum-segment Packet 20)
          (expect (= (net-link.packet-send Left Packet 40) net-link.sent) "send reset at the missing sequence")
          (tcp.listener-poll L 2)
          (expect (= (tcp.connection-state L Old) tcp.reset) "reset terminal state")
          (expect (tcp.release L Old) "release the slot with staged bytes")
          (let New (open-listener Second L 30)
            (do (expect (and (fx> New 0) (not (= New Old))) "reuse the slot with a fresh token")
                (expect (= (tcp.send Second Fresh 6) 6) "queue replacement data")
                (tcp.poll Second 0)
                (expect (= (net-link.packet-recv-into Right Packet) 43) "delay the new first segment")
                (tcp.poll Second 0)
                (tcp.listener-poll L 2)
                (expect (= (net-link.packet-send Left Packet 43) net-link.sent) "fill the new gap")
                (tcp.listener-poll L 2)
                (expect (= (tcp.connection-recv-into L New Out 6) 6) "read the new stream")
                (expect (buffer.equal? Out Fresh) "reset never exposes staged bytes from the prior connection"))))))

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
         Wire (buffer.new 44)
      (do (expect (tcp.connect First 71) "first SYN")
          (tcp.poll First 0)
          (tcp.listener-poll L 2)
          (expect (tcp.connect Second 72) "second SYN")
          (tcp.poll Second 0)
          (tcp.listener-poll L 2)
          (fxvector-> Time 1 1000)
          (tcp.listener-poll L 0)
          (tcp.listener-poll L 0)
          (expect (= (net-link.packet-recv-into Left Wire) 44) "drain the full output ring")
          (expect (= (buffer.u16-be Wire 22) 12345) "first SYN-ACK")
          (tcp.listener-poll L 0)
          (expect (= (net-link.packet-recv-into Left Wire) 44) "waiting peer gets next output slot")
          (expect (= (buffer.u16-be Wire 22) 12346) "blocked polls preserve send rotation")
          (tcp.listener-poll L 0)
          (expect (= (net-link.packet-recv-into Left Wire) 44) "first peer still retransmits")
          (expect (= (buffer.u16-be Wire 22) 12345) "first SYN-ACK retry"))))

(define discard-syn-acks
  {(list fixnum) --> (vector fixnum) --> tcp.listener --> net-link.device --> buffer.view --> boolean}
  [] _ _ _ _ -> true
  [Now | Rest] Time L D Wire ->
    (do (fxvector-> Time 1 Now)
        (tcp.listener-poll L 2)
        (expect (= (net-link.packet-recv-into D Wire) 44) "discard a SYN-ACK before accepting")
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
         Wire (buffer.new 44)
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
  Mtu -> (and (fixture Mtu) (option-fixtures Mtu) (receive-window 41) (partial-read 45)
              (ring-wrap 43) (overlapping-replay 43) (receive-window-edge 43) (reordered-fin 43) (reset-staged-slot 43)
              (timeout-after-syn-loss Mtu) (listener-reuse Mtu) (listener-fairness Mtu)
              (listener-half-open-timeout Mtu) (verify 1 false)))

(preclude [pair.%match window-case.%match sack-case.%match])
)
