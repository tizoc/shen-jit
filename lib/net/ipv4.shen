\\ Fixed-header, unfragmented IPv4 and checksums shared by UDP and TCP.
(shen.x.namespace net-ipv4
  (use buffer)
  (use shen-jit)
  (export address unicast? write-header valid? valid-header? fragmented?
          packet-checksum transport-checksum sum16 checksum)

(define octet
  {fixnum --> fixnum}
  N -> (let I (buffer.index N)
         (if (fx<= I 255) I (error "IPv4: octet exceeds 255"))))

(define address
  {fixnum --> fixnum --> fixnum --> fixnum --> fixnum}
  A B C D -> (fx+ (shen-jit.shift-left (octet A) 24)
                  (fx+ (shen-jit.shift-left (octet B) 16)
                       (fx+ (shen-jit.shift-left (octet C) 8) (octet D)))))

(define unicast?
  {fixnum --> boolean}
  IP -> (and (fx>= IP 16777216) (fx< IP 3758096384)))

\\ One's complement sum in network byte order. The odd tail has an implicit low zero byte.
(define sum16
  {buffer.view --> fixnum --> fixnum --> fixnum --> fixnum}
  _ _ 0 Sum -> Sum
  B I 1 Sum -> (fx+ Sum (shen-jit.shift-left (buffer.u8 B I) 8))
  B I Count Sum -> (sum16 B (fx+ I 2) (fx- Count 2) (fx+ Sum (buffer.u16-be B I))))

(define fold16
  {fixnum --> fixnum}
  N -> (fx+ (shen-jit.bit-and N 65535) (shen-jit.shift-right N 16)))

(define checksum
  {fixnum --> fixnum}
  N -> (shen-jit.bit-xor (fold16 (fold16 N)) 65535))

(define packet-checksum
  {buffer.view --> fixnum --> fixnum --> fixnum}
  B I N -> (checksum (sum16 B I N 0)))

(define transport-checksum
  {buffer.view --> fixnum --> fixnum --> fixnum --> fixnum}
  B I Proto N ->
    (let Pseudo (sum16 B (fx+ I 12) 8 (fx+ Proto N))
      (checksum (sum16 B (fx+ I 20) N Pseudo))))

(define write-header
  {buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> buffer.view}
  B I Count Proto Src Dst ->
    (do (buffer.u16-be-> B I 17664)                     \\ Version 4, IHL 5, service byte 0.
        (buffer.u16-be-> B (fx+ I 2) Count)
        (buffer.u16-be-> B (fx+ I 4) 0)                \\ Zero identification for the atomic datagram.
        (buffer.u16-be-> B (fx+ I 6) 16384)            \\ Don't Fragment.
        (buffer.u16-be-> B (fx+ I 8) (fx+ 16384 Proto)) \\ TTL 64.
        (buffer.u16-be-> B (fx+ I 10) 0)
        (buffer.u32-be-> B (fx+ I 12) Src)
        (buffer.u32-be-> B (fx+ I 16) Dst)
        (buffer.u16-be-> B (fx+ I 10) (packet-checksum B I 20))))

(define valid-header?
  {buffer.view --> fixnum --> fixnum --> boolean}
  B I N ->
    (and (fx>= N 20)
         (= (buffer.u8 B I) 69)
         (= (buffer.u16-be B (fx+ I 2)) N)
         (fx> (buffer.u8 B (fx+ I 8)) 0)
         (= (shen-jit.bit-and (buffer.u16-be B (fx+ I 6)) 32768) 0)
         (= (packet-checksum B I 20) 0)))

(define fragmented?
  {buffer.view --> fixnum --> boolean}
  B I -> (not (= (shen-jit.bit-and (buffer.u16-be B (fx+ I 6)) 16383) 0)))

(define valid?
  {buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  B I N Proto ->
    (and (valid-header? B I N)
         (not (fragmented? B I))
         (= (buffer.u8 B (fx+ I 9)) Proto)))
)
