\\ IPv4 over Ethernet. ARP resolution owns a bounded pending queue per neighbor.
(shen.x.namespace net-ethernet
  (use buffer)
  (use net-link)
  (use net-ipv4)
  (use net-routes)
  (use shen-jit)
  (import struct defstruct)
  (export adapter make configure pump next-deadline hardware adapter.dropped)

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
  (mutable routes : (list net-routes.route))
  (mutable next : fixnum)
  (mutable dropped : fixnum))

(define hardware
  {fixnum --> fixnum --> fixnum}
  High Low ->
    (if (and (fx>= High 0) (fx<= High 65535) (fx>= Low 0) (fx<= Low 4294967295))
        (fx+ (shen-jit.shift-left High 32) Low)
        (error "net/ethernet: MAC address is wider than 48 bits")))

(define read-mac
  {buffer.view --> fixnum --> fixnum}
  B I -> (hardware (buffer.u16-be B I) (buffer.u32-be B (fx+ I 2))))

(define write-mac
  {buffer.view --> fixnum --> fixnum --> buffer.view}
  B I Mac ->
    (do (buffer.u16-be-> B I (shen-jit.shift-right Mac 32))
        (buffer.u32-be-> B (fx+ I 2) (shen-jit.bit-and Mac 4294967295))))

(define unicast-mac?
  {fixnum --> boolean}
  Mac -> (and (fx> Mac 0) (fx<= Mac 281474976710655)
              (= (shen-jit.bit-and Mac 1099511627776) 0)))

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
      (if (and (fx>= Mtu 68) (fx>= (net-link.mtu Frames) (fx+ Mtu 14))
               (unicast-mac? Mac) (or (= IP 0) (net-ipv4.unicast? IP))
               (fx>= Slots 1) (fx<= Slots 256))
          (:adapter
            frames <- Frames
            packets <- Packets
            mac <- Mac
            neighbors <- (setup (vector (fx->number Slots)) Slots Mtu)
            slots <- Slots
            ip <- IP
            routes <- Routes
            next <- 1
            dropped <- 0)
          (error "net/ethernet: invalid address, MTU, or neighbor capacity"))))

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
  A B At Dst Kind ->
    (do (write-mac B At Dst)
        (write-mac B (fx+ At 6) (adapter.mac A))
        (buffer.u16-be-> B (fx+ At 12) Kind)))

