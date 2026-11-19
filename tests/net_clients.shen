(define net-clients-test.expect
  {boolean --> string --> boolean}
  true _ -> true
  false Name -> (error "IPv4 client test failed at ~A" Name))

(define net-clients-test.clock
  {fixnum --> (vector fixnum)}
  Now -> (fxvector-> (vector 1) 1 Now))

(define net-clients-test.bootp
  {buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  B Id Guest Server Kind ->
    (do (buffer.u32-be-> B 0 33621504)
        (buffer.u32-be-> B 4 Id)
        (buffer.u32-be-> B 16 Guest)
        (buffer.u16-be-> B 28 512)
        (buffer.u32-be-> B 30 22)
        (buffer.u32-be-> B 236 1669485411)
        (buffer.u16-be-> B 240 13569)
        (buffer.u8-> B 242 Kind)
        (buffer.u16-be-> B 243 13828)
        (buffer.u32-be-> B 245 Server)
        (buffer.u16-be-> B 249 13060)
        (buffer.u32-be-> B 251 8)
        (buffer.u8-> B 255 255)
        true))

(define net-clients-test.serve-dhcp
  {net-link.device --> buffer.view --> buffer.view --> fixnum --> fixnum --> boolean}
  D Body Wire Server Dst ->
    (do (udp.write-packet Wire 0 Server 67 Dst 68 Body 0 256)
        (= (net-link.packet-send D Wire 284) net-link.sent)))

(define net-clients-test.dhcp
  {--> boolean}
  -> (let Time (net-clients-test.clock 0)
          Cable (net-link.make 2 576 0 (freeze (fx<-vector Time 1)))
          Left (net-link.left Cable)
          Right (net-link.right Cable)
          Host (net-ipv4.address 198 51 100 1)
          Guest (net-ipv4.address 198 51 100 2)
          Bcast (fixnum 4294967295)
          D (net-dhcp.make Left 2199023255574 100)
          F (net-interface.make-host Left Guest [] 1 12 34 [68] 1)
          Inbox (net-interface.udp-binding F 68)
          B (buffer.new 256)
          Wire (buffer.new 576)
       (do (net-clients-test.expect (= (net-dhcp.poll D 2) net-dhcp.selecting) "send discover")
           (net-clients-test.expect (= (net-link.packet-recv-into Right Wire) 328) "wire discover")
           (net-clients-test.bootp B 99 Guest Host 2)
           (net-clients-test.serve-dhcp Right B Wire Host Bcast)
           (net-clients-test.expect (= (net-dhcp.poll D 2) net-dhcp.selecting) "ignore other XID")
           (net-clients-test.bootp B 100 Guest Host 2)
           (net-clients-test.serve-dhcp Right B Wire Host Bcast)
           (net-clients-test.expect (= (net-dhcp.poll D 2) net-dhcp.requesting) "choose offer")
           (net-clients-test.expect (= (net-link.packet-recv-into Right Wire) 328) "wire request")
           (net-clients-test.bootp B 100 Guest Host 5)
           (net-clients-test.serve-dhcp Right B Wire Host Bcast)
           (net-clients-test.expect (and (= (net-dhcp.poll D 2) net-dhcp.bound)
                                         (= (net-dhcp.client.expires D) 8000)
                                         (= (net-dhcp.client.address D) Guest))
                                    "commit accepted lease")
           (fxvector-> Time 1 4000)
           (net-clients-test.expect (= (net-dhcp.maintain D Inbox 2) net-dhcp.renewing) "default T1")
           (net-clients-test.expect (and (= (net-link.packet-recv-into Right Wire) 328)
                                         (= (buffer.u32-be Wire 16) Host)) "unicast renewal")
           (fxvector-> Time 1 7000)
           (net-clients-test.expect (= (net-dhcp.maintain D Inbox 2) net-dhcp.rebinding) "default T2")
           (net-clients-test.expect (and (= (net-link.packet-recv-into Right Wire) 328)
                                         (= (buffer.u32-be Wire 16) Bcast)) "broadcast rebind")
           (net-clients-test.bootp B 101 Guest Host 5)
           (net-clients-test.serve-dhcp Right B Wire Host Bcast)
           (net-interface.poll F 2)
           (net-clients-test.expect (and (= (net-dhcp.maintain D Inbox 2) net-dhcp.bound)
                                         (= (net-dhcp.client.expires D) 15000)) "broadcast ACK extends lease")
           (fxvector-> Time 1 15000)
           (net-clients-test.expect (and (= (net-dhcp.maintain D Inbox 2) net-dhcp.expired)
                                         (= (net-dhcp.client.address D) 0)) "expiry clears address")
           true)))

(define net-clients-test.dns
  {--> boolean}
  -> (let Cable (net-link.make 4 576 0 (freeze 0))
          Left (net-link.left Cable)
          Right (net-link.right Cable)
          Host (net-ipv4.address 198 51 100 1)
          Guest (net-ipv4.address 198 51 100 2)
          F (net-interface.make-host Left Guest [] 1 12 34 [53000] 2)
          R (net-dns.make (net-interface.udp-binding F 53000) 512)
          Server (udp.bind Right Host 53)
          Info (udp.make-recv-info)
          Reply (buffer.new 23)
          Name (buffer.from-string "c#4;testc#0;")
       (do (net-clients-test.expect (net-dns.start R Host 1234 Name 0) "start DNS")
           (net-clients-test.expect (= (net-dns.poll R 0) net-dns.pending) "send DNS query")
           (net-clients-test.expect (= (udp.recv-into Server Reply Info 2) udp.received) "wire DNS query")
           (buffer.u16-be-> Reply 2 33155)
           (buffer.u16-be-> Reply 12 49164)
           (udp.send Server Guest 53000 Reply 22)
           (net-interface.poll F 2)
           (net-clients-test.expect (= (net-dns.poll R 0) net-dns.pending) "ignore looping question pointer")
           (buffer.u8-> Reply 12 4)
           (buffer.u8-> Reply 13 116)
           (udp.send Server Guest 53000 Reply 22)
           (net-interface.poll F 2)
           (net-clients-test.expect (= (net-dns.poll R 0) net-dns.not-found) "matching NXDOMAIN")
           true)))

(define net-clients-test.run
  {--> boolean}
  -> (do (net-clients-test.dhcp)
         (net-clients-test.dns)
         (output "2 passed, 0 failed~%")
         true))
