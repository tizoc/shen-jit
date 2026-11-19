\\ Bounded IPv4 reassembly for fixed headers. An overlap poisons the datagram until expiry.
(shen.x.namespace net-fragments
  (use buffer)
  (use net-ipv4)
  (use shen-jit)
  (import struct defstruct)
  (export table make receive packet)
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
              present <- (buffer.new (fxquotient (fx+ (fx- Limit 20) 7) 8))
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
        (assembly.src-> A (buffer.u32-be B (fx+ I 12)))
        (assembly.dst-> A (buffer.u32-be B (fx+ I 16)))
        (assembly.id-> A (buffer.u16-be B (fx+ I 4)))
        (assembly.proto-> A (buffer.u8 B (fx+ I 9)))
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
                 (and (= (assembly.id A) (buffer.u16-be B (fx+ I 4)))
                      (= (assembly.proto A) (buffer.u8 B (fx+ I 9)))
                      (= (assembly.src A) (buffer.u32-be B (fx+ I 12)))
                      (= (assembly.dst A) (buffer.u32-be B (fx+ I 16))))
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

(define complete
  {table --> fixnum --> assembly --> fixnum}
  T Index A ->
    (let N (fx+ (assembly.end A) 20)
         B (assembly.bytes A)
      (do (buffer.u16-be-> B 2 N)
          (buffer.u16-be-> B 6 0)
          (buffer.u16-be-> B 10 0)
          (buffer.u16-be-> B 10 (net-ipv4.packet-checksum B 0 20))
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
             (or (and (fx>= Last 0) (or (fx> End Last) (and More (= End Last)) (not More)))
                 (and (not More) (fx> (assembly.highest A) End))
                 (overlaps? Map FirstBlock EndBlock))
               (do (assembly.rejected-> A true) (type 0 fixnum))
             true
               (let Out (assembly.bytes A)
                    Total (fx+ (assembly.received A) N)
                 (do (if (= Offset 0) (buffer.copy-into! Out 0 B I 20) Out)
                     (buffer.copy-into! Out (fx+ 20 Offset) B (fx+ I 20) N)
                     (mark Map FirstBlock EndBlock)
                     (if (fx> End (assembly.highest A)) (assembly.highest-> A End) A)
                     (assembly.received-> A Total)
                     (if More A (assembly.end-> A End))
                     (if (= Total (assembly.end A)) (complete T Index A) (type 0 fixnum)))))))

(define receive
  {table --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum}
  T B I N Now ->
    (let Flags (buffer.u16-be B (fx+ I 6))
         Offset (fx* 8 (shen-jit.bit-and Flags 8191))
         More (not (= (shen-jit.bit-and Flags 8192) 0))
         Payload (fx- N 20)
      (if (and (fx> Payload 0) (fx<= (fx+ Offset N) (table.limit T))
               (= (shen-jit.bit-and Flags 49152) 0)
               (or (not More) (= (fxremainder Payload 8) 0)))
          (let Index (find T B I Now 1 0)
            (if (= Index 0) 0 (store T Index B I Payload Offset More Now)))
          0)))

(preclude [assembly.%match table.%match])
)
