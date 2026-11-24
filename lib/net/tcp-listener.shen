\\ TCP's listeners: tables of connections, TIME-WAIT records, ports, deadlines and the connection API.
(shen.x.namespace tcp
  (use buffer)
  (use net-link)
  (use net-ipv4)
  (use net-ipv6)
  (use shen-jit)
  (use net-wire => wire)
  (use grammar)
  (use net-marks)
  (import struct defstruct)
  (import layout write-layout defflags flag-bits)
  (import net-seq seq seq-of seq-number seq-add seq-distance seq-after?)
  (externals [defgrammar u16-be <end> <e> skip at])
  (shadow listen release)

\\ A slot's token advances by the table capacity on each new occupant. Applications get the
\\ token only after the handshake and retain the lease until they release the terminal connection.
(defstruct listener-slot
  (index : fixnum)
  (peer : peer)
  (mutable token : fixnum)
  (mutable lease : lease))

\\ RFC 9293 3.6.1: a connection in TIME-WAIT whose stream slot was released, by its tuple, where its
\\ sequences stood, the window it advertised, when the wait ends, and whether a segment awaits an
\\ acknowledgement. It holds no buffers.
(defstruct wait-entry
  (index : fixnum)
  (local : net-ipv6.address)
  (remote : net-ipv6.address)
  (mutable ip-header : fixnum)
  (mutable local-port : fixnum)
  (mutable remote-port : fixnum)
  (mutable send-next : seq)
  (mutable recv-next : seq)
  (mutable window : fixnum)
  (mutable until : fixnum)
  (mutable ack-needed : boolean))

\\ The slot map has a bit for each slot that is not vacant, and the wait map one for each record in
\\ use, so that a scan passes over the others a run at a time, and over all of them while none is used.
(defstruct listener
  (device : net-link.device)
  (ip : fixnum)
  (port : fixnum)
  (capacity : fixnum)
  (slots : (vector listener-slot))
  (slot-map : buffer.view)
  (mutable used : fixnum)
  (wait-slots : fixnum)
  (waits : (vector wait-entry))
  (wait-map : buffer.view)
  (wait-segment : segment)
  (wait-options : grammar.state)
  (mutable wait-used : fixnum)
  (mutable next-wait-output : fixnum)
  (mutable wait-first : boolean)
  (mutable next-sequence : fixnum)
  (mutable next-port : fixnum)
  (key0 : fixnum)
  (key1 : fixnum)
  (hash : buffer.storage)
  (local4 : net-ipv6.address)                           \\ Its IPv4 address, mapped.
  (input-remote : net-ipv6.address)
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
  D IP Port Slots Initial -> (new-table D IP Port Slots Initial 0 0 0 16))

(define initialise-waits
  {(vector wait-entry) --> fixnum --> (vector wait-entry)}
  V 0 -> V
  V I ->
    (let W (:wait-entry
             index <- I
             local <- (net-ipv6.make-address 0 0 0 0)
             remote <- (net-ipv6.make-address 0 0 0 0)
             ip-header <- (wire.ipv4.size)
             local-port <- 0
             remote-port <- 0
             send-next <- (seq-of 0)
             recv-next <- (seq-of 0)
             window <- 0
             until <- -1
             ack-needed <- false)
      (initialise-waits (fxvector-> V I W) (fx- I 1))))

(define new-table
  {net-link.device --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum -->
   fixnum --> listener}
  D IP Port Slots Initial Key0 Key1 Bytes WaitSlots ->
    (let Mss (if (= Bytes 0) (peer-mss D) (net-link.smaller Bytes (fx- (net-link.mtu D) (headers4))))
         Capacity (if (= Bytes 0) (fx* Mss 8) Bytes)
         N (buffer.index Slots)
         _ (if (and (net-ipv4.unicast? IP) (fx>= Port 0) (fx<= Port 65535) (fx> Mss 0) (fx> N 0)) true
                 (error "tcp: listener needs a unicast endpoint, positive slots and an MTU of at least 41"))
         _ (if (and (= Initial (add32 Initial 0)) (= Key0 (add32 Key0 0))
                    (= Key1 (add32 Key1 0))) true
                 (error "tcp: initial sequence must fit unsigned 32 bits"))
      (:listener
        device <- D
        ip <- IP
        port <- Port
        capacity <- N
        slots <- (initialise-slots (vector (fx->number N)) D IP Port Mss Capacity N)
        slot-map <- (buffer.new (net-marks.bytes N))
        used <- 0
        wait-slots <- WaitSlots
        waits <- (initialise-waits (vector (fx->number WaitSlots)) WaitSlots)
        wait-map <- (buffer.new (net-marks.bytes WaitSlots))
        wait-segment <- (blank-segment)
        wait-options <- (grammar.state)
        wait-used <- 0
        next-wait-output <- 1
        wait-first <- false
        next-sequence <- Initial
        next-port <- 49152
        key0 <- Key0
        key1 <- Key1
        hash <- (shen-jit.bytes 16)
        local4 <- (net-ipv6.map-ipv4 (net-ipv6.make-address 0 0 0 0) IP)
        input-remote <- (net-ipv6.make-address 0 0 0 0)
        next-output <- 1
        next-accept <- 1)))

(define slot-at
  {listener --> fixnum --> listener-slot}
  L I -> (fx<-vector (listener.slots L) I))

(define next-index
  {listener --> fixnum --> fixnum}
  L I -> (if (= I (listener.capacity L)) 1 (fx+ I 1)))

\\ The first of slots I to Last whose bit in Map, of Capacity slots counted from 1, is not Skip, or
\\ Last + 1 if none is.
(define next-slot
  {buffer.view --> fixnum --> fixnum --> fixnum --> boolean --> fixnum}
  Map Capacity I Last Skip ->
    (if (fx> I Last) (fx+ Last 1)
        (fx+ I (net-marks.run-length Map (fx- I 1) Capacity (fx+ (fx- Last I) 1) Skip))))

(define vacant-at?
  {listener --> fixnum --> fixnum --> boolean}
  L I Last -> (or (fx> I Last) (= (listener-slot.lease (slot-at L I)) vacant)))

\\ The first occupied slot after vacant slot I, up to Last, or Last + 1. A scan tests each slot it
\\ reaches, and comes here from a vacant one; the next slot is tested first too, as that costs less
\\ than a read of the map.
(define skip-vacant
  {listener --> fixnum --> fixnum --> fixnum}
  L I Last -> (cases (= (listener.used L) 0) (fx+ Last 1)
                     (vacant-at? L (fx+ I 1) Last)
                       (next-slot (listener.slot-map L) (listener.capacity L) (fx+ I 2) Last false)
                     true (fx+ I 1)))

(define mark-slot
  {buffer.view --> fixnum --> fixnum --> boolean --> boolean}
  Map Capacity I Mark -> (net-marks.mark Map (fx- I 1) Capacity 1 Mark))

(define free-slot
  {listener --> listener-slot --> boolean}
  L S -> (let P (listener-slot.peer S)
           (do (stop-peer P closed)
               (peer.rx-length-> P 0)
               (if (= (listener-slot.lease S) vacant) L (listener.used-> L (fx- (listener.used L) 1)))
               (listener-slot.lease-> S vacant)
               (mark-slot (listener.slot-map L) (listener.capacity L) (listener-slot.index S) false))))

(define wait-at
  {listener --> fixnum --> wait-entry}
  L I -> (fx<-vector (listener.waits L) I))

(define free-record?
  {listener --> fixnum --> fixnum --> boolean}
  L I Last -> (or (fx> I Last) (fx< (wait-entry.until (wait-at L I)) 0)))

\\ The first record in use after free record I, up to Last, or Last + 1, as skip-vacant finds slots.
(define skip-free
  {listener --> fixnum --> fixnum --> fixnum}
  L I Last -> (cases (= (listener.wait-used L) 0) (fx+ Last 1)
                     (free-record? L (fx+ I 1) Last)
                       (next-slot (listener.wait-map L) (listener.wait-slots L) (fx+ I 2) Last false)
                     true (fx+ I 1)))

\\ Moves a connection in TIME-WAIT out of its stream slot into a free record, if there is one.
(define save-wait
  {listener --> peer --> boolean}
  L P ->
    (let N (listener.wait-slots L)
         I (next-slot (listener.wait-map L) N 1 N true)
      (and (fx<= I N)
           (let W (wait-at L I)
                H (peer.ip-header P)
             (do (net-ipv6.copy-address (wait-entry.local W) (peer.local-address P))
                 (net-ipv6.copy-address (wait-entry.remote W) (peer.remote-address P))
                 (wait-entry.ip-header-> W H)
                 (wait-entry.local-port-> W (peer.local-port P))
                 (wait-entry.remote-port-> W (peer.remote-port P))
                 (wait-entry.send-next-> W (peer.send-next P))
                 (wait-entry.recv-next-> W (peer.recv-next P))
                 (wait-entry.window-> W (advertised-window P (flag-bits control ack)))
                 (wait-entry.until-> W (peer.wait-until P))
                 (wait-entry.ack-needed-> W (peer.ack-needed P))
                 (listener.wait-used-> L (fx+ (listener.wait-used L) 1))
                 (mark-slot (listener.wait-map L) N I true))))))

(define clear-wait
  {listener --> wait-entry --> boolean}
  L W ->
    (do (wait-entry.until-> W -1)
        (wait-entry.ack-needed-> W false)
        (listener.wait-used-> L (fx- (listener.wait-used L) 1))
        (mark-slot (listener.wait-map L) (listener.wait-slots L) (wait-entry.index W) false)))

\\ The record of a tuple, by its addresses and ports, or 0.
(define find-wait
  {listener --> net-ipv6.address --> net-ipv6.address --> fixnum --> fixnum --> fixnum --> fixnum}
  L Local Remote LocalPort Port I ->
    (if (fx> I (listener.wait-slots L)) 0
        (let W (wait-at L I)
          (cases (fx< (wait-entry.until W) 0)
                   (find-wait L Local Remote LocalPort Port (skip-free L I (listener.wait-slots L)))
                 (and (= LocalPort (wait-entry.local-port W)) (= Port (wait-entry.remote-port W))
                      (net-ipv6.same? Remote (wait-entry.remote W)) (net-ipv6.same? Local (wait-entry.local W)))
                   I
                 true (find-wait L Local Remote LocalPort Port (fx+ I 1))))))

\\ A segment for a record, read as a peer's are, with the listener's segment and options state.
(define receive-wait
  {listener --> wait-entry --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  L W B T Bytes Now ->
    (let Seg (listener.wait-segment L)
      (and (read-segment (listener.wait-options L) Seg B T Bytes)
           (waiting (segment.flags Seg) W Seg Now))))

\\ RFC 9293 3.10.7.4 and RFC 1337, for a record: a reset is ignored, a segment that takes sequence
\\ space is acknowledged again, and a FIN sent again restarts the wait.
(define waiting
  {fixnum --> wait-entry --> segment --> fixnum --> boolean}
  Flags _ _ _ -> false where (flag? Flags (flag-bits control rst))
  Flags W Seg Now ->
    (do (wait-entry.ack-needed-> W true)
        (if (repeated-fin? Seg (wait-entry.recv-next W)) (wait-entry.until-> W (wait-expiry Now)) W)
        true)
    where (or (fx> (segment.length Seg) 0) (flag? Flags (flag-bits control syn fin)))
  _ _ _ _ -> false)

\\ A record's acknowledgement: its last sequence, and all it received.
(define emit-wait-ack
  {listener --> wait-entry --> net-link.ring --> fixnum --> boolean}
  L W Tx Now ->
    (let H (wait-entry.ip-header W)
         Size (fx+ H (wire.tcp.size))
         B (net-link.ring.data Tx)
         I (net-link.tail-offset Tx)
         T (fx+ I H)
      (do (write-ip-header B I Size H (wait-entry.local W) (wait-entry.remote W))
          (write-layout wire.tcp B T
            (source-port (wait-entry.local-port W)) (destination-port (wait-entry.remote-port W))
            (sequence (seq-number (wait-entry.send-next W)))
            (acknowledgement (seq-number (wait-entry.recv-next W)))
            (data-offset 5) (flags (flag-bits control ack)) (window (wait-entry.window W)))   \\ No options.
          (wire.tcp.checksum-> B T (transport-checksum B I H (wire.tcp.size)))
          (net-link.publish Tx Size (net-link.delivery (listener.device L) Now))
          (wait-entry.ack-needed-> W false)
          true)))

\\ The slot of a connection by its tuple, or 0.
(define find-peer
  {listener --> fixnum --> net-ipv6.address --> net-ipv6.address --> fixnum --> fixnum --> fixnum}
  L LocalPort Local Remote Port I ->
    (if (fx> I (listener.capacity L)) 0
        (let S (slot-at L I) P (listener-slot.peer S)
          (cases (= (listener-slot.lease S) vacant)
                   (find-peer L LocalPort Local Remote Port (skip-vacant L I (listener.capacity L)))
                 (and (= LocalPort (peer.local-port P)) (= Port (peer.remote-port P))
                      (net-ipv6.same? Remote (peer.remote-address P))
                      (net-ipv6.same? Local (peer.local-address P)))
                   I
                 true (find-peer L LocalPort Local Remote Port (fx+ I 1))))))

(define find-vacant
  {listener --> fixnum}
  L -> (let N (listener.capacity L)
            I (next-slot (listener.slot-map L) N 1 N true)
         (if (fx> I N) 0 I)))

\\ HalfSipHash-2-4, over a connection's tuple as tuple-hash gives it: both addresses as IPv6 ones, an IPv4
\\ address mapped, and both ports, 36 bytes. Its state is four words of bytes that nothing else reads, so they
\\ are in the machine's order.
(define rotate32
  {fixnum --> fixnum --> fixnum}
  X Bits -> (add32 (shen-jit.shift-left X Bits) (shen-jit.shift-right X (fx- 32 Bits))))

(define hash-round
  {buffer.storage --> buffer.storage}
  H ->
    (let V0 (shen-jit.u32 H 0)
         V1 (shen-jit.u32 H 4)
         V2 (shen-jit.u32 H 8)
         V3 (shen-jit.u32 H 12)
         A (add32 V0 V1)
         B (shen-jit.bit-xor (rotate32 V1 5) A)
         C (add32 V2 V3)
         D (shen-jit.bit-xor (rotate32 V3 8) C)
         E (add32 (rotate32 A 16) D)
         G (add32 C B)
      (do (shen-jit.u32! H 0 E)
          (shen-jit.u32! H 4 (shen-jit.bit-xor (rotate32 B 13) G))
          (shen-jit.u32! H 8 (rotate32 G 16))
          (shen-jit.u32! H 12 (shen-jit.bit-xor (rotate32 D 7) E)))))

(define hash-word
  {buffer.storage --> fixnum --> buffer.storage}
  H W ->
    (do (shen-jit.u32! H 12 (shen-jit.bit-xor (shen-jit.u32 H 12) W))
        (hash-round (hash-round H))
        (shen-jit.u32! H 0 (shen-jit.bit-xor (shen-jit.u32 H 0) W))))

(define hash-start
  {listener --> buffer.storage}
  L ->
    (let H (listener.hash L)
         K0 (listener.key0 L)
         K1 (listener.key1 L)
      (do (shen-jit.u32! H 0 K0)
          (shen-jit.u32! H 4 K1)
          (shen-jit.u32! H 8 (shen-jit.bit-xor K0 1819895653))
          (shen-jit.u32! H 12 (shen-jit.bit-xor K1 1952801890)))))

(define hash-end
  {buffer.storage --> fixnum --> fixnum}
  H Bytes ->
    (do (hash-word H (shen-jit.shift-left Bytes 24))
        (shen-jit.u32! H 8 (shen-jit.bit-xor (shen-jit.u32 H 8) 255))
        (hash-round (hash-round (hash-round (hash-round H))))
        (shen-jit.bit-xor (shen-jit.u32 H 4) (shen-jit.u32 H 12))))

\\ RFC 6528: a connection's initial sequence number hashes its tuple with the listener's keys.
(define tuple-hash
  {listener --> peer --> fixnum}
  L P ->
    (let H (hash-start L)
      (do (hash-address H (peer.local-address P))
          (hash-address H (peer.remote-address P))
          (hash-word H (fx+ (shen-jit.shift-left (peer.local-port P) 16) (peer.remote-port P)))
          (hash-end H 36))))

(define hash-address
  {buffer.storage --> net-ipv6.address --> buffer.storage}
  H A ->
    (do (hash-word H (net-ipv6.address.a A))
        (hash-word H (net-ipv6.address.b A))
        (hash-word H (net-ipv6.address.c A))
        (hash-word H (net-ipv6.address.d A))))

\\ A table's first ephemeral port comes from its keys and its address.
(define seed-port
  {listener --> listener}
  L -> (let H (hash-start L)
         (do (hash-word H (listener.ip L))
             (hash-word H 0)
             (hash-word H 0)
             (listener.next-port-> L (fx+ 49152 (shen-jit.bit-and (hash-end H 12) 16383))))))

(define make-table
  {net-link.device --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> listener}
  D IP Slots Key0 Key1 Bytes WaitSlots ->
    (if (and (fx>= Bytes 0) (fx<= Bytes 1048576) (fx>= WaitSlots 0) (fx<= WaitSlots 1024))
        (seed-port (new-table D IP 0 Slots 0 Key0 Key1 Bytes WaitSlots))
        (error "tcp: need buffers of 0..1048576 bytes, 0 for eight segments, and 0..1024 TIME-WAIT records")))

(define next-sequence
  {listener --> peer --> fixnum --> fixnum}
  L P Now ->
    (let Seq (listener.next-sequence L)
      (do (listener.next-sequence-> L (add32 Seq 65537))
          (if (= (listener.port L) 0)
              (add32 (tuple-hash L P) (add32 Seq (fx* Now 250)))
              Seq))))

(define configure-peer
  {peer --> fixnum --> net-ipv6.address --> net-ipv6.address --> fixnum --> peer}
  P LocalPort Local Remote Port ->
    (do (peer.ip-header-> P (ip-bytes Remote))
        (net-ipv6.copy-address (peer.local-address P) Local)
        (net-ipv6.copy-address (peer.remote-address P) Remote)
        (peer.remote-port-> P Port)
        (peer.local-port-> P LocalPort)))

(define lease
  {listener --> listener-slot --> lease --> fixnum}
  L S Role ->
    (let Token (fx+ (listener-slot.token S) (listener.capacity L))
      (do (listener-slot.token-> S Token)
          (if (= (listener-slot.lease S) vacant) (listener.used-> L (fx+ (listener.used L) 1)) L)
          (listener-slot.lease-> S Role)
          (mark-slot (listener.slot-map L) (listener.capacity L) (listener-slot.index S) true)
          Token)))

(define admit-segment
  {listener --> listener-slot --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  L S B T Count Now Seq ->
    (let P (listener-slot.peer S)
      (do (listen P Seq)
          (if (receive-valid P B T Count Now)
              (fx> (lease L S pending) 0)
              (do (free-slot L S) false)))))

(define opening-index
  {listener --> buffer.view --> fixnum --> fixnum --> fixnum}
  L B T Count ->
    (if (and (= (segment-flags B T) (flag-bits control syn)) (= Count (header-length B T))) (find-vacant L)
        (fixnum 0)))

(define write-reset
  {buffer.view --> fixnum --> buffer.view --> fixnum --> fixnum --> buffer.view}
  Out At B T Count ->
    (let Flags (segment-flags B T)
         Ack (flag? Flags (flag-bits control ack))
         Space (fx+ (fx- Count (header-length B T))
                    (fx+ (if (flag? Flags (flag-bits control syn)) (fixnum 1) (fixnum 0))
                         (if (flag? Flags (flag-bits control fin)) (fixnum 1) (fixnum 0))))
      (write-layout wire.tcp Out At
        (source-port (wire.tcp.destination-port B T)) (destination-port (wire.tcp.source-port B T))
        (sequence (if Ack (wire.tcp.acknowledgement B T) 0))
        (acknowledgement (if Ack 0 (seq-number (seq-add (seq-of (wire.tcp.sequence B T)) Space))))
        (data-offset 5) (flags (if Ack (flag-bits control rst) (flag-bits control rst ack))))))

(define reset-allowed?
  {net-link.ring --> buffer.view --> fixnum --> boolean}
  Tx B T -> (and (not (flag? (segment-flags B T) (flag-bits control rst))) (not (net-link.full? Tx))))

(define reject-segment
  {listener --> buffer.view --> fixnum --> fixnum --> net-ipv6.address --> net-ipv6.address -->
   fixnum --> boolean}
  L B T Count Local Remote Now ->
    (let D (listener.device L)
         Tx (net-link.device.tx D)
         IpBytes (ip-bytes Remote)
         Size (fx+ IpBytes (wire.tcp.size))
      (if (reset-allowed? Tx B T)
          (let Out (net-link.ring.data Tx)
               At (net-link.tail-offset Tx)
            (do (write-ip-header Out At Size IpBytes Local Remote)
                (write-reset Out (fx+ At IpBytes) B T Count)
                (wire.tcp.checksum-> Out (fx+ At IpBytes) (transport-checksum Out At IpBytes (wire.tcp.size)))
                (net-link.publish Tx Size (net-link.delivery D Now))))
          false)))

(define new-segment
  {listener --> buffer.view --> fixnum --> fixnum --> net-ipv6.address --> net-ipv6.address -->
   fixnum --> fixnum --> fixnum --> boolean --> boolean}
  L B T Count Local Remote LocalPort Port Now Listening ->
    (if (and Listening (not (flag? (segment-flags B T) (flag-bits control ack))))
        (let Index (opening-index L B T Count)
          (and (fx> Index 0)
               (let S (slot-at L Index)
                    P (configure-peer (listener-slot.peer S) LocalPort Local Remote Port)
                 (admit-segment L S B T Count Now (next-sequence L P Now)))))
        (reject-segment L B T Count Local Remote Now)))

\\ A segment for a tuple: to its connection, to its TIME-WAIT record, or as a new one.
(define segment-for
  {listener --> buffer.view --> fixnum --> fixnum --> net-ipv6.address --> net-ipv6.address -->
   fixnum --> fixnum --> fixnum --> boolean --> boolean}
  L B T Bytes Local Remote LocalPort Port Now Listening ->
    (let Index (find-peer L LocalPort Local Remote Port 1)
      (if (fx> Index 0)
          (receive-valid (listener-slot.peer (slot-at L Index)) B T Bytes Now)
          (let Wait (find-wait L Local Remote LocalPort Port 1)
            (if (fx> Wait 0) (receive-wait L (wait-at L Wait) B T Bytes Now)
                (new-segment L B T Bytes Local Remote LocalPort Port Now Listening))))))

(define table-ingress
  {listener --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean --> boolean}
  L B I Count Now Listening ->
    (and (valid-segment? B I Count) (= (wire.ipv4.destination B I) (listener.ip L))
         (let T (fx+ I (wire.ipv4.size))
              IP (wire.ipv4.source B I)
              Port (wire.tcp.source-port B T)
              LocalPort (wire.tcp.destination-port B T)
           (and (endpoint? IP Port) (fx> LocalPort 0)
                (segment-for L B T (fx- Count (wire.ipv4.size)) (listener.local4 L)
                             (net-ipv6.map-ipv4 (listener.input-remote L) IP) LocalPort Port Now Listening)))))

(define table-ingress6
  {listener --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean --> net-ipv6.address --> boolean}
  L B I Count Now Listening LocalIP ->
    (and (fx>= Count (fx+ (wire.ipv6.size) (wire.tcp.size))) (= (wire.ipv6.next-header B I) (wire.tcp-protocol))
         (table-ingress6-at L B I Count (fx+ I (wire.ipv6.size)) Now Listening LocalIP)))

\\ A segment at T, after the base header and any extension headers.
(define table-ingress6-at
  {listener --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> boolean --> net-ipv6.address -->
   boolean}
  L B I Count T Now Listening LocalIP ->
    (let Bytes (fx- (fx+ I Count) T)
      (and (fx>= T (fx+ I (wire.ipv6.size))) (net-ipv6.valid-header? B I Count) (valid-tcp? B T Bytes)
           (= (net-ipv6.transport-checksum-at B I T (wire.tcp-protocol) Bytes) 0)
           (net-ipv6.address-at? LocalIP B (wire.ipv6.destination-at I))
           (let Remote (net-ipv6.read-address (listener.input-remote L) B (wire.ipv6.source-at I))
                Port (wire.tcp.source-port B T)
                LocalPort (wire.tcp.destination-port B T)
             (and (net-ipv6.unicast? Remote) (fx> Port 0) (fx> LocalPort 0)
                  (segment-for L B T Bytes LocalIP Remote LocalPort Port Now Listening))))))

(define listener-ingress
  {listener --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  L B I Count Now ->
    (and (fx>= Count (headers4)) (= (wire.tcp.destination-port B (fx+ I (wire.ipv4.size))) (listener.port L))
         (table-ingress L B I Count Now true)))

(define local-port-in-use?
  {listener --> fixnum --> fixnum --> boolean}
  L Port I ->
    (and (fx<= I (listener.capacity L))
         (let S (slot-at L I)
           (if (= (listener-slot.lease S) vacant)
               (local-port-in-use? L Port (skip-vacant L I (listener.capacity L)))
               (or (= (peer.local-port (listener-slot.peer S)) Port)
                   (local-port-in-use? L Port (fx+ I 1)))))))

(define wait-port-in-use?
  {listener --> fixnum --> fixnum --> boolean}
  L Port I ->
    (and (fx<= I (listener.wait-slots L))
         (let W (wait-at L I)
           (if (fx< (wait-entry.until W) 0)
               (wait-port-in-use? L Port (skip-free L I (listener.wait-slots L)))
               (or (= (wait-entry.local-port W) Port)
                   (wait-port-in-use? L Port (fx+ I 1)))))))

(define claim-port
  {listener --> (list fixnum) --> fixnum --> fixnum}
  _ _ 0 -> 0
  L Reserved Left ->
    (let Port (listener.next-port L)
      (do (listener.next-port-> L (if (= Port 65535) 49152 (fx+ Port 1)))
          (if (or (element? Port Reserved) (local-port-in-use? L Port 1) (wait-port-in-use? L Port 1))
              (claim-port L Reserved (fx- Left 1))
              Port))))

\\ An active open from Local to Port of Remote.
(define open-connection
  {listener --> (list fixnum) --> net-ipv6.address --> net-ipv6.address --> fixnum --> fixnum}
  L Reserved Local Remote Port ->
    (let I (find-vacant L)
         LocalPort (if (= I 0) (fixnum 0) (claim-port L Reserved 16384))
      (if (= LocalPort 0) 0
          (let S (slot-at L I)
               P (configure-peer (listener-slot.peer S) LocalPort Local Remote Port)
            (do (connect P (next-sequence L P (net-link.now (listener.device L))))
                (lease L S leased))))))

(define table-connect
  {listener --> (list fixnum) --> fixnum --> fixnum --> fixnum}
  L Reserved IP Port ->
    (if (endpoint? IP Port)
        (open-connection L Reserved (listener.local4 L) (net-ipv6.map-ipv4 (listener.input-remote L) IP) Port)
        (error "tcp: invalid remote endpoint")))

(define table-connect6
  {listener --> (list fixnum) --> net-ipv6.address --> net-ipv6.address --> fixnum --> fixnum}
  L Reserved LocalIP RemoteIP Port ->
    (if (and (net-ipv6.unicast? LocalIP) (net-ipv6.unicast? RemoteIP)
             (fx>= Port 1) (fx<= Port 65535) (fx>= (net-link.mtu (listener.device L)) (net-ipv6.minimum-mtu)))
        (open-connection L Reserved LocalIP RemoteIP Port)
        (error "tcp: invalid IPv6 endpoints or link MTU below 1280")))

(define expire-addresses6
  {listener --> net-ipv6.address --> boolean --> net-ipv6.address --> boolean --> boolean}
  L Local LocalReady Global GlobalReady ->
    (do (expire-slots6 L Local LocalReady Global GlobalReady 1)
        (expire-waits6 L Local LocalReady Global GlobalReady 1)))

(define usable-address6?
  {net-ipv6.address --> net-ipv6.address --> boolean --> net-ipv6.address --> boolean --> boolean}
  Source Local LocalReady Global GlobalReady ->
    (or (and LocalReady (net-ipv6.same? Source Local))
        (and GlobalReady (net-ipv6.same? Source Global))))

(define expire-slots6
  {listener --> net-ipv6.address --> boolean --> net-ipv6.address --> boolean --> fixnum --> boolean}
  L Local LocalReady Global GlobalReady I ->
    (or (fx> I (listener.capacity L))
        (let S (slot-at L I) P (listener-slot.peer S)
          (if (= (listener-slot.lease S) vacant)
              (expire-slots6 L Local LocalReady Global GlobalReady (skip-vacant L I (listener.capacity L)))
              (do (if (and (= (peer.ip-header P) (wire.ipv6.size)) (not (terminal? P))
                           (not (usable-address6? (peer.local-address P) Local LocalReady Global GlobalReady)))
                      (stop-peer P reset)
                      false)
                  (expire-slots6 L Local LocalReady Global GlobalReady (fx+ I 1)))))))

(define expire-waits6
  {listener --> net-ipv6.address --> boolean --> net-ipv6.address --> boolean --> fixnum --> boolean}
  L Local LocalReady Global GlobalReady I ->
    (or (fx> I (listener.wait-slots L))
        (let W (wait-at L I)
          (if (fx< (wait-entry.until W) 0)
              (expire-waits6 L Local LocalReady Global GlobalReady (skip-free L I (listener.wait-slots L)))
              (do (if (and (= (wait-entry.ip-header W) (wire.ipv6.size))
                           (not (usable-address6? (wait-entry.local W) Local LocalReady Global GlobalReady)))
                      (clear-wait L W)
                      false)
                  (expire-waits6 L Local LocalReady Global GlobalReady (fx+ I 1)))))))

(define listener-input
  {listener --> net-link.ring --> fixnum --> fixnum --> fixnum --> fixnum}
  _ _ _ 0 Done -> Done
  L R Now Budget Done ->
    (if (net-link.ready? R Now)
        (do (listener-ingress L (net-link.ring.data R) (net-link.head-offset R) (net-link.head-length R) Now)
            (net-link.consume R)
            (listener-input L R Now (fx- Budget 1) (fx+ Done 1)))
        Done))

\\ The output of the connections in slots I to Last. Only an actual send moves the start of the next
\\ sweep, even if repeated polls find the ring full.
(define listener-output
  {listener --> fixnum --> fixnum --> fixnum --> boolean}
  L Now I Last ->
    (or (fx> I Last)
        (let S (slot-at L I)
             Lease (listener-slot.lease S)
          (if (= Lease vacant)
              (listener-output L Now (skip-vacant L I Last) Last)
              (let P (listener-slot.peer S)
                (do (if (drive-output P Now) (listener.next-output-> L (next-index L I)) L)
                    (if (and (= Lease pending) (terminal? P)) (free-slot L S) true)
                    (listener-output L Now (fx+ I 1) Last)))))))

(define wait-output
  {listener --> net-link.ring --> fixnum --> fixnum --> fixnum --> boolean}
  L Tx Now I Last ->
    (or (fx> I Last)
        (let W (wait-at L I)
          (if (fx< (wait-entry.until W) 0)
              (wait-output L Tx Now (skip-free L I Last) Last)
              (do (transmit-wait L W Tx Now (if (= I (listener.wait-slots L)) (fixnum 1) (fx+ I 1)))
                  (wait-output L Tx Now (fx+ I 1) Last))))))

(define transmit-wait
  {listener --> wait-entry --> net-link.ring --> fixnum --> fixnum --> boolean}
  L W Tx Now Next ->
    (do (if (and (wait-entry.ack-needed W) (not (net-link.full? Tx)))
            (do (emit-wait-ack L W Tx Now) (listener.next-wait-output-> L Next))
            L)
        (if (and (not (wait-entry.ack-needed W)) (fx>= Now (wait-entry.until W)))
            (clear-wait L W)
            true)))

\\ A sweep starts where the last one sent, and goes round the slots once.
(define table-output
  {listener --> fixnum --> boolean}
  L Now -> (let Start (listener.next-output L)
             (do (listener-output L Now Start (listener.capacity L))
                 (listener-output L Now 1 (fx- Start 1)))))

(define records-output
  {listener --> net-link.ring --> fixnum --> boolean}
  L Tx Now -> (let Start (listener.next-wait-output L)
                (do (wait-output L Tx Now Start (listener.wait-slots L))
                    (wait-output L Tx Now 1 (fx- Start 1)))))

(define listener-transmit
  {listener --> fixnum --> boolean}
  L Now ->
    (if (= (listener.wait-used L) 0)
        (table-output L Now)
        (let Tx (net-link.device.tx (listener.device L))
             First (listener.wait-first L)
          \\ Streams and records take turns going first, as a full send ring could stall either.
          (do (if First (records-output L Tx Now) false)
              (table-output L Now)
              (if First false (records-output L Tx Now))
              (listener.wait-first-> L (not First))
              true))))

(define output-ready?
  {peer --> boolean}
  P ->
    (let Flight (peer.tx-flight P)
         Window (peer.remote-window P)
         End (net-link.smaller Flight (if (= Window 0) 1 Window))
         Replay (peer.tx-replay P)
         Repair (peer.sack-next-repair P)
         Credit (fx- (peer.cwnd P) (peer.sack-pipe P))
      (or (peer.aborting P)
          (peer.ack-needed P)
          (fx> (peer.rx-duplicate-acks P) 0)
          (if (not (= (peer.tx-flags P) 0)) (fx< (peer.tx-due P) 0)
              (or (and (fx>= Replay 0) (fx< Replay (net-link.smaller End (peer.cwnd P))))
                  (and (fx> Window 0)
                       (or (and (peer.tx-fast-retransmit P) (fx> End 0)
                                (or (not (sack-recovering? P)) (fx> Credit 0)))
                           (and (fx>= Repair 0) (fx< Repair End) (fx> Credit 0))))
                  (and (fx> (peer.tx-length P) Flight)
                       (or (and (= Flight 0) (= Window 0))
                           (fx> (net-link.smaller Window (peer.cwnd P)) (net-link.larger Flight (peer.sack-pipe P))))))))))

(define peer-deadline
  {peer --> fixnum --> boolean --> fixnum}
  P Now Writable ->
    (let Due (peer.tx-due P)
         Wait (if (and (= (state P) time-wait) (not (peer.ack-needed P)))
                  (peer.wait-until P) (fixnum -1))
      (if (and Writable (output-ready? P)) Now
          (net-link.earlier Wait (if (or Writable (fx>= (peer.tx-retries P) (max-retries))) Due (fixnum -1))))))

(define table-deadline
  {listener --> fixnum --> boolean --> fixnum --> fixnum --> fixnum}
  L Now Writable I At ->
    (if (fx> I (listener.capacity L)) At
        (let S (slot-at L I)
          (if (= (listener-slot.lease S) vacant)
              (table-deadline L Now Writable (skip-vacant L I (listener.capacity L)) At)
              (table-deadline L Now Writable (fx+ I 1)
                              (net-link.earlier At (peer-deadline (listener-slot.peer S) Now Writable)))))))

(define listener-deadline
  {listener --> fixnum --> fixnum}
  L Now ->
    (let Writable (not (net-link.full? (net-link.device.tx (listener.device L))))
         Due (table-deadline L Now Writable 1 -1)
      (if (= (listener.wait-used L) 0) Due (wait-deadline L Now Writable 1 Due))))

(define wait-deadline
  {listener --> fixnum --> boolean --> fixnum --> fixnum --> fixnum}
  L Now Writable I At ->
    (if (fx> I (listener.wait-slots L)) At
        (let W (wait-at L I)
          (if (fx< (wait-entry.until W) 0)
              (wait-deadline L Now Writable (skip-free L I (listener.wait-slots L)) At)
              (let Due (if (wait-entry.ack-needed W) (if Writable Now (fixnum -1)) (wait-entry.until W))
                (wait-deadline L Now Writable (fx+ I 1) (net-link.earlier At Due)))))))

(define listener-poll
  {listener --> fixnum --> fixnum}
  L Budget ->
    (let D (listener.device L)
         Now (net-link.now D)
         Count (listener-input L (net-link.device.rx D) Now (buffer.index Budget) 0)
      (do (listener-transmit L Now)
          Count)))

\\ The token of the first connection of slots I to Last ready to accept, or 0.
(define accept-ready
  {listener --> fixnum --> fixnum --> fixnum --> fixnum}
  L Port I Last ->
    (if (fx> I Last) 0
        (let S (slot-at L I) P (listener-slot.peer S) Phase (state P)
          (cases (= (listener-slot.lease S) vacant) (accept-ready L Port (skip-vacant L I Last) Last)
                 (and (= (listener-slot.lease S) pending)
                      (or (= Port 0) (= Port (peer.local-port P)))
                      (can-send? Phase))
                   (do (listener-slot.lease-> S leased)
                       (listener.next-accept-> L (next-index L I))
                       (listener-slot.token S))
                 true (accept-ready L Port (fx+ I 1) Last)))))

(define accept
  {listener --> fixnum}
  L -> (accept-on L 0))

\\ From the slot after the last accepted, round the slots once.
(define accept-on
  {listener --> fixnum --> fixnum}
  L Port -> (let Start (listener.next-accept L)
                 Token (accept-ready L Port Start (listener.capacity L))
              (if (= Token 0) (accept-ready L Port 1 (fx- Start 1)) Token)))

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
  {listener --> fixnum --> phase}
  L Token -> (state (listener-slot.peer (lease-slot L Token))))

(define connection-readable?
  {listener --> fixnum --> boolean}
  L Token -> (let P (listener-slot.peer (lease-slot L Token))
               (or (fx> (peer.rx-length P) 0) (peer.recv-eof P) (terminal? P))))

(define connection-writable?
  {listener --> fixnum --> boolean}
  L Token -> (let P (listener-slot.peer (lease-slot L Token)) Phase (state P)
               (and (can-send? Phase) (fx< (peer.tx-length P) (peer.capacity P)))))

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
           (and (fx< (seq-distance (seq-of Seq) (send-una P)) (peer.tx-flight P))
                (fx< Mtu (peer.path-mtu P))
                (do (peer.path-mtu-> P Mtu)
                    (peer.send-mss-> P (net-link.smaller (peer.send-mss P) (fx- Mtu (minimum-header P))))
                    (peer.tx-due-> P Now)
                    true)))))

