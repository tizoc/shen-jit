\\ Checked byte views over managed bytes or a sized pointer. No FFI library is needed.
\\ A view borrows the exact storage object; it never copies a pointer or releases storage.
\\ Closing that original pointer makes subsequent view operations raise. Independently
\\ copied pointers and closing storage during a native call remain the caller's responsibility.
\\ The module loads the typed view operations and builder after their schemas.

(shen.x.namespace buffer
  (use shen-jit)
  (use option)
  (import struct defstruct)
  (shadow index length)
  (export append! append-byte! builder builder-length bytes copy-into!
    buffer.cursor => cursor equal? finish from-string make new slice storage buffer.string => string wrap)

(define make
  Storage Start End -> (view.make Storage Start End))

(defstruct builder
  (limit : fixnum)
  (mutable storage : (option.t view))
  (mutable length : fixnum))

(preclude [builder.%match])

)
