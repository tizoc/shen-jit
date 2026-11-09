\\ Checked byte views over managed bytes or a sized pointer. No FFI library is needed.
\\ A view borrows the exact storage object; it never copies a pointer or releases storage.
\\ Closing that original pointer makes subsequent view operations raise. Independently
\\ copied pointers and closing storage during a native call remain the caller's responsibility.
\\ Load under (tc -); public declarations below support typed clients.

(shen.x.namespace buffer
  (use shen-jit)
  (shadow index length)
  (export append! append-byte! builder builder-length bytes check copy! buffer.cursor => cursor
    end equal? finish from-string index length make new offset owner range slice storage
    buffer.string => string u8 u8! view view? wrap)

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

(define view?
  V -> (trap-error (and (absvector? V) (= (<-address V 0) view))
                   (/. E false)))

\\ Private layout: tag, original owner, start, exclusive end. Metadata is not mutated.
(define make
  Storage Start End -> (address-> (address-> (address-> (address-> (absvector 4)
                                  0 view) 1 Storage) 2 Start) 3 End))

(define check
  V -> (if (view? V)
           (if (<= (<-address V 3) (storage-length (<-address V 1)))
               V
               (error "buffer: backing storage is shorter than the view"))
           (error "buffer: ~S is not a view" V)))

(define wrap
  Storage -> (make Storage 0 (storage-length Storage)))

(define new
  N -> (wrap (shen-jit.bytes (index N))))

(define from-string
  Text -> (wrap (shen-jit.string->bytes Text)))

(define owner
  V -> (<-address (check V) 1))

(define offset
  V -> (<-address (check V) 2))

(define end
  V -> (<-address (check V) 3))

(define length
  V -> (let Checked (check V) (- (<-address Checked 3) (<-address Checked 2))))

(define slice
  V Start Count ->
    (let Checked (check V)
         Begin (<-address Checked 2)
         I (range (- (<-address Checked 3) Begin) Start Count)
         At (+ Begin I)
      (make (<-address Checked 1) At (+ At Count))))

(define u8
  V I -> (let Checked (check V) Start (<-address Checked 2)
              At (range (- (<-address Checked 3) Start) I 1)
           (shen-jit.u8 (<-address Checked 1) (+ Start At))))

(define u8!
  V I Byte -> (let Checked (check V) Start (<-address Checked 2)
                   At (range (- (<-address Checked 3) Start) I 1)
                (do (shen-jit.u8! (<-address Checked 1) (+ Start At) Byte) V)))

(define bytes
  V -> (let Checked (check V) Start (<-address Checked 2)
            N (- (<-address Checked 3) Start) Out (shen-jit.bytes N)
         (shen-jit.copy-bytes Out 0 (<-address Checked 1) Start N)))

(define buffer.string
  V -> (let Checked (check V) Start (<-address Checked 2)
         (shen-jit.bytes->string (<-address Checked 1) Start (- (<-address Checked 3) Start))))

(define copy!
  To I From J Count ->
    (let T (check To) F (check From)
         TStart (<-address T 2) FStart (<-address F 2)
         TI (range (- (<-address T 3) TStart) I Count)
         FJ (range (- (<-address F 3) FStart) J Count)
      (do (shen-jit.copy-bytes (<-address T 1) (+ TStart TI)
                              (<-address F 1) (+ FStart FJ) Count)
          To)))

\\ Flat inner loop: do not reload view records for every byte.
(define equal-range?
  _ _ _ _ 0 -> true
  A I B J N -> (and (= (shen-jit.u8 A I) (shen-jit.u8 B J))
                    (equal-range? A (+ I 1) B (+ J 1) (- N 1))))

(define equal?
  A B -> (let X (check A) Y (check B)
              I (<-address X 2) J (<-address Y 2)
              N (- (<-address X 3) I)
           (and (= N (- (<-address Y 3) J))
                (equal-range? (<-address X 1) I (<-address Y 1) J N))))

\\ A single-owner builder grows geometrically under an explicit byte limit.
\\ Finish transfers its managed storage to a view and seals the builder.
(define builder
  Limit ->
    (let N (index Limit)
         B (absvector 5)
      (do (address-> B 0 builder-state) (address-> B 1 N)
          (address-> B 2 (new 0)) (address-> B 3 0) (address-> B 4 false) B)))

(define builder-check
  B ->
    (if (trap-error (and (absvector? B) (= (<-address B 0) builder-state) (not (<-address B 4)))
          (/. X false))
        B (error "buffer: not an open builder")))

(define builder-length
  B -> (<-address (builder-check B) 3))

(define builder-reserve
  B Need ->
    (let Old (<-address B 2)
         Cap (length Old)
      (if (<= Need Cap)
          Old
          (let Limit (<-address B 1)
               Grow (if (= Cap 0) (if (< Limit 256) Limit 256)
                        (+ Cap (if (< Cap (- Limit Cap)) Cap (- Limit Cap))))
               Next (new (if (> Need Grow) Need Grow))
               _ (copy! Next 0 Old 0 (<-address B 3))
            (do (address-> B 2 Next) Next)))))

(define append!
  B V ->
    (let _ (builder-check B)
         N (length V)
         At (<-address B 3)
         _ (if (<= N (- (<-address B 1) At)) true (error "buffer: builder exceeds byte limit"))
         End (+ At N)
         Out (builder-reserve B End)
         _ (copy! Out At V 0 N)
      (do (address-> B 3 End) B)))

(define append-byte!
  B Byte ->
    (let _ (builder-check B)
         Value (shen-jit.bit-or Byte 0)
         _ (if (and (>= Value 0) (<= Value 255)) true (error "buffer: invalid byte"))
         At (<-address B 3)
         _ (if (< At (<-address B 1)) true (error "buffer: builder exceeds byte limit"))
         Out (builder-reserve B (+ At 1))
         _ (u8! Out At Value)
      (do (address-> B 3 (+ At 1)) B)))

(define finish
  B ->
    (let _ (builder-check B)
         Out (slice (<-address B 2) 0 (<-address B 3))
      (do (address-> B 4 true) (address-> B 2 []) Out)))

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
