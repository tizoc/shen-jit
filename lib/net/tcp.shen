\\ Typed TCP over the packet link with preallocated send and receive windows.
(shen.x.namespace tcp
  (use buffer)
  (use net-link)
  (use net-ipv4)
  (use net-ipv6)
  (use shen-jit)
  (use net-wire => wire)
  (import struct defstruct)
  (import layout write-layout defflags flag-bits)
  (shadow listen release)
  (export peer make-peer listen connect state send recv-into shutdown-write poll
          listener make-listener listener-poll accept connection-index connection-state
          listener-ingress listener-transmit make-table table-ingress table-connect accept-on
          listener-deadline connection-readable? connection-writable? connection-abort
          make-table-sized path-mtu path-mtu6 table-ingress6 table-connect6 expire-addresses6
          connection-send connection-send-from connection-recv-into connection-recv-at connection-shutdown-write release
          closed listen-state syn-sent syn-received established close-wait fin-wait-1 fin-wait-2
          closing last-ack time-wait timed-out reset)

\\ RFC 9293's control bits, the most significant first.
(defflags control cwr ece urg ack psh rst syn fin)

(defstruct peer
  (device : net-link.device)
  (local-ip : fixnum)
  (local-ip6 : net-ipv6.address)
  (remote-ip6 : net-ipv6.address)
  (mutable ip-header : fixnum)
  (mutable local-port : fixnum)
  (mutable remote-ip : fixnum)
  (mutable remote-port : fixnum)
  (tx : buffer.view)
  (rx : buffer.view)
  (rx-present : buffer.view)
  (tx-sacked : buffer.view)
  (tx-repaired : buffer.view)
  (mss : fixnum)
  (capacity : fixnum)
  (map-bytes : fixnum)
  (window-scale : fixnum)
  (mutable remote-scale : fixnum)
  (mutable path-mtu : fixnum)
  (mutable aborting : boolean)
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
  (mutable srtt : fixnum)
  (mutable rttvar : fixnum)
  (mutable rtt-sample-at : fixnum)
  (mutable rtt-sample-end : fixnum)
  (mutable rtt-blocked-bytes : fixnum)
  (mutable tx-duplicate-acks : fixnum)
  (mutable tx-fast-retransmit : boolean)
  (mutable sack-enabled : boolean)
  (mutable tx-sack-high : fixnum)
  (mutable sack-loss-end : fixnum)
  (mutable sack-next-repair : fixnum)
  (mutable sack-pipe : fixnum)
  (mutable rx-sack-recent : fixnum)
  (mutable cwnd : fixnum)
  (mutable ssthresh : fixnum)
  (mutable ca-acked : fixnum)
  (mutable recovery-bytes : fixnum)
  (mutable remote-window : fixnum)
  (mutable remote-window-seq : fixnum)
  (mutable remote-window-ack : fixnum)
  (mutable send-mss : fixnum)
  (mutable recv-next : fixnum)
  (mutable rx-start : fixnum)
  (mutable rx-length : fixnum)
  (mutable rx-pending : fixnum)
  (mutable rx-fin : fixnum)
  (mutable recv-eof : boolean)
  (mutable ack-needed : boolean)
  (mutable rx-duplicate-acks : fixnum)
  (mutable wait-until : fixnum))

(define smaller
  {fixnum --> fixnum --> fixnum}
  A B -> (if (fx< A B) A B))

(define larger
  {fixnum --> fixnum --> fixnum}
  A B -> (if (fx> A B) A B))

(define minimum-header
  {peer --> fixnum}
  P -> (fx+ (peer.ip-header P) (wire.tcp.size)))

\\ Both headers' bytes, without options, behind IPv4 and behind IPv6.
(define headers4
  {--> fixnum}
  -> (fx+ (wire.ipv4.size) (wire.tcp.size)))

(define headers6
  {--> fixnum}
  -> (fx+ (wire.ipv6.size) (wire.tcp.size)))

(define transport-checksum
  {buffer.view --> fixnum --> fixnum --> fixnum --> fixnum}
  B I IpBytes N ->
    (if (= IpBytes (wire.ipv4.size)) (net-ipv4.transport-checksum B I 6 N)
        (net-ipv6.transport-checksum B I 6 N)))

(define endpoint?
  {fixnum --> fixnum --> boolean}
  IP Port -> (and (net-ipv4.unicast? IP) (fx>= Port 1) (fx<= Port 65535)))

(define peer-mss
  {net-link.device --> fixnum}
  D -> (smaller 536 (fx- (net-link.mtu D) 40)))

(define scale-for
  {fixnum --> fixnum --> fixnum}
  Capacity Shift ->
    (if (fx<= Capacity 65535) Shift (scale-for (shen-jit.shift-right Capacity 1) (fx+ Shift 1))))

(define new-peer
  {net-link.device --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> peer}
  D LocalIP LocalPort RemoteIP RemotePort Mss Capacity ->
    (let MapBytes (fxquotient (fx+ Capacity 7) 8)
      (:peer
        device <- D
        local-ip <- LocalIP
        local-ip6 <- (net-ipv6.make-address 0 0 0 0)
        remote-ip6 <- (net-ipv6.make-address 0 0 0 0)
        ip-header <- 20
        local-port <- LocalPort
        remote-ip <- RemoteIP
        remote-port <- RemotePort
        tx <- (buffer.new Capacity)
        rx <- (buffer.new Capacity)
        rx-present <- (buffer.new MapBytes)
        tx-sacked <- (buffer.new MapBytes)
        tx-repaired <- (buffer.new MapBytes)
        mss <- Mss
        capacity <- Capacity
        map-bytes <- MapBytes
        window-scale <- (scale-for Capacity 0)
        remote-scale <- -1
        path-mtu <- (net-link.mtu D)
        aborting <- false
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
        srtt <- 0
        rttvar <- 0
        rtt-sample-at <- -1
        rtt-sample-end <- 0
        rtt-blocked-bytes <- 0
        tx-duplicate-acks <- 0
        tx-fast-retransmit <- false
        sack-enabled <- false
        tx-sack-high <- 0
        sack-loss-end <- 0
        sack-next-repair <- -1
        sack-pipe <- 0
        rx-sack-recent <- -1
        cwnd <- 0
        ssthresh <- Capacity
        ca-acked <- 0
        recovery-bytes <- 0
        remote-window <- 0
        remote-window-seq <- 0
        remote-window-ack <- 0
        send-mss <- Mss
        recv-next <- 0
        rx-start <- 0
        rx-length <- 0
        rx-pending <- 0
        rx-fin <- -1
        recv-eof <- false
        ack-needed <- false
        rx-duplicate-acks <- 0
        wait-until <- 0)))

(define make-peer
  {net-link.device --> fixnum --> fixnum --> fixnum --> fixnum --> peer}
  D LocalIP LocalPort RemoteIP RemotePort ->
    (let Mss (peer-mss D)
      (if (and (endpoint? LocalIP LocalPort) (endpoint? RemoteIP RemotePort) (fx> Mss 0))
          (new-peer D LocalIP LocalPort RemoteIP RemotePort Mss (fx* Mss 8))
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

(define clear-presence
  {buffer.view --> fixnum --> boolean}
  _ 0 -> true
  Map N -> (let I (fx- N 1)
             (do (buffer.u8-> Map I 0)
                 (clear-presence Map I))))

(define presence-mask
  {fixnum --> fixnum}
  At -> (shen-jit.shift-left 1 (shen-jit.bit-and At 7)))

(define marked?
  {buffer.view --> fixnum --> boolean}
  Map At -> (flag? (buffer.u8 Map (shen-jit.shift-right At 3)) (presence-mask At)))

(define clear-sack
  {peer --> boolean}
  P -> (if (fx> (peer.tx-sack-high P) 0)
           (do (clear-presence (peer.tx-sacked P) (peer.map-bytes P))
               (peer.tx-sack-high-> P 0)
               true)
           true))

(define sack-recovering?
  {peer --> boolean}
  P -> (and (peer.sack-enabled P) (fx> (peer.recovery-bytes P) 0)))

(define clear-sack-recovery
  {peer --> boolean}
  P -> (do (if (sack-recovering? P) (clear-presence (peer.tx-repaired P) (peer.map-bytes P)) true)
           (peer.sack-loss-end-> P 0)
           (peer.sack-next-repair-> P -1)
           (peer.sack-pipe-> P 0)
           true))

(define clear-duplicate-acks
  {peer --> boolean}
  P -> (do (peer.tx-duplicate-acks-> P 0)
           (peer.tx-fast-retransmit-> P false)
           true))

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
              (peer.srtt-> P 0)
              (peer.rttvar-> P 0)
              (peer.rtt-sample-at-> P -1)
              (peer.rtt-blocked-bytes-> P 0)
              (clear-duplicate-acks P)
              (clear-sack P)
              (clear-sack-recovery P)
              (peer.sack-enabled-> P false)
              (peer.rx-sack-recent-> P -1)
              (peer.cwnd-> P 0)
              (peer.ssthresh-> P (peer.capacity P))
              (peer.ca-acked-> P 0)
              (peer.recovery-bytes-> P 0)
              (peer.remote-window-> P 0)
              (peer.remote-scale-> P -1)
              (peer.path-mtu-> P (net-link.mtu (peer.device P)))
              (peer.aborting-> P false)
              (peer.send-mss-> P (smaller (peer.mss P) (fx- (peer.path-mtu P) (minimum-header P))))
              (peer.recv-next-> P 0)
              (peer.rx-start-> P 0)
              (if (fx> (peer.rx-pending P) 0) (clear-presence (peer.rx-present P) (peer.map-bytes P)) true)
              (peer.rx-pending-> P 0)
              (peer.rx-fin-> P -1)
              (peer.recv-eof-> P false)
              (peer.ack-needed-> P false)
              (peer.rx-duplicate-acks-> P 0)
              (peer.phase-> P Phase)
              true))
        false))

(define queue-control
  {peer --> fixnum --> boolean}
  P Flags ->
    (do (peer.tx-due-> P -1)
        (peer.tx-retries-> P 0)
        (peer.tx-flags-> P Flags)
        true))

(define listen
  {peer --> fixnum --> boolean}
  P Seq -> (begin P Seq listen-state))

