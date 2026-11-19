(define fixture.head (:result.ok [V]) -> V)

(load "tests/result_helpers.shen")

\\ Bounded chunked bodies, syntax, extensions, separate trailers and exact remainders.
(set chunk-test.passed 0)
(set chunk-test.failed 0)

(define chunk-test.check
  Name Expected F ->
    (let Actual (trap-error (thaw F) (/. X [raised (error-to-string X)]))
      (if (= Actual Expected)
          (set chunk-test.passed (+ 1 (value chunk-test.passed)))
          (do (set chunk-test.failed (+ 1 (value chunk-test.failed)))
              (output "FAIL ~A: wanted ~S, got ~S~%" Name Expected Actual)))))

(define chunk-test.ok
  (:result.ok Q) -> Q)

(define chunk-test.parse
  Fields Limit -> (http.parse-request
    (buffer.from-string (cn "POST / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;" (cn Fields "c#13;c#10;"))) Limit))

(define chunk-test.request
  Limit -> (chunk-test.ok (chunk-test.parse "Transfer-Encoding: chunkedc#13;c#10;" Limit)))

(define chunk-test.code
  (:result.ok _) -> 0
  (:result.err E) -> (io.error-code E))

(define chunk-test.read
  Wire Limit Options ->
    (let E (io.input-buffer (buffer.from-string Wire))
         R (io.reader E [[chunk-size 1]])
         Result (http.read-body (http.body-reader-with R (chunk-test.request Limit) Options))
         _ (io.close E)
      Result))

(map (/. Case
       (let Fields (hd Case) Code (hd (tl Case))
         (chunk-test.check Fields Code (freeze (chunk-test.code (chunk-test.parse Fields 10))))))
  [["Transfer-Encoding: ChUnKeDc#13;c#10;" 0]
   ["Transfer-Encoding: gzip, chunkedc#13;c#10;" 501]
   ["Transfer-Encoding: gzipc#13;c#10;" 400]
   ["Transfer-Encoding: chunked, gzipc#13;c#10;" 400]
   ["Transfer-Encoding: chunked, chunkedc#13;c#10;" 400]
   ["Transfer-Encoding: chunked;foo=barc#13;c#10;" 400]
   ["Transfer-Encoding:c#13;c#10;" 400]
   ["Transfer-Encoding: chunkedc#13;c#10;Transfer-Encoding: chunkedc#13;c#10;" 400]
   ["Transfer-Encoding: chunkedc#13;c#10;Content-Length: 0c#13;c#10;" 400]
   ["Transfer-Encoding: chunkedc#13;c#10;Trailer: Content-Lengthc#13;c#10;" 400]
   ["Transfer-Encoding: chunkedc#13;c#10;Trailer: X-Checksumc#13;c#10;" 0]])

(let Q (chunk-test.request 10)
     E (io.input-buffer (buffer.from-string "3;foo=barc#13;c#10;abcc#13;c#10;2;quoted=c#34;a;c#92;c#34;bc#34;c#13;c#10;dec#13;c#10;00;lastc#13;c#10;X-Ok: yes c#13;c#10;X-Ok: againc#13;c#10;c#13;c#10;NEXT"))
     R (io.reader E [[chunk-size 1]])
     B (http.body-reader R Q)
     Result (http.read-body B)
     Full (chunk-test.ok Result)
     Tail (chunk-test.ok (io.read-all R 4))
     Again (http.read-body B)
  (do (chunk-test.check "unknown extensions ignored and payload decoded" "abcde"
        (freeze (buffer.string (http.body Full))))
      (chunk-test.check "separate ordered trailers" [["x-ok" "yes"] ["x-ok" "again"]]
        (freeze (http.trailers Full)))
      (chunk-test.check "trailer fields do not become headers" [] (freeze (http.header-values Full "x-ok")))
      (chunk-test.check "decoded content length becomes known" 5 (freeze (http.content-length Full)))
      (chunk-test.check "framing metadata remains chunked" true (freeze (http.chunked? Full)))
      (chunk-test.check "next request bytes remain unread" "NEXT" (freeze (buffer.string Tail)))
      (chunk-test.check "body read result is cached" true (freeze (shen-jit.same? Again Result)))
      (chunk-test.check "original length remains unknown" true
        (freeze (trap-error (do (http.content-length Q) false) (/. X true))))
      (io.close E)))

