\\ A string's bytes hashed in place: shen-jit.xxh64 reads strings as it reads buffers, which
\\ typed code cannot pass it, and copying each key to a buffer first would cost more than hashing.
(shen.x.namespace hyperloglog
  (use shen-jit)
  (externals [buffer.storage])

(define hash-string
  Out Text -> (shen-jit.xxh64 Out Text 0 (shen-jit.bytes-length Text) 1))

(declare hash-string [buffer.storage --> [string --> buffer.storage]])
)
