\\ One bounded HTTP head through CRLFCRLF, over our own reader. Module http.
\\ This frames bytes; request-line/field semantics and body framing belong to a complete parser.
\\ deadline.shen is needed only by http.read-head-until.

(shen.x.namespace http
  (use result)
  (use buffer)
  (use io)
  (use option)
  (import struct defstruct)
  (export head-reader read-head read-head-until)

\\ A head reader: its borrowed reader, byte limit, accumulator, used count, CRLF state, saved
\\ result and busy flag.
(define show-head
  F -> (make-string "#<head-reader ~A/~A bytes>" (head-reader.used F) (head-reader.limit F)))

(defstruct head-reader
  (printer show-head)
  (reader : io.reader)
  (limit : fixnum)
  (mutable storage : (option.t buffer.view))
  (mutable used : fixnum)
  (mutable crlf : fixnum)
  (mutable result : (option.t (result.t (io.error * (option.t buffer.view)))))
  (mutable busy : boolean))

(preclude [head-reader.%match])

(synonyms wait-result (result.t (io.error * result.empty)))

)
