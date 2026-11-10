\\ JSON values, strict syntax, byte ownership, encoding bounds and exact integer conversion.
(set json-test.passed 0)
(set json-test.failed 0)

(define json-test.check
  Name Expected F ->
    (let Actual (trap-error (thaw F) (/. X [raised (error-to-string X)]))
      (if (= Actual Expected)
          (set json-test.passed (+ 1 (value json-test.passed)))
          (do (set json-test.failed (+ 1 (value json-test.failed)))
              (output "FAIL ~A: wanted ~S, got ~S~%" Name Expected Actual)))))

(define json-test.raises
  Name F -> (json-test.check Name true (freeze (trap-error (do (thaw F) false) (/. X true)))))

(define json-test.bytes
  _ _ [] -> true
  V At [Byte | Rest] -> (do (buffer.u8! V At Byte) (json-test.bytes V (+ At 1) Rest)))

(json-test.check "ordered object and exact tokens" [object ["a" [[number "-0"] true null]] ["b" [object]]]
  (freeze (json.parse " {c#34;ac#34;:[-0,true,null],c#34;bc#34;:{}} " [])))
(json-test.check "empty array differs from null and object" [[] null [object]]
  (freeze (json.parse "[[],null,{}]" [])))
(json-test.check "Unicode, paired surrogate and NUL" "éλ😀c#0;"
  (freeze (json.parse "c#34;c#92;u00e9c#92;u03bbc#92;ud83dc#92;ude00c#92;u0000c#34;" [])))
(json-test.check "very large numbers retain spelling" [number "-123456789012345678901234567890.001e+10000"]
  (freeze (json.parse "-123456789012345678901234567890.001e+10000" [])))
(json-test.check "encoding owns canonical escapes" "c#34;c#92;c#34;c#92;c#92;c#92;nc#92;tc#92;u0000é😀c#34;"
  (freeze (json.stringify "c#34;c#92;c#10;c#9;c#0;é😀" [])))
(json-test.check "native numbers encode" "[42,-7,1.25]" (freeze (json.stringify [42 -7 1.25] [])))
(json-test.check "token spelling survives encoding" "[1.00,-0,1E+009]"
  (freeze (json.stringify [[number "1.00"] [number "-0"] [number "1E+009"]] [])))
(json-test.check "largest integer" 2305843009213693951
  (freeze (json.integer (json.number "2305843009213693951"))))
(json-test.check "smallest integer" (- (- 0 2305843009213693951) 1)
  (freeze (json.integer (json.number "-2305843009213693952"))))
(json-test.check "integer conversion preserves exact native type" "1"
  (freeze (str (json.integer (json.number "1")))))
(json-test.check "logical input range" [number "1"]
  (freeze (json.decode (buffer.slice (buffer.from-string "!1!") 1 1) [])))
(let V (buffer.from-string "{c#34;xc#34;:c#34;stablec#34;}")
     Value (json.decode V [])
     _ (buffer.u8! V 6 88)
  (json-test.check "decoded strings own their bytes" [object ["x" "stable"]] (freeze Value)))

(map (/. Text (json-test.raises Text (freeze (json.parse Text []))))
  ["" " " "01" "-01" "+1" "-" ".1" "1." "1e" "1e+" "NaN" "Infinity"
   "truex" "null false" "[1,]" "[,1]" "[1 2]" "{a:1}" "{c#34;ac#34;:1,}"
   "{c#34;ac#34;:1,c#34;c#92;u0061c#34;:2}" "c#34;c#92;xc#34;" "c#34;c#10;c#34;"
   "c#34;c#92;ud800c#34;" "c#34;c#92;udc00c#34;" "c#34;c#92;ud800c#92;u0000c#34;"
   "c#34;c#92;uGGGGc#34;" "[" "{" "c#34;unterminated"])

(map (/. Bytes
       (json-test.raises "invalid UTF-8 decode"
         (freeze (let V (buffer.new (+ 2 (length Bytes)))
                      _ (buffer.u8! V 0 34)
                      _ (json-test.bytes V 1 Bytes)
                      _ (buffer.u8! V (- (buffer.length V) 1) 34)
                   (json.decode V [])))))
  [[128] [192 128] [224 128 128] [237 160 128] [244 144 128 128] [245 128 128 128] [226 130]])

