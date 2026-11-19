(define net-interface-test.expect
  {boolean --> string --> boolean}
  true _ -> true
  false Name -> (error "IPv4 interface test failed at ~A" Name))

(define net-interface-test.fill
  {buffer.view --> fixnum --> (list fixnum) --> buffer.view}
  B _ [] -> B
  B I [X | Rest] -> (net-interface-test.fill (buffer.u8-> B I X) (fx+ I 1) Rest))

\\ Wire fixtures computed independently, including a three-byte ICMP payload.
(define net-interface-test.run
  {--> boolean}
  -> (let L (net-link.make 4 64 0 (freeze 0))
          Left (net-link.left L)
          Right (net-link.right L)
          A (net-ipv4.address 192 0 2 1)
          B (net-ipv4.address 192 0 2 2)
          F (net-interface.make Right B 7 1 100 7 1)
          U (udp.bind Left A 12345)
          Payload (buffer.from-string "abc")
          Out (buffer.new 3)
          Short (buffer.new 2)
          Info (udp.make-recv-info)
          Request (net-interface-test.fill (buffer.new 31) 0
                    [69 0 0 31 0 0 64 0 64 1 182 218 192 0 2 1 192 0 2 2 8 0 33 88 18 3 0 66 97 98 99])
          Reply (net-interface-test.fill (buffer.new 31) 0
                  [69 0 0 31 0 0 64 0 64 1 182 218 192 0 2 2 192 0 2 1 0 0 41 88 18 3 0 66 97 98 99])
          Wire (buffer.new 31)
       (do (buffer.u8-> Request 30 100)
           (net-interface-test.expect (= (net-link.packet-send Left Request 31) net-link.sent) "queue bad ICMP checksum")
           (buffer.u8-> Request 30 99)
           (net-interface-test.expect (= (udp.send U B 7 Payload 3) udp.sent) "queue UDP")
           (net-interface-test.expect (= (udp.send U B 7 Payload 2) udp.sent) "queue UDP overflow")
           (net-interface-test.expect (= (net-link.packet-send Left Request 31) net-link.sent) "queue valid ICMP")
           (net-interface-test.expect (= (net-interface.poll F 0) 0) "zero ingress budget")
           (net-interface-test.expect (= (net-interface.poll F 2) 2) "discard and enqueue within budget")
           (net-interface-test.expect (= (net-link.packet-recv-into Left Wire) -1) "bad ICMP earns no reply")
           (net-interface-test.expect (= (net-interface.udp-dropped F) 0) "overflow is still on ingress")
           (net-interface-test.expect (= (net-interface.poll F 2) 2) "progress past UDP overflow")
           (net-interface-test.expect (= (net-interface.udp-dropped F) 1) "one UDP overflow drop")
           (net-interface-test.expect (= (net-link.packet-recv-into Left Wire) 31) "ICMP reply while inbox full")
           (net-interface-test.expect (buffer.equal? Wire Reply) "exact ICMP echo reply")
           (net-interface-test.expect (= (net-interface.udp-recv-into F Short Info) udp.too-small) "short UDP output")
           (net-interface-test.expect (= (udp.recv-info.port Info) 0) "short output leaves metadata alone")
           (net-interface-test.expect (= (net-interface.udp-recv-into F Out Info) udp.received) "retry UDP receive")
           (net-interface-test.expect (and (buffer.equal? Out Payload) (= (udp.recv-info.source Info) A)
                                           (= (udp.recv-info.port Info) 12345) (= (udp.recv-info.length Info) 3))
                                      "UDP payload and metadata")
           (net-interface-test.expect (= (net-interface.udp-recv-into F Out Info) udp.empty) "overflow datagram dropped")
           (output "1 passed, 0 failed~%")
           true)))