(define path-mtu
  {listener --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  L B I Count Mtu Now ->
    (let T (fx+ I (wire.ipv4.size))                       \\ The quote: our IP header, then 8 bytes of TCP.
      (and (fx>= Count (fx+ (wire.ipv4.size) 8))
           (= (wire.ipv4.version B I) 4) (= (wire.ipv4.header-length B I) 5)
           (= (wire.ipv4.protocol B I) (wire.tcp-protocol))
           (= (wire.ipv4.source B I) (listener.ip L))
           (= (net-ipv4.packet-checksum B I (wire.ipv4.size)) 0)
           (fx>= Mtu 68) (fx< Mtu (wire.ipv4.total-length B I))              \\ RFC 791: every link carries 68 bytes.
           (reduce-mtu L (find-peer L (wire.tcp.source-port B T) (listener.local4 L)
                                    (net-ipv6.map-ipv4 (listener.input-remote L) (wire.ipv4.destination B I))
                                    (wire.tcp.destination-port B T) 1)
                       (wire.tcp.sequence B T) Mtu Now))))

(define path-mtu6
  {listener --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> net-ipv6.address --> boolean}
  L B I Count Mtu Now LocalIP ->
    (let T (fx+ I (wire.ipv6.size))                       \\ The quote: our IPv6 header, then TCP's first 8 bytes.
      (and (fx>= Count (fx+ (wire.ipv6.size) 8))
           (= (wire.ipv6.version B I) 6)
           (= (wire.ipv6.next-header B I) (wire.tcp-protocol))
           (net-ipv6.address-at? LocalIP B (wire.ipv6.source-at I))
           (fx>= Mtu (net-ipv6.minimum-mtu)) (fx< Mtu (fx+ (wire.ipv6.size) (wire.ipv6.payload-length B I)))
           (let Remote (net-ipv6.read-address (listener.input-remote L) B (wire.ipv6.destination-at I))
             (reduce-mtu L (find-peer L (wire.tcp.source-port B T) LocalIP Remote
                                       (wire.tcp.destination-port B T) 1)
                         (wire.tcp.sequence B T) Mtu Now)))))

(define release
  {listener --> fixnum --> boolean}
  L Token -> (let S (lease-slot L Token)
                   P (listener-slot.peer S)
               (and (or (terminal? P) (and (= (state P) time-wait) (save-wait L P)))
                    (free-slot L S))))

(preclude [peer.%match listener.%match listener-slot.%match wait-entry.%match])
)
