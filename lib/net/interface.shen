\\ One IP ingress owner for TCP, UDP, and ICMP.
(shen.x.namespace net-interface
  (use buffer)
  (use net-ipv4)
  (use net-ipv6)
  (use net-ipv6-headers)
  (use net-fragments6)
  (use net-ndp)
  (use net-multicast)
  (use shen-jit)
  (use net-fragments)
  (use net-link)
  (use tcp)
  (use udp)
  (use net-wire => wire)
  (import struct defstruct)
  (import layout write-layout)
  (export interface interface.listener make make-host make-host-sized make-host-limits connect poll next-deadline
          enable-multicast enable-multicast-sized join4 join6 leave4 leave6 joined4? joined6?
          join-source4 join-source6 leave-source4 leave-source6
          enable-ipv6 enable-ipv6-sized connect6 udp-send6 no-address udp-binding udp-send udp-recv-into udp-dropped)

(defstruct ipv6-state
  (ndp : net-ndp.host)
  (remote : net-ipv6.address)
  (headers : net-ipv6-headers.cursor)
  (fragments : net-fragments6.table)
  (mutable error-at : fixnum)
  (mutable error-tokens : fixnum))

(defstruct interface
  (device : net-link.device)
  (ip : fixnum)
  (mutable ipv6 : (list ipv6-state))
  (mutable groups : (list net-multicast.membership))
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
      groups <- []
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

(define make-host-limits
  {net-link.device --> fixnum --> (list fixnum) --> fixnum --> fixnum --> fixnum -->
   (list fixnum) --> fixnum --> fixnum --> fixnum --> interface}
  D IP TcpPorts TcpSlots Key0 Key1 UdpPorts UdpSlots Bytes WaitSlots ->
    (new-host D IP TcpPorts (tcp.make-table-limits D IP TcpSlots Key0 Key1 Bytes WaitSlots) UdpPorts UdpSlots))

(define new-host
  {net-link.device --> fixnum --> (list fixnum) --> tcp.listener --> (list fixnum) --> fixnum --> interface}
  D IP TcpPorts L UdpPorts UdpSlots ->
    (do (check-ports TcpPorts)
        (check-ports UdpPorts)
        (:interface
          device <- D
          ip <- IP
          ipv6 <- []
          groups <- []
          fragments <- (net-fragments.make 2 (net-link.mtu D))
          listener <- L
          tcp-ports <- TcpPorts
          udp-bindings <- (bind-udp D IP UdpPorts UdpSlots))))

(define enable-multicast
  {interface --> fixnum --> fixnum --> boolean}
  F Slots Seed ->
    (if (= (interface.groups F) [])
        (do (interface.groups-> F [(net-multicast.make (interface.device F) (interface.ip F) Slots Seed)])
            true)
        (error "net/interface: enable multicast once during setup")))

(define enable-multicast-sized
  {interface --> fixnum --> fixnum --> fixnum --> boolean}
  F Slots Sources Seed ->
    (if (= (interface.groups F) [])
        (do (interface.groups-> F
              [(net-multicast.make-sized (interface.device F) (interface.ip F) Slots Sources Seed)])
            true)
        (error "net/interface: enable multicast once during setup")))

(define membership-of
  {(list net-multicast.membership) --> net-multicast.membership}
  [M] -> M
  _ -> (error "net/interface: multicast is disabled"))

(define join4
  {interface --> fixnum --> boolean}
  F IP ->
    (let Groups (interface.groups F)
      (and (not (= Groups []))
           (net-multicast.join4 (membership-of Groups) IP (net-link.now (interface.device F))))))

(define join6
  {interface --> net-ipv6.address --> boolean}
  F IP ->
    (let Groups (interface.groups F)
      (and (not (= Groups [])) (not (= (interface.ipv6 F) []))
           (net-multicast.join6 (membership-of Groups) IP (net-link.now (interface.device F))))))

(define leave4
  {interface --> fixnum --> boolean}
  F IP ->
    (let Groups (interface.groups F)
      (and (not (= Groups []))
           (net-multicast.leave4 (membership-of Groups) IP (net-link.now (interface.device F))))))

(define leave6
  {interface --> net-ipv6.address --> boolean}
  F IP ->
    (let Groups (interface.groups F)
      (and (not (= Groups []))
           (net-multicast.leave6 (membership-of Groups) IP (net-link.now (interface.device F))))))

(define join-source4
  {interface --> fixnum --> fixnum --> boolean}
  F IP Source ->
    (let Groups (interface.groups F)
      (and (not (= Groups []))
           (net-multicast.join-source4 (membership-of Groups) IP Source (net-link.now (interface.device F))))))

(define join-source6
  {interface --> net-ipv6.address --> net-ipv6.address --> boolean}
  F IP Source ->
    (let Groups (interface.groups F)
      (and (not (= Groups [])) (not (= (interface.ipv6 F) []))
           (net-multicast.join-source6 (membership-of Groups) IP Source (net-link.now (interface.device F))))))

(define leave-source4
  {interface --> fixnum --> fixnum --> boolean}
  F IP Source ->
    (let Groups (interface.groups F)
      (and (not (= Groups []))
           (net-multicast.leave-source4 (membership-of Groups) IP Source (net-link.now (interface.device F))))))

(define leave-source6
  {interface --> net-ipv6.address --> net-ipv6.address --> boolean}
  F IP Source ->
    (let Groups (interface.groups F)
      (and (not (= Groups []))
           (net-multicast.leave-source6 (membership-of Groups) IP Source (net-link.now (interface.device F))))))

(define joined4?
  {interface --> fixnum --> boolean}
  F IP ->
    (let Groups (interface.groups F)
      (and (not (= Groups [])) (net-multicast.joined4? (membership-of Groups) IP))))

(define joined6?
  {interface --> net-ipv6.address --> boolean}
  F IP ->
    (let Groups (interface.groups F)
      (and (not (= Groups [])) (net-multicast.joined6? (membership-of Groups) IP))))

(define joined6-at?
  {interface --> buffer.view --> fixnum --> boolean}
  F B I ->
    (let Groups (interface.groups F)
      (and (not (= Groups [])) (net-multicast.joined6-at? (membership-of Groups) B I))))

(define multicast-from4?
  {interface --> fixnum --> fixnum --> boolean}
  F Group Source ->
    (let Groups (interface.groups F)
      (and (not (= Groups [])) (net-multicast.accepts4? (membership-of Groups) Group Source))))

(define multicast-from6?
  {interface --> buffer.view --> fixnum --> boolean}
  F B I ->
    (let Groups (interface.groups F)
      (and (not (= Groups []))
           (net-multicast.accepts6-at? (membership-of Groups) B (wire.ipv6.destination-at I) (wire.ipv6.source-at I)))))

(define connect
  {interface --> fixnum --> fixnum --> fixnum}
  F IP Port -> (tcp.table-connect (interface.listener F) (interface.tcp-ports F) IP Port))

(define inboxes-empty?
  {(list udp.inbox) --> boolean}
  [] -> true
  [Q | Rest] -> (and (not (udp.inbox-ready? Q)) (inboxes-empty? Rest)))

(define reserve-inboxes
  {(list udp.inbox) --> fixnum --> boolean}
  [] _ -> true
  [Q | Rest] Bytes ->
    (do (udp.reserve-inbox Q Bytes)
        (reserve-inboxes Rest Bytes)))

(define enable-ipv6-sized
  {interface --> net-ndp.host --> fixnum --> fixnum --> boolean}
  F H Slots Bytes ->
    (if (and (= (interface.ipv6 F) []) (= (interface.device F) (net-ndp.host.device H))
             (inboxes-empty? (interface.udp-bindings F)))
        (let State (:ipv6-state
                      ndp <- H
                      remote <- (net-ipv6.make-address 0 0 0 0)
                      headers <- (net-ipv6-headers.make)
                      fragments <- (net-fragments6.make Slots Bytes)
                      error-at <- 0
                      error-tokens <- 8)
          (do (reserve-inboxes (interface.udp-bindings F) Bytes)
              (interface.ipv6-> F [State])
              true))
        (error "net/interface: enable IPv6 once on the interface device before receiving UDP")))

(define enable-ipv6
  {interface --> net-ndp.host --> boolean}
  F H -> (enable-ipv6-sized F H 2 4096))

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
  {interface --> (list udp.inbox) --> fixnum --> buffer.view --> fixnum --> fixnum --> fixnum -->
   boolean --> boolean}
  F [] _ B I N Now Multicast ->
    (and (not Multicast) (udp.valid-datagram? B I N) (unreachable F B I N 3 Now))
  F [Q | Rest] Port B I N Now Multicast ->
    (if (= (udp.peer.port (udp.inbox.peer Q)) Port)
        (if Multicast (udp.inbox-ingress-multicast Q B I N) (udp.inbox-ingress Q B I N))
        (udp-ingress F Rest Port B I N Now Multicast)))

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
  {interface --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean --> boolean}
  F B I N Now Multicast ->
    (let Proto (wire.ipv4.protocol B I)
         T (fx+ I (wire.ipv4.size))
      (cases (and (= Proto 17) (fx>= N (fx+ (wire.ipv4.size) (wire.udp.size))))
               (udp-ingress F (interface.udp-bindings F) (wire.udp.destination-port B T) B I N Now Multicast)
             Multicast false                                     \\ A group's datagrams are UDP.
             (and (= Proto 6) (fx>= N (fx+ (wire.ipv4.size) (wire.tcp.size))))
               (tcp.table-ingress (interface.listener F) B I N Now
                                  (list-has-port? (interface.tcp-ports F) (wire.tcp.destination-port B T)))
             (= Proto 1) (icmp-ingress F B I N Now)
             (or (= Proto 6) (= Proto 17)) false
             true (unreachable F B I N 2 Now))))

