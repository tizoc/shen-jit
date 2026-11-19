\\ A static, setup-owned IPv4 route table. Gateway zero means on-link.
(shen.x.namespace net-routes
  (use net-ipv4)
  (use shen-jit)
  (import struct defstruct)
  (export route make lookup)

(defstruct route
  (network : fixnum)
  (mask : fixnum)
  (prefix : fixnum)
  (gateway : fixnum))

(define make
  {fixnum --> fixnum --> fixnum --> route}
  Network Prefix Gateway ->
    (if (and (fx>= Network 0) (fx<= Network 4294967295)
             (fx>= Prefix 0) (fx<= Prefix 32)
             (or (= Gateway 0) (net-ipv4.unicast? Gateway)))
        (let HostBits (fx- 32 Prefix)
             Mask (fx- 4294967296 (shen-jit.shift-left 1 HostBits))
          (:route
            network <- (shen-jit.bit-and Network Mask)
            mask <- Mask
            prefix <- Prefix
            gateway <- Gateway))
        (error "net/routes: invalid IPv4 route")))

(define longest
  {(list route) --> fixnum --> fixnum --> fixnum --> fixnum}
  [] _ _ Hop -> Hop
  [R | Rest] IP Prefix Hop ->
    (if (and (fx> (route.prefix R) Prefix)
             (= (shen-jit.bit-and IP (route.mask R)) (route.network R)))
        (longest Rest IP (route.prefix R) (if (= (route.gateway R) 0) IP (route.gateway R)))
        (longest Rest IP Prefix Hop)))

(define lookup
  {(list route) --> fixnum --> fixnum}
  Routes IP -> (if (net-ipv4.unicast? IP) (longest Routes IP -1 0) (type 0 fixnum)))

(preclude [route.%match])
)
