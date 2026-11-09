\\ Absolute operation budgets in integer milliseconds, with an injectable frozen clock.
\\ No FFI is needed here. Load buffer.shen and io.shen first; clock.shen supplies a system clock.

(shen.x.namespace deadline
  (use buffer)
  (use io)
  (use shen-jit)
  (import struct defstruct)
  (externals [deadline])
  (export after check expired? remaining slice within)

\\ A budget: its clock, absolute end, the last clock reading, and a guard that an image reload clears.
(define show
  D -> (make-string "#<deadline end ~A>" (budget.end D)))

(defstruct budget
  (printer show)
  clock
  end
  (mutable now)
  guard)

(define after
  Clock Milliseconds ->
    (let Duration (buffer.index Milliseconds)
         Now (buffer.index (thaw Clock))
         End (+ Now Duration)
         Guard (shen-jit.bytes->pointer (shen-jit.u32! (shen-jit.bytes 8) 0 1) 0 deadline)
      (budget.make Clock End Now Guard)))

(define check
  D ->
    (let _ (if (budget? D) true (error "deadline: not a deadline"))
         _ (if (= (shen-jit.pointer-address (budget.guard D)) 0)
               (error "deadline: saved budgets must be recreated")
               true)
      D))

\\ Derive a phase budget from the same clock reading, without extending its parent.
(define within
  Parent Milliseconds ->
    (let _ (check Parent)
         Duration (buffer.index Milliseconds)
         Clock (budget.clock Parent)
         Now (buffer.index (thaw Clock))
         _ (if (< Now (budget.now Parent)) (error "deadline: clock moved backwards") true)
         _ (budget.now-> Parent Now)
         Left (- (budget.end Parent) Now)
         Span (if (< Left 0) 0 (if (< Left Duration) Left Duration))
         Guard (shen-jit.bytes->pointer (shen-jit.u32! (shen-jit.bytes 8) 0 1) 0 deadline)
      (budget.make Clock (+ Now Span) Now Guard)))

(define remaining
  D ->
    (let _ (check D)
         Clock (budget.clock D)
         Now (buffer.index (thaw Clock))
         _ (if (< Now (budget.now D)) (error "deadline: clock moved backwards") true)
         _ (budget.now-> D Now)
         Left (- (budget.end D) Now)
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
