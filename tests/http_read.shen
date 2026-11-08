\\ Heads read in place as they arrive, against http.parse-request of the same head framed.
\\ Load buffer.shen, io.shen, deadline.shen, grammar.shen, http-head.shen and http-request.shen.
(set read-test.passed 0)
(set read-test.failed 0)

(define read-test.check
  Name Expected F ->
    (let Actual (trap-error (thaw F) (/. X [raised (error-to-string X)]))
      (if (= Actual Expected)
          (set read-test.passed (+ 1 (value read-test.passed)))
          (do (set read-test.failed (+ 1 (value read-test.failed)))
              (output "FAIL ~A: wanted ~S, got ~S~%" Name Expected Actual)))))

(define read-test.feed
  Wire Step -> (let State (io.record [0])
                 (io.endpoint "chunks" read 65536
                   (/. Out (let At (<-address State 0)
                                N (io.min Step (io.min (shen-jit.bytes-length Out) (- (buffer.length Wire) At)))
                             (if (= N 0) [eof]
                                 (do (shen-jit.copy-bytes Out 0 (buffer.owner Wire) (+ (buffer.offset Wire) At) N)
                                     (address-> State 0 (+ At N)) [read N]))))
                   (function io.no-write) (freeze [ok]))))
(define read-test.summary
  [ok Q] -> [0 (http.method Q) (http.target Q) (http.headers Q)]
  [error E] -> [(io.error-code E)]
  [eof] -> [eof])
(define read-test.old Text -> (read-test.summary (http.parse-request (buffer.from-string Text) 1024)))
(define read-test.new Text Step ->
  (let R (io.reader (read-test.feed (buffer.from-string (cn Text "NEXT")) Step) [])
       S (read-test.summary (http.read-request R 16384 1024))
       Rest (io.read-all R 100)
    (if (= (hd S) 0) [S (buffer.string (hd (tl Rest)))] [S])))
(define read-test.letters
  N -> (let B (shen-jit.bytes N) _ (read-test.fill B 0 N) (shen-jit.bytes->string B 0 N)))

(define read-test.fill
  _ I I -> true
  B I N -> (do (shen-jit.u8! B I 97) (read-test.fill B (+ I 1) N)))

(define read-test.fields
  0 Acc -> Acc
  N Acc -> (read-test.fields (- N 1) (cn (make-string "X-~A: vc#13;c#10;" N) Acc)))

(define read-test.head Extra -> (cn "GET / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;" (cn Extra "c#13;c#10;")))
(set read-test.cases
  (append
   (map (function read-test.head)
     ["" "Content-Length: 0c#13;c#10;" "Content-Length:c#9; 3 c#9;c#13;c#10;" "Content-Length: 3c#13;c#10;content-length: 3c#13;c#10;"
      "Content-Length: +3c#13;c#10;" "Content-Length: 1025c#13;c#10;" "Transfer-Encoding: chunkedc#13;c#10;"
      "Expect: 100-continuec#13;c#10;" "Upgrade: websocketc#13;c#10;" "Connection: close, keep-alivec#13;c#10;"
      "Connection: close,c#13;c#10;" "X : valuec#13;c#10;" " X: foldedc#13;c#10;" "c#9;foldedc#13;c#10;" ": emptyc#13;c#10;"
      "X@Y: badc#13;c#10;" "X: ac#0;bc#13;c#10;" "X: ac#127;bc#13;c#10;" "X: firstc#13;c#10;X: secondc#13;c#10;"
      "X: a  b c#9; c c#13;c#10;" "X:c#13;c#10;" "X: résumé c#13;c#10;" "X: ac#13;bc#13;c#10;" "X: ac#10;c#13;c#10;"])
   (map (/. L (cn L "c#13;c#10;Host: localhostc#13;c#10;c#13;c#10;"))
     ["GET / HTTP/1.1" "OPTIONS * HTTP/1.1" "GET * HTTP/1.1" "GET http://localhost/ HTTP/1.1" "GET /#fragment HTTP/1.1"
      "GET /%xx HTTP/1.1" "GET /a?b=%20 HTTP/1.1" "GET /a c HTTP/1.1" "GET  / HTTP/1.1" "GETc#9;/ HTTP/1.1"
      " GET / HTTP/1.1" "GET / HTTP/1.1 " "GET / HTTP/1.0" "GET / http/1.1" "CONNECT localhost:443 HTTP/1.1" "GET"])
   ["GET / HTTP/1.1c#13;c#10;c#13;c#10;" "GET / HTTP/1.1c#10;Host: localhostc#10;c#10;" "c#13;c#10;c#13;c#10;"
    "TRACE / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;Content-Length: 1c#13;c#10;c#13;c#10;"]))
\\ The same status, the same request and the same bytes left unread, at each chunk size.
(map (/. Text (map (/. Step (let Old (read-test.old Text)
                              (read-test.check (make-string "~S in chunks of ~A" Text Step)
                                (if (= (hd Old) 0) [Old "NEXT"] [Old])
                                (freeze (read-test.new Text Step)))))
                   [1 3 1000]))
     (value read-test.cases))

(read-test.check "nothing at all is eof" [eof]
  (freeze (read-test.summary (http.read-request (io.reader (read-test.feed (buffer.from-string "") 1) []) 16384 0))))
(read-test.check "a head the input cut is incomplete" [400 "incomplete head"]
  (freeze (let Got (http.read-request (io.reader (read-test.feed (buffer.from-string "GET / HTTP/1.1c#13;c#10;Host: x") 2) []) 16384 0)
            [(io.error-code (hd (tl Got))) (io.error-message (hd (tl Got)))])))
(read-test.check "a head past its limit" [431 "head exceeds byte limit"]
  (freeze (let Got (http.read-request (io.reader (read-test.feed (buffer.from-string (read-test.head "X-Long: 0123456789012345678901234567890123456789c#13;c#10;")) 7) []) 64 0)
            [(io.error-code (hd (tl Got))) (io.error-message (hd (tl Got)))])))
(read-test.check "a request line past 8192 bytes" [414]
  (freeze (read-test.summary (http.read-request (io.reader (read-test.feed (buffer.from-string
            (cn "GET /" (cn (read-test.letters 8200) " HTTP/1.1c#13;c#10;Host: xc#13;c#10;c#13;c#10;"))) 4096) []) 16384 0))))
(read-test.check "a hundred and one fields" [431]
  (freeze (read-test.summary (http.read-request (io.reader (read-test.feed (buffer.from-string
            (read-test.head (read-test.fields 101 ""))) 4096) []) 16384 0))))

(output "~A passed, ~A failed~%" (value read-test.passed) (value read-test.failed))