(define connect
  {peer --> fixnum --> boolean}
  P Seq -> (and (begin P Seq syn-sent) (queue-control P (flag-bits control syn))))

(define window
  {peer --> fixnum}
  \\ Pending bytes already occupy their own positions inside this sequence interval.
  P -> (fx- (peer.capacity P) (peer.rx-length P)))

(define wrap-offset
  {fixnum --> fixnum --> fixnum}
  At Capacity -> (if (fx>= At Capacity) (fx- At Capacity) At))

(define write-sack-marks
  {buffer.view --> fixnum --> fixnum --> fixnum --> boolean --> boolean}
  _ _ _ 0 _ -> true
  Map At Capacity N Mark ->
    (let I (shen-jit.shift-right At 3)
         Bits (buffer.u8 Map I)
         Mask (presence-mask At)
      (do (if (= (flag? Bits Mask) Mark) Map
              (buffer.u8-> Map I (shen-jit.bit-xor Bits Mask)))
          (write-sack-marks Map (wrap-offset (fx+ At 1) Capacity) Capacity (fx- N 1) Mark))))

(define receive-tail
  {peer --> fixnum}
  P -> (wrap-offset (fx+ (peer.rx-start P) (peer.rx-length P)) (peer.capacity P)))

(define receive-limit
  {peer --> fixnum --> fixnum}
  P Window ->
    (let Final (peer.rx-fin P)
      (if (fx< Final 0) Window (smaller Window (seq-distance Final (peer.recv-next P))))))

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
  P Payload Count -> (send-from P Payload 0 Count))

(define send-from
  {peer --> buffer.view --> fixnum --> fixnum --> fixnum}
  P Payload At Count ->
    (let Limit (buffer.index Count)
         _ (buffer.range (buffer.length Payload) At Limit)
         Phase (state P)
         Capacity (peer.capacity P)
         Length (peer.tx-length P)
         N (smaller Limit (fx- Capacity Length))
      (if (and (or (= Phase established) (= Phase close-wait)) (fx> N 0))
          (let Tail (wrap-offset (fx+ (peer.tx-head P) Length) Capacity)
            (do (copy-into-ring (peer.tx P) Tail Capacity Payload At N)
                (peer.tx-length-> P (fx+ Length N))
                N))
          0)))

(define recv-into
  {peer --> buffer.view --> fixnum --> fixnum}
  P Out Count -> (recv-at P Out 0 Count))

