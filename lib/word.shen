\\ 64-bit words, whose arithmetic wraps, for typed code: module word (docs/word.md).
\\
\\ Typed code keeps a word in a word register, where each operation here is one instruction. A word
\\ that leaves them, passed to or returned from a function that is not inlined, or kept, is boxed as a
\\ byte buffer of its 8 bytes, little-endian, which these operations take and give elsewhere, and =
\\ compares by value. Words are for computing, as hashes and random numbers do: get and set keep them
\\ in bytes. Each operation is one shen-jit.word-op, which the lowerer knows by its first argument,
\\ or a copy of 8 bytes for set. The names are the namespace's, and shadow the kernel's where they
\\ share one: (import word t => word + * shr) brings them into another namespace.

(shen.x.namespace word
  (use shen-jit)
  (shadow + - * < <= > >= get set)
  (externals [buffer.storage wof wfixnum wfloat wget w+ w- w* wand wor wxor wshl wshr wsar wrotl wrotr
              w< w<= wu< wu<=])
  (export t of to-fixnum to-float + - * bit-and bit-or bit-xor bit-not shl shr sar rotl rotr
          < <= > >= u< u<= u> u>= get set)

\\ A fixnum as a word, and back, which raises integer overflow for a word that is no fixnum.
(define of X -> (shen-jit.word-op wof X 0))
(define to-fixnum W -> (shen-jit.word-op wfixnum W 0))
(define to-float W -> (shen-jit.word-op wfloat W 0))

(define + A B -> (shen-jit.word-op w+ A B))
(define - A B -> (shen-jit.word-op w- A B))
(define * A B -> (shen-jit.word-op w* A B))
(define bit-and A B -> (shen-jit.word-op wand A B))
(define bit-or A B -> (shen-jit.word-op wor A B))
(define bit-xor A B -> (shen-jit.word-op wxor A B))

\\ Shifts and rotates by N modulo 64: shr brings in zeros and sar the sign.
(define shl A N -> (shen-jit.word-op wshl A N))
(define shr A N -> (shen-jit.word-op wshr A N))
(define sar A N -> (shen-jit.word-op wsar A N))
(define rotl A N -> (shen-jit.word-op wrotl A N))
(define rotr A N -> (shen-jit.word-op wrotr A N))

\\ Comparisons, of words as signed and, with u, as unsigned.
(define < A B -> (shen-jit.word-op w< A B))
(define <= A B -> (shen-jit.word-op w<= A B))
(define u< A B -> (shen-jit.word-op wu< A B))
(define u<= A B -> (shen-jit.word-op wu<= A B))

\\ The word in 8 bytes at I, and bytes with W there.
(define get B I -> (shen-jit.word-op wget B I))
(define set B I W -> (shen-jit.copy-bytes B I W 0 8))

(declare of [fixnum --> t])
(declare to-fixnum [t --> fixnum])
(declare to-float [t --> float])
(map (/. F (declare F [t --> [t --> t]]))
     [+ - * bit-and bit-or bit-xor])
(map (/. F (declare F [t --> [fixnum --> t]]))
     [shl shr sar rotl rotr])
(map (/. F (declare F [t --> [t --> boolean]]))
     [< <= u< u<=])
(declare get [buffer.storage --> [fixnum --> t]])
(declare set [buffer.storage --> [fixnum --> [t --> buffer.storage]]])

)
