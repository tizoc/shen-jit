\\ DHCPv4 client for address acquisition, renewal and rebinding.
(shen.x.namespace net-dhcp
  (use buffer)
  (use net-link)
  (use net-ipv4)
  (use udp)
  (use shen-jit)
  (import struct defstruct)
  (export client make poll maintain
          client.state client.address client.mask client.gateway client.dns
          client.deadline client.expires selecting requesting bound renewing rebinding expired)

(defstruct options
  (mutable kind : fixnum)
  (mutable server : fixnum)
  (mutable mask : fixnum)
  (mutable gateway : fixnum)
  (mutable dns : fixnum)
  (mutable lease : fixnum)
  (mutable renew : fixnum)
  (mutable rebind : fixnum))

(defstruct client
  (device : net-link.device)
  (mac : fixnum)
  (out : buffer.view)
  (in : buffer.view)
  (info : udp.recv-info)
  (options : options)
  (mutable id : fixnum)
  (mutable state : symbol)
  (mutable address : fixnum)
  (mutable mask : fixnum)
  (mutable gateway : fixnum)
  (mutable dns : fixnum)
  (mutable server : fixnum)
  (mutable deadline : fixnum)
  (mutable expires : fixnum)
  (mutable renewal : fixnum)
  (mutable rebinding : fixnum)
  (mutable attempts : fixnum))

(define make
  {net-link.device --> fixnum --> fixnum --> client}
  D Mac Id ->
    (if (and (fx>= (net-link.mtu D) 576) (fx> Mac 0) (fx<= Mac 281474976710655)
             (= (shen-jit.bit-and Mac 1099511627776) 0)
             (fx>= Id 0) (fx<= Id 4294967295))
        (:client
          device <- D
          mac <- Mac
          out <- (buffer.new 300)
          in <- (buffer.new (fx- (net-link.mtu D) 28))
          info <- (udp.make-recv-info)
          options <- (:options
                        kind <- 0
                        server <- 0
                        mask <- 0
                        gateway <- 0
                        dns <- 0
                        lease <- 0
                        renew <- 0
                        rebind <- 0)
          id <- Id
          state <- selecting
          address <- 0
          mask <- 0
          gateway <- 0
          dns <- 0
          server <- 0
          deadline <- 0
          expires <- 0
          renewal <- 0
          rebinding <- 0
          attempts <- 0)
        (error "net/dhcp: invalid hardware address, transaction ID, or MTU below 576")))

(define begin
  {client --> symbol --> fixnum --> boolean}
  C Phase Now ->
    (do (client.state-> C Phase)
        (client.deadline-> C Now)
        (client.attempts-> C 0)
        true))

(define next-id
  {client --> client}
  C -> (client.id-> C (shen-jit.bit-and (fx+ (client.id C) 1) 4294967295)))

(define reset-options
  {options --> options}
  O -> (do (options.kind-> O 0)
           (options.server-> O 0)
           (options.mask-> O 0)
           (options.gateway-> O 0)
           (options.dns-> O 0)
           (options.lease-> O 0)
           (options.renew-> O 0)
           (options.rebind-> O 0)))

(define option
  {options --> buffer.view --> fixnum --> fixnum --> fixnum --> options}
  O B I Len Kind ->
    (cases (and (= Kind 53) (= Len 1)) (options.kind-> O (buffer.u8 B I))
           (and (= Kind 54) (= Len 4)) (options.server-> O (buffer.u32-be B I))
           (and (= Kind 1) (= Len 4)) (options.mask-> O (buffer.u32-be B I))
           (and (= Kind 3) (fx>= Len 4)) (options.gateway-> O (buffer.u32-be B I))
           (and (= Kind 6) (fx>= Len 4)) (options.dns-> O (buffer.u32-be B I))
           (and (= Kind 51) (= Len 4)) (options.lease-> O (buffer.u32-be B I))
           (and (= Kind 58) (= Len 4)) (options.renew-> O (buffer.u32-be B I))
           (and (= Kind 59) (= Len 4)) (options.rebind-> O (buffer.u32-be B I))
           true O))

(define read-options
  {options --> buffer.view --> fixnum --> fixnum --> boolean}
  O B I End ->
    (if (fx>= I End) false
        (let Kind (buffer.u8 B I)
          (cases (= Kind 255) true
                 (= Kind 0) (read-options O B (fx+ I 1) End)
                 (fx>= (fx+ I 1) End) false
                 true (let Len (buffer.u8 B (fx+ I 1))
                            Data (fx+ I 2)
                            Next (fx+ Data Len)
                         (and (fx<= Next End)
                              (read-options (option O B Data Len Kind) B Next End)))))))

(define option-ip
  {fixnum --> fixnum --> fixnum}
  IP Default -> (if (net-ipv4.unicast? IP) IP Default))

(define valid-mask?
  {fixnum --> boolean}
  Mask ->
    (let Host (shen-jit.bit-xor Mask 4294967295)
      (and (fx> Mask 0) (= (shen-jit.bit-and Host (fx+ Host 1)) 0))))

(define commit-lease
  {client --> options --> fixnum --> fixnum --> boolean}
  C O IP Now ->
    (let Lease (options.lease O)
         Mask (options.mask O)
         T1 (options.renew O)
         T2 (options.rebind O)
         Span (fx* Lease 1000)
         Renew (if (and (fx> T1 0) (fx< T1 Lease)) (fx* T1 1000) (fxquotient Span 2))
         Rebind (if (and (fx> (fx* T2 1000) Renew) (fx< T2 Lease)) (fx* T2 1000)
                    (fxquotient (fx* Span 7) 8))
         At (if (fx< Renew Rebind) Renew (fxquotient Span 2))
      (if (and (fx> Lease 0) (net-ipv4.unicast? IP) (net-ipv4.unicast? (options.server O)))
          (do (client.address-> C IP)
              (if (valid-mask? Mask) (client.mask-> C Mask) C)
              (client.gateway-> C (option-ip (options.gateway O) (client.gateway C)))
              (client.dns-> C (option-ip (options.dns O) (client.dns C)))
              (client.server-> C (options.server O))
              (client.expires-> C (fx+ Now Span))
              (client.rebinding-> C (fx+ Now Rebind))
              (client.renewal-> C (fx+ Now At))
              (begin C bound (fx+ Now At)))
          false)))

(define accept-options
  {client --> options --> fixnum --> fixnum --> boolean}
  C O IP Now ->
    (let Phase (client.state C)
         Kind (options.kind O)
         Server (options.server O)
         Match (and (net-ipv4.unicast? Server)
                    (or (= Phase rebinding) (= Server (client.server C))))
      (cases (and (= Phase selecting) (= Kind 2) (net-ipv4.unicast? IP) (net-ipv4.unicast? Server))
               (do (client.address-> C IP) (client.server-> C Server) (begin C requesting Now))
             (and (= Phase requesting) (= Kind 5) Match (= IP (client.address C)))
               (commit-lease C O IP Now)
             (and (or (= Phase renewing) (= Phase rebinding)) (= Kind 5) Match
                  (or (= IP 0) (= IP (client.address C))))
               (commit-lease C O (client.address C) Now)
             (and Match (= Kind 6) (not (= Phase selecting)))
               (do (client.address-> C 0)
                   (client.mask-> C 0)
                   (client.gateway-> C 0)
                   (client.dns-> C 0)
                   (client.server-> C 0)
                   (next-id C)
                   (begin C (if (= Phase requesting) selecting expired) Now))
             true false)))

(define accept
  {client --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  C B I N Now ->
    (and (fx>= N 241)
         (= (buffer.u16-be B I) 513) \\ BOOTREPLY, Ethernet.
         (= (buffer.u8 B (fx+ I 2)) 6)
         (= (buffer.u32-be B (fx+ I 4)) (client.id C))
         (= (buffer.u16-be B (fx+ I 28)) (shen-jit.shift-right (client.mac C) 32))
         (= (buffer.u32-be B (fx+ I 30)) (shen-jit.bit-and (client.mac C) 4294967295))
         (= (buffer.u32-be B (fx+ I 236)) 1669485411)
         (let O (reset-options (client.options C))
           (and (read-options O B (fx+ I 240) (fx+ I N))
                (accept-options C O (buffer.u32-be B (fx+ I 16)) Now)))))

(define init-input
  {client --> net-link.ring --> fixnum --> fixnum --> boolean}
  _ _ _ 0 -> false
  C R Now Left ->
    (and (net-link.ready? R Now)
         (let B (net-link.ring.data R)
              At (net-link.head-offset R)
              N (net-link.head-length R)
              OK (and (udp.valid-datagram? B At N)
                      (= (buffer.u32-be B (fx+ At 20)) 4390980)
                      (accept C B (fx+ At 28) (fx- N 28) Now))
           (do (net-link.consume R)
               (or OK (init-input C R Now (fx- Left 1)))))))

(define bound-input
  {client --> udp.inbox --> fixnum --> fixnum --> boolean}
  _ _ _ 0 -> false
  C Inbox Now Left ->
    (let B (client.in C)
         Info (client.info C)
         Status (udp.inbox-recv-into Inbox B Info)
      (cases (= Status udp.empty) false
             (= Status udp.too-small) (do (udp.inbox-discard Inbox)
                                           (bound-input C Inbox Now (fx- Left 1)))
             (and (= (udp.recv-info.port Info) 67) (accept C B 0 (udp.recv-info.length Info) Now)) true
             true (bound-input C Inbox Now (fx- Left 1)))))

(define clear
  {buffer.view --> fixnum --> buffer.view}
  B 300 -> B
  B I -> (clear (buffer.u32-be-> B I 0) (fx+ I 4)))

(define write-payload
  {client --> boolean --> boolean --> buffer.view}
  C Configured Broadcast ->
    (let B (clear (client.out C) 0)
         State (client.state C)
      (do (buffer.u32-be-> B 0 16844288)
          (buffer.u32-be-> B 4 (client.id C))
          (if Broadcast (buffer.u16-be-> B 10 32768) B)
          (if Configured (buffer.u32-be-> B 12 (client.address C)) B)
          (buffer.u16-be-> B 28 (shen-jit.shift-right (client.mac C) 32))
          (buffer.u32-be-> B 30 (shen-jit.bit-and (client.mac C) 4294967295))
          (buffer.u32-be-> B 236 1669485411)
          (buffer.u16-be-> B 240 13569)
          (buffer.u8-> B 242 (if (= State selecting) 1 3))
          (buffer.u32-be-> B 243 923140355) \\ Parameter request list, mask and router.
          (buffer.u32-be-> B 247 104020539) \\ DNS, lease, T1 and T2.
          (if (= State requesting)
              (do (buffer.u16-be-> B 251 12804)
                  (buffer.u32-be-> B 253 (client.address C))
                  (buffer.u16-be-> B 257 13828)
                  (buffer.u32-be-> B 259 (client.server C))
                  (buffer.u8-> B 263 255))
              (buffer.u8-> B 251 255)))))

(define transmit
  {client --> fixnum --> boolean}
  C Now ->
    (let D (client.device C)
         Tx (net-link.device.tx D)
         State (client.state C)
         Configured (or (= State renewing) (= State rebinding))
         Broadcast (not (= State renewing))
         Attempts (client.attempts C)
         Delay (shen-jit.shift-left 1000 (if (fx< Attempts 5) Attempts (type 5 fixnum)))
         Deadline (fx+ Now Delay)
      (if (net-link.full? Tx) false
          (do (udp.write-packet (net-link.ring.data Tx) (net-link.tail-offset Tx)
                                (if Configured (client.address C) 0) 68
                                (if Broadcast 4294967295 (client.server C)) 67
                                (write-payload C Configured Broadcast) 0 300)
              (net-link.publish Tx 328 (net-link.delivery D Now))
              (client.attempts-> C (fx+ Attempts 1))
              (client.deadline-> C
                (cases (and (= State renewing) (fx> Deadline (client.rebinding C))) (client.rebinding C)
                       (and (= State rebinding) (fx> Deadline (client.expires C))) (client.expires C)
                       true Deadline))
              true))))

(define drive
  {client --> fixnum --> symbol}
  C Now ->
    (let State (client.state C)
      (cases (or (= State expired) (fx< Now (client.deadline C))) State
             (= State bound) (do (next-id C) (begin C renewing Now) (drive C Now))
             (and (or (= State renewing) (= State rebinding)) (fx>= Now (client.expires C)))
               (do (client.address-> C 0) (begin C expired -1) expired)
             (and (= State renewing) (fx>= Now (client.rebinding C)))
               (do (begin C rebinding Now) (drive C Now))
             (and (= State requesting) (fx>= (client.attempts C) 4))
               (do (next-id C) (begin C selecting Now) (drive C Now))
             true (do (transmit C Now) State))))

(define poll
  {client --> fixnum --> symbol}
  C Budget ->
    (let D (client.device C)
         Now (net-link.now D)
         State (client.state C)
      (if (or (= State selecting) (= State requesting))
          (do (init-input C (net-link.device.rx D) Now (buffer.index Budget)) (drive C Now))
          State)))

(define maintain
  {client --> udp.inbox --> fixnum --> symbol}
  C Inbox Budget ->
    (let Now (net-link.now (client.device C))
         State (client.state C)
      (if (or (= State bound) (= State renewing) (= State rebinding))
          (do (if (and (not (= State bound)) (fx< Now (client.expires C)))
                  (bound-input C Inbox Now (buffer.index Budget)) false)
              (drive C Now))
          State)))

(preclude [client.%match options.%match])
)