(define recv-at
  {peer --> buffer.view --> fixnum --> fixnum --> fixnum}
  P Out At Count ->
    (let Limit (buffer.index Count)
         _ (buffer.range (buffer.length Out) At Limit)
         N (smaller Limit (peer.rx-length P))
      (cases (fx> N 0)
               (let Left (fx- (peer.rx-length P) N)
                 (do (copy-from-ring Out At (peer.rx P) (peer.rx-start P) (peer.capacity P) N)
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
          (do (queue-control P (flag-bits control fin ack))
              (peer.phase-> P (if (= Phase established) fin-wait-1 last-ack))
              true)
          false)))

(define receive-marked?
  {peer --> fixnum --> fixnum --> boolean}
  P Tail Offset -> (marked? (peer.rx-present P) (wrap-offset (fx+ Tail Offset) (peer.capacity P))))

(define sack-run-start
  {peer --> fixnum --> fixnum --> fixnum}
  P Tail I ->
    (if (and (fx> I 0) (receive-marked? P Tail (fx- I 1)))
        (sack-run-start P Tail (fx- I 1)) I))

(define sack-run-end
  {peer --> fixnum --> fixnum --> fixnum --> fixnum}
  P Tail I Limit ->
    (if (and (fx< I Limit) (receive-marked? P Tail I))
        (sack-run-end P Tail (fx+ I 1) Limit) I))

(define write-sack-block
  {peer --> buffer.view --> fixnum --> fixnum --> fixnum --> buffer.view}
  P B At Left Right ->
    (let Next (peer.recv-next P)
      (do (buffer.u32-be-> B At (seq-add Next Left))
          (buffer.u32-be-> B (fx+ At 4) (seq-add Next Right)))))

(define write-sack-runs
  {peer --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum}
  P B At Tail I Limit Skip Used Max ->
    (cases (or (fx>= I Limit) (= Used Max)) Used
           (not (receive-marked? P Tail I))
             (write-sack-runs P B At Tail (fx+ I 1) Limit Skip Used Max)
           true
             (let End (sack-run-end P Tail (fx+ I 1) Limit)
               (if (= I Skip) (write-sack-runs P B At Tail End Limit Skip Used Max)
                   (do (write-sack-block P B (fx+ At (fx* Used 8)) I End)
                       (write-sack-runs P B At Tail End Limit Skip (fx+ Used 1) Max))))))

(define write-sack
  {peer --> buffer.view --> fixnum --> fixnum}
  P B At ->
    (let Tail (receive-tail P)
         Limit (receive-limit P (window P))
         Max (smaller 4 (fxquotient (fx- (peer.path-mtu P) (fx+ (minimum-header P) 4)) 8))
         Recent (seq-distance (peer.rx-sack-recent P) (peer.recv-next P))
         First (if (and (fx>= (peer.rx-sack-recent P) 0)
                        (fx< Recent Limit) (receive-marked? P Tail Recent))
                   (sack-run-start P Tail Recent) (type -1 fixnum))
         Blocks (fx+ At 4)
         Used (if (fx>= First 0)
                  (do (write-sack-block P B Blocks First (sack-run-end P Tail (fx+ First 1) Limit))
                      (type 1 fixnum))
                  (type 0 fixnum))
         N (write-sack-runs P B Blocks Tail 0 Limit First Used Max)
         Size (fx* N 8)
      (if (= N 0) 0
          (do (buffer.u16-be-> B At 257) \\ Two NOPs align the block edges.
              (buffer.u16-be-> B (fx+ At 2) (fx+ 1282 Size))
              (fx+ Size 4)))))

(define wants-sack?
  {peer --> boolean}
  P -> (and (peer.sack-enabled P) (fx> (peer.rx-pending P) 0) (not (peer.recv-eof P))))

(define sack-capable?
  {peer --> boolean}
  P -> (fx>= (peer.path-mtu P) (fx+ (minimum-header P) 12)))

(define write-syn-options
  {peer --> buffer.view --> fixnum --> fixnum --> fixnum}
  P B At Flags ->
    (let Sack (and (sack-capable? P) (or (= Flags (flag-bits control syn)) (peer.sack-enabled P)))
         Scale (and (sack-capable? P)
                    (if (= Flags (flag-bits control syn)) (fx> (peer.window-scale P) 0)
                        (fx>= (peer.remote-scale P) 0)))
         N (if Sack (let _ (buffer.u32-be-> B At 67239936) (type 4 fixnum)) (type 0 fixnum))
         M (fx+ At N)
      (if (fx>= (peer.path-mtu P) (fx+ (minimum-header P) 4))
          (do (buffer.u16-be-> B M 516)
              (buffer.u16-be-> B (fx+ M 2) (smaller (peer.capacity P) (fx- (peer.path-mtu P) (minimum-header P))))
              \\ The padding after SACK-Permitted must stay traversable.
              (if Sack (buffer.u16-be-> B (fx+ At 2) 257) B)
              (if Scale
                  (let Pos (fx+ M 4)
                    (do (buffer.u32-be-> B Pos (fx+ 50528256 (fx* (peer.window-scale P) 256)))
                        (fx+ N 8)))
                  (fx+ N 4)))
          N)))

(define write-options
  {peer --> buffer.view --> fixnum --> fixnum --> fixnum}
  P B I Flags ->
    (cases (flag? Flags (flag-bits control syn)) (write-syn-options P B (fx+ I 20) Flags)
           (and (= Flags (flag-bits control ack)) (wants-sack? P)) (write-sack P B (fx+ I 20))
           true 0))

(define advertised-window
  {peer --> fixnum --> fixnum}
  P Flags ->
    (let Space (window P)
         Shift (if (or (flag? Flags (flag-bits control syn)) (fx< (peer.remote-scale P) 0))
                   (type 0 fixnum) (peer.window-scale P))
      (smaller 65535 (shen-jit.shift-right Space Shift))))

(define write-segment
  {peer --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> buffer.view}
  P B T Flags Seq At Count Options ->
    (let Header (fx+ (wire.tcp.size) Options)
      (do (write-layout wire.tcp B T
            (source-port (peer.local-port P)) (destination-port (peer.remote-port P))
            (sequence Seq)
            (acknowledgement (if (flag? Flags (flag-bits control ack)) (peer.recv-next P) 0))
            (data-offset (shen-jit.shift-right Header 2)) (flags Flags) (window (advertised-window P Flags)))
          (if (= Count 0) B
              (copy-from-ring B (fx+ T Header) (peer.tx P) At (peer.capacity P) Count)))))

(define emit-segment
  {peer --> net-link.ring --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  P R Now Flags Seq At Count ->
    (let Delivery (net-link.delivery (peer.device P) Now)
         B (net-link.ring.data R)
         I (net-link.tail-offset R)
         IpBytes (peer.ip-header P)
         T (fx+ I IpBytes)
         Options (write-options P B T Flags)
         TcpBytes (fx+ (fx+ Count (wire.tcp.size)) Options)
         Size (fx+ TcpBytes IpBytes)
      (do (if (= IpBytes (wire.ipv4.size))
                (net-ipv4.write-header B I Size 6 (peer.local-ip P) (peer.remote-ip P))
                (net-ipv6.write-header B I Size 6 64 (peer.local-ip6 P) (peer.remote-ip6 P)))
          (write-segment P B T Flags Seq At Count Options)
          (wire.tcp.checksum-> B T (transport-checksum B I IpBytes TcpBytes))
          (net-link.publish R Size Delivery)
          (if (and (flag? Flags (flag-bits control ack)) (or (= Flags (flag-bits control ack)) (not (wants-sack? P))))
              (peer.ack-needed-> P false) P)
          true)))

(define emit-ack
  {peer --> net-link.ring --> fixnum --> boolean}
  P R Now ->
    (let Pending (peer.rx-duplicate-acks P)
      (do (if (and (not (peer.ack-needed P)) (fx> Pending 0))
              (peer.rx-duplicate-acks-> P (fx- Pending 1)) P)
          (emit-segment P R Now 16 (peer.send-next P) 0 0))))

(define stop-peer
  {peer --> symbol --> boolean}
  P Phase -> (do (peer.phase-> P Phase)
                 (peer.tx-flags-> P 0)
                 (peer.tx-length-> P 0)
                 (peer.tx-flight-> P 0)
                 (peer.tx-replay-> P -1)
                 (peer.tx-due-> P -1)
                 (peer.rtt-sample-at-> P -1)
                 (clear-duplicate-acks P)
                 (clear-sack-recovery P)
                 (peer.recovery-bytes-> P 0)
                 (peer.ack-needed-> P false)
                 (peer.rx-duplicate-acks-> P 0)
                 true))

(define backoff
  {peer --> fixnum --> boolean}
  P Now ->
    (let Rto (smaller 60000 (fx* 2 (peer.tx-rto P)))
      (do (peer.tx-rto-> P Rto)
          (peer.tx-due-> P (fx+ Now Rto))
          (peer.tx-retries-> P (fx+ (peer.tx-retries P) 1))
          true)))

(define start-rtt-sample
  {peer --> fixnum --> fixnum --> boolean}
  P Now End ->
    (if (and (fx< (peer.rtt-sample-at P) 0) (= (peer.rtt-blocked-bytes P) 0))
        (do (peer.rtt-sample-end-> P End)
            (peer.rtt-sample-at-> P Now)
            true)
        false))

(define send-control
  {peer --> net-link.ring --> fixnum --> boolean}
  P R Now ->
    (let Flags (peer.tx-flags P)
         First (fx< (peer.tx-due P) 0)
         Next (peer.send-next P)
      (do (emit-segment P R Now Flags (if First Next (seq-add Next -1)) 0 0)
          (if First
              (let End (seq-add Next 1)
                (do (peer.send-next-> P End)
                    (peer.tx-due-> P (fx+ Now (peer.tx-rto P)))
                    (if (flag? Flags (flag-bits control syn)) (start-rtt-sample P Now End) true)
                    true))
              (do (peer.rtt-sample-at-> P -1)
                  (backoff P Now))))))

\\ Queued bytes are split into an in-flight prefix and a never-sent suffix.
\\ Replay uses offsets within that prefix relative to tx-head.
(define emit-data
  {peer --> net-link.ring --> fixnum --> fixnum --> fixnum --> boolean}
  P R Now Offset Count ->
    (let Seq (seq-add (peer.send-next P) (fx- Offset (peer.tx-flight P)))
         At (wrap-offset (fx+ (peer.tx-head P) Offset) (peer.capacity P))
      (emit-segment P R Now 24 Seq At Count)))

\\ A cumulative ACK across a retransmitted flight cannot give a clean sample.
(define retransmit-data
  {peer --> net-link.ring --> fixnum --> fixnum --> fixnum --> boolean}
  P R Now Offset Count ->
    (do (peer.rtt-sample-at-> P -1)
        (peer.rtt-blocked-bytes-> P (peer.tx-flight P))
        (emit-data P R Now Offset Count)))

(define loss-threshold
  {peer --> fixnum --> fixnum}
  P Flight -> (larger (fx* (peer.send-mss P) 2) (fxquotient Flight 2)))

(define congestion-timeout
  {peer --> fixnum --> boolean}
  P Flight ->
    (do (if (= (peer.tx-retries P) 0) (peer.ssthresh-> P (loss-threshold P Flight)) P)
        (peer.cwnd-> P (peer.send-mss P))
        (peer.ca-acked-> P 0)
        (peer.recovery-bytes-> P 0)
        true))

(define congestion-fast-loss
  {peer --> fixnum --> boolean}
  P Flight ->
    (if (= (peer.recovery-bytes P) 0)
        (let Threshold (loss-threshold P Flight)
          (do (peer.ssthresh-> P Threshold)
              (peer.cwnd-> P (smaller (peer.cwnd P) Threshold))
              (peer.ca-acked-> P 0)
              (peer.recovery-bytes-> P Flight)
              true))
        true))

(define replay-data
  {peer --> net-link.ring --> fixnum --> fixnum --> fixnum --> boolean --> boolean}
  P R Now Offset End Retry ->
    \\ The replay cursor tracks the retransmitted prefix still awaiting an ACK.
    (let Limit (smaller End (peer.cwnd P))
         N (smaller (peer.send-mss P) (fx- Limit Offset))
         Next (fx+ Offset N)
      (do (retransmit-data P R Now Offset N)
          (peer.tx-replay-> P (if (fx< Next (peer.tx-flight P)) Next -1))
          (if Retry
              (do (peer.tx-fast-retransmit-> P false)
                  (peer.tx-duplicate-acks-> P 3)
                  (backoff P Now))
              true))))

(define send-new-data
  {peer --> net-link.ring --> fixnum --> fixnum --> fixnum --> boolean}
  P R Now Flight N ->
    (let End (seq-add (peer.send-next P) N)
      (do (emit-data P R Now Flight N)
          (peer.tx-flight-> P (fx+ Flight N))
          (peer.send-next-> P End)
          (if (sack-recovering? P) (peer.sack-pipe-> P (fx+ (peer.sack-pipe P) N)) P)
          (if (fx> (peer.remote-window P) 0) (start-rtt-sample P Now End) false)
          (if (= Flight 0) (peer.tx-due-> P (fx+ Now (peer.tx-rto P))) P)
          true)))

(define send-ring-offset
  {peer --> fixnum --> fixnum}
  P I -> (wrap-offset (fx+ (peer.tx-head P) I) (peer.capacity P)))

(define sacked?
  {peer --> fixnum --> boolean}
  P I -> (marked? (peer.tx-sacked P) (send-ring-offset P I)))

(define repaired?
  {peer --> fixnum --> boolean}
  P I -> (marked? (peer.tx-repaired P) (send-ring-offset P I)))

\\ Walk back from the highest SACK. Evidence only increases to the left.
(define sack-loss-frontier
  {peer --> fixnum --> fixnum --> fixnum --> boolean --> fixnum}
  P I Bytes Runs InRun ->
    (cases (fx< I 0) 0
           (sacked? P I) (sack-loss-frontier P (fx- I 1) (fx+ Bytes 1)
                                             (if InRun Runs (fx+ Runs 1)) true)
           (or (fx>= Runs 3) (fx> Bytes (fx* (peer.send-mss P) 2))) (fx+ I 1)
           true (sack-loss-frontier P (fx- I 1) Bytes Runs false)))

\\ Count unsacked originals not inferred lost, plus unacknowledged repairs.
(define measure-sack-pipe
  {peer --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum}
  P I Flight LostEnd Count ->
    (if (= I Flight) Count
        (let Next (if (sacked? P I) Count
                      (fx+ (if (fx>= I LostEnd) (fx+ Count 1) Count)
                           (if (repaired? P I) 1 0)))
          (measure-sack-pipe P (fx+ I 1) Flight LostEnd Next))))

(define find-sack-repair
  {peer --> fixnum --> fixnum --> fixnum}
  P I End ->
    (cases (fx>= I End) -1
           (or (sacked? P I) (repaired? P I)) (find-sack-repair P (fx+ I 1) End)
           true I))

(define refresh-sack-recovery
  {peer --> boolean}
  P ->
    (let LostEnd (sack-loss-frontier P (fx- (peer.tx-sack-high P) 1) 0 0 false)
      (do (peer.sack-loss-end-> P LostEnd)
          (peer.sack-next-repair-> P (find-sack-repair P 0 LostEnd))
          (peer.sack-pipe-> P (measure-sack-pipe P 0 (peer.tx-flight P) LostEnd 0))
          true)))

(define mark-repair
  {peer --> fixnum --> fixnum --> boolean}
  P Offset Count ->
    (write-sack-marks (peer.tx-repaired P) (send-ring-offset P Offset) (peer.capacity P) Count true))

(define sack-hole-end
  {peer --> fixnum --> fixnum --> fixnum}
  P I Limit ->
    (if (or (fx>= I Limit) (sacked? P I) (repaired? P I))
        I (sack-hole-end P (fx+ I 1) Limit)))

(define fast-retry-length
  {peer --> fixnum --> fixnum}
  P End ->
    (let Limit (smaller (peer.send-mss P) End)
      \\ Always retry the cumulative gap, even if the peer reneged on that byte.
      (if (fx> (peer.tx-sack-high P) 0) (sack-hole-end P 1 Limit) Limit)))

(define fast-retransmit
  {peer --> net-link.ring --> fixnum --> fixnum --> fixnum --> boolean}
  P R Now Flight End ->
    (let Count (fast-retry-length P End)
      (do (congestion-fast-loss P Flight)
          (retransmit-data P R Now 0 Count)
          (peer.tx-fast-retransmit-> P false)
          (if (sack-recovering? P)
              (do (mark-repair P 0 Count) (refresh-sack-recovery P))
              true))))

(define send-sack-repair
  {peer --> net-link.ring --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  P R Now Offset End Credit ->
    (let LostEnd (peer.sack-loss-end P)
         Limit (smaller (smaller End LostEnd)
                        (fx+ Offset (smaller Credit (peer.send-mss P))))
         Next (sack-hole-end P (fx+ Offset 1) Limit)
         Count (fx- Next Offset)
      (do (retransmit-data P R Now Offset Count)
          (mark-repair P Offset Count)
          (peer.sack-next-repair-> P (find-sack-repair P Next LostEnd))
          (peer.sack-pipe-> P (fx+ (peer.sack-pipe P) Count))
          true)))

(define flush-data
  {peer --> net-link.ring --> fixnum --> boolean --> boolean}
  P R Now Expired ->
    (let Flight (peer.tx-flight P)
         Replay (peer.tx-replay P)
         Window (peer.remote-window P)
         End (smaller Flight (if (= Window 0) 1 Window))
         Repair (peer.sack-next-repair P)
         Pipe (peer.sack-pipe P)
         Credit (fx- (peer.cwnd P) Pipe)
         FastEnd (if (sack-recovering? P) (smaller End Credit) End)
         Available (if (and (= Window 0) (= Flight 0)) (type 1 fixnum)
                       (fx- (smaller Window (peer.cwnd P)) (larger Flight Pipe)))
         N (smaller (fx- (peer.tx-length P) Flight) (smaller (peer.send-mss P) Available))
      (cases (and Expired (fx> End 0))
               (do (clear-sack P)
                   (clear-sack-recovery P)
                   (if (fx> Window 0) (congestion-timeout P Flight)
                       (do (peer.recovery-bytes-> P 0) true))
                   (replay-data P R Now 0 End true))
             (and (fx>= Replay 0) (fx< Replay (smaller End (peer.cwnd P))))
               (replay-data P R Now Replay End false)
             (and (peer.tx-fast-retransmit P) (fx> FastEnd 0) (fx> Window 0))
               (fast-retransmit P R Now Flight FastEnd)
             (and (fx>= Repair 0) (fx< Repair End) (fx> Window 0) (fx> Credit 0))
               (send-sack-repair P R Now Repair End Credit)
             (and (fx> (peer.rx-duplicate-acks P) 0) (not (peer.ack-needed P))) (emit-ack P R Now)
             (and (peer.ack-needed P) (wants-sack? P)) (emit-ack P R Now)
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
             (peer.aborting P) (do (emit-segment P R Now 20 (peer.send-next P) 0 0)
                                   (peer.aborting-> P false)
                                   (stop-peer P reset))
             (and Control (or (fx< Due 0) Expired)) (send-control P R Now)
             true (or (and (not Control) (flush-data P R Now Expired))
                      (and (or (peer.ack-needed P) (fx> (peer.rx-duplicate-acks P) 0))
                           (emit-ack P R Now))))))

(define header-length
  {buffer.view --> fixnum --> fixnum}
  B I -> (fx* 4 (wire.tcp.data-offset B I)))

\\ Read MSS and validate option boundaries before any other option reads.
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
                                (and (= Kind 4) (not (= N 2))) -1
                                (and (= Kind 3) (not (= N 3))) -1
                                (not (= Kind 2)) (options B (fx+ I N) End Mss)
                                (not (= N 4)) -1
                                true (let Advertised (buffer.u16-be B (fx+ I 2))
                                       (if (= Advertised 0) -1
                                           (options B (fx+ I N) End (smaller Mss Advertised))))))))))

