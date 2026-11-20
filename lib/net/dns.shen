\\ One bounded UDP A lookup, with compression-safe decoding and CNAME following.
(shen.x.namespace net-dns
  (use buffer)
  (use udp)
  (use net-ipv4)
  (use shen-jit)
  (use net-wire => wire)
  (use grammar)
  (import struct defstruct)
  (import layout write-layout)
  (externals [defgrammar skip])
  (export resolver make start poll
          resolver.state resolver.ip resolver.ttl resolver.deadline
          idle pending resolved not-found failed state)

\\ A resolver is idle, waits for an answer, or has one: an address, none, or a failure.
(datatype states
  if (element? State [idle pending resolved not-found failed])
  ____________________________________________________________
  State : state;)

(defstruct resolver
  (socket : udp.inbox)
  (query : buffer.view)
  (reply : buffer.view)
  (info : udp.recv-info)
  (mutable server : fixnum)
  (mutable id : fixnum)
  (mutable query-length : fixnum)
  (mutable state : state)
  (mutable ip : fixnum)
  (mutable ttl : fixnum)
  (mutable deadline : fixnum)
  (mutable attempts : fixnum)
  (names : grammar.state))

(define make
  {udp.inbox --> fixnum --> resolver}
  Socket ReceiveBytes ->
    (if (and (fx>= ReceiveBytes 512) (fx<= ReceiveBytes 65507))
        (:resolver
          socket <- Socket
          query <- (buffer.new 271)
          reply <- (buffer.new ReceiveBytes)
          info <- (udp.make-recv-info)
          names <- (grammar.state)
          server <- 0
          id <- 0
          query-length <- 0
          state <- idle
          ip <- 0
          ttl <- 0
          deadline <- -1
          attempts <- 0)
        (error "net/dns: receive buffer must be in 512..65507 bytes")))

\\ A name's bytes, RFC 1035 4.1.4: labels, each a length of at most 63 and its bytes, to the empty label,
\\ or, where compression is allowed, to a pointer, two bytes whose first has its top two bits set.
(defgrammar (<name> Compressed) {boolean ==> fixnum}
  0 := 0;
  Head (where (and Compressed (fx>= Head 192))) _ := 0;
  Length (where (fx<= Length 63)) (skip Length) (<name> Compressed) := 0;)

(grammar.finish)

\\ Where the name at I ends, before End, or -1.
\\ RFC 1035 3.2.2, 3.2.4 and 4.1.1: the record types read here, the class, the codes of an answer, and
\\ the port.
(define a-type {--> fixnum} -> 1)
(define cname-type {--> fixnum} -> 5)
(define internet {--> fixnum} -> 1)
(define no-error {--> fixnum} -> 0)
(define name-error {--> fixnum} -> 3)
(define dns-port {--> fixnum} -> 53)

(define after-name
  {grammar.state --> buffer.view --> fixnum --> fixnum --> boolean --> fixnum}
  S B I End Compressed -> (<name>.end-at Compressed S B I End))

(define start
  {resolver --> fixnum --> fixnum --> buffer.view --> fixnum --> boolean}
  R Server Id Name Now ->
    (let N (buffer.length Name)
         Q (resolver.query R)
      (if (and (not (= (resolver.state R) pending)) (net-ipv4.unicast? Server)
               (fx>= Id 0) (fx<= Id 65535) (fx>= N 1) (fx<= N 255)
               (= (after-name (resolver.names R) Name 0 N false) N))
          (do (write-layout wire.dns Q 0 (id Id) (recursion-desired 1) (questions 1))
              (buffer.copy-into! Q (wire.dns.size) Name 0 N)
              (write-layout wire.dns-question Q (fx+ (wire.dns.size) N) (type (a-type)) (class (internet)))
              (resolver.server-> R Server)
              (resolver.id-> R Id)
              (resolver.query-length-> R (fx+ N (fx+ (wire.dns.size) (wire.dns-question.size))))
              (resolver.ip-> R 0)
              (resolver.ttl-> R 0)
              (resolver.attempts-> R 0)
              (resolver.deadline-> R Now)
              (resolver.state-> R pending)
              true)
          false)))

(define fold-ascii
  {fixnum --> fixnum}
  C -> (if (and (fx>= C 65) (fx<= C 90)) (fx+ C 32) C))

(define equal-label?
  {buffer.view --> fixnum --> buffer.view --> fixnum --> fixnum --> boolean}
  _ _ _ _ 0 -> true
  A I B J N ->
    (and (= (fold-ascii (buffer.u8 A I)) (fold-ascii (buffer.u8 B J)))
         (equal-label? A (fx+ I 1) B (fx+ J 1) (fx- N 1))))

(define label-offset
  {buffer.view --> fixnum --> fixnum --> fixnum --> fixnum}
  B At End Left ->
    (if (or (fx< At 0) (fx>= At End) (= Left 0)) -1
        (let Head (buffer.u8 B At)
          (cases (fx<= Head 63) At
                 (and (= (wire.dns-pointer.marker B At) 3) (fx< (fx+ At 1) End))
                   (let Target (wire.dns-pointer.offset B At)
                     (if (fx< Target At) (label-offset B Target End (fx- Left 1)) (fixnum -1)))
                 true -1))))

(define name-equal?
  {buffer.view --> fixnum --> fixnum --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  A I EndA B J EndB Left ->
    (let X (label-offset A I EndA 32)
         Y (label-offset B J EndB 32)
      (and (fx>= X 0) (fx>= Y 0)
           (let N (buffer.u8 A X)
                StartA (fx+ X 1)
                StartB (fx+ Y 1)
                NextA (fx+ StartA N)
                NextB (fx+ StartB N)
             (and (= N (buffer.u8 B Y)) (fx<= NextA EndA) (fx<= NextB EndB)
                  (fx<= N Left)
                  (or (= N 0)
                      (and (equal-label? A StartA B StartB N)
                           (name-equal? A NextA EndA B NextB EndB (fx- (fx- Left N) 1)))))))))

(define finish
  {resolver --> state --> state}
  R State -> (do (resolver.state-> R State) (resolver.deadline-> R -1) State))

\\ Return an A record or the first well-formed CNAME for the current owner.
(define find-answer
  {grammar.state --> buffer.view --> fixnum --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum}
  _ _ _ _ _ _ _ 0 -> -1
  S Name Owner B N I EndName Count ->
    (let Fields (after-name S B I N true)
      (if (or (fx< Fields 0) (fx> (fx+ Fields (wire.dns-record.size)) N)) -1
          (let Data (fx+ Fields (wire.dns-record.size))
               Size (wire.dns-record.length B Fields)
               Next (fx+ Data Size)
               Kind (wire.dns-record.type B Fields)
            (cases (fx> Next N) -1
                   (and (= (wire.dns-record.class B Fields) (internet))
                        (or (and (= Kind (a-type)) (= Size (wire.ipv4-address.size)))
                            (and (= Kind (cname-type)) (fx> Size 0) (= (after-name S B Data Next true) Next)))
                        (name-equal? Name Owner EndName B I N 255))
                     Fields
                   true (find-answer S Name Owner B N Next EndName (fx- Count 1)))))))

(define resolve-answer
  {resolver --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  _ _ _ _ _ _ _ 0 -> false
  R Name Owner EndName N Start Ttl Left ->
    (let B (resolver.reply R)
         Fields (find-answer (resolver.names R) Name Owner B N Start EndName (wire.dns.answers B 0))
      (if (fx< Fields 0) false
          (let Data (fx+ Fields (wire.dns-record.size))
               Lifetime (wire.dns-record.ttl B Fields)
               Min (if (fx< Lifetime Ttl) Lifetime Ttl)
            (if (= (wire.dns-record.type B Fields) (a-type))
                (do (resolver.ip-> R (wire.ipv4-address.address B Data))
                    (resolver.ttl-> R Min)
                    (finish R resolved)
                    true)
                (resolve-answer R B Data N N Start Min (fx- Left 1)))))))

(define accept
  {resolver --> fixnum --> boolean}
  R N ->
    (let B (resolver.reply R)
      (and (fx>= N (wire.dns.size)) (= (wire.dns.id B 0) (resolver.id R))
           (= (wire.dns.response B 0) 1) (= (wire.dns.opcode B 0) 0)      \\ An answer to a query,
           (= (wire.dns.questions B 0) 1)                                  \\ to one question.
           (let Q (resolver.query R)
                Stop (after-name (resolver.names R) B (wire.dns.size) N true)
                Rcode (wire.dns.rcode B 0)
             (and (fx>= Stop 0) (fx<= (fx+ Stop (wire.dns-question.size)) N)
                  (= (wire.dns-question.type B Stop) (a-type)) (= (wire.dns-question.class B Stop) (internet))
                  (name-equal? Q (wire.dns.size) (resolver.query-length R) B (wire.dns.size) N 255)
                  (cases (or (= (wire.dns.truncated B 0) 1)
                             (and (not (= Rcode (no-error))) (not (= Rcode (name-error)))))
                           (= (finish R failed) failed)
                         (= Rcode (name-error)) (= (finish R not-found) not-found)
                         true (or (resolve-answer R Q (wire.dns.size) (resolver.query-length R)
                                                  N (fx+ Stop (wire.dns-question.size)) 4294967295 9)
                                  (= (finish R not-found) not-found))))))))

(define receive-reply
  {resolver --> fixnum --> boolean}
  _ 0 -> false
  R Left ->
    (let S (resolver.socket R)
         Info (resolver.info R)
         Status (udp.inbox-recv-into S (resolver.reply R) Info)
      (cases (= Status udp.empty) false
             (= Status udp.too-small) (do (udp.inbox-discard S) (receive-reply R (fx- Left 1)))
             (and (= (udp.recv-info.source Info) (resolver.server R))
                  (= (udp.recv-info.port Info) (dns-port))
                  (accept R (udp.recv-info.length Info))) true
             true (receive-reply R (fx- Left 1)))))

(define poll
  {resolver --> fixnum --> state}
  R Now ->
    (cases (not (= (resolver.state R) pending)) (resolver.state R)
           (receive-reply R 4) (resolver.state R)
           (fx< Now (resolver.deadline R)) pending
           (= (resolver.attempts R) 4) (finish R failed)
           true (let Status (udp.send (udp.inbox.peer (resolver.socket R)) (resolver.server R) (dns-port)
                                       (resolver.query R) (resolver.query-length R))
                  (cases (= Status udp.sent)
                           (let N (resolver.attempts R)
                             (do (resolver.deadline-> R (fx+ Now (shen-jit.shift-left 1000 N)))
                                 (resolver.attempts-> R (fx+ N 1))
                                 pending))
                         (= Status udp.would-block) pending
                         true (finish R failed)))))

(preclude [resolver.%match])
)
