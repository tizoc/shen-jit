\\ A typed IPv4/UDP peer over a bounded, single-owner in-memory link.
(shen.x.namespace udp
  (use buffer)
  (use shen-jit)
  (use net-link)
  (use net-ipv4)
  (use net-ipv6)
  (use net-wire => wire)
  (import struct defstruct)
  (import layout write-layout)
  (shadow bind)
  (export link device peer peer.port recv-info recv-info.source recv-info.family recv-info.source6 recv-info.destination6 recv-info.port recv-info.length
          make-link left right ipv4 bind make-recv-info packet-send packet-recv-into
          send send6 recv-into echo-step valid-datagram6? inbox-ingress6
          sent would-block too-large received empty budget-exhausted too-small
          inbox inbox.peer inbox.dropped make-inbox inbox-ingress inbox-recv-into inbox-ready? inbox-discard inbox-ingress-broadcast valid-datagram? write-packet)

(synonyms link net-link.link device net-link.device)

(defstruct peer
  (device : device)
  (ip : fixnum)
  (port : fixnum))

(defstruct recv-info
  (mutable source : fixnum)
  (mutable family : fixnum)
  (source6 : net-ipv6.address)
  (destination6 : net-ipv6.address)
  (mutable port : fixnum)
  (mutable length : fixnum))

(defstruct inbox
  (peer : peer)
  (queue : net-link.ring)
  (mutable dropped : fixnum))

\\ These names remain the UDP facade over the shared link.
\\ Where the datagram starts behind each IP header, and both headers' bytes.
(define datagram4
  {fixnum --> fixnum}
  I -> (fx+ I (wire.ipv4.size)))

(define datagram6
  {fixnum --> fixnum}
  I -> (fx+ I (wire.ipv6.size)))

(define headers4
  {--> fixnum}
  -> (fx+ (wire.ipv4.size) (wire.udp.size)))

(define headers6
  {--> fixnum}
  -> (fx+ (wire.ipv6.size) (wire.udp.size)))

\\ A computed checksum of 0 is sent as all ones, as 0 means none (RFC 768).
(define as-sent
  {fixnum --> fixnum}
  0 -> 65535
  Sum -> Sum)

(define make-link
  {fixnum --> fixnum --> fixnum --> (lazy fixnum) --> link}
  Slots Mtu Delay Clock ->
    (if (fx>= Mtu (headers4)) (net-link.make Slots Mtu Delay Clock)
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
      family <- 0
      source6 <- (net-ipv6.make-address 0 0 0 0)
      destination6 <- (net-ipv6.make-address 0 0 0 0)
      port <- 0
      length <- 0))

(define udp-checksum
  {buffer.view --> fixnum --> fixnum --> fixnum}
  B I N -> (net-ipv4.transport-checksum B I 17 N))

(define write-packet
  {buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum -->
   buffer.view --> fixnum --> fixnum --> buffer.view}
  B I Src SrcPort Dst DstPort Payload Start N ->
    (let Length (fx+ N (wire.udp.size))
         T (datagram4 I)
      (do (net-ipv4.write-header B I (fx+ N (headers4)) 17 Src Dst)
          (write-layout wire.udp B T (source-port SrcPort) (destination-port DstPort) (length Length))
          (buffer.copy-into! B (fx+ T (wire.udp.size)) Payload Start N)
          (wire.udp.checksum-> B T (as-sent (udp-checksum B I Length))))))

(define queue-datagram
  {peer --> fixnum --> fixnum --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  P Dst Port Payload Start N Delivery ->
    (let Tx (net-link.device.tx (peer.device P))
         B (net-link.ring.data Tx)
         I (net-link.tail-offset Tx)
      (do (write-packet B I (peer.ip P) (peer.port P) Dst Port Payload Start N)
          (net-link.publish Tx (fx+ N (headers4)) Delivery))))

(define send
  {peer --> fixnum --> fixnum --> buffer.view --> fixnum --> symbol}
  P IP Port Payload Count ->
    (let N (buffer.index Count)
         _ (buffer.range (buffer.length Payload) 0 N)
         D (peer.device P)
         Tx (net-link.device.tx D)
      (cases (not (and (net-ipv4.unicast? IP) (port? Port))) (error "udp: invalid destination")
             (fx> N (fx- (net-link.mtu D) (headers4))) too-large
             (net-link.full? Tx) would-block
             true (let Delivery (net-link.delivery D (net-link.now D))
                    (do (queue-datagram P IP Port Payload 0 N Delivery) sent)))))

(define send6
  {peer --> net-ipv6.address --> net-ipv6.address --> fixnum --> buffer.view --> fixnum --> symbol}
  P Source Destination Port Payload Count ->
    (let N (buffer.index Count)
         _ (buffer.range (buffer.length Payload) 0 N)
         D (peer.device P)
         Tx (net-link.device.tx D)
         Length (fx+ N (wire.udp.size))
         Size (fx+ N (headers6))
      (cases (not (and (net-ipv6.unicast? Source) (net-ipv6.unicast? Destination) (port? Port)
                       (fx>= (net-link.mtu D) 1280))) (error "udp: invalid IPv6 endpoints or MTU")
             (fx> Size (net-link.mtu D)) too-large
             (net-link.full? Tx) would-block
             true (let Delivery (net-link.delivery D (net-link.now D))
                       B (net-link.ring.data Tx)
                       I (net-link.tail-offset Tx)
                       T (datagram6 I)
                    (do (net-ipv6.write-header B I Size 17 64 Source Destination)
                        (write-layout wire.udp B T (source-port (peer.port P)) (destination-port Port) (length Length))
                        (buffer.copy-into! B (fx+ T (wire.udp.size)) Payload 0 N)
                        (wire.udp.checksum-> B T (as-sent (net-ipv6.transport-checksum B I 17 Length)))
                        (net-link.publish Tx Size Delivery)
                        sent)))))

(define valid-datagram6?
  {buffer.view --> fixnum --> fixnum --> boolean}
  B I N ->
    (let T (datagram6 I)
      (and (fx>= N (headers6))
           (net-ipv6.valid-header? B I N)
           (= (wire.ipv6.next-header B I) 17)
           (port? (wire.udp.source-port B T))
           (port? (wire.udp.destination-port B T))
           (= (wire.udp.length B T) (fx- N (wire.ipv6.size)))
           (not (= (wire.udp.checksum B T) 0))
           (= (net-ipv6.transport-checksum B I 17 (fx- N (wire.ipv6.size))) 0))))

\\ Length checks precede reading the transport header.
(define valid-datagram?
  {buffer.view --> fixnum --> fixnum --> boolean}
  B I N ->
    (let T (datagram4 I)
      (and (fx>= N (headers4))
           (net-ipv4.valid? B I N 17)
           (net-ipv4.unicast? (wire.ipv4.source B I))
           (port? (wire.udp.source-port B T))
           (port? (wire.udp.destination-port B T))
           (= (wire.udp.length B T) (fx- N (wire.ipv4.size)))
           (or (= (wire.udp.checksum B T) 0) (= (udp-checksum B I (fx- N (wire.ipv4.size))) 0)))))

(define accept?
  {peer --> buffer.view --> fixnum --> fixnum --> boolean}
  P B I N ->
    (and (fx>= N (headers4))
         (= (wire.ipv4.destination B I) (peer.ip P))
         (= (wire.udp.destination-port B (datagram4 I)) (peer.port P))
         (valid-datagram? B I N)))

(define receive-datagram
  {net-link.ring --> buffer.view --> fixnum --> fixnum --> buffer.view --> recv-info --> symbol}
  R B I N Out Info ->
    (let V4 (= (wire.ipv4.version B I) 4)
         T (if V4 (datagram4 I) (datagram6 I))
         Count (fx- N (if V4 (headers4) (headers6)))
      (if (fx> Count (buffer.length Out)) too-small
          (do (buffer.copy-into! Out 0 B (fx+ T (wire.udp.size)) Count)
              (recv-info.family-> Info (if V4 4 6))
              (if V4 (recv-info.source-> Info (wire.ipv4.source B I))
                  (do (net-ipv6.read-address (recv-info.source6 Info) B (wire.ipv6.source-at I))
                      (net-ipv6.read-address (recv-info.destination6 Info) B (wire.ipv6.destination-at I))
                      (recv-info.source-> Info 0)))
              (recv-info.port-> Info (wire.udp.source-port B T))
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
                        (do (queue-datagram P (wire.ipv4.source B I) (wire.udp.source-port B (datagram4 I))
                                            B (fx+ I (headers4)) (fx- N (headers4)) Delivery)
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
         _ (if (and (fx> N 0) (fx>= Mtu (headers4))) true
               (error "udp: inbox needs positive slots and an MTU of at least 28"))
      (:inbox
        peer <- (bind D IP Port)
        queue <- (net-link.make-ring N Mtu)
        dropped <- 0)))

\\ The interface always consumes ingress, even when just this inbox is full.
(define store-inbox
  {inbox --> buffer.view --> fixnum --> fixnum --> boolean}
  Q B I N ->
    (let R (inbox.queue Q)
      (cases (fx> N (net-link.mtu (peer.device (inbox.peer Q)))) false
             (net-link.full? R) (do (inbox.dropped-> Q (fx+ (inbox.dropped Q) 1)) false)
             true (do (buffer.copy-into! (net-link.ring.data R) (net-link.tail-offset R) B I N)
                      (net-link.publish R N 0)))))

(define inbox-ingress
  {inbox --> buffer.view --> fixnum --> fixnum --> boolean}
  Q B I N -> (and (accept? (inbox.peer Q) B I N) (store-inbox Q B I N)))

(define inbox-ingress6
  {inbox --> buffer.view --> fixnum --> fixnum --> boolean}
  Q B I N ->
    (and (valid-datagram6? B I N) (= (wire.udp.destination-port B (datagram6 I)) (peer.port (inbox.peer Q)))
         (store-inbox Q B I N)))

(define inbox-ingress-broadcast
  {inbox --> buffer.view --> fixnum --> fixnum --> boolean}
  Q B I N ->
    (and (valid-datagram? B I N)
         (= (wire.ipv4.destination B I) 4294967295)               \\ The limited broadcast address.
         (= (wire.udp.destination-port B (datagram4 I)) (peer.port (inbox.peer Q)))
         (store-inbox Q B I N)))

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

(define inbox-discard
  {inbox --> boolean}
  Q -> (let R (inbox.queue Q) (and (net-link.ready? R 0) (net-link.consume R))))

(preclude [peer.%match recv-info.%match inbox.%match])
)
