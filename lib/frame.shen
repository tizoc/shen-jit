\\ Bounded binary messages over our own I/O reader. Module frame.
\\ Wire format: unsigned big-endian tag (2 bytes), payload length (4 bytes), payload.
\\ One task owns the framer and its reader. EOF and framing/transport errors are terminal.

(shen.x.namespace frame
  (import result ok err)
  (use result)
  (use buffer)
  (use io)
  (use option)
  (use shen-jit)
  (import struct defstruct)
  (shadow limit)
  (export frame frame? encode next position reader)

(defstruct frame (_ : fixnum) (_ : buffer.view))

\\ A framer: its borrowed I/O reader, payload limit, terminal result and in-flight flag.
(define show-reader
  F -> (make-string "#<frame reader limit ~A>" (reader.limit F)))

(defstruct reader
  (printer show-reader)
  (input : io.reader)
  (limit : fixnum)
  (mutable terminal : (option.t (result.t (io.error * (option.t frame)))))
  (mutable busy : boolean))

(preclude [reader.%match])

)
