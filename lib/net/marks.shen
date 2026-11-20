\\ Presence maps: a bit for each position of a ring of Capacity positions, marked or not, read and
\\ written a run at a time. TCP keeps which bytes of its windows were received, sacked and repaired.
(shen.x.namespace net-marks
  (use buffer)
  (use shen-jit)
  (export bytes marked? run-length run-length-back count mark clear)

(define smaller
  {fixnum --> fixnum --> fixnum}
  A B -> (if (fx< A B) A B))

(define larger
  {fixnum --> fixnum --> fixnum}
  A B -> (if (fx< A B) B A))

\\ A presence map has a bit for each position of a ring: bit At & 7 of byte At >> 3. Its runs are
\\ walked 32 positions to a read, in the machine's order, little-endian on every platform this runs on,
\\ so that position 8K + J is bit J of the word read at byte K. A map has three bytes past those of its
\\ positions, so that a word read at the byte of any position stays in it.
(define bytes
  {fixnum --> fixnum}
  Capacity -> (fx+ (shen-jit.shift-right (fx+ Capacity 7) 3) 3))

\\ How many of the N positions from At on have the bits of Fill, all ones or none, added to Done. The
\\ caller has checked the map's bytes, and that the N positions are in the ring.
(define run-from
  {buffer.storage --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum}
  Storage Base At N Fill Done ->
    (if (fx<= N 0) Done
        (let Shift (shen-jit.bit-and At 7)
             Avail (fx- 32 Shift)
             Word (shen-jit.shift-right (shen-jit.u32 Storage (fx+ Base (shen-jit.shift-right At 3))) Shift)
             Differ (shen-jit.bit-and (shen-jit.bit-xor Word Fill) (fx- (shen-jit.shift-left 1 Avail) 1))
          (cases (not (= Differ 0)) (fx+ Done (smaller N (shen-jit.ctz Differ)))
                 (fx>= Avail N) (fx+ Done N)
                 true (run-from Storage Base (fx+ At Avail) (fx- N Avail) Fill (fx+ Done Avail))))))

\\ The same down from At: the word read ends at At's byte, or starts at the map's first.
(define back-from
  {buffer.storage --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum}
  Storage Base At N Fill Done ->
    (if (fx<= N 0) Done
        (let Byte (larger 0 (fx- (shen-jit.shift-right At 3) 3))
             Top (fx- At (fx* 8 Byte))
             Avail (fx+ Top 1)
             Word (shen-jit.u32 Storage (fx+ Base Byte))
             Differ (shen-jit.bit-and (shen-jit.bit-xor Word Fill) (fx- (shen-jit.shift-left 1 Avail) 1))
          (cases (not (= Differ 0)) (fx+ Done (smaller N (fx- Top (fx- 61 (shen-jit.clz Differ)))))
                 (fx>= Avail N) (fx+ Done N)
                 true (back-from Storage Base (fx- At Avail) (fx- N Avail) Fill (fx+ Done Avail))))))

\\ How many of the N positions from At on are marked, added to Count.
(define count-from
  {buffer.storage --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum}
  Storage Base At N Count ->
    (if (fx<= N 0) Count
        (let Shift (shen-jit.bit-and At 7)
             Take (smaller (fx- 32 Shift) N)
             Word (shen-jit.shift-right (shen-jit.u32 Storage (fx+ Base (shen-jit.shift-right At 3))) Shift)
          (count-from Storage Base (fx+ At Take) (fx- N Take)
                      (fx+ Count (shen-jit.popcount (shen-jit.bit-and Word (fx- (shen-jit.shift-left 1 Take) 1))))))))

\\ Marks the N positions from At on, or clears them.
(define mark-from
  {buffer.storage --> fixnum --> fixnum --> fixnum --> boolean --> boolean}
  Storage Base At N Mark ->
    (if (fx<= N 0) true
        (let Shift (shen-jit.bit-and At 7)
             Take (smaller (fx- 32 Shift) N)
             Offset (fx+ Base (shen-jit.shift-right At 3))
             Bits (shen-jit.shift-left (fx- (shen-jit.shift-left 1 Take) 1) Shift)
             Word (shen-jit.u32 Storage Offset)
          (do (shen-jit.u32! Storage Offset (if Mark (shen-jit.bit-or Word Bits)
                                                (shen-jit.bit-and Word (shen-jit.bit-xor Bits 4294967295))))
              (mark-from Storage Base (fx+ At Take) (fx- N Take) Mark)))))

\\ Where a map starts in its storage, once its bytes and the position Pos of a ring of Capacity are
\\ checked, so that its storage can be read from the view as it is.
(define base-at
  {buffer.view --> fixnum --> fixnum --> fixnum}
  Map Pos Capacity ->
    (if (and (fx>= Pos 0) (fx< Pos Capacity))
        (buffer.offset-at Map 0 (bytes Capacity))
        (error "marks: ring position ~A outside ~A" Pos Capacity)))

\\ The runs, counts and marks of N positions of a ring from Pos on, across its end once at most.
(define run-length
  {buffer.view --> fixnum --> fixnum --> fixnum --> boolean --> fixnum}
  Map Pos Capacity N Mark ->
    (let Base (base-at Map Pos Capacity)
         Storage (buffer.view.owner Map)
         Fill (if Mark (fixnum 4294967295) (fixnum 0))
         First (smaller N (fx- Capacity Pos))
         Run (run-from Storage Base Pos First Fill 0)
      (if (fx< Run First) Run
          (run-from Storage Base 0 (smaller (fx- N First) Pos) Fill Run))))

\\ Down from Pos, the run that ends there.
(define run-length-back
  {buffer.view --> fixnum --> fixnum --> fixnum --> boolean --> fixnum}
  Map Pos Capacity N Mark ->
    (let Base (base-at Map Pos Capacity)
         Storage (buffer.view.owner Map)
         Fill (if Mark (fixnum 4294967295) (fixnum 0))
         First (smaller N (fx+ Pos 1))
         Run (back-from Storage Base Pos First Fill 0)
      (if (fx< Run First) Run
          (back-from Storage Base (fx- Capacity 1) (smaller (fx- N First) (fx- Capacity (fx+ Pos 1))) Fill Run))))

(define count
  {buffer.view --> fixnum --> fixnum --> fixnum --> fixnum}
  Map Pos Capacity N ->
    (let Base (base-at Map Pos Capacity)
         Storage (buffer.view.owner Map)
         First (smaller N (fx- Capacity Pos))
      (count-from Storage Base 0 (smaller (fx- N First) Pos) (count-from Storage Base Pos First 0))))

(define mark
  {buffer.view --> fixnum --> fixnum --> fixnum --> boolean --> boolean}
  Map Pos Capacity N Mark ->
    (let Base (base-at Map Pos Capacity)
         Storage (buffer.view.owner Map)
         First (smaller N (fx- Capacity Pos))
      (do (mark-from Storage Base Pos First Mark)
          (mark-from Storage Base 0 (smaller (fx- N First) Pos) Mark))))

(define clear
  {buffer.view --> fixnum --> boolean}
  Map Capacity -> (mark Map 0 Capacity Capacity false))

\\ Whether position At is marked.
(define marked?
  {buffer.view --> fixnum --> boolean}
  Map At -> (not (= (shen-jit.bit-and (buffer.u8 Map (shen-jit.shift-right At 3))
                                      (shen-jit.shift-left 1 (shen-jit.bit-and At 7)))
                    0)))

)
