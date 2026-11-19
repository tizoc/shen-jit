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
  (import struct defstruct)
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
         Start (fx+ I 20)
         Count (fx- N 20)
      (if (and (not (net-link.full? Tx)) (fx>= N 28)
               (net-ipv4.valid? B I N 1)
               (= (buffer.u32-be B (fx+ I 16)) IP)
               (net-ipv4.unicast? (buffer.u32-be B (fx+ I 12)))
               (= (buffer.u16-be B Start) 2048)
               (= (net-ipv4.packet-checksum B Start Count) 0))
          (let Out (net-link.ring.data Tx)
               At (net-link.tail-offset Tx)
               Body (fx+ At 20)
            (do (net-ipv4.write-header Out At N 1 IP (buffer.u32-be B (fx+ I 12)))
                (buffer.copy-into! Out (fx+ Body 4) B (fx+ Start 4) (fx- Count 4))
                (buffer.u32-be-> Out Body 0)
                (buffer.u16-be-> Out (fx+ Body 2) (net-ipv4.packet-checksum Out Body Count))
                (net-link.publish Tx N (net-link.delivery D Now))))
          false)))

(define unreachable
  {interface --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  F B I N Code Now ->
    (let D (interface.device F)
         Tx (net-link.device.tx D)
         Quote (if (fx< N 28) N (type 28 fixnum))
         Count (fx+ Quote 28)
      (if (and (fx<= Count (net-link.mtu D)) (not (net-link.full? Tx)))
          (let Out (net-link.ring.data Tx)
               At (net-link.tail-offset Tx)
               Body (fx+ At 20)
            (do (net-ipv4.write-header Out At Count 1 (interface.ip F) (buffer.u32-be B (fx+ I 12)))
                (buffer.u16-be-> Out Body (fx+ 768 Code))
                (buffer.u16-be-> Out (fx+ Body 2) 0)
                (buffer.u32-be-> Out (fx+ Body 4) 0)
                (buffer.copy-into! Out (fx+ Body 8) B I Quote)
                (buffer.u16-be-> Out (fx+ Body 2) (net-ipv4.packet-checksum Out Body (fx+ Quote 8)))
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
    (if (fx< N 28) false
        (let Code (buffer.u16-be B (fx+ I 20))
          (cases (= Code 2048) (echo-request F B I N Now)
                 (and (= Code 772) (fx>= N 56)
                      (= (net-ipv4.packet-checksum B (fx+ I 20) (fx- N 20)) 0))
                   (tcp.path-mtu (interface.listener F) B (fx+ I 28) (fx- N 28)
                                 (buffer.u16-be B (fx+ I 26)) Now)
                 true false))))

(define dispatch
  {interface --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  F B I N Now ->
    (let Proto (buffer.u8 B (fx+ I 9))
      (cases (= Proto 6)
               (and (fx>= N 40)
                    (tcp.table-ingress (interface.listener F) B I N Now
                                       (list-has-port? (interface.tcp-ports F) (buffer.u16-be B (fx+ I 22)))))
             (= Proto 17)
               (and (fx>= N 28)
                    (udp-ingress F (interface.udp-bindings F) (buffer.u16-be B (fx+ I 22)) B I N Now))
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
         (net-ipv4.unicast? (buffer.u32-be B (fx+ I 12)))
         (let Dst (buffer.u32-be B (fx+ I 16))
           (cases (and (= Dst 4294967295) (fx>= N 28) (= (buffer.u8 B (fx+ I 9)) 17)
                       (= (buffer.u32-be B (fx+ I 20)) 4390980))
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
   fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  F Source Remote B Start Bytes Type Detail Now ->
    (let D (interface.device F)
         Tx (net-link.device.tx D)
         Count (fx+ Bytes 48)
      (if (and (not (net-link.full? Tx)) (fx<= Count (net-link.mtu D)))
          (let Out (net-link.ring.data Tx)
               At (net-link.tail-offset Tx)
               ICMP (fx+ At 40)
            (do (net-ipv6.write-header Out At Count 58 64 Source Remote)
                (buffer.u32-be-> Out ICMP (shen-jit.shift-left Type 16))
                (buffer.u32-be-> Out (fx+ ICMP 4) Detail)
                (buffer.copy-into! Out (fx+ ICMP 8) B Start Bytes)
                (buffer.u16-be-> Out (fx+ ICMP 2) (net-ipv6.transport-checksum Out At 58 (fx+ Bytes 8)))
                (net-link.publish Tx Count (net-link.delivery D Now))))
          false)))

(define icmp6
  {interface --> net-ipv6.address --> net-ipv6.address --> buffer.view --> fixnum -->
   fixnum --> fixnum --> boolean}
  F Local Remote B I N Now ->
    (and (fx>= N 48) (= (net-ipv6.transport-checksum B I 58 (fx- N 40)) 0)
         (let Type (buffer.u16-be B (fx+ I 40))
           (cases (= Type 32768)
                    (emit-icmp6 F Local Remote B (fx+ I 48) (fx- N 48)
                                 33024 (buffer.u32-be B (fx+ I 44)) Now)
                  (= Type 512)
                    (tcp.path-mtu6 (interface.listener F) B (fx+ I 48) (fx- N 48)
                                   (buffer.u32-be B (fx+ I 44)) Now Local)
                  true false))))

(define udp-ingress6
  {interface --> (list udp.inbox) --> fixnum --> net-ipv6.address --> net-ipv6.address -->
   buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  F [] _ Local Remote B I N Now ->
    (and (udp.valid-datagram6? B I N)
         (emit-icmp6 F Local Remote B I (smaller N 1232) 260 0 Now))
  F [Q | Rest] Port Local Remote B I N Now ->
    (if (= (udp.peer.port (udp.inbox.peer Q)) Port)
        (udp.inbox-ingress6 Q B I N)
        (udp-ingress6 F Rest Port Local Remote B I N Now)))

(define dispatch6
  {interface --> ipv6-state --> net-ipv6.address --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  F S Local B I N Now ->
    (let Remote (net-ipv6.read-address (ipv6-state.remote S) B (fx+ I 8))
         Proto (buffer.u8 B (fx+ I 6))
      (and (net-ipv6.unicast? Remote)
           (cases (and (= Proto 6) (fx>= N 60))
                    (tcp.table-ingress6 (interface.listener F) B I N Now
                                        (list-has-port? (interface.tcp-ports F) (buffer.u16-be B (fx+ I 42))) Local)
                  (and (= Proto 17) (fx>= N 48))
                    (udp-ingress6 F (interface.udp-bindings F) (buffer.u16-be B (fx+ I 42))
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
