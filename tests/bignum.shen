\\ Bignums (lib/bignum.shen). Run by tests/bignum.sh with the module loaded, and by its image and
\\ isolate checks. It needs GMP's library; where that is missing, it says so and stops.

(set bignum-test.*passed* 0)
(set bignum-test.*failed* 0)

(define bignum-test.result
  F -> (trap-error (thaw F) (/. E [error (error-to-string E)])))

(define bignum-test.check
  Name Expected F -> (bignum-test.compare Name Expected (bignum-test.result F)))

(define bignum-test.compare
  _ X X -> (set bignum-test.*passed* (+ 1 (value bignum-test.*passed*)))
  Name Expected Got -> (do (output "FAIL ~A: expected ~S, got ~S~%" Name Expected Got)
                           (set bignum-test.*failed* (+ 1 (value bignum-test.*failed*)))))

\\ As its digits, which the printer shows.
(define bignum-test.shows
  Name Expected F -> (bignum-test.check Name Expected (freeze (make-string "~A" (thaw F)))))

(set bignum-test.*probe* (bignum-test.result (freeze (bignum.factorial 1))))
(if (= (value bignum-test.*probe*) 1)
    skip
    (do (output "1 passed, 0 failed (no GMP here: ~A)~%" (hd (tl (value bignum-test.*probe*)))) (shen-jit.exit 0)))

(set most 2305843009213693951)
(set least (- -2305843009213693951 1))
(define most -> (value most))
(define least -> (value least))
(define big -> (bignum.of-string "123456789012345678901234567890"))

\\ ---------------------------------------------------------------------------
\\ Fixnums stay fixnums, and results that fit are fixnums again.

(bignum-test.check "a small sum" 12 (freeze (bignum.+ 5 7)))
(bignum-test.check "a small difference" -2 (freeze (bignum.- 5 7)))
(bignum-test.check "a small product" 35 (freeze (bignum.* 5 7)))
(bignum-test.shows "a sum past the fixnums" "2305843009213693952" (freeze (bignum.+ (most) 1)))
(bignum-test.shows "a difference past the fixnums" "-2305843009213693953" (freeze (bignum.- (least) 1)))
(bignum-test.shows "a product past the fixnums" "5316911983139663487003542222693990401" (freeze (bignum.* (most) (most))))
(bignum-test.check "back to the most" (most) (freeze (bignum.- (bignum.+ (most) 1) 1)))
(bignum-test.check "back to the least" (least) (freeze (bignum.+ (bignum.- (least) 1) 1)))
(bignum-test.check "each a fixnum" [true true false false]
  (freeze (map (/. X (shen-jit.fixnum? X)) [(bignum.- (bignum.+ (most) 1) 1) (bignum.+ (bignum.- (least) 1) 1)
                                            (bignum.+ (most) 1) (bignum.- (least) 1)])))
(bignum-test.shows "the least negated" "2305843009213693952" (freeze (bignum.negate (least))))
(bignum-test.shows "the least by -1" "2305843009213693952" (freeze (bignum.quotient (least) -1)))
(bignum-test.check "the least's remainder by -1" 0 (freeze (bignum.remainder (least) -1)))
(bignum-test.check "the least modulo -1" 0 (freeze (bignum.modulo (least) -1)))
(bignum-test.check "the least as an operand" (least) (freeze (bignum.quotient (bignum.* (least) (big)) (big))))
(bignum-test.check "one limb either way" [true true true true]
  (freeze [(= (bignum.+ (most) 1) (bignum.expt 2 61)) (= (bignum.- 0 (bignum.expt 2 61)) (least))
           (= (bignum.- (bignum.expt 2 64) 1) (bignum.of-string "18446744073709551615"))
           (= (bignum.- 0 (bignum.expt 2 64)) (bignum.of-string "-18446744073709551616"))]))
(bignum-test.check "zero from large operands" 0 (freeze (bignum.- (big) (big))))

\\ ---------------------------------------------------------------------------
\\ Limbs: carries into a new one, and those a difference or a product leaves 0 at the top.

