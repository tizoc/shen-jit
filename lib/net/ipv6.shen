\\ IPv6 base headers and addresses stored as four unsigned words.
(shen.x.namespace net-ipv6
  (use buffer)
  (use shen-jit)
  (use net-ipv4)
  (import struct defstruct)
  (export address make-address address.a address.b address.c address.d copy-address read-address
          write-address compose-prefix same? address-at? unspecified? multicast? unicast? link-local?
          solicited-node solicited-node? multicast-mac-at
          valid-header? write-header transport-checksum)

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
    (do (address.a-> Out (buffer.u32-be B I))
        (address.b-> Out (buffer.u32-be B (fx+ I 4)))
        (address.c-> Out (buffer.u32-be B (fx+ I 8)))
        (address.d-> Out (buffer.u32-be B (fx+ I 12)))))

(define write-address
  {buffer.view --> fixnum --> address --> buffer.view}
  B I A ->
    (do (buffer.u32-be-> B I (address.a A))
        (buffer.u32-be-> B (fx+ I 4) (address.b A))
        (buffer.u32-be-> B (fx+ I 8) (address.c A))
        (buffer.u32-be-> B (fx+ I 12) (address.d A))))

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
  A B I -> (and (= (address.a A) (buffer.u32-be B I))
                (= (address.b A) (buffer.u32-be B (fx+ I 4)))
                (= (address.c A) (buffer.u32-be B (fx+ I 8)))
                (= (address.d A) (buffer.u32-be B (fx+ I 12)))))

(define unspecified?
  {address --> boolean}
  A -> (and (= (address.a A) 0) (= (address.b A) 0) (= (address.c A) 0) (= (address.d A) 0)))

(define multicast?
  {address --> boolean}
  A -> (= (shen-jit.shift-right (address.a A) 24) 255))

(define link-local?
  {address --> boolean}
  A -> (= (shen-jit.shift-right (address.a A) 22) 1018))

(define unicast?
  {address --> boolean}
  A -> (and (not (unspecified? A)) (not (multicast? A))))

(define solicited-node
  {address --> address --> address}
  Out Target ->
    (let Low (fx+ 4278190080 (shen-jit.bit-and (address.d Target) 16777215))
      (do (address.a-> Out 4278321152)
          (address.b-> Out 0)
          (address.c-> Out 1)
          (address.d-> Out Low))))

(define solicited-node?
  {address --> address --> boolean}
  Group Target ->
    (and (= (address.a Group) 4278321152) (= (address.b Group) 0)
         (= (address.c Group) 1)
         (= (address.d Group) (fx+ 4278190080 (shen-jit.bit-and (address.d Target) 16777215)))))

(define multicast-mac-at
  {buffer.view --> fixnum --> fixnum}
  B I -> (fx+ 56294136348672 (buffer.u32-be B (fx+ I 12))))

(define valid-header?
  {buffer.view --> fixnum --> fixnum --> boolean}
  B I N ->
    (and (fx>= N 40)
         (= (shen-jit.shift-right (buffer.u8 B I) 4) 6)
         (= (buffer.u16-be B (fx+ I 4)) (fx- N 40))
         (fx> (buffer.u8 B (fx+ I 7)) 0)))

(define write-header
  {buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> address --> address --> buffer.view}
  B I Count Proto Hop Source Destination ->
    (do (buffer.u32-be-> B I 1610612736)
        (buffer.u16-be-> B (fx+ I 4) (fx- Count 40))
        (buffer.u8-> B (fx+ I 6) Proto)
        (buffer.u8-> B (fx+ I 7) Hop)
        (write-address B (fx+ I 8) Source)
        (write-address B (fx+ I 24) Destination)))

(define transport-checksum
  {buffer.view --> fixnum --> fixnum --> fixnum --> fixnum}
  B I Proto Length ->
    (let Pseudo (net-ipv4.sum16 B (fx+ I 8) 32 (fx+ Proto Length))
      (net-ipv4.checksum (net-ipv4.sum16 B (fx+ I 40) Length Pseudo))))

(preclude [address.%match])
)