(map (/. Case
       (let Wire (hd Case) Code (hd (tl Case))
         (chunk-test.check Wire Code (freeze (chunk-test.code (chunk-test.read Wire 8 []))))))
  [["0c#13;c#10;c#13;c#10;" 0]
   ["1 ; foo = barc#13;c#10;ac#13;c#10;0c#13;c#10;c#13;c#10;" 0]
   ["1;x=c#34;c#34;c#13;c#10;ac#13;c#10;0c#13;c#10;c#13;c#10;" 0]
   ["" 400] ["0c#13;" 400] ["0c#13;c#10;" 400]
   ["1c#10;a" 400] ["1c#13;xa" 400] ["+1c#13;c#10;a" 400] ["0x1c#13;c#10;a" 400]
   ["1 c#13;c#10;a" 400] ["1;c#13;c#10;a" 400] ["1;x=c#13;c#10;a" 400]
   ["1;x=c#34;unterminatedc#13;c#10;a" 400] ["1;x=c#0;c#13;c#10;a" 400]
   ["1c#13;c#10;aXX" 400] ["3c#13;c#10;ab" 400]
   ["ffffffffffffffffffffffffc#13;c#10;" 413]
   ["5c#13;c#10;abcdec#13;c#10;4c#13;c#10;" 413]
   ["0c#13;c#10;Content-Length: 1c#13;c#10;c#13;c#10;" 400]
   ["0c#13;c#10;Authorization: secretc#13;c#10;c#13;c#10;" 400]
   ["0c#13;c#10; X: foldedc#13;c#10;c#13;c#10;" 400]])

(map (/. Case
       (let Options (hd Case) Code (hd (tl Case))
         (chunk-test.check "chunk bounds" Code
           (freeze (chunk-test.code (chunk-test.read "1c#13;c#10;ac#13;c#10;0c#13;c#10;c#13;c#10;" 1 Options))))))
  [[[[chunk-line-limit 1]] 0] [[[chunk-metadata-limit 10]] 0] [[[chunk-metadata-limit 9]] 413]
   [[[chunk-count-limit 1]] 413] [[[chunk-count-limit 2]] 0] [[[trailer-limit 1]] 413]
   [[[trailer-limit 2]] 0] [[[trailer-fields-limit 0]] 0]])
(chunk-test.check "trailer field bound" 413
  (freeze (chunk-test.code (chunk-test.read "0c#13;c#10;X: yc#13;c#10;c#13;c#10;" 0 [[trailer-fields-limit 0]]))))
(chunk-test.check "trailer aggregate byte bound" 413
  (freeze (chunk-test.code (chunk-test.read "0c#13;c#10;X: yc#13;c#10;c#13;c#10;" 0 [[trailer-limit 7]]))))
(chunk-test.check "empty decoded body within zero body limit" 0
  (freeze (http.content-length (chunk-test.ok (chunk-test.read "0c#13;c#10;c#13;c#10;" 0 [])))))
(chunk-test.check "positive decoded body exceeds zero body limit" 413
  (freeze (chunk-test.code (chunk-test.read "1c#13;c#10;a" 0 []))))
(chunk-test.check "largest exact hex size" 2305843009213693951
  (freeze (http.chunk-size (buffer.from-string "1fffffffffffffff") 2305843009213693951)))
(chunk-test.check "hex overflow is bounded before multiplication" too-large
  (freeze (http.chunk-size (buffer.from-string "2000000000000000") 2305843009213693951)))

(let E (io.input-buffer (buffer.from-string "2c#13;c#10;abc#13;c#10;2c#13;c#10;cd"))
     R (io.reader E [])
     B (http.body-reader R (chunk-test.request 3))
     Result (http.read-body B)
     Error (fixture.failure Result)
  (do (chunk-test.check "cumulative limit progress" [413 2]
        (freeze [(io.error-code Error) (io.error-progress Error)]))
      (chunk-test.check "failure is cached" Result (freeze (http.read-body B)))
      (io.close E)))
(let E (io.input-buffer (buffer.from-string "3c#13;c#10;ab"))
     R (io.reader E [])
     Error (fixture.failure (http.read-body (http.body-reader R (chunk-test.request 3))))
  (do (chunk-test.check "truncated data progress excludes framing" 2 (freeze (io.error-progress Error)))
      (io.close E)))

\\ Complete head/body wire under every first transport split, not only aligned chunk reads.
(define chunk-test.feed
  Wire State ->
    (io.endpoint "chunk fixture" read 256
      (/. Out (let At (<-address State 0)
                   Step (if (= At 0) (<-address State 1) 256)
                   N (io.min Step (io.min (shen-jit.bytes-length Out) (- (buffer.length Wire) At)))
                (if (= N 0) (:result.ok [])
                    (do (shen-jit.copy-bytes Out 0 (buffer.owner Wire) At N)
                        (address-> State 0 (+ At N)) (:result.ok [N])))))
      (function io.no-write) (freeze (:result.ok []))))