(map (/. Token (json-test.raises "out of range integer" (freeze (json.integer (json.number Token)))))
  ["2305843009213693952" "-2305843009213693953" "1.0" "1e0"])
(map (/. Value (json-test.raises "invalid encoded value" (freeze (json.encode Value []))))
  [nope [number "01"] [object ["x" 1] ["x" 2]] [object [1 true]] [object ["x"]] [true | false]])
(json-test.raises "invalid UTF-8 encode"
  (freeze (let B (shen-jit.u8! (shen-jit.bytes 1) 0 255) (json.encode (shen-jit.bytes->string B 0 1) []))))
(json-test.raises "infinite native number"
  (freeze (let B (shen-jit.u32! (shen-jit.bytes 8) 4 2146435072) (json.encode (shen-jit.f64 B 0) []))))
(json-test.raises "NaN native number"
  (freeze (let B (shen-jit.u32! (shen-jit.bytes 8) 4 2146959360) (json.encode (shen-jit.f64 B 0) []))))
(json-test.raises "decode byte bound" (freeze (json.parse "[1]" [[byte-limit 2]])))
(json-test.raises "encode byte bound" (freeze (json.encode "x" [[byte-limit 2]])))
(json-test.raises "escape expansion bound" (freeze (json.encode "c#0;" [[byte-limit 7]])))
(json-test.check "exact encode byte bound" "c#34;c#92;u0000c#34;"
  (freeze (json.stringify "c#0;" [[byte-limit 8]])))
(json-test.raises "decode depth bound" (freeze (json.parse "[[]]" [[depth-limit 1]])))
(json-test.raises "encode depth bound" (freeze (json.encode [[]] [[depth-limit 1]])))
(json-test.check "exact container depth" [[]] (freeze (json.parse "[[]]" [[depth-limit 2]])))
(json-test.check "scalar at depth zero" true (freeze (json.parse "true" [[depth-limit 0]])))
(json-test.raises "unknown option" (freeze (json.parse "1" [[unknown 1]])))
(json-test.raises "duplicate option" (freeze (json.parse "1" [[byte-limit 1] [byte-limit 2]])))
(json-test.raises "excessive recursion option" (freeze (json.parse "1" [[depth-limit 257]])))

(let B (buffer.builder 1024)
     Source (buffer.from-string "abc")
     _ (buffer.append! B Source)
     _ (buffer.u8! Source 0 88)
     _ (buffer.append! B (buffer.new 700))
     _ (buffer.append-byte! B 255)
     Result (buffer.finish B)
  (do (json-test.check "builder grows and owns input" [704 "abc" 255]
        (freeze [(buffer.length Result) (buffer.string (buffer.slice Result 0 3)) (buffer.u8 Result 703)]))
      (json-test.raises "finished builder is sealed" (freeze (buffer.append-byte! B 0)))
      (json-test.raises "finish transfers storage once" (freeze (buffer.finish B)))))
(let B (buffer.builder 3)
     _ (buffer.append! B (buffer.from-string "abc"))
     _ (json-test.raises "builder byte bound" (freeze (buffer.append-byte! B 0)))
  (json-test.check "failed append preserves prefix" "abc" (freeze (buffer.string (buffer.finish B)))))
(let B (buffer.builder 2)
     _ (json-test.raises "builder rejects invalid byte" (freeze (buffer.append-byte! B 256)))
  (json-test.check "bad byte leaves builder unchanged" 0 (freeze (buffer.builder-length B))))
(json-test.check "empty builder with huge declared bound" 0
  (freeze (buffer.length (buffer.finish (buffer.builder 2305843009213693951)))))

(json-test.check "a literal cut short is the end of the input"
  [[raised "json: byte 2: unexpected end"] [raised "json: byte 1: invalid literal"]]
  (freeze (map (/. T (trap-error (json.parse T []) (/. X [raised (error-to-string X)]))) ["tr" "tx"])))

(output "~A passed, ~A failed~%" (value json-test.passed) (value json-test.failed))
