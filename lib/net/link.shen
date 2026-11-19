\\ Bounded, single-owner packet queues with a shared monotonic clock.
(shen.x.namespace net-link
  (use buffer)
  (import struct defstruct)
  (export link device ring ring.data ring.mtu ring.slots device.rx device.tx make make-ring left right mtu now delivery
          sent would-block too-large
          head-offset head-length head-deadline tail-offset ready? full? publish consume packet-send packet-recv-into)

(defstruct ring
  (data : buffer.view)
  (lengths : (vector fixnum))
  (times : (vector fixnum))
  (slots : fixnum)
  (mtu : fixnum)
  (mutable head : fixnum)
  (mutable tail : fixnum)
  (mutable count : fixnum))

(defstruct link
  (forward : ring)
  (reverse : ring)
  (clock : (lazy fixnum))
  (delay : fixnum)
  (mutable now : fixnum))

(defstruct device
  (link : link)
  (rx : ring)
  (tx : ring))

(define make-ring
  {fixnum --> fixnum --> ring}
  Slots Mtu ->
    (:ring
      data <- (buffer.new (fx* Slots Mtu))
      lengths <- (vector (fx->number Slots))
      times <- (vector (fx->number Slots))
      slots <- Slots
      mtu <- Mtu
      head <- 1
      tail <- 1
      count <- 0))

(define make
  {fixnum --> fixnum --> fixnum --> (lazy fixnum) --> link}
  Slots Mtu Delay Clock ->
    (let N (buffer.index Slots)
         Size (buffer.index Mtu)
         Span (buffer.index Delay)
         _ (if (and (fx> N 0) (and (fx>= Size 20) (fx<= Size 65535)))
               true (error "net-link: need positive queue capacity and an MTU in 20..65535"))
         Now (buffer.index (thaw Clock))
      (:link
        forward <- (make-ring N Size)
        reverse <- (make-ring N Size)
        clock <- Clock
        delay <- Span
        now <- Now)))

(define left
  {link --> device}
  L ->
    (:device
      link <- L
      rx <- (link.reverse L)
      tx <- (link.forward L)))

(define right
  {link --> device}
  L ->
    (:device
      link <- L
      rx <- (link.forward L)
      tx <- (link.reverse L)))

(define sample
  {link --> fixnum}
  L -> (let Clock (link.clock L)
            Now (buffer.index (thaw Clock))
         (if (fx< Now (link.now L))
             (error "net-link: clock moved backwards")
             (do (link.now-> L Now) Now))))

(define advance
  {ring --> fixnum --> fixnum}
  R I -> (if (= I (ring.slots R)) 1 (fx+ I 1)))

(define slot-offset
  {ring --> fixnum --> fixnum}
  R I -> (fx* (fx- I 1) (ring.mtu R)))

(define head-offset
  {ring --> fixnum}
  R -> (slot-offset R (ring.head R)))

(define head-length
  {ring --> fixnum}
  R -> (fx<-vector (ring.lengths R) (ring.head R)))

(define head-deadline
  {ring --> fixnum}
  R -> (if (fx> (ring.count R) 0) (fx<-vector (ring.times R) (ring.head R)) -1))

(define ready?
  {ring --> fixnum --> boolean}
  R Now -> (and (fx> (ring.count R) 0)
                (fx<= (fx<-vector (ring.times R) (ring.head R)) Now)))

(define full?
  {ring --> boolean}
  R -> (= (ring.count R) (ring.slots R)))

(define publish
  {ring --> fixnum --> fixnum --> boolean}
  R Count At -> (let I (ring.tail R)
                 (do (fxvector-> (ring.lengths R) I Count)
                     (fxvector-> (ring.times R) I At)
                     (ring.tail-> R (advance R I))
                     (ring.count-> R (fx+ (ring.count R) 1))
                     true)))

(define consume
  {ring --> boolean}
  R -> (do (ring.head-> R (advance R (ring.head R)))
           (ring.count-> R (fx- (ring.count R) 1))
           true))

(define tail-offset
  {ring --> fixnum}
  R -> (slot-offset R (ring.tail R)))

(define mtu
  {device --> fixnum}
  D -> (ring.mtu (device.tx D)))

(define now
  {device --> fixnum}
  D -> (sample (device.link D)))

(define delivery
  {device --> fixnum --> fixnum}
  D Now -> (fx+ Now (link.delay (device.link D))))

\\ Raw packet operations for a device peer. The output buffer belongs to the caller.
(define packet-send
  {device --> buffer.view --> fixnum --> symbol}
  D Packet Count ->
    (let N (buffer.index Count)
         _ (buffer.range (buffer.length Packet) 0 N)
         R (device.tx D)
      (cases (fx> N (ring.mtu R)) too-large
             (full? R) would-block
             true (let Delivery (delivery D (now D))
                    (do (buffer.copy-into! (ring.data R) (tail-offset R) Packet 0 N)
                        (publish R N Delivery)
                        sent)))))

(define packet-recv-into
  {device --> buffer.view --> fixnum}
  D Out ->
    (let R (device.rx D)
         Now (now D)
      (if (ready? R Now)
          (let N (head-length R)
            (if (fx> N (buffer.length Out))
                -2
                (do (buffer.copy-into! Out 0 (ring.data R) (head-offset R) N)
                    (consume R)
                    N)))
          -1)))

(preclude [ring.%match link.%match device.%match])
)
