(set curl-test.passed 0)
(set curl-test.failed 0)

(define curl-test.check
  Name Expected F ->
    (let Actual (trap-error (thaw F) (/. X [raised (error-to-string X)]))
      (if (= Expected Actual)
          (set curl-test.passed (+ 1 (value curl-test.passed)))
          (do (set curl-test.failed (+ 1 (value curl-test.failed)))
              (output "FAIL ~A: wanted ~S, got ~S~%" Name Expected Actual)))))

(define curl-test.ok
  [ok R] -> R
  [error E] -> (error "request failed: ~A (~A)" (io.error-message E) (io.error-code E)))

(define curl-test.error
  [error E] -> E
  _ -> (error "expected a failed transfer"))

(define curl-test.url
  Path -> (cn (value curl-test.base) Path))

(define curl-test.request
  C Method Path Fields Body Options ->
    (curl.request C Method (curl-test.url Path) Fields Body (append [[proxy ""]] Options)))

(define curl-test.get
  C Path Options -> (curl-test.request C "GET" Path [] (buffer.new 0) Options))

(define curl-test.raises?
  F -> (trap-error (do (thaw F) false) (/. X true)))

(let C (curl.open)
     First (curl-test.ok (curl-test.get C "/binary" []))
     Again (curl-test.ok (curl-test.get C "/binary" []))
     _ (shen-jit.collect)
  (do (curl-test.check "status" 200 (freeze (curl.status First)))
      (curl-test.check "binary length" 1024 (freeze (buffer.length (curl.body First))))
      (curl-test.check "binary NUL" 0 (freeze (buffer.u8 (curl.body First) 0)))
      (curl-test.check "binary high byte" 255 (freeze (buffer.u8 (curl.body First) 255)))
      (curl-test.check "connection reused" (curl.header-values First "x-client-port")
        (freeze (curl.header-values Again "x-client-port")))
      (curl-test.check "response remains owned across request/GC" true
        (freeze (buffer.equal? (curl.body First) (curl.body Again))))
      (curl-test.check "repeated ordered fields" ["a=1" "b=2"]
        (freeze (curl.header-values First "SET-cookie")))
      (curl-test.check "metadata URL" (curl-test.url "/binary") (freeze (curl.url First)))
      (curl-test.check "elapsed milliseconds" true (freeze (>= (curl.elapsed First) 0)))
      (curl-test.check "no redirects" 0 (freeze (curl.redirects First)))
      (curl-test.check "explicit close" [ok] (freeze (curl.close C)))
      (curl-test.check "idempotent close" [ok] (freeze (curl.close C)))
      (curl-test.check "closed request refused" true
        (freeze (curl-test.raises? (freeze (curl-test.get C "/binary" [])))))
      (curl-test.check "owned body after close" 255 (freeze (buffer.u8 (curl.body Again) 255)))))

(let C (curl.open)
     Data (buffer.from-string "ac#0;bc#255;")
     Post (curl-test.ok (curl-test.request C "POST" "/echo" [["X-Reset" "once"] ["X-Empty" ""]] Data []))
     Get (curl-test.ok (curl-test.get C "/echo" []))
     Put (curl-test.ok (curl-test.request C "PUT" "/echo" [] Data []))
     Slice (buffer.slice (buffer.from-string "skipac#0;bc#255;end") 4 4)
     Sliced (curl-test.ok (curl-test.request C "POST" "/echo" [] Slice []))
     Empty (curl-test.ok (curl-test.request C "POST" "/echo" [] (buffer.new 0) [[body-limit 0]]))
     Head (curl-test.ok (curl-test.request C "HEAD" "/binary" [] (buffer.new 0) [[body-limit 0]]))
     _ (curl.close C)
  (do (curl-test.check "binary POST length" 4 (freeze (buffer.length (curl.body Post))))
      (curl-test.check "binary POST bytes" true (freeze (buffer.equal? Data (curl.body Post))))
      (curl-test.check "POST method" ["POST"] (freeze (curl.header-values Post "x-method")))
      (curl-test.check "default binary content type" ["application/octet-stream"]
        (freeze (curl.header-values Post "x-content-type")))
      (curl-test.check "empty header transmitted" ["empty"] (freeze (curl.header-values Post "x-empty-value")))
      (curl-test.check "GET resets method" ["GET"] (freeze (curl.header-values Get "x-method")))
      (curl-test.check "GET resets body" 0 (freeze (buffer.length (curl.body Get))))
      (curl-test.check "GET resets headers" ["missing"] (freeze (curl.header-values Get "x-reset-value")))
      (curl-test.check "custom PUT method" ["PUT"] (freeze (curl.header-values Put "x-method")))
      (curl-test.check "custom PUT bytes" true (freeze (buffer.equal? Data (curl.body Put))))
      (curl-test.check "request copies only its view" true (freeze (buffer.equal? Data (curl.body Sliced))))
      (curl-test.check "empty response with zero body budget" 0 (freeze (buffer.length (curl.body Empty))))
      (curl-test.check "HEAD has no body" 0 (freeze (buffer.length (curl.body Head))))
      (curl-test.check "HEAD preserves representation length" ["1024"]
        (freeze (curl.header-values Head "content-length")))))

