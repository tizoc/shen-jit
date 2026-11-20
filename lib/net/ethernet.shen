\\ IPv4 and IPv6 over Ethernet, with fixed queues for pending address resolution.
(shen.x.namespace net-ethernet
  (use buffer)
  (use net-link)
  (use net-ipv4)
  (use net-ipv6)
  (use net-ndp)
  (use net-routes)
  (use shen-jit)
  (use net-wire => wire)
  (import struct defstruct)
  (import layout write-layout)
  (export adapter make configure enable-ipv6 pump next-deadline hardware adapter.dropped)

(defstruct neighbor
  (pending : net-link.ring)
  (mutable ip : fixnum)
  (mutable mac : fixnum)
  (mutable expires : fixnum)
  (mutable request-at : fixnum))

(defstruct adapter
  (frames : net-link.device)
  (packets : net-link.device)
  (mac : fixnum)
  (neighbors : (vector neighbor))
  (slots : fixnum)
  (mutable ip : fixnum)
  (mutable ipv6 : (list net-ndp.host))
  (mutable next6 : fixnum)
  (mutable ipv6-first : boolean)
  (mutable routes : (list net-routes.route))
  (mutable next : fixnum)
  (mutable dropped : fixnum))

(define hardware
  {fixnum --> fixnum --> fixnum}
  High Low ->
    (if (and (fx>= High 0) (fx<= High 65535) (fx>= Low 0) (fx<= Low 4294967295))
        (wire.mac High Low)
        (error "net/ethernet: MAC address is wider than 48 bits")))

\\ ff:ff:ff:ff:ff:ff, every station on the link.
(define broadcast-mac
  {--> fixnum}
  -> 281474976710655)

\\ How long a neighbor's address is kept without a new answer.
(define neighbor-lifetime
  {--> fixnum}
  -> 60000)

(define setup
  {(vector neighbor) --> fixnum --> fixnum --> (vector neighbor)}
  V 0 _ -> V
  V I Mtu ->
    (let N (:neighbor
              pending <- (net-link.make-ring 4 Mtu)
              ip <- 0
              mac <- 0
              expires <- 0
              request-at <- 0)
      (setup (fxvector-> V I N) (fx- I 1) Mtu)))

(define make
  {net-link.device --> net-link.device --> fixnum --> fixnum --> (list net-routes.route) -->
   fixnum --> adapter}
  Frames Packets Mac IP Routes Slots ->
    (let Mtu (net-link.mtu Packets)
      (if (and (fx>= Mtu 68) (fx>= (net-link.mtu Frames) (fx+ Mtu (wire.ethernet.size)))
               (wire.station-mac? Mac) (or (= IP 0) (net-ipv4.unicast? IP))
               (fx>= Slots 1) (fx<= Slots 256))
          (:adapter
            frames <- Frames
            packets <- Packets
            mac <- Mac
            neighbors <- (setup (vector (fx->number Slots)) Slots Mtu)
            slots <- Slots
            ip <- IP
            ipv6 <- []
            next6 <- 1
            ipv6-first <- false
            routes <- Routes
            next <- 1
            dropped <- 0)
          (error "net/ethernet: invalid address, MTU, or neighbor capacity"))))

(define enable-ipv6
  {adapter --> net-ndp.host --> boolean}
  A H ->
    (let Cable (adapter.packets A)
         Interface (net-ndp.host.device H)
      (if (and (= (adapter.ipv6 A) []) (= (adapter.mac A) (net-ndp.host.mac H))
               (= (net-link.device.tx Cable) (net-link.device.rx Interface))
               (= (net-link.device.rx Cable) (net-link.device.tx Interface)))
          (do (adapter.ipv6-> A [H]) true)
          (error "net/ethernet: enable IPv6 once with this MAC and the opposite IP link device"))))

(define neighbor-at
  {adapter --> fixnum --> neighbor}
  A I -> (fx<-vector (adapter.neighbors A) I))

(define clear-pending
  {net-link.ring --> boolean}
  R -> (if (net-link.ready? R 0) (do (net-link.consume R) (clear-pending R)) true))

(define clear-neighbor
  {neighbor --> boolean}
  N -> (do (clear-pending (neighbor.pending N))
           (neighbor.ip-> N 0)
           (neighbor.mac-> N 0)
           (neighbor.expires-> N 0)
           true))

(define flush-cache
  {adapter --> fixnum --> boolean}
  _ 0 -> true
  A I -> (do (clear-neighbor (neighbor-at A I))
             (flush-cache A (fx- I 1))))

(define configure
  {adapter --> fixnum --> (list net-routes.route) --> boolean}
  A IP Routes ->
    (if (or (= IP 0) (net-ipv4.unicast? IP))
        (do (adapter.ip-> A IP)
            (adapter.routes-> A Routes)
            (flush-cache A (adapter.slots A)))
        (error "net/ethernet: invalid local IPv4 address")))

(define note-drop
  {adapter --> boolean}
  A -> (do (adapter.dropped-> A (fx+ (adapter.dropped A) 1)) true))

(define find
  {adapter --> fixnum --> fixnum --> fixnum}
  _ _ 0 -> 0
  A IP I -> (if (= IP (neighbor.ip (neighbor-at A I))) I (find A IP (fx- I 1))))

(define replaceable
  {adapter --> fixnum --> fixnum --> fixnum --> fixnum}
  _ _ 0 Slot -> Slot
  A Now I Slot ->
    (let N (neighbor-at A I)
      (cases (= (neighbor.ip N) 0) I
             (fx<= (neighbor.expires N) Now) I
             (and (fx> (neighbor.mac N) 0) (not (net-link.ready? (neighbor.pending N) 0))
                  (or (= Slot 0) (fx< (neighbor.expires N) (neighbor.expires (neighbor-at A Slot)))))
               (replaceable A Now (fx- I 1) I)
             true (replaceable A Now (fx- I 1) Slot))))

(define claim
  {adapter --> fixnum --> fixnum --> fixnum}
  A IP Now ->
    (let Known (find A IP (adapter.slots A))
         I (if (= Known 0) (replaceable A Now (adapter.slots A) 0) Known)
      (if (= I 0) 0
          (let N (neighbor-at A I)
            (do (if (or (= Known 0) (fx<= (neighbor.expires N) Now))
                    (do (clear-neighbor N)
                        (neighbor.ip-> N IP)
                        (neighbor.expires-> N (fx+ Now 3000))
                        (neighbor.request-at-> N Now)
                        true)
                    true)
                I)))))

(define pad
  {buffer.view --> fixnum --> fixnum --> buffer.view}
  B I End -> (if (= I End) B (pad (buffer.u8-> B I 0) (fx+ I 1) End)))

(define ethernet-header
  {adapter --> buffer.view --> fixnum --> fixnum --> fixnum --> buffer.view}
  A B At Dst Kind -> (write-layout wire.ethernet B At (destination Dst) (source (adapter.mac A)) (ethertype Kind)))

\\ The shortest frame, without its check sequence: shorter ones are padded.
(define minimum-frame
  {--> fixnum}
  -> 60)

(define arp
  {adapter --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  A TargetIP TargetMac Dst Op Now ->
    (let D (adapter.frames A)
         Tx (net-link.device.tx D)
      (if (net-link.full? Tx) false
          (let B (net-link.ring.data Tx)
               I (net-link.tail-offset Tx)
               Start (fx+ I (wire.ethernet.size))
            (do (ethernet-header A B I Dst (wire.arp-type))
                (write-layout wire.arp B Start
                  (hardware-type 1) (protocol-type (wire.ipv4-type)) (hardware-length 6) (protocol-length 4) (operation Op)
                  (sender-hardware (adapter.mac A)) (sender-protocol (adapter.ip A))
                  (target-hardware TargetMac) (target-protocol TargetIP))
                (pad B (fx+ Start (wire.arp.size)) (fx+ I (minimum-frame)))
                (net-link.publish Tx (minimum-frame) (net-link.delivery D Now)))))))

(define learn
  {adapter --> fixnum --> fixnum --> fixnum --> boolean}
  A IP Mac Now ->
    (let I (claim A IP Now)
      (if (= I 0) false
          (let N (neighbor-at A I)
            (do (neighbor.mac-> N Mac)
                (neighbor.expires-> N (fx+ Now (neighbor-lifetime)))
                true)))))

(define arp-input
  {adapter --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  A B I N Now ->
    (let S (fx+ I (wire.ethernet.size))
      (and (fx>= N (fx+ (wire.ethernet.size) (wire.arp.size))) (fx> (adapter.ip A) 0)
           (= (wire.arp.hardware-type B S) 1) (= (wire.arp.protocol-type B S) (wire.ipv4-type))      \\ IPv4 over Ethernet.
           (= (wire.arp.hardware-length B S) 6) (= (wire.arp.protocol-length B S) 4)
           (= (wire.arp.target-protocol B S) (adapter.ip A))
           (let Op (wire.arp.operation B S)
                Mac (wire.arp.sender-hardware B S)
                IP (wire.arp.sender-protocol B S)
             (and (wire.station-mac? Mac) (= Mac (wire.ethernet.source B I))
                (cases (= Op 1)
                         (do (if (net-ipv4.unicast? IP) (learn A IP Mac Now) true)
                             (arp A IP Mac Mac 2 Now))
                       (= Op 2)
                         (and (= (wire.arp.target-hardware B S) (adapter.mac A))
                              (net-ipv4.unicast? IP) (fx> (find A IP (adapter.slots A)) 0)
                              (learn A IP Mac Now))
                       true false))))))

(define receive-ip
  {adapter --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  A B I N Count Now ->
    (let D (adapter.packets A)
         Tx (net-link.device.tx D)
      (and (fx<= Count N) (fx<= Count (net-link.mtu D))
           (if (net-link.full? Tx) (do (note-drop A) false)
               (do (buffer.copy-into! (net-link.ring.data Tx) (net-link.tail-offset Tx) B I Count)
                   (net-link.publish Tx Count (net-link.delivery D Now)))))))

(define frame-input
  {adapter --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  A B I N Now ->
    (and (fx>= N (wire.ethernet.size))
         (let Dst (wire.ethernet.destination B I)
              Kind (wire.ethernet.ethertype B I)
              IP (fx+ I (wire.ethernet.size))
              Payload (fx- N (wire.ethernet.size))
              Ours (= Dst (adapter.mac A))
              Broadcast (= Dst (broadcast-mac))
           (cases (and (= Kind (wire.arp-type)) (or Ours Broadcast)) (arp-input A B I N Now)
                  (and (= Kind (wire.ipv4-type)) (fx>= Payload (wire.ipv4.size))
                       (= (wire.ipv4.version B IP) 4)
                       (or Ours Broadcast
                           (let Address (wire.ipv4.destination B IP)                          \\ Or a group
                             (and (net-ipv4.multicast? Address) (= Dst (net-ipv4.multicast-mac Address))))))
                    (let Count (wire.ipv4.total-length B IP)
                      (and (fx>= Count (wire.ipv4.size)) (receive-ip A B IP Payload Count Now)))
                  (and (= Kind (wire.ipv6-type)) (fx>= Payload (wire.ipv6.size)) (not (= (adapter.ipv6 A) []))
                       (= (wire.ipv6.version B IP) 6)
                       (or Ours (and (net-ipv6.multicast-at? B (wire.ipv6.destination-at IP))    \\ Multicast,
                                     (= Dst (net-ipv6.multicast-mac-at B (wire.ipv6.destination-at IP))))))  \\ to our group.
                    (receive-ip A B IP Payload (fx+ (wire.ipv6.size) (wire.ipv6.payload-length B IP)) Now)
                  true false))))

(define rx-frames
  {adapter --> net-link.ring --> fixnum --> fixnum --> fixnum --> fixnum}
  _ _ _ 0 Done -> Done
  A R Now Left Done ->
    (if (net-link.ready? R Now)
        (do (frame-input A (net-link.ring.data R) (net-link.head-offset R) (net-link.head-length R) Now)
            (net-link.consume R)
            (rx-frames A R Now (fx- Left 1) (fx+ Done 1)))
        Done))

(define send-ip
  {adapter --> net-link.ring --> fixnum --> fixnum --> fixnum --> boolean}
  A R Mac Kind Now ->
    (let D (adapter.frames A)
         Tx (net-link.device.tx D)
      (if (net-link.full? Tx) false
          (let B (net-link.ring.data Tx)
               At (net-link.tail-offset Tx)
               N (net-link.head-length R)
               Len (fx+ N (wire.ethernet.size))
               Wire (if (fx>= Len (minimum-frame)) Len (minimum-frame))
            (do (ethernet-header A B At Mac Kind)
                (buffer.copy-into! B (fx+ At (wire.ethernet.size)) (net-link.ring.data R) (net-link.head-offset R) N)
                (pad B (fx+ At Len) (fx+ At Wire))
                (net-link.publish Tx Wire (net-link.delivery D Now)))))))

(define stash
  {adapter --> net-link.ring --> net-link.ring --> boolean}
  A R Q ->
    (if (net-link.full? Q) (note-drop A)
        (let N (net-link.head-length R)
          (do (buffer.copy-into! (net-link.ring.data Q) (net-link.tail-offset Q)
                                (net-link.ring.data R) (net-link.head-offset R) N)
              (net-link.publish Q N 0)))))

(define emit-ipv4
  {adapter --> net-link.ring --> fixnum --> boolean}
  A R Now ->
    (if (fx< (net-link.head-length R) (wire.ipv4.size)) (note-drop A)
        (let Dst (wire.ipv4.destination (net-link.ring.data R) (net-link.head-offset R))
             Hop (net-routes.lookup (adapter.routes A) Dst)
          (cases (= Dst (net-ipv4.broadcast)) (send-ip A R (broadcast-mac) (wire.ipv4-type) Now)
                 (net-ipv4.multicast? Dst) (send-ip A R (net-ipv4.multicast-mac Dst) (wire.ipv4-type) Now)
                 (= Hop 0) (note-drop A)
                 true (let I (claim A Hop Now)
                         (if (= I 0) (note-drop A)
                             (let N (neighbor-at A I)
                                  Q (neighbor.pending N)
                               (if (and (fx> (neighbor.mac N) 0) (not (net-link.ready? Q 0)))
                                   (send-ip A R (neighbor.mac N) (wire.ipv4-type) Now)
                                   (stash A R Q)))))))))

(define emit-ipv6
  {adapter --> (list net-ndp.host) --> net-link.ring --> fixnum --> boolean}
  A [] _ _ -> (note-drop A)
  A [H] R Now ->
    (if (fx< (net-link.head-length R) (wire.ipv6.size)) (note-drop A)
        (let B (net-link.ring.data R)
             At (wire.ipv6.destination-at (net-link.head-offset R))
          (if (net-ipv6.multicast-at? B At)
              (send-ip A R (net-ipv6.multicast-mac-at B At) (wire.ipv6-type) Now)
              (let I (net-ndp.route H B At Now)
                (if (= I 0) (note-drop A)
                    (let N (net-ndp.neighbor-at H I)
                         Q (net-ndp.neighbor.pending N)
                      (if (and (fx> (net-ndp.neighbor.mac N) 0) (not (net-link.ready? Q 0)))
                          (send-ip A R (net-ndp.neighbor.mac N) (wire.ipv6-type) Now)
                          (stash A R Q)))))))))

(define emit-ip
  {adapter --> net-link.ring --> fixnum --> boolean}
  A R Now ->
    (if (= (net-link.head-length R) 0) (note-drop A)
        (let Version (wire.ipv4.version (net-link.ring.data R) (net-link.head-offset R))   \\ Where IPv6's is too.
          (cases (= Version 4) (emit-ipv4 A R Now)
                 (= Version 6) (emit-ipv6 A (adapter.ipv6 A) R Now)
                 true (note-drop A)))))

(define tx-packets
  {adapter --> net-link.ring --> fixnum --> fixnum --> fixnum --> fixnum}
  _ _ _ 0 Done -> Done
  A R Now Left Done ->
    (if (and (net-link.ready? R Now) (emit-ip A R Now))
        (do (net-link.consume R)
            (tx-packets A R Now (fx- Left 1) (fx+ Done 1)))
        Done))

(define next-index
  {adapter --> fixnum --> fixnum}
  A I -> (if (= I (adapter.slots A)) 1 (fx+ I 1)))

(define work-neighbor
  {adapter --> neighbor --> fixnum --> boolean}
  A N Now ->
    (let Q (neighbor.pending N)
      (cases (not (net-link.ready? Q 0)) false
             (fx<= (neighbor.expires N) Now) (do (clear-neighbor N) (note-drop A))
             (fx> (neighbor.mac N) 0) (and (send-ip A Q (neighbor.mac N) (wire.ipv4-type) Now) (net-link.consume Q))
             (fx<= (neighbor.request-at N) Now)
               (and (arp A (neighbor.ip N) 0 (broadcast-mac) 1 Now)
                    (do (neighbor.request-at-> N (fx+ Now 1000)) true))
             true false)))

(define drain
  {adapter --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum}
  _ _ _ 0 _ Done -> Done
  _ _ _ _ 0 Done -> Done
  A Now I Left Budget Done ->
    (let Next (next-index A I)
      (if (work-neighbor A (neighbor-at A I) Now)
          (do (adapter.next-> A Next)
              (drain A Now Next (fx- Left 1) (fx- Budget 1) (fx+ Done 1)))
          (drain A Now Next (fx- Left 1) Budget Done))))

(define drain6
  {adapter --> net-ndp.host --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum}
  _ _ _ _ 0 _ Done -> Done
  _ _ _ _ _ 0 Done -> Done
  A H Now I Left Budget Done ->
    (let N (net-ndp.neighbor-at H I)
         Next (if (= I (net-ndp.host.slots H)) (fixnum 1) (fx+ I 1))
         Pending (net-ndp.neighbor.pending N)
      (if (and (net-ndp.neighbor-ready? N Now) (send-ip A Pending (net-ndp.neighbor.mac N) (wire.ipv6-type) Now))
          (do (net-link.consume Pending)
              (adapter.next6-> A Next)
              (drain6 A H Now Next (fx- Left 1) (fx- Budget 1) (fx+ Done 1)))
          (drain6 A H Now Next (fx- Left 1) Budget Done))))

(define drain-ipv6
  {adapter --> (list net-ndp.host) --> fixnum --> fixnum --> fixnum}
  _ [] _ _ -> 0
  A [H] Now Budget -> (drain6 A H Now (adapter.next6 A) (net-ndp.host.slots H) Budget 0))

\\ Alternate resolved ARP and NDP queues when the frame ring has limited space.
(define drain-pending
  {adapter --> fixnum --> fixnum --> fixnum}
  A Now Budget ->
    (let V6 (adapter.ipv6 A)
         First (adapter.ipv6-first A)
         Next (adapter.next A)
         Slots (adapter.slots A)
      (cases (= V6 []) (drain A Now Next Slots Budget 0)
             First (let Six (drain-ipv6 A V6 Now Budget)
                         Four (drain A Now Next Slots Budget 0)
                       (do (adapter.ipv6-first-> A false) (fx+ Six Four)))
             true (let Four (drain A Now Next Slots Budget 0)
                        Six (drain-ipv6 A V6 Now Budget)
                      (do (adapter.ipv6-first-> A true) (fx+ Four Six))))))

(define pump
  {adapter --> fixnum --> fixnum}
  A Budget ->
    (let Now (net-link.now (adapter.frames A))
         Limit (buffer.index Budget)
         Received (rx-frames A (net-link.device.rx (adapter.frames A)) Now Limit 0)
         Sent (drain-pending A Now Limit)
         Queued (tx-packets A (net-link.device.rx (adapter.packets A)) Now Limit 0)
      (fx+ (fx+ Received Queued) Sent)))

(define neighbor-deadline
  {adapter --> fixnum --> boolean --> fixnum --> fixnum --> fixnum}
  _ _ _ 0 At -> At
  A Now Free I At ->
    (let N (neighbor-at A I)
         Due (if (net-link.ready? (neighbor.pending N) 0)
                 (net-link.earlier (neighbor.expires N)
                          (if Free (if (fx> (neighbor.mac N) 0) Now (neighbor.request-at N))
                              (fixnum -1)))
                 (fixnum -1))
      (neighbor-deadline A Now Free (fx- I 1) (net-link.earlier At Due))))

(define pending-ipv6?
  {net-ndp.host --> fixnum --> fixnum --> boolean}
  _ 0 _ -> false
  H I Now ->
    (or (net-ndp.neighbor-ready? (net-ndp.neighbor-at H I) Now)
        (pending-ipv6? H (fx- I 1) Now)))

(define ready6?
  {(list net-ndp.host) --> fixnum --> boolean}
  [] _ -> false
  [H] Now -> (pending-ipv6? H (net-ndp.host.slots H) Now))

(define next-deadline
  {adapter --> fixnum}
  A ->
    (let Frames (adapter.frames A)
         Now (net-link.now Frames)
         Rx (net-link.head-deadline (net-link.device.rx Frames))
         Free (not (net-link.full? (net-link.device.tx Frames)))
         Tx (if Free (net-link.head-deadline (net-link.device.rx (adapter.packets A))) (fixnum -1))
      (if (and Free (ready6? (adapter.ipv6 A) Now)) (net-link.earlier (net-link.earlier Rx Tx) Now)
          (neighbor-deadline A Now Free (adapter.slots A) (net-link.earlier Rx Tx)))))

(preclude [neighbor.%match adapter.%match])
)
