\\ IPv6 neighbor discovery and one autonomous /64 prefix per link.
(shen.x.namespace net-ndp
  (use buffer)
  (use net-link)
  (use net-ipv6)
  (use shen-jit)
  (use net-wire => wire)
  (use grammar)
  (import struct defstruct)
  (import layout write-layout)
  (externals [defgrammar <end> skip u16-be u32-be])
  (export host make configure-static poll ingress ingress-at multicast-at? next-deadline
          host.device host.link-local host.global host.local-state host.global-state
          host.preferred-until host.valid-until host.router host.router-until
          tentative usable duplicate absent local-ready? global-ready? source-address
          neighbor neighbor.mac neighbor.pending neighbor-at neighbor-ready? host.slots host.mac route)

(defstruct neighbor
  (ip : net-ipv6.address)
  (pending : net-link.ring)
  (mutable mac : fixnum)
  (mutable expires : fixnum)
  (mutable probe-at : fixnum))

(defstruct host
  (device : net-link.device)
  (mac : fixnum)
  (link-local : net-ipv6.address)
  (global : net-ipv6.address)
  (prefix : net-ipv6.address)
  (router : net-ipv6.address)
  (unspecified : net-ipv6.address)
  (all-nodes : net-ipv6.address)
  (all-routers : net-ipv6.address)
  (group : net-ipv6.address)
  (source : net-ipv6.address)
  (destination : net-ipv6.address)
  (target : net-ipv6.address)
  (hop : net-ipv6.address)
  (neighbors : (vector neighbor))
  (slots : fixnum)
  (mutable local-state : symbol)
  (mutable global-state : symbol)
  (mutable local-at : fixnum)
  (mutable global-at : fixnum)
  (mutable static : boolean)
  (mutable rs-at : fixnum)
  (mutable rs-left : fixnum)
  (mutable prefix-until : fixnum)
  (mutable router-until : fixnum)
  (mutable preferred-until : fixnum)
  (mutable valid-until : fixnum)
  (option-state : grammar.state)
  (mutable source-link : fixnum)                   \\ The options' first link-layer addresses, or -1.
  (mutable target-link : fixnum))

(define blank-address
  {--> net-ipv6.address}
  -> (net-ipv6.make-address 0 0 0 0))

(define init-neighbors
  {(vector neighbor) --> fixnum --> fixnum --> (vector neighbor)}
  V 0 _ -> V
  V I Mtu ->
    (let N (:neighbor
              ip <- (blank-address)
              pending <- (net-link.make-ring 4 Mtu)
              mac <- 0
              expires <- 0
              probe-at <- 0)
      (init-neighbors (fxvector-> V I N) (fx- I 1) Mtu)))

(define make
  {net-link.device --> fixnum --> fixnum --> fixnum --> fixnum --> host}
  D Mac IdHigh IdLow Slots ->
    (let Mtu (net-link.mtu D)
      (if (and (fx>= Mtu 1280) (fx>= Slots 0) (fx<= Slots 256)
               (fx>= Mac 0) (fx<= Mac 281474976710655)
               (= (shen-jit.bit-and Mac 1099511627776) 0)
               (or (= Mac 0) (fx> Slots 0))
               (not (and (= IdHigh 0) (= IdLow 0))))
          (:host
            option-state <- (grammar.state)
            source-link <- -1
            target-link <- -1
            device <- D
            mac <- Mac
            link-local <- (net-ipv6.make-address 4269801472 0 IdHigh IdLow)
            global <- (blank-address)
            prefix <- (blank-address)
            router <- (blank-address)
            unspecified <- (blank-address)
            all-nodes <- (net-ipv6.make-address 4278321152 0 0 1)
            all-routers <- (net-ipv6.make-address 4278321152 0 0 2)
            group <- (blank-address)
            source <- (blank-address)
            destination <- (blank-address)
            target <- (blank-address)
            hop <- (blank-address)
            neighbors <- (init-neighbors (vector (fx->number Slots)) Slots Mtu)
            slots <- Slots
            local-state <- tentative
            global-state <- absent
            local-at <- -1
            global-at <- -1
            static <- false
            rs-at <- 0
            rs-left <- 3
            prefix-until <- 0
            router-until <- 0
            preferred-until <- 0
            valid-until <- 0)
          (error "IPv6: invalid interface identifier, MAC, neighbor capacity, or link MTU"))))

(define configure-static
  {host --> net-ipv6.address --> boolean}
  H Address ->
    (if (and (net-ipv6.unicast? Address) (not (net-ipv6.link-local? Address)))
        (do (net-ipv6.copy-address (host.global H) Address)
            (host.global-state-> H tentative)
            (host.global-at-> H -1)
            (host.static-> H true)
            (host.rs-left-> H 0)
            true)
        (error "IPv6: need a non-link-local unicast address")))

(define local-ready?
  {host --> boolean}
  H -> (= (host.local-state H) usable))

(define global-ready?
  {host --> fixnum --> boolean}
  H Now -> (and (not (= (host.local-state H) duplicate))
                (= (host.global-state H) usable) (or (host.static H) (fx< Now (host.valid-until H)))))

(define source-address
  {host --> net-ipv6.address --> fixnum --> net-ipv6.address}
  H Destination Now ->
    (cases (net-ipv6.link-local? Destination)
             (if (local-ready? H) (host.link-local H) (host.unspecified H))
           (global-ready? H Now) (host.global H)
           true (host.unspecified H)))

(define neighbor-at
  {host --> fixnum --> neighbor}
  H I -> (fx<-vector (host.neighbors H) I))

(define neighbor-ready?
  {neighbor --> fixnum --> boolean}
  N Now -> (and (fx> (neighbor.mac N) 0) (fx< Now (neighbor.expires N))
                (net-link.ready? (neighbor.pending N) 0)))

(define find
  {host --> net-ipv6.address --> fixnum --> fixnum}
  _ _ 0 -> 0
  H IP I -> (if (net-ipv6.same? IP (neighbor.ip (neighbor-at H I))) I (find H IP (fx- I 1))))

(define free-queue
  {net-link.ring --> boolean}
  R -> (if (net-link.ready? R 0) (do (net-link.consume R) (free-queue R)) true))

(define find-available
  {host --> fixnum --> fixnum --> fixnum --> fixnum}
  _ _ 0 Best -> Best
  H Now I Best ->
    (let N (neighbor-at H I)
      (cases (fx<= (neighbor.expires N) Now) I
             (and (fx> (neighbor.mac N) 0) (not (net-link.ready? (neighbor.pending N) 0))
                  (or (= Best 0) (fx< (neighbor.expires N) (neighbor.expires (neighbor-at H Best)))))
               (find-available H Now (fx- I 1) I)
             true (find-available H Now (fx- I 1) Best))))

(define claim
  {host --> net-ipv6.address --> fixnum --> fixnum}
  H IP Now ->
    (let Old (find H IP (host.slots H))
         Index (if (= Old 0) (find-available H Now (host.slots H) 0) Old)
      (if (= Index 0) 0
          (let N (neighbor-at H Index)
            (do (if (or (= Old 0) (fx<= (neighbor.expires N) Now))
                    (do (free-queue (neighbor.pending N))
                        (net-ipv6.copy-address (neighbor.ip N) IP)
                        (neighbor.mac-> N 0)
                        (neighbor.expires-> N (fx+ Now 3000))
                        (neighbor.probe-at-> N Now)
                        true)
                    true)
                Index)))))

(define same-prefix?
  {net-ipv6.address --> net-ipv6.address --> boolean}
  A B -> (and (= (net-ipv6.address.a A) (net-ipv6.address.a B))
              (= (net-ipv6.address.b A) (net-ipv6.address.b B))))

(define route
  {host --> buffer.view --> fixnum --> fixnum --> fixnum}
  H B I Now ->
    (let IP (net-ipv6.read-address (host.hop H) B I)
      (cases (not (net-ipv6.unicast? IP)) 0
             (or (net-ipv6.link-local? IP)
                 (and (host.static H) (same-prefix? IP (host.global H)))
                 (and (fx< Now (host.prefix-until H)) (same-prefix? IP (host.prefix H))))
               (claim H IP Now)
             (fx< Now (host.router-until H)) (claim H (host.router H) Now)
             true 0)))

(define valid-mac?
  {fixnum --> boolean}
  Mac -> (and (fx> Mac 0) (= (shen-jit.bit-and Mac 1099511627776) 0)))

(define write-option
  {buffer.view --> fixnum --> fixnum --> fixnum --> buffer.view}
  B I Kind Mac -> (write-layout wire.ndp-link-address B I (type Kind) (length 1) (address Mac)))

\\ Neighbor discovery's options, RFC 4861 4.6: a type and a length in 8-byte units, never 0, that covers
\\ both, to the end. A source (1) or target (2) link-layer address takes one unit, and the first of each
\\ is stored in H as it is matched.
(defgrammar (<options> H) {host ==> boolean}
  <end> := true;
  1 1 (u16-be High) (u32-be Low) (<options> (source-link H (link-address High Low))) := <options>;
  2 1 (u16-be High) (u32-be Low) (<options> (target-link H (link-address High Low))) := <options>;
  Kind Units (where (and (fx> Units 0) (not (= Kind 1)) (not (= Kind 2))))
    (skip (fx- (fx* 8 Units) 2)) (<options> H) := <options>;)

(grammar.finish)

(define link-address
  {fixnum --> fixnum --> fixnum}
  High Low -> (fx+ (shen-jit.shift-left High 32) Low))

(define source-link
  {host --> fixnum --> host}
  H Mac -> (if (fx< (host.source-link H) 0) (host.source-link-> H Mac) H))

(define target-link
  {host --> fixnum --> host}
  H Mac -> (if (fx< (host.target-link H) 0) (host.target-link-> H Mac) H))

(define options-valid?
  {host --> buffer.view --> fixnum --> fixnum --> boolean}
  H B At End -> (do (host.source-link-> H -1)
                    (host.target-link-> H -1)
                    (<options>.parse-at H (host.option-state H) B At End (/. Position Message false))))

\\ A link-layer address the options gave, if it is a unicast one, or 0.
(define link-mac
  {fixnum --> fixnum}
  Mac -> (if (valid-mac? Mac) Mac 0))

(define set-neighbor
  {neighbor --> fixnum --> fixnum --> boolean}
  N Mac Now ->
    (do (neighbor.mac-> N Mac)
        (neighbor.expires-> N (fx+ Now 30000))
        true))

(define learn
  {host --> net-ipv6.address --> fixnum --> fixnum --> boolean}
  H IP Mac Now ->
    (and (valid-mac? Mac)
         (let I (claim H IP Now)
           (and (fx> I 0) (set-neighbor (neighbor-at H I) Mac Now)))))

(define advertise-neighbor
  {host --> net-ipv6.address --> fixnum --> fixnum --> fixnum --> boolean}
  H IP Mac Override Now ->
    (and (valid-mac? Mac)
         (let I (find H IP (host.slots H))
           (and (fx> I 0)
                (let N (neighbor-at H I)
                     Old (neighbor.mac N)
                  (and (or (= Old 0) (= Old Mac)
                           (= Override 1))
                       (set-neighbor N Mac Now)))))))

(define emit
  {host --> net-ipv6.address --> net-ipv6.address --> net-ipv6.address -->
   fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  H Source Destination Target Kind Solicited Override Now ->
    (let D (host.device H)
         Tx (net-link.device.tx D)
         Mac (host.mac H)
      (if (net-link.full? Tx) false
          (let B (net-link.ring.data Tx)
               At (net-link.tail-offset Tx)
               Body (fx+ At (wire.ipv6.size))
               Base (cases (= Kind 133) (wire.ndp-router-solicitation.size)
                           (= Kind 135) (wire.ndp-neighbor-solicitation.size)
                           true (wire.ndp-neighbor-advertisement.size))
               IncludeMac (and (fx> Mac 0) (not (net-ipv6.unspecified? Source)))
               N (if IncludeMac (fx+ Base (wire.ndp-link-address.size)) Base)
               Count (fx+ N (wire.ipv6.size))
            (do (net-ipv6.write-header B At Count 58 255 Source Destination)
                (cases (= Kind 133) (write-layout wire.ndp-router-solicitation B Body (type 133))
                       (= Kind 135) (do (write-layout wire.ndp-neighbor-solicitation B Body (type 135))
                                        (net-ipv6.write-address B (wire.ndp-neighbor-solicitation.target-at Body) Target))
                       true (do (write-layout wire.ndp-neighbor-advertisement B Body
                                  (type 136) (solicited Solicited) (override Override))
                                (net-ipv6.write-address B (wire.ndp-neighbor-advertisement.target-at Body) Target)))
                (if IncludeMac (write-option B (fx+ Body Base) (if (= Kind 136) 2 1) Mac) B)   \\ Target or source address.
                (wire.icmp.checksum-> B Body (net-ipv6.transport-checksum B At 58 N))
                (net-link.publish Tx Count (net-link.delivery D Now)))))))

(define duplicate-if-probing
  {host --> net-ipv6.address --> boolean}
  H Target ->
    (cases (and (= (host.local-state H) tentative) (net-ipv6.same? Target (host.link-local H)))
             (do (host.local-state-> H duplicate) true)
           (and (= (host.global-state H) tentative) (net-ipv6.same? Target (host.global H)))
             (do (host.global-state-> H duplicate) true)
           true false))

(define local-target?
  {host --> net-ipv6.address --> fixnum --> boolean}
  H Target Now ->
    (or (and (local-ready? H) (net-ipv6.same? Target (host.link-local H)))
        (and (global-ready? H Now) (net-ipv6.same? Target (host.global H)))))

(define neighbor-solicitation
  {host --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  H B Body End Now ->
    (let Source (host.source H)
         Destination (host.destination H)
         Target (net-ipv6.read-address (host.target H) B (wire.ndp-neighbor-solicitation.target-at Body))
         Opt (fx+ Body (wire.ndp-neighbor-solicitation.size))
         Dad (net-ipv6.unspecified? Source)
      (and (net-ipv6.unicast? Target)
           (options-valid? H B Opt End)
           (if Dad
               (and (net-ipv6.solicited-node? Destination Target)
                    (fx< (host.source-link H) 0))
               (and (net-ipv6.unicast? Source)
                    (or (net-ipv6.same? Destination Target)
                        (net-ipv6.solicited-node? Destination Target))))
           (or (and Dad (duplicate-if-probing H Target))
               (and (local-target? H Target Now)
                    (do (if Dad false (learn H Source (link-mac (host.source-link H)) Now))
                        (if Dad (emit H Target (host.all-nodes H) Target 136 0 1 Now)     \\ Override,
                            (emit H Target Source Target 136 1 1 Now))))))))           \\ and solicited.

(define neighbor-advertisement
  {host --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  H B Body End Now ->
    (let Source (host.source H)
         Target (net-ipv6.read-address (host.target H) B (wire.ndp-neighbor-advertisement.target-at Body))
         Solicited (wire.ndp-neighbor-advertisement.solicited B Body)
         Opt (fx+ Body (wire.ndp-neighbor-advertisement.size))
      (and (net-ipv6.unicast? Source) (net-ipv6.unicast? Target)
           (or (local-target? H (host.destination H) Now)
               (and (net-ipv6.same? (host.destination H) (host.all-nodes H))
                    (= Solicited 0))
               (and (= (host.local-state H) tentative)
                    (net-ipv6.same? (host.destination H) (host.link-local H)))
               (and (= (host.global-state H) tentative)
                    (net-ipv6.same? (host.destination H) (host.global H))))
           (options-valid? H B Opt End)
           (or (duplicate-if-probing H Target)
               (advertise-neighbor H Target (link-mac (host.target-link H))
                                   (wire.ndp-neighbor-advertisement.override B Body) Now)))))

\\ Apply the unauthenticated-advertisement lifetime rule from RFC 4862.
(define refreshed-valid
  {fixnum --> fixnum --> fixnum --> fixnum}
  Old New Now ->
    (cases (or (fx> New 7200000) (fx> (fx+ Now New) Old)) (fx+ Now New)
           (fx<= Old (fx+ Now 7200000)) Old
           true (fx+ Now 7200000)))

(define set-prefix
  {host --> buffer.view --> fixnum --> fixnum --> boolean}
  H B At Now ->
    (let P (net-ipv6.read-address (host.target H) B (wire.ndp-prefix.prefix-at At))
         Valid (fx* (wire.ndp-prefix.valid-lifetime B At) 1000)            \\ In milliseconds.
         Preferred (fx* (wire.ndp-prefix.preferred-lifetime B At) 1000)
         Global (host.global H)
         Known (same-prefix? Global P)
         CanReplace (or (= (host.global-state H) absent) (fx<= (host.valid-until H) Now))
      (if (and (= (wire.ndp-prefix.prefix-length B At) 64)
               (net-ipv6.unicast? P) (not (net-ipv6.link-local? P)))
          (do (if (and (= (wire.ndp-prefix.on-link B At) 1)
                       (or (fx<= (host.prefix-until H) Now) (same-prefix? P (host.prefix H))))
                  (do (net-ipv6.copy-address (host.prefix H) P)
                      (host.prefix-until-> H (fx+ Now Valid))
                      true)
                  false)
              (if (and (not (host.static H)) (not (= (host.local-state H) duplicate))
                       (= (wire.ndp-prefix.autonomous B At) 1)
                       (fx<= Preferred Valid) (or (and CanReplace (fx> Valid 0)) Known))
                  (let Until (if CanReplace (fx+ Now Valid) (refreshed-valid (host.valid-until H) Valid Now))
                       Expires (fx+ Now Preferred)
                    (do (if CanReplace
                            (do (net-ipv6.compose-prefix Global P (host.link-local H))
                                (host.global-state-> H tentative)
                                (host.global-at-> H -1)
                                true)
                            true)
                        (host.valid-until-> H Until)
                        (host.preferred-until-> H (if (fx< Expires Until) Expires Until))
                        true))
                  false))
          false)))

(define prefixes
  {host --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  H B I End Now ->
    (if (= I End) true
        (let Bytes (fx* 8 (wire.ndp-option.length B I))
          (do (if (and (= (wire.ndp-option.type B I) 3) (= Bytes (wire.ndp-prefix.size)))   \\ Prefix information.
                  (set-prefix H B I Now)
                  false)
              (prefixes H B (fx+ I Bytes) End Now)))))

(define router-advertisement
  {host --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  H B Body End Now ->
    (let Source (host.source H)
         Destination (host.destination H)
         Opt (fx+ Body (wire.ndp-router-advertisement.size))
         Span (fx* (wire.ndp-router-advertisement.router-lifetime B Body) 1000)
      (and (net-ipv6.link-local? Source)
           (or (net-ipv6.same? Destination (host.all-nodes H)) (local-target? H Destination Now))
           (options-valid? H B Opt End)
           (do (if (or (net-ipv6.same? Source (host.router H)) (fx<= (host.router-until H) Now))
                   (do (net-ipv6.copy-address (host.router H) Source)
                       (host.router-until-> H (fx+ Now Span))
                       (learn H Source (link-mac (host.source-link H)) Now))
                   false)
               (prefixes H B Opt End Now)
               (if (or (fx> (host.router-until H) Now) (fx> (host.valid-until H) Now))
                   (host.rs-left-> H 0) H)
               true))))

(define multicast-at?
  {host --> buffer.view --> fixnum --> fixnum --> boolean}
  H B At Now ->
    (and (= (buffer.u8 B At) 255)
         (let Group (net-ipv6.read-address (host.destination H) B At)
           (or (net-ipv6.same? Group (host.all-nodes H))
               (and (not (= (host.local-state H) duplicate))
                    (net-ipv6.solicited-node? Group (host.link-local H)))
               (and (or (= (host.global-state H) tentative) (global-ready? H Now))
                    (net-ipv6.solicited-node? Group (host.global H)))))))

(define ingress
  {host --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  H B I N Now -> (and (fx>= N (fx+ (wire.ipv6.size) (wire.icmp.size))) (= (wire.ipv6.next-header B I) 58)
                      (ingress-at H B I N (fx+ I (wire.ipv6.size)) Now)))

\\ A message at Body, after the base header and any extension headers.
(define ingress-at
  {host --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  H B I N Body Now ->
    (let End (fx+ I N)
         Message (fx- End Body)
      (and (fx>= Body (fx+ I (wire.ipv6.size))) (fx>= Message (wire.icmp.size))
           (net-ipv6.valid-header? B I N)
           (= (wire.ipv6.hop-limit B I) 255)                    \\ From this link only.
           (= (wire.icmp.code B Body) 0)
           (let Kind (wire.icmp.type B Body)
             (and (cases (= Kind 134) (fx>= Message (wire.ndp-router-advertisement.size))
                         (= Kind 135) (fx>= Message (wire.ndp-neighbor-solicitation.size))
                         (= Kind 136) (fx>= Message (wire.ndp-neighbor-advertisement.size))
                         true false)
                  (= (net-ipv6.transport-checksum-at B I Body 58 Message) 0)
                  (do (net-ipv6.read-address (host.source H) B (wire.ipv6.source-at I))
                      (net-ipv6.read-address (host.destination H) B (wire.ipv6.destination-at I))
                      (cases (= Kind 134) (router-advertisement H B Body End Now)
                             (= Kind 135) (neighbor-solicitation H B Body End Now)
                             true (neighbor-advertisement H B Body End Now))))))))

(define drive-dad
  {host --> net-ipv6.address --> fixnum --> fixnum --> fixnum}
  H Address At Now ->
    (if (fx< At 0)
        (if (emit H (host.unspecified H) (net-ipv6.solicited-node (host.group H) Address)
                  Address 135 0 0 Now)
            (fx+ Now 1000) At)
        At))

(define dad
  {host --> fixnum --> boolean}
  H Now ->
    (do (if (= (host.local-state H) tentative)
            (let At (host.local-at H)
              (if (and (fx>= At 0) (fx>= Now At))
                  (host.local-state-> H usable)
                  (host.local-at-> H (drive-dad H (host.link-local H) At Now))))
            H)
        (if (and (not (host.static H)) (not (= (host.global-state H) absent))
                 (fx>= Now (host.valid-until H)))
            (host.global-state-> H absent)
            (if (= (host.global-state H) tentative)
                (let At (host.global-at H)
                  (if (and (fx>= At 0) (fx>= Now At))
                      (host.global-state-> H usable)
                      (host.global-at-> H (drive-dad H (host.global H) At Now))))
                H))
        true))

(define neighbor-probes
  {host --> fixnum --> fixnum --> boolean}
  _ 0 _ -> true
  H I Now ->
    (let N (neighbor-at H I)
         Q (neighbor.pending N)
         Address (neighbor.ip N)
      (do (if (net-link.ready? Q 0)
              (cases (fx<= (neighbor.expires N) Now) (free-queue Q)
                     (and (= (neighbor.mac N) 0) (fx<= (neighbor.probe-at N) Now) (local-ready? H))
                       (and (emit H (host.link-local H)
                                  (net-ipv6.solicited-node (host.group H) Address) Address 135 0 0 Now)
                            (do (neighbor.probe-at-> N (fx+ Now 1000)) true))
                     true false)
              false)
          (neighbor-probes H (fx- I 1) Now))))

(define poll
  {host --> fixnum --> boolean}
  H Now ->
    (do (dad H Now)
        (if (and (fx> (host.rs-left H) 0) (local-ready? H) (fx>= Now (host.rs-at H))
                 (emit H (host.link-local H) (host.all-routers H) (host.unspecified H) 133 0 0 Now))
            (do (host.rs-left-> H (fx- (host.rs-left H) 1))
                (host.rs-at-> H (fx+ Now 4000)))
            H)
        (neighbor-probes H (host.slots H) Now)))

(define earlier
  {fixnum --> fixnum --> fixnum}
  A B -> (if (or (fx< A 0) (and (fx>= B 0) (fx< B A))) B A))

(define due
  {fixnum --> fixnum --> boolean --> fixnum}
  At Now Free ->
    (if Free (if (fx< At Now) Now At) (type -1 fixnum)))

(define probe-deadline
  {host --> fixnum --> fixnum --> boolean --> fixnum --> fixnum}
  _ 0 _ _ At -> At
  H I Now Free At ->
    (let N (neighbor-at H I)
         Next (if (net-link.ready? (neighbor.pending N) 0)
                  (earlier (neighbor.expires N)
                           (if (and (= (neighbor.mac N) 0) (local-ready? H))
                               (due (neighbor.probe-at N) Now Free) (type -1 fixnum)))
                  (type -1 fixnum))
      (probe-deadline H (fx- I 1) Now Free (earlier At Next))))

(define dad-deadline
  {symbol --> fixnum --> fixnum --> boolean --> fixnum}
  State At Now Free ->
    (if (= State tentative)
        (if (fx>= At 0) At (due At Now Free))
        -1))

(define next-deadline
  {host --> fixnum --> fixnum}
  H Now ->
    (let Free (not (net-link.full? (net-link.device.tx (host.device H))))
         Local (dad-deadline (host.local-state H) (host.local-at H) Now Free)
         Global (dad-deadline (host.global-state H) (host.global-at H) Now Free)
         Rs (if (and (fx> (host.rs-left H) 0) (local-ready? H))
                (due (host.rs-at H) Now Free) (type -1 fixnum))
         Lifetime (if (and (not (host.static H)) (not (= (host.global-state H) absent)))
                      (host.valid-until H) (type -1 fixnum))
      (probe-deadline H (host.slots H) Now Free (earlier (earlier Local Global) (earlier Rs Lifetime)))))

(preclude [host.%match neighbor.%match])
)
