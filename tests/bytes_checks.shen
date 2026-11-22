(set *bytes-failed* 0)
(set *bytes-passed* 0)

(set *blank* (bytes.class [9 32]))
(define bytes-test.blank -> (value *blank*))

(define check
  Name Expected Actual -> (if (= Expected Actual)
                              (set *bytes-passed* (+ 1 (value *bytes-passed*)))
                              (do (output "FAIL ~A: expected ~S, got ~S~%" Name Expected Actual)
                                  (set *bytes-failed* (+ 1 (value *bytes-failed*))))))

(define raises?
  F -> (trap-error (do (thaw F) false) (/. E true)))

\\ Plain Shen references for each, over the same storage and range.
(define ref.find
  B At End Byte -> (cases (>= At End) End
                          (= (shen-jit.u8 B At) Byte) At
                          true (ref.find B (+ At 1) End Byte)))

(define ref.member?
  C Byte -> (= 1 (shen-jit.bit-and 1 (shen-jit.shift-right (shen-jit.u8 C (shen-jit.shift-right Byte 3))
                                                          (shen-jit.bit-and Byte 7)))))

(define ref.span
  B At End C -> (cases (>= At End) End
                       (ref.member? C (shen-jit.u8 B At)) (ref.span B (+ At 1) End C)
                       true At))

(define ref.span-back
  B Start End C -> (cases (<= End Start) Start
                          (ref.member? C (shen-jit.u8 B (- End 1))) (ref.span-back B Start (- End 1) C)
                          true End))

(define random-bytes
  N Seed -> (random-fill (shen-jit.bytes N) 0 N Seed))

\\ A small generator of bytes from few values, so that ranges hold what is looked for.
(define random-fill
  B I N _ -> B where (= I N)
  B I N Seed -> (let Next (shen.mod (+ (* Seed 75) 74) 65537)
                  (do (shen-jit.u8! B I (+ 30 (shen-jit.bit-and (shen-jit.shift-right Next 4) 63)))
                      (random-fill B (+ I 1) N Next))))

(define compare-random
  0 _ -> true
  K Seed ->
    (let N (+ 1 (shen.mod Seed 300))
         B (random-bytes N Seed)
         At (shen.mod (* Seed 7) N)
         End (+ At (shen.mod (* Seed 13) (+ 1 (- N At))))
         Byte (+ 30 (shen.mod Seed 64))
         C (bytes.class [[(+ 30 (shen.mod Seed 40)) (+ 50 (shen.mod Seed 40))] "AEIOU"])
         _ (check "find matches Shen" (ref.find B At End Byte) (bytes.find B At End Byte))
         _ (check "span matches Shen" (ref.span B At End C) (bytes.span B At End C))
         _ (check "span-back matches Shen" (ref.span-back B At End C) (bytes.span-back B At End C))
         _ (check "class-not finds" (ref.span B At End (bytes.class-not C)) (bytes.span B At End (bytes.class-not C)))
      (compare-random (- K 1) (shen.mod (+ (* Seed 31) 17) 1000003))))

(compare-random 400 7)

(let B (shen-jit.string->bytes "Content-Type:  text/plain c#9;")
     S "abc:def"
  (do (check "find" 12 (bytes.find B 0 27 58))
      (check "find, absent" 5 (bytes.find B 0 5 58))
      (check "find, empty" 3 (bytes.find B 3 3 58))
      (check "find in a string" 3 (bytes.find S 0 7 58))
      (check "find from an offset" 7 (bytes.find "a:b:c:d" 4 7 0))
      (check "find past the end raises" true (raises? (freeze (bytes.find S 0 8 0))))
      (check "find a number that is no byte" [10 10 36 36 20]
             (let Short "0123456789" Long "abcdefghijklmnopqrstuvwxyz0123456789" Ff (shen-jit.bytes 20)
                  _ (shen-jit.u8! Ff 5 255)
               [(bytes.find Short 0 10 304) (bytes.find Short 0 10 -208) (bytes.find Long 0 36 304)
                (bytes.find Long 0 36 -208) (bytes.find Ff 0 20 -1)]))
      (check "span of blanks" 15 (bytes.span B 13 27 (bytes-test.blank)))
      (check "span to the end" 27 (bytes.span B 25 27 (bytes-test.blank)))
      (check "span-back of blanks" 25 (bytes.span-back B 15 27 (bytes-test.blank)))
      (check "span-back over all" 25 (bytes.span-back B 25 27 (bytes-test.blank)))
      (check "span-back over none" 12 (bytes.span-back B 0 12 (bytes-test.blank)))
      (check "class of a range and bytes" 3 (bytes.span "019a" 0 4 (bytes.class [[48 57] 10])))
      (check "a bad member raises" true (raises? (freeze (bytes.class [sym]))))
      (check "typed field" ["content-type" "text/plain" "636f" "-1"] (bytes-test.field B 0 27 (bytes-test.blank)))
      (check "typed decimal" ["x" "42" "783a" "42"] (bytes-test.field (shen-jit.string->bytes "x: 42") 0 5 (bytes-test.blank)))))

