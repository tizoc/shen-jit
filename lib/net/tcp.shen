\\ Typed TCP over the packet link with preallocated send and receive windows.
(shen.x.namespace tcp
  (use buffer)
  (use net-link)
  (use net-ipv4)
  (use shen-jit)
  (import struct defstruct)
  (shadow listen release)
  (export peer make-peer listen connect state send recv-into shutdown-write poll
          listener make-listener listener-poll accept connection-index connection-state
          listener-ingress listener-transmit
          connection-send connection-recv-into connection-shutdown-write release
          closed listen-state syn-sent syn-received established close-wait fin-wait-1 fin-wait-2
          closing last-ack time-wait timed-out reset)

(defstruct peer
  (device : net-link.device)
  (local-ip : fixnum)
  (local-port : fixnum)
  (mutable remote-ip : fixnum)
  (mutable remote-port : fixnum)
  (tx : buffer.view)
  (rx : buffer.view)
  (mss : fixnum)
  (capacity : fixnum)
  (mutable phase : symbol)
  (mutable send-next : fixnum)
  (mutable tx-flags : fixnum)
  (mutable tx-head : fixnum)
  (mutable tx-length : fixnum)
  (mutable tx-flight : fixnum)
  (mutable tx-replay : fixnum)
  (mutable tx-due : fixnum)
  (mutable tx-rto : fixnum)
  (mutable tx-retries : fixnum)
  (mutable remote-window : fixnum)
  (mutable remote-window-seq : fixnum)
  (mutable remote-window-ack : fixnum)
  (mutable send-mss : fixnum)
  (mutable recv-next : fixnum)
  (mutable rx-start : fixnum)
  (mutable rx-length : fixnum)
  (mutable recv-eof : boolean)
  (mutable ack-needed : boolean)
  (mutable wait-until : fixnum))

(define smaller
  {fixnum --> fixnum --> fixnum}
  A B -> (if (fx< A B) A B))

(define endpoint?
  {fixnum --> fixnum --> boolean}
  IP Port -> (and (net-ipv4.unicast? IP) (fx>= Port 1) (fx<= Port 65535)))

(define peer-mss
  {net-link.device --> fixnum}
  D -> (smaller 536 (fx- (net-link.mtu D) 40)))

(define new-peer
  {net-link.device --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> peer}
  D LocalIP LocalPort RemoteIP RemotePort Mss ->
    (let Capacity (fx* Mss 8)
      (:peer
        device <- D
        local-ip <- LocalIP
        local-port <- LocalPort
        remote-ip <- RemoteIP
        remote-port <- RemotePort
        tx <- (buffer.new Capacity)
        rx <- (buffer.new Capacity)
        mss <- Mss
        capacity <- Capacity
        phase <- closed
        send-next <- 0
        tx-flags <- 0
        tx-head <- 0
        tx-length <- 0
        tx-flight <- 0
        tx-replay <- -1
        tx-due <- -1
        tx-rto <- 1000
        tx-retries <- 0
        remote-window <- 0
        remote-window-seq <- 0
        remote-window-ack <- 0
        send-mss <- Mss
        recv-next <- 0
        rx-start <- 0
        rx-length <- 0
        recv-eof <- false
        ack-needed <- false
        wait-until <- 0)))

(define make-peer
  {net-link.device --> fixnum --> fixnum --> fixnum --> fixnum --> peer}
  D LocalIP LocalPort RemoteIP RemotePort ->
    (let Mss (peer-mss D)
      (if (and (endpoint? LocalIP LocalPort) (endpoint? RemoteIP RemotePort) (fx> Mss 0))
          (new-peer D LocalIP LocalPort RemoteIP RemotePort Mss)
          (error "tcp: need two unicast endpoints and an MTU of at least 41"))))

(define state
  {peer --> symbol}
  P -> (peer.phase P))

(define seq-add
  {fixnum --> fixnum --> fixnum}
  Seq N -> (shen-jit.bit-and (fx+ Seq N) 4294967295))

(define seq-distance
  {fixnum --> fixnum --> fixnum}
  End Start -> (seq-add End (fx- 0 Start)))

(define seq-after?
  {fixnum --> fixnum --> boolean}
  A B -> (let Delta (seq-distance A B)
           (and (fx> Delta 0) (fx< Delta 2147483648))))

(define flag?
  {fixnum --> fixnum --> boolean}
  Flags Bit -> (not (= (shen-jit.bit-and Flags Bit) 0)))

(define begin
  {peer --> fixnum --> symbol --> boolean}
  P Seq Phase ->
    (if (and (= (state P) closed) (= (peer.rx-length P) 0))
        (let _ (if (and (fx>= Seq 0) (fx<= Seq 4294967295)) true
                     (error "tcp: initial sequence must fit unsigned 32 bits"))
          (do (peer.send-next-> P Seq)
              (peer.tx-flags-> P 0)
              (peer.tx-head-> P 0)
              (peer.tx-length-> P 0)
              (peer.tx-flight-> P 0)
              (peer.tx-replay-> P -1)
              (peer.tx-due-> P -1)
              (peer.tx-rto-> P 1000)
              (peer.tx-retries-> P 0)
              (peer.remote-window-> P 0)
              (peer.send-mss-> P (peer.mss P))
              (peer.recv-next-> P 0)
              (peer.rx-start-> P 0)
              (peer.recv-eof-> P false)
              (peer.ack-needed-> P false)
              (peer.phase-> P Phase)
              true))
        false))

(define queue-control
  {peer --> fixnum --> boolean}
  P Flags ->
    (do (peer.tx-due-> P -1)
        (peer.tx-rto-> P 1000)
        (peer.tx-retries-> P 0)
        (peer.tx-flags-> P Flags)
        true))

(define listen
  {peer --> fixnum --> boolean}
  P Seq -> (begin P Seq listen-state))

(define connect
  {peer --> fixnum --> boolean}
  P Seq -> (and (begin P Seq syn-sent) (queue-control P 2)))

(define window
  {peer --> fixnum}
  P -> (fx- (peer.capacity P) (peer.rx-length P)))

(define wrap-offset
  {fixnum --> fixnum --> fixnum}
  At Capacity -> (if (fx>= At Capacity) (fx- At Capacity) At))

(define copy-into-ring
  {buffer.view --> fixnum --> fixnum --> buffer.view --> fixnum --> fixnum --> buffer.view}
  Ring At Capacity Source Start Count ->
    (let First (smaller Count (fx- Capacity At))
      (do (buffer.copy-into! Ring At Source Start First)
          (if (= First Count) Ring
              (buffer.copy-into! Ring 0 Source (fx+ Start First) (fx- Count First))))))

(define copy-from-ring
  {buffer.view --> fixnum --> buffer.view --> fixnum --> fixnum --> fixnum --> buffer.view}
  Out Start Ring At Capacity Count ->
    (let First (smaller Count (fx- Capacity At))
      (do (buffer.copy-into! Out Start Ring At First)
          (if (= First Count) Out
              (buffer.copy-into! Out (fx+ Start First) Ring 0 (fx- Count First))))))

(define send
  {peer --> buffer.view --> fixnum --> fixnum}
  P Payload Count ->
    (let Limit (buffer.index Count)
         _ (buffer.range (buffer.length Payload) 0 Limit)
         Phase (state P)
         Capacity (peer.capacity P)
         Length (peer.tx-length P)
         N (smaller Limit (fx- Capacity Length))
      (if (and (or (= Phase established) (= Phase close-wait)) (fx> N 0))
          (let Tail (wrap-offset (fx+ (peer.tx-head P) Length) Capacity)
            (do (copy-into-ring (peer.tx P) Tail Capacity Payload 0 N)
                (peer.tx-length-> P (fx+ Length N))
                N))
          0)))

(define recv-into
  {peer --> buffer.view --> fixnum --> fixnum}
  P Out Count ->
    (let Limit (buffer.index Count)
         _ (buffer.range (buffer.length Out) 0 Limit)
         N (smaller Limit (peer.rx-length P))
      (cases (fx> N 0)
               (let Left (fx- (peer.rx-length P) N)
                 (do (copy-from-ring Out 0 (peer.rx P) (peer.rx-start P) (peer.capacity P) N)
                     (peer.rx-start-> P (wrap-offset (fx+ (peer.rx-start P) N) (peer.capacity P)))
                     (peer.rx-length-> P Left)
                     (if (peer.recv-eof P) P (peer.ack-needed-> P true))
                     N))
             (and (fx> Limit 0) (peer.recv-eof P) (= (peer.rx-length P) 0)) -1
             true 0)))

(define shutdown-write
  {peer --> boolean}
  P ->
    (let Phase (state P)
      (if (and (or (= Phase established) (= Phase close-wait)) (= (peer.tx-length P) 0))
          (do (queue-control P 17)
              (peer.phase-> P (if (= Phase established) fin-wait-1 last-ack))
              true)
          false)))

(define write-segment
  {peer --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> buffer.view}
  P B I Flags Seq At Count ->
    (do (net-ipv4.write-header B I (fx+ Count 40) 6 (peer.local-ip P) (peer.remote-ip P))
        (buffer.u16-be-> B (fx+ I 20) (peer.local-port P))
        (buffer.u16-be-> B (fx+ I 22) (peer.remote-port P))
        (buffer.u32-be-> B (fx+ I 24) Seq)
        (buffer.u32-be-> B (fx+ I 28) (if (flag? Flags 16) (peer.recv-next P) 0))
        (buffer.u16-be-> B (fx+ I 32) (fx+ 20480 Flags))
        (buffer.u16-be-> B (fx+ I 34) (window P))
        (buffer.u16-be-> B (fx+ I 36) 0)
        (buffer.u16-be-> B (fx+ I 38) 0)
        (if (= Count 0) B
            (copy-from-ring B (fx+ I 40) (peer.tx P) At (peer.capacity P) Count))
        (buffer.u16-be-> B (fx+ I 36) (net-ipv4.transport-checksum B I 6 (fx+ Count 20)))))

(define emit-segment
  {peer --> net-link.ring --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  P R Now Flags Seq At Count ->
    (let Delivery (net-link.delivery (peer.device P) Now)
      (do (write-segment P (net-link.ring.data R) (net-link.tail-offset R) Flags Seq At Count)
          (net-link.publish R (fx+ Count 40) Delivery)
          (if (flag? Flags 16) (peer.ack-needed-> P false) P)
          true)))

(define stop-peer
  {peer --> symbol --> boolean}
  P Phase -> (do (peer.phase-> P Phase)
                 (peer.tx-flags-> P 0)
                 (peer.tx-length-> P 0)
                 (peer.tx-flight-> P 0)
                 (peer.tx-replay-> P -1)
                 (peer.tx-due-> P -1)
                 (peer.ack-needed-> P false)
                 true))

(define backoff
  {peer --> fixnum --> boolean}
  P Now ->
    (let Rto (smaller 60000 (fx* 2 (peer.tx-rto P)))
      (do (peer.tx-rto-> P Rto)
          (peer.tx-due-> P (fx+ Now Rto))
          (peer.tx-retries-> P (fx+ (peer.tx-retries P) 1))
          true)))

(define send-control
  {peer --> net-link.ring --> fixnum --> boolean}
  P R Now ->
    (let Flags (peer.tx-flags P)
         First (fx< (peer.tx-due P) 0)
         Next (peer.send-next P)
      (do (emit-segment P R Now Flags (if First Next (seq-add Next -1)) 0 0)
          (if First
              (do (peer.send-next-> P (seq-add Next 1))
                  (peer.tx-due-> P (fx+ Now (peer.tx-rto P)))
                  true)
              (backoff P Now)))))

\\ Queued bytes are split into an in-flight prefix and a never-sent suffix.
\\ Replay uses offsets within that prefix relative to tx-head.
(define emit-data
  {peer --> net-link.ring --> fixnum --> fixnum --> fixnum --> boolean}
  P R Now Offset Count ->
    (let Seq (seq-add (peer.send-next P) (fx- Offset (peer.tx-flight P)))
         At (wrap-offset (fx+ (peer.tx-head P) Offset) (peer.capacity P))
      (emit-segment P R Now 24 Seq At Count)))

(define replay-data
  {peer --> net-link.ring --> fixnum --> fixnum --> fixnum --> boolean --> boolean}
  P R Now Offset End Retry ->
    (let N (smaller (peer.send-mss P) (fx- End Offset))
         Next (fx+ Offset N)
      (do (emit-data P R Now Offset N)
          (peer.tx-replay-> P (if (fx< Next End) Next -1))
          (if Retry (backoff P Now) true))))

(define send-new-data
  {peer --> net-link.ring --> fixnum --> fixnum --> fixnum --> boolean}
  P R Now Flight N ->
    (do (emit-data P R Now Flight N)
        (peer.tx-flight-> P (fx+ Flight N))
        (peer.send-next-> P (seq-add (peer.send-next P) N))
        (if (= Flight 0) (peer.tx-due-> P (fx+ Now (peer.tx-rto P))) P)
        true))

(define flush-data
  {peer --> net-link.ring --> fixnum --> boolean --> boolean}
  P R Now Expired ->
    (let Flight (peer.tx-flight P)
         Replay (peer.tx-replay P)
         Window (peer.remote-window P)
         End (smaller Flight (if (= Window 0) 1 Window))
         Available (if (and (= Window 0) (= Flight 0)) (type 1 fixnum) (fx- Window Flight))
         N (smaller (fx- (peer.tx-length P) Flight) (smaller (peer.send-mss P) Available))
      (cases (and (fx>= Replay 0) (fx< Replay End)) (replay-data P R Now Replay End false)
             (and Expired (fx> End 0)) (replay-data P R Now 0 End true)
             (fx> N 0) (send-new-data P R Now Flight N)
             true false)))

(define flush
  {peer --> fixnum --> boolean}
  P Now ->
    (let R (net-link.device.tx (peer.device P))
         Due (peer.tx-due P)
         Expired (and (fx>= Due 0) (fx<= Due Now))
         Control (not (= (peer.tx-flags P) 0))
      (cases (and Expired (fx>= (peer.tx-retries P) 6)) (do (stop-peer P timed-out) false)
             (net-link.full? R) false
             (and Control (or (fx< Due 0) Expired)) (send-control P R Now)
             true (or (and (not Control) (flush-data P R Now Expired))
                      (and (peer.ack-needed P) (emit-segment P R Now 16 (peer.send-next P) 0 0))))))

(define header-length
  {buffer.view --> fixnum --> fixnum}
  B I -> (fx* 4 (shen-jit.shift-right (buffer.u8 B (fx+ I 32)) 4)))

\\ Skip unnegotiated options, and read MSS from SYN. Return -1 for malformed options.
(define options
  {buffer.view --> fixnum --> fixnum --> fixnum --> fixnum}
  B I End Mss ->
    (if (= I End) Mss
        (let Kind (buffer.u8 B I)
          (cases (= Kind 0) Mss
                 (= Kind 1) (options B (fx+ I 1) End Mss)
                 (fx< (fx- End I) 2) -1
                 true (let N (buffer.u8 B (fx+ I 1))
                         (cases (or (fx< N 2) (fx> N (fx- End I))) -1
                                (not (= Kind 2)) (options B (fx+ I N) End Mss)
                                (not (= N 4)) -1
                                true (let Advertised (buffer.u16-be B (fx+ I 2))
                                       (if (= Advertised 0) -1
                                           (options B (fx+ I N) End (smaller Mss Advertised))))))))))

(define valid-segment?
  {buffer.view --> fixnum --> fixnum --> boolean}
  B I N ->
    (and (fx>= N 40)
         (net-ipv4.valid? B I N 6)
         (= (shen-jit.bit-and (buffer.u8 B (fx+ I 32)) 15) 0)
         (fx>= (header-length B I) 20)
         (fx<= (header-length B I) (fx- N 20))
         (not (flag? (buffer.u8 B (fx+ I 33)) 32))
         (= (net-ipv4.transport-checksum B I 6 (fx- N 20)) 0)))

(define addressed-to?
  {buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  B I IP Port -> (and (= (buffer.u32-be B (fx+ I 16)) IP)
                       (= (buffer.u16-be B (fx+ I 22)) Port)))

\\ ECN is declined by leaving the negotiation bits clear in replies.
(define segment-flags
  {buffer.view --> fixnum --> fixnum}
  B I -> (shen-jit.bit-and (buffer.u8 B (fx+ I 33)) 31))

(define enter-time-wait
  {peer --> fixnum --> boolean}
  P Now -> (let Until (fx+ Now 120000)
             (do (peer.wait-until-> P Until)
                 (peer.phase-> P time-wait)
                 true)))

(define acknowledge?
  {peer --> fixnum --> boolean}
  P Ack -> (and (not (= (peer.tx-flags P) 0))
                (fx>= (peer.tx-due P) 0)
                (= Ack (peer.send-next P))))

(define reset-timer
  {peer --> fixnum --> fixnum --> boolean}
  P Flight Now ->
    (do (peer.tx-due-> P (if (= Flight 0) -1 (fx+ Now 1000)))
        (peer.tx-rto-> P 1000)
        (peer.tx-retries-> P 0)
        true))

(define remember-window
  {peer --> fixnum --> fixnum --> fixnum --> boolean}
  P Seq Ack Window ->
    (do (peer.remote-window-> P Window)
        (peer.remote-window-seq-> P Seq)
        (peer.remote-window-ack-> P Ack)
        true))

(define update-window
  {peer --> fixnum --> fixnum --> fixnum --> boolean}
  P Seq Ack Window ->
    (let LastSeq (peer.remote-window-seq P)
         LastAck (peer.remote-window-ack P)
      (if (or (seq-after? Seq LastSeq)
              (and (= Seq LastSeq) (or (= Ack LastAck) (seq-after? Ack LastAck))))
          (remember-window P Seq Ack Window)
          false)))

(define acknowledge-control
  {peer --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  P Seq Ack Window Now ->
    (if (acknowledge? P Ack)
        (let Phase (state P)
          (do (remember-window P Seq Ack Window)
              (peer.tx-flags-> P 0)
              (reset-timer P 0 Now)
              (cases (= Phase syn-received) (do (peer.phase-> P established) true)
                     (= Phase fin-wait-1) (do (peer.phase-> P fin-wait-2) true)
                     (= Phase closing) (enter-time-wait P Now)
                     (= Phase last-ack) (stop-peer P closed)
                     true true)))
        false))

(define advance-ack
  {peer --> fixnum --> fixnum --> fixnum --> boolean}
  P N Flight Now ->
    (let Left (fx- Flight N)
         Replay (peer.tx-replay P)
         At (fx- Replay N)
      (do (peer.tx-head-> P (wrap-offset (fx+ (peer.tx-head P) N) (peer.capacity P)))
          (peer.tx-length-> P (fx- (peer.tx-length P) N))
          (peer.tx-flight-> P Left)
          (peer.tx-replay-> P (cases (or (= Left 0) (fx< Replay 0)) -1 (fx< At 0) 0 true At))
          (reset-timer P Left Now))))

(define acknowledge-data
  {peer --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  P Seq Ack Window Now ->
    (let Flight (peer.tx-flight P)
         Una (seq-add (peer.send-next P) (fx- 0 Flight))
         N (seq-distance Ack Una)
         OldWindow (peer.remote-window P)
      (if (fx<= N Flight)
          (do (update-window P Seq Ack Window)
              (cases (fx> N 0) (advance-ack P N Flight Now)
                     (and (fx> Flight 0) (= OldWindow 0) (fx> (peer.remote-window P) 0))
                       (do (peer.tx-replay-> P 0) true)
                     true true))
          false)))

(define acknowledge
  {peer --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  P Seq Ack Window Now ->
    (if (= (peer.tx-flags P) 0)
        (acknowledge-data P Seq Ack Window Now)
        (acknowledge-control P Seq Ack Window Now)))

(define receive-bytes
  {peer --> buffer.view --> fixnum --> fixnum --> boolean}
  P B Start N ->
    (let Rx (peer.rx P)
         Count (peer.rx-length P)
         Capacity (peer.capacity P)
         At (wrap-offset (fx+ (peer.rx-start P) Count) Capacity)
      (do (copy-into-ring Rx At Capacity B Start N)
          (peer.rx-length-> P (fx+ Count N))
          (peer.recv-next-> P (seq-add (peer.recv-next P) N))
          (peer.ack-needed-> P true)
          true)))

(define receive-fin
  {peer --> fixnum --> boolean}
  P Now ->
    (let Phase (state P)
      (do (peer.recv-eof-> P true)
          (peer.recv-next-> P (seq-add (peer.recv-next P) 1))
          (peer.ack-needed-> P true)
          (cases (= Phase established) (do (peer.phase-> P close-wait) true)
                 (= Phase fin-wait-1) (do (peer.phase-> P closing) true)
                 (= Phase fin-wait-2) (enter-time-wait P Now)
                 true true))))

(define answer-duplicate
  {peer --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  P Flags Seq N Now ->
    (if (or (fx> N 0) (flag? Flags 3))
        (do (peer.ack-needed-> P true)
            (if (and (= (state P) time-wait) (flag? Flags 1)
                     (= (seq-add Seq (fx+ N 1)) (peer.recv-next P)))
                (enter-time-wait P Now)
                true))
        false))

(define receive-connected
  {peer --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  P B Start N Flags Seq Ack Win Now ->
    \\ A retransmission may overlap already delivered bytes after resegmentation.
    (let Next (peer.recv-next P)
         Window (window P)
         Skip (seq-distance Next Seq)
         Fin (flag? Flags 1)
         Span (if Fin (fx+ N 1) N)
         Contiguous (or (= Skip 0) (fx< Skip Span))
      (cases (= (state P) time-wait) (answer-duplicate P Flags Seq N Now)
             (flag? Flags 4) (if (= Seq Next) (stop-peer P reset) false)
             (flag? Flags 2) (answer-duplicate P Flags Seq N Now)
             (or (not (flag? Flags 16)) (seq-after? Ack (peer.send-next P))) false
             true
               (do (if (or Contiguous (fx< (seq-distance Seq Next) Window))
                       (acknowledge P Seq Ack Win Now) false)
                   (if (and Contiguous (fx> Span 0) (not (peer.recv-eof P)))
                       (let Count (fx- N Skip)
                            Accepted (smaller Count Window)
                         (do (peer.ack-needed-> P true)
                             (if (fx> Accepted 0) (receive-bytes P B (fx+ Start Skip) Accepted) true)
                             (if (and Fin (fx< Count Window)) (receive-fin P Now) true)))
                       (answer-duplicate P Flags Seq N Now))))))

(define receive-opening
  {peer --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  P Flags Seq Ack Win N Mss ->
    (let Phase (state P)
      (cases (and (= Phase listen-state) (= Flags 2) (= N 0))
               (do (peer.recv-next-> P (seq-add Seq 1))
                   (remember-window P Seq Ack Win)
                   (peer.send-mss-> P Mss)
                   (peer.phase-> P syn-received)
                   (queue-control P 18))
             (and (= Phase syn-sent) (= Flags 18) (= N 0) (acknowledge? P Ack))
               (do (peer.recv-next-> P (seq-add Seq 1))
                   (remember-window P Seq Ack Win)
                   (peer.send-mss-> P Mss)
                   (peer.tx-flags-> P 0)
                   (reset-timer P 0 0)
                   (peer.phase-> P established)
                   (peer.ack-needed-> P true)
                   true)
             true false)))

(define terminal?
  {peer --> boolean}
  P -> (let Phase (state P) (or (= Phase closed) (= Phase timed-out) (= Phase reset))))

(define receive-valid
  {peer --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  P B I Count Now ->
    (if (terminal? P) false
        (let Phase (state P)
             Seq (buffer.u32-be B (fx+ I 24))
             Ack (buffer.u32-be B (fx+ I 28))
             Flags (segment-flags B I)
             Win (buffer.u16-be B (fx+ I 34))
             H (fx+ 20 (header-length B I))
             Start (fx+ I H)
             N (fx- Count H)
             Mss (options B (fx+ I 40) Start (peer.mss P))
          (cases (fx< Mss 0) false
                 (or (= Phase listen-state) (= Phase syn-sent))
                   (receive-opening P Flags Seq Ack Win N Mss)
                 (and (= Phase syn-received)
                      (not (and (= Seq (peer.recv-next P)) (flag? Flags 16) (acknowledge? P Ack))))
                   (if (and (= Flags 2) (= (seq-add Seq 1) (peer.recv-next P))
                            (fx>= (peer.tx-due P) 0))
                       (do (peer.tx-due-> P Now) true)
                       false)
                 true (receive-connected P B Start N Flags Seq Ack Win Now)))))

(define receive-segment
  {peer --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  P B I N Now ->
    (and (not (terminal? P))
         (fx>= N 40)
         (addressed-to? B I (peer.local-ip P) (peer.local-port P))
         (= (buffer.u32-be B (fx+ I 12)) (peer.remote-ip P))
         (= (buffer.u16-be B (fx+ I 20)) (peer.remote-port P))
         (valid-segment? B I N)
         (receive-valid P B I N Now)))

(define receive-ready
  {peer --> net-link.ring --> fixnum --> fixnum --> fixnum --> fixnum}
  _ _ _ 0 Done -> Done
  P R Now Budget Done ->
    (if (net-link.ready? R Now)
        (do (receive-segment P (net-link.ring.data R) (net-link.head-offset R) (net-link.head-length R) Now)
            (net-link.consume R)
            (receive-ready P R Now (fx- Budget 1) (fx+ Done 1)))
        Done))

(define drive-output
  {peer --> fixnum --> boolean}
  P Now ->
    (if (terminal? P) false
        (let Sent (flush P Now)
          (do (if (and (= (state P) time-wait) (not (peer.ack-needed P)) (fx>= Now (peer.wait-until P)))
                  (stop-peer P closed)
                  true)
              Sent))))

(define poll
  {peer --> fixnum --> fixnum}
  P Budget ->
    (let Limit (buffer.index Budget)
         D (peer.device P)
         Now (net-link.now D)
         Count (receive-ready P (net-link.device.rx D) Now Limit 0)
      (do (drive-output P Now) Count)))

\\ A slot's token advances by the table capacity on each new occupant. Applications get the
\\ token only after the handshake and retain the lease until they release the terminal connection.
(defstruct listener-slot
  (index : fixnum)
  (peer : peer)
  (mutable token : fixnum)
  (mutable lease : symbol))

(defstruct listener
  (device : net-link.device)
  (ip : fixnum)
  (port : fixnum)
  (capacity : fixnum)
  (slots : (vector listener-slot))
  (mutable next-sequence : fixnum)
  (mutable next-output : fixnum)
  (mutable next-accept : fixnum))

(define initialise-slots
  {(vector listener-slot) --> net-link.device --> fixnum --> fixnum --> fixnum --> fixnum -->
   (vector listener-slot)}
  Slots _ _ _ _ 0 -> Slots
  Slots D IP Port Mss I ->
    (let Slot (:listener-slot
                 index <- I
                 peer <- (new-peer D IP Port 0 0 Mss)
                 token <- I
                 lease <- vacant)
      (do (fxvector-> Slots I Slot)
          (initialise-slots Slots D IP Port Mss (fx- I 1)))))

(define make-listener
  {net-link.device --> fixnum --> fixnum --> fixnum --> fixnum --> listener}
  D IP Port Slots Initial ->
    (let Mss (peer-mss D)
         N (buffer.index Slots)
         _ (if (and (endpoint? IP Port) (fx> Mss 0) (fx> N 0)) true
                 (error "tcp: listener needs a unicast endpoint, positive slots and an MTU of at least 41"))
         _ (if (and (fx>= Initial 0) (fx<= Initial 4294967295)) true
                 (error "tcp: initial sequence must fit unsigned 32 bits"))
      (:listener
        device <- D
        ip <- IP
        port <- Port
        capacity <- N
        slots <- (initialise-slots (vector (fx->number N)) D IP Port Mss N)
        next-sequence <- Initial
        next-output <- 1
        next-accept <- 1)))

(define slot-at
  {listener --> fixnum --> listener-slot}
  L I -> (fx<-vector (listener.slots L) I))

(define next-index
  {listener --> fixnum --> fixnum}
  L I -> (if (= I (listener.capacity L)) 1 (fx+ I 1)))

(define free-slot
  {listener-slot --> boolean}
  S -> (let P (listener-slot.peer S)
         (do (stop-peer P closed)
             (peer.rx-length-> P 0)
             (listener-slot.lease-> S vacant)
             true)))

(define find-peer
  {listener --> fixnum --> fixnum --> fixnum --> fixnum}
  L IP Port I ->
    (if (fx> I (listener.capacity L)) 0
        (let S (slot-at L I) P (listener-slot.peer S)
          (if (and (not (= (listener-slot.lease S) vacant))
                   (= IP (peer.remote-ip P)) (= Port (peer.remote-port P)))
              I
              (find-peer L IP Port (fx+ I 1))))))

(define find-vacant
  {listener --> fixnum --> fixnum}
  L I ->
    (if (fx> I (listener.capacity L)) 0
        (if (= (listener-slot.lease (slot-at L I)) vacant) I (find-vacant L (fx+ I 1)))))

(define admit
  {listener --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  L B I Count IP Port Now ->
    (if (and (= (segment-flags B I) 2) (= Count (fx+ 20 (header-length B I))) (endpoint? IP Port))
        (let Index (find-vacant L 1)
          (if (= Index 0) false
              (let S (slot-at L Index)
                   P (listener-slot.peer S)
                   Token (fx+ (listener-slot.token S) (listener.capacity L))
                   Seq (listener.next-sequence L)
                (do (peer.remote-ip-> P IP)
                    (peer.remote-port-> P Port)
                    (listen P Seq)
                    (if (receive-valid P B I Count Now)
                        (do (listener-slot.token-> S Token)
                            (listener-slot.lease-> S pending)
                            (listener.next-sequence-> L (seq-add Seq 65537))
                            true)
                        (do (free-slot S) false))))))
        false))

(define listener-ingress
  {listener --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  L B I Count Now ->
    (if (and (fx>= Count 40) (addressed-to? B I (listener.ip L) (listener.port L))
             (valid-segment? B I Count))
        (let IP (buffer.u32-be B (fx+ I 12))
             Port (buffer.u16-be B (fx+ I 20))
             Index (find-peer L IP Port 1)
          (if (= Index 0)
              (admit L B I Count IP Port Now)
              (receive-valid (listener-slot.peer (slot-at L Index)) B I Count Now)))
        false))

(define listener-input
  {listener --> net-link.ring --> fixnum --> fixnum --> fixnum --> fixnum}
  _ _ _ 0 Done -> Done
  L R Now Budget Done ->
    (if (net-link.ready? R Now)
        (do (listener-ingress L (net-link.ring.data R) (net-link.head-offset R) (net-link.head-length R) Now)
            (net-link.consume R)
            (listener-input L R Now (fx- Budget 1) (fx+ Done 1)))
        Done))

\\ Only an actual send moves the start of the next sweep, even if repeated polls find the ring full.
(define listener-output
  {listener --> fixnum --> fixnum --> fixnum --> boolean}
  _ _ _ 0 -> true
  L Now I Left ->
    (let S (slot-at L I)
         P (listener-slot.peer S)
         Lease (listener-slot.lease S)
         Next (next-index L I)
      (do (if (and (not (= Lease vacant)) (drive-output P Now)) (listener.next-output-> L Next) L)
          (if (and (= Lease pending) (terminal? P)) (free-slot S) true)
          (listener-output L Now Next (fx- Left 1)))))

(define listener-transmit
  {listener --> fixnum --> boolean}
  L Now -> (listener-output L Now (listener.next-output L) (listener.capacity L)))

(define listener-poll
  {listener --> fixnum --> fixnum}
  L Budget ->
    (let D (listener.device L)
         Now (net-link.now D)
         Count (listener-input L (net-link.device.rx D) Now (buffer.index Budget) 0)
      (do (listener-transmit L Now)
          Count)))

(define accept-ready
  {listener --> fixnum --> fixnum --> fixnum}
  _ _ 0 -> 0
  L I Left ->
    (let S (slot-at L I) Phase (state (listener-slot.peer S))
      (if (and (= (listener-slot.lease S) pending)
               (or (= Phase established) (= Phase close-wait)))
          (do (listener-slot.lease-> S leased)
              (listener.next-accept-> L (next-index L I))
              (listener-slot.token S))
          (accept-ready L (next-index L I) (fx- Left 1)))))

(define accept
  {listener --> fixnum}
  L -> (accept-ready L (listener.next-accept L) (listener.capacity L)))

(define lease-slot
  {listener --> fixnum --> listener-slot}
  L Token ->
    (let N (listener.capacity L)
         Id (buffer.index Token)
         _ (if (fx> Id N) true (error "tcp: invalid connection token"))
         I (fx+ (fxremainder (fx- Id 1) N) 1)
         S (slot-at L I)
      (if (and (= (listener-slot.lease S) leased) (= (listener-slot.token S) Id))
          S
          (error "tcp: stale or unaccepted connection token"))))

(define connection-index
  {listener --> fixnum --> fixnum}
  L Token -> (listener-slot.index (lease-slot L Token)))

(define connection-state
  {listener --> fixnum --> symbol}
  L Token -> (state (listener-slot.peer (lease-slot L Token))))

(define connection-send
  {listener --> fixnum --> buffer.view --> fixnum --> fixnum}
  L Token Payload Count -> (send (listener-slot.peer (lease-slot L Token)) Payload Count))

(define connection-recv-into
  {listener --> fixnum --> buffer.view --> fixnum --> fixnum}
  L Token Out Count -> (recv-into (listener-slot.peer (lease-slot L Token)) Out Count))

(define connection-shutdown-write
  {listener --> fixnum --> boolean}
  L Token -> (shutdown-write (listener-slot.peer (lease-slot L Token))))

(define release
  {listener --> fixnum --> boolean}
  L Token -> (let S (lease-slot L Token)
               (and (terminal? (listener-slot.peer S)) (free-slot S))))

(preclude [peer.%match listener.%match listener-slot.%match])
)