(define bignum-test.power
  N -> (bignum.expt 2 N))

(define bignum-test.all?
  [] -> true
  [X | Xs] -> (and X (bignum-test.all? Xs)))

(bignum-test.check "carries" true
  (freeze (bignum-test.all? (map (/. N (let P (bignum-test.power N)
                                         Ones (bignum.- P 1)
                                      (and (= (bignum.+ Ones 1) P)
                                           (and (= (bignum.+ 1 Ones) P)
                                                (and (= (bignum.+ Ones Ones) (bignum.- (bignum.* P 2) 2))
                                                     (and (= (bignum.- (bignum.negate Ones) 1) (bignum.negate P))
                                                          (= (bignum.+ (bignum.negate Ones) (bignum.negate Ones)) (bignum.* Ones -2))))))))
                              [61 62 63 64 65 127 128 129 191 192 193 640]))))
(bignum-test.check "differences" true
  (freeze (bignum-test.all? (map (/. N (let P (bignum-test.power N)
                                         Ones (bignum.- P 1)
                                      (and (= (bignum.- P Ones) 1)
                                           (and (= (bignum.- Ones P) -1)
                                                (and (= (bignum.+ P (bignum.negate P)) 0)
                                                     (and (= (bignum.- P (bignum.- P (bignum-test.power 64))) (bignum-test.power 64))
                                                          (= (bignum.- (bignum.- P (most)) (bignum.- P 1)) (- 1 (most)))))))))
                              [62 64 65 128 129 192 193 640]))))
(bignum-test.check "products by a fixnum" true
  (freeze (bignum-test.all? (map (/. N (let P (bignum-test.power N)
                                         Ones (bignum.- P 1)
                                      (and (= (bignum.* Ones 2) (bignum.- (bignum-test.power (+ N 1)) 2))
                                           (and (= (bignum.* (most) Ones) (bignum.- (bignum.- (bignum-test.power (+ N 61)) P) (most)))
                                                (and (= (bignum.* P (least)) (bignum.negate (bignum-test.power (+ N 61))))
                                                     (and (= (bignum.* Ones -1) (bignum.negate Ones))
                                                          (= (bignum.* (bignum.negate Ones) (- 0 (most))) (bignum.* Ones (most)))))))))
                              [62 63 64 65 127 128 129 640]))))
(bignum-test.check "by 0" [0 0 0 0] (freeze [(bignum.* (big) 0) (bignum.* 0 (big)) (bignum.* 0 (bignum.negate (big))) (bignum.* (least) 0)]))
(bignum-test.check "and not what is no integer" [[error "bignum: foo is not an integer"] [error "bignum: foo is not an integer"]]
  (freeze [(bignum-test.result (freeze (bignum.* foo 0))) (bignum-test.result (freeze (bignum.* 0 foo)))]))
(bignum-test.check "sums with 0" true
  (freeze (and (= (bignum.+ (big) 0) (big)) (and (= (bignum.- (big) 0) (big)) (= (bignum.- 0 (big)) (bignum.negate (big)))))))
(bignum-test.check "with the least fixnum" true
  (freeze (and (= (bignum.+ (big) (least)) (bignum.- (big) (bignum-test.power 61)))
               (and (= (bignum.- (big) (least)) (bignum.+ (big) (bignum-test.power 61)))
                    (and (= (bignum.- (least) (big)) (bignum.negate (bignum.+ (big) (bignum-test.power 61))))
                         (= (bignum.+ (bignum-test.power 61) (least)) 0))))))
(define bignum-test.divides
  A D -> (let Q (bignum.quotient A D)
              R (bignum.remainder A D)
              F (bignum.floor-quotient A D)
              M (bignum.modulo A D)
           (and (= (bignum.+ (bignum.* Q D) R) A)
                (and (= (bignum.+ (bignum.* F D) M) A)
                     (and (= (bignum.quotient-remainder A D) (@p Q R))
                          (and (bignum.< (bignum.abs R) (bignum.abs D))
                               (and (or (= R 0) (= (bignum.sign R) (bignum.sign A)))
                                    (and (bignum.< (bignum.abs M) (bignum.abs D))
                                         (or (= M 0) (= (bignum.sign M) (bignum.sign D)))))))))))
