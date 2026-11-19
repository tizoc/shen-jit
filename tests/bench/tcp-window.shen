(shen.x.namespace tcp-window-bench
  (use tcp)
  (use buffer)
  (use net-link)
  (use net-ipv4)
  (import struct defstruct)
  (shadow run)
  (export run)

(defstruct transfer
  (time : (vector fixnum))
  (client : tcp.peer)
  (server : tcp.peer)
  (input : buffer.view)
  (output : buffer.view)
  (mutable remaining : fixnum)
  (mutable received : fixnum))

(define clock
  {fixnum --> (vector fixnum)}
  Now -> (fxvector-> (vector 1) 1 Now))

(define setup
  {fixnum --> transfer}
  Delay ->
    (let Time (clock 0)
         Link (net-link.make 32 1500 Delay (freeze (fx<-vector Time 1)))
         A (net-ipv4.address 192 0 2 1)
         B (net-ipv4.address 192 0 2 2)
      (:transfer
        time <- Time
        client <- (tcp.make-peer (net-link.left Link) A 12345 B 7)
        server <- (tcp.make-peer (net-link.right Link) B 7 A 12345)
        input <- (buffer.new 536)
        output <- (buffer.new 4288)
        remaining <- 131072
        received <- 0)))

(define handshake
  {transfer --> fixnum --> boolean}
  T Delay ->
    (let Time (transfer.time T)
         C (transfer.client T)
         S (transfer.server T)
      (do (tcp.listen S 1000)
          (tcp.connect C 4294967200)
          (tcp.poll C 32)
          (fxvector-> Time 1 Delay)
          (tcp.poll S 32)
          (fxvector-> Time 1 (fx* Delay 2))
          (tcp.poll C 32)
          (fxvector-> Time 1 (fx* Delay 3))
          (tcp.poll S 32)
          (if (and (= (tcp.state C) tcp.established) (= (tcp.state S) tcp.established)) true
              (error "TCP benchmark handshake failed")))))

\\ Service application and packet queues several times before advancing simulated time.
(define service
  {transfer --> fixnum --> boolean}
  _ 0 -> true
  T Steps ->
    (let C (transfer.client T)
         S (transfer.server T)
         Left (transfer.remaining T)
         N (if (fx< Left 536) Left 536)
         Sent (tcp.send C (transfer.input T) N)
         _ (transfer.remaining-> T (fx- Left Sent))
         _ (tcp.poll C 32)
         _ (tcp.poll S 32)
         Received (tcp.recv-into S (transfer.output T) 4288)
      (do (transfer.received-> T (fx+ (transfer.received T) Received))
          (service T (fx- Steps 1)))))

(define advance
  {transfer --> fixnum --> fixnum --> fixnum --> fixnum}
  T Delay Now Deadline ->
    (do (service T 32)
        (cases (= (transfer.received T) 131072) Now
               (fx>= Now Deadline) (error "TCP benchmark transfer timed out")
               true (let Next (fx+ Now Delay)
                      (do (fxvector-> (transfer.time T) 1 Next)
                          (advance T Delay Next Deadline))))))

(define measure
  {fixnum --> boolean}
  Delay ->
    (let T (setup Delay)
         _ (handshake T Delay)
         Start (fx<-vector (transfer.time T) 1)
         Elapsed (fx- (advance T Delay Start (fx+ Start (fx* Delay 1024))) Start)
      (do (output "~A ms RTT, 131072 bytes in ~A ms~%" (fx->number (fx* Delay 2)) (fx->number Elapsed))
          true)))

(define run
  {--> boolean}
  -> (and (measure 1) (measure 10) (measure 50)))

(preclude [transfer.%match])
)
