(shen.x.namespace hyperloglog
  (use buffer)
  (use shen-jit)
  (import word shl => wshl shr => wshr to-fixnum => wfix get => wget)
  (externals [word.t])
  (export hash-bytes)

\\ Keys are hashed with seed-zero XXH64, written into 8 bytes, where word.get reads it.
(define hash-bytes
  {buffer.view --> word.t}
  View ->
    (let Checked (buffer.check View)
         Start (buffer.view.start Checked)
      (wget (shen-jit.xxh64 (shen-jit.bytes 8) (buffer.view.owner Checked) Start
                            (fx- (buffer.view.end Checked) Start) 1)
            0)))

(define hash-index
  {word.t --> fixnum --> fixnum}
  H P -> (wfix (wshr H (fx- 64 P))))

\\ The rank is one more than the leading zeros of the 64 - P bits after the index. Shifted right
\\ by three, they fit a fixnum whose top bit is zero, and shen-jit.clz, counting 62 bits, counts
\\ that bit too: the one. The bit at 1 << (P - 4) stops an all-zero suffix at 65 - P.
(define hash-rank
  {word.t --> fixnum --> fixnum}
  H P ->
    (shen-jit.clz
      (shen-jit.bit-or (wfix (wshr (wshl H P) 3))
                      (shen-jit.shift-left 1 (fx- P 4)))))

(define pack-hash
  {word.t --> fixnum --> fixnum}
  H P -> (shen-jit.bit-or (shen-jit.shift-left (hash-index H P) 6) (hash-rank H P)))
)
