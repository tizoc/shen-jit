\\ Each slot holds one datagram and the per-fragment headers from offset zero.
(shen.x.namespace net-fragments6
  (use buffer)
  (use net-ipv6)
  (use net-fragments)
  (use shen-jit)
  (use net-wire => wire)
  (import struct defstruct)
  (shadow receive)
  (export table make receive packet expire next-deadline table.quote table.slots)

(defstruct assembly
  (bytes : buffer.view)
  (header : buffer.view)
  (present : buffer.view)
  (source : net-ipv6.address)
  (destination : net-ipv6.address)
  (mutable identification : fixnum)
  (mutable expires : fixnum)
  (mutable received : fixnum)
  (mutable highest : fixnum)
  (mutable end : fixnum)
  (mutable first-size : fixnum)
  (mutable header-size : fixnum)
  (mutable next-field : fixnum)
  (mutable rejected : boolean))

(defstruct table
  (entries : (vector assembly))
  (slots : fixnum)
  (limit : fixnum)
  (quote : buffer.view)
  (mutable ready-index : fixnum))

(define initialise
  {(vector assembly) --> fixnum --> fixnum --> (vector assembly)}
  V 0 _ -> V
  V I Limit ->
    (let A (:assembly
              bytes <- (buffer.new Limit)
              header <- (buffer.new 296)
              present <- (buffer.new (fxquotient (fx+ (fx- Limit (wire.ipv6.size)) 7) 8))
              source <- (net-ipv6.make-address 0 0 0 0)
              destination <- (net-ipv6.make-address 0 0 0 0)
              identification <- 0
              expires <- -1
              received <- 0
              highest <- 0
              end <- -1
              first-size <- 0
              header-size <- 0
              next-field <- 0
              rejected <- false)
      (initialise (fxvector-> V I A) (fx- I 1) Limit)))

(define make
  {fixnum --> fixnum --> table}
  Slots Limit ->
    (if (and (fx>= Slots 1) (fx<= Slots 16) (fx>= Limit 1500) (fx<= Limit 65575))
        (:table
          entries <- (initialise (vector (fx->number Slots)) Slots Limit)
          slots <- Slots
          limit <- Limit
          quote <- (buffer.new (net-ipv6.error-quote))
          ready-index <- 0)
        (error "IPv6: need 1..16 reassembly slots of 1500..65575 bytes")))

(define entry
  {table --> fixnum --> assembly}
  T I -> (fx<-vector (table.entries T) I))

(define packet
  {table --> buffer.view}
  T -> (assembly.bytes (entry T (table.ready-index T))))

(define reset-slot
  {assembly --> buffer.view --> fixnum --> fixnum --> fixnum --> assembly}
  A B I Id Now ->
    (do (net-fragments.clear (assembly.present A) (fxquotient (fx+ (assembly.highest A) 7) 8))
        (net-ipv6.read-address (assembly.source A) B (wire.ipv6.source-at I))
        (net-ipv6.read-address (assembly.destination A) B (wire.ipv6.destination-at I))
        (assembly.identification-> A Id)
        (assembly.expires-> A (fx+ Now (reassembly-timeout)))
        (assembly.received-> A 0)
        (assembly.highest-> A 0)
        (assembly.end-> A -1)
        (assembly.first-size-> A 0)
        (assembly.header-size-> A 0)
        (assembly.rejected-> A false)))

\\ RFC 8200 4.5: a datagram's fragments all arrive within a minute of the first.
(define reassembly-timeout
  {--> fixnum}
  -> 60000)

(define find
  {table --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum}
  T B I Id Index Available ->
    (if (fx> Index (table.slots T)) Available
        (let A (entry T Index)
          (cases (fx< (assembly.expires A) 0) (find T B I Id (fx+ Index 1) Index)
                 (and (= (assembly.identification A) Id)
                      (net-ipv6.address-at? (assembly.source A) B (wire.ipv6.source-at I))
                      (net-ipv6.address-at? (assembly.destination A) B (wire.ipv6.destination-at I))) Index
                 true (find T B I Id (fx+ Index 1) Available)))))

(define remember-first
  {assembly --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> assembly}
  A B I Header Prev Count ->
    (do (buffer.copy-into! (assembly.header A) 0 B I Header)
        (assembly.header-size-> A Header)
        (assembly.next-field-> A (fx- Prev I))
        (assembly.first-size-> A Count)))

(define complete
  {table --> assembly --> fixnum --> fixnum}
  T A Index ->
    (let Out (assembly.bytes A)
         Head (assembly.header A)
         Prefix (fx- (assembly.header-size A) (wire.ipv6-fragment.size))
         Count (assembly.end A)
         Size (fx+ Prefix Count)
      (do (buffer.copy-into! Out Prefix Out (wire.ipv6.size) Count)
          (buffer.copy-into! Out 0 Head 0 Prefix)
          \\ The field that named the fragment header names what followed it.
          (buffer.u8-> Out (assembly.next-field A) (wire.ipv6-fragment.next-header Head Prefix))
          (wire.ipv6.payload-length-> Out 0 (fx- Size (wire.ipv6.size)))
          (table.ready-index-> T Index)
          (assembly.expires-> A -1)
          Size)))

(define larger
  {fixnum --> fixnum --> fixnum}
  A B -> (if (fx> A B) A B))

(define conflict?
  {assembly --> fixnum --> fixnum --> boolean --> boolean}
  A Offset End More ->
    (let Final (assembly.end A)
      (or (and (fx>= Final 0) (or (fx> End Final) (not More) (and More (= End Final))))
          (and (not More) (fx>= (assembly.highest A) End))
          (net-fragments.overlaps? (assembly.present A)
                                   (fxquotient Offset 8) (fxquotient (fx+ End 7) 8)))))

(define store
  {table --> assembly --> fixnum --> buffer.view --> fixnum --> fixnum --> fixnum -->
   fixnum --> fixnum --> boolean --> fixnum}
  T A Index B I Frag Prev Bytes Offset More ->
    (let End (fx+ Offset Bytes)
         High (larger (assembly.highest A) End)
         Prefix (cases (= Offset 0) (fx- Frag I)
                       (fx> (assembly.header-size A) 0) (fx- (assembly.header-size A) (wire.ipv6-fragment.size))
                       true (wire.ipv6.size))
         Total (fx+ (assembly.received A) Bytes)
      (cases (assembly.rejected A) 0
             (or (fx> (fx+ Prefix High) (table.limit T)) (conflict? A Offset End More))
               (do (assembly.rejected-> A true) (fixnum 0))
             true
               (do (if (= Offset 0) (remember-first A B I (fx+ (fx- Frag I) (wire.ipv6-fragment.size)) Prev Bytes) A)
                   (buffer.copy-into! (assembly.bytes A) (fx+ (wire.ipv6.size) Offset) B
                                      (fx+ Frag (wire.ipv6-fragment.size)) Bytes)
                   (net-fragments.mark (assembly.present A)
                                       (fxquotient Offset 8) (fxquotient (fx+ End 7) 8))
                   (assembly.highest-> A High)
                   (assembly.received-> A Total)
                   (if More A (assembly.end-> A End))
                   (if (and (fx> (assembly.header-size A) 0) (= Total (assembly.end A)))
                       (complete T A Index) (fixnum 0))))))

\\ Atomic fragments are handled by the header walker, outside the slot table.
(define receive
  {table --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum}
  T B I N Frag Prev Now ->
    (let Offset (fx* 8 (wire.ipv6-fragment.offset B Frag))                \\ In bytes.
         More (= (wire.ipv6-fragment.more B Frag) 1)
         Bytes (fx- (fx+ I N) (fx+ Frag (wire.ipv6-fragment.size)))
         Id (wire.ipv6-fragment.identification B Frag)
         TooLarge (fx> (fx+ (fx+ Offset Bytes) (wire.ipv6.size)) (table.limit T))
      (if (and (fx> Bytes 0)
               (or More (fx> Offset 0))
               (or (not More) (= (fxremainder Bytes 8) 0)))
          (let Index (find T B I Id 1 0)
            (if (= Index 0) 0
                (let A (entry T Index)
                     Free (fx< (assembly.expires A) 0)
                  (if (and Free TooLarge) 0
                      (do (if Free (reset-slot A B I Id Now) A)
                          (store T A Index B I Frag Prev Bytes Offset More))))))
          0)))

(define expire
  {table --> fixnum --> fixnum --> fixnum}
  T I Now ->
    (let A (entry T I)
         At (assembly.expires A)
         Size (assembly.header-size A)
      (if (and (fx>= At 0) (fx<= At Now))
          (do (assembly.expires-> A -1)
              (if (and (not (assembly.rejected A)) (fx> Size 0))
                  (let Out (table.quote T)
                       Available (fx- (net-ipv6.error-quote) Size)
                       First (assembly.first-size A)
                       N (if (fx< First Available) First Available)
                    (do (buffer.copy-into! Out 0 (assembly.header A) 0 Size)
                        (buffer.copy-into! Out Size (assembly.bytes A) (wire.ipv6.size) N)
                        (fx+ Size N)))
                  (fixnum 0)))
          0)))

(define deadline
  {table --> fixnum --> fixnum --> fixnum}
  _ 0 Next -> Next
  T I Next ->
    (let At (assembly.expires (entry T I))
      (deadline T (fx- I 1) (if (or (fx< Next 0) (and (fx>= At 0) (fx< At Next))) At Next))))

(define next-deadline
  {table --> fixnum}
  T -> (deadline T (table.slots T) -1))

(preclude [assembly.%match table.%match])
)
