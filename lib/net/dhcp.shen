\\ DHCPv4 client for address acquisition, renewal and rebinding.
(shen.x.namespace net-dhcp
  (use buffer)
  (use net-link)
  (use net-ipv4)
  (use udp)
  (use shen-jit)
  (use net-wire => wire)
  (use grammar)
  (import struct defstruct)
  (import layout write-layout)
  (externals [defgrammar u32-be <end> require skip])
  (export client make poll maintain
          client.state client.address client.mask client.gateway client.dns
          client.deadline client.expires selecting requesting bound renewing rebinding expired state)

\\ RFC 2131 4.4: a client's states, and the one its lease ends in.
(datatype states
  if (element? State [selecting requesting bound renewing rebinding expired])
  ___________________________________________________________________________
  State : state;)

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
  (mutable state : state)
  (mutable address : fixnum)
  (mutable mask : fixnum)
  (mutable gateway : fixnum)
  (mutable dns : fixnum)
  (mutable server : fixnum)
  (mutable deadline : fixnum)
  (mutable expires : fixnum)
  (mutable renewal : fixnum)
  (mutable rebinding : fixnum)
  (mutable attempts : fixnum)
  (option-state : grammar.state))

\\ RFC 2131 3 and 4.1: the magic cookie, the ports, the messages a client sends and takes, and the end
\\ of the options; RFC 1542 2.1: a message of at least 300 bytes.
(define cookie {--> fixnum} -> 1669485411)
(define server-port {--> fixnum} -> 67)
(define client-port {--> fixnum} -> 68)
(define discover-message {--> fixnum} -> 1)
(define offer-message {--> fixnum} -> 2)
(define request-message {--> fixnum} -> 3)
(define ack-message {--> fixnum} -> 5)
(define nak-message {--> fixnum} -> 6)
(define end-option {--> fixnum} -> 255)
(define message-size {--> fixnum} -> 300)

