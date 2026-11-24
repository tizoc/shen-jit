\\ Typed definitions over bytes and bits that refine (lib/refine.shen) must accept, as lib/net and
\\ lib/hyperloglog have them: loaded with buffer under (tc +) by tests/smt.sh, whose check is of
\\ refine-bytes.main.

(define-checked byte
  {B : buffer.storage --> I : fixnum --> R : fixnum}
  {requires (fx<= 0 I) (fx< I (shen-jit.bytes-length B))}
  {ensures (fx<= 0 R) (fx<= R 255)}
  B I -> (shen-jit.u8 B I))
(define-checked word
  {B : buffer.storage --> I : fixnum --> fixnum}
  {requires (fx<= 0 I) (fx<= (fx+ I 4) (shen-jit.bytes-length B))}
  B I -> (shen-jit.u32 B I))
(define-checked item
  {V : buffer.view --> I : fixnum --> fixnum}
  {requires (fx<= 0 I) (fx< I (buffer.length V))}
  V I -> (buffer.u8 V I))

\\ Shifts and masks by constants: a bit map's byte, a byte's digits, a word at a bit, a table's slot.
(define-checked marked?
  {Map : buffer.view --> At : fixnum --> boolean}
  {requires (fx<= 0 At) (fx< At (fx* 8 (buffer.length Map)))}
  Map At -> (not (fx= 0 (shen-jit.bit-and (item Map (shen-jit.shift-right At 3)) (shen-jit.shift-left 1 (shen-jit.bit-and At 7))))))
(define-checked digits
  {Table : buffer.storage --> N : fixnum --> fixnum}
  {requires (fx= (shen-jit.bytes-length Table) 16) (fx<= 0 N) (fx<= N 255)}
  Table N -> (shen-jit.bit-or (shen-jit.shift-left (byte Table (shen-jit.shift-right N 4)) 8) (byte Table (shen-jit.bit-and 15 N))))
(define-checked smaller
  {A : fixnum --> B : fixnum --> R : fixnum}
  {ensures (fx<= R A) (fx<= R B) (or (fx= R A) (fx= R B))}
  A B -> (if (fx< A B) A B))
(define-checked count-from
  {B : buffer.storage --> At : fixnum --> N : fixnum --> fixnum --> fixnum}
  {requires (fx<= 0 At) (fx<= (fx+ 4 (shen-jit.shift-right (fx+ At N) 3)) (shen-jit.bytes-length B))}
  B At N Count -> (if (fx<= N 0)
                      Count
                      (let Shift (shen-jit.bit-and At 7)
                           Take (smaller (fx- 32 Shift) N)
                           Word (shen-jit.shift-right (word B (shen-jit.shift-right At 3)) Shift)
                           Mask (fx- (shen-jit.shift-left 1 Take) 1)
                        (count-from B (fx+ At Take) (fx- N Take) (fx+ Count (shen-jit.popcount (shen-jit.bit-and Word Mask)))))))
(define-checked slot
  {B : buffer.storage --> I : fixnum --> fixnum}
  {requires (fx<= 0 I) (fx< I 4096) (fx<= (fx+ 4 (fx* 4 I)) (shen-jit.bytes-length B))}
  B I -> (word B (shen-jit.shift-left I 2)))
(define-checked next-slot
  {B : buffer.storage --> fixnum --> fixnum}
  {requires (fx= 64 (shen-jit.bytes-length B))}
  B I -> (slot B (shen-jit.bit-and (fx+ I 1) 15)))
(define-checked joined
  {B : buffer.storage --> High : fixnum --> Low : fixnum --> fixnum}
  {requires (fx<= 0 High) (fx< High 4) (fx<= 0 Low) (fx< Low 16) (fx= 79 (shen-jit.bytes-length B))}
  B High Low -> (byte B (shen-jit.bit-or (shen-jit.shift-left High 4) Low)))
(define-checked flipped
  {B : buffer.storage --> I : fixnum --> J : fixnum --> fixnum}
  {requires (fx<= 0 I) (fx< I 4) (fx<= 0 J) (fx< J 4) (fx= 7 (shen-jit.bytes-length B))}
  B I J -> (byte B (shen-jit.bit-xor I J)))
\\ What is of 8, 16 or 32 bits stays so.
(refine.type u8 N where (and (fx<= 0 N) (fx<= N 255)))
(refine.type u16 N where (and (fx<= 0 N) (fx<= N 65535)))
(refine.type u32 N where (and (fx<= 0 N) (fx<= N 4294967295)))
(define-checked mixed8 {u8 --> u8 --> u8} A B -> (shen-jit.bit-xor A (shen-jit.bit-or B 129)))
(define-checked mixed16 {u16 --> u8 --> u16} A B -> (shen-jit.bit-or A (shen-jit.bit-xor A B)))
(define-checked mixed32 {u32 --> u16 --> u32 --> u32} A B C -> (shen-jit.bit-xor (shen-jit.bit-or A B) (shen-jit.bit-xor C 1819895653)))
(define-checked middle
  {B : buffer.storage --> Low : fixnum --> High : fixnum --> fixnum}
  {requires (fx<= 0 Low) (fx< Low High) (fx<= High (shen-jit.bytes-length B))}
  B Low High -> (byte B (shen-jit.shift-right (fx+ Low High) 1)))

