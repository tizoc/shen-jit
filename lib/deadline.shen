\\ Absolute operation budgets in integer milliseconds, with an injectable frozen clock.
\\ No FFI is needed here. Load buffer.shen and io.shen first; clock.shen supplies a system clock.

(shen.x.namespace deadline
  (use buffer)
  (use io)
  (use shen-jit)
  (externals [deadline])
  (export after check expired? remaining slice within)

(define after
  Clock Milliseconds ->
    (let Duration (buffer.index Milliseconds)
         Now (buffer.index (thaw Clock))
         End (+ Now Duration)
         Guard (shen-jit.bytes->pointer (shen-jit.u32! (shen-jit.bytes 8) 0 1) 0 deadline)
      (io.record [deadline Clock End Now Guard])))

(define check
  D ->
    (let _ (if (io.tag? D deadline) true (error "deadline: not a deadline"))
         _ (if (= (shen-jit.pointer-address (<-address D 4)) 0)
               (error "deadline: saved budgets must be recreated")
               true)
      D))

\\ Derive a phase budget from the same clock reading, without extending its parent.
(define within
  Parent Milliseconds ->
    (let _ (check Parent)
         Duration (buffer.index Milliseconds)
         Clock (<-address Parent 1)
         Now (buffer.index (thaw Clock))
         _ (if (< Now (<-address Parent 3)) (error "deadline: clock moved backwards") true)
         _ (address-> Parent 3 Now)
         Left (- (<-address Parent 2) Now)
         Span (if (< Left 0) 0 (if (< Left Duration) Left Duration))
         Guard (shen-jit.bytes->pointer (shen-jit.u32! (shen-jit.bytes 8) 0 1) 0 deadline)
      (io.record [deadline Clock (+ Now Span) Now Guard])))

(define remaining
  D ->
    (let _ (check D)
         Clock (<-address D 1)
         Now (buffer.index (thaw Clock))
         _ (if (< Now (<-address D 3)) (error "deadline: clock moved backwards") true)
         _ (address-> D 3 Now)
         Left (- (<-address D 2) Now)
      (if (> Left 0) Left 0)))

(define expired?
  D -> (= (remaining D) 0))

(define slice
  D Maximum ->
    (let Max (buffer.index Maximum)
         _ (if (> Max 0) true (error "deadline: slice must be positive"))
         Left (remaining D)
      (if (< Left Max) Left Max)))

(declare after [[lazy number] --> [number --> deadline]])
(declare within [deadline --> [number --> deadline]])
(declare remaining [deadline --> number])
(declare expired? [deadline --> boolean])
(declare slice [deadline --> [number --> number]])

)
