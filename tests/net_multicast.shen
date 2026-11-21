\\ Join, leave, and send both families with a single heap probe.
(shen.x.namespace net-multicast-test
  (use buffer)
  (use net-link)
  (use net-tun)
  (use net-ethernet)
  (use net-routes)
  (use net-ipv4)
  (use net-ipv6)
  (use net-ndp)
  (use net-interface)
  (use udp)
  (use shen-jit)
  (use tun-test)
  (import struct defstruct)
  (export tun tap)

(defstruct test-host
  (interface : net-interface.interface)
  (ipv6 : net-ndp.host)
  (group4 : fixnum)
  (group6 : net-ipv6.address)
  (ssm4 : fixnum)
  (ssm6 : net-ipv6.address)
  (source4a : fixnum)
  (source4b : fixnum)
  (source6a : net-ipv6.address)
  (source6b : net-ipv6.address)
  (mutable ssm-phase : fixnum)
  (mutable received4 : fixnum)
  (mutable received6 : fixnum)
  (reply4 : buffer.view)
  (reply6 : buffer.view)
  (scratch : buffer.view)
  (info : udp.recv-info)
  (mutable joined : boolean)
  (mutable left : boolean)
  (mutable answered4 : boolean)
  (mutable answered6 : boolean))

(define make-host
  {net-link.device --> net-ndp.host --> fixnum --> fixnum --> net-ipv6.address --> test-host}
  D H IP Index Address6 ->
    (let F (net-interface.make-host D IP
             (:net-interface.setup tcp-ports <- [] tcp-slots <- 1 tcp-buffer <- 0 time-waits <- 16
                                   udp-ports <- [7777] udp-slots <- 4 key0 <- 19 key1 <- 40))
         _ (net-ndp.configure-static H Address6)
         _ (net-interface.enable-ipv6 F H)
         _ (net-interface.enable-multicast-sized F 2 2 95)
      (:test-host
        interface <- F
        ipv6 <- H
        group4 <- (net-ipv4.address 239 1 2 Index)
        group6 <- (net-ipv6.make-address 4279369728 0 0 (fx+ 4660 Index))
        ssm4 <- (net-ipv4.address 232 1 2 Index)
        ssm6 <- (net-ipv6.make-address 4281466880 0 0 (fx+ 4660 Index))
        source4a <- (fx- IP 1)
        source4b <- (fx+ IP 1)
        source6a <- (net-ipv6.make-address 4269801472 0 0 1)
        source6b <- (net-ipv6.make-address 4269801472 0 0 9)
        ssm-phase <- 0
        received4 <- 0
        received6 <- 0
        reply4 <- (buffer.from-string "Shen IPv4 multicast")
        reply6 <- (buffer.from-string "Shen IPv6 multicast")
        scratch <- (buffer.new 128)
        info <- (udp.make-recv-info)
        joined <- false
        left <- false
        answered4 <- false
        answered6 <- false)))

(define group-setup
  {test-host --> boolean}
  H ->
    (if (or (test-host.joined H) (not (net-ndp.local-ready? (test-host.ipv6 H)))) false
        (let F (test-host.interface H)
             G4 (test-host.group4 H)
             G6 (test-host.group6 H)
          (if (and (net-interface.join4 F G4) (net-interface.join6 F G6)
                   (net-interface.join4 F G4) (net-interface.joined4? F G4) (net-interface.joined6? F G6))
              (do (test-host.joined-> H true) (tun-test.notify 2))
              (error "cannot join both multicast groups")))))

(define leave-groups
  {test-host --> boolean}
  H ->
    (let F (test-host.interface H)
         G4 (test-host.group4 H)
         G6 (test-host.group6 H)
      (if (and (test-host.answered4 H) (test-host.answered6 H)
               (net-interface.leave4 F G4) (net-interface.leave6 F G6)
               (not (net-interface.joined4? F G4)) (not (net-interface.joined6? F G6)))
          (do (test-host.left-> H true) false)
          (error "cannot leave both multicast groups"))))

(define check-send
  {net-interface.send-result --> boolean}
  Status ->
    (cases (= Status udp.sent) false
           true (error "could not send multicast test reply: ~A" Status)))

(define start-ssm
  {test-host --> boolean}
  H ->
    (let F (test-host.interface H)
         A (test-host.ssm4 H)
         B (test-host.ssm6 H)
      (if (and (test-host.left H) (= (test-host.ssm-phase H) 0)
               (net-interface.join-source4 F A (test-host.source4a H))
               (net-interface.join-source6 F B (test-host.source6a H))
               (net-interface.join-source4 F A (test-host.source4a H)))
          (do (test-host.ssm-phase-> H 1) false)
          (error "cannot join source-specific groups"))))

(define switch-ssm
  {test-host --> boolean}
  H ->
    (let F (test-host.interface H)
         A (test-host.ssm4 H)
         B (test-host.ssm6 H)
      (if (and (= (test-host.ssm-phase H) 1) (= (test-host.received4 H) 1) (= (test-host.received6 H) 1)
               (net-interface.join-source4 F A (test-host.source4b H))
               (net-interface.join-source6 F B (test-host.source6b H))
               (net-interface.leave-source4 F A (test-host.source4a H))
               (net-interface.leave-source6 F B (test-host.source6a H)))
          (do (test-host.ssm-phase-> H 2) false)
          (error "cannot replace subscribed multicast sources"))))

(define stop-ssm
  {test-host --> boolean}
  H ->
    (let F (test-host.interface H)
         A (test-host.ssm4 H)
         B (test-host.ssm6 H)
      (if (and (= (test-host.ssm-phase H) 2) (= (test-host.received4 H) 2) (= (test-host.received6 H) 2)
               (net-interface.leave-source4 F A (test-host.source4b H))
               (net-interface.leave-source6 F B (test-host.source6b H))
               (not (net-interface.joined4? F A)) (not (net-interface.joined6? F B)))
          (do (test-host.ssm-phase-> H 3) false)
          (error "cannot leave source-specific groups"))))

(define source-input
  {test-host --> boolean --> fixnum --> boolean}
  H IPv4 Byte ->
    (let F (test-host.interface H)
         Info (test-host.info H)
         Payload (test-host.scratch H)
         Phase (test-host.ssm-phase H)
         Count (if IPv4 (test-host.received4 H) (test-host.received6 H))
         Port (udp.recv-info.port Info)
         A (udp.recv-info.source Info)
         B (udp.recv-info.source6 Info)
         SourceOK (if IPv4
                      (= A (if (= Phase 1) (test-host.source4a H) (test-host.source4b H)))
                      (net-ipv6.same? B (if (= Phase 1) (test-host.source6a H) (test-host.source6b H))))
      (if (and (or (= Phase 1) (= Phase 2)) (= Byte (fx+ Phase 96))
               (= Count (fx- Phase 1)) SourceOK)
          (let Status (if IPv4 (net-interface.udp-send F A Port Payload 1)
                           (net-interface.udp-send6 F 7777 B Port Payload 1))
            (do (if IPv4 (test-host.received4-> H Phase) (test-host.received6-> H Phase))
                (check-send Status)))
          (error "source-specific UDP escaped its filter or arrived twice"))))

(define multicast-input
  {test-host --> boolean}
  H ->
    (let F (test-host.interface H)
         Info (test-host.info H)
         B (test-host.scratch H)
         IPv4 (= (udp.recv-info.family Info) 4)
         Byte (buffer.u8 B 0)
         IsGroup (if IPv4 (= (udp.recv-info.destination Info) (test-host.group4 H))
                     (net-ipv6.same? (udp.recv-info.destination6 Info) (test-host.group6 H)))
         IsSSM (if IPv4 (= (udp.recv-info.destination Info) (test-host.ssm4 H))
                   (net-ipv6.same? (udp.recv-info.destination6 Info) (test-host.ssm6 H)))
      (cases (not (= (udp.recv-info.length Info) 1)) (error "unexpected multicast test payload length")
             (and IsGroup (test-host.left H)) (error "received data after leaving multicast group")
             (and IsGroup IPv4 (= Byte 52))
               (let P (test-host.reply4 H)
                    Status (net-interface.udp-send F (test-host.group4 H) 9000 P (buffer.length P))
                 (do (test-host.answered4-> H true) (check-send Status)))
             (and IsGroup (not IPv4) (= Byte 54))
               (let P (test-host.reply6 H)
                    Status (net-interface.udp-send6 F 7777 (test-host.group6 H) 9000 P (buffer.length P))
                 (do (test-host.answered6-> H true) (check-send Status)))
             IsSSM (source-input H IPv4 Byte)
             (and (not IsGroup) IPv4 (= Byte 76)) (leave-groups H)
             (and (not IsGroup) IPv4 (= Byte 83)) (start-ssm H)
             (and (not IsGroup) IPv4 (= Byte 82)) (switch-ssm H)
             (and (not IsGroup) IPv4 (= Byte 68)) (stop-ssm H)
             (and (not IsGroup) IPv4 (= Byte 81) (= (test-host.ssm-phase H) 3)) true
             true (error "unexpected multicast test message ~A" (fx->number Byte)))))

(define drive
  {net-tun.adapter --> (fixnum --> fixnum) --> test-host --> fixnum --> boolean}
  Device Ethernet H Until ->
    (let F (test-host.interface H)
         _ (net-tun.pump Device 8)
         _ (Ethernet 8)
         _ (net-interface.poll F 8)
         _ (group-setup H)
         Stop (and (= (net-interface.udp-recv-into F (test-host.scratch H) (test-host.info H)) udp.received)
                   (multicast-input H))
         _ (net-interface.poll F 8)
         _ (Ethernet 8)
         _ (net-tun.pump Device 8)
      (cases Stop true
             (fx>= (net-tun.monotonic 0) Until) (error "multicast test timed out")
             true (do (net-tun.wait Device 2) (drive Device Ethernet H Until)))))

(define measure
  {net-tun.adapter --> (fixnum --> fixnum) --> test-host --> boolean}
  Device Ethernet H ->
    (let _ (tun-test.mark 0)
         View (buffer.slice (test-host.scratch H) 0 1)
         Control (tun-test.words 0)
         _ (if (and (= (buffer.length View) 1) (fx> Control 0)) true
               (error "multicast heap positive control failed"))
         Until (fx+ (net-tun.monotonic 0) 25000)
         _ (tun-test.notify 0)
         _ (tun-test.mark 0)
         _ (drive Device Ethernet H Until)
         Heap (tun-test.words 0)
      (if (= Heap 0)
          (do (output "IGMP and MLD group and source changes and UDP used 0 Shen heap words (control ~A)~%"
                      (fx->number Control))
              true)
          (error "multicast workload used ~A Shen heap words" (fx->number Heap)))))

(define tun
  {string --> boolean}
  Name ->
    (let Link (net-link.make 8 1500 0 (freeze (net-tun.monotonic 0)))
         D (net-link.left Link)
         H (net-ndp.make D 0 0 32 0)
         F (make-host D H (net-ipv4.address 192 0 2 50) 3 (net-ipv6.make-address 536939960 7340032 0 32))
         Device (net-tun.attach (net-link.right Link) Name)
         NoEthernet (/. Budget (fx- Budget Budget))
      (shen-jit.finally (freeze (measure Device NoEthernet F)) (freeze (net-tun.close Device)))))

(define tap
  {string --> boolean}
  Name ->
    (let Clock (freeze (net-tun.monotonic 0))
         Link (net-link.make 8 1500 0 Clock)
         Frames (net-link.make 8 1514 0 Clock)
         D (net-link.left Link)
         IP (net-ipv4.address 192 0 2 66)
         Mac (net-ethernet.hardware 512 32)
         H (net-ndp.make D Mac 0 32 4)
         F (make-host D H IP 4 (net-ipv6.make-address 536939960 8388608 0 32))
         Ethernet (net-ethernet.make (net-link.left Frames) (net-link.right Link) Mac IP
                                     [(net-routes.make IP 29 0)] 4)
         _ (net-ethernet.enable-ipv6 Ethernet H)
         Device (net-tun.attach-tap (net-link.right Frames) Name)
         Pump (/. Budget (net-ethernet.pump Ethernet Budget))
      (shen-jit.finally (freeze (measure Device Pump F)) (freeze (net-tun.close Device)))))

(preclude [test-host.%match])
)