(define dhcp-broadcast
  {(list udp.inbox) --> buffer.view --> fixnum --> fixnum --> boolean}
  [] _ _ _ -> false
  [Q | Rest] B I N ->
    (if (= (udp.peer.port (udp.inbox.peer Q)) 68)
        (udp.inbox-ingress-broadcast Q B I N)
        (dhcp-broadcast Rest B I N)))

(define ipv4-deliver
  {interface --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean --> boolean}
  F B I N Now Multicast ->
    (if (net-ipv4.fragmented? B I)
        (let T (interface.fragments F)
             Count (net-fragments.receive T B I N Now)
          (and (fx> Count 0) (dispatch F (net-fragments.packet T) 0 Count Now Multicast)))
        (dispatch F B I N Now Multicast)))

(define ipv4-data
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
                  (= Dst (interface.ip F))
                    (ipv4-deliver F B I N Now false)
                  (and (= (wire.ipv4.protocol B I) 17)
                       (multicast-from4? F Dst (wire.ipv4.source B I)))
                    (ipv4-deliver F B I N Now true)
                  true false))))

(define ingress4
  {interface --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  F B I N Now ->
    (and (fx>= N (wire.ipv4.size))
         (if (= (wire.ipv4.protocol B I) 2)                              \\ IGMP.
             (let Groups (interface.groups F)
               (and (not (= Groups [])) (net-multicast.ingress4 (membership-of Groups) B I N Now)))
             (ipv4-data F B I N Now))))

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

\\ Rate-limit ICMPv6 errors independently of echo replies and discovery.
(define refill-errors
  {ipv6-state --> fixnum --> fixnum}
  S Now ->
    (let At (ipv6-state.error-at S)
         Units (fxquotient (fx- Now At) 100)
         Tokens (smaller 8 (fx+ (ipv6-state.error-tokens S) Units))
      (do (ipv6-state.error-at-> S (fx+ At (fx* Units 100)))
          (ipv6-state.error-tokens-> S Tokens)
          Tokens)))

(define error6
  {interface --> ipv6-state --> net-ipv6.address --> buffer.view --> fixnum -->
   fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  F S Local B I N Type Code Pointer Now ->
    (let Remote (net-ipv6.read-address (ipv6-state.remote S) B (wire.ipv6.source-at I))
      (and (net-ipv6.unicast? Remote) (net-ipv6-headers.can-report? B I N)
           (fx> (refill-errors S Now) 0)
           (emit-icmp6 F Local Remote B I (smaller N 1232) Type Code Pointer Now)
           (do (ipv6-state.error-tokens-> S (fx- (ipv6-state.error-tokens S) 1)) true))))

(define icmp6
  {interface --> net-ipv6.address --> net-ipv6.address --> buffer.view --> fixnum -->
   fixnum --> fixnum --> fixnum --> boolean}
  F Local Remote B I N At Now ->
    (let Count (fx- (fx+ I N) At)
         Body (fx+ At (wire.icmp.size))
      (and (fx>= Count (wire.icmp.size)) (= (net-ipv6.transport-checksum-at B I At 58 Count) 0)
           (let Type (wire.icmp.type B At)
                Code (wire.icmp.code B At)
             (cases (and (= Type 128) (= Code 0))                \\ An echo request, answered with its rest.
                      (emit-icmp6 F Local Remote B Body (fx- Count (wire.icmp.size))
                                   129 0 (wire.icmp.rest B At) Now)
                    (and (= Type 2) (= Code 0))                  \\ Packet too big.
                      (tcp.path-mtu6 (interface.listener F) B Body (fx- Count (wire.icmp.size))
                                     (wire.icmp6-too-big.mtu B At) Now Local)
                    true false)))))

(define udp-ingress6
  {interface --> ipv6-state --> (list udp.inbox) --> fixnum --> net-ipv6.address -->
   buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> boolean --> boolean}
  F S [] _ Local B I N At Now Multicast ->
    (and (not Multicast) (udp.valid-datagram6-at? B I N At)
         (error6 F S Local B I N 1 4 0 Now))                       \\ Port unreachable.
  F S [Q | Rest] Port Local B I N At Now Multicast ->
    (if (= (udp.peer.port (udp.inbox.peer Q)) Port)
        (udp.inbox-ingress6-at Q B I N At)
        (udp-ingress6 F S Rest Port Local B I N At Now Multicast)))

(define mld-ingress
  {(list net-multicast.membership) --> ipv6-state --> buffer.view -->
   fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  [] _ _ _ _ _ _ -> false
  [M] S B I N At Now -> (net-multicast.ingress6 M (net-ndp.host.link-local (ipv6-state.ndp S)) B I N At
                                                (net-ipv6-headers.cursor.router-alert (ipv6-state.headers S)) Now))

(define dispatch6
  {interface --> ipv6-state --> net-ipv6.address --> buffer.view --> fixnum --> fixnum -->
   fixnum --> symbol --> boolean --> boolean}
  F S Local B I N Now Scope Fragmented ->
    (let Cursor (ipv6-state.headers S)
         Proto (net-ipv6-headers.cursor.protocol Cursor)
         At (net-ipv6-headers.cursor.at Cursor)
         Count (fx- (fx+ I N) At)
         H (ipv6-state.ndp S)
      (or (and (= Proto 58) (not Fragmented)
               (or (net-ndp.ingress-at H B I N At Now)
                   (and (= Scope multicast) (mld-ingress (interface.groups F) S B I N At Now))))
          (and (or (= Scope unicast) (= Scope multicast))
               (let Remote (net-ipv6.read-address (ipv6-state.remote S) B (wire.ipv6.source-at I))
                 (and (net-ipv6.unicast? Remote)
                      (cases (and (= Proto 17) (fx>= Count (wire.udp.size))
                                  (or (= Scope unicast) (multicast-from6? F B I)))
                               (udp-ingress6 F S (interface.udp-bindings F) (wire.udp.destination-port B At)
                                             Local B I N At Now (= Scope multicast))
                             (not (= Scope unicast)) false
                             (and (= Proto 6) (fx>= Count (wire.tcp.size)))
                               (tcp.table-ingress6-at (interface.listener F) B I N At Now
                                 (list-has-port? (interface.tcp-ports F) (wire.tcp.destination-port B At)) Local)
                             (= Proto 58) (icmp6 F Local Remote B I N At Now)
                             true false)))))))

(define complain6
  {interface --> ipv6-state --> net-ipv6.address --> buffer.view --> fixnum -->
   fixnum --> fixnum --> symbol --> boolean}
  F S Local B I N Now Scope ->
    (let H (ipv6-state.ndp S)
         Cursor (ipv6-state.headers S)
         Pointer (fx- (net-ipv6-headers.cursor.at Cursor) I)
         Code (net-ipv6-headers.cursor.problem-code Cursor)
      (cases (= Scope unicast)
               (error6 F S Local B I N 4 Code Pointer Now)
             (and (= Scope multicast) (net-ipv6-headers.cursor.multicast-error Cursor))
               (cases (net-ndp.local-ready? H)
                        (error6 F S (net-ndp.host.link-local H) B I N 4 Code Pointer Now)
                      (net-ndp.global-ready? H Now)
                        (error6 F S (net-ndp.host.global H) B I N 4 Code Pointer Now)
                      true false)
             true false)))

(define upper-fits?
  {net-ipv6-headers.cursor --> buffer.view --> fixnum --> boolean}
  Cursor B End ->
    (let At (net-ipv6-headers.cursor.at Cursor)
         Left (fx- End At)
      (if (= (net-ipv6-headers.cursor.protocol Cursor) 6)
          (tcp.header-fits? B At Left)
          (fx>= Left 8))))

(define fragmented-discovery?
  {net-ipv6-headers.cursor --> buffer.view --> boolean}
  Cursor B ->
    (and (= (net-ipv6-headers.cursor.protocol Cursor) 58)
         (let Kind (wire.icmp.type B (net-ipv6-headers.cursor.at Cursor))
           (and (fx>= Kind 133) (fx<= Kind 137)))))

(define reassemble6
  {interface --> ipv6-state --> net-ipv6.address --> buffer.view --> fixnum --> fixnum -->
   fixnum --> fixnum --> fixnum --> symbol --> boolean}
  F S Local B I N Frag Prev Now Scope ->
    (let Table (ipv6-state.fragments S)
         Cursor (ipv6-state.headers S)
         Length (net-fragments6.receive Table B I N Frag Prev Now)
      (and (fx> Length 0)
           (let Packet (net-fragments6.packet Table)
             (and (= (net-ipv6-headers.parse Cursor Packet 0 Length) net-ipv6-headers.upper)
                  (dispatch6 F S Local Packet 0 Length Now Scope true))))))

(define first-fragment
  {interface --> ipv6-state --> net-ipv6.address --> buffer.view --> fixnum --> fixnum -->
   fixnum --> fixnum --> fixnum --> symbol --> boolean}
  F S Local B I N Frag Prev Now Scope ->
    (let Cursor (ipv6-state.headers S)
         Next (net-ipv6-headers.after-fragment Cursor B I N)
      (cases (= Next net-ipv6-headers.problem) (complain6 F S Local B I N Now Scope)
             (or (= Next net-ipv6-headers.incomplete)
                 (and (= Next net-ipv6-headers.upper) (not (upper-fits? Cursor B (fx+ I N)))))
               (and (= Scope unicast) (error6 F S Local B I N 4 3 0 Now))
             (and (= Next net-ipv6-headers.upper) (not (fragmented-discovery? Cursor B))
                  (or (= Scope unicast) (= (net-ipv6-headers.cursor.protocol Cursor) 17)))
               (reassemble6 F S Local B I N Frag Prev Now Scope)
             true false)))

(define fragment6
  {interface --> ipv6-state --> net-ipv6.address --> buffer.view --> fixnum --> fixnum -->
   fixnum --> symbol --> boolean}
  F S Local B I N Now Scope ->
    (let Cursor (ipv6-state.headers S)
         Frag (net-ipv6-headers.cursor.at Cursor)
         Prev (net-ipv6-headers.cursor.next-field Cursor)
         Offset (fx* 8 (wire.ipv6-fragment.offset B Frag))                   \\ In bytes.
         More (= (wire.ipv6-fragment.more B Frag) 1)
         Bytes (fx- (fx+ I N) (fx+ Frag (wire.ipv6-fragment.size)))
         Remote (net-ipv6.read-address (ipv6-state.remote S) B (wire.ipv6.source-at I))
      (and (net-ipv6.unicast? Remote)
           (or (= Scope unicast) (and (= Scope multicast) (multicast-from6? F B I)))
           (cases (and (= Offset 0) (not More))
                    (let Next (net-ipv6-headers.after-fragment Cursor B I N)
                      (cases (or (= Next net-ipv6-headers.problem) (= Next net-ipv6-headers.incomplete))
                               (complain6 F S Local B I N Now Scope)
                             (= Next net-ipv6-headers.upper)
                               (dispatch6 F S Local B I N Now Scope true)
                             true false))
                  (= Bytes 0) false
                  (and More (not (= (fxremainder Bytes 8) 0)))
                    (and (= Scope unicast) (error6 F S Local B I N 4 0 (wire.ipv6.payload-length-at 0) Now))
                  (fx> (fx+ Offset Bytes) 65535)
                    (and (= Scope unicast) (error6 F S Local B I N 4 0 (fx- (wire.ipv6-fragment.offset-at Frag) I) Now))
                  (= Offset 0) (first-fragment F S Local B I N Frag Prev Now Scope)
                  true (reassemble6 F S Local B I N Frag Prev Now Scope)))))

(define packet6
  {interface --> ipv6-state --> net-ipv6.address --> buffer.view --> fixnum --> fixnum -->
   fixnum --> symbol --> boolean}
  F S Local B I N Now Scope ->
    (let Kind (net-ipv6-headers.parse (ipv6-state.headers S) B I N)
      (cases (= Kind net-ipv6-headers.upper) (dispatch6 F S Local B I N Now Scope false)
             (= Kind net-ipv6-headers.fragment) (fragment6 F S Local B I N Now Scope)
             (or (= Kind net-ipv6-headers.problem) (= Kind net-ipv6-headers.incomplete))
               (complain6 F S Local B I N Now Scope)
             true false)))

(define ingress6
  {interface --> (list ipv6-state) --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  _ [] _ _ _ _ -> false
  F [S] B I N Now ->
    (and (net-ipv6.valid-header? B I N)
         (let H (ipv6-state.ndp S)
              Local (net-ndp.host.link-local H)
              Global (net-ndp.host.global H)
              At (wire.ipv6.destination-at I)
           (cases (and (net-ndp.local-ready? H) (net-ipv6.address-at? Local B At))
                    (packet6 F S Local B I N Now unicast)
                  (and (net-ndp.global-ready? H Now) (net-ipv6.address-at? Global B At))
                    (packet6 F S Global B I N Now unicast)
                  (or (net-ndp.multicast-at? H B At Now) (joined6-at? F B At))
                    (packet6 F S Local B I N Now multicast)
                  (or (and (= (net-ndp.host.local-state H) net-ndp.tentative)
                           (net-ipv6.address-at? Local B At))
                      (and (= (net-ndp.host.global-state H) net-ndp.tentative)
                           (net-ipv6.address-at? Global B At)))
                    (packet6 F S Local B I N Now tentative)
                  true false))))

(define expire-slots6
  {interface --> ipv6-state --> net-fragments6.table --> fixnum --> fixnum --> boolean}
  _ _ _ 0 _ -> true
  F S Table Index Now ->
    (let Bytes (net-fragments6.expire Table Index Now)
      (do (if (fx> Bytes 0)
              (let Packet (net-fragments6.table.quote Table)
                   H (ipv6-state.ndp S)
                   Local (net-ndp.host.link-local H)
                   Global (net-ndp.host.global H)
                (cases (and (net-ndp.local-ready? H) (net-ipv6.address-at? Local Packet (wire.ipv6.destination-at 0)))
                         (error6 F S Local Packet 0 Bytes 3 1 0 Now)
                       (and (net-ndp.global-ready? H Now) (net-ipv6.address-at? Global Packet (wire.ipv6.destination-at 0)))
                         (error6 F S Global Packet 0 Bytes 3 1 0 Now)
                       true false))
              false)
          (expire-slots6 F S Table (fx- Index 1) Now))))

(define expire-ipv6
  {interface --> (list ipv6-state) --> fixnum --> boolean}
  _ [] _ -> true
  F [S] Now ->
    (let Table (ipv6-state.fragments S)
      (expire-slots6 F S Table (net-fragments6.table.slots Table) Now)))

(define ingress
  {interface --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  F B I N Now ->
    (and (fx> N 0)
         (if (= (wire.ipv6.version B I) 6)
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
  [S] Now -> (earlier (net-ndp.next-deadline (ipv6-state.ndp S) Now)
                     (net-fragments6.next-deadline (ipv6-state.fragments S))))

(define multicast-source
  {(list ipv6-state) --> net-multicast.membership --> net-ipv6.address}
  [] M -> (net-multicast.membership.blank6 M)
  [S] M ->
    (let H (ipv6-state.ndp S)
      (if (net-ndp.local-ready? H) (net-ndp.host.link-local H) (net-multicast.membership.blank6 M))))

(define multicast-poll
  {(list net-multicast.membership) --> (list ipv6-state) --> fixnum --> boolean}
  [] _ _ -> false
  [M] V6 Now -> (net-multicast.poll M (multicast-source V6 M) Now))

(define multicast-deadline
  {(list net-multicast.membership) --> (list ipv6-state) --> fixnum}
  [] _ -> -1
  [M] V6 -> (net-multicast.next-deadline M (net-ipv6.link-local? (multicast-source V6 M))))

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
         _ (expire-ipv6 F (interface.ipv6 F) Now)
         Count (receive-ready F (net-link.device.rx D) Now (buffer.index Budget) 0)
      (do (ipv6-poll (interface.ipv6 F) (interface.listener F) Now)
          (multicast-poll (interface.groups F) (interface.ipv6 F) Now)
          (tcp.listener-transmit (interface.listener F) Now)
          Count)))

\\ Absolute milliseconds, or -1 when only external I/O can make progress.
(define next-deadline
  {interface --> fixnum}
  F -> (let D (interface.device F)
            Now (net-link.now D)
            Rx (net-link.head-deadline (net-link.device.rx D))
            Tcp (tcp.listener-deadline (interface.listener F) Now)
         (earlier (multicast-deadline (interface.groups F) (interface.ipv6 F))
                  (earlier (ipv6-deadline (interface.ipv6 F) Now) (earlier Rx Tcp)))))

(preclude [interface.%match ipv6-state.%match])
)
