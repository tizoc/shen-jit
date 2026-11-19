\\ An owned Linux TUN descriptor and its fixed receive scratch buffer.
(shen.x.namespace net-tun
  (use buffer)
  (use net-link)
  (use shen-jit)
  (import struct defstruct)
  (shadow close)
  (export adapter attach attach-tap close pump wait monotonic)

(defstruct adapter
  (device : net-link.device)
  (ingress : buffer.view)
  (mtu : fixnum)
  (guard : buffer.storage)
  (mutable fd : fixnum))

(define checked
  {fixnum --> symbol --> fixnum}
  N Op -> (if (fx>= N 0) N (error "net/tun ~A failed (Linux errno ~A)" Op (fx- 0 N))))

(define monotonic
  {fixnum --> fixnum}
  Origin -> (checked (fixnum (c-clock (fx->number Origin))) clock))

(define attach
  {net-link.device --> string --> adapter}
  D Name -> (open-device D Name false))

(define attach-tap
  {net-link.device --> string --> adapter}
  D Name -> (open-device D Name true))

(define open-device
  {net-link.device --> string --> boolean --> adapter}
  D Name Tap ->
    (let Mtu (net-link.mtu D)
         A (:adapter
             device <- D
             ingress <- (buffer.new (fx+ Mtu 1))
             mtu <- Mtu
             guard <- (make-guard 0)
             fd <- -1)
         Fd (checked (fixnum (c-open Name Tap)) open)
      (do (adapter.fd-> A Fd) A)))

(define live?
  {adapter --> boolean}
  A -> (not (= (shen-jit.pointer-address (adapter.guard A)) 0)))

(define descriptor
  {adapter --> fixnum}
  A -> (if (live? A) (adapter.fd A) (error "net/tun: closed or stale adapter")))

(define close
  {adapter --> boolean}
  A -> (if (live? A)
           (let Fd (adapter.fd A)
             (do (kill-guard (adapter.guard A))
                 (checked (fixnum (c-close (fx->number Fd))) close)
                 true))
           false))

\\ One extra byte lets us reject oversize packets even when TUN discards the tail.
(define ingress
  {adapter --> net-link.ring --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum}
  _ _ _ _ 0 Done -> Done
  A R Fd Delivery Budget Done ->
    (if (net-link.full? R) Done
        (let Scratch (adapter.ingress A)
             N (checked (c-read Fd (buffer.owner Scratch) (buffer.length Scratch)) read)
          (if (= N 0) Done
              (do (if (fx<= N (adapter.mtu A))
                      (do (buffer.copy-into! (net-link.ring.data R) (net-link.tail-offset R) Scratch 0 N)
                          (net-link.publish R N Delivery))
                      false)
                  (ingress A R Fd Delivery (fx- Budget 1) (fx+ Done 1)))))))

\\ Write directly out of the ring. On would-block the same packet stays queued.
(define egress
  {net-link.ring --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum}
  _ _ _ 0 Done -> Done
  R Fd Now Budget Done ->
    (if (net-link.ready? R Now)
        (let Packet (net-link.ring.data R)
             Start (net-link.head-offset R)
             Count (net-link.head-length R)
             Sent (if (fx> Count 0) (checked (c-write Fd (buffer.owner Packet) Start Count) write) 0)
          (if (= Count Sent)
              (do (net-link.consume R) (egress R Fd Now (fx- Budget 1) (fx+ Done 1)))
              Done))
        Done))

(define pump
  {adapter --> fixnum --> fixnum}
  A Budget ->
    (let Fd (descriptor A)
         Count (buffer.index Budget)
         D (adapter.device A)
         Now (net-link.now D)
         Written (egress (net-link.device.rx D) Fd Now Count 0)
         Read (ingress A (net-link.device.tx D) Fd (net-link.delivery D Now) Count 0)
      (fx+ Written Read)))

(define wait
  {adapter --> fixnum --> boolean}
  A Millis ->
    (let Fd (descriptor A)
         D (adapter.device A)
         T (buffer.index Millis)
         _ (if (fx<= T 2147483647) true (error "net/tun: wait exceeds Linux poll limit"))
         Read (not (net-link.full? (net-link.device.tx D)))
         Write (net-link.ready? (net-link.device.rx D) (net-link.now D))
      (fx> (checked (fixnum (c-wait (fx->number Fd) Read Write (fx->number T))) poll) 0)))

(preclude [adapter.%match])
)
