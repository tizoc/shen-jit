\\ Checked byte views over managed bytes or a sized pointer. No FFI library is needed.
\\ A view borrows the exact storage object; it never copies a pointer or releases storage.
\\ Closing that original pointer makes subsequent view operations raise. Independently
\\ copied pointers and closing storage during a native call remain the caller's responsibility.
\\ Load under (tc -); public declarations below support typed clients.

(shen.x.namespace buffer
  (use shen-jit)
  (use struct)
  (import struct defstruct)
  (shadow index length)
  (export append! append-byte! builder builder-length bytes check copy! buffer.cursor => cursor
    end equal? finish from-string index length make new offset owner range slice storage
    buffer.string => string u8 u8! view view? view.end view.owner view.start wrap)

(define index
  N -> (let I (shen-jit.bit-or N 0)
         (if (>= I 0) I (error "buffer: ~S is not a nonnegative index" N))))

(define range
  Length Start Count ->
    (let I (index Start) N (index Count)
      (if (and (<= I Length) (<= N (- Length I)))
          I
          (error "buffer: range ~A + ~A exceeds ~A bytes" I N Length))))

(define storage-length
  Storage -> (if (and (shen-jit.pointer? Storage)
                     (= (shen-jit.pointer-address Storage) 0))
                 (error "buffer: storage is closed")
                 (shen-jit.bytes-length Storage)))

\\ A view: the original owner, start and exclusive end. Metadata is not mutated.
(define show-view
  V -> (make-string "#<view ~A..~A>" (view.start V) (view.end V)))

(defstruct view
  (printer show-view)
  owner
  start
  end)

(define make
  Storage Start End -> (view.make Storage Start End))

(define check
  V -> (if (view? V)
           (if (<= (view.end V) (storage-length (view.owner V)))
               V
               (error "buffer: backing storage is shorter than the view"))
           (error "buffer: ~S is not a view" V)))

(define wrap
  Storage -> (view.make Storage 0 (storage-length Storage)))

(define new
  N -> (wrap (shen-jit.bytes (index N))))

(define from-string
  Text -> (wrap (shen-jit.string->bytes Text)))

(define owner
  V -> (view.owner (check V)))

(define offset
  V -> (view.start (check V)))

(define end
  V -> (view.end (check V)))

(define length
  V -> (let Checked (check V) (- (view.end Checked) (view.start Checked))))

(define slice
  V Start Count ->
    (let Checked (check V)
         Begin (view.start Checked)
         I (range (- (view.end Checked) Begin) Start Count)
         At (+ Begin I)
      (view.make (view.owner Checked) At (+ At Count))))

(define u8
  V I -> (let Checked (check V) Start (view.start Checked)
              At (range (- (view.end Checked) Start) I 1)
           (shen-jit.u8 (view.owner Checked) (+ Start At))))

(define u8!
  V I Byte -> (let Checked (check V) Start (view.start Checked)
                   At (range (- (view.end Checked) Start) I 1)
                (do (shen-jit.u8! (view.owner Checked) (+ Start At) Byte) V)))

(define bytes
  V -> (let Checked (check V) Start (view.start Checked)
            N (- (view.end Checked) Start) Out (shen-jit.bytes N)
         (shen-jit.copy-bytes Out 0 (view.owner Checked) Start N)))

(define buffer.string
  V -> (let Checked (check V) Start (view.start Checked)
         (shen-jit.bytes->string (view.owner Checked) Start (- (view.end Checked) Start))))

(define copy!
  To I From J Count ->
    (let T (check To) F (check From)
         TStart (view.start T) FStart (view.start F)
         TI (range (- (view.end T) TStart) I Count)
         FJ (range (- (view.end F) FStart) J Count)
      (do (shen-jit.copy-bytes (view.owner T) (+ TStart TI)
                              (view.owner F) (+ FStart FJ) Count)
          To)))

\\ Flat inner loop: do not reload view records for every byte.
(define equal-range?
  _ _ _ _ 0 -> true
  A I B J N -> (and (= (shen-jit.u8 A I) (shen-jit.u8 B J))
                    (equal-range? A (+ I 1) B (+ J 1) (- N 1))))

(define equal?
  A B -> (let X (check A) Y (check B)
              I (view.start X) J (view.start Y)
              N (- (view.end X) I)
           (and (= N (- (view.end Y) J))
                (equal-range? (view.owner X) I (view.owner Y) J N))))

\\ A single-owner builder grows geometrically under an explicit byte limit.
\\ Finish transfers its managed storage to a view and seals the builder.
(defstruct builder-state
  limit
  (mutable storage)
  (mutable length)
  (mutable sealed))

(define builder
  Limit ->
    (let N (index Limit)
      (struct.make builder-state
        limit <- N;
        storage <- (new 0);
        length <- 0;
        sealed <- false;)))

(define builder-check
  B ->
    (if (and (builder-state? B) (not (builder-state.sealed B)))
        B
        (error "buffer: not an open builder")))

(define builder-length
  B -> (builder-state.length (builder-check B)))

(define builder-reserve
  B Need ->
    (let Old (builder-state.storage B)
         Cap (length Old)
      (if (<= Need Cap)
          Old
          (let Limit (builder-state.limit B)
               Grow (if (= Cap 0) (if (< Limit 256) Limit 256)
                        (+ Cap (if (< Cap (- Limit Cap)) Cap (- Limit Cap))))
               Next (new (if (> Need Grow) Need Grow))
               _ (copy! Next 0 Old 0 (builder-state.length B))
            (do (builder-state.storage-> B Next) Next)))))

(define append!
  B V ->
    (let _ (builder-check B)
         N (length V)
         At (builder-state.length B)
         _ (if (<= N (- (builder-state.limit B) At)) true (error "buffer: builder exceeds byte limit"))
         End (+ At N)
         Out (builder-reserve B End)
         _ (copy! Out At V 0 N)
      (builder-state.length-> B End)))

(define append-byte!
  B Byte ->
    (let _ (builder-check B)
         Value (shen-jit.bit-or Byte 0)
         _ (if (and (>= Value 0) (<= Value 255)) true (error "buffer: invalid byte"))
         At (builder-state.length B)
         _ (if (< At (builder-state.limit B)) true (error "buffer: builder exceeds byte limit"))
         Out (builder-reserve B (+ At 1))
         _ (u8! Out At Value)
      (builder-state.length-> B (+ At 1))))

(define finish
  B ->
    (let _ (builder-check B)
         Out (slice (builder-state.storage B) 0 (builder-state.length B))
      (do (builder-state.sealed-> B true) (builder-state.storage-> B []) Out)))

(declare view? [A --> boolean])
(declare new [number --> view])
(declare wrap [storage --> view])
(declare from-string [string --> view])
(declare slice [view --> [number --> [number --> view]]])
(declare owner [view --> storage])
(declare offset [view --> number])
(declare end [view --> number])
(declare length [view --> number])
(declare u8 [view --> [number --> number]])
(declare u8! [view --> [number --> [number --> view]]])
(declare bytes [view --> storage])
(declare buffer.string [view --> string])
(declare copy! [view --> [number --> [view --> [number --> [number --> view]]]]])
(declare equal? [view --> [view --> boolean]])
(declare builder [number --> builder])
(declare builder-length [builder --> number])
(declare append! [builder --> [view --> builder]])
(declare append-byte! [builder --> [number --> builder]])
(declare finish [builder --> view])

)
