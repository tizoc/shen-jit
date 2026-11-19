(shen.x.namespace layout-test
  (use buffer)
  (import layout deflayout write-layout)

(deflayout ipv4
  (version 4) (header-length 4) (service 8) (total-length 16)
  (identification 16) (flags 3) (fragment-offset 13)
  (time-to-live 8) (protocol 8) (checksum 16)
  (source 32)
  (destination 32))

(deflayout tcp
  (source-port 16) (destination-port 16)
  (sequence 32)
  (acknowledgement 32)
  (data-offset 4) (_ 4) (flags 8) (window 16)
  (checksum 16) (urgent 16))

(deflayout ethernet
  (destination 48)
  (source 48)
  (ethertype 16))

(deflayout ipv6
  (version 4) (traffic-class 8) (flow-label 20)
  (payload-length 16) (next-header 8) (hop-limit 8)
  (source 128)
  (destination 128))

(deflayout odd
  (tag 8) (count 24))

\\ The TCP payload's offset in a packet at I with a 20-byte IPv4 header.
(define payload-start
  {buffer.view --> fixnum --> fixnum}
  B I -> (let T (fx+ I (ipv4.size))
           (fx+ T (fx* 4 (tcp.data-offset B T)))))

\\ A whole IPv4 header in one call, as packed stores.
(define write-ipv4
  {buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> buffer.view}
  B I Count Proto Src Dst ->
    (write-layout ipv4 B I
      (version 4) (header-length 5) (total-length Count)
      (flags 2) (time-to-live 64) (protocol Proto)
      (source Src) (destination Dst)))

(define write-ethernet
  {buffer.view --> fixnum --> fixnum --> buffer.view}
  B Dst Src -> (write-layout ethernet B 0 (destination Dst) (source Src) (ethertype 2048)))

(define write-ipv6
  {buffer.view --> fixnum --> fixnum --> buffer.view}
  B Length Flow -> (write-layout ipv6 B 0 (version 6) (flow-label Flow) (payload-length Length)
                                          (next-header 17) (hop-limit 255)))

(define fill-bytes
  {buffer.view --> fixnum --> fixnum --> fixnum --> buffer.view}
  B I N _ -> B where (fx>= I N)
  B I N X -> (fill-bytes (buffer.u8-> B I X) (fx+ I 1) N X))
)