(let C (curl.open)
     ErrorPage (curl-test.ok (curl-test.get C "/error" []))
     Redirect (curl-test.ok (curl-test.get C "/redirect" []))
     Final (curl-test.ok (curl-test.get C "/redirect" [[redirect-limit 2]]))
     Chunked (curl-test.ok (curl-test.get C "/chunked" []))
     Interim (curl-test.ok (curl-test.get C "/interim" []))
     HeaderBudget (- (+ (buffer.length (curl.raw-headers Redirect)) (buffer.length (curl.raw-headers Final))) 1)
     Over (curl-test.error (curl-test.get C "/redirect" [[redirect-limit 2] [header-limit HeaderBudget]]))
     _ (curl.close C)
  (do (curl-test.check "HTTP failure is a response" 404 (freeze (curl.status ErrorPage)))
      (curl-test.check "HTTP failure retains body" "missing" (freeze (buffer.string (curl.body ErrorPage))))
      (curl-test.check "redirects disabled by default" 302 (freeze (curl.status Redirect)))
      (curl-test.check "redirect location available" ["/binary"] (freeze (curl.header-values Redirect "location")))
      (curl-test.check "bounded redirect follows" 200 (freeze (curl.status Final)))
      (curl-test.check "redirect count" 1 (freeze (curl.redirects Final)))
      (curl-test.check "effective URL" (curl-test.url "/binary") (freeze (curl.url Final)))
      (curl-test.check "intermediate fields excluded" [] (freeze (curl.header-values Final "x-hop")))
      (curl-test.check "intermediate body excluded" 1024 (freeze (buffer.length (curl.body Final))))
      (curl-test.check "chunked payload decoded" "abcde" (freeze (buffer.string (curl.body Chunked))))
      (curl-test.check "trailers separate" [["x-trail" "yes"]] (freeze (curl.trailers Chunked)))
      (curl-test.check "trailer absent from ordinary fields" [] (freeze (curl.header-values Chunked "x-trail")))
      (curl-test.check "interim status excluded" ["final"] (freeze (curl.header-values Interim "x-phase")))
      (curl-test.check "headers across redirects share one budget" limit (freeze (io.error-domain Over)))))

(let C (curl.open)
  (do (map (/. Case
             (let Error (curl-test.error (curl-test.get C (hd Case) (hd (tl Case))))
               (curl-test.check "transfer error preserves native code" (hd (tl (tl Case)))
                 (freeze (io.error-code Error)))))
        [["/slow" [[timeout 50]] 28] ["/loop" [[redirect-limit 2]] 47] ["/partial" [] 18]])
      (map (/. Options
             (let Error (curl-test.error (curl-test.get C "/binary" Options))
               (curl-test.check "collection limit distinguished" limit (freeze (io.error-domain Error)))))
        [[[body-limit 16]] [[header-limit 16]]])
      (curl-test.check "timeout domain" timeout
        (freeze (io.error-domain (curl-test.error (curl-test.get C "/slow" [[timeout 50]])))))
      (curl-test.check "partial progress retained" 3
        (freeze (io.error-progress (curl-test.error (curl-test.get C "/partial" [])))))
      (curl-test.check "handle reusable after failures" 200
        (freeze (curl.status (curl-test.ok (curl-test.get C "/binary" [])))))
      (map (/. Options
             (curl-test.check "invalid option rejected" true
               (freeze (curl-test.raises? (freeze (curl-test.get C "/binary" Options))))))
        [[[timeout 0]] [[timeout -1]] [[body-limit -1]] [[body-limit 268435457]]
         [[header-limit 1048577]] [[redirect-limit 21]] [[unknown 1]]
         [[timeout 1] [timeout 2]] [[ca-file ""]]])
      (curl-test.check "request framing header rejected" true
        (freeze (curl-test.raises? (freeze (curl-test.request C "POST" "/echo"
                   [["Content-Length" "1"]] (buffer.new 0) [])))))
      (curl-test.check "header injection rejected" true
        (freeze (curl-test.raises? (freeze (curl-test.request C "GET" "/echo"
                   [["X" "badc#13;c#10;injection"]] (buffer.new 0) [])))))
      (curl-test.check "URL scheme restricted" true
        (freeze (curl-test.raises? (freeze (curl.request C "GET" "file:///not-read" [] (buffer.new 0) [])))))
      (curl-test.check "POST redirect policy explicit" true
        (freeze (curl-test.raises? (freeze (curl-test.request C "POST" "/redirect" []
                   (buffer.new 0) [[redirect-limit 1]])))))
      (curl.close C)))

(curl-test.check "one-shot convenience" 200
  (freeze (curl.status (curl-test.ok (curl.get (curl-test.url "/binary") [[proxy ""]])))))
(curl-test.check "scoped client cleans up on exception" error
  (freeze (hd (curl.with-client (/. C (error "scope failed"))))))

(curl-test.check "field parse failure preserves body progress" 3
  (freeze
    (let C (curl.open)
         E (curl-test.error (curl-test.get C "/bad-field" []))
         _ (curl.close C)
      (io.error-progress E))))

(output "~A passed, ~A failed~%" (value curl-test.passed) (value curl-test.failed))