(define make
  {net-link.device --> fixnum --> fixnum --> client}
  D Mac Id ->
    (if (and (fx>= (net-link.mtu D) 576) (wire.station-mac? Mac)                  \\ RFC 2131 2: 576-byte messages.
             (fx>= Id 0) (fx<= Id 4294967295))
        (:client
          device <- D
          mac <- Mac
          out <- (buffer.new (message-size))
          option-state <- (grammar.state)
          in <- (buffer.new (fx- (net-link.mtu D) (fx+ (wire.ipv4.size) (wire.udp.size))))
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
  {client --> state --> fixnum --> boolean}
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

\\ DHCP's options, RFC 2132: a code, and for all but padding and the end, a length and that many bytes.
\\ Those the client uses are read into O as they are matched, and the list must end. Once an option is
\\ known, the rest of the list is required, so that no other alternative parses it again.
(defgrammar (<options> O) {options ==> boolean}
  255 (* _) := true;                                                     \\ The end; padding follows.
  0 (require (<options> O) "malformed options") := <options>;            \\ Padding.
  53 1 Kind (require (<options> (options.kind-> O Kind)) "malformed options") := <options>;      \\ Message type.
  54 4 (u32-be IP) (require (<options> (options.server-> O IP)) "malformed options") := <options>;   \\ Server.
  1 4 (u32-be Mask) (require (<options> (options.mask-> O Mask)) "malformed options") := <options>;  \\ Subnet mask.
  3 Length (where (fx>= Length 4)) (u32-be IP) (skip (fx- Length 4))                       \\ Routers,
    (require (<options> (options.gateway-> O IP)) "malformed options") := <options>;               \\ the first.
  6 Length (where (fx>= Length 4)) (u32-be IP) (skip (fx- Length 4))                       \\ DNS servers,
    (require (<options> (options.dns-> O IP)) "malformed options") := <options>;                   \\ the first.
  51 4 (u32-be Seconds) (require (<options> (options.lease-> O Seconds)) "malformed options") := <options>;
  58 4 (u32-be Seconds) (require (<options> (options.renew-> O Seconds)) "malformed options") := <options>;
  59 4 (u32-be Seconds) (require (<options> (options.rebind-> O Seconds)) "malformed options") := <options>;
  _ Length (skip Length) (require (<options> O) "malformed options") := <options>;          \\ Others.
  <end> := false;)

(grammar.finish)

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
      (cases (and (= Phase selecting) (= Kind (offer-message)) (net-ipv4.unicast? IP) (net-ipv4.unicast? Server))
               (do (client.address-> C IP) (client.server-> C Server) (begin C requesting Now))
             (and (= Phase requesting) (= Kind (ack-message)) Match (= IP (client.address C)))
               (commit-lease C O IP Now)
             (and (or (= Phase renewing) (= Phase rebinding)) (= Kind (ack-message)) Match
                  (or (= IP 0) (= IP (client.address C))))
               (commit-lease C O (client.address C) Now)
             (and Match (= Kind (nak-message)) (not (= Phase selecting)))
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
    (and (fx> N (wire.dhcp.size))                           \\ At least the end option.
         (= (wire.dhcp.op B I) 2)                              \\ A reply,
         (= (wire.dhcp.hardware-type B I) 1) (= (wire.dhcp.hardware-length B I) 6)   \\ over Ethernet,
         (= (wire.dhcp.transaction-id B I) (client.id C))
         (= (wire.dhcp.client-hardware B I) (client.mac C))   \\ to us.
         (= (wire.dhcp.magic-cookie B I) (cookie))
         (let O (reset-options (client.options C))
           (and (<options>.parse-at O (client.option-state C) B (fx+ I (wire.dhcp.size)) (fx+ I N) (/. At Message false))
                (accept-options C O (wire.dhcp.your-address B I) Now)))))

(define init-input
  {client --> net-link.ring --> fixnum --> fixnum --> boolean}
  _ _ _ 0 -> false
  C R Now Left ->
    (and (net-link.ready? R Now)
         (let B (net-link.ring.data R)
              At (net-link.head-offset R)
              N (net-link.head-length R)
              T (fx+ At (wire.ipv4.size))
              Headers (fx+ (wire.ipv4.size) (wire.udp.size))
              OK (and (udp.valid-datagram? B At N)
                      (= (wire.udp.source-port B T) (server-port)) (= (wire.udp.destination-port B T) (client-port))
                      (accept C B (fx+ At Headers) (fx- N Headers) Now))
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
             (and (= (udp.recv-info.port Info) (server-port)) (accept C B 0 (udp.recv-info.length Info) Now)) true
             true (bound-input C Inbox Now (fx- Left 1)))))

(define clear
  {buffer.view --> fixnum --> buffer.view}
  B I -> (if (= I (message-size)) B (clear (buffer.u32-be-> B I 0) (fx+ I 4))))

(define write-payload
  {client --> boolean --> boolean --> buffer.view}
  C Configured Broadcast ->
    (let B (clear (client.out C) 0)
         State (client.state C)
      (do (write-layout wire.dhcp B 0
            (op 1) (hardware-type 1) (hardware-length 6)          \\ A request, over Ethernet.
            (transaction-id (client.id C))
            (broadcast (if Broadcast 1 0))
            (client-address (if Configured (client.address C) 0))
            (client-hardware (client.mac C))
            (magic-cookie (cookie)))
          (write-layout wire.dhcp-request-options B (wire.dhcp.size)
            (type-code 53) (type-length 1)
            (message-type (if (= State selecting) (discover-message) (request-message)))
            (list-code 55) (list-length 6) (mask 1) (router 3) (dns 6) (lease 51) (renewal 58) (rebinding 59))
          (let At (fx+ (wire.dhcp.size) (wire.dhcp-request-options.size))
            (if (= State requesting)
                (let Server (fx+ At (wire.dhcp-address-option.size))
                  (do (write-layout wire.dhcp-address-option B At (code 50) (length 4) (address (client.address C)))
                      (write-layout wire.dhcp-address-option B Server (code 54) (length 4) (address (client.server C)))
                      (buffer.u8-> B (fx+ Server (wire.dhcp-address-option.size)) (end-option))))
                (buffer.u8-> B At (end-option)))))))

(define transmit
  {client --> fixnum --> boolean}
  C Now ->
    (let D (client.device C)
         Tx (net-link.device.tx D)
         State (client.state C)
         Configured (or (= State renewing) (= State rebinding))
         Broadcast (not (= State renewing))
         Attempts (client.attempts C)
         Delay (shen-jit.shift-left 1000 (if (fx< Attempts 5) Attempts (fixnum 5)))
         Deadline (fx+ Now Delay)
      (if (net-link.full? Tx) false
          (do (udp.write-packet (net-link.ring.data Tx) (net-link.tail-offset Tx)
                                (if Configured (client.address C) 0) (client-port)
                                (if Broadcast (net-ipv4.broadcast) (client.server C)) (server-port)
                                (write-payload C Configured Broadcast) 0 (message-size))
              (net-link.publish Tx (fx+ (message-size) (fx+ (wire.ipv4.size) (wire.udp.size)))
                                (net-link.delivery D Now))
              (client.attempts-> C (fx+ Attempts 1))
              (client.deadline-> C
                (cases (and (= State renewing) (fx> Deadline (client.rebinding C))) (client.rebinding C)
                       (and (= State rebinding) (fx> Deadline (client.expires C))) (client.expires C)
                       true Deadline))
              true))))

(define drive
  {client --> fixnum --> state}
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
  {client --> fixnum --> state}
  C Budget ->
    (let D (client.device C)
         Now (net-link.now D)
         State (client.state C)
      (if (or (= State selecting) (= State requesting))
          (do (init-input C (net-link.device.rx D) Now (buffer.index Budget)) (drive C Now))
          State)))

(define maintain
  {client --> udp.inbox --> fixnum --> state}
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
