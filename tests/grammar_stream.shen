\\ Grammars read from an I/O reader as input arrives. Load buffer.shen, io.shen and grammar.shen first.
(set stream-test.passed 0)
(set stream-test.failed 0)

(define stream-test.check
  Name Expected F ->
    (let Actual (trap-error (thaw F) (/. X [raised (error-to-string X)]))
      (if (= Actual Expected)
          (set stream-test.passed (+ 1 (value stream-test.passed)))
          (do (set stream-test.failed (+ 1 (value stream-test.failed)))
              (output "FAIL ~A: wanted ~S, got ~S~%" Name Expected Actual)))))

\\ An endpoint that gives Step bytes a read, then Last: [eof], or an error.
(define stream-test.feed
  Wire Step Last ->
    (let State (io.record [0])
      (io.endpoint "chunks" read 1048576
        (/. Out (let At (<-address State 0)
                     N (io.min Step (io.min (shen-jit.bytes-length Out) (- (buffer.length Wire) At)))
                  (if (= N 0)
                      Last
                      (do (shen-jit.copy-bytes Out 0 (buffer.owner Wire) (+ (buffer.offset Wire) At) N)
                          (address-> State 0 (+ At N))
                          [read N]))))
        (function io.no-write) (freeze [ok]))))

(define stream-test.reader
  Text Step -> (io.reader (stream-test.feed (buffer.from-string Text) Step [eof]) []))

(define stream-test.fail
  At Message -> [fail At Message])

(defgrammar <s.digit> B := (- B 48) where (and (>= B 48) (<= B 57));)
(defgrammar <s.digits> (+ <s.digit>);)
(defgrammar <s.word> (text <s.digits>) ";" := <s.digits>;)
(defgrammar <s.letter> B where (and (>= B 97) (<= B 122));)
(defgrammar <s.letters> (+ <s.letter>);)
(defgrammar <s.spanned> "<" (span <s.letters>) ">" := <s.letters>;)
(defgrammar (<s.repeat> Byte) (+ (<s.is> Byte)) ";";)
(defgrammar (<s.is> Q) B where (= B Q);)
(defgrammar <s.literal> "true" := true; "tree" := tree;)
(defgrammar <s.changing> "a" := one;)

(define stream-test.words
  R Acc -> (let Got (grammar.read <s.word> R (function stream-test.fail))
             (if (= (hd Got) ok) (stream-test.words R [(hd (tl Got)) | Acc]) [(reverse Acc) Got])))

(map (/. Step (stream-test.check (make-string "words in chunks of ~A" Step)
                [["12" "345" "6789" "0"] [fail 16 "input ended"]]
                (freeze (stream-test.words (stream-test.reader "12;345;6789;0;77" Step) []))))
     [1 2 3 7 100])

(let R (stream-test.reader "12;345;rest of it" 2)
     _ (grammar.read <s.word> R (function stream-test.fail))
  (do (stream-test.check "what follows the value stays in the reader" [ok "345"]
        (freeze (grammar.read <s.word> R (function stream-test.fail))))
      (stream-test.check "and is read as it is" "rest of it"
        (freeze (buffer.string (hd (tl (io.read-all R 100))))))))

(stream-test.check "nothing at all is eof" [eof]
  (freeze (grammar.read <s.word> (stream-test.reader "" 1) (function stream-test.fail))))
(stream-test.check "a syntax error, at its place in the stream" [[ok "12"] [fail 3 "no match"]]
  (freeze (let R (stream-test.reader "12;x4;" 1)
            [(grammar.read <s.word> R (function stream-test.fail)) (grammar.read <s.word> R (function stream-test.fail))])))
(stream-test.check "lookahead that reached the end" [fail 3 "input ended"]
  (freeze (grammar.read <s.literal> (stream-test.reader "tre" 1) (function stream-test.fail))))
(stream-test.check "lookahead that backtracked" [ok tree]
  (freeze (grammar.read <s.literal> (stream-test.reader "tree" 1) (function stream-test.fail))))
(stream-test.check "a value larger than the reader's buffer" [fail 8 "input exceeds the limit"]
  (freeze (grammar.read <s.word> (io.reader (stream-test.feed (buffer.from-string "1234567890;") 3 [eof]) [[chunk-size 8]])
                        (function stream-test.fail))))
(stream-test.check "the reader's error, with nothing consumed" [error "broken" 0]
  (freeze (let E (stream-test.feed (buffer.from-string "12") 1 [error (io.error read "chunks" "broken")])
               R (io.reader E [])
               Got (grammar.read <s.word> R (function stream-test.fail))
            [(hd Got) (io.error-message (hd (tl Got))) (io.position R)])))
(stream-test.check "arguments from the entry point" [ok 4 ok 7]
  (freeze (let R (stream-test.reader "aaa;bb;" 1)
               First (hd (grammar.read (<s.repeat> 97) R (function stream-test.fail)))
               After (io.position R)
               Second (hd (grammar.read (<s.repeat> 98) R (function stream-test.fail)))
            [First After Second (io.position R)])))
(stream-test.check "a span owns its bytes when the reader's buffer is reused" ["abc" "xyz"]
  (freeze (let R (io.reader (stream-test.feed (buffer.from-string "<abc><xyz>") 2 [eof]) [[chunk-size 8]])
               First (hd (tl (grammar.read <s.spanned> R (function stream-test.fail))))
               Second (hd (tl (grammar.read <s.spanned> R (function stream-test.fail))))
            [(buffer.string First) (buffer.string Second)])))
(stream-test.check "a rule defined again is read as defined" [[ok one] [ok two]]
  (freeze (let Before (grammar.read <s.changing> (stream-test.reader "a" 1) (function stream-test.fail))
               _ (eval (hd (read-from-string "(defgrammar <s.changing> c#34;ac#34; := two;)")))
            [Before (grammar.read <s.changing> (stream-test.reader "a" 1) (function stream-test.fail))])))

(defgrammar <s.number> (text <s.digits>) := <s.digits>;)

(stream-test.check "lookahead errors cannot terminate a token" [error 0]
  (freeze
    (let E (stream-test.feed (buffer.from-string "12") 1
              [error (io.error read "chunks" "broken")])
         R (io.reader E [])
         Got (grammar.read <s.number> R (function stream-test.fail))
      [(hd Got) (io.position R)])))

(stream-test.check "a full window cannot terminate a token"
  [[fail 2 "input exceeds the limit"] 0]
  (freeze
    (let R (stream-test.reader "123" 1)
         Got (grammar.read-within <s.number> R 2
               (function stream-test.fail))
      [Got (io.position R)])))

(defgrammar <s.callee>
  "a" "b" "c" "d" "e" "f" "g" "h" "i" "j" "k" "l" "m" := one;)
(defgrammar <s.parent> <s.callee> := <s.callee>;)

(stream-test.check "streaming refreshes a redefined callee"
  [[ok one] [ok two] two]
  (freeze
    (let Before
           (grammar.read <s.parent>
             (stream-test.reader "abcdefghijklm" 1)
             (function stream-test.fail))
         _ (eval (hd (read-from-string
             "(defgrammar <s.callee> c#34;abcdefghijklmc#34; := two;)")))
         After
           (grammar.read <s.parent>
             (stream-test.reader "abcdefghijklm" 1)
             (function stream-test.fail))
         Plain
           (grammar.parse <s.parent>
             (buffer.from-string "abcdefghijklm")
             (function stream-test.fail))
      [Before After Plain])))

(output "~A passed, ~A failed~%" (value stream-test.passed) (value stream-test.failed))
