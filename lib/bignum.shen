\\ Bignums, integers of any size, over GMP, in Shen alone: module bignum (docs/bignum.md). It stays out of
\\ the image until asked for, and needs GMP's library, which most systems have or package:
\\
\\   shen-jit eval -m bignum -l program.shen
\\
\\ (bignum.expt 2 100)                                        1267650600228229401496703205376
\\ (bignum.* (bignum.of-string "123456789012345678901") 10)   1234567890123456789010
\\
\\ A bignum that fits a fixnum is one, and any other is a bignum.big: its sign and its 64-bit limbs, as
\\ plain data of the Shen heap. So equal bignums are =, and hash alike, one prints as its digits, and one
\\ goes into a saved image or to another isolate as any value does. Operations on fixnums are the kernel's
\\ arithmetic, and call GMP only where the result is no fixnum.
\\
\\ Sums, products, comparisons and divisions by a fixnum work on the limbs where they are. The other
\\ operations work on registers of this module's, in memory outside the heap: operands are copied into
\\ them, and results out. Each isolate makes its own when it first needs them, and frees them as it
\\ ends. GMP ends the process where an operation has no answer, as a division by zero, or no memory for
\\ it: each operation checks for the first here, and refuses a result of more than 2^31 bits.

(shen.x.namespace bignum
  (use shen-jit)
  (import struct defstruct)
  (externals [buffer.storage bytes define-foreign double fixnum float int32 int64 limbs memory.alloc
              memory.free pointer string uint32 void])
  (shadow + - * < <= big compare even? expt factorial gcd integer? lcm modulo negative? prime? quotient registers
          release remainder result sign sqrt square?)
  (export *library-files* t integer? of of-float of-string of-string-base to-fixnum to-float to-string to-string-base
          + - * quotient remainder quotient-remainder floor-quotient modulo sign
          < <= compare even? expt expt-mod invert gcd gcd-extended lcm sqrt square?
          prime? next-prime factorial binomial fibonacci
          bit-and bit-or bit-xor bit-set? bit-length bit-count shift-left shift-right)

(if (bound? *library-files*) true
    (set *library-files*
      ["libgmp.so.10" "libgmp.so" "libgmp.dylib" "/opt/homebrew/lib/libgmp.dylib" "/usr/local/lib/libgmp.dylib"
       "/opt/local/lib/libgmp.dylib" "libgmp-10.dll"]))
(shen-jit.library gmp (value *library-files*))

(define-foreign c-init gmp "__gmpz_init" (pointer) --> void)
(define-foreign c-clear gmp "__gmpz_clear" (pointer) --> void)
(define-foreign c-set-d gmp "__gmpz_set_d" (pointer double) --> void)
(define-foreign c-set-str gmp "__gmpz_set_str" (pointer string int32) --> int32)
(define-foreign c-get-str gmp "__gmpz_get_str" (bytes int32 pointer) --> void)
(define-foreign c-size-in-base gmp "__gmpz_sizeinbase" (pointer int32) --> int64)
(define-foreign c-tdiv-q gmp "__gmpz_tdiv_q" (pointer pointer pointer) --> void)
(define-foreign c-tdiv-r gmp "__gmpz_tdiv_r" (pointer pointer pointer) --> void)
(define-foreign c-tdiv-qr gmp "__gmpz_tdiv_qr" (pointer pointer pointer pointer) --> void)
(define-foreign c-fdiv-q gmp "__gmpz_fdiv_q" (pointer pointer pointer) --> void)
(define-foreign c-fdiv-r gmp "__gmpz_fdiv_r" (pointer pointer pointer) --> void)
(define-foreign c-pow-ui gmp "__gmpz_pow_ui" (pointer pointer uint32) --> void)
(define-foreign c-powm gmp "__gmpz_powm" (pointer pointer pointer pointer) --> void)
(define-foreign c-invert gmp "__gmpz_invert" (pointer pointer pointer) --> int32)
(define-foreign c-gcd gmp "__gmpz_gcd" (pointer pointer pointer) --> void)
(define-foreign c-gcdext gmp "__gmpz_gcdext" (pointer pointer pointer pointer pointer) --> void)
(define-foreign c-lcm gmp "__gmpz_lcm" (pointer pointer pointer) --> void)
(define-foreign c-sqrt gmp "__gmpz_sqrt" (pointer pointer) --> void)
(define-foreign c-square? gmp "__gmpz_perfect_square_p" (pointer) --> int32)
(define-foreign c-prime? gmp "__gmpz_probab_prime_p" (pointer int32) --> int32)
(define-foreign c-next-prime gmp "__gmpz_nextprime" (pointer pointer) --> void)
(define-foreign c-factorial gmp "__gmpz_fac_ui" (pointer uint32) --> void)
(define-foreign c-binomial gmp "__gmpz_bin_ui" (pointer pointer uint32) --> void)
(define-foreign c-fibonacci gmp "__gmpz_fib_ui" (pointer uint32) --> void)
(define-foreign c-and gmp "__gmpz_and" (pointer pointer pointer) --> void)
(define-foreign c-or gmp "__gmpz_ior" (pointer pointer pointer) --> void)
(define-foreign c-xor gmp "__gmpz_xor" (pointer pointer pointer) --> void)
(define-foreign c-bit-set? gmp "__gmpz_tstbit" (pointer uint32) --> int32)
(define-foreign c-popcount gmp "__gmpz_popcount" (pointer) --> uint32)
(define-foreign c-shift-left gmp "__gmpz_mul_2exp" (pointer pointer uint32) --> void)
(define-foreign c-shift-right gmp "__gmpz_fdiv_q_2exp" (pointer pointer uint32) --> void)

\\ On limbs in byte buffers. A carry or a remainder is less than the limb given, so it is a fixnum.
(define-foreign n-add gmp "__gmpn_add" (bytes bytes int64 bytes int64) --> int32)
(define-foreign n-sub gmp "__gmpn_sub" (bytes bytes int64 bytes int64) --> int32)
(define-foreign n-mul gmp "__gmpn_mul" (bytes bytes int64 bytes int64) --> void)
(define-foreign n-cmp gmp "__gmpn_cmp" (bytes bytes int64) --> int32)
(define-foreign n-add-1 gmp "__gmpn_add_1" (bytes bytes int64 int64) --> int32)
(define-foreign n-sub-1 gmp "__gmpn_sub_1" (bytes bytes int64 int64) --> int32)
(define-foreign n-mul-1 gmp "__gmpn_mul_1" (bytes bytes int64 int64) --> int64)
(define-foreign n-divrem-1 gmp "__gmpn_divrem_1" (bytes int64 bytes int64 int64) --> int64)
(define-foreign n-mod-1 gmp "__gmpn_mod_1" (bytes int64 int64) --> int64)

\\ ---------------------------------------------------------------------------
\\ The registers. GMP's integer, an mpz_t, is 16 bytes: the limbs it has room for and the limbs it
\\ has, negative for a negative integer, as C ints, and the address of its limbs. gmp.h compiles
\\ that into every program that uses GMP. Results are GMP's own; an operand's limbs are in a block
\\ from here, which grows, and which GMP only reads.

(defstruct operand
  mpz
  (mutable block))

(defstruct registers
  r s u
  x y z
  (mutable large))

(define registers
  -> (let Rs (trap-error (value *registers*) (/. E []))
       (if (live? Rs) Rs (make-registers))))

\\ Pointers in a saved image load dead, with no length.
(define live?
  [] -> false
  Rs -> (fx> (shen-jit.bytes-length (registers.r Rs)) 0))

(define make-registers
  -> (let R (new-result)
          Rs (registers.make R (new-result) (new-result) (new-operand) (new-operand) (new-operand) false)
       (do (set *registers* Rs)
           (shen-jit.at-end release)
           Rs)))

(define new-result
  -> (let M (memory.alloc 16)
       (do (shen-jit.on-error (freeze (c-init M)) (freeze (memory.free M)))
           M)))

(define new-operand
  -> (let M (memory.alloc 16)
          B (memory.alloc 512)
       (do (shen-jit.pointer! M 8 B)
           (operand.make M B))))

(define release
  -> (let Rs (trap-error (value *registers*) (/. E []))
       (if (live? Rs)
           (do (set *registers* [])
               (map (/. Z (do (c-clear Z) (memory.free Z))) [(registers.r Rs) (registers.s Rs) (registers.u Rs)])
               (map (/. O (do (memory.free (operand.block O)) (memory.free (operand.mpz O))))
                    [(registers.x Rs) (registers.y Rs) (registers.z Rs)])
               true)
           true)))

\\ ---------------------------------------------------------------------------
\\ Bignums in and out of the registers.

(defstruct big
  (printer digits)
  size
  limbs)

(define digits
  A -> (to-string A))

(define integer?
  X -> (or (shen-jit.fixnum? X) (big? X)))

(define not-integer
  X -> (error "bignum: ~S is not an integer" X))

(define fixnums?
  A B -> (and (shen-jit.fixnum? A) (shen-jit.fixnum? B)))

(define copy-in
  O N -> (let Mpz (operand.mpz O)
           (do (put-limb (operand.block O) N)
               (shen-jit.s32! Mpz 4 (if (fx> N 0) 1 (if (= N 0) 0 -1)))))
      where (shen-jit.fixnum? N)
  O A -> (let B (big.limbs A)
              K (shen-jit.bytes-length B)
           (do (room O K)
               (shen-jit.copy-bytes (operand.block O) 0 B 0 K)
               (shen-jit.s32! (operand.mpz O) 4 (big.size A))))
      where (big? A)
  _ X -> (not-integer X))

\\ The magnitude of a fixnum, of which the least one's is no fixnum.
(define put-limb
  M N -> (shen-jit.s64! M 0 N) where (fx>= N 0)
  M N -> (trap-error (shen-jit.s64! M 0 (fx- 0 N))
                     (/. E (do (shen-jit.u32! M 0 0) (shen-jit.u32! M 4 536870912)))))

(define room
  O K -> O where (fx<= K (shen-jit.bytes-length (operand.block O)))
  O K -> (let B (memory.alloc (fx* 2 K))
              Old (operand.block O)
           (do (operand.block-> O B)
               (shen-jit.pointer! (operand.mpz O) 8 B)
               (memory.free Old)
               (if (fx> K 1048576) (registers.large-> (registers) true) skip)
               O)))

(define load1
  A -> (let Rs (registers)
         (do (copy-in (registers.x Rs) A) Rs)))

(define load2
  A B -> (let Rs (registers)
           (do (copy-in (registers.x Rs) A) (copy-in (registers.y Rs) B) Rs)))

(define x Rs -> (operand.mpz (registers.x Rs)))
(define y Rs -> (operand.mpz (registers.y Rs)))
(define z Rs -> (operand.mpz (registers.z Rs)))

\\ A bignum from a result, copied out of GMP's memory.
(define copy-out
  M -> (let N (shen-jit.s32 M 4)
         (if (= N 0)
             0
             (let B (shen-jit.pointer->bytes (shen-jit.bytes->pointer M 8 limbs) 0 (fx* 8 (magnitude N)))
               (if (= (magnitude N) 1) (one-limb N B) (big.make N B))))))

(define magnitude
  N -> (if (fx< N 0) (fx- 0 N) N))

\\ 2^29 is the upper half of 2^61, the first integer past the fixnums, whose negation is the least.
(define one-limb
  N B -> (let High (shen-jit.u32 B 4)
           (if (fx< High 536870912)
               (fx* N (shen-jit.s64 B 0))
               (if (and (= N -1) (and (= High 536870912) (= (shen-jit.u32 B 0) 0)))
                   (fx- -2305843009213693951 1)
                   (big.make N B)))))

\\ Registers that held more than 1 MB go back to the system, as the next operation may need little.
(define result
  Rs -> (settle Rs (copy-out (registers.r Rs))))

(define settle
  Rs V -> (do (if (or (registers.large Rs) (fx> (shen-jit.s32 (registers.r Rs) 0) 131072)) (release) skip)
              V))

(define size-of
  A -> 1 where (shen-jit.fixnum? A)
  A -> (magnitude (big.size A)) where (big? A)
  X -> (not-integer X))

(define check-bits
  N -> (if (fx> N 2147483648) (error "bignum: the result would have more than 2^31 bits") true))

(define check-limbs
  N -> (if (fx> N 33554432) (error "bignum: the result would have more than 2^31 bits") true))

\\ A count of bits or such.
(define check-count
  N -> true where (and (shen-jit.fixnum? N) (fx>= N 0))
  N -> (error "bignum: ~S is not a fixnum from 0" N))

(define by-zero
  -> (error "bignum: division by zero"))

\\ ---------------------------------------------------------------------------
\\ Limbs. A magnitude is a byte buffer of them, the lowest first, and a sign is true for a negative
\\ bignum. A result goes into a new buffer, which is the bignum's unless its highest limb is 0.

(define negative?
  A -> (fx< A 0) where (shen-jit.fixnum? A)
  A -> (fx< (big.size A) 0) where (big? A)
  X -> (not-integer X))

(define limbs-of
  A -> (big.limbs A) where (big? A)
  N -> (put-limb (shen-jit.bytes 8) N))

(define count-of
  B -> (shen-jit.shift-right (shen-jit.bytes-length B) 3))

(define new-limbs
  M -> (shen-jit.bytes (fx* 8 M)))

\\ A fixnum whose magnitude is one too, as every one's but the least's is.
(define small?
  N -> (and (shen-jit.fixnum? N) (fx>= N -2305843009213693951)))

\\ The bignum of sign P and the M limbs of R, the highest of them not 0.
(define signed
  P M R -> (let N (if P (fx- 0 M) M)
             (if (= M 1) (one-limb N R) (big.make N R))))

\\ The same with a limb C above R's.
(define with-carry
  P M R 0 -> (signed P M R)
  P M R C -> (let K (fx* 8 M)
               (signed P (fx+ M 1) (shen-jit.s64! (shen-jit.copy-bytes (shen-jit.bytes (fx+ K 8)) 0 R 0 K) K C))))

\\ The same without the limbs that are 0 at R's top.
(define trimmed
  P M R -> (if (zero-limb? R (fx- M 1)) (cut P (top R (fx- M 1)) R) (signed P M R)))

(define zero-limb?
  R I -> (and (= (shen-jit.u32 R (fx* 8 I)) 0) (= (shen-jit.u32 R (fx+ (fx* 8 I) 4)) 0)))

\\ How many of R's first M limbs are left without those.
(define top
  _ 0 -> 0
  R M -> (if (zero-limb? R (fx- M 1)) (top R (fx- M 1)) M))

(define cut
  _ 0 _ -> 0
  P M R -> (signed P M (shen-jit.copy-bytes (new-limbs M) 0 R 0 (fx* 8 M))))

\\ ---------------------------------------------------------------------------
\\ Arithmetic.

(define +
  A B -> (if (fixnums? A B) (trap-error (fx+ A B) (/. E (add A B))) (add A B)))

(define add
  A B -> (add-small (negative? A) (big.limbs A) B) where (and (small? B) (big? A))
  A B -> (add-small (negative? B) (big.limbs B) A) where (and (small? A) (big? B))
  A B -> (add-signed (negative? A) (limbs-of A) (negative? B) (limbs-of B)))

\\ N and a bignum past the fixnums, so of a greater magnitude.
(define add-small
  P A N -> (let M (count-of A)
                R (new-limbs M)
             (if (= P (fx< N 0))
                 (with-carry P M R (n-add-1 R A M (magnitude N)))
                 (do (n-sub-1 R A M (magnitude N)) (trimmed P M R)))))

(define add-signed
  P A Q B -> (let M (count-of A)
                  N (count-of B)
               (if (= P Q)
                   (if (fx>= M N) (add-limbs P A M B N) (add-limbs P B N A M))
                   (let C (if (= M N) (n-cmp A B M) (fx- M N))
                     (if (= C 0)
                         0
                         (if (fx> C 0) (subtract-limbs P A M B N) (subtract-limbs Q B N A M)))))))

(define add-limbs
  P A M B N -> (let R (new-limbs M)
                 (with-carry P M R (n-add R A M B N))))

(define subtract-limbs
  P A M B N -> (let R (new-limbs M)
                 (do (n-sub R A M B N) (trimmed P M R))))

(define -
  A B -> (if (fixnums? A B) (trap-error (fx- A B) (/. E (subtract A B))) (subtract A B)))

(define subtract
  A B -> (add-small (negative? A) (big.limbs A) (fx- 0 B)) where (and (small? B) (big? A))
  A B -> (add-signed (negative? A) (limbs-of A) (not (negative? B)) (limbs-of B)))

(define *
  A B -> (if (fixnums? A B) (trap-error (fx* A B) (/. E (multiply A B))) (multiply A B)))

(define multiply
  A B -> (multiply-small (negative? A) (limbs-of A) B) where (small? B)
  A B -> (multiply-small (negative? B) (limbs-of B) A) where (small? A)
  A B -> (multiply-limbs (not (= (negative? A) (negative? B))) (limbs-of A) (limbs-of B)))

(define multiply-small
  _ _ 0 -> 0
  P A N -> (let M (count-of A)
                _ (check-limbs (fx+ M 1))
                R (new-limbs M)
             (with-carry (not (= P (fx< N 0))) M R (n-mul-1 R A M (magnitude N)))))

(define multiply-limbs
  P A B -> (let M (count-of A)
                N (count-of B)
                K (fx+ M N)
                _ (check-limbs K)
                R (new-limbs K)
                _ (if (fx>= M N) (n-mul R A M B N) (n-mul R B N A M))
             (trimmed P K R)))

\\ The quotient truncates, and the remainder has the dividend's sign.
(define quotient
  _ 0 -> (by-zero)
  A B -> (if (fixnums? A B) (trap-error (fxquotient A B) (/. E (big-quotient A B))) (big-quotient A B)))

(define big-quotient
  A B -> (let R (new-limbs (count-of (big.limbs A)))
           (do (divide R A B) (divided R A B)))
      where (and (small? B) (big? A))
  A B -> (let Rs (load2 A B)
           (do (c-tdiv-q (registers.r Rs) (x Rs) (y Rs)) (result Rs))))

\\ The quotient's limbs into R, giving the remainder's magnitude, and the quotient from them.
(define divide
  R A B -> (n-divrem-1 R 0 (big.limbs A) (count-of R) (magnitude B)))

(define divided
  R A B -> (trimmed (not (= (negative? A) (fx< B 0))) (count-of R) R))

(define remainder
  _ 0 -> (by-zero)
  A B -> (if (fixnums? A B) (trap-error (fxremainder A B) (/. E (big-remainder A B))) (big-remainder A B)))

(define big-remainder
  A B -> (with-sign A (n-mod-1 (big.limbs A) (count-of (big.limbs A)) (magnitude B)))
      where (and (small? B) (big? A))
  A B -> (let Rs (load2 A B)
           (do (c-tdiv-r (registers.r Rs) (x Rs) (y Rs)) (result Rs))))

(define with-sign
  A N -> (if (negative? A) (fx- 0 N) N))

(define quotient-remainder
  _ 0 -> (by-zero)
  A B -> (@p (quotient A B) (remainder A B)) where (fixnums? A B)
  A B -> (let R (new-limbs (count-of (big.limbs A)))
              N (divide R A B)
           (@p (divided R A B) (with-sign A N)))
      where (and (small? B) (big? A))
  A B -> (let Rs (load2 A B)
              _ (c-tdiv-qr (registers.r Rs) (registers.s Rs) (x Rs) (y Rs))
              R (copy-out (registers.s Rs))
           (@p (result Rs) R)))

\\ The quotient rounded down, and the remainder with the divisor's sign.
(define floor-quotient
  _ 0 -> (by-zero)
  A B -> (let Q (fxquotient A B)
           (if (or (= (fx* Q B) A) (= (fx< A 0) (fx< B 0))) Q (fx- Q 1)))
      where (and (fixnums? A B) (not (= B -1)))
  A B -> (let P (quotient-remainder A B)
           (if (or (= (snd P) 0) (= (fx< (snd P) 0) (fx< B 0))) (fst P) (- (fst P) 1)))
      where (and (small? B) (big? A))
  A B -> (let Rs (load2 A B)
           (do (c-fdiv-q (registers.r Rs) (x Rs) (y Rs)) (result Rs))))

(define modulo
  _ 0 -> (by-zero)
  A B -> (let R (remainder A B)
           (if (or (= R 0) (= (fx< R 0) (fx< B 0))) R (fx+ R B)))
      where (small? B)
  A B -> (let Rs (load2 A B)
           (do (c-fdiv-r (registers.r Rs) (x Rs) (y Rs)) (result Rs))))

\\ -1, 0 or 1. Where the limbs differ in number, they tell.
(define compare
  A B -> (if (fx< A B) -1 (if (= A B) 0 1)) where (fixnums? A B)
  A B -> (let M (signed-size A)
              N (signed-size B)
           (if (= M N)
               (one (if (fx> M 0) (n-cmp (limbs-of A) (limbs-of B) M) (n-cmp (limbs-of B) (limbs-of A) (fx- 0 M))))
               (if (fx< M N) -1 1))))

(define signed-size
  A -> (one A) where (shen-jit.fixnum? A)
  A -> (big.size A) where (big? A)
  X -> (not-integer X))

(define one
  N -> (if (fx> N 0) 1 (if (= N 0) 0 -1)))

(define <
  A B -> (if (fixnums? A B) (fx< A B) (fx< (compare A B) 0)))

(define <=
  A B -> (if (fixnums? A B) (fx<= A B) (fx<= (compare A B) 0)))

(define sign
  A -> (one (signed-size A)))

(define even?
  A -> (= (shen-jit.bit-and A 1) 0) where (shen-jit.fixnum? A)
  A -> (= (shen-jit.bit-and (shen-jit.u8 (big.limbs A) 0) 1) 0) where (big? A)
  X -> (not-integer X))

\\ The result has at least (L - 1) N bits and at most L N, for a base of L bits.
(define expt
  _ N -> (check-count N) where (not (and (shen-jit.fixnum? N) (fx>= N 0)))
  _ 0 -> 1
  0 _ -> 0
  1 _ -> 1
  -1 N -> (if (even? N) 1 -1)
  A N -> (let L (fx- (bit-length A) 1)
              _ (if (fx> N (fxquotient 2147483648 L)) (check-bits 2147483649) true)
              Rs (load1 A)
           (do (c-pow-ui (registers.r Rs) (x Rs) N) (result Rs))))

\\ B^E modulo M, from 0 up to M's magnitude. A negative E is a power of B's inverse.
(define expt-mod
  _ _ 0 -> (by-zero)
  B E M -> (expt-mod (invert B M) (- 0 E) M) where (fx< (sign E) 0)
  B E M -> (let Rs (load2 B E)
             (do (copy-in (registers.z Rs) M)
                 (c-powm (registers.r Rs) (x Rs) (y Rs) (z Rs))
                 (result Rs))))

(define invert
  _ 0 -> (by-zero)
  A M -> (let Rs (load2 A M)
           (if (= (c-invert (registers.r Rs) (x Rs) (y Rs)) 0)
               (error "bignum.invert: no inverse modulo that")
               (result Rs))))

(define gcd
  A B -> (let Rs (load2 A B)
           (do (c-gcd (registers.r Rs) (x Rs) (y Rs)) (result Rs))))

\\ (@p G (@p S T)), where G is the greatest common divisor, A S + B T.
(define gcd-extended
  A B -> (let Rs (load2 A B)
              _ (c-gcdext (registers.r Rs) (registers.s Rs) (registers.u Rs) (x Rs) (y Rs))
              S (copy-out (registers.s Rs))
              T (copy-out (registers.u Rs))
           (@p (result Rs) (@p S T))))

(define lcm
  A B -> (let _ (check-limbs (fx+ (size-of A) (size-of B)))
              Rs (load2 A B)
           (do (c-lcm (registers.r Rs) (x Rs) (y Rs)) (result Rs))))

(define sqrt
  A -> (if (fx< (sign A) 0)
           (error "bignum.sqrt: a negative integer")
           (let Rs (load1 A)
             (do (c-sqrt (registers.r Rs) (x Rs)) (result Rs)))))

(define square?
  A -> (and (fx>= (sign A) 0)
            (let Rs (load1 A) (settle Rs (not (= (c-square? (x Rs)) 0))))))

(define prime?
  A -> (and (not (< A 2))
            (let Rs (load1 A) (settle Rs (not (= (c-prime? (x Rs) 25) 0))))))

(define next-prime
  A -> (let Rs (load1 A)
         (do (c-next-prime (registers.r Rs) (x Rs)) (result Rs))))

(define factorial
  N -> (let _ (check-count N)
            _ (if (fx> N 67108864) (check-bits 2147483649) true)
            Rs (registers)
         (do (c-factorial (registers.r Rs) N) (result Rs))))

(define binomial
  N K -> (let _ (check-count K)
              _ (if (fx> K (fxquotient 2147483648 (fx+ (bit-length N) 1))) (check-bits 2147483649) true)
              Rs (load1 N)
           (do (c-binomial (registers.r Rs) (x Rs) K) (result Rs))))

(define fibonacci
  N -> (let _ (check-count N)
            _ (check-bits N)
            Rs (registers)
         (do (c-fibonacci (registers.r Rs) N) (result Rs))))

\\ ---------------------------------------------------------------------------
\\ Bits, of a negative bignum as in two's complement.

(define bit-and
  A B -> (shen-jit.bit-and A B) where (fixnums? A B)
  A B -> (let Rs (load2 A B)
           (do (c-and (registers.r Rs) (x Rs) (y Rs)) (result Rs))))

(define bit-or
  A B -> (shen-jit.bit-or A B) where (fixnums? A B)
  A B -> (let Rs (load2 A B)
           (do (c-or (registers.r Rs) (x Rs) (y Rs)) (result Rs))))

(define bit-xor
  A B -> (shen-jit.bit-xor A B) where (fixnums? A B)
  A B -> (let Rs (load2 A B)
           (do (c-xor (registers.r Rs) (x Rs) (y Rs)) (result Rs))))

\\ How many bits the magnitude has: 0 for 0.
(define bit-length
  A -> (trap-error (bits (magnitude A)) (/. E 62)) where (shen-jit.fixnum? A)
  A -> (let B (big.limbs A)
            K (shen-jit.bytes-length B)
            High (shen-jit.u32 B (fx- K 4))
         (if (= High 0)
             (fx+ (fx- (fx* 8 K) 64) (bits (shen-jit.u32 B (fx- K 8))))
             (fx+ (fx- (fx* 8 K) 32) (bits High))))
      where (big? A)
  X -> (not-integer X))

(define bits
  N -> (fx- 62 (shen-jit.clz N)))

(define bit-set?
  A I -> (do (check-count I)
             (if (fx>= I (bit-length A))
                 (fx< (sign A) 0)
                 (if (shen-jit.fixnum? A)
                     (= (shen-jit.bit-and (shen-jit.shift-right A I) 1) 1)
                     (let Rs (load1 A) (settle Rs (= (c-bit-set? (x Rs) I) 1)))))))

(define bit-count
  A -> (if (fx< (sign A) 0)
           (error "bignum.bit-count: a negative integer")
           (if (shen-jit.fixnum? A)
               (shen-jit.popcount A)
               (let Rs (load1 A) (settle Rs (c-popcount (x Rs)))))))

(define shift-left
  A N -> (let _ (check-count N)
              _ (check-bits N)
              L (fx+ (bit-length A) N)
           (if (or (= A 0) (fx<= L 60))
               (if (= A 0) 0 (fx* A (shen-jit.shift-left 1 N)))
               (let _ (check-bits L)
                    Rs (load1 A)
                 (do (c-shift-left (registers.r Rs) (x Rs) N) (result Rs))))))

\\ Rounded down.
(define shift-right
  A N -> (do (check-count N)
             (if (fx>= N (bit-length A))
                 (if (fx< (sign A) 0) -1 0)
                 (if (shen-jit.fixnum? A)
                     (shen-jit.shift-right A N)
                     (let Rs (load1 A)
                       (do (c-shift-right (registers.r Rs) (x Rs) N) (result Rs)))))))

\\ ---------------------------------------------------------------------------
\\ Conversions.

(define of
  N -> N where (shen-jit.fixnum? N)
  X -> (not-integer X))

(define to-fixnum
  A -> A where (shen-jit.fixnum? A)
  A -> (error "bignum.to-fixnum: integer overflow") where (big? A)
  X -> (not-integer X))

\\ Towards zero.
(define of-float
  F -> (trap-error (fl->fx F) (/. E (of-large-float F))) where (number? F)
  X -> (error "bignum.of-float: ~S is not a float" X))

(define of-large-float
  F -> (error "bignum.of-float: ~S is not finite" F) where (not (= (fl- F F) 0))
  F -> (let Rs (registers)
         (do (c-set-d (registers.r Rs) F) (result Rs))))

\\ The nearest float: 60 bits of the magnitude, the last of them set if any below is, which an
\\ integer's conversion rounds as it would the whole, then scaled.
(define to-float
  A -> (shen-jit.float A) where (shen-jit.fixnum? A)
  A -> (let L (bit-length A)
            _ (if (fx> L 1024) (too-large) true)
            N (fx- L 60)
            M (if (fx< (sign A) 0) (- 0 A) A)
            Q (shift-right M N)
            F (scale (shen-jit.float (if (= (shift-left Q N) M) Q (shen-jit.bit-or Q 1))) N)
         (if (= (fl- F F) 0)
             (if (fx< (sign A) 0) (fl- (shen-jit.float 0) F) F)
             (too-large))))

(define too-large
  -> (error "bignum.to-float: the integer is too large for a float"))

(define scale
  F 0 -> F
  F N -> (scale (fl* F (shen-jit.float 1152921504606846976)) (fx- N 60)) where (fx>= N 60)
  F N -> (scale (fl* F (shen-jit.float 2)) (fx- N 1)))

(define of-string
  S -> (of-string-base S 10))

\\ An optional minus sign and digits, letters in either case for those past 9. GMP would also skip
\\ white space.
(define of-string-base
  S Base -> (let _ (check-base Base)
                 B (shen-jit.string->bytes S)
                 N (shen-jit.bytes-length B)
                 I (if (and (fx> N 0) (= (shen-jit.u8 B 0) 45)) 1 0)
              (if (and (fx< I N) (digits? B I N Base))
                  (let _ (check-bits (fx* N (bit-length (fx- Base 1))))
                       Rs (registers)
                    (do (c-set-str (registers.r Rs) S Base) (result Rs)))
                  (error "bignum.of-string: ~S is not an integer in base ~A" S Base))))

(define check-base
  Base -> true where (and (shen-jit.fixnum? Base) (and (fx>= Base 2) (fx<= Base 36)))
  Base -> (error "bignum: ~S is not a base from 2 to 36" Base))

(define digits?
  _ N N _ -> true
  B I N Base -> (and (fx< (digit (shen-jit.u8 B I)) Base) (digits? B (fx+ I 1) N Base)))

(define digit
  C -> (fx- C 48) where (and (fx>= C 48) (fx<= C 57))
  C -> (fx- C 87) where (and (fx>= C 97) (fx<= C 122))
  C -> (fx- C 55) where (and (fx>= C 65) (fx<= C 90))
  _ -> 36)

(define to-string
  A -> (str A) where (shen-jit.fixnum? A)
  A -> (to-string-base A 10))

\\ GMP says how many digits there are, or one more, and writes a zero byte after them.
(define to-string-base
  A Base -> (let _ (check-base Base)
                 Rs (load1 A)
                 N (fx+ (c-size-in-base (x Rs) Base) (if (fx< (sign A) 0) 1 0))
                 B (shen-jit.bytes (fx+ N 2))
                 _ (c-get-str B Base (x Rs))
              (settle Rs (shen-jit.bytes->string B 0 (if (= (shen-jit.u8 B (fx- N 1)) 0) (fx- N 1) N)))))

\\ ---------------------------------------------------------------------------
\\ Types.

(map (/. F (declare F [t --> [t --> t]]))
     [+ - * quotient remainder floor-quotient modulo invert gcd lcm bit-and bit-or bit-xor])
(map (/. F (declare F [t --> [t --> boolean]])) [< <=])
(map (/. F (declare F [t --> boolean])) [even? square? prime?])
(map (/. F (declare F [t --> t])) [sqrt next-prime])
(map (/. F (declare F [t --> [fixnum --> t]])) [expt binomial shift-left shift-right])
(map (/. F (declare F [fixnum --> t])) [of factorial fibonacci])
(map (/. F (declare F [t --> fixnum])) [to-fixnum sign bit-length bit-count])
(declare compare [t --> [t --> fixnum]])
(declare integer? [(protect A) --> boolean])
(declare expt-mod [t --> [t --> [t --> t]]])
(declare bit-set? [t --> [fixnum --> boolean]])
(declare of-float [float --> t])
(declare to-float [t --> float])
(declare of-string [string --> t])
(declare of-string-base [string --> [fixnum --> t]])
(declare to-string [t --> string])
(declare to-string-base [t --> [fixnum --> string]])

)

\\ Apart from the rest, as here * is the kernel's, a product's, and so is -, which says that the rule
\\ checks a literal against a t and never gives one that type by itself.
(shen.x.namespace bignum
  (use shen-jit)
  (export t quotient-remainder gcd-extended)

(declare quotient-remainder [t --> [t --> [t * t]]])
(declare gcd-extended [t --> [t --> [t * [t * t]]]])

\\ An integer literal of a fixnum can be a t.
(datatype literal
  if (shen-jit.fixnum? X)
  _______________________
  X : (- t);)

)
