(shen.x.namespace deadline
  (use buffer)
  (use shen-jit)
  (externals [deadline deadline?])
  (export after check expired? remaining slice within)

(define after
  {(lazy number) --> number --> deadline}
  Clock Milliseconds ->
    (let Duration (fx->number (buffer.index (fixnum Milliseconds)))
         Now (fx->number (buffer.index (fixnum (thaw Clock))))
         End (+ Now Duration)
         Guard (make-guard)
      (:deadline clock <- Clock end <- End now <- Now guard <- Guard)))

(define guard-live?
  {buffer.storage --> boolean}
  Guard -> (not (= (shen-jit.pointer-address Guard) 0)))

(define check
  {deadline --> deadline}
  D ->
    (let _ (if (deadline? D) true (error "deadline: not a deadline"))
         _ (if (not (guard-live? (deadline.guard D)))
               (error "deadline: saved budgets must be recreated")
               true)
      D))

\\ Derive a phase budget from the same clock reading, without extending its parent.
(define within
  {deadline --> number --> deadline}
  Parent Milliseconds ->
    (let _ (check Parent)
         Duration (fx->number (buffer.index (fixnum Milliseconds)))
         Clock (deadline.clock Parent)
         Now (fx->number (buffer.index (fixnum (thaw Clock))))
         _ (if (< Now (deadline.now Parent)) (error "deadline: clock moved backwards") true)
         _ (deadline.now-> Parent Now)
         Left (- (deadline.end Parent) Now)
         Span (if (< Left 0) 0 (if (< Left Duration) Left Duration))
         Guard (make-guard)
      (:deadline clock <- Clock end <- (+ Now Span) now <- Now guard <- Guard)))

(define remaining
  {deadline --> number}
  D ->
    (let _ (check D)
         Clock (deadline.clock D)
         Now (fx->number (buffer.index (fixnum (thaw Clock))))
         _ (if (< Now (deadline.now D)) (error "deadline: clock moved backwards") true)
         _ (deadline.now-> D Now)
         Left (- (deadline.end D) Now)
      (if (> Left 0) Left 0)))

(define slice
  {deadline --> number --> number}
  D Maximum ->
    (let Max (fx->number (buffer.index (fixnum Maximum)))
         _ (if (> Max 0) true (error "deadline: slice must be positive"))
         Left (remaining D)
      (if (< Left Max) Left Max)))

(define expired?
  {deadline --> boolean}
  D -> (= (remaining D) 0))

)
