(shen.x.namespace buffer
  (use option)
  (use shen-jit)
  (shadow index length)
  (export append! append-byte! builder builder-length finish)

(define builder
  {fixnum --> builder}
  Limit ->
    (let N (index Limit)
      (:builder
        limit <- N
        storage <- (option.some (new 0))
        length <- 0)))

(define open-storage
  {(option.t view) --> view}
  [View] -> View
  [] -> (error "buffer: not an open builder"))

(define builder-view
  {builder --> view}
  B -> (if (builder? B)
           (open-storage (builder.storage B))
           (error "buffer: not an open builder")))

(define builder-length
  {builder --> fixnum}
  B -> (do (builder-view B) (builder.length B)))

(define builder-reserve
  {builder --> view --> fixnum --> view}
  B Old Need ->
    (let Cap (length Old)
      (if (fx<= Need Cap)
          Old
          (let Limit (builder.limit B)
               Grow (if (= Cap 0) (if (fx< Limit 256) Limit 256)
                        (fx+ Cap (if (fx< Cap (fx- Limit Cap)) Cap (fx- Limit Cap))))
               Next (new (if (fx> Need Grow) Need Grow))
               _ (copy! Next 0 Old 0 (builder.length B))
            (do (builder.storage-> B (option.some Next)) Next)))))

(define append!
  {builder --> view --> builder}
  B V ->
    (let Old (builder-view B)
         N (length V)
         At (builder.length B)
         _ (if (fx<= N (fx- (builder.limit B) At)) true (error "buffer: builder exceeds byte limit"))
         End (fx+ At N)
         Out (builder-reserve B Old End)
         _ (copy! Out At V 0 N)
      (builder.length-> B End)))

(define append-byte!
  {builder --> fixnum --> builder}
  B Byte ->
    (let Old (builder-view B)
         Value (shen-jit.bit-or Byte 0)
         _ (if (and (fx>= Value 0) (fx<= Value 255)) true (error "buffer: invalid byte"))
         At (builder.length B)
         _ (if (fx< At (builder.limit B)) true (error "buffer: builder exceeds byte limit"))
         End (fx+ At 1)
         Out (builder-reserve B Old End)
         _ (u8! Out At Value)
      (builder.length-> B End)))

(define finish
  {builder --> view}
  B ->
    (let Old (builder-view B)
         Out (slice Old 0 (builder.length B))
      (do (builder.storage-> B (option.none)) Out)))

)