(let B (shen-jit.string->bytes "MiXeD 09 @[`{ ZZ")
     _ (bytes.lower! B 0 16)
  (do (check "lower!" "mixed 09 @[`{ zz" (shen-jit.bytes->string B 0 16))
      (check "lower! on a string raises" true (raises? (freeze (bytes.lower! "AB" 0 2))))
      (check "lower" "content-type: x" (bytes.lower "Content-Type: X"))
      (check "lower leaves its text" "AB" (let T "AB" _ (bytes.lower T) T))))

(define all-bytes
  B 256 -> B
  B I -> (all-bytes (shen-jit.u8! B I I) (+ I 1)))

(define ref.hex-digit
  N -> (if (< N 10) (+ N 48) (+ N 87)))

(define ref.hex
  B I End Acc -> (if (= I End) Acc
                     (let X (shen-jit.u8 B I)
                       (ref.hex B (+ I 1) End
                         (cn Acc (cn (n->string (ref.hex-digit (shen-jit.shift-right X 4)))
                                     (n->string (ref.hex-digit (shen-jit.bit-and X 15)))))))))

(let B (all-bytes (shen-jit.bytes 256) 0)
     Hex (bytes.hex B 0 256)
     Back (shen-jit.bytes 256)
     Upper (shen-jit.string->bytes Hex)
     _ (bytes.lower! Upper 0 0)
  (do (check "hex of every byte" (ref.hex B 0 256 "") Hex)
      (check "hex of nothing" "" (bytes.hex B 9 9))
      (check "unhex! of every byte" B (bytes.unhex! Back 0 Hex 0 512))
      (check "unhex! of capitals" (shen-jit.string->bytes "Ab") (bytes.unhex! (shen-jit.bytes 2) 0 "4162" 0 4))
      (check "unhex! of capital digits" 171 (shen-jit.u8 (bytes.unhex! (shen-jit.bytes 1) 0 "AB" 0 2) 0))
      (check "unhex! at an offset" 239 (shen-jit.u8 (bytes.unhex! (shen-jit.bytes 3) 2 "xxeF" 2 4) 2))
      (check "unhex! of no digit" [] (bytes.unhex! (shen-jit.bytes 1) 0 "0g" 0 2))
      (check "unhex! of an odd count" [] (bytes.unhex! (shen-jit.bytes 1) 0 "abc" 0 3))
      (check "unhex! past To raises" true (raises? (freeze (bytes.unhex! (shen-jit.bytes 1) 0 "abcd" 0 4))))))

(do (check "decimal" 1234 (bytes.decimal "x1234" 1 5 10000))
    (check "decimal at its limit" 10000 (bytes.decimal "10000" 0 5 10000))
    (check "decimal past its limit" -2 (bytes.decimal "10001" 0 5 10000))
    (check "decimal past a limit by tens" -2 (bytes.decimal "100000" 0 6 10000))
    (check "decimal with zeros first" 7 (bytes.decimal "0007" 0 4 10))
    (check "decimal of no digit" -1 (bytes.decimal "12a" 0 3 1000))
    (check "decimal of nothing" -1 (bytes.decimal "12" 1 1 1000))
    (check "decimal of a sign" -1 (bytes.decimal "-1" 0 2 1000))
    (check "decimal below a limit below 0" [-2 -2 -2 -2 -1]
           [(bytes.decimal "0" 0 1 -1) (bytes.decimal "7" 0 1 -5) (bytes.decimal "12345" 0 5 -10)
            (bytes.decimal "99999999999999999999999" 0 23 -10) (bytes.decimal "a1" 0 2 -1)])
    (check "decimal of the largest fixnum" 2305843009213693951
           (bytes.decimal "2305843009213693951" 0 19 2305843009213693951))
    (check "decimal past the largest fixnum" -2
           (bytes.decimal "2305843009213693952" 0 19 2305843009213693951)))

\\ A class written with constants is a constant of the code, so another isolate, whose globals are
\\ unbound, has it too.
(define blank-span
  [Text Out] -> (channel.send Out (bytes.span Text 0 (shen-jit.bytes-length Text) (bytes.class [9 32]))))

(let Replies (channel.new 1)
     _ (isolate.spawn blank-span [" c#9; x" (channel.sender Replies)])
  (check "a class in another isolate" 3 (channel.receive Replies)))

(output "~A passed, ~A failed~%" (value *bytes-passed*) (value *bytes-failed*))
