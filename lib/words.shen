\\ Arrays of 64-bit words, unboxed, indexed by element: module words (docs/words.md).
\\
\\ A words.t is a byte buffer of 8 bytes for each word, little-endian, as shen-jit.bytes and
\\ memory.alloc make, so memory, mmap and the FFI take one as it is (bytes, of-bytes). In typed
\\ code, get and set read and write a word in a register at the element's index, which the access
\\ scales, with one check of the index against the length in words (docs/bytecode.md); elsewhere
\\ they box it, as word.get does. Each definition is small, so it inlines where it is sealed. The
\\ names are the namespace's: (import words get set) or (use words => ws) brings them in.

(shen.x.namespace words
  (use shen-jit)
  (shadow get set length)
  (externals [buffer.storage word.t wget])
  (export t new get set length bytes of-bytes of-list to-list)

\\ The word at index I, and V with W there: word.get and word.set at 8 times I, written out so that
\\ the lowerer sees the product at the access and scales the index there.
(define get
  V I -> (shen-jit.word-op wget V (fx* I 8)))

(define set
  V I W -> (shen-jit.copy-bytes V (fx* I 8) W 0 8))

\\ V as the bytes it is, and bytes as words.
(define bytes
  V -> V)

(define of-bytes
  B -> B)

(declare get [t --> [fixnum --> word.t]])
(declare set [t --> [fixnum --> [word.t --> t]]])
(declare bytes [t --> buffer.storage])
(declare of-bytes [buffer.storage --> t])

)
