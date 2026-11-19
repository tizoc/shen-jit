\\ Absolute operation budgets in integer milliseconds, with an injectable frozen clock.
\\ No FFI is needed here. Module deadline; module clock supplies a system clock.

(shen.x.namespace deadline
  (use buffer)
  (use io)
  (use shen-jit)
  (import struct defstruct)
  (externals [deadline])
  (export after check expired? remaining slice within)

\\ A budget: its clock, absolute end, the last clock reading, and a guard that an image reload clears.
(define show
  D -> (make-string "#<deadline end ~A>" (deadline.end D)))

(defstruct deadline
  (printer show)
  (clock : (lazy number))
  (end : number)
  (mutable now : number)
  (guard : buffer.storage))

(preclude [deadline.%match])

(define make-guard
  -> (shen-jit.bytes->pointer (shen-jit.u32! (shen-jit.bytes 8) 0 1) 0 deadline))

\\ This single slot contains 1, so loading it as a pointer cannot return [].
(declare make-guard [--> buffer.storage])

)