(define option-offset
  {buffer.view --> fixnum --> fixnum --> fixnum --> fixnum}
  B I End Wanted ->
    (if (= I End) -1
        (let Kind (buffer.u8 B I)
          (cases (= Kind 0) -1
                 (= Kind Wanted) I
                 (= Kind 1) (option-offset B (fx+ I 1) End Wanted)
                 true (option-offset B (fx+ I (buffer.u8 B (fx+ I 1))) End Wanted)))))

(define valid-segment?
  {buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  B I N IpBytes ->
    (let T (fx+ I IpBytes)
         Count (fx- N IpBytes)
      (and (fx>= Count (wire.tcp.size))
           (if (= IpBytes (wire.ipv4.size)) (net-ipv4.valid? B I N 6)
               (and (net-ipv6.valid-header? B I N) (= (wire.ipv6.next-header B I) 6)))
           (= (wire.tcp.reserved B T) 0)
           (fx>= (header-length B T) (wire.tcp.size))
           (fx<= (header-length B T) Count)
           (not (flag? (wire.tcp.flags B T) (flag-bits control urg)))                     \\ URG is refused.
           (= (transport-checksum B I IpBytes Count) 0))))

(define addressed-to?
  {buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  B I IP Port -> (and (= (wire.ipv4.destination B I) IP)
                       (= (wire.tcp.destination-port B (fx+ I (wire.ipv4.size))) Port)))

\\ ECN is declined by leaving the negotiation bits clear in replies.
(define segment-flags
  {buffer.view --> fixnum --> fixnum}
  B I -> (shen-jit.bit-and (wire.tcp.flags B I) (flag-bits control ack psh rst syn fin)))

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

\\ SRTT and RTTVAR are fixed point in eighths of a millisecond. The
\\ variance uses the old smoothed RTT. Quantize the timer upward to milliseconds.
(define record-rtt
  {peer --> fixnum --> boolean}
  P Ms ->
    (let Sample (fx* (larger 1 (smaller 60000 Ms)) 8)
         Previous (peer.srtt P)
         Delta (fx- Previous Sample)
         Error (larger Delta (fx- 0 Delta))
         Variation (if (= Previous 0) (fxquotient Sample 2)
                       (fxquotient (fx+ (fx* (peer.rttvar P) 3) Error) 4))
         Smoothed (if (= Previous 0) Sample (fxquotient (fx+ (fx* Previous 7) Sample) 8))
         Rto (fxquotient (fx+ (fx+ Smoothed (larger 8 (fx* Variation 4))) 7) 8)
      (do (peer.srtt-> P Smoothed)
          (peer.rttvar-> P Variation)
          (peer.tx-rto-> P (larger 1000 (smaller 60000 Rto)))
          true)))

(define take-rtt-sample
  {peer --> fixnum --> boolean}
  P Now ->
    (let At (peer.rtt-sample-at P)
      (if (fx>= At 0)
          (do (peer.rtt-sample-at-> P -1)
              (record-rtt P (fx- Now At)))
          false)))

(define restart-timer
  {peer --> fixnum --> fixnum --> boolean}
  P Flight Now ->
    (do (peer.tx-due-> P (if (= Flight 0) -1 (fx+ Now (peer.tx-rto P))))
        (peer.tx-retries-> P 0)
        true))

(define finish-syn
  {peer --> fixnum --> boolean}
  P Now ->
    (let Retried (fx> (peer.tx-retries P) 0)
      (do (peer.cwnd-> P (fx* (peer.send-mss P) (if Retried 1 4)))
          (if Retried (do (peer.tx-rto-> P 3000) true) (take-rtt-sample P Now))
          (restart-timer P 0 Now))))

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
              (if (= Phase syn-received) (finish-syn P Now) (restart-timer P 0 Now))
              (cases (= Phase syn-received) (do (peer.phase-> P established) true)
                     (= Phase fin-wait-1) (do (peer.phase-> P fin-wait-2) true)
                     (= Phase closing) (enter-time-wait P Now)
                     (= Phase last-ack) (stop-peer P closed)
                     true true)))
        false))

(define congestion-ack
  {peer --> fixnum --> boolean}
  P N ->
    (let Cwnd (peer.cwnd P)
         Threshold (peer.ssthresh P)
         Capacity (peer.capacity P)
         Mss (peer.send-mss P)
         Recovery (peer.recovery-bytes P)
      (cases (fx> Recovery 0)
               (do (if (fx>= N Recovery) (clear-sack-recovery P) true)
                   (peer.recovery-bytes-> P (larger 0 (fx- Recovery N)))
                   true)
             (= Cwnd Capacity) true
             (fx< Cwnd Threshold)
               (do (peer.cwnd-> P (smaller Threshold (fx+ Cwnd (smaller N Mss)))) true)
             true
               (let Credit (fx+ (peer.ca-acked P) N)
                 (if (fx>= Credit Cwnd)
                     (do (peer.cwnd-> P (smaller Capacity (fx+ Cwnd Mss)))
                         (peer.ca-acked-> P (fx- Credit Cwnd))
                         true)
                     (do (peer.ca-acked-> P Credit) true))))))

(define retire-sack
  {peer --> fixnum --> boolean}
  P N ->
    (let High (peer.tx-sack-high P)
      (cases (= High 0) true
             (fx>= N High) (clear-sack P)
             true (do (write-sack-marks (peer.tx-sacked P) (peer.tx-head P) (peer.capacity P) N false)
                      (peer.tx-sack-high-> P (fx- High N))
                      true))))