(define arp
  {adapter --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  A TargetIP TargetMac Dst Op Now ->
    (let D (adapter.frames A)
         Tx (net-link.device.tx D)
      (if (net-link.full? Tx) false
          (let B (net-link.ring.data Tx)
               I (net-link.tail-offset Tx)
               Start (fx+ I 14)
            (do (ethernet-header A B I Dst 2054)
                (buffer.u32-be-> B Start 67584)
                (buffer.u16-be-> B (fx+ Start 4) 1540)
                (buffer.u16-be-> B (fx+ Start 6) Op)
                (write-mac B (fx+ Start 8) (adapter.mac A))
                (buffer.u32-be-> B (fx+ Start 14) (adapter.ip A))
                (write-mac B (fx+ Start 18) TargetMac)
                (buffer.u32-be-> B (fx+ Start 24) TargetIP)
                (pad B (fx+ I 42) (fx+ I 60))
                (net-link.publish Tx 60 (net-link.delivery D Now)))))))

(define learn
  {adapter --> fixnum --> fixnum --> fixnum --> boolean}
  A IP Mac Now ->
    (let I (claim A IP Now)
      (if (= I 0) false
          (let N (neighbor-at A I)
            (do (neighbor.mac-> N Mac)
                (neighbor.expires-> N (fx+ Now 60000))
                true)))))

(define arp-input
  {adapter --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  A B I N Now ->
    (and (fx>= N 42) (fx> (adapter.ip A) 0)
         (= (buffer.u32-be B (fx+ I 14)) 67584)
         (= (buffer.u16-be B (fx+ I 18)) 1540)
         (= (buffer.u32-be B (fx+ I 38)) (adapter.ip A))
         (let Op (buffer.u16-be B (fx+ I 20))
              Mac (read-mac B (fx+ I 22))
              IP (buffer.u32-be B (fx+ I 28))
           (and (unicast-mac? Mac) (= Mac (read-mac B (fx+ I 6)))
                (cases (= Op 1)
                         (do (if (net-ipv4.unicast? IP) (learn A IP Mac Now) true)
                             (arp A IP Mac Mac 2 Now))
                       (= Op 2)
                         (and (= (read-mac B (fx+ I 32)) (adapter.mac A))
                              (net-ipv4.unicast? IP) (fx> (find A IP (adapter.slots A)) 0)
                              (learn A IP Mac Now))
                       true false)))))

(define receive-ip
  {adapter --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  A B I N Now ->
    (let D (adapter.packets A)
         Tx (net-link.device.tx D)
         Count (buffer.u16-be B (fx+ I 2))
      (and (fx>= Count 20) (fx<= Count N) (fx<= Count (net-link.mtu D))
           (if (net-link.full? Tx) (do (note-drop A) false)
               (do (buffer.copy-into! (net-link.ring.data Tx) (net-link.tail-offset Tx) B I Count)
                   (net-link.publish Tx Count (net-link.delivery D Now)))))))

(define frame-input
  {adapter --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  A B I N Now ->
    (and (fx>= N 14)
         (let Dst (read-mac B I)
              Kind (buffer.u16-be B (fx+ I 12))
           (and (or (= Dst (adapter.mac A)) (= Dst 281474976710655))
                (cases (= Kind 2054) (arp-input A B I N Now)
                       (and (= Kind 2048) (fx>= N 34))
                         (receive-ip A B (fx+ I 14) (fx- N 14) Now)
                       true false)))))

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
  {adapter --> net-link.ring --> fixnum --> fixnum --> boolean}
  A R Mac Now ->
    (let D (adapter.frames A)
         Tx (net-link.device.tx D)
      (if (net-link.full? Tx) false
          (let B (net-link.ring.data Tx)
               At (net-link.tail-offset Tx)
               N (net-link.head-length R)
               Len (fx+ N 14)
               Wire (if (fx>= Len 60) Len (type 60 fixnum))
            (do (ethernet-header A B At Mac 2048)
                (buffer.copy-into! B (fx+ At 14) (net-link.ring.data R) (net-link.head-offset R) N)
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

(define emit-ip
  {adapter --> net-link.ring --> fixnum --> boolean}
  A R Now ->
    (if (fx< (net-link.head-length R) 20) (note-drop A)
        (let Dst (buffer.u32-be (net-link.ring.data R) (fx+ (net-link.head-offset R) 16))
             Hop (net-routes.lookup (adapter.routes A) Dst)
          (cases (= Dst 4294967295) (send-ip A R 281474976710655 Now)
                 (= Hop 0) (note-drop A)
                 true (let I (claim A Hop Now)
                         (if (= I 0) (note-drop A)
                             (let N (neighbor-at A I)
                                  Q (neighbor.pending N)
                               (if (and (fx> (neighbor.mac N) 0) (not (net-link.ready? Q 0)))
                                   (send-ip A R (neighbor.mac N) Now)
                                   (stash A R Q)))))))))

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
             (fx> (neighbor.mac N) 0) (and (send-ip A Q (neighbor.mac N) Now) (net-link.consume Q))
             (fx<= (neighbor.request-at N) Now)
               (and (arp A (neighbor.ip N) 0 281474976710655 1 Now)
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

(define pump
  {adapter --> fixnum --> fixnum}
  A Budget ->
    (let Now (net-link.now (adapter.frames A))
         Limit (buffer.index Budget)
         Received (rx-frames A (net-link.device.rx (adapter.frames A)) Now Limit 0)
         Queued (tx-packets A (net-link.device.rx (adapter.packets A)) Now Limit 0)
         Sent (drain A Now (adapter.next A) (adapter.slots A) Limit 0)
      (fx+ (fx+ Received Queued) Sent)))

(define earlier
  {fixnum --> fixnum --> fixnum}
  A B -> (if (or (fx< A 0) (and (fx>= B 0) (fx< B A))) B A))

(define neighbor-deadline
  {adapter --> fixnum --> boolean --> fixnum --> fixnum --> fixnum}
  _ _ _ 0 At -> At
  A Now Free I At ->
    (let N (neighbor-at A I)
         Due (if (net-link.ready? (neighbor.pending N) 0)
                 (earlier (neighbor.expires N)
                          (if Free (if (fx> (neighbor.mac N) 0) Now (neighbor.request-at N))
                              (type -1 fixnum)))
                 (type -1 fixnum))
      (neighbor-deadline A Now Free (fx- I 1) (earlier At Due))))

(define next-deadline
  {adapter --> fixnum}
  A ->
    (let Frames (adapter.frames A)
         Now (net-link.now Frames)
         Rx (net-link.head-deadline (net-link.device.rx Frames))
         Free (not (net-link.full? (net-link.device.tx Frames)))
         Tx (if Free (net-link.head-deadline (net-link.device.rx (adapter.packets A))) (type -1 fixnum))
      (neighbor-deadline A Now Free (adapter.slots A) (earlier Rx Tx))))

(preclude [neighbor.%match adapter.%match])
)
