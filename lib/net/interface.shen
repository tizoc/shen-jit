\\ One IPv4 ingress owner for TCP, UDP, and ICMP echo.
(shen.x.namespace net-interface
  (use buffer)
  (use net-ipv4)
  (use net-link)
  (use tcp)
  (use udp)
  (import struct defstruct)
  (export interface interface.listener make poll udp-send udp-recv-into udp-dropped)

(defstruct interface
  (device : net-link.device)
  (ip : fixnum)
  (listener : tcp.listener)
  (udp : udp.inbox))

(define make
  {net-link.device --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> interface}
  D IP TcpPort TcpSlots InitialSequence UdpPort UdpSlots ->
    (:interface
      device <- D
      ip <- IP
      listener <- (tcp.make-listener D IP TcpPort TcpSlots InitialSequence)
      udp <- (udp.make-inbox D IP UdpPort UdpSlots)))

(define udp-send
  {interface --> fixnum --> fixnum --> buffer.view --> fixnum --> symbol}
  F IP Port Payload Count -> (udp.send (udp.inbox.peer (interface.udp F)) IP Port Payload Count))

(define udp-recv-into
  {interface --> buffer.view --> udp.recv-info --> symbol}
  F Out Info -> (udp.inbox-recv-into (interface.udp F) Out Info))

(define udp-dropped
  {interface --> fixnum}
  F -> (udp.inbox.dropped (interface.udp F)))

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

(define ingress
  {interface --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  F B I N Now ->
    (if (fx< N 20) false
        (let Proto (buffer.u8 B (fx+ I 9))
          (cases (= Proto 6) (tcp.listener-ingress (interface.listener F) B I N Now)
                 (= Proto 17) (udp.inbox-ingress (interface.udp F) B I N)
                 (= Proto 1) (echo-request F B I N Now)
                 true false))))

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
      (do (tcp.listener-transmit (interface.listener F) Now)
          Count)))

(preclude [interface.%match])
)
