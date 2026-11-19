\\ IPv6 base headers and addresses stored as four unsigned words.
(shen.x.namespace net-ipv6
  (use buffer)
  (use shen-jit)
  (use net-ipv4)
  (use net-wire => wire)
  (import struct defstruct)
  (import layout write-layout)
  (export address make-address address.a address.b address.c address.d copy-address read-address
          write-address compose-prefix same? address-at? unspecified? multicast? multicast-at? scope unicast? link-local?
          solicited-node solicited-node? multicast-mac-at link-group minimum-mtu error-quote map-ipv4 mapped?
          valid-header? write-header transport-checksum transport-checksum-at)

(defstruct address
  (mutable a : fixnum)
  (mutable b : fixnum)
  (mutable c : fixnum)
  (mutable d : fixnum))

(define word
  {fixnum --> fixnum}
  X -> (if (and (fx>= X 0) (fx<= X 4294967295)) X (error "IPv6: address word is outside uint32")))

(define make-address
  {fixnum --> fixnum --> fixnum --> fixnum --> address}
  A B C D ->
    (:address
      a <- (word A)
      b <- (word B)
      c <- (word C)
      d <- (word D)))

(define copy-address
  {address --> address --> address}
  Out In ->
    (do (address.a-> Out (address.a In))
        (address.b-> Out (address.b In))
        (address.c-> Out (address.c In))
        (address.d-> Out (address.d In))))

(define read-address
  {address --> buffer.view --> fixnum --> address}
  Out B I ->
    (do (address.a-> Out (wire.ipv6-address.a B I))
        (address.b-> Out (wire.ipv6-address.b B I))
        (address.c-> Out (wire.ipv6-address.c B I))
        (address.d-> Out (wire.ipv6-address.d B I))))

(define write-address
  {buffer.view --> fixnum --> address --> buffer.view}
  B I A ->
    (write-layout wire.ipv6-address B I (a (address.a A)) (b (address.b A)) (c (address.c A)) (d (address.d A))))

(define compose-prefix
  {address --> address --> address --> address}
  Out Prefix Id ->
    (do (address.a-> Out (address.a Prefix))
        (address.b-> Out (address.b Prefix))
        (address.c-> Out (address.c Id))
        (address.d-> Out (address.d Id))))

(define same?
  {address --> address --> boolean}
  A B -> (and (= (address.a A) (address.a B))
              (= (address.b A) (address.b B))
              (= (address.c A) (address.c B))
              (= (address.d A) (address.d B))))

(define address-at?
  {address --> buffer.view --> fixnum --> boolean}
  A B I -> (and (= (address.a A) (wire.ipv6-address.a B I))
                (= (address.b A) (wire.ipv6-address.b B I))
                (= (address.c A) (wire.ipv6-address.c B I))
                (= (address.d A) (wire.ipv6-address.d B I))))

(define unspecified?
  {address --> boolean}
  A -> (and (= (address.a A) 0) (= (address.b A) 0) (= (address.c A) 0) (= (address.d A) 0)))

(define multicast?
  {address --> boolean}
  A -> (= (shen-jit.shift-right (address.a A) 24) 255))

\\ Whether the address at I of B is a group's, as its first byte says.
(define multicast-at?
  {buffer.view --> fixnum --> boolean}
  B I -> (= (shen-jit.shift-right (wire.ipv6-address.a B I) 24) 255))

(define scope
  {address --> fixnum}
  A -> (shen-jit.bit-and (shen-jit.shift-right (address.a A) 16) 15))

(define link-local?
  {address --> boolean}
  A -> (= (shen-jit.shift-right (address.a A) 22) 1018))

(define unicast?
  {address --> boolean}
  A -> (and (not (unspecified? A)) (not (multicast? A))))

\\ RFC 4291 2.7: ff02::, the first word of a group of link scope, and the group ff02::Id.
\\ RFC 4291 2.5.5.2: an IPv4 address as an IPv6 one, ::ffff:a.b.c.d, as tables keep both kinds.
(define map-ipv4
  {address --> fixnum --> address}
  Out IP -> (do (address.a-> Out 0) (address.b-> Out 0) (address.c-> Out 65535) (address.d-> Out IP)))

(define mapped?
  {address --> boolean}
  A -> (and (= (address.c A) 65535) (= (address.b A) 0) (= (address.a A) 0)))

(define link-scope
  {--> fixnum}
  -> 4278321152)

(define link-group
  {fixnum --> address}
  Id -> (make-address (link-scope) 0 0 Id))

\\ RFC 8200 5: every link carries 1,280 bytes; RFC 4443 2.4: an error quotes what fits in them.
(define minimum-mtu
  {--> fixnum}
  -> 1280)

(define error-quote
  {--> fixnum}
  -> (fx- (minimum-mtu) (fx+ (wire.ipv6.size) (wire.icmp.size))))

(define solicited-node
  {address --> address --> address}
  Out Target ->
    (let Low (fx+ 4278190080 (shen-jit.bit-and (address.d Target) 16777215))
      (do (address.a-> Out (link-scope))
          (address.b-> Out 0)
          (address.c-> Out 1)
          (address.d-> Out Low))))

(define solicited-node?
  {address --> address --> boolean}
  Group Target ->
    (and (= (address.a Group) (link-scope)) (= (address.b Group) 0)
         (= (address.c Group) 1)
         (= (address.d Group) (fx+ 4278190080 (shen-jit.bit-and (address.d Target) 16777215)))))

(define multicast-mac-at
  {buffer.view --> fixnum --> fixnum}
  B I -> (fx+ 56294136348672 (wire.ipv6-address.d B I)))      \\ 33:33, then the low 32 bits (RFC 2464).

(define valid-header?
  {buffer.view --> fixnum --> fixnum --> boolean}
  B I N ->
    (and (fx>= N (wire.ipv6.size))
         (= (wire.ipv6.version B I) 6)
         (= (wire.ipv6.payload-length B I) (fx- N (wire.ipv6.size)))
         (fx> (wire.ipv6.hop-limit B I) 0)))

(define write-header
  {buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> address --> address --> buffer.view}
  B I Count Proto Hop Source Destination ->
    (do (write-layout wire.ipv6 B I
          (version 6) (payload-length (fx- Count (wire.ipv6.size))) (next-header Proto) (hop-limit Hop))
        (write-address B (wire.ipv6.source-at I) Source)
        (write-address B (wire.ipv6.destination-at I) Destination)))

(define transport-checksum
  {buffer.view --> fixnum --> fixnum --> fixnum --> fixnum}
  B I Proto Length -> (transport-checksum-at B I (fx+ I (wire.ipv6.size)) Proto Length))

\\ The same, for an upper-layer header at At, after extension headers.
(define transport-checksum-at
  {buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum}
  B I At Proto Length ->
    (let Pseudo (net-ipv4.sum16 B (wire.ipv6.source-at I) 32 (fx+ Proto Length))   \\ Both addresses.
      (net-ipv4.checksum (net-ipv4.sum16 B At Length Pseudo))))

(preclude [address.%match])
)
