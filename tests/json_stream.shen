\\ JSON values read from an I/O reader at every chunk size. Load buffer.shen, io.shen, grammar.shen and json.shen.
(set json-stream.passed 0)
(set json-stream.failed 0)

(define json-stream.check
  Name Expected F ->
    (let Actual (trap-error (thaw F) (/. X [raised (error-to-string X)]))
      (if (= Actual Expected)
          (set json-stream.passed (+ 1 (value json-stream.passed)))
          (do (set json-stream.failed (+ 1 (value json-stream.failed)))
              (output "FAIL ~A: wanted ~S, got ~S~%" Name Expected Actual)))))

(define json-stream.feed
  Wire Step ->
    (let State (io.record [0])
      (io.endpoint "chunks" read 1048576
        (/. Out (let At (<-address State 0)
                     N (io.min Step (io.min (shen-jit.bytes-length Out) (- (buffer.length Wire) At)))
                  (if (= N 0)
                      [eof]
                      (do (shen-jit.copy-bytes Out 0 (buffer.owner Wire) (+ (buffer.offset Wire) At) N)
                          (address-> State 0 (+ At N))
                          [read N]))))
        (function io.no-write) (freeze [ok]))))

(define json-stream.values
  R Acc -> (let Got (trap-error (json.read R []) (/. E [raised (error-to-string E)]))
             (if (= (hd Got) ok) (json-stream.values R [(hd (tl Got)) | Acc]) [(reverse Acc) Got])))

(define json-stream.read
  Text Step -> (json-stream.values (io.reader (json-stream.feed (buffer.from-string Text) Step) []) []))

(define json-stream.join
  [] -> ""
  [Doc | Docs] -> (cn Doc (cn " c#10;c#9;" (json-stream.join Docs))))

(define json-stream.all?
  _ [] -> true
  F [X | Xs] -> (and (F X) (json-stream.all? F Xs)))

(define json-stream.steps
  N N -> [N]
  I N -> [I | (json-stream.steps (+ I 1) N)])

(set json-stream.docs
  ["{c#34;ac#34;:[-0,true,null],c#34;bc#34;:{}}" "[[],null,{}]" "c#34;c#92;u00e9c#92;u03bbc#92;ud83dc#92;ude00c#92;u0000c#34;"
   "-123456789012345678901234567890.001e+10000" "42" "0" "c#34;déjà vu, 日本語c#34;" "[1,[2,[3,[4]]]]"
   "{c#34;keyc#34;:c#34;valuec#92;nwithc#92;tescapesc#34;,c#34;nc#34;:-1.5E-3}" "true" "false" "null" "c#34;c#34;"])

(let Docs (value json-stream.docs)
     Text (json-stream.join Docs)
     Expected [(map (/. D (json.parse D [])) Docs) [eof]]
  (json-stream.check "every chunk size gives the complete decoder's values" true
    (freeze (json-stream.all? (/. Step (= (json-stream.read Text Step) Expected))
                    (json-stream.steps 1 (shen-jit.bytes-length (shen-jit.string->bytes Text)))))))

(json-stream.check "only whitespace is eof" [[] [eof]] (freeze (json-stream.read " c#10; " 1)))
(json-stream.check "a number that ends with the input" [[[number "12"]] [eof]] (freeze (json-stream.read "12" 1)))
(json-stream.check "a syntax error at its place in the stream" [[[[number "1"]]] [raised "json: byte 8: expected value"]]
  (freeze (json-stream.read "[1]  [3,, 4]" 2)))
(json-stream.check "a value the input cut" [[[[number "1"]]] [raised "json: byte 9: input ended"]]
  (freeze (json-stream.read "[1] [3, 4" 1)))
(json-stream.check "a literal the input cut" [[] [raised "json: byte 3: input ended"]]
  (freeze (json-stream.read "tru" 1)))
(json-stream.check "the depth limit holds" [raised "json: byte 2: nesting limit"]
  (freeze (trap-error (json.read (io.reader (json-stream.feed (buffer.from-string "[[1]]") 1) []) [[depth-limit 1]])
                      (/. E [raised (error-to-string E)]))))
(let R (io.reader (json-stream.feed (buffer.from-string "{c#34;ac#34;:1}c#10;rest") 3) [])
     First (json.read R [])
  (json-stream.check "what follows a value stays unread" [[ok [object ["a" [number "1"]]]] "c#10;rest"]
    (freeze [First (buffer.string (hd (tl (io.read-all R 100))))])))

(json-stream.check "closing quote needs no further read" [[ok "x"] 1]
  (freeze
    (let Calls (io.record [0])
         Wire (buffer.from-string "c#34;xc#34;")
         E (io.endpoint "complete string" read 16
             (/. B
               (let N (<-address Calls 0)
                    _ (address-> Calls 0 (+ N 1))
                 (if (= N 0)
                     (do (shen-jit.copy-bytes B 0 (buffer.owner Wire) 0 3)
                         [read 3])
                     [error (io.error read "complete string"
                                      "unnecessary read")])))
             (function io.no-write) (freeze [ok]))
         Got (json.read (io.reader E []) [])
         _ (io.close E)
      [Got (<-address Calls 0)])))

(json-stream.check "surrogate errors use the stream offset"
  [[[number "0"]] [raised "json: byte 3: missing low surrogate"]]
  (freeze
    (json-stream.read "0 c#34;c#92;ud800c#34;" 1)))

(output "~A passed, ~A failed~%" (value json-stream.passed) (value json-stream.failed))
