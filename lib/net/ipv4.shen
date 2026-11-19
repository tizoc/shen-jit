\\ Fixed-header, unfragmented IPv4 and checksums shared by UDP and TCP.
(shen.x.namespace net-ipv4
  (use buffer)
  (use shen-jit)
  (use net-wire => wire)
  (import layout write-layout)
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
    (let Pseudo (sum16 B (wire.ipv4.source-at I) 8 (fx+ Proto N))
      (checksum (sum16 B (fx+ I (wire.ipv4.size)) N Pseudo))))

(define write-header
  {buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> buffer.view}
  B I Count Proto Src Dst ->
    (do (write-layout wire.ipv4 B I
          (version 4) (header-length 5) (total-length Count)
          (dont-fragment 1) (time-to-live 64) (protocol Proto)
          (source Src) (destination Dst))
        (wire.ipv4.checksum-> B I (packet-checksum B I (wire.ipv4.size)))))

(define valid-header?
  {buffer.view --> fixnum --> fixnum --> boolean}
  B I N ->
    (and (fx>= N (wire.ipv4.size))
         (= (wire.ipv4.version B I) 4)
         (= (wire.ipv4.header-length B I) 5)
         (= (wire.ipv4.total-length B I) N)
         (fx> (wire.ipv4.time-to-live B I) 0)
         (= (wire.ipv4.reserved B I) 0)
         (= (packet-checksum B I (wire.ipv4.size)) 0)))

(define fragmented?
  {buffer.view --> fixnum --> boolean}
  B I -> (or (= (wire.ipv4.more-fragments B I) 1)
             (not (= (wire.ipv4.fragment-offset B I) 0))))

(define valid?
  {buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  B I N Proto ->
    (and (valid-header? B I N)
         (not (fragmented? B I))
         (= (wire.ipv4.protocol B I) Proto)))
)