(bignum-test.check "divisions by a fixnum" true
  (freeze (bignum-test.all? (map (/. D (bignum-test.all? (map (/. A (bignum-test.divides A D)) [(big) (bignum.negate (big)) (bignum-test.power 64)
                                                                                      (bignum.- (bignum-test.power 128) 1) (bignum.negate (bignum-test.power 61))])))
                              [1 -1 2 -2 10 -10 (most) (- 0 (most)) (least)]))))
(bignum-test.check "operands as they were" true
  (freeze (let A (bignum.- (bignum-test.power 128) 1)
               B (bignum.+ (bignum-test.power 64) 1)
               _ [(bignum.+ A B) (bignum.- A B) (bignum.* A B) (bignum.+ A 1) (bignum.- A 1) (bignum.* A 3) (bignum.quotient A 7) (bignum.gcd A B)]
            (and (= A (bignum.of-string "340282366920938463463374607431768211455")) (= B (bignum.of-string "18446744073709551617"))))))
(bignum-test.check "operands every isolate shares" true
  (freeze (let A (isolate.share (big))
            (and (= (bignum.+ A 1) (bignum.+ (big) 1)) (and (= (bignum.* A A) (bignum.* (big) (big))) (= (bignum.sqrt A) (bignum.sqrt (big))))))))

\\ ---------------------------------------------------------------------------
\\ Values: equal integers are =, hash alike, and go where any value does.

(bignum-test.check "equal" true (freeze (= (bignum.* (big) 10) (bignum.of-string "1234567890123456789012345678900"))))
(bignum-test.check "unequal" false (freeze (= (big) (bignum.negate (big)))))
(bignum-test.check "in a pattern's comparison" [a (bignum.expt 10 20)] (freeze [a (bignum.of-string "100000000000000000000")]))
(bignum-test.check "hashed alike" true (freeze (= (hash (big) 100000) (hash (bignum.of-string "123456789012345678901234567890") 100000))))
(bignum-test.check "a dictionary's key" found
  (freeze (let D (shen.dict 10) _ (shen.dict-> D (big) found) (shen.<-dict D (bignum.of-string "123456789012345678901234567890")))))
(bignum-test.shows "printed" "[123456789012345678901234567890 -1]" (freeze [(big) -1]))
(bignum-test.check "integer?" [true true false false false]
  (freeze (map (/. X (bignum.integer? X)) [1 (big) 1.5 "1" [1]])))

\\ ---------------------------------------------------------------------------
\\ Division, with each pair of signs.

(define bignum-test.signs
  F -> (map (/. P (F (fst P) (snd P))) [(@p 7 2) (@p -7 2) (@p 7 -2) (@p -7 -2)]))
(define bignum-test.big-signs
  F -> (let M (bignum.expt 10 30)
            N (bignum.* 2 M)
            A (bignum.* 7 M)
         (map (/. P (F (fst P) (snd P)))
              [(@p A N) (@p (bignum.negate A) N) (@p A (bignum.negate N)) (@p (bignum.negate A) (bignum.negate N))])))

(bignum-test.check "quotients" [3 -3 -3 3] (freeze (bignum-test.signs (/. X (/. Y (bignum.quotient X Y))))))
(bignum-test.check "remainders" [1 -1 1 -1] (freeze (bignum-test.signs (/. X (/. Y (bignum.remainder X Y))))))
(bignum-test.check "floor quotients" [3 -4 -4 3] (freeze (bignum-test.signs (/. X (/. Y (bignum.floor-quotient X Y))))))
(bignum-test.check "moduli" [1 1 -1 -1] (freeze (bignum-test.signs (/. X (/. Y (bignum.modulo X Y))))))
(bignum-test.check "large quotients" [3 -3 -3 3] (freeze (bignum-test.big-signs (/. X (/. Y (bignum.quotient X Y))))))
(bignum-test.check "large remainders" [1 -1 1 -1]
  (freeze (map (/. R (bignum.quotient R (bignum.expt 10 30))) (bignum-test.big-signs (/. X (/. Y (bignum.remainder X Y)))))))
