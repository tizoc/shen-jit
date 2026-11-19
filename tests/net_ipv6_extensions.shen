(shen.x.namespace net-ipv6-ext-test
  (use buffer)
  (use net-link)
  (use net-ipv4)
  (use net-ipv6)
  (use net-ndp)
  (use net-interface)
  (use net-ipv6-test)
  (use udp)
  (import struct defstruct)
  (shadow run)
  (export run)

(defstruct fixture
  (time : (vector fixnum))
  (remote : net-link.device)
  (interface : net-interface.interface)
  (ndp : net-ndp.host)
  (source : net-ipv6.address)
  (destination : net-ipv6.address)
  (payload : buffer.view)
  (packet : buffer.view)
  (wire : buffer.view)
  (response : buffer.view)
  (out : buffer.view)
  (info : udp.recv-info))

(define setup
  {fixnum --> boolean --> fixture}
  Slots Static ->
    (let Time (net-ipv6-test.clock)
         Link (net-link.make 8 1500 0 (freeze (fx<-vector Time 1)))
         D (net-link.right Link)
         A (net-ipv6.make-address 536939960 0 0 1)
         B (net-ipv6.make-address 536939960 0 0 2)
         H (net-ndp.make D 0 0 2 0)
         F (net-interface.make-host D (net-ipv4.address 192 0 2 2) [] 1 22 33 [7] 2)
         _ (if Static (net-ndp.configure-static H B) true)
         _ (net-interface.enable-ipv6-sized F H Slots 1500)
         Payload (buffer.from-string "reassembled IPv6 packet!")
         Packet (buffer.new 72)
         Left (net-link.left Link)
         Wire (buffer.new 1500)
      (do (net-ipv6.write-header Packet 0 72 17 64 A B)
          (buffer.u16-be-> Packet 40 9000)
          (buffer.u16-be-> Packet 42 7)
          (buffer.u16-be-> Packet 44 32)
          (buffer.copy-into! Packet 48 Payload 0 24)
          (buffer.u16-be-> Packet 46 (net-ipv6.transport-checksum Packet 0 17 32))
          (net-interface.poll F 0)
          (fxvector-> Time 1 1000)
          (net-interface.poll F 0)
          (discard-output Left Wire)
          (:fixture
            time <- Time
            remote <- Left
            interface <- F
            ndp <- H
            source <- A
            destination <- B
            payload <- Payload
            packet <- Packet
            wire <- Wire
            response <- (buffer.new 1500)
            out <- (buffer.new 24)
            info <- (udp.make-recv-info)))))

(define discard-output
  {net-link.device --> buffer.view --> boolean}
  D B -> (if (fx>= (net-link.packet-recv-into D B) 0) (discard-output D B) true))

(define advance
  {fixture --> fixnum --> boolean}
  F At ->
    (do (fxvector-> (fixture.time F) 1 At)
        (net-interface.poll (fixture.interface F) 0)
        true))

(define deliver
  {fixture --> fixnum --> boolean}
  F Bytes ->
    (do (net-ipv6-test.expect (= (net-link.packet-send (fixture.remote F) (fixture.wire F) Bytes) net-link.sent)
                             "enqueue test IPv6 packet")
        (net-interface.poll (fixture.interface F) 1)
        true))

(define reply-bytes
  {fixture --> fixnum}
  F -> (net-link.packet-recv-into (fixture.remote F) (fixture.response F)))

(define recv
  {fixture --> udp.receive-result}
  F -> (net-interface.udp-recv-into (fixture.interface F) (fixture.out F) (fixture.info F)))

(define payload?
  {fixture --> boolean}
  F -> (and (= (recv F) udp.received)
            (= (udp.recv-info.family (fixture.info F)) 6)
            (buffer.equal? (fixture.out F) (fixture.payload F))))

(define parameter?
  {fixture --> fixnum --> fixnum --> boolean}
  F Type Pointer ->
    (let Count (reply-bytes F)
         B (fixture.response F)
      (and (fx>= Count 48) (= (buffer.u16-be B 40) Type)
           (= (buffer.u32-be B 44) Pointer)
           (= (net-ipv6.transport-checksum B 0 58 (fx- Count 40)) 0))))

(define extension-packet
  {fixture --> fixnum --> fixnum --> fixnum --> fixnum --> buffer.view}
  F Kind Next Option Length ->
    (let B (fixture.wire F)
      (do (net-ipv6.write-header B 0 80 Kind 64 (fixture.source F) (fixture.destination F))
          (buffer.u32-be-> B 40 (fx+ (fx* Next 16777216) (fx+ (fx* Option 256) Length)))
          (buffer.u32-be-> B 44 0)
          (buffer.copy-into! B 48 (fixture.packet F) 40 32))))

(define extension-options
  {fixnum --> boolean}
  Slots ->
    (let F (setup Slots true)
         B (extension-packet F 0 17 5 2)
         AllNodes (net-ipv6.make-address 4278321152 0 0 1)
      (do (deliver F 80)
          (net-ipv6-test.expect (payload? F) "Hop-by-Hop Router Alert and Pad1")
          (extension-packet F 60 17 33 4)
          (deliver F 80)
          (net-ipv6-test.expect (payload? F) "skip unrecognized option with action 00")
          (buffer.u8-> B 42 65)
          (deliver F 80)
          (net-ipv6-test.expect (and (= (recv F) udp.empty) (= (reply-bytes F) -1))
                               "discard option with action 01 without an error")
          (buffer.u8-> B 42 129)
          (deliver F 80)
          (net-ipv6-test.expect (parameter? F 1026 42) "unrecognized option pointer")
          (net-ipv6.write-address B 24 AllNodes)
          (deliver F 80)
          (net-ipv6-test.expect (parameter? F 1026 42) "action 10 reports from an IPv6 multicast destination")
          (buffer.u8-> B 42 193)
          (deliver F 80)
          (net-ipv6-test.expect (= (reply-bytes F) -1) "action 11 suppresses multicast error")
          (extension-packet F 43 17 253 1)
          (deliver F 80)
          (net-ipv6-test.expect (parameter? F 1024 42) "reject routing header with segments remaining")
          (buffer.u8-> B 43 0)
          (deliver F 80)
          (net-ipv6-test.expect (payload? F) "accept routing header with zero segments left")
          (extension-packet F 60 17 1 5)
          (deliver F 80)
          (net-ipv6-test.expect (parameter? F 1024 43) "reject malformed option length")
          (buffer.u8-> B 6 59)
          (deliver F 80)
          (net-ipv6-test.expect (and (= (recv F) udp.empty) (= (reply-bytes F) -1))
                               "No Next Header ignores trailing octets"))))

(define option-chain
  {buffer.view --> fixnum --> fixnum --> buffer.view}
  B _ 0 -> B
  B At Headers ->
    (do (buffer.u32-be-> B At (if (= Headers 1) 285212672 1006632960))
        (buffer.u32-be-> B (fx+ At 4) 0)
        (option-chain B (fx+ At 8) (fx- Headers 1))))

(define bounded-headers
  {fixnum --> boolean}
  Slots ->
    (let F (setup Slots true)
         B (fixture.wire F)
      (do (net-ipv6.write-header B 0 144 60 64 (fixture.source F) (fixture.destination F))
          (option-chain B 40 9)
          (buffer.copy-into! B 112 (fixture.packet F) 40 32)
          (deliver F 144)
          (net-ipv6-test.expect (and (= (recv F) udp.empty) (= (reply-bytes F) -1))
                               "extension count limit")
          (net-ipv6.write-header B 0 336 60 64 (fixture.source F) (fixture.destination F))
          (buffer.copy-into! B 40 (buffer.new 264) 0 264)
          (buffer.u16-be-> B 40 4384)
          (buffer.copy-into! B 304 (fixture.packet F) 40 32)
          (deliver F 336)
          (net-ipv6-test.expect (and (= (recv F) udp.empty) (= (reply-bytes F) -1))
                               "extension byte limit"))))

(define make-fragment
  {fixture --> fixnum --> fixnum --> fixnum --> boolean --> fixnum --> boolean --> fixnum}
  F Offset Count Id More Proto Hop ->
    (let B (fixture.wire F)
         At (if Hop (type 48 fixnum) (type 40 fixnum))
         Size (fx+ (fx+ At 8) Count)
      (do (net-ipv6.write-header B 0 Size (if Hop 0 44) 64 (fixture.source F) (fixture.destination F))
          (if Hop (do (buffer.u32-be-> B 40 738197504)
                      (buffer.u32-be-> B 44 0)) B)
          (buffer.u8-> B At Proto)
          (buffer.u8-> B (fx+ At 1) 0)
          (buffer.u16-be-> B (fx+ At 2) (fx+ Offset (if More 1 0)))
          (buffer.u32-be-> B (fx+ At 4) Id)
          (if (fx<= (fx+ Offset Count) 32)
              (buffer.copy-into! B (fx+ At 8) (fixture.packet F) (fx+ Offset 40) Count) B)
          Size)))

(define deliver-fragment
  {fixture --> fixnum --> fixnum --> fixnum --> boolean --> fixnum --> boolean --> boolean}
  F Offset Count Id More Proto Hop -> (deliver F (make-fragment F Offset Count Id More Proto Hop)))

(define bounded-fragments
  {fixnum --> boolean}
  Slots ->
    (let F (setup Slots true)
         I (fixture.interface F)
         B (fixture.response F)
      (do (deliver-fragment F 16 16 1 false 6 true)
          (deliver-fragment F 0 16 2 true 17 false)
          (deliver-fragment F 16 16 2 false 17 false)
          (net-ipv6-test.expect (= (recv F) udp.empty) "one occupied slot excludes another ID")
          (deliver-fragment F 0 32 1 false 17 true)
          (net-ipv6-test.expect (payload? F) "atomic fragment with matching ID is independent")
          (deliver-fragment F 0 16 1 true 17 false)
          (net-ipv6-test.expect (payload? F) "first fragment selects prefix and protocol")
          (deliver-fragment F 0 16 3 true 17 false)
          (deliver-fragment F 8 24 3 false 17 false)
          (deliver-fragment F 16 16 3 false 17 false)
          (net-ipv6-test.expect (and (= (recv F) udp.empty) (= (reply-bytes F) -1))
                               "overlap discards the datagram silently")
          (advance F 61000)
          (net-ipv6-test.expect (= (reply-bytes F) -1) "poisoned slot expires silently")
          (deliver-fragment F 0 16 4 true 17 false)
          (net-ipv6-test.expect (= (net-interface.next-deadline I) 121000) "fragment timeout wakes interface")
          (advance F 121001)
          (net-ipv6-test.expect (and (= (reply-bytes F) 112) (= (buffer.u16-be B 40) 769)
                                    (= (buffer.u32-be B 92) 4)) "time exceeded quotes original first fragment")
          (deliver-fragment F 0 8 5 true 6 false)
          (net-ipv6-test.expect (parameter? F 1027 0) "first fragment must contain the upper header")
          (deliver-fragment F 1496 16 6 false 17 false)
          (deliver-fragment F 0 16 7 true 17 true)
          (deliver-fragment F 16 16 7 false 17 false)
          (net-ipv6-test.expect (payload? F) "oversize tail does not consume the free slot"))))

(define discovery
  {fixnum --> boolean}
  Slots ->
    (let F (setup Slots false)
         H (fixture.ndp F)
         B (fixture.wire F)
         Router (net-ipv6.make-address 4269801472 0 0 1)
         Prefix (net-ipv6.make-address 536939960 65536 0 0)
      (do (net-ipv6.write-header B 0 96 44 255 Router (net-ndp.host.link-local H))
          (buffer.u32-be-> B 40 973078528)
          (buffer.u32-be-> B 44 22)
          (buffer.u32-be-> B 48 2248146944)
          (buffer.u32-be-> B 52 1073741884)
          (buffer.u32-be-> B 56 0)
          (buffer.u32-be-> B 60 0)
          (buffer.u32-be-> B 64 50610368)
          (buffer.u32-be-> B 68 120)
          (buffer.u32-be-> B 72 60)
          (buffer.u32-be-> B 76 0)
          (net-ipv6.write-address B 80 Prefix)
          (buffer.u16-be-> B 50 (net-ipv6.transport-checksum-at B 0 48 58 48))
          (deliver F 96)
          (net-ipv6-test.expect (= (net-ndp.host.global-state H) net-ndp.absent) "ignore atomic fragment of RA")
          (buffer.u8-> B 6 60)
          (buffer.u32-be-> B 44 0)
          (deliver F 96)
          (net-ipv6-test.expect (= (net-ndp.host.global-state H) net-ndp.tentative) "RA behind Destination Options"))))

(define run
  {--> boolean}
  -> (do (extension-options 1)
         (bounded-headers 1)
         (bounded-fragments 1)
         (discovery 1)
         (output "4 passed, 0 failed~%")
         true))

(preclude [fixture.%match])
)
