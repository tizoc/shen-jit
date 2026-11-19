(shen.x.namespace frame
  (use buffer)
  (import layout deflayout write-layout)
  (shadow limit)
  (export encode)

\\ A tag, then the payload's length; the payload follows.
(deflayout header
  (tag 16) (length 32))

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
         Out (buffer.new (fx+ (header.size) N))
      (do (write-layout header Out 0 (tag T) (length N))
          (buffer.copy-into! Out (header.size) Payload 0 N)
          Out)))

)
