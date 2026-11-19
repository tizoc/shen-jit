(shen.x.namespace clock
  (use deadline)
  (use buffer)
  (use shen-jit)
  (externals [deadline])
  (export clock.deadline => deadline monotonic)

(define clock.deadline
  {number --> deadline}
  Milliseconds -> (deadline.after (freeze (monotonic)) Milliseconds))

(define monotonic
  {--> number}
  -> (monotonic-on (os)))

(define monotonic-on
  {string --> number}
  "Windows" -> (fx->number (buffer.index (fixnum (c-ticks))))
  "Linux" -> (posix-monotonic 1)
  "macOS" -> (posix-monotonic 6)
  OS -> (error "clock: unsupported OS ~A" OS))

(define posix-monotonic
  {number --> number}
  Kind ->
    (let B (shen-jit.bytes 16)
         Result (c-monotonic Kind B)
         Code (shen-jit.c-errno)
         _ (if (= Result 0) true (error "clock: clock_gettime failed: ~A" Code))
         Seconds (fx->number (buffer.index (shen-jit.s64 B 0)))
         Nanos (buffer.index (shen-jit.s64 B 8))
         Millis (fx->number (fxquotient Nanos 1000000))
      (+ (* Seconds 1000) Millis)))

)
