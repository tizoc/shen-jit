\\ A typed IPv4/UDP peer over a bounded, single-owner in-memory link.
(shen.x.namespace udp
  (use buffer)
  (use shen-jit)
  (use net-link)
  (use net-ipv4)
  (import struct defstruct)
  (shadow bind)
  (export link device peer peer.port recv-info recv-info.source recv-info.port recv-info.length
          make-link left right ipv4 bind make-recv-info packet-send packet-recv-into
          send recv-into echo-step
          sent would-block too-large received empty budget-exhausted too-small
          inbox inbox.peer inbox.dropped make-inbox inbox-ingress inbox-recv-into inbox-ready? valid-datagram? write-packet)

(synonyms link net-link.link device net-link.device)

(defstruct peer
  (device : device)
  (ip : fixnum)
  (port : fixnum))

(defstruct recv-info
  (mutable source : fixnum)
  (mutable port : fixnum)
  (mutable length : fixnum))

(defstruct inbox
  (peer : peer)
  (queue : net-link.ring)
  (mutable dropped : fixnum))

\\ These names remain the UDP facade over the shared link.
(define make-link
  {fixnum --> fixnum --> fixnum --> (lazy fixnum) --> link}
  Slots Mtu Delay Clock ->
    (if (fx>= Mtu 28) (net-link.make Slots Mtu Delay Clock)
        (error "udp: need an MTU of at least 28")))

(define left
  {link --> device}
  L -> (net-link.left L))

(define right
  {link --> device}
  L -> (net-link.right L))

(define packet-send
  {device --> buffer.view --> fixnum --> symbol}
  D B N -> (let Status (net-link.packet-send D B N)
             (cases (= Status net-link.sent) sent
                    (= Status net-link.would-block) would-block
                    true too-large)))

(define packet-recv-into
  {device --> buffer.view --> fixnum}
  D B -> (net-link.packet-recv-into D B))

(define ipv4
  {fixnum --> fixnum --> fixnum --> fixnum --> fixnum}
  A B C D -> (net-ipv4.address A B C D))

(define port?
  {fixnum --> boolean}
  Port -> (and (fx>= Port 1) (fx<= Port 65535)))

(define bind
  {device --> fixnum --> fixnum --> peer}
  D IP Port ->
    (if (and (net-ipv4.unicast? IP) (port? Port))
        (:peer
          device <- D
          ip <- IP
          port <- Port)
        (error "udp: need a unicast IPv4 address and a port in 1..65535")))

(define make-recv-info
  {--> recv-info}
  ->
    (:recv-info
      source <- 0
      port <- 0
      length <- 0))

(define udp-checksum
  {buffer.view --> fixnum --> fixnum --> fixnum}
  B I N -> (net-ipv4.transport-checksum B I 17 N))

(define write-packet
  {buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum -->
   buffer.view --> fixnum --> fixnum --> buffer.view}
  B I Src SrcPort Dst DstPort Payload Start N ->
    (let UdpLength (fx+ N 8)
      (do (net-ipv4.write-header B I (fx+ N 28) 17 Src Dst)
          (buffer.u16-be-> B (fx+ I 20) SrcPort)
          (buffer.u16-be-> B (fx+ I 22) DstPort)
          (buffer.u16-be-> B (fx+ I 24) UdpLength)
          (buffer.u16-be-> B (fx+ I 26) 0)
          (buffer.copy-into! B (fx+ I 28) Payload Start N)
          (let Sum (udp-checksum B I UdpLength)
            (buffer.u16-be-> B (fx+ I 26) (if (= Sum 0) 65535 Sum))))))

(define queue-datagram
  {peer --> fixnum --> fixnum --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  P Dst Port Payload Start N Delivery ->
    (let Tx (net-link.device.tx (peer.device P))
         B (net-link.ring.data Tx)
         I (net-link.tail-offset Tx)
      (do (write-packet B I (peer.ip P) (peer.port P) Dst Port Payload Start N)
          (net-link.publish Tx (fx+ N 28) Delivery))))

(define send
  {peer --> fixnum --> fixnum --> buffer.view --> fixnum --> symbol}
  P IP Port Payload Count ->
    (let N (buffer.index Count)
         _ (buffer.range (buffer.length Payload) 0 N)
         D (peer.device P)
         Tx (net-link.device.tx D)
      (cases (not (and (net-ipv4.unicast? IP) (port? Port))) (error "udp: invalid destination")
             (fx> N (fx- (net-link.mtu D) 28)) too-large
             (net-link.full? Tx) would-block
             true (let Delivery (net-link.delivery D (net-link.now D))
                    (do (queue-datagram P IP Port Payload 0 N Delivery) sent)))))

\\ Length checks precede reading the transport header.
(define valid-datagram?
  {buffer.view --> fixnum --> fixnum --> boolean}
  B I N ->
    (and (fx>= N 28)
         (net-ipv4.valid? B I N 17)
         (net-ipv4.unicast? (buffer.u32-be B (fx+ I 12)))
         (port? (buffer.u16-be B (fx+ I 20)))
         (port? (buffer.u16-be B (fx+ I 22)))
         (= (buffer.u16-be B (fx+ I 24)) (fx- N 20))
         (or (= (buffer.u16-be B (fx+ I 26)) 0) (= (udp-checksum B I (fx- N 20)) 0))))

(define accept?
  {peer --> buffer.view --> fixnum --> fixnum --> boolean}
  P B I N ->
    (and (fx>= N 28)
         (= (buffer.u32-be B (fx+ I 16)) (peer.ip P))
         (= (buffer.u16-be B (fx+ I 22)) (peer.port P))
         (valid-datagram? B I N)))

(define receive-datagram
  {net-link.ring --> buffer.view --> fixnum --> fixnum --> buffer.view --> recv-info --> symbol}
  R B I N Out Info ->
    (let Count (fx- N 28)
      (if (fx> Count (buffer.length Out)) too-small
          (do (buffer.copy-into! Out 0 B (fx+ I 28) Count)
              (recv-info.source-> Info (buffer.u32-be B (fx+ I 12)))
              (recv-info.port-> Info (buffer.u16-be B (fx+ I 20)))
              (recv-info.length-> Info Count)
              (net-link.consume R)
              received))))

(define receive-ready
  {peer --> net-link.ring --> buffer.view --> recv-info --> fixnum --> fixnum --> symbol}
  _ _ _ _ _ 0 -> budget-exhausted
  P R Out Info Now Budget ->
    (if (net-link.ready? R Now)
        (let B (net-link.ring.data R) I (net-link.head-offset R) N (net-link.head-length R)
          (if (accept? P B I N)
              (receive-datagram R B I N Out Info)
              (do (net-link.consume R) (receive-ready P R Out Info Now (fx- Budget 1)))))
        empty))

(define recv-into
  {peer --> buffer.view --> recv-info --> fixnum --> symbol}
  P Out Info Budget ->
    (let D (peer.device P)
         Count (buffer.index Budget)
         Now (net-link.now D)
      (receive-ready P (net-link.device.rx D) Out Info Now Count)))

(define echo-ready
  {peer --> net-link.ring --> net-link.ring --> fixnum --> fixnum --> fixnum --> fixnum}
  _ _ _ _ 0 Done -> Done
  P Rx Tx Now Budget Done ->
    (if (net-link.ready? Rx Now)
        (let B (net-link.ring.data Rx) I (net-link.head-offset Rx) N (net-link.head-length Rx)
          (cases (not (accept? P B I N))
                   (do (net-link.consume Rx) (echo-ready P Rx Tx Now (fx- Budget 1) (fx+ Done 1)))
                 (net-link.full? Tx) Done
                 true (let Delivery (net-link.delivery (peer.device P) Now)
                        (do (queue-datagram P (buffer.u32-be B (fx+ I 12)) (buffer.u16-be B (fx+ I 20))
                                            B (fx+ I 28) (fx- N 28) Delivery)
                            (net-link.consume Rx)
                            (echo-ready P Rx Tx Now (fx- Budget 1) (fx+ Done 1))))))
        Done))

(define echo-step
  {peer --> fixnum --> fixnum}
  P Budget ->
    (let D (peer.device P)
         Count (buffer.index Budget)
         Now (net-link.now D)
      (echo-ready P (net-link.device.rx D) (net-link.device.tx D) Now Count 0)))

(define make-inbox
  {device --> fixnum --> fixnum --> fixnum --> inbox}
  D IP Port Slots ->
    (let N (buffer.index Slots)
         Mtu (net-link.mtu D)
         _ (if (and (fx> N 0) (fx>= Mtu 28)) true
               (error "udp: inbox needs positive slots and an MTU of at least 28"))
      (:inbox
        peer <- (bind D IP Port)
        queue <- (net-link.make-ring N Mtu)
        dropped <- 0)))

\\ The interface always consumes ingress, even when just this inbox is full.
(define inbox-ingress
  {inbox --> buffer.view --> fixnum --> fixnum --> boolean}
  Q B I N ->
    (let P (inbox.peer Q)
         R (inbox.queue Q)
      (if (and (fx<= N (net-link.mtu (peer.device P))) (accept? P B I N))
          (if (net-link.full? R)
              (do (inbox.dropped-> Q (fx+ (inbox.dropped Q) 1)) false)
              (do (buffer.copy-into! (net-link.ring.data R) (net-link.tail-offset R) B I N)
                  (net-link.publish R N 0)))
          false)))

(define inbox-recv-into
  {inbox --> buffer.view --> recv-info --> symbol}
  Q Out Info ->
    (let R (inbox.queue Q)
      (if (net-link.ready? R 0)
          (receive-datagram R (net-link.ring.data R) (net-link.head-offset R) (net-link.head-length R) Out Info)
          empty)))

(define inbox-ready?
  {inbox --> boolean}
  Q -> (net-link.ready? (inbox.queue Q) 0))

(preclude [peer.%match recv-info.%match inbox.%match])
)
