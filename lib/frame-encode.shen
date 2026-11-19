(shen.x.namespace frame
  (use buffer)
  (use shen-jit)
  (shadow limit)
  (export encode)

(define limit
  {fixnum --> fixnum}
  Limit ->
    (let N (buffer.index Limit)
      (if (fx<= N 4294967295) N (error "frame: payload limit exceeds the wire format"))))

(define tag
  {fixnum --> fixnum}
  Tag ->
    (let N (buffer.index Tag)
      (if (fx<= N 65535) N (error "frame: tag exceeds 65535"))))

(define header
  {fixnum --> fixnum --> buffer.view}
  Tag Length ->
    (let H (buffer.new 6)
         _ (buffer.u8! H 0 (shen-jit.shift-right Tag 8))
         _ (buffer.u8! H 1 (shen-jit.bit-and Tag 255))
      (put-uint H 2 4 Length)))

(define put-uint
  {buffer.view --> fixnum --> fixnum --> fixnum --> buffer.view}
  V _ 0 _ -> V
  V Start Count N ->
    (do (buffer.u8! V (fx+ Start (fx- Count 1)) (shen-jit.bit-and N 255))
        (put-uint V Start (fx- Count 1) (shen-jit.shift-right N 8))))

(define encode
  {fixnum --> buffer.view --> fixnum --> buffer.view}
  Tag Payload Limit ->
    (let T (tag Tag)
         Max (limit Limit)
         N (buffer.length Payload)
         _ (if (fx<= N Max) true (error "frame: payload exceeds limit"))
         Out (buffer.new (fx+ 6 N))
      (do (buffer.copy! Out 0 (header T N) 0 6)
          (buffer.copy! Out 6 Payload 0 N)
          Out)))

)
