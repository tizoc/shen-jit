\\ Bounded IPv4 reassembly for fixed headers. An overlap poisons the datagram until expiry.
(shen.x.namespace net-fragments
  (use buffer)
  (use net-ipv4)
  (use shen-jit)
  (use net-wire => wire)
  (import struct defstruct)
  (export table make receive packet clear conflict? mark)
  (shadow receive)

(defstruct assembly
  (bytes : buffer.view)
  (present : buffer.view)
  (mutable src : fixnum)
  (mutable dst : fixnum)
  (mutable id : fixnum)
  (mutable proto : fixnum)
  (mutable expires : fixnum)
  (mutable received : fixnum)
  (mutable highest : fixnum)
  (mutable end : fixnum)
  (mutable rejected : boolean))

(defstruct table
  (entries : (vector assembly))
  (slots : fixnum)
  (limit : fixnum)
  (mutable ready-index : fixnum))

(define initialise
  {(vector assembly) --> fixnum --> fixnum --> (vector assembly)}
  V 0 _ -> V
  V I Limit ->
    (let A (:assembly
              bytes <- (buffer.new Limit)
              present <- (buffer.new (fxquotient (fx+ (fx- Limit (wire.ipv4.size)) 7) 8))
              src <- 0
              dst <- 0
              id <- 0
              proto <- 0
              expires <- 0
              received <- 0
              highest <- 0
              end <- -1
              rejected <- false)
      (initialise (fxvector-> V I A) (fx- I 1) Limit)))

(define make
  {fixnum --> fixnum --> table}
  Slots Limit ->
    (:table
      entries <- (initialise (vector (fx->number Slots)) Slots Limit)
      slots <- Slots
      limit <- Limit
      ready-index <- 0))

(define entry
  {table --> fixnum --> assembly}
  T I -> (fx<-vector (table.entries T) I))

(define packet
  {table --> buffer.view}
  T -> (assembly.bytes (entry T (table.ready-index T))))

(define clear
  {buffer.view --> fixnum --> buffer.view}
  B 0 -> B
  B N -> (let Last (fx- N 1) (clear (buffer.u8-> B Last 0) Last)))

(define initialise-entry
  {assembly --> buffer.view --> fixnum --> fixnum --> assembly}
  A B I Now ->
    (do (clear (assembly.present A) (fxquotient (fx+ (assembly.highest A) 7) 8))
        (assembly.src-> A (wire.ipv4.source B I))
        (assembly.dst-> A (wire.ipv4.destination B I))
        (assembly.id-> A (wire.ipv4.identification B I))
        (assembly.proto-> A (wire.ipv4.protocol B I))
        (assembly.expires-> A (fx+ Now 30000))
        (assembly.received-> A 0)
        (assembly.highest-> A 0)
        (assembly.end-> A -1)
        (assembly.rejected-> A false)))

(define find
  {table --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum}
  T B I Now Index Available ->
    (if (fx> Index (table.slots T)) Available
        (let A (entry T Index)
          (cases (fx<= (assembly.expires A) Now)
                   (find T B I Now (fx+ Index 1) Index)
                 (and (= (assembly.id A) (wire.ipv4.identification B I))
                      (= (assembly.proto A) (wire.ipv4.protocol B I))
                      (= (assembly.src A) (wire.ipv4.source B I))
                      (= (assembly.dst A) (wire.ipv4.destination B I)))
                   Index
                 true (find T B I Now (fx+ Index 1) Available)))))

(define overlaps?
  {buffer.view --> fixnum --> fixnum --> boolean}
  B At End ->
    (and (fx< At End) (or (= (buffer.u8 B At) 1) (overlaps? B (fx+ At 1) End))))

(define mark
  {buffer.view --> fixnum --> fixnum --> buffer.view}
  B At End ->
    (if (= At End) B (mark (buffer.u8-> B At 1) (fx+ At 1) End)))

\\ Whether a fragment of the bytes from Offset to End, with more to follow or not, conflicts with those
\\ stored, marked in Present and reaching Highest, of a datagram that ends at Last, or -1 until its last
\\ fragment came: it ends past the end, or at it with more to follow; it is a second last fragment; it is
\\ the last but stored bytes reach past it; or it overlaps them. A fragment is never empty, so one that
\\ ends where stored bytes reach overlaps them.
(define conflict?
  {buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> boolean --> boolean}
  Present Highest Last Offset End More ->
    (or (and (fx>= Last 0) (or (not More) (fx>= End Last)))
        (and (not More) (fx> Highest End))
        (overlaps? Present (fxquotient Offset 8) (fxquotient (fx+ End 7) 8))))

(define complete
  {table --> fixnum --> assembly --> fixnum}
  T Index A ->
    (let N (fx+ (assembly.end A) (wire.ipv4.size))
         B (assembly.bytes A)
      (do (wire.ipv4.total-length-> B 0 N)
          (wire.ipv4.more-fragments-> B 0 0)                \\ Whole now: the last fragment, at offset 0.
          (wire.ipv4.fragment-offset-> B 0 0)
          (wire.ipv4.checksum-> B 0 0)
          (wire.ipv4.checksum-> B 0 (net-ipv4.packet-checksum B 0 (wire.ipv4.size)))
          (table.ready-index-> T Index)
          (assembly.expires-> A 0)
          N)))

(define store
  {table --> fixnum --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean --> fixnum --> fixnum}
  T Index B I N Offset More Now ->
    (let A (entry T Index)
         _ (if (fx<= (assembly.expires A) Now) (initialise-entry A B I Now) A)
         End (fx+ Offset N)
         Last (assembly.end A)
         Map (assembly.present A)
         FirstBlock (fxquotient Offset 8)
         EndBlock (fxquotient (fx+ End 7) 8)
      (cases (assembly.rejected A) 0
             (conflict? Map (assembly.highest A) Last Offset End More)
               (do (assembly.rejected-> A true) (fixnum 0))
             true
               (let Out (assembly.bytes A)
                    Total (fx+ (assembly.received A) N)
                 (do (if (= Offset 0) (buffer.copy-into! Out 0 B I (wire.ipv4.size)) Out)  \\ The first's header.
                     (buffer.copy-into! Out (fx+ (wire.ipv4.size) Offset) B (fx+ I (wire.ipv4.size)) N)
                     (mark Map FirstBlock EndBlock)
                     (if (fx> End (assembly.highest A)) (assembly.highest-> A End) A)
                     (assembly.received-> A Total)
                     (if More A (assembly.end-> A End))
                     (if (= Total (assembly.end A)) (complete T Index A) (fixnum 0)))))))

(define receive
  {table --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum}
  T B I N Now ->
    (let Offset (fx* 8 (wire.ipv4.fragment-offset B I))         \\ Counted in 8-byte blocks.
         More (= (wire.ipv4.more-fragments B I) 1)
         Payload (fx- N (wire.ipv4.size))
      (if (and (fx> Payload 0) (fx<= (fx+ Offset N) (table.limit T))
               (= (wire.ipv4.reserved B I) 0) (= (wire.ipv4.dont-fragment B I) 0)
               (or (not More) (= (fxremainder Payload 8) 0)))
          (let Index (find T B I Now 1 0)
            (if (= Index 0) 0 (store T Index B I Payload Offset More Now)))
          0)))

(preclude [assembly.%match table.%match])
)