(bignum-test.check "large floor quotients" [3 -4 -4 3] (freeze (bignum-test.big-signs (/. X (/. Y (bignum.floor-quotient X Y))))))
(bignum-test.check "large moduli" [1 1 -1 -1]
  (freeze (map (/. R (bignum.quotient R (bignum.expt 10 30))) (bignum-test.big-signs (/. X (/. Y (bignum.modulo X Y)))))))
(bignum-test.check "both at once" (@p 61728394506172839 -12345)
  (freeze (bignum.quotient-remainder (bignum.- (bignum.* -2000000000 61728394506172839) 12345) -2000000000)))
(bignum-test.check "both at once, small" (@p -3 -1) (freeze (bignum.quotient-remainder -7 2)))
(set by-zero [error "bignum: division by zero"])
(bignum-test.check "by zero" [(value by-zero) (value by-zero) (value by-zero) (value by-zero) (value by-zero)]
  (freeze (map (/. F (bignum-test.result (freeze ((F (big)) 0))))
               [(/. X (/. Y (bignum.quotient X Y))) (/. X (/. Y (bignum.remainder X Y))) (/. X (/. Y (bignum.modulo X Y)))
                (/. X (/. Y (bignum.floor-quotient X Y))) (/. X (/. Y (bignum.quotient-remainder X Y)))])))
(bignum-test.check "a power modulo 0" (value by-zero) (freeze (bignum.expt-mod 2 10 0)))
(bignum-test.check "an inverse modulo 0" (value by-zero) (freeze (bignum.invert 2 0)))

\\ ---------------------------------------------------------------------------
\\ Order.

(bignum-test.check "in order" [-1 -1 -1 -1 -1 -1 0 1]
  (freeze [(bignum.compare (bignum.negate (big)) (least)) (bignum.compare (least) (most)) (bignum.compare (most) (bignum.expt 2 61))
           (bignum.compare (bignum.expt 2 61) (bignum.expt 2 63)) (bignum.compare (bignum.expt 2 64) (big))
           (bignum.compare (bignum.negate (bignum.+ (big) 1)) (bignum.negate (big))) (bignum.compare (big) (big))
           (bignum.compare (big) 0)]))
(bignum-test.check "comparisons" [true false false true true true false]
  (freeze [(bignum.< (most) (big)) (bignum.> (most) (big)) (bignum.>= (least) (big)) (bignum.<= (big) (big))
           (bignum.> (big) (bignum.negate (big))) (bignum.< 1 2) (bignum.<= 2 1)]))
(bignum-test.check "signs" [-1 0 1 -1 1] (freeze (map (fn bignum.sign) [-5 0 5 (bignum.negate (big)) (big)])))
(bignum-test.check "parity" [true false true false] (freeze (map (fn bignum.even?) [0 -3 (bignum.expt 2 70) (bignum.+ (bignum.expt 2 70) 1)])))
(bignum-test.check "odd" [false true] (freeze (map (fn bignum.odd?) [(bignum.expt 2 70) -1])))
(bignum-test.check "magnitudes" true (freeze (and (= (bignum.abs (bignum.negate (big))) (big)) (= (bignum.abs -5) 5))))

\\ ---------------------------------------------------------------------------
\\ Powers, roots and number theory.

(bignum-test.shows "a power" "1267650600228229401496703205376" (freeze (bignum.expt 2 100)))
(bignum-test.check "powers of 0, 1 and -1" [1 0 1 1 -1 1]
  (freeze [(bignum.expt 0 0) (bignum.expt 0 (most)) (bignum.expt 1 (most)) (bignum.expt -1 0) (bignum.expt -1 (most)) (bignum.expt 0 0)]))
