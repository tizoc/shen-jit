\\ A mutable position over a fixed byte view. Module cursor.
\\ One task owns a cursor; fork shares bytes but has an independent position.
\\ A local byte boundary returns -1, without making any claim about transport EOF.

(shen.x.namespace cursor
  (use buffer)
  (import struct defstruct)
  (externals [buffer.cursor buffer.cursor.position buffer.cursor.%match])
  (shadow fork read)
  (export buffer bytes cursor? fork new offset peek position read remaining seek skip
    cursor.string => string view)

(define show
  C -> (make-string "#<cursor at ~A>" (buffer.cursor.position C)))

(defstruct buffer.cursor
  (printer show)
  (view : buffer.view)
  (mutable position : fixnum))

(preclude [buffer.cursor.%match])

)
