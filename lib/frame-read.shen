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

\\ Decode from the header's own storage without checking a view at each byte.
(define uint
  {buffer.storage --> fixnum --> fixnum --> fixnum --> fixnum}
  _ _ 0 N -> N
  B At Count N -> (uint B (fx+ At 1) (fx- Count 1) (fx+ (fx* N 256) (shen-jit.u8 B At))))

(define reader
  {io.reader --> fixnum --> reader}
  R Limit ->
    (let Max (limit Limit)
         _ (io.reader-check R)
      (:reader input <- R limit <- Max terminal <- (option.none) busy <- false)))

(define check
  {reader --> reader}
  F ->
    (let _ (if (reader? F) true (error "frame: not a reader"))
         _ (if (reader.busy F) (error "frame: operation is already in flight") true)
         _ (io.reader-check (reader.input F))
      F))

(define position
  {reader --> fixnum}
  F -> (io.position (reader.input (check F))))

(define frame.error
  {string --> fixnum --> (io.result (option.t frame))}
  Message Progress ->
    (:err (io.progress (io.error (with-externals [frame] frame) "binary frame" Message) Progress)))

(define finish
  {reader --> (io.result (option.t frame)) --> (io.result (option.t frame))}
  _ (:ok [(:frame Tag Payload)]) -> (:ok (option.some (:frame Tag Payload)))
  F Terminal -> (do (reader.terminal-> F (option.some Terminal)) Terminal))

(define cache-error
  {reader --> string --> fixnum --> reader}
  F Message Progress -> (reader.terminal-> F (option.some (frame.error Message Progress))))

(define read-payload
  {fixnum --> buffer.view --> (io.result io.transfer) --> (io.result (option.t frame))}
  Tag Payload (:ok (:io.transfer true _)) -> (:ok (option.some (:frame Tag Payload)))
  _ _ (:ok (:io.transfer false N)) -> (frame.error "incomplete payload" (fx+ 6 N))
  _ _ (:err Error) -> (:err (io.progress Error (fx+ 6 (io.error-progress Error)))))

(define read-header
  {reader --> buffer.storage --> (io.result io.transfer) -->
   (io.result (option.t frame))}
  _ _ (:ok (:io.transfer false 0)) -> (:ok (option.none))
  _ _ (:ok (:io.transfer false N)) -> (frame.error "incomplete header" N)
  _ _ (:err Error) -> (:err Error)
  F B (:ok (:io.transfer true 6)) ->
    (let Tag (uint B 0 2 0)
         N (uint B 2 4 0)
      (if (fx> N (reader.limit F))
          (frame.error "payload exceeds limit" 6)
          (let Payload (buffer.new N)
            (read-payload Tag Payload (io.reader-exact (reader.input F) Payload))))))

(define next-or-terminal
  {reader --> (option.t (io.result (option.t frame))) -->
   (io.result (option.t frame))}
  _ [Terminal] -> Terminal
  F [] ->
    (let B (shen-jit.bytes 6)
         Start (io.position (reader.input F))
         _ (reader.busy-> F true)
         Result (trap-error (read-header F B (io.reader-exact (reader.input F) (buffer.wrap B)))
                  (/. X (do (reader.busy-> F false)
                            \\ Record how much of this frame was read before the exception.
                            (cache-error F (error-to-string X)
                              (trap-error (fx- (io.position (reader.input F)) Start) (/. E 0)))
                            (simple-error (error-to-string X)))))
      (do (reader.busy-> F false) (finish F Result))))

(define next
  {reader --> (io.result (option.t frame))}
  F -> (next-or-terminal (check F) (reader.terminal F)))

)
