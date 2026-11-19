\\ Independent format fixtures for tools/buffer-parsers.shen.
(set buffer-example-test.*passed* 0)
(set buffer-example-test.*failed* 0)
(define buffer-example-test.check
  Name Expected F ->
    (let Got (trap-error (thaw F) (/. E [error (error-to-string E)]))
      (if (= Expected Got)
          (set buffer-example-test.*passed* (+ 1 (value buffer-example-test.*passed*)))
          (do (output "FAIL ~A: expected ~S, got ~S~%" Name Expected Got)
              (set buffer-example-test.*failed* (+ 1 (value buffer-example-test.*failed*)))))))
(define buffer-example-test.raises
  Name F -> (buffer-example-test.check Name true
              (freeze (trap-error (do (thaw F) false) (/. E true)))))
(define buffer-example-test.json
  Text -> (buffer-example.json (buffer.from-string Text)))

(buffer-example-test.check "nested values"
  [object ["a" [[number "-12.5e+3"] true false null [object] []]]]
  (freeze (buffer-example-test.json " {c#34;ac#34;:[-12.5e+3,true,false,null,{},[]]} c#10;")))
(buffer-example-test.check "empty string" "" (freeze (buffer-example-test.json "c#34;c#34;")))
(buffer-example-test.check "all simple escapes" "c#34;c#92;/c#8;c#12;c#10;c#13;c#9;"
  (freeze (buffer-example-test.json "c#34;c#92;c#34;c#92;c#92;c#92;/c#92;bc#92;fc#92;nc#92;rc#92;tc#34;")))
(buffer-example-test.check "Unicode scalar below 256" "c#195;c#169;"
  (freeze (buffer-example-test.json "c#34;c#92;u00e9c#34;")))
(buffer-example-test.check "surrogate pair" "c#240;c#159;c#152;c#128;"
  (freeze (buffer-example-test.json "c#34;c#92;uD83Dc#92;uDE00c#34;")))
(buffer-example-test.check "escaped NUL" "c#0;"
  (freeze (buffer-example-test.json "c#34;c#92;u0000c#34;")))
(buffer-example-test.check "raw UTF-8" "c#206;c#187;c#240;c#159;c#152;c#128;"
  (freeze (buffer-example-test.json "c#34;c#206;c#187;c#240;c#159;c#152;c#128;c#34;")))
(buffer-example-test.check "large exact numeric token" [number "9007199254740993"]
  (freeze (buffer-example-test.json "9007199254740993")))
(buffer-example-test.check "negative zero token" [number "-0"]
  (freeze (buffer-example-test.json "-0")))

(define buffer-example-test.nest
  0 Text -> Text
  N Text -> (buffer-example-test.nest (- N 1) (cn "[" (cn Text "]"))))
(buffer-example-test.check "nesting limit accepts 128 containers" true
  (freeze (do (buffer-example-test.json (buffer-example-test.nest 128 "0")) true)))
(buffer-example-test.raises "nesting limit rejects 129 containers"
  (freeze (buffer-example-test.json (buffer-example-test.nest 129 "[]"))))

(define buffer-example-test.invalid
  [] -> true
  [Text | Rest] -> (do (buffer-example-test.raises Text (freeze (buffer-example-test.json Text)))
                      (buffer-example-test.invalid Rest)))
(buffer-example-test.invalid
  ["" " " "nul" "true false" "nullx" "01" "-" "-.1" "+1" "1." "1e" "1e+" "NaN"
   "[1,]" "[,1]" "[1 2]" "{c#34;ac#34;:1,}" "{a:1}" "{c#34;ac#34; 1}"
   "{c#34;ac#34;:1,c#34;ac#34;:2}" "c#34;unterminated" "c#34;c#10;c#34;"
   "c#34;c#92;qc#34;" "c#34;c#92;u12xxc#34;" "c#34;c#92;uD800c#34;"
   "c#34;c#92;uDC00c#34;" "c#34;c#92;uD800c#92;u0041c#34;"
   "c#34;c#192;c#128;c#34;" "c#34;c#237;c#160;c#128;c#34;"
   "c#34;c#244;c#144;c#128;c#128;c#34;" "c#34;c#194;c#34;"])

(define buffer-example-test.truncated
  V N N -> true
  V I N -> (do (buffer-example-test.raises "truncated logical view"
                  (freeze (buffer-example.json (buffer.slice V 0 I))))
               (buffer-example-test.truncated V (+ I 1) N)))
(let Text "{c#34;ac#34;:[1,true,c#34;c#92;u00e9c#34;]}"
     Storage (buffer.from-string (cn "!" (cn Text "?")))
     V (buffer.slice Storage 1 (- (buffer.length Storage) 2))
  (do (buffer-example-test.check "nonzero logical input"
        [object ["a" [[number "1"] true "c#195;c#169;"]]]
        (freeze (buffer-example.json V)))
      (buffer-example-test.truncated V 0 (buffer.length V))))

\\ Header: tag 0x1234, big-endian length 3, then three payload bytes including NUL.
(let Raw (buffer.new 11) V (buffer.slice Raw 1 9)
     _ (buffer.u8-> V 0 18) _ (buffer.u8-> V 1 52) _ (buffer.u8-> V 5 3)
     _ (buffer.u8-> V 6 97) _ (buffer.u8-> V 7 0) _ (buffer.u8-> V 8 255)
     Result (buffer-example.packet V 3)
  (do (buffer-example-test.check "binary endian tag" 4660 (freeze (hd (tl Result))))
      (buffer-example-test.check "binary owned payload" "ac#0;c#255;"
        (freeze (buffer.string (buffer.wrap (hd (tl (tl Result)))))))
      (buffer-example-test.raises "binary limit" (freeze (buffer-example.packet V 2)))
      (buffer-example-test.raises "binary incomplete header" (freeze (buffer-example.packet (buffer.slice V 0 5) 3)))
      (buffer-example-test.raises "binary incomplete payload" (freeze (buffer-example.packet (buffer.slice V 0 8) 3)))
      (buffer-example-test.raises "binary trailing byte" (freeze (buffer-example.packet (buffer.slice Raw 1 10) 3)))
      (buffer.u8-> V 6 88)
      (buffer-example-test.check "payload survives mutation" 97
        (freeze (shen-jit.u8 (hd (tl (tl Result))) 0)))))

(output "~A passed, ~A failed~%" (value buffer-example-test.*passed*) (value buffer-example-test.*failed*))
