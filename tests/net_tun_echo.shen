\\ Echo kernel streams and datagrams using preallocated application buffers.
(shen.x.namespace tun-test
  (use buffer)
  (use net-link)
  (use net-tun)
  (use net-ipv4)
  (use net-interface)
  (use tcp)
  (use tcp-test)
  (use udp)
  (use shen-jit)
  (import struct defstruct)
  (shadow run)
  (export run)

(defstruct echo-session
  (scratch : buffer.view)
  (mutable token : fixnum)
  (mutable pending : fixnum)
  (mutable eof : boolean))

(defstruct server
  (interface : net-interface.interface)
  (streams : (vector echo-session))
  (capacity : fixnum)
  (datagram : buffer.view)
  (info : udp.recv-info)
  (mutable udp-pending : boolean)
  (mutable udp-full : boolean)
  (mutable udp-echoes : fixnum)
  (mutable active : fixnum)
  (mutable peak : fixnum)
  (mutable closed : fixnum)
  (mutable bytes : fixnum))

(define initialise-streams
  {(vector echo-session) --> fixnum --> (vector echo-session)}
  Streams 0 -> Streams
  Streams I ->
    (let S (:echo-session
              scratch <- (buffer.new 536)
              token <- 0
              pending <- 0
              eof <- false)
      (do (fxvector-> Streams I S)
          (initialise-streams Streams (fx- I 1)))))

(define make-server
  {net-interface.interface --> fixnum --> fixnum --> server}
  F N Mtu ->
    (:server
      interface <- F
      streams <- (initialise-streams (vector (fx->number N)) N)
      capacity <- N
      datagram <- (buffer.new (fx- Mtu 28))
      info <- (udp.make-recv-info)
      udp-pending <- false
      udp-full <- false
      udp-echoes <- 0
      active <- 0
      peak <- 0
      closed <- 0
      bytes <- 0))

(define listener
  {server --> tcp.listener}
  S -> (net-interface.interface.listener (server.interface S)))

(define accept-streams
  {server --> boolean}
  S ->
    (let L (listener S)
         Token (tcp.accept L)
      (if (= Token 0) true
          (let Stream (fx<-vector (server.streams S) (tcp.connection-index L Token))
               Active (fx+ (server.active S) 1)
            (do (echo-session.token-> Stream Token)
                (echo-session.pending-> Stream 0)
                (echo-session.eof-> Stream false)
                (server.active-> S Active)
                (if (fx> Active (server.peak S)) (server.peak-> S Active) S)
                (accept-streams S))))))

(define finish-stream
  {server --> echo-session --> boolean}
  S Stream ->
    (do (if (tcp.release (listener S) (echo-session.token Stream)) true
            (error "TUN echo could not release a closed stream"))
        (echo-session.token-> Stream 0)
        (server.active-> S (fx- (server.active S) 1))
        (server.closed-> S (fx+ (server.closed S) 1))
        true))

(define echo-stream
  {server --> echo-session --> boolean}
  S Stream ->
    (let L (listener S)
         Token (echo-session.token Stream)
         State (tcp.connection-state L Token)
      (cases (= State tcp.closed) (finish-stream S Stream)
             (or (= State tcp.timed-out) (= State tcp.reset))
               (error "TUN echo connection ~A stopped at ~A" (fx->number Token) State)
             true
               (let Scratch (echo-session.scratch Stream)
                    Pending (echo-session.pending Stream)
                    N (if (and (not (echo-session.eof Stream)) (= Pending 0))
                          (tcp.connection-recv-into L Token Scratch (buffer.length Scratch)) 0)
                    Available (if (fx> N 0) N Pending)
                    Sent (if (fx> Available 0) (tcp.connection-send L Token Scratch Available) 0)
                    Left (fx- Available Sent)
                 (do (if (= N -1) (echo-session.eof-> Stream true) Stream)
                     (if (and (fx> Sent 0) (fx> Left 0)) (buffer.copy-into! Scratch 0 Scratch Sent Left) Scratch)
                     (echo-session.pending-> Stream Left)
                     (server.bytes-> S (fx+ (server.bytes S) Sent))
                     (if (and (echo-session.eof Stream) (= Left 0) (= State tcp.close-wait))
                         (tcp.connection-shutdown-write L Token) false)
                     true)))))

(define echo-streams
  {server --> fixnum --> boolean}
  _ 0 -> true
  S I -> (let Stream (fx<-vector (server.streams S) I)
           (do (if (= (echo-session.token Stream) 0) true (echo-stream S Stream))
               (echo-streams S (fx- I 1)))))

(define report-udp-full
  {server --> boolean}
  S -> (if (and (not (server.udp-full S)) (fx> (net-interface.udp-dropped (server.interface S)) 0))
           (do (server.udp-full-> S true) (notify 1))
           false))

\\ Hold the mailbox full through the first wave. A blocked echo retains its own datagram.
(define echo-datagram
  {server --> boolean}
  S ->
    (if (fx< (server.closed S) (server.capacity S)) false
        (let F (server.interface S)
             Out (server.datagram S)
             Info (server.info S)
             Pending (or (server.udp-pending S) (= (net-interface.udp-recv-into F Out Info) udp.received))
          (if Pending
              (let Status (net-interface.udp-send F (udp.recv-info.source Info) (udp.recv-info.port Info)
                                                    Out (udp.recv-info.length Info))
                (cases (= Status udp.sent) (do (server.udp-pending-> S false)
                                               (server.udp-echoes-> S (fx+ (server.udp-echoes S) 1))
                                               true)
                       (= Status udp.would-block) (do (server.udp-pending-> S true) false)
                       true (error "TUN UDP echo did not fit the MTU")))
              false))))

(define echo
  {net-tun.adapter --> server --> fixnum --> fixnum --> fixnum}
  Tun S Until Expected ->
    (let F (server.interface S)
         In (net-tun.pump Tun 16)
         Handled (net-interface.poll F 16)
         _ (report-udp-full S)
         _ (accept-streams S)
         _ (echo-streams S (server.capacity S))
         _ (echo-datagram S)
         More (net-interface.poll F 16)
         Out (net-tun.pump Tun 16)
      (cases (and (= (server.closed S) Expected) (= (server.udp-echoes S) 3)) (server.bytes S)
             (fx>= (net-tun.monotonic 0) Until)
               (error "TUN echo timed out with ~A closed and ~A active TCP connections and ~A UDP echoes"
                      (fx->number (server.closed S)) (fx->number (server.active S))
                      (fx->number (server.udp-echoes S)))
             true
               (do (if (= (fx+ (fx+ In Out) (fx+ Handled More)) 0) (net-tun.wait Tun 10) false)
                   (echo Tun S Until Expected)))))

(define measured
  {net-tun.adapter --> server --> fixnum --> boolean}
  Tun S Expected ->
    (let Window (tcp-test.make-window-case 43)
         Until (fx+ (net-tun.monotonic 0) 25000)
         Scratch (echo-session.scratch (fx<-vector (server.streams S) 1))
         _ (mark 0)
         _ (words 0)
         _ (mark 0)
         View (buffer.slice Scratch 0 1)
         Control (words 0)
         _ (if (and (= (buffer.length View) 1) (fx> Control 0)) true (error "heap probe missed a new view"))
         _ (notify 0)
         _ (mark 0)
         _ (tcp-test.exercise-window Window 16)
         Count (echo Tun S Until Expected)
         Words (words 0)
      (if (= Words 0)
          (do (output "TUN echo ~A TCP bytes on ~A connections (peak ~A), UDP echoed ~A and dropped ~A, ~A heap words (control ~A)~%"
                      (fx->number Count) (fx->number (server.closed S)) (fx->number (server.peak S))
                      (fx->number (server.udp-echoes S))
                      (fx->number (net-interface.udp-dropped (server.interface S)))
                      (fx->number Words) (fx->number Control)) true)
          (error "TUN echo used ~A heap words (-1 means a collection)" (fx->number Words)))))

(define run
  {string --> boolean}
  Name ->
    (let Mtu (type 1500 fixnum)
         Link (net-link.make 8 Mtu 0 (freeze (net-tun.monotonic 0)))
         Guest (net-ipv4.address 192 0 2 2)
         Slots (type 4 fixnum)
         F (net-interface.make (net-link.left Link) Guest 7777 Slots 4294967290 7777 2)
         S (make-server F Slots Mtu)
         Tun (net-tun.attach (net-link.right Link) Name)
      (shen-jit.finally (freeze (measured Tun S 8)) (freeze (net-tun.close Tun)))))

(preclude [echo-session.%match server.%match])
)
