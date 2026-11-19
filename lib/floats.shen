\\ Arrays of doubles, unboxed, indexed by element: module floats (docs/floats.md).
\\
\\ A floats.t is a byte buffer of 8 bytes for each double, as shen-jit.bytes and memory.alloc make,
\\ so memory, mmap and the FFI take one as it is (bytes, of-bytes). In typed code, get and set read
\\ and write a double in a register at the element's index, which the access scales, with one check
\\ of the index against the length in doubles (docs/bytecode.md); elsewhere they box it, as
\\ shen-jit.f64 does. Each definition is small, so it inlines where it is sealed. The names are the
\\ namespace's: (import floats get set) or (use floats => f) brings them in.

(shen.x.namespace floats
  (use shen-jit)
  (shadow get set length)
  (externals [buffer.storage])
  (export t new get set length bytes of-bytes of-list to-list)

\\ The double at index I.
(define get
  V I -> (shen-jit.f64 V (fx* I 8)))

\\ V with X at index I.
(define set
  V I X -> (do (shen-jit.f64! V (fx* I 8) X) V))

\\ V as the bytes it is, and bytes as doubles.
(define bytes
  V -> V)

(define of-bytes
  B -> B)

(declare get [t --> [fixnum --> float]])
(declare set [t --> [fixnum --> [float --> t]]])
(declare bytes [t --> buffer.storage])
(declare of-bytes [buffer.storage --> t])

)