\\ What is left over, and that there is room for a step where there is for one that is a multiple.
(define-checked sum-words
  {B : buffer.storage --> I : fixnum --> End : fixnum --> fixnum --> fixnum}
  {requires (fx<= 0 I) (fx<= End (shen-jit.bytes-length B)) (fx= 0 (fxremainder I 4)) (fx= 0 (fxremainder End 4))}
  _ I End Sum -> Sum where (fx>= I End)
  B I End Sum -> (sum-words B (fx+ I 4) End (fx+ Sum (word B I))))
(define-checked split
  {N : fixnum --> R : fixnum}
  {ensures (fx= R N)}
  N -> (fx+ (fx* 10 (fxquotient N 10)) (fxremainder N 10)))
(define-checked rounded
  {N : fixnum --> R : fixnum}
  {ensures (fx<= R N) (fx< N (fx+ R 8)) (fx= 0 (fxremainder R 8))}
  N -> (fx* 8 (shen-jit.shift-right N 3)))
(define-checked parted
  {N : fixnum --> R : fixnum}
  {ensures (fx= R N)}
  N -> (fx+ (shen-jit.bit-and N 255) (fx* 256 (shen-jit.shift-right N 8))))

\\ How long what is made is, and what is written.
(define-checked last-of-new
  {N : fixnum --> fixnum}
  {requires (fx> N 0)}
  N -> (let B (shen-jit.bytes N) (byte B (fx- N 1))))
(define-checked last-written
  {--> fixnum}
  -> (byte (shen-jit.u8! (shen-jit.u16! (shen-jit.bytes 5) 0 7) 4 9) 4))
(define-checked copied
  {B : buffer.storage --> fixnum}
  {requires (fx= 5 (shen-jit.bytes-length B))}
  B -> (byte (shen-jit.copy-bytes (shen-jit.bytes 3) 0 B 1 3) 2))
(define-checked sliced
  {V : buffer.view --> fixnum}
  {requires (fx>= (buffer.length V) 8)}
  V -> (let W (buffer.slice V 4 4) (fx+ (item W 3) (byte (buffer.bytes W) 2))))
(define-checked pad
  {V : buffer.view --> I : fixnum --> End : fixnum --> R : buffer.view}
  {requires (fx<= 0 I) (fx<= I End) (fx<= End (buffer.length V))}
  {ensures (fx>= (buffer.length R) End)}
  V I End -> (if (= I End) V (let W (buffer.u8-> V I 3) (pad W (fx+ I 1) End))))
(define-checked padded
  {--> fixnum}
  -> (item (pad (buffer.new 6) 2 6) 5))
(define-checked wrapped
  {--> fixnum}
  -> (item (buffer.u32-be-> (buffer.u16-be-> (buffer.wrap (shen-jit.bytes 6)) 0 258) 2 16909060) 5))

\\ What the first part of a do promises, and what a test of a list that is written says.
(define-checked within
  {I : fixnum --> N : fixnum --> boolean}
  {ensures (fx<= 0 I) (fx< I N)}
  I N -> true where (and (fx<= 0 I) (fx< I N))
  I N -> (error "~A is not below ~A" I N))
(define-checked checked
  {buffer.storage --> fixnum --> fixnum}
  B I -> (do (within I (shen-jit.bytes-length B)) (byte B I)))
(define-checked checked-if
  {buffer.storage --> fixnum --> fixnum}
  B I -> (do (if (fx< I 4) (within I 4) (within I (shen-jit.bytes-length B)))
             (if (fx>= I 4) (byte B I) 0)))
(define-checked access
  {M : symbol --> fixnum}
  {requires (element? M [read write])}
  read -> 1
  _ -> 2)
(define-checked accessed
  {symbol --> fixnum}
  M -> (let Known (element? M [write read]) (if Known (access M) 0)))
(define-checked accessing
  {symbol --> fixnum}
  M -> 0 where (not (element? M [read write other]))
  other -> 3
  M -> (access M))

(define ascending
  {fixnum --> buffer.storage}
  N -> (fill (shen-jit.bytes N) 0 N))
(define fill
  {buffer.storage --> fixnum --> fixnum --> buffer.storage}
  B N N -> B
  B I N -> (fill (shen-jit.u8! B I I) (fx+ I 1) N))

(define-checked refine-bytes.main
  {--> string}
  -> (let B (shen-jit.bytes 64)
          C (shen-jit.bytes 16)
          D (shen-jit.bytes 79)
          E (shen-jit.bytes 7)
          F (shen-jit.bytes 5)
          V (buffer.u8-> (buffer.new 8) 1 5)
       (do (fill B 0 64) (fill C 0 16) (fill D 0 79) (fill E 0 7) (fill F 0 5)
           (@s (make-string "~A ~A ~A ~A " (marked? V 10) (marked? V 9) (digits C 169) (count-from B 8 12 0))
               (make-string "~A ~A ~A ~A " (slot B 2) (next-slot B 17) (joined D 3 14) (flipped E 1 3))
               (make-string "~A ~A ~A ~A " (middle B 10 20) (sum-words B 0 8 0) (split -123) (rounded -9))
               (make-string "~A ~A ~A ~A " (last-of-new 3) (last-written) (copied F) (sliced V))
               (make-string "~A ~A ~A ~A " (padded) (wrapped) (checked B 63) (trap-error (checked B 64) (/. X 0)))
               (make-string "~A ~A ~A ~A " (checked-if B 2) (checked-if B 5) (accessed write) (accessed close))
               (make-string "~A ~A ~A " (accessing read) (accessing other) (parted -1234))
               (make-string "~A ~A ~A" (mixed8 255 64) (mixed16 65280 15) (mixed32 4294967295 1 1819895653))))))
