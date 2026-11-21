\\ Scans and conversions over a range of bytes, written as native code: module bytes (docs/bytes.md).
\\
\\ Each takes the storage B, a string, a byte buffer or memory, and a range At to End of it, every read
\\ checked as any is, and gives a fixnum, a boolean or a value it made: what crosses a call without
\\ being boxed. One call does the whole range, which is where native code gains on a loop in Shen.

(shen.x.namespace bytes
  (use shen-jit)
  (externals [buffer.storage fixnum bytes.class define-native word vector splat v= v128 vmask ctz != vand vor const
              vshr vlookup
              for when unless while return return-word u8 u8!
              prim bit-and bit-or bit-not shift-right shift-left u< u> u<= u>=])
  (shadow find)
  (export class class-not find span span-back lower! lower hex unhex! decimal)

\\ The first Byte from At, or End. A range of 16 bytes or more is read 16 at a time, and its last
\\ 16 bytes once more at the end, which covers what is left over: what they hold before I was
\\ read already, and held no Byte.
(define-native find (B At End Byte)
  (word I At)
  (word Last (- End 16))
  (when (<= I Last)
    (vector Needle (splat Byte))
    (while (< I Last)
      (word Hits (vmask (v= (v128 B I) Needle)))
      (when (!= Hits 0) (return-word (+ I (ctz Hits))))
      (word I (+ I 16)))
    (word Hits (vmask (v= (v128 B Last) Needle)))
    (when (!= Hits 0) (return-word (+ Last (ctz Hits))))
    (return End))
  (word X Byte)
  (for J I End
    (when (= (u8 B J) X) (return-word J)))
  (return End))

\\ A class is a string of 96 bytes: the set of bytes whose bits are set in its first 32, then the
\\ same set as two tables of 16 for vectors, by a byte's low four bits: bit H of the first is set
\\ when the byte with high four bits H, from 0 to 7, is in the set, and of the second, H from 8 to
\\ 15; then, by the high four bits, the bit each has in those. class makes one from a list of strings, whose bytes it holds, bytes, and [Lo Hi] for the bytes
\\ from Lo to Hi. Written with a list of constants, (bytes.class [...]) is made as the code is read,
\\ so that the class is a constant of the code, which every isolate has: a global would be unbound
\\ in another.
(define class
  Members -> (class-tables (class-add (shen-jit.bytes 32) Members)))

(define class-tables
  Bits -> (let Out (shen-jit.copy-bytes (shen-jit.bytes 96) 0 Bits 0 32)
               _ (high-bits-fill Out 64 0)
               _ (high-bits-fill Out 88 0)
            (shen-jit.bytes->string (nibble-tables Bits Out 0) 0 96)))

(define nibble-tables
  _ Out 256 -> Out
  Bits Out Byte -> (let At (+ (+ 32 (shen-jit.bit-and Byte 15)) (if (>= Byte 128) 16 0))
                        Bit (shen-jit.shift-left 1 (shen-jit.bit-and (shen-jit.shift-right Byte 4) 7))
                     (nibble-tables Bits
                       (if (member? Bits Byte) (shen-jit.u8! Out At (shen-jit.bit-or (shen-jit.u8 Out At) Bit)) Out)
                       (+ Byte 1))))

(define member?
  Bits Byte -> (= 1 (shen-jit.bit-and 1 (shen-jit.shift-right (shen-jit.u8 Bits (shen-jit.shift-right Byte 3))
                                                              (shen-jit.bit-and Byte 7)))))

\\ For a byte's high four bits H, the bit H has in the tables, from 0 to 7 at 64 and from 8 to 15 at
\\ 80: the same in every class, there to be read with the class's own memory, which is checked once.
(define high-bits-fill
  Out _ 8 -> Out
  Out From K -> (high-bits-fill (shen-jit.u8! Out (+ From K) (shen-jit.shift-left 1 K)) From (+ K 1)))

(defmacro class-macro
  [bytes.class Members] -> (class (eval Members)) where (constant? Members))

(define constant?
  [cons A B] -> (and (constant? A) (constant? B))
  X -> (or (number? X) (string? X) (empty? X)))

(define class-add
  C [] -> C
  C [[Lo Hi] | Members] -> (class-add (class-range C Lo Hi) Members)
  C [M | Members] -> (class-add (class-range C M M) Members) where (integer? M)
  C [S | Members] -> (class-add (class-string C (shen-jit.string->bytes S) 0) Members) where (string? S)
  _ [M | _] -> (error "bytes.class: ~S is not a string, a byte or [Lo Hi]" M))

(define class-range
  C Lo Hi -> (if (> Lo Hi) C (class-range (class-put C Lo) (+ Lo 1) Hi)))

(define class-string
  C S I -> (if (= I (shen-jit.bytes-length S)) C (class-string (class-put C (shen-jit.u8 S I)) S (+ I 1))))

(define class-put
  C Byte -> (let At (shen-jit.shift-right Byte 3)
              (shen-jit.u8! C At (shen-jit.bit-or (shen-jit.u8 C At)
                                                  (shen-jit.shift-left 1 (shen-jit.bit-and Byte 7))))))

\\ The bytes not in C.
(define class-not
  C -> (class-tables (class-invert C (shen-jit.bytes 32) 0)))

(define class-invert
  _ Out 32 -> Out
  C Out I -> (class-invert C (shen-jit.u8! Out I (- 255 (shen-jit.u8 C I))) (+ I 1)))

\\ The first byte from At not in Class, or End: (span B At End (class-not C)) finds one in C. The first
\\ 8 bytes are tested one at a time, as most runs end within them and a grammar gives its input's
\\ end, which lies far beyond; a longer range is read 16 at a time, the last of them ending at End,
\\ and a byte is in the class when the bit of its high four bits is set in the tables by its low four.
(define-native span (B At End Class)
  (word E End)
  (word I (+ At 8))
  (when (> I E) (word I E))
  (for J At I
    (word C (u8 B J))
    (when (= (bit-and (u8 Class (shift-right C 3)) (shift-left 1 (bit-and C 7))) 0)
      (return-word J)))
  (word Last (- E 16))
  (when (<= I Last)
    (vector Low0 (v128 Class 32))
    (vector Low1 (v128 Class 48))
    (vector High0 (v128 Class 64))
    (vector High1 (v128 Class 80))
    (vector Nibble (splat 15))
    (vector Zero (splat 0))
    (while (< I E)
      (when (> I Last) (word I Last))
      (vector X (v128 B I))
      (vector L (vand X Nibble))
      (vector H (vshr X 4))
      (vector In (vand (vlookup Low0 L) (vlookup High0 H)))
      (vector X (vand (vlookup Low1 L) (vlookup High1 H)))
      (word C (vmask (v= (vor In X) Zero)))
      (when (!= C 0) (return-word (+ I (ctz C))))
      (word I (+ I 16)))
    (return End))
  (for J I E
    (word C (u8 B J))
    (when (= (bit-and (u8 Class (shift-right C 3)) (shift-left 1 (bit-and C 7))) 0)
      (return-word J)))
  (return End))

\\ The least I from Start such that the bytes from I to End are all in Class.
(define-native span-back (B Start End Class)
  (word S Start)
  (word I End)
  (while (> I S)
    (word C (u8 B (- I 1)))
    (when (= (bit-and (u8 Class (shift-right C 3)) (shift-left 1 (bit-and C 7))) 0)
      (return-word I))
    (word I (- I 1)))
  (return Start))

\\ B with the ASCII capitals from At to End made small, in place: B is a buffer, not a string.
(define-native lower! (B At End)
  (for I At End
    (word C (u8 B I))
    (when (u<= (- C 65) 25)
      (u8! B I (+ C 32))))
  (return B))

\\ Text with its ASCII capitals made small.
(define lower
  Text -> (let B (shen-jit.string->bytes Text)
               N (shen-jit.bytes-length B)
            (shen-jit.bytes->string (lower! B 0 N) 0 N)))

\\ The bytes from At to End as a string of small hexadecimal digits, two a byte. A digit D is
\\ D + 48, and 39 more from 10, which is when D + 6 reaches 16.
(define-native hex (B At End)
  (prim N - End At)
  (prim Size * N 2)
  (prim Out shen-jit.bytes Size)
  (word K 0)
  (for I At End
    (word C (u8 B I))
    (word H (shift-right C 4))
    (word L (bit-and C 15))
    (u8! Out K (+ H 48 (* 39 (shift-right (+ H 6) 4))))
    (u8! Out (+ K 1) (+ L 48 (* 39 (shift-right (+ L 6) 4))))
    (word K (+ K 2)))
  (prim S shen-jit.bytes->string Out 0 Size)
  (return S))

\\ The bytes that the hexadecimal digits from At to End stand for, either case, stored from I in
\\ To, which it gives; [] for an odd count or a byte that is no digit, with To changed up to it.
(define-native unhex! (To I B At End)
  (word J At)
  (word E End)
  (when (= (bit-and (- E J) 1) 1) (return []))
  (word K I)
  (while (< J E)
    (word C (u8 B J))
    (word H 16)
    (when (u<= (- C 48) 9) (word H (- C 48)))
    (when (u<= (- C 97) 5) (word H (- C 87)))
    (when (u<= (- C 65) 5) (word H (- C 55)))
    (word C (u8 B (+ J 1)))
    (word L 16)
    (when (u<= (- C 48) 9) (word L (- C 48)))
    (when (u<= (- C 97) 5) (word L (- C 87)))
    (when (u<= (- C 65) 5) (word L (- C 55)))
    (when (u> (bit-or H L) 15) (return []))
    (u8! To K (+ (shift-left H 4) L))
    (word K (+ K 1))
    (word J (+ J 2)))
  (return To))

\\ The decimal number the digits from At to End make, up to Limit, at least 0: -1 if there are
\\ none or a byte is no digit, and -2 if the number is more than Limit.
(define-native decimal (B At End Limit)
  (when (>= At End) (return -1))
  (prim Tens shen-jit.quotient Limit 10)
  (prim Units shen-jit.remainder Limit 10)
  (word T Tens)
  (word R Units)
  (word V 0)
  (for I At End
    (word D (- (u8 B I) 48))
    (when (u> D 9) (return -1))
    (when (or (u> V T) (and (= V T) (u> D R))) (return -2))
    (word V (+ (* V 10) D)))
  (return-word V))

(declare find [buffer.storage --> [fixnum --> [fixnum --> [fixnum --> fixnum]]]])
(declare span [buffer.storage --> [fixnum --> [fixnum --> [string --> fixnum]]]])
(declare span-back [buffer.storage --> [fixnum --> [fixnum --> [string --> fixnum]]]])
(declare lower! [buffer.storage --> [fixnum --> [fixnum --> buffer.storage]]])
(declare lower [string --> string])
(declare hex [buffer.storage --> [fixnum --> [fixnum --> string]]])
(declare decimal [buffer.storage --> [fixnum --> [fixnum --> [fixnum --> fixnum]]]])
(declare class-not [string --> string])
)
