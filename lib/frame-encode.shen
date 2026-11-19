(shen.x.namespace frame
  (use buffer)
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

(define encode
  {fixnum --> buffer.view --> fixnum --> buffer.view}
  Tag Payload Limit ->
    (let T (tag Tag)
         Max (limit Limit)
         N (buffer.length Payload)
         _ (if (fx<= N Max) true (error "frame: payload exceeds limit"))
         Out (buffer.new (fx+ 6 N))
      (do (buffer.u16-be-> Out 0 T)
          (buffer.u32-be-> Out 2 N)
          (buffer.copy-into! Out 6 Payload 0 N)
          Out)))

)
