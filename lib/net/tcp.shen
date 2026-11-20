\\ Typed TCP over the packet link with preallocated send and receive windows.
(shen.x.namespace tcp
  (use buffer)
  (use net-link)
  (use net-ipv4)
  (use net-ipv6)
  (use net-marks)
  (use shen-jit)
  (use net-wire => wire)
  (use grammar)
  (import struct defstruct)
  (import layout write-layout defflags flag-bits)
  (import net-seq seq seq-of seq-number seq-add seq-distance seq-after?)
  (externals [defgrammar u16-be <end> <e> skip at])
  (shadow listen release)
  (export peer make-peer listen connect state send recv-into shutdown-write poll
          listener make-listener listener-poll accept connection-index connection-state
          listener-ingress listener-transmit make-table table-ingress table-connect accept-on
          listener-deadline connection-readable? connection-writable? connection-abort
          make-table-sized make-table-limits path-mtu path-mtu6
          table-ingress6 table-ingress6-at header-fits? table-connect6 expire-addresses6
          connection-send connection-send-from connection-recv-into connection-recv-at connection-shutdown-write release
          closed listen-state syn-sent syn-received established close-wait fin-wait-1 fin-wait-2
          closing last-ack time-wait timed-out reset phase)

\\ RFC 9293's control bits, the most significant first.
(defflags control cwr ece urg ack psh rst syn fin)

\\ RFC 9293 3.3.2: the states a connection passes through, and the three it can end in.
(datatype phases
  if (element? Phase [closed listen-state syn-sent syn-received established close-wait fin-wait-1
                      fin-wait-2 closing last-ack time-wait timed-out reset])
  ___________________________________________________________________________________
  Phase : phase;)

\\ A listener's stream slot is free, holds a half-open connection, or is the application's.
(datatype leases
  if (element? Lease [vacant pending leased])
  ___________________________________________
  Lease : lease;)

\\ A received segment, decoded once into a record the peer reuses. MSS is the smallest offered.
\\ MSS, window scale, and SACK block bounds are -1 when absent. SACK permission is kept separately.
(defstruct segment
  (mutable data : buffer.view)
  (mutable start : fixnum)
  (mutable length : fixnum)
  (mutable flags : fixnum)
  (mutable sequence : seq)
  (mutable acknowledgement : seq)
  (mutable window : fixnum)
  (mutable mss : fixnum)
  (mutable scale : fixnum)
  (mutable sack-permitted : boolean)
  (mutable sack-at : fixnum)
  (mutable sack-end : fixnum))

(define blank-segment
  {--> segment}
  -> (:segment data <- (buffer.new 0) start <- 0 length <- 0 flags <- 0
               sequence <- (seq-of 0) acknowledgement <- (seq-of 0) window <- 0
               mss <- -1 scale <- -1 sack-permitted <- false sack-at <- -1 sack-end <- -1))

(defstruct peer
  (device : net-link.device)
  (local-address : net-ipv6.address)                     \\ Both families', IPv4's mapped.
  (remote-address : net-ipv6.address)
  (mutable ip-header : fixnum)
  (mutable local-port : fixnum)
  (mutable remote-port : fixnum)
  (tx : buffer.view)
  (rx : buffer.view)
  (rx-present : buffer.view)
  (tx-sacked : buffer.view)
  (tx-repaired : buffer.view)
  (mss : fixnum)
  (capacity : fixnum)
  (window-scale : fixnum)
  (mutable remote-scale : fixnum)
  (mutable path-mtu : fixnum)
  (mutable aborting : boolean)
  (mutable phase : phase)
  (mutable send-next : seq)
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
  (mutable rtt-sample-end : seq)
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
  (mutable remote-window-seq : seq)
  (mutable remote-window-ack : seq)
  (mutable send-mss : fixnum)
  (mutable recv-next : seq)
  (mutable rx-start : fixnum)
  (mutable rx-length : fixnum)
  (mutable rx-pending : fixnum)
  (mutable rx-fin : fixnum)
  (mutable recv-eof : boolean)
  (mutable ack-needed : boolean)
  (mutable rx-duplicate-acks : fixnum)
  (mutable wait-until : fixnum)
  (options-state : grammar.state)
  (segment : segment))

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

\\ The IP header of a segment between two addresses, with IpBytes of it.
(define write-ip-header
  {buffer.view --> fixnum --> fixnum --> fixnum --> net-ipv6.address --> net-ipv6.address --> buffer.view}
  B I Size IpBytes Local Remote ->
    (if (= IpBytes (wire.ipv4.size))
        (net-ipv4.write-header B I Size (wire.tcp-protocol) (net-ipv6.address.d Local) (net-ipv6.address.d Remote))
        (net-ipv6.write-header B I Size (wire.tcp-protocol) 64 Local Remote)))

\\ How many bytes of IP header go to an address.
(define ip-bytes
  {net-ipv6.address --> fixnum}
  A -> (if (net-ipv6.mapped? A) (wire.ipv4.size) (wire.ipv6.size)))

(define transport-checksum
  {buffer.view --> fixnum --> fixnum --> fixnum --> fixnum}
  B I IpBytes N ->
    (if (= IpBytes (wire.ipv4.size)) (net-ipv4.transport-checksum B I (wire.tcp-protocol) N)
        (net-ipv6.transport-checksum B I (wire.tcp-protocol) N)))

(define endpoint?
  {fixnum --> fixnum --> boolean}
  IP Port -> (and (net-ipv4.unicast? IP) (fx>= Port 1) (fx<= Port 65535)))

\\ RFC 9293 3.7.1: the size a peer may send when it offers none, behind IPv4 or IPv6. This end offers
\\ IPv4's default, or less on a smaller link.
(define default-mss
  {fixnum --> fixnum}
  IpBytes -> (if (= IpBytes (wire.ipv4.size)) 536 1220))

(define peer-mss
  {net-link.device --> fixnum}
  D -> (smaller (default-mss (wire.ipv4.size)) (fx- (net-link.mtu D) (fx+ (wire.ipv4.size) (wire.tcp.size)))))

(define scale-for
  {fixnum --> fixnum --> fixnum}
  Capacity Shift ->
    (if (fx<= Capacity 65535) Shift (scale-for (shen-jit.shift-right Capacity 1) (fx+ Shift 1))))

(define new-peer
  {net-link.device --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> peer}
  D LocalIP LocalPort RemoteIP RemotePort Mss Capacity ->
    (let MapBytes (net-marks.bytes Capacity)
      (:peer
        device <- D
        local-address <- (net-ipv6.map-ipv4 (net-ipv6.make-address 0 0 0 0) LocalIP)
        remote-address <- (net-ipv6.map-ipv4 (net-ipv6.make-address 0 0 0 0) RemoteIP)
        ip-header <- (wire.ipv4.size)
        local-port <- LocalPort
        remote-port <- RemotePort
        tx <- (buffer.new Capacity)
        rx <- (buffer.new Capacity)
        rx-present <- (buffer.new MapBytes)
        tx-sacked <- (buffer.new MapBytes)
        tx-repaired <- (buffer.new MapBytes)
        mss <- Mss
        capacity <- Capacity
        options-state <- (grammar.state)
        segment <- (blank-segment)
        window-scale <- (scale-for Capacity 0)
        remote-scale <- -1
        path-mtu <- (net-link.mtu D)
        aborting <- false
        phase <- closed
        send-next <- (seq-of 0)
        tx-flags <- 0
        tx-head <- 0
        tx-length <- 0
        tx-flight <- 0
        tx-replay <- -1
        tx-due <- -1
        tx-rto <- (initial-rto)
        tx-retries <- 0
        srtt <- 0
        rttvar <- 0
        rtt-sample-at <- -1
        rtt-sample-end <- (seq-of 0)
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
        remote-window-seq <- (seq-of 0)
        remote-window-ack <- (seq-of 0)
        send-mss <- Mss
        recv-next <- (seq-of 0)
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
  {peer --> phase}
  P -> (peer.phase P))

\\ RFC 9293 3.3.2's state diagram: where a connection goes when this end closes, when the other end's
\\ FIN arrives, and when what this end sent last, a SYN or a FIN, is acknowledged.
(define on-close
  {phase --> phase}
  established -> fin-wait-1
  close-wait -> last-ack
  Phase -> Phase)

(define on-fin
  {phase --> phase}
  established -> close-wait
  fin-wait-1 -> closing
  fin-wait-2 -> time-wait
  Phase -> Phase)

(define on-acknowledged
  {phase --> phase}
  syn-received -> established
  fin-wait-1 -> fin-wait-2
  closing -> time-wait
  last-ack -> closed
  Phase -> Phase)

\\ The states in which this end may still send: synchronized, and not yet closed by it.
(define can-send?
  {phase --> boolean}
  Phase -> (or (= Phase established) (= Phase close-wait)))

\\ RFC 6298 2.1: until a round trip is measured, the retransmission timeout is a second.
(define initial-rto
  {--> fixnum}
  -> 1000)

\\ A 32-bit word's sum, as the hash of a connection's endpoints takes it.
(define add32
  {fixnum --> fixnum --> fixnum}
  A B -> (shen-jit.bit-and (fx+ A B) 4294967295))

(define flag?
  {fixnum --> fixnum --> boolean}
  Flags Bit -> (not (= (shen-jit.bit-and Flags Bit) 0)))

(define clear-sack
  {peer --> boolean}
  P -> (if (fx> (peer.tx-sack-high P) 0)
           (do (net-marks.clear (peer.tx-sacked P) (peer.capacity P))
               (peer.tx-sack-high-> P 0)
               true)
           true))

(define sack-recovering?
  {peer --> boolean}
  P -> (and (peer.sack-enabled P) (fx> (peer.recovery-bytes P) 0)))

(define clear-sack-recovery
  {peer --> boolean}
  P -> (do (if (sack-recovering? P) (net-marks.clear (peer.tx-repaired P) (peer.capacity P)) true)
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
  {peer --> fixnum --> phase --> boolean}
  P Seq Phase ->
    (if (and (= (state P) closed) (= (peer.rx-length P) 0))
        (let _ (if (and (fx>= Seq 0) (fx<= Seq 4294967295)) true
                     (error "tcp: initial sequence must fit unsigned 32 bits"))
          (do (peer.send-next-> P (seq-of Seq))
              (peer.tx-flags-> P 0)
              (peer.tx-head-> P 0)
              (peer.tx-length-> P 0)
              (peer.tx-flight-> P 0)
              (peer.tx-replay-> P -1)
              (peer.tx-due-> P -1)
              (peer.tx-rto-> P (initial-rto))
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
              (peer.recv-next-> P (seq-of 0))
              (peer.rx-start-> P 0)
              (if (fx> (peer.rx-pending P) 0) (net-marks.clear (peer.rx-present P) (peer.capacity P)) true)
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

(define receive-tail
  {peer --> fixnum}
  P -> (wrap-offset (fx+ (peer.rx-start P) (peer.rx-length P)) (peer.capacity P)))

(define receive-limit
  {peer --> fixnum --> fixnum}
  P Window ->
    (let Final (peer.rx-fin P)
      (if (fx< Final 0) Window (smaller Window (seq-distance (seq-of Final) (peer.recv-next P))))))

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
      (if (and (can-send? Phase) (fx> N 0))
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
      (if (and (can-send? Phase) (= (peer.tx-length P) 0))
          (do (queue-control P (flag-bits control fin ack))
              (peer.phase-> P (on-close Phase))
              true)
          false)))
)
