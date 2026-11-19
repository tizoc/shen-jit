\\ Fixed-header, unfragmented IPv4 and checksums shared by UDP and TCP.
(shen.x.namespace net-ipv4
  (use buffer)
  (use shen-jit)
  (use net-wire => wire)
  (import layout write-layout)
  (export address broadcast unicast? multicast? multicast-mac write-header write-header-ttl header-length valid-envelope? valid? valid-header? fragmented?
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

\\ 255.255.255.255, the limited broadcast address.
(define broadcast
  {--> fixnum}
  -> 4294967295)

(define multicast?
  {fixnum --> boolean}
  IP -> (and (fx>= IP 3758096384) (fx< IP 4026531840)))

(define multicast-mac
  {fixnum --> fixnum}
  IP -> (fx+ 1101088686080 (shen-jit.bit-and IP 8388607)))

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

\\ The same with another TTL, as a group's datagrams take 1.
(define write-header-ttl
  {buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> buffer.view}
  B I Count Proto Src Dst TTL ->
    (do (write-layout wire.ipv4 B I
          (version 4) (header-length 5) (total-length Count)
          (dont-fragment 1) (time-to-live TTL) (protocol Proto)
          (source Src) (destination Dst))
        (wire.ipv4.checksum-> B I (packet-checksum B I (wire.ipv4.size)))))

(define header-length
  {buffer.view --> fixnum --> fixnum}
  B I -> (fx* 4 (wire.ipv4.header-length B I)))

\\ RFC 791: what a header of Bytes bytes, options included, says of a packet of N.
(define sound?
  {buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  B I N Bytes ->
    (and (= (wire.ipv4.total-length B I) N)
         (fx> (wire.ipv4.time-to-live B I) 0)
         (= (wire.ipv4.reserved B I) 0)
         (= (packet-checksum B I Bytes) 0)))

\\ A header without options, as all here are but IGMP's.
(define valid-header?
  {buffer.view --> fixnum --> fixnum --> boolean}
  B I N -> (and (fx>= N (wire.ipv4.size)) (= (wire.ipv4.version B I) 4) (= (wire.ipv4.header-length B I) 5)
                (sound? B I N (wire.ipv4.size))))

\\ A header with options or without.
(define valid-envelope?
  {buffer.view --> fixnum --> fixnum --> boolean}
  B I N -> (and (fx>= N (wire.ipv4.size)) (= (wire.ipv4.version B I) 4)
                (let Bytes (header-length B I)
                  (and (fx>= Bytes (wire.ipv4.size)) (fx<= Bytes N) (sound? B I N Bytes)))))

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