(bignum-test.check "a power of a large number" true (freeze (= (bignum.expt (big) 3) (bignum.* (big) (bignum.* (big) (big))))))
(bignum-test.check "a negative exponent" [error "bignum: -1 is not a fixnum from 0"] (freeze (bignum.expt 2 -1)))
(bignum-test.check "Fermat" 1
  (freeze (bignum.expt-mod 3 (bignum.- (bignum.expt 2 127) 2) (bignum.- (bignum.expt 2 127) 1))))
(bignum-test.check "a negative power" 4 (freeze (bignum.expt-mod 3 -1 11)))
(bignum-test.check "a power modulo 1" 0 (freeze (bignum.expt-mod 3 5 1)))
(bignum-test.check "an inverse" 4 (freeze (bignum.invert 3 11)))
(bignum-test.check "no inverse" [error "bignum.invert: no inverse modulo that"] (freeze (bignum.invert 2 4)))
(bignum-test.check "no negative power" [error "bignum.invert: no inverse modulo that"] (freeze (bignum.expt-mod 2 -3 4)))
(bignum-test.check "divisors" [6 (bignum.expt 10 20) 0 5 36]
  (freeze [(bignum.gcd 12 -18) (bignum.gcd (bignum.expt 10 20) (bignum.expt 10 40)) (bignum.gcd 0 0) (bignum.gcd 0 -5) (bignum.lcm 12 18)]))
(bignum-test.check "Bezout" true
  (freeze (let G (bignum.gcd-extended (big) (bignum.expt 3 50))
            (= (fst G) (bignum.+ (bignum.* (big) (fst (snd G))) (bignum.* (bignum.expt 3 50) (snd (snd G))))))))
(bignum-test.check "square roots" [0 1 1 (bignum.expt 10 20) 9]
  (freeze [(bignum.sqrt 0) (bignum.sqrt 1) (bignum.sqrt 3) (bignum.sqrt (bignum.+ (bignum.expt 10 40) 5)) (bignum.sqrt 99)]))
(bignum-test.check "a negative root" [error "bignum.sqrt: a negative integer"] (freeze (bignum.sqrt -1)))
(bignum-test.check "squares" [true true false true false] (freeze (map (fn bignum.square?) [0 49 50 (bignum.expt 10 40) -4])))
(bignum-test.check "primes" [false false false true true false false true false]
  (freeze (map (fn bignum.prime?) [-7 0 1 2 97 561 (bignum.expt 10 30) (bignum.- (bignum.expt 2 127) 1) (bignum.- (bignum.expt 2 128) 1)])))
(bignum-test.check "next primes" [2 2 3 11] (freeze (map (fn bignum.next-prime) [-5 0 2 7])))
(bignum-test.shows "a large next prime" "100000000000000000039" (freeze (bignum.next-prime (bignum.expt 10 20))))
(bignum-test.shows "a factorial" "265252859812191058636308480000000" (freeze (bignum.factorial 30)))
(bignum-test.check "binomials" [1 0 10 (bignum.of-string "100891344545564193334812497256") 6]
  (freeze [(bignum.binomial 5 0) (bignum.binomial 5 6) (bignum.binomial 5 2) (bignum.binomial 100 50) (bignum.binomial -3 2)]))
(bignum-test.shows "a Fibonacci number" "280571172992510140037611932413038677189525" (freeze (bignum.fibonacci 200)))

\\ ---------------------------------------------------------------------------
\\ Bits.

(bignum-test.check "bit lengths" [0 1 1 8 9 61 62 62 64 65 96 97]
  (freeze (map (fn bignum.bit-length) [0 1 -1 255 256 (most) (least) (bignum.expt 2 61) (bignum.expt 2 63) (bignum.expt 2 64)
                                    (bignum.expt 2 95) (bignum.negate (bignum.expt 2 96))])))
