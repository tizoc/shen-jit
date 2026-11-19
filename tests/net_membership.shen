(shen.x.namespace net-membership-test
  (use buffer)
  (use net-link)
  (use net-ipv4)
  (use net-ipv6)
  (use net-multicast)
  (use net-ipv6-headers)
  (import struct defstruct)
  (shadow run)
  (export run)

(defstruct fixture
  (members : net-multicast.membership)
  (left : net-link.device)
  (right : net-link.device)
  (time : (vector fixnum))
  (wire : buffer.view)
  (local6 : net-ipv6.address)
  (querier6 : net-ipv6.address)
  (nodes6 : net-ipv6.address)
  (group6 : net-ipv6.address)
  (group4 : fixnum))

(define expect
  {boolean --> string --> boolean}
  true _ -> true
  false Place -> (error "multicast check failed at ~A" Place))

(define test-clock
  {fixnum --> (vector fixnum)}
  Now -> (fxvector-> (vector 1) 1 Now))

(define setup
  {fixnum --> fixnum --> fixture}
  Slots Sources ->
    (let Time (test-clock 0)
         Link (net-link.make 1 1280 0 (freeze (fx<-vector Time 1)))
         Left (net-link.left Link)
         Right (net-link.right Link)
         IP (net-ipv4.address 192 0 2 1)
      (:fixture
        members <- (net-multicast.make-sized Left IP Slots Sources 121)
        left <- Left
        right <- Right
        time <- Time
        wire <- (buffer.new 1280)
        local6 <- (net-ipv6.make-address 4269801472 0 0 1)
        querier6 <- (net-ipv6.make-address 4269801472 0 0 2)
        nodes6 <- (net-ipv6.make-address 4278321152 0 0 1)
        group6 <- (net-ipv6.make-address 4279369728 0 0 100)
        group4 <- (net-ipv4.address 239 1 2 3))))

(define poll
  {fixture --> fixnum --> boolean}
  F Now ->
    (do (fxvector-> (fixture.time F) 1 Now)
        (net-multicast.poll (fixture.members F) (fixture.local6 F) Now)))

(define take
  {fixture --> fixnum}
  F -> (net-link.packet-recv-into (fixture.right F) (fixture.wire F)))

(define joins
  {fixture --> boolean}
  F ->
    (let M (fixture.members F)
      (and (net-multicast.join4 M (fixture.group4 F) 0)
           (net-multicast.join6 M (fixture.group6 F) 0))))

(define capacity
  {fixnum --> boolean}
  Slots ->
    (let F (setup Slots 8)
         M (fixture.members F)
         IP (fixture.group4 F)
         IPv6 (fixture.group6 F)
         Other (net-ipv4.address 239 1 2 4)
         B (fixture.wire F)
      (do (expect (and (not (net-multicast.join4 M (net-ipv4.address 232 1 2 3) 0))
                       (not (net-multicast.join6 M (net-ipv6.make-address 4281466880 0 0 3) 0)))
                  "source-specific ranges require source filters")
          (expect (joins F) "two families share the configured slots")
          (expect (and (net-multicast.join4 M IP 0) (net-multicast.joined6? M IPv6)
                       (not (net-multicast.join4 M Other 0))) "idempotent join and table exhaustion")
          (net-link.packet-send (fixture.left F) B 0)
          (expect (and (not (poll F 0)) (= (net-multicast.next-deadline M true) -1))
                  "a full output queue delays reports")
          (expect (= (take F) 0) "open one output slot")
          (expect (and (= (net-multicast.next-deadline M true) 0) (poll F 0)
                       (= (take F) 76) (= (buffer.u8 B 56) 4)) "send deferred MLDv2 join")
          (expect (and (poll F 0) (= (take F) 40) (= (buffer.u8 B 32) 4)) "send IGMPv3 join")
          (expect (and (poll F 1000) (fx> (take F) 0) (poll F 1000) (fx> (take F) 0))
                  "retransmit both joins")
          (expect (and (net-multicast.leave4 M IP 1000) (not (net-multicast.joined4? M IP))
                       (not (net-multicast.join4 M Other 1000))) "leave immediately filters input and preserves report")
          (expect (and (poll F 1000) (= (take F) 40) (= (buffer.u8 B 32) 3)) "IGMPv3 leave record")
          (expect (and (poll F 2000) (= (take F) 40) (net-multicast.join4 M Other 2000))
                  "a completed leave recycles its slot"))))

(define legacy4
  {fixture --> fixnum --> fixnum --> fixnum --> boolean}
  F Kind Code IP ->
    (let B (fixture.wire F)
         Host (net-ipv4.address 192 0 2 9)
         Destination (if (= IP 0) (fixnum 3758096385) IP)
      (do (net-ipv4.write-header-ttl B 0 28 2 Host Destination 1)
          (buffer.u32-be-> B 20 (fx+ (fx* Kind 16777216) (fx* Code 65536)))
          (buffer.u32-be-> B 24 IP)
          (buffer.u16-be-> B 22 (net-ipv4.packet-checksum B 20 8))
          (net-multicast.ingress4 (fixture.members F) B 0 28 0))))

(define legacy6-query
  {fixture --> fixnum --> boolean}
  F Alert ->
    (let B (fixture.wire F)
      (do (net-ipv6.write-header B 0 72 0 1 (fixture.querier6 F) (fixture.nodes6 F))
          (buffer.u32-be-> B 40 973079810)
          (buffer.u32-be-> B 44 (fx+ (fx* Alert 65536) 256))
          (buffer.u32-be-> B 48 2181038080)
          (buffer.u32-be-> B 52 0)
          (net-ipv6.write-address B 56 (net-multicast.membership.blank6 (fixture.members F)))
          (buffer.u16-be-> B 50 (net-ipv6.transport-checksum-at B 0 48 58 24))
          (net-multicast.ingress6 (fixture.members F) (fixture.local6 F) B 0 72 48 (router-alert B 72) 0))))

\\ The router alert the header walk finds in a packet, or -1.
(define router-alert
  {buffer.view --> fixnum --> fixnum}
  B N -> (let C (net-ipv6-headers.make)
           (do (net-ipv6-headers.parse C B 0 N) (net-ipv6-headers.cursor.router-alert C))))

(define legacy
  {fixnum --> boolean}
  Slots ->
    (let F (setup Slots 8)
         M (fixture.members F)
         B (fixture.wire F)
         IP (fixture.group4 F)
      (do (expect (joins F) "prepare legacy compatibility")
          (expect (legacy4 F 17 1 0) "IGMPv2 general query")
          (expect (not (legacy6-query F 1)) "reject MLD query without its Router Alert")
          (expect (legacy6-query F 0) "MLDv1 general query")
          (expect (and (poll F 0) (= (take F) 72) (= (buffer.u8 B 48) 131)
                       (net-ipv6.address-at? (fixture.group6 F) B 24)) "MLDv1 report to group")
          (expect (and (poll F 0) (= (take F) 32) (= (buffer.u8 B 24) 22)
                       (= (buffer.u32-be B 16) IP)) "IGMPv2 report to group")
          (expect (legacy4 F 22 0 IP) "other listener suppresses our IGMPv2 report")
          (expect (and (net-multicast.leave4 M IP 0) (poll F 0) (= (take F) -1))
                  "a non-reporter leaves silently in IGMPv2")
          (expect (and (net-multicast.leave6 M (fixture.group6 F) 0) (poll F 0)
                       (= (take F) 72) (= (buffer.u8 B 48) 132) (= (buffer.u32-be B 36) 2))
                  "last MLDv1 reporter sends Done to all routers")
          (expect (and (legacy4 F 17 0 0) (net-multicast.join4 M IP 0) (poll F 0)
                       (= (take F) 32) (= (buffer.u8 B 24) 18)) "IGMPv1 query selects v1 reports")
          (expect (and (net-multicast.leave4 M IP 0) (poll F 0) (= (take F) -1))
                  "IGMPv1 has no leave report"))))

(define source-query4
  {fixture --> fixnum --> fixnum --> fixnum --> boolean}
  F Group Source Now ->
    (let B (fixture.wire F)
         Router (net-ipv4.address 192 0 2 9)
         Bytes (if (= Source 0) (fixnum 32) (fixnum 36))
      (do (net-ipv4.write-header-ttl B 0 Bytes 2 Router Group 1)
          (buffer.u32-be-> B 20 285278208)
          (buffer.u32-be-> B 24 Group)
          (buffer.u32-be-> B 28 (if (= Source 0) (fixnum 41746432) (fixnum 41746433)))
          (if (= Source 0) B (buffer.u32-be-> B 32 Source))
          (buffer.u16-be-> B 22 (net-ipv4.packet-checksum B 20 (fx- Bytes 20)))
          (net-multicast.ingress4 (fixture.members F) B 0 Bytes Now))))

(define report-source4?
  {fixture --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  F Kind Group A B ->
    (let Wire (fixture.wire F)
         Count (if (= B 0) (fixnum 1) (fixnum 2))
      (and (= (take F) (fx+ 40 (fx* 4 Count)))
           (= (buffer.u8 Wire 24) 34)
           (= (buffer.u16-be Wire 30) 1)
           (= (buffer.u8 Wire 32) Kind)
           (= (buffer.u16-be Wire 34) Count)
           (= (buffer.u32-be Wire 36) Group)
           (if (= Count 1) (= (buffer.u32-be Wire 40) A)
               (let First (buffer.u32-be Wire 40)
                    Second (buffer.u32-be Wire 44)
                 (or (and (= First A) (= Second B)) (and (= First B) (= Second A))))))))

(define source-filters
  {fixnum --> boolean}
  Slots ->
    (let F (setup Slots 2)
         M (fixture.members F)
         Group (net-ipv4.address 232 1 2 3)
         A (net-ipv4.address 192 0 2 2)
         B (net-ipv4.address 192 0 2 3)
         C (net-ipv4.address 192 0 2 4)
      (do (expect (and (net-multicast.join-source4 M Group A 0)
                       (net-multicast.join-source4 M Group B 0)
                       (net-multicast.join-source4 M Group A 0)
                       (not (net-multicast.join-source4 M Group C 0))
                       (not (net-multicast.leave4 M Group 0))
                       (net-multicast.accepts4? M Group A)
                       (net-multicast.accepts4? M Group B)
                       (not (net-multicast.accepts4? M Group C))) "two bounded and idempotent source subscriptions")
          (expect (legacy4 F 17 1 0) "an interface can still see an IGMPv2 querier")
          (expect (and (poll F 0) (report-source4? F 5 Group A B)
                       (poll F 1000) (report-source4? F 5 Group A B)) "SSM reports use IGMPv3 under an old querier")
          (expect (and (source-query4 F Group A 1000) (poll F 1100)
                       (report-source4? F 1 Group A 0)) "answer with the subscribed source requested")
          (expect (and (source-query4 F Group A 1100) (source-query4 F Group B 1100)
                       (poll F 1200) (report-source4? F 1 Group A B)) "combine pending source queries")
          (expect (and (not (source-query4 F Group C 1200)) (not (poll F 1300))) "ignore an unmatched source query")
          (expect (and (net-multicast.leave-source4 M Group A 1300)
                       (not (net-multicast.accepts4? M Group A))
                       (net-multicast.accepts4? M Group B)
                       (not (net-multicast.join-source4 M Group C 1300))
                       (poll F 1300) (report-source4? F 6 Group A 0)
                       (poll F 2300) (report-source4? F 6 Group A 0)
                       (net-multicast.join-source4 M Group C 2300))
                  "filter immediately and recycle the slot after the second leave report")
          (expect (and (source-query4 F Group 0 2300)
                       (net-multicast.leave-source4 M Group B 2300)
                       (net-multicast.leave-source4 M Group C 2300)
                       (not (net-multicast.joined4? M Group))
                       (net-multicast.join-source4 M Group B 2300)
                       (net-multicast.join-source4 M Group C 2300)
                       (poll F 2300) (report-source4? F 5 Group B C)
                       (source-query4 F Group B 2300)
                       (poll F 2400) (report-source4? F 1 Group B 0))
                  "reset a pending full-group query when the last source leaves"))))

(define run
  {--> boolean}
  -> (do (capacity 2)
         (legacy 2)
         (source-filters 1)
         (output "3 passed, 0 failed~%")
         true))

(preclude [fixture.%match])
)
