\\ Run IPv4 and IPv6 applications on the same interface and heap measurement.
(shen.x.namespace net-dual-test
  (use buffer)
  (use net-link)
  (use net-tun)
  (use net-ipv4)
  (use net-ipv6)
  (use net-interface)
  (use net-ndp)
  (use net-ethernet)
  (use net-routes)
  (use tcp)
  (use net-stream)
  (use udp)
  (use shen-jit)
  (use tun-test)
  (import struct defstruct)
  (export tap tun)

(defstruct session
  (scratch : buffer.view)
  (mutable token : fixnum)
  (mutable pending : fixnum)
  (mutable eof : boolean))

(defstruct server
  (interface : net-interface.interface)
  (ipv6 : net-ndp.host)
  (sessions : (vector session))
  (inbox : udp.inbox)
  (udp-out : buffer.view)
  (udp-info : udp.recv-info)
  (outbound : net-stream.stream-handle)
  (remote6 : net-ipv6.address)
  (expected6 : net-ipv6.address)
  (offlink : (list net-ipv6.address))
  (mutable route-sent : boolean)
  (mutable route-reply : boolean)
  (payload : buffer.view)
  (reply : buffer.view)
  (mutable udp-pending : boolean)
  (mutable udp4 : fixnum)
  (mutable udp6 : fixnum)
  (mutable opened : boolean)
  (mutable sent : fixnum)
  (mutable received : fixnum)
  (mutable outgoing-done : boolean)
  (mutable closed : fixnum)
  (mutable bytes : fixnum))

(define sessions
  {(vector session) --> fixnum --> (vector session)}
  V 0 -> V
  V I ->
    (let S (:session
              scratch <- (buffer.new 997)
              token <- 0
              pending <- 0
              eof <- false)
      (sessions (fxvector-> V I S) (fx- I 1))))

(define make-server
  {net-link.device --> fixnum --> net-ndp.host --> net-ipv6.address --> net-ipv6.address -->
   (list net-ipv6.address) --> server}
  D IP H Remote Guest Offlink ->
    (let F (net-interface.make-host D IP
             (:net-interface.setup tcp-ports <- [7777] tcp-slots <- 3 tcp-buffer <- 16384 time-waits <- 16
                                   udp-ports <- [7777] udp-slots <- 4 key0 <- 52 key1 <- 92))
         _ (net-interface.enable-ipv6 F H)
         P (buffer.from-string "outbound IPv6 stream")
      (:server
        interface <- F
        ipv6 <- H
        sessions <- (sessions (vector 3) 3)
        inbox <- (net-interface.udp-binding F 7777)
        udp-out <- (buffer.new 4096)
        udp-info <- (udp.make-recv-info)
        outbound <- (net-stream.make F)
        remote6 <- Remote
        expected6 <- Guest
        offlink <- Offlink
        route-sent <- (= Offlink [])
        route-reply <- (= Offlink [])
        payload <- P
        reply <- (buffer.new (buffer.length P))
        udp-pending <- false
        udp4 <- 0
        udp6 <- 0
        opened <- false
        sent <- 0
        received <- 0
        outgoing-done <- false
        closed <- 0
        bytes <- 0)))

(define listener
  {server --> tcp.listener}
  S -> (net-interface.interface.listener (server.interface S)))

(define accept-streams
  {server --> boolean}
  S ->
    (let L (listener S)
         T (tcp.accept-on L 7777)
      (if (= T 0) true
          (let Session (fx<-vector (server.sessions S) (tcp.connection-index L T))
            (do (session.token-> Session T)
                (session.pending-> Session 0)
                (session.eof-> Session false)
                (accept-streams S))))))

(define echo-stream
  {server --> session --> boolean}
  S Session ->
    (let T (session.token Session)
         L (listener S)
         Phase (tcp.connection-state L T)
      (cases (= Phase tcp.closed)
               (do (tcp.release L T)
                   (session.token-> Session 0)
                   (server.closed-> S (fx+ (server.closed S) 1))
                   true)
             (or (= Phase tcp.timed-out) (= Phase tcp.reset))
               (error "dual-stack echo stream stopped at ~A" Phase)
             true (let B (session.scratch Session)
                       Pending (session.pending Session)
                       N (if (and (= Pending 0) (not (session.eof Session)))
                             (tcp.connection-recv-into L T B (buffer.length B)) 0)
                       Available (if (fx> N 0) N Pending)
                       Written (if (fx> Available 0) (tcp.connection-send L T B Available) 0)
                       Left (fx- Available Written)
                    (do (if (= N -1) (session.eof-> Session true) Session)
                        (if (and (fx> Written 0) (fx> Left 0)) (buffer.copy-into! B 0 B Written Left) B)
                        (session.pending-> Session Left)
                        (server.bytes-> S (fx+ (server.bytes S) Written))
                        (if (and (session.eof Session) (= Left 0) (= Phase tcp.close-wait))
                            (tcp.connection-shutdown-write L T) false)
                        true)))))

(define streams
  {server --> fixnum --> boolean}
  _ 0 -> true
  S I ->
    (let Session (fx<-vector (server.sessions S) I)
      (do (if (fx> (session.token Session) 0) (echo-stream S Session) false)
          (streams S (fx- I 1)))))

(define route-probe
  {server --> (list net-ipv6.address) --> boolean}
  _ [] -> true
  S [Destination] ->
    (if (or (server.route-sent S) (not (server.outgoing-done S))) false
        (let Payload (server.payload S)
             Status (net-interface.udp-send6 (server.interface S) 7777 Destination 7779
                                             Payload (buffer.length Payload))
          (cases (= Status udp.sent) (do (server.route-sent-> S true) true)
                 (= Status udp.would-block) false
                 true (error "cannot send IPv6 UDP probe via the default router")))))

(define route-received
  {server --> (list net-ipv6.address) --> udp.recv-info --> boolean}
  _ [] _ -> false
  S [Destination] Info ->
    (and (= (udp.recv-info.family Info) 6) (= (udp.recv-info.port Info) 7779)
         (= (udp.recv-info.length Info) (buffer.length (server.payload S)))
         (net-ipv6.same? (udp.recv-info.source6 Info) Destination)
         (do (server.route-reply-> S true) true)))

(define fragment-pattern?
  {buffer.view --> fixnum --> fixnum --> boolean}
  B At Count ->
    (or (= At Count)
        (and (= (buffer.u8 B At) (fxremainder At 251))
             (fragment-pattern? B (fx+ At 1) Count))))

(define echo-length
  {buffer.view --> fixnum --> fixnum}
  B N ->
    (cases (fx<= N 1452) N
           (and (= N 2189) (fragment-pattern? B 0 N)) 64
           true (error "reassembled IPv6 UDP contents differed")))

(define udp-echo
  {server --> boolean}
  S ->
    (let F (server.interface S)
         B (server.udp-out S)
         Info (server.udp-info S)
      (if (or (server.udp-pending S) (= (udp.inbox-recv-into (server.inbox S) B Info) udp.received))
          (if (route-received S (server.offlink S) Info) true
              (let V4 (= (udp.recv-info.family Info) 4)
                   N (echo-length B (udp.recv-info.length Info))
                   Port (udp.recv-info.port Info)
                   Status (if V4 (net-interface.udp-send F (udp.recv-info.source Info) Port B N)
                              (udp.send6 (udp.inbox.peer (server.inbox S))
                                         (udp.recv-info.destination6 Info) (udp.recv-info.source6 Info) Port B N))
                (cases (= Status udp.sent)
                         (do (if V4 (server.udp4-> S (fx+ (server.udp4 S) 1))
                                 (server.udp6-> S (fx+ (server.udp6 S) 1)))
                             (server.udp-pending-> S false)
                             true)
                       (= Status udp.would-block) (do (server.udp-pending-> S true) false)
                       true (error "dual-stack UDP reply failed at ~A" Status))))
          false)))

(define open-outbound
  {server --> fixnum --> boolean}
  S Now ->
    (if (and (not (server.opened S)) (net-ndp.global-ready? (server.ipv6 S) Now))
        (if (net-ipv6.same? (net-ndp.host.global (server.ipv6 S)) (server.expected6 S))
            (and (net-stream.connect6 (server.outbound S) (server.remote6 S) 7778)
                 (do (server.opened-> S true) (tun-test.notify 2)))
            (error "unexpected IPv6 address after duplicate address detection"))
        false))

(define outbound
  {server --> boolean}
  S ->
    (if (and (server.opened S) (not (server.outgoing-done S)))
        (let Stream (server.outbound S)
             State (net-stream.state Stream)
             B (server.reply S)
             P (server.payload S)
             Sent (server.sent S)
             Received (server.received S)
             Length (buffer.length P)
          (cases (= State tcp.closed)
                   (if (and (= Received Length) (buffer.equal? B P) (net-stream.release Stream))
                       (do (server.outgoing-done-> S true) true)
                       (error "outbound IPv6 TCP echo differed"))
                 (or (= State tcp.timed-out) (= State tcp.reset))
                   (error "outbound IPv6 stream stopped at ~A" State)
                 true (let N (net-stream.write-from Stream P Sent (fx- Length Sent))
                           R (net-stream.read-into Stream B Received (fx- Length Received))
                        (do (server.sent-> S (fx+ Sent N))
                            (if (fx> R 0) (server.received-> S (fx+ Received R)) S)
                            (if (and (= State tcp.close-wait) (= (server.received S) Length))
                                (net-stream.shutdown-write Stream) false)
                            true))))
        false))

(define drive
  {net-tun.adapter --> (fixnum --> fixnum) --> server --> fixnum --> fixnum}
  Device Ethernet S Until ->
    (let _ (net-tun.pump Device 16)
         _ (Ethernet 16)
         F (server.interface S)
         _ (net-interface.poll F 16)
         Now (net-tun.monotonic 0)
         _ (open-outbound S Now)
         _ (accept-streams S)
         _ (streams S 3)
         _ (outbound S)
         _ (route-probe S (server.offlink S))
         _ (udp-echo S)
         _ (net-interface.poll F 16)
         _ (Ethernet 16)
         _ (net-tun.pump Device 16)
      (cases (and (= (server.closed S) 2) (server.outgoing-done S) (server.route-reply S)
                  (= (server.udp4 S) 2) (= (server.udp6 S) 4)) (server.bytes S)
             (fx>= Now Until)
               (error "dual-stack timeout in IPv6 state ~A with ~A TCP closes and ~A IPv4 / ~A IPv6 UDP echoes"
                      (net-ndp.host.global-state (server.ipv6 S))
                      (fx->number (server.closed S)) (fx->number (server.udp4 S)) (fx->number (server.udp6 S)))
             true (do (net-tun.wait Device 2) (drive Device Ethernet S Until)))))

(define measured
  {net-tun.adapter --> (fixnum --> fixnum) --> server --> boolean}
  Device Ethernet S ->
    (let _ (tun-test.mark 0)
         Slice (buffer.slice (server.udp-out S) 0 1)
         Control (tun-test.words 0)
         _ (if (and (= (buffer.length Slice) 1) (fx> Control 0)) true (error "missing heap positive control"))
         Until (fx+ (net-tun.monotonic 0) 25000)
         _ (tun-test.notify 0)
         _ (tun-test.mark 0)
         N (drive Device Ethernet S Until)
         Heap (tun-test.words 0)
      (if (= Heap 0)
          (do (output "Dual stack echoed ~A TCP bytes and six UDP datagrams, 0 Shen heap words (control ~A)~%"
                      (fx->number N) (fx->number Control))
              true)
          (error "dual stack used ~A Shen heap words (-1 means a collection)" (fx->number Heap)))))

(define tun
  {string --> boolean}
  Name ->
    (let Link (net-link.make 16 1500 0 (freeze (net-tun.monotonic 0)))
         D (net-link.left Link)
         H (net-ndp.make D 0 0 32 0)
         Local (net-ipv6.make-address 536939960 5242880 0 32)
         Remote (net-ipv6.make-address 536939960 5242880 0 1)
         _ (net-ndp.configure-static H Local)
         S (make-server D (net-ipv4.address 192 0 2 18) H Remote Local [])
         Device (net-tun.attach (net-link.right Link) Name)
         NoEthernet (/. Budget (fx- Budget Budget))
      (shen-jit.finally (freeze (measured Device NoEthernet S)) (freeze (net-tun.close Device)))))

(define tap
  {string --> boolean}
  Name ->
    (let Clock (freeze (net-tun.monotonic 0))
         Link (net-link.make 16 1500 0 Clock)
         Frames (net-link.make 16 1514 0 Clock)
         D (net-link.left Link)
         Mac (net-ethernet.hardware 512 32)
         IP (net-ipv4.address 192 0 2 34)
         H (net-ndp.make D Mac 0 32 4)
         Local (net-ipv6.make-address 536939960 6291456 0 32)
         Remote (net-ipv6.make-address 536939960 6291456 0 1)
         Offlink (net-ipv6.make-address 536939960 6356992 0 1)
         S (make-server D IP H Remote Local [Offlink])
         Ethernet (net-ethernet.make (net-link.left Frames) (net-link.right Link) Mac IP
                                      [(net-routes.make IP 29 0)] 4)
         _ (net-ethernet.enable-ipv6 Ethernet H)
         Device (net-tun.attach-tap (net-link.right Frames) Name)
         Pump (/. Budget (net-ethernet.pump Ethernet Budget))
      (shen-jit.finally (freeze (measured Device Pump S)) (freeze (net-tun.close Device)))))

(preclude [server.%match session.%match])
)