(set chunk-test.wire (buffer.from-string
  "POST / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;Transfer-Encoding: chunkedc#13;c#10;c#13;c#10;3;x=yc#13;c#10;abcc#13;c#10;0c#13;c#10;X-End: yes c#13;c#10;c#13;c#10;NEXT"))
(define chunk-test.splits
  0 -> true
  N ->
    (let E (chunk-test.feed (value chunk-test.wire) (io.record [0 N]))
         R (io.reader E [])
         Head (fixture.head (http.read-head (http.head-reader R 256)))
         Q (chunk-test.ok (http.parse-request Head 3))
         Full (chunk-test.ok (http.read-body (http.body-reader R Q)))
         Tail (chunk-test.ok (io.read-all R 4))
         _ (chunk-test.check "every chunked transport split" ["abc" [["x-end" "yes"]] "NEXT"]
             (freeze [(buffer.string (http.body Full)) (http.trailers Full) (buffer.string Tail)]))
         _ (io.close E)
      (chunk-test.splits (- N 1))))
(chunk-test.splits (buffer.length (value chunk-test.wire)))

(let E (io.input-buffer (buffer.from-string "1c#13;c#10;ac#13;c#10;0c#13;c#10;c#13;c#10;"))
     R (io.reader E [])
     Time (io.record [0])
     D (deadline.after (freeze (let N (+ 1 (<-address Time 0)) _ (address-> Time 0 N) N)) 5)
     Error (fixture.failure (http.read-body-until (http.body-reader R (chunk-test.request 1)) D))
  (do (chunk-test.check "one total budget across chunk metadata and data" timeout
        (freeze (io.error-domain Error)))
      (io.close E)))
(let Calls (io.record [0])
     E (io.endpoint "one-byte fixture" read 64
         (/. Out (if (= (<-address Calls 0) 0)
                     (do (address-> Calls 0 1) (shen-jit.u8! Out 0 120) (:result.ok [1]))
                     (error "peek tried to fill the maximum")))
         (function io.no-write) (freeze (:result.ok [])))
     R (io.reader E [])
     V (hd (chunk-test.ok (io.peek-up-to R 64)))
  (do (chunk-test.check "bounded peek waits for availability, not a full span" "x" (freeze (buffer.string V)))
      (chunk-test.check "bounded peek leaves bytes queued" 0 (freeze (io.position R)))
      (buffer.u8-> V 0 88)
      (chunk-test.check "bounded peek returns owned bytes" "x"
        (freeze (buffer.string (hd (chunk-test.ok (io.peek-up-to R 1))))))
      (chunk-test.check "zero bounded peek does not probe transport" 0
        (freeze (buffer.length (hd (chunk-test.ok (io.peek-up-to R 0))))))
      (io.close E)))

(let Q (chunk-test.ok (http.parse-request
                (buffer.from-string "TRACE / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;Transfer-Encoding: chunkedc#13;c#10;c#13;c#10;") 8))
     E (io.input-buffer (buffer.from-string "1c#13;c#10;a"))
     Result (http.read-body (http.body-reader (io.reader E []) Q))
     _ (io.close E)
  (chunk-test.check "nonempty chunked TRACE rejected" 400 (freeze (chunk-test.code Result))))
(let Q (chunk-test.ok (chunk-test.parse
                "Transfer-Encoding: chunkedc#13;c#10;Connection: X-Hop c#13;c#10;" 0))
     E (io.input-buffer (buffer.from-string "0c#13;c#10;X-Hop: vc#13;c#10;c#13;c#10;"))
     Result (http.read-body (http.body-reader (io.reader E []) Q))
     _ (io.close E)
  (chunk-test.check "hop-by-hop nominated trailer rejected" 400 (freeze (chunk-test.code Result))))
(let Prefix (buffer.from-string "1c#13;c#10;xc#13;c#10;2c#13;c#10;a")
     State (io.record [false])
     E (io.endpoint "native failure fixture" read 64
         (/. Out (if (<-address State 0)
                     (:result.err (io.native-error read posix 54 "fixture" "forced reset"))
                     (do (shen-jit.copy-bytes Out 0 (buffer.owner Prefix) 0 (buffer.length Prefix))
                         (address-> State 0 true) (:result.ok [(buffer.length Prefix)]))))
         (function io.no-write) (freeze (:result.ok [])))
     Error (fixture.failure (http.read-body (http.body-reader (io.reader E []) (chunk-test.request 8))))
     _ (io.close E)
  (chunk-test.check "native error keeps code and cumulative decoded progress" [posix 54 2]
    (freeze [(io.error-domain Error) (io.error-code Error) (io.error-progress Error)])))
(output "~A passed, ~A failed~%" (value chunk-test.passed) (value chunk-test.failed))
