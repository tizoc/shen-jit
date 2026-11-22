(shen.x.namespace net-ipv6-test
  (use buffer)
  (use net-link)
  (use net-ipv4)
  (use net-ipv6)
  (use net-ndp)
  (use net-interface)
  (use tcp)
  (use udp)
  (import struct defstruct)
  (shadow run)
  (export run clock expect)

(define expect
  {boolean --> string --> boolean}
  true _ -> true
  false Name -> (error "IPv6 test failed at ~A" Name))

(define clock
  {--> (vector fixnum)}
  -> (fxvector-> (vector 1) 1 0))

(define host
  {net-link.device --> fixnum --> net-ipv6.address --> fixnum --> net-interface.interface}
  D V4 V6 Id ->
    (let H (net-ndp.make D 0 0 Id 0)
         F (net-interface.make-host D V4
             (:net-interface.setup tcp-ports <- [80] tcp-slots <- 2 tcp-buffer <- 8192 time-waits <- 16
                                   udp-ports <- [7] udp-slots <- 2 key0 <- 1234 key1 <- 35))
      (do (net-ndp.configure-static H V6)
          (net-interface.enable-ipv6 F H)
          F)))

(define pair-poll
  {net-interface.interface --> net-interface.interface --> fixnum --> boolean}
  _ _ 0 -> true
  C S N ->
    (do (net-interface.poll C 8)
        (net-interface.poll S 8)
        (pair-poll C S (fx- N 1))))

(define put-icmp6-checksum
  {buffer.view --> fixnum --> buffer.view}
  B N -> (buffer.u16-be-> B 42 (net-ipv6.transport-checksum B 0 58 (fx- N 40))))

(define udp-checks
  {net-link.device --> net-link.device --> net-interface.interface --> net-interface.interface -->
   net-ipv6.address --> net-ipv6.address --> boolean}
  Left Right C S A B ->
    (let P (buffer.from-string "hello")
         Out (buffer.new 5)
         Info (udp.make-recv-info)
         Inbox (net-interface.udp-binding S 7)
         Wire (buffer.new 1500)
         Source (net-interface.udp-binding C 7)
      (do (expect (= (net-interface.udp-send6 C 7 B 7 P 5) udp.sent) "send IPv6 UDP")
          (expect (= (net-link.packet-recv-into Right Wire) 53) "capture IPv6 UDP")
          (buffer.u16-be-> Wire 46 0)
          (net-link.packet-send Left Wire 53)
          (net-interface.poll S 1)
          (expect (= (udp.inbox-recv-into Inbox Out Info) udp.empty) "reject zero UDP checksum")
          (net-interface.udp-send6 C 7 B 7 P 5)
          (net-interface.poll S 1)
          (expect (and (= (udp.inbox-recv-into Inbox Out Info) udp.received)
                       (= (udp.recv-info.family Info) 6)
                       (net-ipv6.same? (udp.recv-info.source6 Info) A)
                       (net-ipv6.same? (udp.recv-info.destination6 Info) B)
                       (buffer.equal? P Out)) "IPv6 receive metadata and payload")
          (net-interface.udp-send6 C 7 B 7 P 5)
          (expect (= (net-link.packet-recv-into Right Wire) 53) "capture IPv6 UDP again")
          (buffer.u8-> Wire 7 0)
          (net-link.packet-send Left Wire 53)
          (net-interface.poll S 1)
          (expect (= (udp.inbox-recv-into Inbox Out Info) udp.received) "take a Hop Limit of 0, RFC 8200 3")
          (udp.send6 (udp.inbox.peer Source) A B 8 P 5)
          (net-interface.poll S 1)
          (expect (= (net-link.packet-recv-into Left Wire) 101) "IPv6 unbound UDP port response")
          (expect (and (= (buffer.u16-be Wire 40) 260)
                       (= (buffer.u16-be Wire 90) 8)
                       (= (net-ipv6.transport-checksum Wire 0 58 61) 0)) "ICMPv6 quote and checksum"))))

(define pmtu
  {net-link.device --> net-interface.interface --> net-interface.interface -->
   net-ipv6.address --> net-ipv6.address --> boolean}
  Right C S A B ->
    (let L (net-interface.interface.listener C)
         Payload (buffer.new 1440)
         Wire (buffer.new 1500)
         TooBig (buffer.new 96)
         T (net-interface.connect6 C B 80)
      (do (expect (fx> T 0) "start IPv6 TCP")
          (pair-poll C S 4)
          (expect (tcp.connection-writable? L T) "IPv6 TCP established")
          (expect (= (tcp.connection-send L T Payload 1440) 1440) "queue full-size IPv6 TCP segment")
          (net-interface.poll C 0)
          (expect (= (net-link.packet-recv-into Right Wire) 1500) "IPv6 segment at local MTU")
          (net-ipv6.write-header TooBig 0 96 58 64 B A)
          (buffer.u32-be-> TooBig 40 33554432)
          (buffer.u32-be-> TooBig 44 1280)
          (buffer.copy-into! TooBig 48 Wire 0 48)
          (put-icmp6-checksum TooBig 96)
          (net-link.packet-send Right TooBig 96)
          (net-interface.poll C 1)
          (expect (= (net-link.packet-recv-into Right Wire) 1280) "retry at reduced IPv6 path MTU")
          (expect (= (net-ipv6.transport-checksum Wire 0 6 1240) 0) "IPv6 replay checksum")
          (tcp.expire-addresses6 L A false B true)
          (expect (= (tcp.connection-state L T) tcp.reset) "expired source cancels active TCP"))))

(define transports
  {--> boolean}
  -> (let Time (clock)
          Link (net-link.make 8 1500 0 (freeze (fx<-vector Time 1)))
          Left (net-link.left Link)
          Right (net-link.right Link)
          A (net-ipv6.make-address 536939960 0 0 1)
          B (net-ipv6.make-address 536939960 0 0 2)
          C (host Left (net-ipv4.address 192 0 2 1) A 1)
          S (host Right (net-ipv4.address 192 0 2 2) B 2)
       (do (expect (= (net-interface.connect6 C B 80) 0) "tentative source cannot connect")
           (pair-poll C S 2)
           (fxvector-> Time 1 1000)
           (pair-poll C S 2)
           (udp-checks Left Right C S A B)
           (pmtu Right C S A B))))

(defstruct discovery
  (time : (vector fixnum))
  (ndp : net-ndp.host)
  (peer : net-link.device)
  (wire : buffer.view)
  (router : net-ipv6.address)
  (nodes : net-ipv6.address)
  (prefix : net-ipv6.address)
  (address : net-ipv6.address))

(define discovery-case
  {fixnum --> discovery}
  Id -> (let Time (clock)
             Link (net-link.make 8 1280 0 (freeze (fx<-vector Time 1)))
       (:discovery
         time <- Time
         ndp <- (net-ndp.make (net-link.left Link) 0 0 Id 0)
         peer <- (net-link.right Link)
         wire <- (buffer.new 1280)
         router <- (net-ipv6.make-address 4269801472 0 0 1)
         nodes <- (net-ipv6.make-address 4278321152 0 0 1)
         prefix <- (net-ipv6.make-address 536939960 65536 0 0)
         address <- (net-ipv6.make-address 536939960 65536 0 Id))))

(define ra
  {discovery --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  S Hop Valid Preferred Now ->
    (let B (discovery.wire S)
      (do (net-ipv6.write-header B 0 88 58 Hop (discovery.router S) (discovery.nodes S))
          (buffer.u32-be-> B 40 2248146944)
          (buffer.u32-be-> B 44 1073741884)
          (buffer.u32-be-> B 48 0)
          (buffer.u32-be-> B 52 0)
          (buffer.u32-be-> B 56 50610368)
          (buffer.u32-be-> B 60 Valid)
          (buffer.u32-be-> B 64 Preferred)
          (buffer.u32-be-> B 68 0)
          (net-ipv6.write-address B 72 (discovery.prefix S))
          (put-icmp6-checksum B 88)
          (net-ndp.ingress (discovery.ndp S) B 0 88 Now))))

(define advertise
  {discovery --> fixnum --> boolean}
  S Now ->
    (let B (discovery.wire S)
         Target (discovery.address S)
      (do (net-ipv6.write-header B 0 64 58 255 Target (discovery.nodes S))
          (buffer.u32-be-> B 40 2281701376)
          (buffer.u32-be-> B 44 0)
          (net-ipv6.write-address B 48 Target)
          (put-icmp6-checksum B 64)
          (net-ndp.ingress (discovery.ndp S) B 0 64 Now))))

(define prepare-discovery
  {discovery --> boolean}
  F ->
    (let H (discovery.ndp F)
         D (discovery.peer F)
         Wire (discovery.wire F)
      (do (net-ndp.poll H 0)
          (expect (= (net-link.packet-recv-into D Wire) 64) "link-local DAD uses no source option")
          (expect (and (not (net-ndp.local-ready? H)) (= (net-ndp.next-deadline H 0) 1000))
                  "link-local address is tentative for one second")
          (fxvector-> (discovery.time F) 1 1000)
          (net-ndp.poll H 1000)
          (expect (net-ndp.local-ready? H) "link-local ready before RS")
          (expect (and (= (net-link.packet-recv-into D Wire) 48) (= (buffer.u8 Wire 40) 133))
                  "router solicitation format")
          (expect (and (not (ra F 64 120 60 1000)) (= (net-ndp.host.global-state H) net-ndp.absent))
                  "reject off-link RA hop limit")
          (expect (ra F 255 120 60 1000) "accept on-link RA")
          (net-ndp.poll H 1000)
          (expect (and (= (net-ndp.host.global-state H) net-ndp.tentative)
                       (net-ipv6.same? (net-ndp.host.global H) (discovery.address F))
                       (= (net-link.packet-recv-into D Wire) 64)) "prefix forms tentative address"))))

(define lifetimes
  {--> boolean}
  -> (let F (discovery-case 2)
          H (discovery.ndp F)
       (do (prepare-discovery F)
           (net-ndp.poll H 2000)
           (expect (and (net-ndp.global-ready? H 2000)
                        (= (net-ndp.host.preferred-until H) 61000)
                        (= (net-ndp.host.valid-until H) 121000)
                        (net-ipv6.same? (net-ndp.host.router H) (discovery.router F))) "SLAAC and route lifetimes")
           (ra F 255 2 0 3000)
           (expect (and (= (net-ndp.host.preferred-until H) 3000)
                        (= (net-ndp.host.valid-until H) 121000)) "short RA deprecates without invalidating")
           (net-ndp.poll H 121000)
           (expect (and (not (net-ndp.global-ready? H 121000))
                        (= (net-ndp.host.global-state H) net-ndp.absent)) "address expires"))))

(define duplicate-address
  {--> boolean}
  -> (let F (discovery-case 2)
          H (discovery.ndp F)
       (do (prepare-discovery F)
           (expect (advertise F 1500) "process conflicting neighbor advertisement")
           (net-ndp.poll H 2000)
           (expect (and (not (net-ndp.global-ready? H 2000))
                        (= (net-ndp.host.global-state H) net-ndp.duplicate)) "DAD rejects duplicate address"))))

(define run
  {--> boolean}
  -> (do (transports)
         (lifetimes)
         (duplicate-address)
         (output "3 passed, 0 failed~%")
         true))

(preclude [discovery.%match])
)
