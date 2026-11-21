\\ Exercise outbound HTTP over the allocation-free stream interface.
(shen.x.namespace net-host-test
  (use buffer)
  (use net-ipv4)
  (use net-tun)
  (use net-link)
  (use net-ethernet)
  (use net-routes)
  (use net-interface)
  (use net-stream)
  (use net-dhcp)
  (use net-dns)
  (use tcp)
  (use shen-jit)
  (use tun-test)
  (import struct defstruct)
  (export tun tap)

(defstruct request-state
  (stream : net-stream.stream-handle)
  (request : buffer.view)
  (reply : buffer.view)
  (expected : buffer.view)
  (mutable written : fixnum)
  (mutable received : fixnum)
  (mutable done : boolean))

(defstruct faults
  (held : buffer.view)
  (mutable size : fixnum)
  (mutable reordered : boolean))

(define fill-body
  {buffer.view --> fixnum --> fixnum --> buffer.view}
  B At End ->
    (if (= At End) B (fill-body (buffer.u8-> B At 120) (fx+ At 1) End)))

(define expected-reply
  {boolean --> buffer.view}
  Wide ->
    (if Wide
        (let Head (buffer.from-string "HTTP/1.1 200 OKc#13;c#10;Content-Length: 2200c#13;c#10;Connection: closec#13;c#10;c#13;c#10;")
             N (buffer.length Head)
             End (fx+ N 2200)
             B (buffer.new End)
          (do (buffer.copy-into! B 0 Head 0 N) (fill-body B N End)))
        (buffer.from-string "HTTP/1.1 200 OKc#13;c#10;Content-Length: 5c#13;c#10;Connection: closec#13;c#10;c#13;c#10;hello")))

(define make-request
  {net-interface.interface --> boolean --> request-state}
  F Wide ->
    (let Expected (expected-reply Wide)
      (:request-state
        stream <- (net-stream.make F)
        request <- (buffer.from-string "GET / HTTP/1.1c#13;c#10;Host: testc#13;c#10;Connection: closec#13;c#10;c#13;c#10;")
        reply <- (buffer.new (fx+ (buffer.length Expected) 1))
        expected <- Expected
        written <- 0
        received <- 0
        done <- false)))

(define equal-bytes?
  {buffer.view --> buffer.view --> fixnum --> boolean}
  _ _ 0 -> true
  A B N -> (let I (fx- N 1)
             (and (= (buffer.u8 A I) (buffer.u8 B I)) (equal-bytes? A B I))))

(define exchange
  {request-state --> boolean}
  Q ->
    (let S (request-state.stream Q)
         State (net-stream.state S)
         Input (request-state.request Q)
         Output (request-state.reply Q)
         Written (request-state.written Q)
         Received (request-state.received Q)
      (cases (request-state.done Q) true
             (= State tcp.closed) (do (net-stream.release S) (request-state.done-> Q true) true)
             (or (= State tcp.reset) (= State tcp.timed-out))
               (error "HTTP connection stopped at ~A" State)
             true
               (let N (net-stream.write-from S Input Written (fx- (buffer.length Input) Written))
                    R (net-stream.read-into S Output Received (fx- (buffer.length Output) Received))
                 (do (request-state.written-> Q (fx+ Written N))
                     (cases (= R -1) (net-stream.shutdown-write S)
                            (fx> R 0) (do (request-state.received-> Q (fx+ Received R)) true)
                            true false)
                     (if (= (request-state.received Q) (buffer.length Output))
                         (error "HTTP fixture exceeded its reply limit") false))))))

(define correct-reply?
  {request-state --> boolean}
  Q ->
    (let Expected (request-state.expected Q)
         N (buffer.length Expected)
      (and (request-state.done Q) (= (request-state.received Q) N)
           (equal-bytes? Expected (request-state.reply Q) N))))

(define report
  {fixnum --> fixnum --> string --> boolean}
  Heap Control Label ->
    (if (= Heap 0)
        (do (output "~A used 0 Shen heap words (control ~A)~%" Label (fx->number Control)) true)
        (error "~A used ~A Shen heap words (-1 means a collection)" Label (fx->number Heap))))

(define positive-control
  {buffer.view --> fixnum}
  B ->
    (let _ (tun-test.mark 0)
         View (buffer.slice B 0 1)
         Used (tun-test.words 0)
      (if (and (= (buffer.length View) 1) (fx> Used 0)) Used
          (error "host heap probe missed a new view"))))

(define data-at-head?
  {net-link.ring --> fixnum --> boolean}
  R Now ->
    (and (net-link.ready? R Now)
         (fx> (net-link.head-length R) 40)
         (let B (net-link.ring.data R)
              I (net-link.head-offset R)
              Header (fx* 4 (shen-jit.shift-right (buffer.u8 B (fx+ I 32)) 4))
           (and (= (buffer.u8 B (fx+ I 9)) 6)
                (fx> (net-link.head-length R) (fx+ 20 Header))))))

(define drop-first-data
  {net-link.device --> boolean}
  Wire ->
    (let R (net-link.device.rx Wire)
      (and (data-at-head? R (net-link.now Wire)) (net-link.consume R))))

(define reorder-data
  {net-interface.interface --> net-link.device --> faults --> boolean}
  F Wire Faults ->
    (let R (net-link.device.tx Wire)
         Now (net-link.now Wire)
      (if (or (faults.reordered Faults) (not (data-at-head? R Now))) false
          (let B (net-link.ring.data R)
               I (net-link.head-offset R)
               Held (faults.held Faults)
               N (faults.size Faults)
            (cases (= N 0)
                     (let Count (net-link.head-length R)
                       (do (buffer.copy-into! Held 0 B I Count)
                           (faults.size-> Faults Count)
                           (net-link.consume R)
                           (reorder-data F Wire Faults)))
                   (= (buffer.u32-be Held 24) (buffer.u32-be B (fx+ I 24)))
                     (net-link.consume R)
                   true
                     (do (net-interface.poll F 1)
                         (buffer.copy-into! B (net-link.tail-offset R) Held 0 N)
                         (net-link.publish R N Now)
                         (faults.reordered-> Faults true)
                         true))))))

(define tun-input
  {net-interface.interface --> net-link.device --> faults --> fixnum --> boolean}
  _ _ _ 0 -> true
  F Wire Faults Budget ->
    (let _ (reorder-data F Wire Faults)
         R (net-link.device.tx Wire)
      (if (net-link.ready? R (net-link.now Wire))
          (do (net-interface.poll F 1)
              (tun-input F Wire Faults (fx- Budget 1)))
          (do (net-interface.poll F 0) true))))

(define tun-pump
  {net-tun.adapter --> net-link.device --> boolean --> boolean}
  Device Wire Dropped ->
    (let Lost (or Dropped (drop-first-data Wire))
      (do (net-tun.pump Device (if Lost 8 1)) Lost)))

(define tun-loop
  {net-tun.adapter --> net-link.device --> net-interface.interface --> request-state -->
   faults --> fixnum --> boolean --> boolean}
  Device Wire F Q Faults Until Dropped ->
    (let First (tun-pump Device Wire Dropped)
         _ (tun-input F Wire Faults 8)
         Second (tun-pump Device Wire First)
         _ (exchange Q)
         _ (tun-input F Wire Faults 8)
         Lost (tun-pump Device Wire Second)
      (cases (request-state.done Q) (and Lost (faults.reordered Faults) (correct-reply? Q))
             (fx>= (net-tun.monotonic 0) Until) (error "TUN outbound HTTP timed out")
             true (do (net-tun.wait Device 5) (tun-loop Device Wire F Q Faults Until Lost)))))

(define measure-tun
  {net-tun.adapter --> net-link.device --> net-interface.interface --> request-state --> fixnum --> boolean}
  Device Wire F Q Server ->
    (let Control (positive-control (request-state.reply Q))
         Until (fx+ (net-tun.monotonic 0) 12000)
         Faults (:faults
                   held <- (buffer.new 1500)
                   size <- 0
                   reordered <- false)
         _ (tun-test.mark 0)
         _ (if (net-stream.connect (request-state.stream Q) Server 8080) true (error "cannot open HTTP stream"))
         Good (tun-loop Device Wire F Q Faults Until false)
         Heap (tun-test.words 0)
      (if Good (report Heap Control "TUN outbound HTTP with TCP loss and reordering")
          (error "TUN outbound HTTP reply or fault injection check failed"))))

(define tun
  {string --> boolean}
  Name ->
    (let Cable (net-link.make 8 1500 0 (freeze (net-tun.monotonic 0)))
         Wire (net-link.right Cable)
         F (net-interface.make-host (net-link.left Cable) (net-ipv4.address 198 51 100 2)
             (:net-interface.setup tcp-ports <- [] tcp-slots <- 1 tcp-buffer <- 0 time-waits <- 16
                                   udp-ports <- [] udp-slots <- 0 key0 <- 22703 key1 <- 42166))
         Q (make-request F true)
         Device (net-tun.attach Wire Name)
         Server (net-ipv4.address 198 51 100 1)
      (shen-jit.finally (freeze (measure-tun Device Wire F Q Server)) (freeze (net-tun.close Device)))))

(define tap-poll
  {net-tun.adapter --> net-ethernet.adapter --> fixnum}
  Device Eth ->
    (let A (net-tun.pump Device 8)
         B (net-ethernet.pump Eth 8)
         C (net-tun.pump Device 8)
      (fx+ A (fx+ B C))))

(define obtain-lease
  {net-tun.adapter --> net-ethernet.adapter --> net-dhcp.client --> fixnum --> boolean}
  Device Eth D Until ->
    (do (tap-poll Device Eth)
        (cases (= (net-dhcp.poll D 8) net-dhcp.bound) true
               (fx>= (net-tun.monotonic 0) Until) (error "TAP DHCP acquisition timed out")
               true (do (tap-poll Device Eth)
                        (net-tun.wait Device 5)
                        (obtain-lease Device Eth D Until)))))

(define tap-loop
  {net-tun.adapter --> net-ethernet.adapter --> net-interface.interface --> net-dhcp.client -->
   net-dns.resolver --> request-state --> fixnum --> fixnum --> boolean --> boolean}
  Device Eth F D R Q Until InitialLease Started ->
    (let _ (tap-poll Device Eth)
         _ (net-interface.poll F 8)
         NewState (net-dhcp.maintain D (net-interface.udp-binding F 68) 8)
         DNS (net-dns.poll R (net-tun.monotonic 0))
         Active (or Started
                    (and (= DNS net-dns.resolved)
                         (= (net-dns.resolver.ip R) (net-dhcp.client.dns D))
                         (net-stream.connect (request-state.stream Q) (net-dns.resolver.ip R) 8080)))
         _ (if Active (exchange Q) false)
         _ (net-interface.poll F 8)
         _ (tap-poll Device Eth)
      (cases (and (request-state.done Q) (fx> (net-dhcp.client.expires D) InitialLease))
               (and (= (net-dns.resolver.ttl R) 42) (correct-reply? Q))
             (or (= DNS net-dns.failed) (= DNS net-dns.not-found) (= NewState net-dhcp.expired)
                 (fx>= (net-tun.monotonic 0) Until))
               (error "TAP host exchange failed at DHCP ~A DNS ~A" NewState DNS)
             true (do (net-tun.wait Device 5)
                      (tap-loop Device Eth F D R Q Until InitialLease Active)))))

(define tap-http
  {net-tun.adapter --> net-ethernet.adapter --> net-link.device --> net-dhcp.client --> boolean}
  Device Eth Cable D ->
    (let IP (net-dhcp.client.address D)
         Gateway (net-dhcp.client.gateway D)
         DNS (net-dhcp.client.dns D)
         _ (if (and (= (net-dhcp.client.mask D) 4294967168) (fx> Gateway 0) (fx> DNS 0)) true
               (error "DHCP lease omitted fixture network settings"))
         Local (net-routes.make IP 25 0)
         Default (net-routes.make 0 0 Gateway)
         _ (net-ethernet.configure Eth IP [Default Local])
         F (net-interface.make-host Cable IP
             (:net-interface.setup tcp-ports <- [] tcp-slots <- 2 tcp-buffer <- 0 time-waits <- 16
                                   udp-ports <- [68 53333] udp-slots <- 2 key0 <- 1066 key1 <- 1126))
         R (net-dns.make (net-interface.udp-binding F 53333) 1472)
         Name (buffer.from-string "c#4;testc#0;")
         Q (make-request F false)
         Control (positive-control (request-state.reply Q))
         Now (net-tun.monotonic 0)
         Initial (net-dhcp.client.expires D)
         _ (tun-test.mark 0)
         _ (if (net-dns.start R DNS 38111 Name Now) true (error "cannot start DNS request"))
         Good (tap-loop Device Eth F D R Q (fx+ Now 12000) Initial false)
         Heap (tun-test.words 0)
      (if Good (report Heap Control "TAP gateway DNS, outbound HTTP, and DHCP renewal")
          (error "TAP HTTP contents or DNS TTL differed"))))

(define tap-session
  {net-tun.adapter --> net-ethernet.adapter --> net-link.device --> net-dhcp.client --> boolean}
  Device Eth Cable D ->
    (let Control (positive-control (buffer.new 8))
         Until (fx+ (net-tun.monotonic 0) 12000)
         _ (tun-test.mark 0)
         _ (obtain-lease Device Eth D Until)
         Heap (tun-test.words 0)
      (and (report Heap Control "TAP DHCP acquisition")
           (tap-http Device Eth Cable D))))

(define tap
  {string --> boolean}
  Name ->
    (let Clock (freeze (net-tun.monotonic 0))
         Frames (net-link.make 8 1514 0 Clock)
         Packets (net-link.make 8 1500 0 Clock)
         Cable (net-link.left Packets)
         Mac (net-ethernet.hardware 512 22)
         Eth (net-ethernet.make (net-link.left Frames) (net-link.right Packets) Mac 0 [] 4)
         D (net-dhcp.make Cable Mac 571727655)
         Device (net-tun.attach-tap (net-link.right Frames) Name)
      (shen-jit.finally (freeze (tap-session Device Eth Cable D)) (freeze (net-tun.close Device)))))

(preclude [request-state.%match faults.%match])
)
