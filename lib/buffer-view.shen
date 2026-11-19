\\ A view: the original owner, start and exclusive end. Metadata is not mutated. Read first, under
\\ (tc -), so that buffer-typed.shen can type its checks over the struct, and buffer.shen call them.

(shen.x.namespace buffer
  (use shen-jit)
  (import struct defstruct)
  (export view view? view.end view.owner view.start)

(define show-view
  V -> (make-string "#<view ~A..~A>" (view.start V) (view.end V)))

(defstruct view
  (printer show-view)
  (owner : storage)
  (start : fixnum)
  (end : fixnum))

\\ Additional native signatures for checked view operations.
(declare shen-jit.pointer? [A --> boolean])
(declare shen-jit.pointer-address [storage --> number])
(declare shen-jit.string->bytes [string --> storage])
(declare shen-jit.bytes->string [storage --> [fixnum --> [fixnum --> string]]])
(declare shen-jit.copy-bytes [storage --> [fixnum --> [storage --> [fixnum --> [fixnum --> storage]]]]])

)
