\\ One IP ingress owner for TCP, UDP, and ICMP.
(shen.x.namespace net-interface
  (use buffer)
  (use net-ipv4)
  (use net-ipv6)
  (use net-ndp)
  (use shen-jit)
  (use net-fragments)
  (use net-link)
  (use tcp)
  (use udp)
  (use net-wire => wire)
  (import struct defstruct)
  (import layout write-layout)
  (export interface interface.listener make make-host make-host-sized connect poll next-deadline
          enable-ipv6 connect6 udp-send6 no-address udp-binding udp-send udp-recv-into udp-dropped)

(defstruct ipv6-state
  (ndp : net-ndp.host)
  (remote : net-ipv6.address))

(defstruct interface
  (device : net-link.device)
  (ip : fixnum)
  (mutable ipv6 : (list ipv6-state))
  (fragments : net-fragments.table)
  (listener : tcp.listener)
  (tcp-ports : (list fixnum))
  (udp-bindings : (list udp.inbox)))

(define make
  {net-link.device --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> interface}
  D IP TcpPort TcpSlots InitialSequence UdpPort UdpSlots ->
    (:interface
      device <- D
      ip <- IP
      ipv6 <- []
      fragments <- (net-fragments.make 2 (net-link.mtu D))
      listener <- (tcp.make-listener D IP TcpPort TcpSlots InitialSequence)
      tcp-ports <- [TcpPort]
      udp-bindings <- [(udp.make-inbox D IP UdpPort UdpSlots)]))

(define list-has-port?
  {(list fixnum) --> fixnum --> boolean}
  [] _ -> false
  [P | Rest] Port -> (or (= P Port) (list-has-port? Rest Port)))

(define check-ports
  {(list fixnum) --> boolean}
  [] -> true
  [P | Rest] -> (if (and (fx>= P 1) (fx<= P 65535) (not (list-has-port? Rest P)))
                   (check-ports Rest)
                   (error "net/interface: ports must be distinct within each transport and in 1..65535")))

(define bind-udp
  {net-link.device --> fixnum --> (list fixnum) --> fixnum --> (list udp.inbox)}
  _ _ [] _ -> []
  D IP [P | Rest] Slots -> [(udp.make-inbox D IP P Slots) | (bind-udp D IP Rest Slots)])

(define make-host
  {net-link.device --> fixnum --> (list fixnum) --> fixnum --> fixnum --> fixnum -->
   (list fixnum) --> fixnum --> interface}
  D IP TcpPorts TcpSlots Key0 Key1 UdpPorts UdpSlots ->
    (new-host D IP TcpPorts (tcp.make-table D IP TcpSlots Key0 Key1) UdpPorts UdpSlots))

(define make-host-sized
  {net-link.device --> fixnum --> (list fixnum) --> fixnum --> fixnum --> fixnum -->
   (list fixnum) --> fixnum --> fixnum --> interface}
  D IP TcpPorts TcpSlots Key0 Key1 UdpPorts UdpSlots Bytes ->
    (new-host D IP TcpPorts (tcp.make-table-sized D IP TcpSlots Key0 Key1 Bytes) UdpPorts UdpSlots))

(define new-host
  {net-link.device --> fixnum --> (list fixnum) --> tcp.listener --> (list fixnum) --> fixnum --> interface}
  D IP TcpPorts L UdpPorts UdpSlots ->
    (do (check-ports TcpPorts)
        (check-ports UdpPorts)
        (:interface
          device <- D
          ip <- IP
          ipv6 <- []
          fragments <- (net-fragments.make 2 (net-link.mtu D))
          listener <- L
          tcp-ports <- TcpPorts
          udp-bindings <- (bind-udp D IP UdpPorts UdpSlots))))

(define connect
  {interface --> fixnum --> fixnum --> fixnum}
  F IP Port -> (tcp.table-connect (interface.listener F) (interface.tcp-ports F) IP Port))

(define enable-ipv6
  {interface --> net-ndp.host --> boolean}
  F H ->
    (if (and (= (interface.ipv6 F) []) (= (interface.device F) (net-ndp.host.device H)))
        (do (interface.ipv6-> F
              [(:ipv6-state
                 ndp <- H
                 remote <- (net-ipv6.make-address 0 0 0 0))])
            true)
        (error "net/interface: enable IPv6 once on the interface device")))

(define open-ipv6
  {interface --> (list ipv6-state) --> net-ipv6.address --> fixnum --> fixnum}
  _ [] _ _ -> 0
  F [S] Destination Port ->
    (let Source (net-ndp.source-address (ipv6-state.ndp S) Destination
                                        (net-link.now (interface.device F)))
      (if (net-ipv6.unicast? Source)
          (tcp.table-connect6 (interface.listener F) (interface.tcp-ports F) Source Destination Port)
          0)))

(define connect6
  {interface --> net-ipv6.address --> fixnum --> fixnum}
  F Destination Port -> (open-ipv6 F (interface.ipv6 F) Destination Port))

(define find-binding
  {(list udp.inbox) --> fixnum --> udp.inbox}
  [] _ -> (error "net/interface: unbound UDP port")
  [Q | Rest] Port -> (if (= (udp.peer.port (udp.inbox.peer Q)) Port) Q (find-binding Rest Port)))

(define udp-binding
  {interface --> fixnum --> udp.inbox}
  F Port -> (find-binding (interface.udp-bindings F) Port))

(define default-udp
  {(list udp.inbox) --> udp.inbox}
  [] -> (error "net/interface: no UDP bindings")
  [Q | _] -> Q)

(define udp-send
  {interface --> fixnum --> fixnum --> buffer.view --> fixnum --> symbol}
  F IP Port Payload Count -> (udp.send (udp.inbox.peer (default-udp (interface.udp-bindings F))) IP Port Payload Count))

(define send-ipv6
  {(list ipv6-state) --> interface --> fixnum --> net-ipv6.address --> fixnum --> buffer.view -->
   fixnum --> symbol}
  [] _ _ _ _ _ _ -> no-address
  [S] F LocalPort Destination Port Payload Count ->
    (let Source (net-ndp.source-address (ipv6-state.ndp S) Destination
                                        (net-link.now (interface.device F)))
      (if (net-ipv6.unicast? Source)
          (udp.send6 (udp.inbox.peer (udp-binding F LocalPort)) Source Destination Port Payload Count)
          no-address)))

(define udp-send6
  {interface --> fixnum --> net-ipv6.address --> fixnum --> buffer.view --> fixnum --> symbol}
  F LocalPort Destination Port Payload Count ->
    (send-ipv6 (interface.ipv6 F) F LocalPort Destination Port Payload Count))

(define udp-recv-into
  {interface --> buffer.view --> udp.recv-info --> symbol}
  F Out Info -> (udp.inbox-recv-into (default-udp (interface.udp-bindings F)) Out Info))

(define udp-dropped
  {interface --> fixnum}
  F -> (udp.inbox.dropped (default-udp (interface.udp-bindings F))))

\\ Write the reply straight into an available packet slot.
(define echo-request
  {interface --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  F B I N Now ->
    (let D (interface.device F)
         Tx (net-link.device.tx D)
         IP (interface.ip F)
         Start (fx+ I (wire.ipv4.size))
         Count (fx- N (wire.ipv4.size))
      (if (and (not (net-link.full? Tx)) (fx>= Count (wire.icmp.size))
               (net-ipv4.valid? B I N 1)
               (= (wire.ipv4.destination B I) IP)
               (net-ipv4.unicast? (wire.ipv4.source B I))
               (= (wire.icmp.type B Start) 8) (= (wire.icmp.code B Start) 0)       \\ An echo request.
               (= (net-ipv4.packet-checksum B Start Count) 0))
          (let Out (net-link.ring.data Tx)
               At (net-link.tail-offset Tx)
               Body (fx+ At (wire.ipv4.size))
            (do (net-ipv4.write-header Out At N 1 IP (wire.ipv4.source B I))
                (write-layout wire.icmp Out Body (type 0) (code 0))                 \\ The reply,
                (buffer.copy-into! Out (wire.icmp.rest-at Body) B (wire.icmp.rest-at Start) (fx- Count 4))  \\ with the same rest.
                (wire.icmp.checksum-> Out Body (net-ipv4.packet-checksum Out Body Count))
                (net-link.publish Tx N (net-link.delivery D Now))))
          false)))

(define unreachable
  {interface --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  F B I N Code Now ->
    (let D (interface.device F)
         Tx (net-link.device.tx D)
         Headers (fx+ (wire.ipv4.size) (wire.icmp.size))
         Quote (if (fx< N Headers) N Headers)                \\ The IP header and 8 bytes after it.
         Count (fx+ Quote Headers)
      (if (and (fx<= Count (net-link.mtu D)) (not (net-link.full? Tx)))
          (let Out (net-link.ring.data Tx)
               At (net-link.tail-offset Tx)
               Body (fx+ At (wire.ipv4.size))
            (do (net-ipv4.write-header Out At Count 1 (interface.ip F) (wire.ipv4.source B I))
                (write-layout wire.icmp Out Body (type 3) (code Code))             \\ Destination unreachable.
                (buffer.copy-into! Out (fx+ Body (wire.icmp.size)) B I Quote)
                (wire.icmp.checksum-> Out Body (net-ipv4.packet-checksum Out Body (fx+ Quote (wire.icmp.size))))
                (net-link.publish Tx Count (net-link.delivery D Now))))
          false)))

(define udp-ingress
  {interface --> (list udp.inbox) --> fixnum --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  F [] _ B I N Now ->
    (and (udp.valid-datagram? B I N) (unreachable F B I N 3 Now))
  F [Q | Rest] Port B I N Now ->
    (if (= (udp.peer.port (udp.inbox.peer Q)) Port)
        (udp.inbox-ingress Q B I N)
        (udp-ingress F Rest Port B I N Now)))

(define icmp-ingress
  {interface --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  F B I N Now ->
    (let T (fx+ I (wire.ipv4.size))
         Headers (fx+ (wire.ipv4.size) (wire.icmp.size))
      (if (fx< N Headers) false
          (let Type (wire.icmp.type B T)
               Code (wire.icmp.code B T)
            (cases (and (= Type 8) (= Code 0)) (echo-request F B I N Now)
                   (and (= Type 3) (= Code 4) (fx>= N (fx+ Headers Headers))   \\ Fragmentation needed,
                        (= (net-ipv4.packet-checksum B T (fx- N (wire.ipv4.size))) 0))  \\ quoting our header.
                     (tcp.path-mtu (interface.listener F) B (fx+ I Headers) (fx- N Headers)
                                   (wire.icmp-too-big.next-hop-mtu B T) Now)
                   true false)))))

(define dispatch
  {interface --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  F B I N Now ->
    (let Proto (wire.ipv4.protocol B I)
         T (fx+ I (wire.ipv4.size))
      (cases (= Proto 6)
               (and (fx>= N (fx+ (wire.ipv4.size) (wire.tcp.size)))
                    (tcp.table-ingress (interface.listener F) B I N Now
                                       (list-has-port? (interface.tcp-ports F) (wire.tcp.destination-port B T))))
             (= Proto 17)
               (and (fx>= N (fx+ (wire.ipv4.size) (wire.udp.size)))
                    (udp-ingress F (interface.udp-bindings F) (wire.udp.destination-port B T) B I N Now))
             (= Proto 1) (icmp-ingress F B I N Now)
             true (unreachable F B I N 2 Now))))

(define dhcp-broadcast
  {(list udp.inbox) --> buffer.view --> fixnum --> fixnum --> boolean}
  [] _ _ _ -> false
  [Q | Rest] B I N ->
    (if (= (udp.peer.port (udp.inbox.peer Q)) 68)
        (udp.inbox-ingress-broadcast Q B I N)
        (dhcp-broadcast Rest B I N)))

(define ingress4
  {interface --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  F B I N Now ->
    (and (net-ipv4.valid-header? B I N)
         (net-ipv4.unicast? (wire.ipv4.source B I))
         (let Dst (wire.ipv4.destination B I)
              T (fx+ I (wire.ipv4.size))
           (cases (and (= Dst 4294967295) (fx>= N (fx+ (wire.ipv4.size) (wire.udp.size)))
                       (= (wire.ipv4.protocol B I) 17)
                       (= (wire.udp.source-port B T) 67) (= (wire.udp.destination-port B T) 68))   \\ A DHCP server's broadcast.
                    (dhcp-broadcast (interface.udp-bindings F) B I N)
                  (not (= Dst (interface.ip F))) false
                  (net-ipv4.fragmented? B I)
                    (let T (interface.fragments F)
                         Count (net-fragments.receive T B I N Now)
                      (and (fx> Count 0) (dispatch F (net-fragments.packet T) 0 Count Now)))
                  true (dispatch F B I N Now)))))

(define smaller
  {fixnum --> fixnum --> fixnum}
  A B -> (if (fx< A B) A B))

(define earlier
  {fixnum --> fixnum --> fixnum}
  A B -> (if (or (fx< A 0) (and (fx>= B 0) (fx< B A))) B A))

(define emit-icmp6
  {interface --> net-ipv6.address --> net-ipv6.address --> buffer.view --> fixnum -->
   fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  F Source Remote B Start Bytes Type Code Detail Now ->
    (let D (interface.device F)
         Tx (net-link.device.tx D)
         Count (fx+ Bytes (fx+ (wire.ipv6.size) (wire.icmp.size)))
      (if (and (not (net-link.full? Tx)) (fx<= Count (net-link.mtu D)))
          (let Out (net-link.ring.data Tx)
               At (net-link.tail-offset Tx)
               ICMP (fx+ At (wire.ipv6.size))
            (do (net-ipv6.write-header Out At Count 58 64 Source Remote)
                (write-layout wire.icmp Out ICMP (type Type) (code Code) (rest Detail))
                (buffer.copy-into! Out (fx+ ICMP (wire.icmp.size)) B Start Bytes)
                (wire.icmp.checksum-> Out ICMP (net-ipv6.transport-checksum Out At 58 (fx+ Bytes (wire.icmp.size))))
                (net-link.publish Tx Count (net-link.delivery D Now))))
          false)))

(define icmp6
  {interface --> net-ipv6.address --> net-ipv6.address --> buffer.view --> fixnum -->
   fixnum --> fixnum --> boolean}
  F Local Remote B I N Now ->
    (let T (fx+ I (wire.ipv6.size))
         Headers (fx+ (wire.ipv6.size) (wire.icmp.size))
      (and (fx>= N Headers) (= (net-ipv6.transport-checksum B I 58 (fx- N (wire.ipv6.size))) 0)
           (let Type (wire.icmp.type B T)
                Code (wire.icmp.code B T)
             (cases (and (= Type 128) (= Code 0))                \\ An echo request, answered with its rest.
                      (emit-icmp6 F Local Remote B (fx+ I Headers) (fx- N Headers)
                                   129 0 (wire.icmp.rest B T) Now)
                    (and (= Type 2) (= Code 0))                  \\ Packet too big.
                      (tcp.path-mtu6 (interface.listener F) B (fx+ I Headers) (fx- N Headers)
                                     (wire.icmp6-too-big.mtu B T) Now Local)
                    true false)))))

(define udp-ingress6
  {interface --> (list udp.inbox) --> fixnum --> net-ipv6.address --> net-ipv6.address -->
   buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  F [] _ Local Remote B I N Now ->
    (and (udp.valid-datagram6? B I N)
         (emit-icmp6 F Local Remote B I (smaller N 1232) 1 4 0 Now))      \\ Port unreachable.
  F [Q | Rest] Port Local Remote B I N Now ->
    (if (= (udp.peer.port (udp.inbox.peer Q)) Port)
        (udp.inbox-ingress6 Q B I N)
        (udp-ingress6 F Rest Port Local Remote B I N Now)))

(define dispatch6
  {interface --> ipv6-state --> net-ipv6.address --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  F S Local B I N Now ->
    (let Remote (net-ipv6.read-address (ipv6-state.remote S) B (wire.ipv6.source-at I))
         Proto (wire.ipv6.next-header B I)
         T (fx+ I (wire.ipv6.size))
      (and (net-ipv6.unicast? Remote)
           (cases (and (= Proto 6) (fx>= N (fx+ (wire.ipv6.size) (wire.tcp.size))))
                    (tcp.table-ingress6 (interface.listener F) B I N Now
                                        (list-has-port? (interface.tcp-ports F) (wire.tcp.destination-port B T)) Local)
                  (and (= Proto 17) (fx>= N (fx+ (wire.ipv6.size) (wire.udp.size))))
                    (udp-ingress6 F (interface.udp-bindings F) (wire.udp.destination-port B T)
                                  Local Remote B I N Now)
                  (= Proto 58) (icmp6 F Local Remote B I N Now)
                  true false))))

(define ingress6
  {interface --> (list ipv6-state) --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  _ [] _ _ _ _ -> false
  F [S] B I N Now ->
    (and (net-ipv6.valid-header? B I N)
         (let H (ipv6-state.ndp S)
              Local (net-ndp.host.link-local H)
              Global (net-ndp.host.global H)
              At (fx+ I 24)
           (or (net-ndp.ingress H B I N Now)
               (cases (and (net-ndp.local-ready? H) (net-ipv6.address-at? Local B At))
                        (dispatch6 F S Local B I N Now)
                      (and (net-ndp.global-ready? H Now) (net-ipv6.address-at? Global B At))
                        (dispatch6 F S Global B I N Now)
                      true false)))))

(define ingress
  {interface --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  F B I N Now ->
    (and (fx> N 0)
         (if (= (shen-jit.shift-right (buffer.u8 B I) 4) 6)
             (ingress6 F (interface.ipv6 F) B I N Now)
             (ingress4 F B I N Now))))

(define ipv6-poll
  {(list ipv6-state) --> tcp.listener --> fixnum --> boolean}
  [] _ _ -> false
  [S] L Now ->
    (let H (ipv6-state.ndp S)
      (do (net-ndp.poll H Now)
          (tcp.expire-addresses6 L (net-ndp.host.link-local H) (net-ndp.local-ready? H)
                                  (net-ndp.host.global H) (net-ndp.global-ready? H Now)))))

(define ipv6-deadline
  {(list ipv6-state) --> fixnum --> fixnum}
  [] _ -> -1
  [S] Now -> (net-ndp.next-deadline (ipv6-state.ndp S) Now))

(define receive-ready
  {interface --> net-link.ring --> fixnum --> fixnum --> fixnum --> fixnum}
  _ _ _ 0 Done -> Done
  F R Now Budget Done ->
    (if (net-link.ready? R Now)
        (do (ingress F (net-link.ring.data R) (net-link.head-offset R) (net-link.head-length R) Now)
            (net-link.consume R)
            (receive-ready F R Now (fx- Budget 1) (fx+ Done 1)))
        Done))

(define poll
  {interface --> fixnum --> fixnum}
  F Budget ->
    (let D (interface.device F)
         Now (net-link.now D)
         Count (receive-ready F (net-link.device.rx D) Now (buffer.index Budget) 0)
      (do (ipv6-poll (interface.ipv6 F) (interface.listener F) Now)
          (tcp.listener-transmit (interface.listener F) Now)
          Count)))

\\ Absolute milliseconds, or -1 when only external I/O can make progress.
(define next-deadline
  {interface --> fixnum}
  F -> (let D (interface.device F)
            Now (net-link.now D)
            Rx (net-link.head-deadline (net-link.device.rx D))
            Tcp (tcp.listener-deadline (interface.listener F) Now)
         (earlier (ipv6-deadline (interface.ipv6 F) Now) (earlier Rx Tcp))))

(preclude [interface.%match ipv6-state.%match])
)