(bignum-test.check "as in two's complement" true
  (freeze (and (= (bignum.bit-and (bignum.- (bignum.expt 2 70) 1) -256) (bignum.- (bignum.expt 2 70) 256))
               (and (= (bignum.bit-or (bignum.negate (bignum.expt 2 70)) 1) (bignum.+ (bignum.negate (bignum.expt 2 70)) 1))
                    (= (bignum.bit-xor (big) (bignum.bit-not (big))) -1)))))
(bignum-test.check "small ones" [8 14 6 -13] (freeze [(bignum.bit-and 12 10) (bignum.bit-or 12 10) (bignum.bit-xor 12 10) (bignum.bit-not 12)]))
(bignum-test.check "a bit" [true false true false true true false true]
  (freeze [(bignum.bit-set? 5 0) (bignum.bit-set? 5 1) (bignum.bit-set? 5 2) (bignum.bit-set? 5 1000) (bignum.bit-set? -1 1000)
           (bignum.bit-set? (bignum.expt 2 70) 70) (bignum.bit-set? (bignum.expt 2 70) 69) (bignum.bit-set? (bignum.negate (bignum.expt 2 70)) 75)]))
(bignum-test.check "counts" [0 8 100] (freeze [(bignum.bit-count 0) (bignum.bit-count 255) (bignum.bit-count (bignum.- (bignum.expt 2 100) 1))]))
(bignum-test.check "a negative count" [error "bignum.bit-count: a negative integer"] (freeze (bignum.bit-count -1)))
(bignum-test.check "shifts" [0 40 (bignum.* -5 (bignum.expt 2 70)) -3 0 -1 -1 1 2]
  (freeze [(bignum.shift-left 0 (bignum.to-fixnum 2147483648)) (bignum.shift-left 5 3) (bignum.shift-left -5 70)
           (bignum.shift-right (bignum.* -5 (bignum.expt 2 70)) 71) (bignum.shift-right 5 100) (bignum.shift-right -5 100)
           (bignum.shift-right (bignum.negate (big)) 5000) (bignum.shift-right (bignum.expt 2 70) 70) (bignum.shift-right 5 1)]))
(bignum-test.check "by a negative count" [error "bignum: -1 is not a fixnum from 0"] (freeze (bignum.shift-left 1 -1)))

\\ ---------------------------------------------------------------------------
\\ Strings, fixnums and floats.

(bignum-test.check "bases" ["-ff" "1001" "zz" "10000000000000000000000000" "-10000000000000000000000000"]
  (freeze [(bignum.to-string-base -255 16) (bignum.to-string-base 9 2) (bignum.to-string-base 1295 36)
           (bignum.to-string-base (bignum.expt 2 100) 16) (bignum.to-string-base (bignum.negate (bignum.expt 2 100)) 16)]))
(bignum-test.check "read" [-255 255 0 0 7 true]
  (freeze [(bignum.of-string-base "-FF" 16) (bignum.of-string-base "fF" 16) (bignum.of-string "-0") (bignum.of-string "000")
           (bignum.of-string "0007") (= (bignum.of-string (bignum.to-string (big))) (big))]))
(map (/. S (bignum-test.check S [error (make-string "bignum.of-string: ~S is not an integer in base 10" S)]
             (freeze (bignum.of-string S))))
     ["" "-" "+1" "1 2" " 1" "1 " "--1" "1.5" "0x10" "1a" "1e5"])
(bignum-test.check "a bad digit" [error "bignum.of-string: c#34;12c#34; is not an integer in base 2"] (freeze (bignum.of-string-base "12" 2)))
(bignum-test.check "a bad base" [error "bignum: 37 is not a base from 2 to 36"] (freeze (bignum.to-string-base 5 37)))
(bignum-test.check "to fixnums" [5 [error "bignum.to-fixnum: integer overflow"]]
  (freeze [(bignum.to-fixnum (bignum.- (bignum.+ (most) 1) 2305843009213693947)) (bignum-test.result (freeze (bignum.to-fixnum (big))))]))
(bignum-test.check "from floats" [1 -1 0 true true]
  (freeze [(bignum.of-float 1.9) (bignum.of-float -1.9) (bignum.of-float 0.5) (= (bignum.of-float 1e30) (bignum.of-string "1000000000000000019884624838656"))
           (= (bignum.of-float -1e30) (bignum.of-string "-1000000000000000019884624838656"))]))
