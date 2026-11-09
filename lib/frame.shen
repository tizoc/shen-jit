\\ Bounded binary messages over our own I/O reader. Load buffer.shen and io.shen first.
\\ Wire format: unsigned big-endian tag (2 bytes), payload length (4 bytes), payload.
\\ One task owns the framer and its reader. EOF and framing/transport errors are terminal.

(shen.x.namespace frame
  (use buffer)
  (use io)
  (use shen-jit)
  (externals [eof frame frame-results ok])
  (shadow limit)
  (export encode next position reader result)

(define limit
  Limit ->
    (let N (buffer.index Limit)
      (if (<= N 4294967295) N (error "frame: payload limit exceeds the wire format"))))

(define tag
  Tag ->
    (let N (buffer.index Tag)
      (if (<= N 65535) N (error "frame: tag exceeds 65535"))))

(define header
  Tag Length ->
    (let H (buffer.new 6)
         _ (buffer.u8! H 0 (shen-jit.shift-right Tag 8))
         _ (buffer.u8! H 1 (shen-jit.bit-and Tag 255))
      (put-uint H 2 4 Length)))

(define put-uint
  V _ 0 _ -> V
  V Start Count N ->
    (do (buffer.u8! V (+ Start (- Count 1)) (shen-jit.bit-and N 255))
        (put-uint V Start (- Count 1) (shen-jit.shift-right N 8))))

\\ Over the header's own bytes, which frame.next made: no view to check at each byte.
(define uint
  _ _ 0 N -> N
  B At Count N -> (uint B (+ At 1) (- Count 1) (+ (* N 256) (shen-jit.u8 B At))))

(define encode
  Tag Payload Limit ->
    (let T (tag Tag)
         Max (limit Limit)
         N (buffer.length Payload)
         _ (if (<= N Max) true (error "frame: payload exceeds limit"))
         Out (buffer.new (+ 6 N))
      (do (buffer.copy! Out 0 (header T N) 0 6)
          (buffer.copy! Out 6 Payload 0 N)
          Out)))

\\ Framer slots: tag, borrowed I/O reader, payload limit, terminal result, in-flight flag.
(define reader
  R Limit ->
    (let Max (limit Limit)
         _ (io.reader-check R)
      (io.record [reader R Max [] false])))

(define check
  F ->
    (let _ (if (io.tag? F reader) true (error "frame: not a reader"))
         _ (if (<-address F 4) (error "frame: operation is already in flight") true)
         _ (io.reader-check (<-address F 1))
      F))

(define position
  F -> (io.position (<-address (check F) 1)))

(define frame.error
  Message Progress ->
    [error (io.progress (io.error frame "binary frame" Message) Progress)])

(define finish
  F [frame Tag Payload] -> [frame Tag Payload]
  F Terminal -> (do (address-> F 3 Terminal) Terminal))

(define next
  F ->
    (let _ (check F)
         Terminal (<-address F 3)
      (if (not (empty? Terminal))
          Terminal
          (let B (shen-jit.bytes 6)
               _ (address-> F 4 true)
               Result (trap-error (read-header F B (io.reader-exact (<-address F 1) (buffer.wrap B)))
                        (/. X (do (address-> F 4 false)
                                  (address-> F 3 (frame.error (error-to-string X) 0))
                                  (simple-error (error-to-string X)))))
            (do (address-> F 4 false) (finish F Result))))))

(define read-header
  _ _ [eof 0] -> [eof]
  _ _ [eof N] -> (frame.error "incomplete header" N)
  _ _ [error Error N] -> [error (io.progress Error N)]
  F B [ok 6] ->
    (let Tag (uint B 0 2 0)
         N (uint B 2 4 0)
      (if (> N (<-address F 2))
          (frame.error "payload exceeds limit" 6)
          (let Payload (buffer.new N)
            (read-payload Tag Payload (io.reader-exact (<-address F 1) Payload))))))

(define read-payload
  Tag Payload [ok _] -> [frame Tag Payload]
  _ _ [eof N] -> (frame.error "incomplete payload" (+ 6 N))
  _ _ [error Error N] -> [error (io.progress Error (+ 6 N))])

(datatype frame-results
  Tag : number; Payload : buffer.view;
  ===================================
  [frame Tag Payload] : result;

  ___________________
  [eof] : result;

  Error : io.error;
  ===========================
  [error Error] : result;)

(declare encode [number --> [buffer.view --> [number --> buffer.view]]])
(declare reader [io.reader --> [number --> reader]])
(declare position [reader --> number])
(declare next [reader --> result])

)
