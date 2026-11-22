\\ Bounded multicast listener state shared by IGMP and MLD.
(shen.x.namespace net-multicast
  (use buffer)
  (use net-link)
  (use net-ipv4)
  (use net-ipv6)
  (use shen-jit)
  (use net-wire => wire)
  (import struct defstruct)
  (import layout write-layout)
  (shadow join)
  (export membership make make-sized join4 join6 leave4 leave6 joined4? joined6? joined6-at?
          join-source4 join-source6 leave-source4 leave-source6 accepts4? accepts6-at?
          ingress4 ingress6 poll next-deadline membership.blank6)

\\ A source slot is free, a source listened to, or one left and still reported.
(datatype source-states
  if (element? State [vacant included blocked])
  _____________________________________________
  State : source-state;)

\\ The messages a member takes: a query, a report another member sent, which an older version's member
\\ suppresses its own for, and the rest.
(datatype message-kinds
  if (element? Kind [membership-query older-report other-message])
  ________________________________________________________________
  Kind : message-kind;)

\\ RFC 3376 4.2.12 and RFC 3810 5.2.12: what a report's record says of its group's sources.
(datatype record-kinds
  if (element? Kind [mode-is-include mode-is-exclude change-to-include change-to-exclude
                     allow-new-sources block-old-sources])
  ________________________________________________________________________________
  Kind : record-kind;)

\\ RFC 2236 and RFC 3376: IGMP's messages by type, a v1 and a v2 report both older ones.
(define igmp-message
  {fixnum --> message-kind}
  17 -> membership-query
  18 -> older-report
  22 -> older-report
  _ -> other-message)

\\ RFC 2710 and RFC 3810: MLD's.
(define mld-message
  {fixnum --> message-kind}
  130 -> membership-query
  131 -> older-report
  _ -> other-message)

(defstruct source
  (address : net-ipv6.address)                           \\ IPv4's mapped.
  (mutable state : source-state)
  (mutable reports : fixnum)
  (mutable queried : boolean))

(defstruct group
  (mutable family : fixnum)
  (address : net-ipv6.address)                           \\ IPv4's mapped.
  (sources : (vector source))
  (source-limit : fixnum)
  (mutable filtered : boolean)
  (mutable source-count : fixnum)
  (mutable query-all : boolean)
  (mutable joined : boolean)
  (mutable changes : fixnum)
  (mutable change-at : fixnum)
  (mutable query-at : fixnum)
  (mutable reporter : boolean))

(defstruct membership
  (device : net-link.device)
  (ip : fixnum)
  (groups : (vector group))
  (slots : fixnum)
  (blank6 : net-ipv6.address)
  (scratch6 : net-ipv6.address)
  (sender6 : net-ipv6.address)
  (nodes6 : net-ipv6.address)
  (routers6 : net-ipv6.address)
  (reports6 : net-ipv6.address)
  (mutable seed : fixnum)
  (mutable next : fixnum)
  (mutable igmp1-until : fixnum)
  (mutable igmp2-until : fixnum)
  (mutable mld1-until : fixnum))

(define setup-sources
  {(vector source) --> fixnum --> (vector source)}
  V 0 -> V
  V I ->
    (let S (:source
              address <- (net-ipv6.make-address 0 0 0 0)
              state <- vacant
              reports <- 0
              queried <- false)
      (setup-sources (fxvector-> V I S) (fx- I 1))))

(define setup
  {(vector group) --> fixnum --> fixnum --> (vector group)}
  V 0 _ -> V
  V I Sources ->
    (let G (:group
              family <- 0
              address <- (net-ipv6.make-address 0 0 0 0)
              sources <- (setup-sources (vector (fx->number Sources)) Sources)
              source-limit <- Sources
              filtered <- false
              source-count <- 0
              query-all <- false
              joined <- false
              changes <- 0
              change-at <- -1
              query-at <- -1
              reporter <- false)
      (setup (fxvector-> V I G) (fx- I 1) Sources)))

(define make-sized
  {net-link.device --> fixnum --> fixnum --> fixnum --> fixnum --> membership}
  D IP Slots Sources Seed ->
    (if (and (fx>= Slots 1) (fx<= Slots 64) (fx>= Sources 0) (fx<= Sources 64)
             (fx>= Seed 0) (fx<= Seed 4294967295)
             (fx>= (net-link.mtu D) (if (= Sources 0) 40 (fx+ 48 (fx* Sources 4)))))
        (:membership
          device <- D
          ip <- IP
          groups <- (setup (vector (fx->number Slots)) Slots Sources)
          slots <- Slots
          blank6 <- (net-ipv6.make-address 0 0 0 0)
          scratch6 <- (net-ipv6.make-address 0 0 0 0)
          sender6 <- (net-ipv6.make-address 0 0 0 0)
          nodes6 <- (net-ipv6.link-group 1)
          routers6 <- (net-ipv6.link-group 2)
          reports6 <- (net-ipv6.link-group 22)
          seed <- Seed
          next <- 1
          igmp1-until <- 0
          igmp2-until <- 0
          mld1-until <- 0)
        (error "multicast: need 1..64 groups, 0..64 sources per group, a uint32 seed and room for reports")))

(define make
  {net-link.device --> fixnum --> fixnum --> fixnum --> membership}
  D IP Slots Seed ->
    (let Left (fx- (net-link.mtu D) 48)
         Sources (cases (fx>= Left 32) (fixnum 8)
                        (fx<= Left 0) (fixnum 0)
                        true (fxquotient Left 4))
      (make-sized D IP Slots Sources Seed)))

(define at
  {membership --> fixnum --> group}
  M I -> (fx<-vector (membership.groups M) I))

(define ssm4?
  {fixnum --> boolean}
  IP -> (= (shen-jit.shift-right IP 24) 232))

(define ssm6?
  {net-ipv6.address --> boolean}
  IP -> (and (fx>= (net-ipv6.scope IP) 2) (fx<= (net-ipv6.scope IP) 14)
             (= (shen-jit.bit-and (net-ipv6.address.a IP) 4293984255) 4281335808)))

(define usable4?
  {fixnum --> boolean}
  IP -> (and (net-ipv4.multicast? IP) (not (= IP (all-systems))) (not (ssm4? IP))))

\\ 224.0.0.1, 224.0.0.2 and 224.0.0.22: all systems, all routers, and IGMPv3's reports.
(define all-systems
  {--> fixnum}
  -> (net-ipv4.address 224 0 0 1))

(define all-routers
  {--> fixnum}
  -> (net-ipv4.address 224 0 0 2))

(define igmp3-reports
  {--> fixnum}
  -> (net-ipv4.address 224 0 0 22))

(define usable6?
  {membership --> net-ipv6.address --> boolean}
  M IP ->
    (and (net-ipv6.multicast? IP) (fx>= (net-ipv6.scope IP) 2) (fx<= (net-ipv6.scope IP) 14)
         (not (net-ipv6.same? IP (membership.nodes6 M))) (not (ssm6? IP))))

\\ The slot of a group, by its address, IPv4's mapped, or 0.
(define find
  {membership --> net-ipv6.address --> fixnum --> fixnum}
  _ _ 0 -> 0
  M IP I ->
    (let G (at M I)
      (if (and (not (= (group.family G) 0)) (net-ipv6.same? (group.address G) IP))
          I
          (find M IP (fx- I 1)))))

\\ An IPv4 group's address, and a source's, mapped into the membership's two scratch addresses.
(define group4
  {membership --> fixnum --> net-ipv6.address}
  M IP -> (net-ipv6.map-ipv4 (membership.scratch6 M) IP))

(define source4
  {membership --> fixnum --> net-ipv6.address}
  M IP -> (net-ipv6.map-ipv4 (membership.sender6 M) IP))

(define family-of
  {net-ipv6.address --> fixnum}
  IP -> (if (net-ipv6.mapped? IP) 4 6))

(define vacant
  {membership --> fixnum --> fixnum}
  _ 0 -> 0
  M I -> (if (= (group.family (at M I)) 0) I (vacant M (fx- I 1))))

(define schedule-change
  {group --> boolean --> fixnum --> boolean}
  G Joined Now ->
    (do (group.joined-> G Joined)
        (group.query-at-> G -1)
        (group.changes-> G 2)
        (group.change-at-> G Now)
        true))

(define join
  {membership --> net-ipv6.address --> fixnum --> boolean}
  M IP Now ->
    (let Known (find M IP (membership.slots M))
         I (if (= Known 0) (vacant M (membership.slots M)) Known)
      (and (fx> I 0)
           (let G (at M I)
             (or (group.joined G)
                 (do (group.family-> G (family-of IP))
                     (group.filtered-> G false)
                     (net-ipv6.copy-address (group.address G) IP)
                     (group.reporter-> G false)
                     (schedule-change G true Now)))))))

(define join4
  {membership --> fixnum --> fixnum --> boolean}
  M IP Now ->
    (and (usable4? IP) (join M (group4 M IP) Now)))

(define join6
  {membership --> net-ipv6.address --> fixnum --> boolean}
  M IP Now -> (and (usable6? M IP) (join M IP Now)))

(define leave
  {membership --> fixnum --> fixnum --> boolean}
  M I Now ->
    (and (fx> I 0)
         (let G (at M I)
           (and (not (group.filtered G)) (group.joined G) (schedule-change G false Now)))))

(define leave4
  {membership --> fixnum --> fixnum --> boolean}
  M IP Now -> (leave M (find M (group4 M IP) (membership.slots M)) Now))

(define leave6
  {membership --> net-ipv6.address --> fixnum --> boolean}
  M IP Now -> (leave M (find M IP (membership.slots M)) Now))

(define joined4?
  {membership --> fixnum --> boolean}
  M IP -> (let I (find M (group4 M IP) (membership.slots M))
           (and (fx> I 0) (group.joined (at M I)))))

(define joined6?
  {membership --> net-ipv6.address --> boolean}
  M IP -> (let I (find M IP (membership.slots M))
           (and (fx> I 0) (group.joined (at M I)))))

(define joined6-at?
  {membership --> buffer.view --> fixnum --> boolean}
  M B I -> (and (net-ipv6.multicast-at? B I)
                (joined6? M (net-ipv6.read-address (membership.scratch6 M) B I))))

(define source-at
  {group --> fixnum --> source}
  G I -> (fx<-vector (group.sources G) I))

(define find-source
  {group --> net-ipv6.address --> fixnum --> fixnum --> fixnum}
  _ _ 0 Free -> Free
  G IP I Free ->
    (let S (source-at G I)
      (cases (= (source.state S) vacant) (find-source G IP (fx- I 1) (if (= Free 0) I Free))
             (net-ipv6.same? (source.address S) IP) I
             true (find-source G IP (fx- I 1) Free))))

(define includes?
  {group --> fixnum --> boolean}
  G I -> (and (fx> I 0) (= (source.state (source-at G I)) included)))

(define use-group
  {group --> net-ipv6.address --> group}
  G IP ->
    (if (not (= (group.family G) 0)) G
        (do (group.family-> G (family-of IP))
            (net-ipv6.copy-address (group.address G) IP)
            (group.source-count-> G 0)
            (group.filtered-> G true))))

(define add-source
  {membership --> net-ipv6.address --> net-ipv6.address --> fixnum --> boolean}
  M Group Source Now ->
    (let Known (find M Group (membership.slots M))
         Id (if (= Known 0) (vacant M (membership.slots M)) Known)
      (and (fx> Id 0)
           (let G (at M Id)
                I (find-source G Source (group.source-limit G) 0)
             (and (fx> I 0)
                  (or (includes? G I)
                      (let S (source-at G I)
                        (do (use-group G Group)
                            (net-ipv6.copy-address (source.address S) Source)
                            (source.state-> S included)
                            (source.queried-> S false)
                            (source.reports-> S 2)
                            (group.source-count-> G (fx+ (group.source-count G) 1))
                            (group.joined-> G true)
                            (group.change-at-> G Now)
                            true))))))))

(define remove-source
  {membership --> net-ipv6.address --> net-ipv6.address --> fixnum --> boolean}
  M Group Source Now ->
    (let Id (find M Group (membership.slots M))
      (and (fx> Id 0)
           (let G (at M Id)
                I (find-source G Source (group.source-limit G) -1)
             (and (includes? G I)
                  (let S (source-at G I)
                       Left (fx- (group.source-count G) 1)
                    (do (source.state-> S blocked)
                        (source.queried-> S false)
                        (source.reports-> S 2)
                        (group.source-count-> G Left)
                        (group.joined-> G (fx> Left 0))
                        (if (= Left 0)
                            (do (group.query-at-> G -1) (group.query-all-> G false))
                            G)
                        (group.change-at-> G Now)
                        true)))))))

(define join-source4
  {membership --> fixnum --> fixnum --> fixnum --> boolean}
  M Group Source Now ->
    (and (ssm4? Group) (net-ipv4.unicast? Source)
         (add-source M (group4 M Group) (source4 M Source) Now)))

(define join-source6
  {membership --> net-ipv6.address --> net-ipv6.address --> fixnum --> boolean}
  M Group Source Now ->
    (and (ssm6? Group) (net-ipv6.unicast? Source) (fx>= (net-link.mtu (membership.device M)) (net-ipv6.minimum-mtu))
         (add-source M Group Source Now)))

(define leave-source4
  {membership --> fixnum --> fixnum --> fixnum --> boolean}
  M Group Source Now -> (remove-source M (group4 M Group) (source4 M Source) Now))

(define leave-source6
  {membership --> net-ipv6.address --> net-ipv6.address --> fixnum --> boolean}
  M Group Source Now -> (remove-source M Group Source Now))

(define accepts4?
  {membership --> fixnum --> fixnum --> boolean}
  M Group Source ->
    (let Id (find M (group4 M Group) (membership.slots M))
      (and (fx> Id 0)
           (let G (at M Id)
             (and (group.joined G)
                  (or (not (group.filtered G))
                      (includes? G (find-source G (source4 M Source) (group.source-limit G) -1))))))))

(define accepts6-at?
  {membership --> buffer.view --> fixnum --> fixnum --> boolean}
  M B Group Source ->
    (and (net-ipv6.multicast-at? B Group)
         (let IP (net-ipv6.read-address (membership.scratch6 M) B Group)
              Id (find M IP (membership.slots M))
           (and (fx> Id 0)
                (let G (at M Id)
                  (and (group.joined G)
                       (or (not (group.filtered G))
                           (let Remote (net-ipv6.read-address (membership.sender6 M) B Source)
                             (includes? G (find-source G Remote (group.source-limit G) -1))))))))))

(define jitter
  {membership --> fixnum --> fixnum}
  M Span ->
    (let Seed (shen-jit.bit-and (fx+ (fx* (membership.seed M) 1664525) 1013904223) 4294967295)
      (do (membership.seed-> M Seed) (fxremainder Seed (fx+ Span 1)))))

(define arm-query
  {membership --> group --> fixnum --> fixnum --> boolean}
  M G Span Now ->
    (let Due (group.query-at G)
      (do (if (or (fx< Due 0) (fx> Due (fx+ Now Span)))
              (let Delay (if (fx> Span 0) (fx+ 1 (jitter M (fx- Span 1))) (fixnum 0))
                (group.query-at-> G (fx+ Now Delay)))
              G)
          true)))

(define query
  {membership --> fixnum --> fixnum --> fixnum --> fixnum --> boolean --> boolean}
  _ 0 _ _ _ _ -> false
  M I Family Span Now Modern ->
    (let G (at M I)
      (and (= (group.family G) Family) (group.joined G) (or Modern (not (group.filtered G)))
           (do (group.query-all-> G true)
               (arm-query M G Span Now)))))

(define query-all
  {membership --> fixnum --> fixnum --> fixnum --> fixnum --> boolean --> boolean}
  _ 0 _ _ _ _ -> true
  M I Family Span Now Modern ->
    (do (query M I Family Span Now Modern)
        (query-all M (fx- I 1) Family Span Now Modern)))

(define note-query-source
  {membership --> group --> buffer.view --> fixnum --> boolean}
  M G B At ->
    (let Source (if (= (group.family G) 4) (source4 M (wire.ipv4-address.address B At))
                    (net-ipv6.read-address (membership.sender6 M) B At))
         I (find-source G Source (group.source-limit G) -1)
      (and (includes? G I) (do (source.queried-> (source-at G I) true) true))))

(define query-matches
  {membership --> group --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean --> boolean}
  _ _ _ _ _ 0 Matched -> Matched
  M G B At Width Count Matched ->
    (let Added (note-query-source M G B At)
      (query-matches M G B (fx+ At Width) Width (fx- Count 1) (or Matched Added))))

(define query-sources
  {membership --> fixnum --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  M I B At Width Count Span Now ->
    (and (fx> I 0)
         (let G (at M I)
           (and (group.filtered G) (group.joined G)
                (query-matches M G B At Width Count false)
                (arm-query M G Span Now)))))

(define igmp-version
  {membership --> fixnum --> fixnum}
  M Now -> (cases (fx< Now (membership.igmp1-until M)) 1
                  (fx< Now (membership.igmp2-until M)) 2
                  true 3))

(define mld-version
  {membership --> fixnum --> fixnum}
  M Now -> (if (fx< Now (membership.mld1-until M)) 1 2))

(define suppress
  {membership --> fixnum --> boolean}
  M I ->
    (and (fx> I 0)
         (let G (at M I)
           (and (group.joined G) (not (group.filtered G))
                (do (group.query-at-> G -1)
                    (group.change-at-> G -1)
                    (group.changes-> G 0)
                    (group.reporter-> G false)
                    true)))))

\\ RFC 3376 8.12 and RFC 3810 9.12: how long a router of an older version is taken to be present,
\\ twice the query interval of 125 seconds and the 10-second response.
(define older-version-timeout
  {--> fixnum}
  -> 260000)

(define igmp-delay
  {fixnum --> fixnum}
  Code ->
    (fx* 100 (if (fx< Code 128) Code
                 (shen-jit.shift-left (fx+ 16 (shen-jit.bit-and Code 15))
                                      (fx+ 3 (shen-jit.bit-and (shen-jit.shift-right Code 4) 7))))))

(define igmp-query
  {membership --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  M B At Bytes Dst Now ->
    (let IP (wire.igmp.group B At)
         Code (wire.igmp.max-response B At)
         Old (= Bytes (wire.igmp.size))
         Modern (fx>= Bytes (wire.igmp3-query.size))
         Count (if Modern (wire.igmp3-query.sources B At) (fixnum 0))
         Span (if Old (if (= Code 0) (fixnum 10000) (fx* 100 Code)) (igmp-delay Code))   \\ RFC 2236 2.2.
      (and (or (and (= IP 0) (= Dst (all-systems)) (= Count 0))
               (and (net-ipv4.multicast? IP) (= IP Dst) (or Modern (not (ssm4? IP)))))
           (or (and Old (or (not (= Code 0)) (= IP 0)))
               (and Modern (= Bytes (fx+ (wire.igmp3-query.size) (fx* Count (wire.ipv4-address.size))))))
           (do (if Old
                   (if (= Code 0) (membership.igmp1-until-> M (fx+ Now (older-version-timeout)))
                       (membership.igmp2-until-> M (fx+ Now (older-version-timeout))))
                   M)
               (if (= IP 0) (query-all M (membership.slots M) 4 Span Now Modern)
                   (let I (find M (group4 M IP) (membership.slots M))
                     (if (= Count 0) (query M I 4 Span Now Modern)
                         (query-sources M I B (fx+ At (wire.igmp3-query.size)) (wire.ipv4-address.size)
                                        Count Span Now))))))))

(define ingress4
  {membership --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  M B I N Now ->
    (and (net-ipv4.valid-envelope? B I N) (not (net-ipv4.fragmented? B I))
         (= (wire.ipv4.time-to-live B I) 1) (= (wire.ipv4.protocol B I) (wire.igmp-protocol))
         (let Bytes (net-ipv4.header-length B I)
              Body (fx- N Bytes)
              At (fx+ I Bytes)
              Source (wire.ipv4.source B I)
              Destination (wire.ipv4.destination B I)
           (and (fx>= Body (wire.igmp.size)) (= (net-ipv4.packet-checksum B At Body) 0)
                (let Kind (igmp-message (wire.igmp.type B At))
                     Group (wire.igmp.group B At)
                  (cases (and (= Kind membership-query) (net-ipv4.unicast? Source) (not (= Source (membership.ip M))))
                           (igmp-query M B At Body Destination Now)
                         (and (= Kind older-report) (= Body (wire.igmp.size)) (= Destination Group)
                              (or (= Source 0) (net-ipv4.unicast? Source))
                              (not (= Source (membership.ip M))) (fx< (igmp-version M Now) 3))
                           (suppress M (find M (group4 M Group) (membership.slots M)))
                         true false))))))

(define mld-delay
  {fixnum --> fixnum}
  Code ->
    (if (fx< Code 32768) Code
        (shen-jit.shift-left (fx+ 4096 (shen-jit.bit-and Code 4095))
                             (fx+ 3 (shen-jit.bit-and (shen-jit.shift-right Code 12) 7)))))

(define mld-query
  {membership --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  M B I At Bytes Now ->
    (let Group (net-ipv6.read-address (membership.scratch6 M) B (wire.mld.group-at At))
         General (net-ipv6.unspecified? Group)
         Old (= Bytes (wire.mld.size))
         Modern (fx>= Bytes (wire.mld2-query.size))
         Count (if Modern (wire.mld2-query.sources B At) (fixnum 0))
         Code (wire.mld.max-response B At)
         Span (if Old Code (mld-delay Code))
         To (wire.ipv6.destination-at I)
      (and (if General (and (= Count 0) (net-ipv6.address-at? (membership.nodes6 M) B To))
               (and (or (usable6? M Group) (and Modern (ssm6? Group)))
                    (net-ipv6.address-at? Group B To)))
           (or Old (and Modern (= Bytes (fx+ (wire.mld2-query.size) (fx* Count (wire.ipv6-address.size))))))
           (do (if Old (membership.mld1-until-> M (fx+ Now (older-version-timeout))) M)
               (if General (query-all M (membership.slots M) 6 Span Now Modern)
                   (let Index (find M Group (membership.slots M))
                     (if (= Count 0) (query M Index 6 Span Now Modern)
                         (query-sources M Index B (fx+ At (wire.mld2-query.size)) (wire.ipv6-address.size)
                                        Count Span Now))))))))

\\ A message at At. RFC 3810 5: it comes behind a hop-by-hop header whose router alert says MLD, 0;
\\ Alert is the value the header walk found, or -1.
(define ingress6
  {membership --> net-ipv6.address --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum -->
   boolean}
  M Local B I N At Alert Now ->
    (let Bytes (fx- (fx+ I N) At)
      (and (= Alert 0) (fx>= Bytes (wire.mld.size)) (= (wire.ipv6.hop-limit B I) 1) (= (wire.mld.code B At) 0)
           (= (net-ipv6.transport-checksum-at B I At (wire.icmp6-protocol) Bytes) 0)
           (let Source (net-ipv6.read-address (membership.sender6 M) B (wire.ipv6.source-at I))
                Kind (mld-message (wire.mld.type B At))
             (and (not (net-ipv6.same? Source Local))
                  (cases (and (= Kind membership-query) (net-ipv6.link-local? Source))
                           (mld-query M B I At Bytes Now)
                         (and (= Kind older-report) (= Bytes (wire.mld.size)) (= (mld-version M Now) 1)
                              (or (net-ipv6.link-local? Source) (net-ipv6.unspecified? Source)))
                           (let IP (net-ipv6.read-address (membership.scratch6 M) B (wire.mld.group-at At))
                             (and (net-ipv6.address-at? IP B (wire.ipv6.destination-at I))
                                  (suppress M (find M IP (membership.slots M)))))
                         true false))))))

(define record-number
  {record-kind --> fixnum}
  mode-is-include -> 1
  mode-is-exclude -> 2
  change-to-include -> 3
  change-to-exclude -> 4
  allow-new-sources -> 5
  block-old-sources -> 6)

\\ A record of no sources: excluding none, as a joined group answers a query, or a change of mode.
(define change-record
  {group --> boolean --> record-kind}
  G Change ->
    (cases (not Change) mode-is-exclude
           (group.joined G) change-to-exclude
           true change-to-include))

\\ RFC 2236 and RFC 3376: a v3 report of one record, a v1 or v2 report, or a v2 leave.
(define igmp-body
  {group --> buffer.view --> fixnum --> fixnum --> boolean --> buffer.view}
  G B At Version Change ->
    (cases (= Version 3)
             (do (write-layout wire.membership-report B At (type 34) (records 1))
                 (write-layout wire.igmp3-record B (fx+ At (wire.membership-report.size))
                   (record-type (record-number (change-record G Change))) (group (net-ipv6.address.d (group.address G)))))
           (= Version 1) (write-layout wire.igmp B At (type 18) (group (net-ipv6.address.d (group.address G))))
           (group.joined G) (write-layout wire.igmp B At (type 22) (group (net-ipv6.address.d (group.address G))))
           true (write-layout wire.igmp B At (type 23) (group (net-ipv6.address.d (group.address G))))))

\\ IGMP goes with TTL 1 and a router alert, so behind an IPv4 header of 24 bytes.
(define igmp-offset
  {--> fixnum}
  -> (fx+ (wire.ipv4.size) (wire.ipv4-router-alert.size)))

(define igmp-header
  {membership --> buffer.view --> fixnum --> fixnum --> fixnum --> buffer.view}
  M B I Size Dst ->
    (do (write-layout wire.ipv4 B I
          (version 4) (header-length 6) (total-length Size)
          (dont-fragment 1) (time-to-live 1) (protocol (wire.igmp-protocol))
          (source (membership.ip M)) (destination Dst))
        (write-layout wire.ipv4-router-alert B (fx+ I (wire.ipv4.size)) (type 148) (length 4))   \\ Copied.
        (wire.ipv4.checksum-> B I (net-ipv4.packet-checksum B I (igmp-offset)))))

(define igmp-publish
  {membership --> net-link.ring --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  M Tx B I Size Now ->
    (let At (fx+ I (igmp-offset))
      (do (wire.igmp.checksum-> B At (net-ipv4.packet-checksum B At (fx- Size (igmp-offset))))
          (net-link.publish Tx Size (net-link.delivery (membership.device M) Now)))))

(define send4
  {membership --> group --> net-link.ring --> fixnum --> boolean --> fixnum --> boolean}
  M G Tx Version Change Now ->
    (let Size (fx+ (igmp-offset) (if (= Version 3) (fx+ (wire.membership-report.size) (wire.igmp3-record.size))
                                     (wire.igmp.size)))
         Dst (cases (= Version 3) (igmp3-reports)
                    (group.joined G) (net-ipv6.address.d (group.address G))
                    true (all-routers))
         B (net-link.ring.data Tx)
         I (net-link.tail-offset Tx)
      (do (igmp-header M B I Size Dst)
          (igmp-body G B (fx+ I (igmp-offset)) Version Change)
          (igmp-publish M Tx B I Size Now))))

\\ RFC 2710 and RFC 3810: a v2 report of one record, a v1 report, or a v1 done.
(define mld-body
  {group --> buffer.view --> fixnum --> fixnum --> boolean --> buffer.view}
  G B At Version Change ->
    (if (= Version 2)
        (let R (fx+ At (wire.membership-report.size))
          (do (write-layout wire.membership-report B At (type 143) (records 1))
              (write-layout wire.mld2-record B R (record-type (record-number (change-record G Change))))
              (net-ipv6.write-address B (wire.mld2-record.group-at R) (group.address G))))
        (do (if (group.joined G) (write-layout wire.mld B At (type 131)) (write-layout wire.mld B At (type 132)))
            (net-ipv6.write-address B (wire.mld.group-at At) (group.address G)))))

\\ MLD goes with hop limit 1 and a hop-by-hop header holding a router alert, so behind 48 bytes.
(define mld-offset
  {--> fixnum}
  -> (fx+ (wire.ipv6.size) (wire.ipv6-router-alert.size)))

(define mld-header
  {buffer.view --> fixnum --> fixnum --> net-ipv6.address --> net-ipv6.address --> buffer.view}
  B I Size Source Dst ->
    (do (net-ipv6.write-header B I Size 0 1 Source Dst)
        (write-layout wire.ipv6-router-alert B (fx+ I (wire.ipv6.size))
          (next-header (wire.icmp6-protocol)) (type 5) (option-length 2) (pad 1))))

(define mld-publish
  {membership --> net-link.ring --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  M Tx B I Size Now ->
    (let At (fx+ I (mld-offset))
      (do (wire.mld.checksum-> B At (net-ipv6.transport-checksum-at B I At (wire.icmp6-protocol) (fx- Size (mld-offset))))
          (net-link.publish Tx Size (net-link.delivery (membership.device M) Now)))))

(define send6
  {membership --> group --> net-link.ring --> net-ipv6.address --> fixnum --> boolean --> fixnum --> boolean}
  M G Tx Source Version Change Now ->
    (let Size (fx+ (mld-offset) (if (= Version 2) (fx+ (wire.membership-report.size) (wire.mld2-record.size))
                                    (wire.mld.size)))
         Dst (cases (= Version 2) (membership.reports6 M)
                    (group.joined G) (group.address G)
                    true (membership.routers6 M))
         B (net-link.ring.data Tx)
         I (net-link.tail-offset Tx)
      (do (mld-header B I Size Source Dst)
          (mld-body G B (fx+ I (mld-offset)) Version Change)
          (mld-publish M Tx B I Size Now))))

\\ SSM records carry the selected sources, never an EXCLUDE mode.
(define selected?
  {group --> source --> record-kind --> boolean}
  G S Kind ->
    (let State (source.state S)
      (cases (= Kind mode-is-include) (and (= State included) (or (group.query-all G) (source.queried S)))
             (= Kind allow-new-sources) (and (= State included) (fx> (source.reports S) 0))
             true (and (= State blocked) (fx> (source.reports S) 0)))))

(define count-sources
  {group --> record-kind --> fixnum --> fixnum --> fixnum}
  _ _ 0 Count -> Count
  G Kind I Count ->
    (count-sources G Kind (fx- I 1)
                   (if (selected? G (source-at G I) Kind) (fx+ Count 1) Count)))

(define write-sources
  {group --> buffer.view --> fixnum --> boolean --> record-kind --> fixnum --> buffer.view}
  _ B _ _ _ 0 -> B
  G B At Four Kind I ->
    (let S (source-at G I)
      (cases (not (selected? G S Kind)) (write-sources G B At Four Kind (fx- I 1))
             Four (write-sources G (wire.ipv4-address.address-> B At (net-ipv6.address.d (source.address S)))
                                 (fx+ At (wire.ipv4-address.size)) Four Kind (fx- I 1))
             true (write-sources G (net-ipv6.write-address B At (source.address S))
                                 (fx+ At (wire.ipv6-address.size)) Four Kind (fx- I 1)))))

(define write-source-record
  {group --> buffer.view --> fixnum --> boolean --> record-kind --> fixnum --> buffer.view}
  G B At Four Kind Count ->
    (if Four
        (write-sources G (write-layout wire.igmp3-record B At (record-type (record-number Kind)) (sources Count) (group (net-ipv6.address.d (group.address G))))
                       (fx+ At (wire.igmp3-record.size)) Four Kind (group.source-limit G))
        (do (write-layout wire.mld2-record B At (record-type (record-number Kind)) (sources Count))
            (net-ipv6.write-address B (wire.mld2-record.group-at At) (group.address G))
            (write-sources G B (fx+ At (wire.mld2-record.size)) Four Kind (group.source-limit G)))))

\\ A v3 or v2 report of the sources a query asked about, or of those allowed and blocked.
(define send-source-report
  {membership --> group --> net-link.ring --> net-ipv6.address --> record-kind --> fixnum -->
   fixnum --> fixnum --> boolean}
  M G Tx Source Kind First Blocks Now ->
    (let Four (= (group.family G) 4)
         Width (if Four (wire.ipv4-address.size) (wire.ipv6-address.size))
         Header (if Four (igmp-offset) (mld-offset))
         Per (if Four (wire.igmp3-record.size) (wire.mld2-record.size))
         Records (fx+ (if (fx> First 0) 1 0) (if (fx> Blocks 0) 1 0))
         One (if (fx> First 0) (fx+ Per (fx* First Width)) (fixnum 0))
         Size (fx+ (fx+ Header (wire.membership-report.size)) (fx+ (fx* Records Per) (fx* (fx+ First Blocks) Width)))
         B (net-link.ring.data Tx)
         I (net-link.tail-offset Tx)
         At (fx+ I Header)
         Body (fx+ At (wire.membership-report.size))
      (do (if Four (igmp-header M B I Size (igmp3-reports))
              (mld-header B I Size Source (membership.reports6 M)))
          (if Four (write-layout wire.membership-report B At (type 34) (records Records))
              (write-layout wire.membership-report B At (type 143) (records Records)))
          (if (fx> First 0) (write-source-record G B Body Four Kind First) B)
          (if (fx> Blocks 0) (write-source-record G B (fx+ Body One) Four block-old-sources Blocks) B)
          (if Four (igmp-publish M Tx B I Size Now) (mld-publish M Tx B I Size Now)))))

(define clear-query
  {group --> fixnum --> boolean}
  _ 0 -> true
  G I -> (do (source.queried-> (source-at G I) false) (clear-query G (fx- I 1))))

(define note-reports
  {group --> fixnum --> boolean --> boolean}
  _ 0 Pending -> Pending
  G I Pending ->
    (let S (source-at G I)
         Old (source.reports S)
         Left (if (fx> Old 0) (fx- Old 1) (fixnum 0))
      (do (source.reports-> S Left)
          (if (and (= Left 0) (= (source.state S) blocked)) (source.state-> S vacant) S)
          (note-reports G (fx- I 1) (or Pending (fx> Left 0))))))

(define filtered-change
  {membership --> group --> net-link.ring --> net-ipv6.address --> fixnum --> boolean}
  M G Tx Source Now ->
    (let Limit (group.source-limit G)
         Allowed (count-sources G allow-new-sources Limit 0)
         Blocked (count-sources G block-old-sources Limit 0)
         Sent (or (= (fx+ Allowed Blocked) 0)
                  (send-source-report M G Tx Source allow-new-sources Allowed Blocked Now))
      (and Sent
           (let Pending (note-reports G Limit false)
             (cases Pending (do (group.change-at-> G (fx+ Now (fx+ 1 (jitter M 999)))) true)
                    (not (group.joined G)) (retire G)
                    true (do (group.change-at-> G -1) true))))))

(define filtered-query
  {membership --> group --> net-link.ring --> net-ipv6.address --> fixnum --> boolean}
  M G Tx Source Now ->
    (let Limit (group.source-limit G)
         Count (count-sources G mode-is-include Limit 0)
      (and (or (= Count 0) (send-source-report M G Tx Source mode-is-include Count 0 Now))
           (do (group.query-at-> G -1)
               (group.query-all-> G false)
               (clear-query G Limit)))))

(define due?
  {fixnum --> fixnum --> boolean}
  At Now -> (and (fx>= At 0) (fx<= At Now)))

(define retire
  {group --> boolean}
  G -> (do (group.family-> G 0)
           (group.change-at-> G -1)
           (group.query-at-> G -1)
           (group.query-all-> G false)
           (group.changes-> G 0)
           true))

(define reported
  {membership --> group --> boolean --> boolean --> fixnum --> boolean}
  M G Change Modern Now ->
    (let Left (fx- (group.changes G) 1)
      (do (group.reporter-> G (group.joined G))
          (if (or (not Change) (and (not Modern) (due? (group.query-at G) Now))) (group.query-at-> G -1) G)
          (if Change
              (cases (and (not (group.joined G)) (or (not Modern) (= Left 0))) (retire G)
                     true (do (group.changes-> G Left)
                              (group.change-at-> G (if (= Left 0) -1
                                                       (fx+ Now (fx+ 1 (jitter M 999)))))
                              true))
              true))))

(define step-group
  {membership --> group --> net-link.ring --> net-ipv6.address --> fixnum --> boolean}
  M G Tx Source Now ->
    (let Family (group.family G)
         Change (due? (group.change-at G) Now)
         Query (due? (group.query-at G) Now)
         Version (if (= Family 4) (igmp-version M Now) (mld-version M Now))
         Modern (if (= Family 4) (= Version 3) (= Version 2))
      (cases (or (= Family 0) (not (or Change Query))) false
             (and (= Family 6) (not (net-ipv6.link-local? Source))) false
             (group.filtered G)
               (if Change (filtered-change M G Tx Source Now)
                   (filtered-query M G Tx Source Now))
             (and (not (group.joined G)) (not Modern)
                  (or (not (group.reporter G)) (and (= Family 4) (= Version 1)))) (retire G)
             (= Family 4) (and (send4 M G Tx Version Change Now) (reported M G Change Modern Now))
             true (and (send6 M G Tx Source Version Change Now) (reported M G Change Modern Now)))))

(define scan
  {membership --> net-link.ring --> net-ipv6.address --> fixnum --> fixnum --> fixnum --> boolean}
  _ _ _ _ _ 0 -> false
  M Tx Source Now I Left ->
    (let Next (if (= I (membership.slots M)) (fixnum 1) (fx+ I 1))
      (if (step-group M (at M I) Tx Source Now)
          (do (membership.next-> M Next) true)
          (scan M Tx Source Now Next (fx- Left 1)))))

(define poll
  {membership --> net-ipv6.address --> fixnum --> boolean}
  M Source Now ->
    (let Tx (net-link.device.tx (membership.device M))
      (and (not (net-link.full? Tx))
           (scan M Tx Source Now (membership.next M) (membership.slots M)))))

(define pending
  {membership --> boolean --> fixnum --> fixnum --> fixnum}
  _ _ 0 At -> At
  M Ready6 I At ->
    (let G (at M I)
         Next (if (or (= (group.family G) 4) (and Ready6 (= (group.family G) 6)))
                  (net-link.earlier At (net-link.earlier (group.change-at G) (group.query-at G)))
                  At)
      (pending M Ready6 (fx- I 1) Next)))

(define next-deadline
  {membership --> boolean --> fixnum}
  M Ready6 ->
    (if (net-link.full? (net-link.device.tx (membership.device M))) -1
        (pending M Ready6 (membership.slots M) -1)))

(preclude [group.%match source.%match membership.%match])
)