(set inf (* 1e308 1e308))
(bignum-test.check "not from an infinity or a NaN" true
  (freeze (and (cons? (bignum-test.result (freeze (bignum.of-float (value inf)))))
               (cons? (bignum-test.result (freeze (bignum.of-float (- (value inf) (value inf)))))))))
\\ 2^100 + 2^47 is halfway between two floats, and one more or less is not.
(bignum-test.check "the nearest floats" [1e30 -1e30 true true true]
  (freeze (let Half (bignum.+ (bignum.expt 2 100) (bignum.expt 2 47))
               Low (bignum.to-float (bignum.expt 2 100))
               High (bignum.to-float (bignum.+ (bignum.expt 2 100) (bignum.expt 2 48)))
            [(bignum.to-float (bignum.expt 10 30)) (bignum.to-float (bignum.negate (bignum.expt 10 30)))
             (= (bignum.to-float Half) Low) (= (bignum.to-float (bignum.+ Half 1)) High) (not (= Low High))])))
(bignum-test.check "the largest float, and past it" [true true true]
  (freeze (let Max (bignum.* (bignum.- (bignum.expt 2 53) 1) (bignum.expt 2 971))
            [(= (bignum.of-float (bignum.to-float Max)) Max)
             (= (bignum-test.result (freeze (bignum.to-float (bignum.- (bignum.expt 2 1024) 1))))
                [error "bignum.to-float: the integer is too large for a float"])
             (= (bignum-test.result (freeze (bignum.to-float (bignum.expt 10 400))))
                [error "bignum.to-float: the integer is too large for a float"])])))

\\ ---------------------------------------------------------------------------
\\ What is refused.

(bignum-test.check "not an integer" [error "bignum: c#34;xc#34; is not an integer"] (freeze (bignum.+ "x" 1)))
(bignum-test.check "nor a float" [error "bignum: 1.5 is not an integer"] (freeze (bignum.* 2 1.5)))
(bignum-test.check "nor on the right" [error "bignum: [1] is not an integer"] (freeze (bignum.< (big) [1])))
(bignum-test.check "nor for a predicate" [error "bignum: foo is not an integer"] (freeze (bignum.even? foo)))
(bignum-test.check "nor a conversion" [error "bignum: 1.5 is not an integer"] (freeze (bignum.of 1.5)))
(set too-large [error "bignum: the result would have more than 2^31 bits"])
(bignum-test.check "results too large" [(value too-large) (value too-large) (value too-large) (value too-large) (value too-large) (value too-large)]
  (freeze (map (/. F (bignum-test.result F))
               [(freeze (bignum.expt 10 (most))) (freeze (bignum.expt (big) 100000000)) (freeze (bignum.shift-left 1 3000000000))
                (freeze (bignum.factorial 100000000)) (freeze (bignum.fibonacci (most))) (freeze (bignum.binomial (big) 100000000))])))

\\ ---------------------------------------------------------------------------
\\ Registers: grown by a large operand or result, they go back, and the next operation makes others.

(bignum-test.check "large ones" true
  (freeze (let A (bignum.expt 3 8000000)
               B (bignum.* A A)
               Released (empty? (value bignum.*registers*))
            (and Released (and (= (bignum.sqrt B) A) (= (bignum.+ (most) 1) (bignum.expt 2 61)))))))
(define bignum-test.doubled
  _ 0 -> true
  A N -> (let B (bignum.+ (bignum.* A (bignum.expt 2 (bignum.bit-length A))) 1)
           (and (= (bignum.quotient B (bignum.expt 2 (bignum.bit-length A))) A) (bignum-test.doubled B (- N 1)))))
(bignum-test.check "grown in steps" true (freeze (bignum-test.doubled 1 14)))

(output "~A passed, ~A failed~%" (value bignum-test.*passed*) (value bignum-test.*failed*))