(define advance-ack
  {peer --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  P Ack N Flight Now ->
    (let Left (fx- Flight N)
         Replay (peer.tx-replay P)
         At (fx- Replay N)
         SampleEnd (peer.rtt-sample-end P)
         Blocked (peer.rtt-blocked-bytes P)
      (do (if (or (= Ack SampleEnd) (seq-after? Ack SampleEnd)) (take-rtt-sample P Now) false)
          (if (fx> Blocked 0) (peer.rtt-blocked-bytes-> P (larger 0 (fx- Blocked N))) P)
          (retire-sack P N)
          (if (and (sack-recovering? P) (fx< N (peer.recovery-bytes P)))
              (write-sack-marks (peer.tx-repaired P) (peer.tx-head P) (peer.capacity P) N false)
              true)
          (peer.tx-head-> P (wrap-offset (fx+ (peer.tx-head P) N) (peer.capacity P)))
          (peer.tx-length-> P (fx- (peer.tx-length P) N))
          (peer.tx-flight-> P Left)
          (peer.tx-replay-> P (cases (or (= Left 0) (fx< Replay 0)) -1 (fx< At 0) 0 true At))
          (congestion-ack P N)
          (clear-duplicate-acks P)
          (restart-timer P Left Now))))

(define count-duplicate-ack
  {peer --> boolean}
  P ->
    (let Count (peer.tx-duplicate-acks P)
      (if (fx< Count 3)
          (let Next (fx+ Count 1)
            (do (peer.tx-duplicate-acks-> P Next)
                (peer.tx-fast-retransmit-> P (= Next 3))
                true))
          false)))

(define send-una
  {peer --> fixnum}
  P -> (seq-add (peer.send-next P) (fx- 0 (peer.tx-flight P))))

(define queue-sack-head-repair
  {peer --> boolean}
  P -> (do (peer.tx-duplicate-acks-> P 3)
           (peer.tx-fast-retransmit-> P (not (repaired? P 0)))
           true))

(define acknowledge-data
  {peer --> fixnum --> fixnum --> fixnum --> fixnum --> boolean --> boolean}
  P Seq Ack Window Now PureAck ->
    (let Flight (peer.tx-flight P)
         Una (send-una P)
         N (seq-distance Ack Una)
         OldWindow (peer.remote-window P)
      (if (fx<= N Flight)
          (do (update-window P Seq Ack Window)
              (cases (fx> N 0) (advance-ack P Ack N Flight Now)
                     (and (fx> Flight 0) (= OldWindow 0) (fx> (peer.remote-window P) 0))
                       (if (sack-recovering? P) (queue-sack-head-repair P)
                           (do (peer.tx-replay-> P 0) true))
                     (and PureAck (fx> Flight 0) (fx> Window 0) (= Window OldWindow)
                          (fx< (peer.tx-replay P) 0)) (count-duplicate-ack P)
                     (fx< (peer.tx-duplicate-acks P) 3) (clear-duplicate-acks P)
                     (= (peer.remote-window P) 0) (do (peer.tx-fast-retransmit-> P false) true)
                     true true))
          false)))

(define acknowledge
  {peer --> fixnum --> fixnum --> fixnum --> fixnum --> boolean --> boolean}
  P Seq Ack Window Now PureAck ->
    (if (= (peer.tx-flags P) 0)
        (acknowledge-data P Seq Ack Window Now PureAck)
        (acknowledge-control P Seq Ack Window Now)))

(define read-sack-blocks
  {peer --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  _ _ I I _ -> true
  P B I End Una ->
    (let Left (seq-distance (buffer.u32-be B I) Una)
         Right (seq-distance (buffer.u32-be B (fx+ I 4)) Una)
         Capacity (peer.capacity P)
      (do (if (and (fx> Left 0) (fx< Left Right) (fx<= Right (peer.tx-flight P)))
              (do (write-sack-marks (peer.tx-sacked P) (wrap-offset (fx+ (peer.tx-head P) Left) Capacity)
                                    Capacity (fx- Right Left) true)
                  (peer.tx-sack-high-> P (larger (peer.tx-sack-high P) Right))
                  true)
              false)
          (read-sack-blocks P B (fx+ I 8) End Una))))

(define accept-sack
  {peer --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  P B Options End Ack Previous ->
    (if (and (peer.sack-enabled P) (= Ack (send-una P)) (fx> (peer.tx-flight P) 0))
        (let At (option-offset B Options End 5)
             _ (if (fx>= At 0)
                   (let Size (buffer.u8 B (fx+ At 1))
                     (if (and (fx>= Size 10) (fx<= Size 34) (= (fxremainder (fx- Size 2) 8) 0))
                         (read-sack-blocks P B (fx+ At 2) (fx+ At Size) Ack)
                         false))
                   false)
          (if (sack-recovering? P)
              (do (if (or (repaired? P 0) (and (seq-after? Ack Previous) (fx> (peer.tx-sack-high P) 0)))
                      (queue-sack-head-repair P) true)
                  (refresh-sack-recovery P))
              false))
        false))

\\ Store the first byte received at each position and count only newly marked bytes.
(define store-missing
  {buffer.view --> buffer.view --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum}
  _ _ _ _ _ _ 0 Added -> Added
  Rx Map B Start At Capacity N Added ->
    (let I (shen-jit.shift-right At 3)
         Bits (buffer.u8 Map I)
         Mask (presence-mask At)
         Next (wrap-offset (fx+ At 1) Capacity)
         Fresh (= (shen-jit.bit-and Bits Mask) 0)
      (do (if Fresh
              (do (buffer.u8-> Rx At (buffer.u8 B Start))
                  (buffer.u8-> Map I (shen-jit.bit-or Bits Mask)))
              Rx)
          (store-missing Rx Map B (fx+ Start 1) Next Capacity (fx- N 1)
                         (if Fresh (fx+ Added 1) Added)))))

\\ Contiguous bytes are already at the end of the readable data in the same ring.
(define promote-contiguous
  {buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum}
  _ _ _ 0 Count -> Count
  Map At Capacity Limit Count ->
    (let I (shen-jit.shift-right At 3)
         Bits (buffer.u8 Map I)
         Mask (presence-mask At)
      (if (= (shen-jit.bit-and Bits Mask) 0) Count
          (do (buffer.u8-> Map I (shen-jit.bit-xor Bits Mask))
              (promote-contiguous Map (wrap-offset (fx+ At 1) Capacity) Capacity
                                  (fx- Limit 1) (fx+ Count 1))))))

(define advance-receive
  {peer --> fixnum --> boolean}
  P N -> (do (peer.rx-length-> P (fx+ (peer.rx-length P) N))
             (peer.recv-next-> P (seq-add (peer.recv-next P) N))
             (peer.rx-duplicate-acks-> P 0)
             true))

(define receive-bytes
  {peer --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  P B Start Offset N Limit ->
    (let Rx (peer.rx P)
         Capacity (peer.capacity P)
         Tail (receive-tail P)
         Pending (peer.rx-pending P)
      (if (and (= Offset 0) (= Pending 0))
          (do (copy-into-ring Rx Tail Capacity B Start N)
              (advance-receive P N))
          (let Map (peer.rx-present P)
               At (wrap-offset (fx+ Tail Offset) Capacity)
               Added (store-missing Rx Map B Start At Capacity N 0)
            (if (= Offset 0)
                (let Ready (promote-contiguous Map Tail Capacity Limit 0)
                  (do (peer.rx-pending-> P (fx- (fx+ Pending Added) Ready))
                      (advance-receive P Ready)))
                (do (peer.rx-pending-> P (fx+ Pending Added)) true))))))

(define receive-fin
  {peer --> fixnum --> boolean}
  P Now ->
    (let Phase (state P)
      (do (peer.recv-eof-> P true)
          (peer.rx-fin-> P -1)
          (peer.recv-next-> P (seq-add (peer.recv-next P) 1))
          (peer.ack-needed-> P true)
          (peer.rx-duplicate-acks-> P 0)
          (cases (= Phase established) (do (peer.phase-> P close-wait) true)
                 (= Phase fin-wait-1) (do (peer.phase-> P closing) true)
                 (= Phase fin-wait-2) (enter-time-wait P Now)
                 true true))))

(define receive-text
  {peer --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean --> fixnum --> fixnum --> boolean}
  P B Start Offset N Fin Window Now ->
    (let End (fx+ Offset N)
         Next (peer.recv-next P)
         _ (if (and Fin (fx< End Window) (fx< (peer.rx-fin P) 0))
               (peer.rx-fin-> P (seq-add Next End)) P)
         Final (peer.rx-fin P)
         Limit (receive-limit P Window)
         Count (smaller N (fx- Limit Offset))
      \\ Keep up to three gap ACKs across polls even when several segments arrive together.
      (do (if (= Offset 0) (peer.ack-needed-> P true)
              (peer.rx-duplicate-acks-> P (smaller 3 (fx+ (peer.rx-duplicate-acks P) 1))))
          (if (fx> Count 0)
              (do (receive-bytes P B Start Offset Count Limit)
                  (if (and (fx> Offset 0) (peer.sack-enabled P))
                      (peer.rx-sack-recent-> P (seq-add Next Offset)) P)
                  true)
              true)
          (if (= Final (peer.recv-next P)) (receive-fin P Now) true))))

(define answer-duplicate
  {peer --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  P Flags Seq N Now ->
    (if (or (fx> N 0) (flag? Flags (flag-bits control syn fin)))
        (do (peer.ack-needed-> P true)
            (if (and (= (state P) time-wait) (flag? Flags (flag-bits control fin))
                     (= (seq-add Seq (fx+ N 1)) (peer.recv-next P)))
                (enter-time-wait P Now)
                true))
        false))

(define receive-connected
  {peer --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  P B Options Start N Flags Seq Ack Win Now ->
    (let Next (peer.recv-next P)
         Previous (send-una P)
         Window (window P)
         Ahead (seq-distance Seq Next)
         Skip (seq-distance Next Seq)
         Fin (flag? Flags (flag-bits control fin))
         Span (if Fin (fx+ N 1) N)
         Overlap (fx< Skip Span)
         Acceptable (or (= Ahead 0) Overlap (fx< Ahead Window))
      (cases (= (state P) time-wait) (answer-duplicate P Flags Seq N Now)
             (flag? Flags (flag-bits control rst))
               (cases (= Seq Next) (stop-peer P reset)
                      Acceptable (do (peer.ack-needed-> P true) true)
                      true false)
             (flag? Flags (flag-bits control syn)) (answer-duplicate P Flags Seq N Now)
             (or (not (flag? Flags (flag-bits control ack))) (seq-after? Ack (peer.send-next P))) false
             (not Acceptable) (answer-duplicate P Flags Seq N Now)
             true
               (do (acknowledge P Seq Ack Win Now (and (= Flags (flag-bits control ack)) (= N 0)))
                   (if (peer.sack-enabled P) (accept-sack P B Options Start Ack Previous) false)
                   (if (and (fx> Span 0) (not (peer.recv-eof P)))
                       (if Overlap
                           (receive-text P B (fx+ Start Skip) 0 (fx- N Skip) Fin Window Now)
                           (receive-text P B Start Ahead N Fin Window Now))
                       (answer-duplicate P Flags Seq N Now))))))

(define receive-opening
  {peer --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum -->
   boolean --> boolean}
  P Flags Seq Ack Win N Mss Now Scale Sacked -> (opening (state P) Flags P Seq Ack Win N Mss Now Scale Sacked))

\\ The handshake, RFC 9293 3.5: by the state the peer is in and the segment it receives.
(define opening
  {symbol --> fixnum --> peer --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum -->
   boolean --> boolean}
  syn-sent Flags P _ Ack _ _ _ _ _ _ -> (stop-peer P reset)
    where (and (flag? Flags (flag-bits control rst)) (flag? Flags (flag-bits control ack)) (acknowledge? P Ack))
  listen-state (flag-bits control syn) P Seq Ack Win 0 Mss _ Scale Sacked ->
    (do (accept-syn P Seq Ack Win Mss Scale Sacked true)
        (peer.phase-> P syn-received)
        (queue-control P (flag-bits control syn ack)))
  syn-sent (flag-bits control syn ack) P Seq Ack Win 0 Mss Now Scale Sacked ->
    (do (accept-syn P Seq Ack Win Mss Scale Sacked false)
        (peer.tx-flags-> P 0)
        (finish-syn P Now)
        (peer.phase-> P established)
        (peer.ack-needed-> P true)
        true)
    where (acknowledge? P Ack)
  _ _ _ _ _ _ _ _ _ _ _ -> false)

\\ What either end takes from the other's SYN. A listener takes a window scale whenever it can, an
\\ opener only if it offered one.
(define accept-syn
  {peer --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> boolean --> boolean --> peer}
  P Seq Ack Win Mss Scale Sacked Listening ->
    (do (peer.recv-next-> P (seq-add Seq 1))
        (remember-window P Seq Ack Win)
        (peer.send-mss-> P Mss)
        (peer.remote-scale-> P (if (and (sack-capable? P) (or Listening (fx> (peer.window-scale P) 0)))
                                   Scale (type -1 fixnum)))
        (peer.sack-enabled-> P Sacked)))

(define read-scale
  {buffer.view --> fixnum --> fixnum --> fixnum}
  B Options End ->
    (let At (option-offset B Options End 3)
      (if (fx< At 0) -1 (smaller 14 (buffer.u8 B (fx+ At 2))))))

(define terminal?
  {peer --> boolean}
  P -> (let Phase (state P) (or (= Phase closed) (= Phase timed-out) (= Phase reset))))

(define receive-valid
  {peer --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  P B I Count Now ->
    (if (terminal? P) false
        (let Phase (state P)
             Seq (wire.tcp.sequence B I)
             Ack (wire.tcp.acknowledgement B I)
             Flags (segment-flags B I)
             Win (wire.tcp.window B I)
             H (header-length B I)
             Start (fx+ I H)
             N (fx- Count H)
             Options (fx+ I (wire.tcp.size))
             Mss (options B Options Start (smaller (peer.mss P)
                                                   (fx- (peer.path-mtu P) (minimum-header P))))
             Shift (larger 0 (peer.remote-scale P))
          (cases (fx< Mss 0) false
                 (or (= Phase listen-state) (= Phase syn-sent))
                   (receive-opening P Flags Seq Ack Win N
                                    (if (fx< (option-offset B Options Start 2) 0) (smaller Mss (if (= (peer.ip-header P) (wire.ipv4.size)) 536 1220)) Mss)
                                    Now (read-scale B Options Start)
                                    (and (sack-capable? P) (fx>= (option-offset B Options Start 4) 0)))
                 (and (= Phase syn-received) (flag? Flags (flag-bits control rst)) (= Seq (peer.recv-next P)))
                   (stop-peer P reset)
                 (and (= Phase syn-received)
                      (not (and (= Seq (peer.recv-next P)) (flag? Flags (flag-bits control ack)) (acknowledge? P Ack))))
                   (if (and (= Flags (flag-bits control syn)) (= (seq-add Seq 1) (peer.recv-next P))
                            (fx>= (peer.tx-due P) 0))
                       (do (peer.tx-due-> P Now) true)
                       false)
                 true (receive-connected P B Options Start N Flags Seq Ack
                                         (shen-jit.shift-left Win Shift) Now)))))

(define receive-segment
  {peer --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  P B I N Now ->
    (and (not (terminal? P))
         (fx>= N (headers4))
         (addressed-to? B I (peer.local-ip P) (peer.local-port P))
         (= (wire.ipv4.source B I) (peer.remote-ip P))
         (= (wire.tcp.source-port B (fx+ I (wire.ipv4.size))) (peer.remote-port P))
         (valid-segment? B I N (wire.ipv4.size))
         (receive-valid P B (fx+ I (wire.ipv4.size)) (fx- N (wire.ipv4.size)) Now)))

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
  (mutable next-port : fixnum)
  (key0 : fixnum)
  (key1 : fixnum)
  (hash : buffer.view)
  (input-ip6 : net-ipv6.address)
  (mutable next-output : fixnum)
  (mutable next-accept : fixnum))

(define initialise-slots
  {(vector listener-slot) --> net-link.device --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum -->
   (vector listener-slot)}
  Slots _ _ _ _ _ 0 -> Slots
  Slots D IP Port Mss Capacity I ->
    (let Slot (:listener-slot
                 index <- I
                 peer <- (new-peer D IP Port 0 0 Mss Capacity)
                 token <- I
                 lease <- vacant)
      (do (fxvector-> Slots I Slot)
          (initialise-slots Slots D IP Port Mss Capacity (fx- I 1)))))

(define make-listener
  {net-link.device --> fixnum --> fixnum --> fixnum --> fixnum --> listener}
  D IP Port Slots Initial -> (new-table D IP Port Slots Initial 0 0 0))

(define new-table
  {net-link.device --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> listener}
  D IP Port Slots Initial Key0 Key1 Bytes ->
    (let Mss (if (= Bytes 0) (peer-mss D) (smaller Bytes (fx- (net-link.mtu D) 40)))
         Capacity (if (= Bytes 0) (fx* Mss 8) Bytes)
         N (buffer.index Slots)
         _ (if (and (net-ipv4.unicast? IP) (fx>= Port 0) (fx<= Port 65535) (fx> Mss 0) (fx> N 0)) true
                 (error "tcp: listener needs a unicast endpoint, positive slots and an MTU of at least 41"))
         _ (if (and (= Initial (seq-add Initial 0)) (= Key0 (seq-add Key0 0))
                    (= Key1 (seq-add Key1 0))) true
                 (error "tcp: initial sequence must fit unsigned 32 bits"))
      (:listener
        device <- D
        ip <- IP
        port <- Port
        capacity <- N
        slots <- (initialise-slots (vector (fx->number N)) D IP Port Mss Capacity N)
        next-sequence <- Initial
        next-port <- 49152
        key0 <- Key0
        key1 <- Key1
        hash <- (buffer.new 16)
        input-ip6 <- (net-ipv6.make-address 0 0 0 0)
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
  {listener --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum}
  L LocalPort IP Port I ->
    (if (fx> I (listener.capacity L)) 0
        (let S (slot-at L I) P (listener-slot.peer S)
          (if (and (not (= (listener-slot.lease S) vacant))
                   (= LocalPort (peer.local-port P))
                   (= (peer.ip-header P) 20)
                   (= IP (peer.remote-ip P)) (= Port (peer.remote-port P)))
              I
              (find-peer L LocalPort IP Port (fx+ I 1))))))

(define find-peer6
  {listener --> fixnum --> net-ipv6.address --> net-ipv6.address --> fixnum --> fixnum --> fixnum}
  L LocalPort LocalIP RemoteIP Port I ->
    (if (fx> I (listener.capacity L)) 0
        (let S (slot-at L I) P (listener-slot.peer S)
          (if (and (not (= (listener-slot.lease S) vacant))
                   (= LocalPort (peer.local-port P)) (= Port (peer.remote-port P))
                   (= (peer.ip-header P) 40)
                   (net-ipv6.same? LocalIP (peer.local-ip6 P))
                   (net-ipv6.same? RemoteIP (peer.remote-ip6 P)))
              I
              (find-peer6 L LocalPort LocalIP RemoteIP Port (fx+ I 1))))))

(define find-vacant
  {listener --> fixnum --> fixnum}
  L I ->
    (if (fx> I (listener.capacity L)) 0
        (if (= (listener-slot.lease (slot-at L I)) vacant) I (find-vacant L (fx+ I 1)))))

\\ HalfSipHash-2-4 over the fixed 12-byte IPv4 TCP tuple.
(define rotate32
  {fixnum --> fixnum --> fixnum}
  X Bits -> (seq-add (shen-jit.shift-left X Bits) (shen-jit.shift-right X (fx- 32 Bits))))

(define hash-round
  {buffer.view --> buffer.view}
  H ->
    (let V0 (buffer.u32-be H 0)
         V1 (buffer.u32-be H 4)
         V2 (buffer.u32-be H 8)
         V3 (buffer.u32-be H 12)
         A (seq-add V0 V1)
         B (shen-jit.bit-xor (rotate32 V1 5) A)
         C (seq-add V2 V3)
         D (shen-jit.bit-xor (rotate32 V3 8) C)
         E (seq-add (rotate32 A 16) D)
         G (seq-add C B)
      (do (buffer.u32-be-> H 0 E)
          (buffer.u32-be-> H 4 (shen-jit.bit-xor (rotate32 B 13) G))
          (buffer.u32-be-> H 8 (rotate32 G 16))
          (buffer.u32-be-> H 12 (shen-jit.bit-xor (rotate32 D 7) E)))))

(define hash-word
  {buffer.view --> fixnum --> buffer.view}
  H W ->
    (do (buffer.u32-be-> H 12 (shen-jit.bit-xor (buffer.u32-be H 12) W))
        (hash-round (hash-round H))
        (buffer.u32-be-> H 0 (shen-jit.bit-xor (buffer.u32-be H 0) W))))

(define hash-start
  {listener --> buffer.view}
  L ->
    (let H (listener.hash L)
         K0 (listener.key0 L)
         K1 (listener.key1 L)
      (do (buffer.u32-be-> H 0 K0)
          (buffer.u32-be-> H 4 K1)
          (buffer.u32-be-> H 8 (shen-jit.bit-xor K0 1819895653))
          (buffer.u32-be-> H 12 (shen-jit.bit-xor K1 1952801890)))))

(define hash-end
  {buffer.view --> fixnum --> fixnum}
  H Bytes ->
    (do (hash-word H (shen-jit.shift-left Bytes 24))
        (buffer.u32-be-> H 8 (shen-jit.bit-xor (buffer.u32-be H 8) 255))
        (hash-round (hash-round (hash-round (hash-round H))))
        (shen-jit.bit-xor (buffer.u32-be H 4) (buffer.u32-be H 12))))

(define tuple-hash
  {listener --> fixnum --> fixnum --> fixnum --> fixnum}
  L Local IP Port ->
    (let H (hash-start L)
      (do (hash-word H (listener.ip L))
          (hash-word H IP)
          (hash-word H (fx+ (shen-jit.shift-left Local 16) Port))
          (hash-end H 12))))

(define hash-address6
  {buffer.view --> net-ipv6.address --> buffer.view}
  H A ->
    (do (hash-word H (net-ipv6.address.a A))
        (hash-word H (net-ipv6.address.b A))
        (hash-word H (net-ipv6.address.c A))
        (hash-word H (net-ipv6.address.d A))))

(define next-sequence6
  {listener --> peer --> fixnum --> fixnum}
  L P Now ->
    (let H (hash-start L)
         Seq (listener.next-sequence L)
      (do (hash-address6 H (peer.local-ip6 P))
          (hash-address6 H (peer.remote-ip6 P))
          (hash-word H (fx+ (shen-jit.shift-left (peer.local-port P) 16) (peer.remote-port P)))
          (listener.next-sequence-> L (seq-add Seq 65537))
          (seq-add (hash-end H 36) (seq-add Seq (fx* Now 250))))))

(define seed-port
  {listener --> listener}
  L -> (listener.next-port-> L (fx+ 49152 (shen-jit.bit-and (tuple-hash L 0 0 0) 16383))))

(define make-table
  {net-link.device --> fixnum --> fixnum --> fixnum --> fixnum --> listener}
  D IP Slots Key0 Key1 -> (seed-port (new-table D IP 0 Slots 0 Key0 Key1 0)))

(define make-table-sized
  {net-link.device --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> listener}
  D IP Slots Key0 Key1 Bytes ->
    (if (and (fx>= Bytes 1) (fx<= Bytes 1048576))
        (seed-port (new-table D IP 0 Slots 0 Key0 Key1 Bytes))
        (error "tcp: window must be in 1..1048576 bytes")))

(define next-sequence
  {listener --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum}
  L Local IP Port Now ->
    (let Seq (listener.next-sequence L)
      (do (listener.next-sequence-> L (seq-add Seq 65537))
          (if (= (listener.port L) 0)
              (seq-add (tuple-hash L Local IP Port) (seq-add Seq (fx* Now 250)))
              Seq))))

(define configure-peer
  {peer --> fixnum --> fixnum --> fixnum --> peer}
  P Local IP Port -> (do (peer.ip-header-> P 20)
                         (peer.remote-ip-> P IP)
                         (peer.remote-port-> P Port)
                         (peer.local-port-> P Local)))

(define configure-peer6
  {peer --> fixnum --> net-ipv6.address --> net-ipv6.address --> fixnum --> peer}
  P Local LocalIP RemoteIP Port ->
    (do (peer.ip-header-> P 40)
        (net-ipv6.copy-address (peer.local-ip6 P) LocalIP)
        (net-ipv6.copy-address (peer.remote-ip6 P) RemoteIP)
        (peer.remote-port-> P Port)
        (peer.local-port-> P Local)))

(define lease
  {listener --> listener-slot --> symbol --> fixnum}
  L S Role ->
    (let Token (fx+ (listener-slot.token S) (listener.capacity L))
      (do (listener-slot.token-> S Token)
          (listener-slot.lease-> S Role)
          Token)))

(define admit-segment
  {listener --> listener-slot --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  L S B T Count Now Seq ->
    (let P (listener-slot.peer S)
      (do (listen P Seq)
          (if (receive-valid P B T Count Now)
              (fx> (lease L S pending) 0)
              (do (free-slot S) false)))))

(define opening-index
  {listener --> buffer.view --> fixnum --> fixnum --> fixnum}
  L B T Count ->
    (if (and (= (segment-flags B T) 2) (= Count (header-length B T))) (find-vacant L 1)
        (type 0 fixnum)))

(define write-reset
  {buffer.view --> fixnum --> buffer.view --> fixnum --> fixnum --> buffer.view}
  Out At B T Count ->
    (let Flags (segment-flags B T)
         Ack (flag? Flags (flag-bits control ack))
         Space (fx+ (fx- Count (header-length B T))
                    (fx+ (if (flag? Flags (flag-bits control syn)) (type 1 fixnum) (type 0 fixnum))
                         (if (flag? Flags (flag-bits control fin)) (type 1 fixnum) (type 0 fixnum))))
      (write-layout wire.tcp Out At
        (source-port (wire.tcp.destination-port B T)) (destination-port (wire.tcp.source-port B T))
        (sequence (if Ack (wire.tcp.acknowledgement B T) 0))
        (acknowledgement (if Ack 0 (seq-add (wire.tcp.sequence B T) Space)))
        (data-offset 5) (flags (if Ack (flag-bits control rst) (flag-bits control rst ack))))))

(define reset-allowed?
  {net-link.ring --> buffer.view --> fixnum --> boolean}
  Tx B T -> (and (not (flag? (segment-flags B T) (flag-bits control rst))) (not (net-link.full? Tx))))

(define reject-segment
  {listener --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  L B T Count IP Now ->
    (let D (listener.device L)
         Tx (net-link.device.tx D)
      (if (reset-allowed? Tx B T)
          (let Out (net-link.ring.data Tx)
               At (net-link.tail-offset Tx)
            (do (net-ipv4.write-header Out At (headers4) 6 (listener.ip L) IP)
                (write-reset Out (fx+ At (wire.ipv4.size)) B T Count)
                (wire.tcp.checksum-> Out (fx+ At (wire.ipv4.size))
                                     (net-ipv4.transport-checksum Out At 6 (wire.tcp.size)))
                (net-link.publish Tx (headers4) (net-link.delivery D Now))))
          false)))

(define reject-segment6
  {listener --> buffer.view --> fixnum --> fixnum --> net-ipv6.address --> net-ipv6.address -->
   fixnum --> boolean}
  L B T Count LocalIP RemoteIP Now ->
    (let D (listener.device L)
         Tx (net-link.device.tx D)
      (if (reset-allowed? Tx B T)
          (let Out (net-link.ring.data Tx)
               At (net-link.tail-offset Tx)
            (do (net-ipv6.write-header Out At (headers6) 6 64 LocalIP RemoteIP)
                (write-reset Out (fx+ At (wire.ipv6.size)) B T Count)
                (wire.tcp.checksum-> Out (fx+ At (wire.ipv6.size))
                                     (net-ipv6.transport-checksum Out At 6 (wire.tcp.size)))
                (net-link.publish Tx (headers6) (net-link.delivery D Now))))
          false)))

(define new-segment
  {listener --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum -->
   fixnum --> boolean --> boolean}
  L B T Count Local IP Port Now Listening ->
    (if (and Listening (not (flag? (segment-flags B T) (flag-bits control ack))))
        (let Index (opening-index L B T Count)
          (and (fx> Index 0)
               (let S (slot-at L Index)
                 (do (configure-peer (listener-slot.peer S) Local IP Port)
                     (admit-segment L S B T Count Now (next-sequence L Local IP Port Now))))))
        (reject-segment L B T Count IP Now)))

(define table-ingress
  {listener --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean --> boolean}
  L B I Count Now Listening ->
    (and (valid-segment? B I Count (wire.ipv4.size)) (= (wire.ipv4.destination B I) (listener.ip L))
         (let T (fx+ I (wire.ipv4.size))
              IP (wire.ipv4.source B I)
              Port (wire.tcp.source-port B T)
              Local (wire.tcp.destination-port B T)
              Bytes (fx- Count (wire.ipv4.size))
           (and (endpoint? IP Port) (fx> Local 0)
                (let Index (find-peer L Local IP Port 1)
                  (if (= Index 0)
                      (new-segment L B T Bytes Local IP Port Now Listening)
                      (receive-valid (listener-slot.peer (slot-at L Index)) B T Bytes Now)))))))

(define new-segment6
  {listener --> buffer.view --> fixnum --> fixnum --> net-ipv6.address --> net-ipv6.address -->
   fixnum --> fixnum --> fixnum --> boolean --> boolean}
  L B T Count LocalIP RemoteIP Local Port Now Listening ->
    (if (and Listening (not (flag? (segment-flags B T) (flag-bits control ack))))
        (let Index (opening-index L B T Count)
          (and (fx> Index 0)
               (let S (slot-at L Index)
                    P (configure-peer6 (listener-slot.peer S) Local LocalIP RemoteIP Port)
                 (admit-segment L S B T Count Now (next-sequence6 L P Now)))))
        (reject-segment6 L B T Count LocalIP RemoteIP Now)))

(define table-ingress6
  {listener --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean --> net-ipv6.address --> boolean}
  L B I Count Now Listening LocalIP ->
    (and (valid-segment? B I Count (wire.ipv6.size)) (net-ipv6.address-at? LocalIP B (wire.ipv6.destination-at I))
         (let T (fx+ I (wire.ipv6.size))
              Remote (net-ipv6.read-address (listener.input-ip6 L) B (wire.ipv6.source-at I))
              Port (wire.tcp.source-port B T)
              Local (wire.tcp.destination-port B T)
              Bytes (fx- Count (wire.ipv6.size))
           (and (net-ipv6.unicast? Remote) (fx> Port 0) (fx> Local 0)
                (let Index (find-peer6 L Local LocalIP Remote Port 1)
                  (if (= Index 0)
                      (new-segment6 L B T Bytes LocalIP Remote Local Port Now Listening)
                      (receive-valid (listener-slot.peer (slot-at L Index)) B T Bytes Now)))))))

(define listener-ingress
  {listener --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  L B I Count Now ->
    (and (fx>= Count (headers4)) (= (wire.tcp.destination-port B (fx+ I (wire.ipv4.size))) (listener.port L))
         (table-ingress L B I Count Now true)))

(define bound-port?
  {(list fixnum) --> fixnum --> boolean}
  [] _ -> false
  [P | Rest] Port -> (or (= P Port) (bound-port? Rest Port)))

(define local-port-in-use?
  {listener --> fixnum --> fixnum --> boolean}
  L Port I ->
    (and (fx<= I (listener.capacity L))
         (let S (slot-at L I)
           (or (and (not (= (listener-slot.lease S) vacant))
                    (= (peer.local-port (listener-slot.peer S)) Port))
               (local-port-in-use? L Port (fx+ I 1))))))

(define claim-port
  {listener --> (list fixnum) --> fixnum --> fixnum}
  _ _ 0 -> 0
  L Reserved Left ->
    (let Port (listener.next-port L)
      (do (listener.next-port-> L (if (= Port 65535) 49152 (fx+ Port 1)))
          (if (or (bound-port? Reserved Port) (local-port-in-use? L Port 1))
              (claim-port L Reserved (fx- Left 1))
              Port))))

(define table-connect
  {listener --> (list fixnum) --> fixnum --> fixnum --> fixnum}
  L Reserved IP Port ->
    (if (endpoint? IP Port)
        (let I (find-vacant L 1)
             Local (if (= I 0) (type 0 fixnum) (claim-port L Reserved 16384))
          (if (= Local 0) 0
              (let S (slot-at L I)
                   P (configure-peer (listener-slot.peer S) Local IP Port)
                   Now (net-link.now (listener.device L))
                (do (connect P (next-sequence L Local IP Port Now))
                    (lease L S leased)))))
        (error "tcp: invalid remote endpoint")))

(define table-connect6
  {listener --> (list fixnum) --> net-ipv6.address --> net-ipv6.address --> fixnum --> fixnum}
  L Reserved LocalIP RemoteIP Port ->
    (if (and (net-ipv6.unicast? LocalIP) (net-ipv6.unicast? RemoteIP)
             (fx>= Port 1) (fx<= Port 65535) (fx>= (net-link.mtu (listener.device L)) 1280))
        (let I (find-vacant L 1)
             Local (if (= I 0) (type 0 fixnum) (claim-port L Reserved 16384))
          (if (= Local 0) 0
              (let S (slot-at L I)
                   P (configure-peer6 (listener-slot.peer S) Local LocalIP RemoteIP Port)
                   Now (net-link.now (listener.device L))
                (do (connect P (next-sequence6 L P Now))
                    (lease L S leased)))))
        (error "tcp: invalid IPv6 endpoints or link MTU below 1280")))

(define expire-addresses6
  {listener --> net-ipv6.address --> boolean --> net-ipv6.address --> boolean --> boolean}
  L Local LocalReady Global GlobalReady ->
    (expire-slots6 L Local LocalReady Global GlobalReady (listener.capacity L)))

(define expire-slots6
  {listener --> net-ipv6.address --> boolean --> net-ipv6.address --> boolean --> fixnum --> boolean}
  _ _ _ _ _ 0 -> true
  L Local LocalReady Global GlobalReady I ->
    (let S (slot-at L I)
         P (listener-slot.peer S)
         Source (peer.local-ip6 P)
      (do (if (and (= (peer.ip-header P) 40) (not (= (listener-slot.lease S) vacant)) (not (terminal? P))
                   (not (or (and LocalReady (net-ipv6.same? Source Local))
                            (and GlobalReady (net-ipv6.same? Source Global)))))
              (stop-peer P reset)
              false)
          (expire-slots6 L Local LocalReady Global GlobalReady (fx- I 1)))))

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

(define earlier
  {fixnum --> fixnum --> fixnum}
  A B -> (if (fx< A 0) B (if (fx< B 0) A (smaller A B))))

(define output-ready?
  {peer --> boolean}
  P ->
    (let Flight (peer.tx-flight P)
         Window (peer.remote-window P)
         End (smaller Flight (if (= Window 0) 1 Window))
         Replay (peer.tx-replay P)
         Repair (peer.sack-next-repair P)
         Credit (fx- (peer.cwnd P) (peer.sack-pipe P))
      (or (peer.aborting P)
          (peer.ack-needed P)
          (fx> (peer.rx-duplicate-acks P) 0)
          (if (not (= (peer.tx-flags P) 0)) (fx< (peer.tx-due P) 0)
              (or (and (fx>= Replay 0) (fx< Replay (smaller End (peer.cwnd P))))
                  (and (fx> Window 0)
                       (or (and (peer.tx-fast-retransmit P) (fx> End 0)
                                (or (not (sack-recovering? P)) (fx> Credit 0)))
                           (and (fx>= Repair 0) (fx< Repair End) (fx> Credit 0))))
                  (and (fx> (peer.tx-length P) Flight)
                       (or (and (= Flight 0) (= Window 0))
                           (fx> (smaller Window (peer.cwnd P)) (larger Flight (peer.sack-pipe P))))))))))

(define peer-deadline
  {peer --> fixnum --> boolean --> fixnum}
  P Now Writable ->
    (let Due (peer.tx-due P)
         Wait (if (and (= (state P) time-wait) (not (peer.ack-needed P)))
                  (peer.wait-until P) (type -1 fixnum))
      (if (and Writable (output-ready? P)) Now
          (earlier Wait (if (or Writable (fx>= (peer.tx-retries P) 6)) Due (type -1 fixnum))))))

(define table-deadline
  {listener --> fixnum --> boolean --> fixnum --> fixnum --> fixnum}
  _ _ _ 0 At -> At
  L Now Writable I At ->
    (let S (slot-at L I)
         Due (if (= (listener-slot.lease S) vacant) (type -1 fixnum)
                 (peer-deadline (listener-slot.peer S) Now Writable))
      (table-deadline L Now Writable (fx- I 1) (earlier At Due))))

(define listener-deadline
  {listener --> fixnum --> fixnum}
  L Now -> (table-deadline L Now (not (net-link.full? (net-link.device.tx (listener.device L))))
                          (listener.capacity L) -1))

(define listener-poll
  {listener --> fixnum --> fixnum}
  L Budget ->
    (let D (listener.device L)
         Now (net-link.now D)
         Count (listener-input L (net-link.device.rx D) Now (buffer.index Budget) 0)
      (do (listener-transmit L Now)
          Count)))

(define accept-ready
  {listener --> fixnum --> fixnum --> fixnum --> fixnum}
  _ _ _ 0 -> 0
  L Port I Left ->
    (let S (slot-at L I) P (listener-slot.peer S) Phase (state P)
      (if (and (= (listener-slot.lease S) pending)
               (or (= Port 0) (= Port (peer.local-port P)))
               (or (= Phase established) (= Phase close-wait)))
          (do (listener-slot.lease-> S leased)
              (listener.next-accept-> L (next-index L I))
              (listener-slot.token S))
          (accept-ready L Port (next-index L I) (fx- Left 1)))))

(define accept
  {listener --> fixnum}
  L -> (accept-on L 0))

(define accept-on
  {listener --> fixnum --> fixnum}
  L Port -> (accept-ready L Port (listener.next-accept L) (listener.capacity L)))

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

(define connection-readable?
  {listener --> fixnum --> boolean}
  L Token -> (let P (listener-slot.peer (lease-slot L Token))
               (or (fx> (peer.rx-length P) 0) (peer.recv-eof P) (terminal? P))))

(define connection-writable?
  {listener --> fixnum --> boolean}
  L Token -> (let P (listener-slot.peer (lease-slot L Token)) Phase (state P)
               (and (or (= Phase established) (= Phase close-wait))
                    (fx< (peer.tx-length P) (peer.capacity P)))))

(define connection-send
  {listener --> fixnum --> buffer.view --> fixnum --> fixnum}
  L Token Payload Count -> (send (listener-slot.peer (lease-slot L Token)) Payload Count))

(define connection-recv-into
  {listener --> fixnum --> buffer.view --> fixnum --> fixnum}
  L Token Out Count -> (recv-into (listener-slot.peer (lease-slot L Token)) Out Count))

(define connection-send-from
  {listener --> fixnum --> buffer.view --> fixnum --> fixnum --> fixnum}
  L Token B At Count -> (send-from (listener-slot.peer (lease-slot L Token)) B At Count))

(define connection-recv-at
  {listener --> fixnum --> buffer.view --> fixnum --> fixnum --> fixnum}
  L Token B At Count -> (recv-at (listener-slot.peer (lease-slot L Token)) B At Count))

(define connection-shutdown-write
  {listener --> fixnum --> boolean}
  L Token -> (shutdown-write (listener-slot.peer (lease-slot L Token))))

(define connection-abort
  {listener --> fixnum --> boolean}
  L Token ->
    (let P (listener-slot.peer (lease-slot L Token))
      (cases (terminal? P) false
             (= (state P) syn-sent) (stop-peer P reset)
             true (do (peer.aborting-> P true) (peer.tx-due-> P -1) true))))

\\ Validate a quoted segment against a live tuple and its outstanding sequence interval.
(define reduce-mtu
  {listener --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  L Index Seq Mtu Now ->
    (and (fx> Index 0)
         (let P (listener-slot.peer (slot-at L Index))
           (and (fx< (seq-distance Seq (send-una P)) (peer.tx-flight P))
                (fx< Mtu (peer.path-mtu P))
                (do (peer.path-mtu-> P Mtu)
                    (peer.send-mss-> P (smaller (peer.send-mss P) (fx- Mtu (minimum-header P))))
                    (peer.tx-due-> P Now)
                    true)))))

(define path-mtu
  {listener --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  L B I Count Mtu Now ->
    (let T (fx+ I (wire.ipv4.size))                       \\ The quote: our IP header, then 8 bytes of TCP.
      (and (fx>= Count (fx+ (wire.ipv4.size) 8))
           (= (wire.ipv4.version B I) 4) (= (wire.ipv4.header-length B I) 5)
           (= (wire.ipv4.protocol B I) 6)
           (= (wire.ipv4.source B I) (listener.ip L))
           (= (net-ipv4.packet-checksum B I (wire.ipv4.size)) 0)
           (fx>= Mtu 68) (fx< Mtu (wire.ipv4.total-length B I))
           (reduce-mtu L (find-peer L (wire.tcp.source-port B T) (wire.ipv4.destination B I)
                                    (wire.tcp.destination-port B T) 1)
                       (wire.tcp.sequence B T) Mtu Now))))

(define path-mtu6
  {listener --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> net-ipv6.address --> boolean}
  L B I Count Mtu Now LocalIP ->
    (let T (fx+ I (wire.ipv6.size))                       \\ The quote: our IPv6 header, then TCP's first 8 bytes.
      (and (fx>= Count (fx+ (wire.ipv6.size) 8))
           (= (wire.ipv6.version B I) 6)
           (= (wire.ipv6.next-header B I) 6)
           (net-ipv6.address-at? LocalIP B (wire.ipv6.source-at I))
           (fx>= Mtu 1280) (fx< Mtu (fx+ (wire.ipv6.size) (wire.ipv6.payload-length B I)))
           (let Remote (net-ipv6.read-address (listener.input-ip6 L) B (wire.ipv6.destination-at I))
             (reduce-mtu L (find-peer6 L (wire.tcp.source-port B T) LocalIP Remote
                                       (wire.tcp.destination-port B T) 1)
                         (wire.tcp.sequence B T) Mtu Now)))))

(define release
  {listener --> fixnum --> boolean}
  L Token -> (let S (lease-slot L Token)
               (and (terminal? (listener-slot.peer S)) (free-slot S))))

(preclude [peer.%match listener.%match listener-slot.%match])
)
