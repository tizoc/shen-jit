\\ Complete request syntax, framing decisions, owned bounded bodies and response bytes.
(set request-test.passed 0)
(set request-test.failed 0)

(define request-test.check
  Name Expected F ->
    (let Got (trap-error (thaw F) (/. X [raised (error-to-string X)]))
      (if (= Expected Got)
          (set request-test.passed (+ 1 (value request-test.passed)))
          (do (output "FAIL ~A: expected ~S, got ~S~%" Name Expected Got)
              (set request-test.failed (+ 1 (value request-test.failed)))))))

(define request-test.raises
  Name F -> (request-test.check Name true (freeze (trap-error (do (thaw F) false) (/. X true)))))

(define request-test.code
  [ok _] -> 0
  [error E] -> (io.error-code E))

(define request-test.ok
  [ok Value] -> Value)

(define request-test.head
  Extra -> (cn "GET / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;" (cn Extra "c#13;c#10;")))

(define request-test.parse
  Text Limit -> (http.parse-request (buffer.from-string Text) Limit))

(define request-test.fields
  [] -> true
  [[Extra Expected] | Rest] ->
    (do (request-test.check Extra Expected
          (freeze (request-test.code (request-test.parse (request-test.head Extra) 1024))))
        (request-test.fields Rest)))

(request-test.fields
  [["" 0]
   ["Content-Length: 0c#13;c#10;" 0]
   ["Content-Length: 0003c#13;c#10;" 0]
   ["Content-Length:c#9; 3 c#9;c#13;c#10;" 0]
   ["Content-Length: 3c#13;c#10;content-length: 3c#13;c#10;" 400]
   ["Content-Length: 3c#13;c#10;Content-Length: 4c#13;c#10;" 400]
   ["Content-Length: 3,3c#13;c#10;" 400]
   ["Content-Length: +3c#13;c#10;" 400]
   ["Content-Length: -1c#13;c#10;" 400]
   ["Content-Length: 3e0c#13;c#10;" 400]
   ["Content-Length: 0x10c#13;c#10;" 400]
   ["Content-Length: 3 0c#13;c#10;" 400]
   ["Content-Length:c#13;c#10;" 400]
   ["Content-Length: 1025c#13;c#10;" 413]
   ["Content-Length: 999999999999999999999999999999999c#13;c#10;" 413]
   ["Transfer-Encoding: chunkedc#13;c#10;" 0]
   ["Transfer-Encoding: identityc#13;c#10;Content-Length: 0c#13;c#10;" 400]
   ["Content-Length: 0c#13;c#10;Transfer-Encoding: chunkedc#13;c#10;" 400]
   ["Expect: 100-continuec#13;c#10;" 417]
   ["Upgrade: websocketc#13;c#10;" 501]
   ["Connection: upgradec#13;c#10;" 501]
   ["Connection: Hostc#13;c#10;" 400]
   ["Connection: content-lengthc#13;c#10;" 400]
   ["Connection: transfer-encodingc#13;c#10;" 400]
   ["Connection: expectc#13;c#10;" 400]
   ["Connection: close, keep-alivec#13;c#10;" 0]
   ["Connection: close,c#13;c#10;" 400]
   ["Connection: ,closec#13;c#10;" 400]
   ["Connection: close,,fooc#13;c#10;" 400]
   ["Trailer: xc#13;c#10;" 400]
   ["Host: otherc#13;c#10;" 400]
   ["X : valuec#13;c#10;" 400]
   [" X: foldedc#13;c#10;" 400]
   ["c#9;foldedc#13;c#10;" 400]
   [": emptyc#13;c#10;" 400]
   ["X@Y: badc#13;c#10;" 400]
   ["X: ac#0;bc#13;c#10;" 400]
   ["X: ac#127;bc#13;c#10;" 400]
   ["X: firstc#13;c#10;X: secondc#13;c#10;" 0]])

(define request-test.hosts
  [] _ -> true
  [Host | Rest] Expected ->
    (do (request-test.check Host Expected
          (freeze (request-test.code
                    (request-test.parse (cn "GET / HTTP/1.1c#13;c#10;Host: "
                                            (cn Host "c#13;c#10;c#13;c#10;")) 0))))
        (request-test.hosts Rest Expected)))

(request-test.hosts ["localhost" "EXAMPLE.com:80" "example.com." "127.0.0.1:0"
                    "[::1]" "[::]:443" "[1:2:3:4:5:6:7:8]" "[1:2:3:4:5:6:7::]"] 0)
(request-test.hosts ["" "a..b" "-bad" "bad-" "a b" "a,b" "user@host" "host/path"
                    "host:" "host:65536" "host:+80" "::1" "[]" "[:::]" "[1::2::3]"
                    "[1:2:3:4:5:6:7:8::]" "[1:2]" "[::1]:" "[::1]x" "[::gg]"
                    "[::ffff:192.0.2.1]" "[v1.x]" "[fe80::1%en0]"] 400)

(define request-test.lines
  [] -> true
  [[Line Expected] | Rest] ->
    (do (request-test.check Line Expected
          (freeze (request-test.code (request-test.parse (cn Line "c#13;c#10;Host: localhostc#13;c#10;c#13;c#10;") 0))))
        (request-test.lines Rest)))

(request-test.lines [["GET / HTTP/1.1" 0] ["OPTIONS * HTTP/1.1" 0]
                    ["GET * HTTP/1.1" 400] ["GET http://localhost/ HTTP/1.1" 400]
                    ["GET /#fragment HTTP/1.1" 400] ["GET /%xx HTTP/1.1" 400]
                    ["GET /%0 HTTP/1.1" 400] ["GET /a?b=%20 HTTP/1.1" 0]
                    ["GET /a c HTTP/1.1" 400] ["GET  / HTTP/1.1" 400]
                    ["GETc#9;/ HTTP/1.1" 400] [" GET / HTTP/1.1" 400]
                    ["GET / HTTP/1.1 " 400] ["GET / HTTP/1.0" 505]
                    ["GET / HTTP/2.0" 505] ["GET / http/1.1" 400]
                    ["CONNECT localhost:443 HTTP/1.1" 501] ["GET" 400]])

(request-test.check "missing Host" 400
  (freeze (request-test.code (request-test.parse "GET / HTTP/1.1c#13;c#10;c#13;c#10;" 0))))
(request-test.check "bare LF" 400
  (freeze (request-test.code (request-test.parse "GET / HTTP/1.1c#10;Host: localhostc#10;c#10;" 0))))
(request-test.check "trailing body passed to head parser" 400
  (freeze (request-test.code (request-test.parse (cn (request-test.head "") "body") 0))))
(request-test.check "empty framed block is not a request" 400
  (freeze (request-test.code (request-test.parse "c#13;c#10;c#13;c#10;" 0))))
(request-test.check "TRACE cannot have content" 400
  (freeze (request-test.code (request-test.parse
    "TRACE / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;Content-Length: 1c#13;c#10;c#13;c#10;" 10))))
(request-test.check "largest exact Content-Length is compared without overflow" 2305843009213693951
  (freeze (http.content-length (request-test.ok (request-test.parse
    (request-test.head "Content-Length: 2305843009213693951c#13;c#10;") 2305843009213693951)))))
(request-test.check "Content-Length above fixnum range is safely rejected" 413
  (freeze (request-test.code (request-test.parse
    (request-test.head "Content-Length: 2305843009213693952c#13;c#10;") 2305843009213693951))))
(request-test.raises "negative body limit" (freeze (request-test.parse (request-test.head "") -1)))
(request-test.raises "invalid view is a programming error" (freeze (http.parse-request [] 0)))

(let Source (buffer.from-string (request-test.head "X-Foo: firstc#13;c#10;x-foo: secondc#13;c#10;"))
     Q (request-test.ok (http.parse-request Source 0))
     _ (buffer.u8! Source 0 88)
  (do (request-test.check "metadata owns strings after input mutation" ["GET" "/" "HTTP/1.1"]
        (freeze [(http.method Q) (http.target Q) (http.version Q)]))
      (request-test.check "ordered repeated field values" ["first" "second"]
        (freeze (http.header-values Q "X-FOO")))
      (request-test.raises "body is not available before reading" (freeze (http.body Q)))))

(let Q (request-test.ok (request-test.parse (request-test.head "Content-Length: 3c#13;c#10;") 3))
     Wire (buffer.from-string "ac#0;zNEXT")
     _ (buffer.u8! Wire 2 255)
     E (io.input-buffer Wire)
     R (io.reader E [[chunk-size 1]])
     B (http.body-reader R Q)
     Result (http.read-body B)
     Full (request-test.ok Result)
     Again (http.read-body B)
     Tail (io.read-all R 4)
     _ (io.close E)
  (do (request-test.check "body reader result is one shot" true (freeze (shen-jit.same? Result Again)))
      (request-test.check "body length is exact" 3 (freeze (buffer.length (http.body Full))))
      (request-test.check "body preserves NUL" 0 (freeze (buffer.u8 (http.body Full) 1)))
      (request-test.check "body preserves raw byte 255" 255 (freeze (buffer.u8 (http.body Full) 2)))
      (request-test.check "body leaves following bytes unread" "NEXT"
        (freeze (buffer.string (request-test.ok Tail))))
      (request-test.raises "parsed metadata was not mutated" (freeze (http.body Q)))))

(let Q (request-test.ok (request-test.parse (request-test.head "Content-Length: 5c#13;c#10;") 5))
     E (io.input-buffer (buffer.from-string "abc"))
     R (io.reader E [])
     B (http.body-reader R Q)
     Result (http.read-body B)
     Error (hd (tl Result))
  (do (request-test.check "truncated body" [400 3]
        (freeze [(io.error-code Error) (io.error-progress Error)]))
      (request-test.check "truncated body failure is terminal" Result (freeze (http.read-body B)))
      (io.close E)))

(let Q (request-test.ok (request-test.parse (request-test.head "") 0))
     E (io.input-buffer (buffer.from-string "NEXT"))
     R (io.reader E [])
     Full (request-test.ok (http.read-body (http.body-reader R Q)))
  (do (request-test.check "absent Content-Length means empty body" 0 (freeze (buffer.length (http.body Full))))
      (request-test.check "zero body does not read next request" 0 (freeze (io.position R)))
      (io.close E)))

(set request-test.get (request-test.ok (request-test.parse (request-test.head "") 0)))
(set request-test.head-request (request-test.ok (request-test.parse
  "HEAD / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;c#13;c#10;" 0)))

(request-test.check "exact response bytes"
  "HTTP/1.1 200 OKc#13;c#10;X: ac#13;c#10;Content-Length: 5c#13;c#10;Connection: closec#13;c#10;c#13;c#10;hello"
  (freeze (buffer.string (http.encode-response (value request-test.get)
            (http.response 200 [["X" "a"]] (buffer.from-string "hello")) 1024 5))))
(request-test.check "HEAD advertises representation length without bytes"
  "HTTP/1.1 200 OKc#13;c#10;Content-Length: 5c#13;c#10;Connection: closec#13;c#10;c#13;c#10;"
  (freeze (buffer.string (http.encode-response (value request-test.head-request)
            (http.response 200 [] (buffer.from-string "hello")) 1024 5))))
(request-test.check "204 omits Content-Length"
  "HTTP/1.1 204 No Contentc#13;c#10;Connection: closec#13;c#10;c#13;c#10;"
  (freeze (buffer.string (http.encode-response (value request-test.get)
            (http.response 204 [] (buffer.new 0)) 1024 0))))
(request-test.check "205 explicitly frames zero bytes"
  "HTTP/1.1 205 Reset Contentc#13;c#10;Content-Length: 0c#13;c#10;Connection: closec#13;c#10;c#13;c#10;"
  (freeze (buffer.string (http.encode-response (value request-test.get)
            (http.response 205 [] (buffer.new 0)) 1024 0))))
(request-test.check "304 omits Content-Length"
  "HTTP/1.1 304 Not Modifiedc#13;c#10;Connection: closec#13;c#10;c#13;c#10;"
  (freeze (buffer.string (http.encode-response (value request-test.get)
            (http.response 304 [] (buffer.new 0)) 1024 0))))

(define request-test.response-field-errors
  [] -> true
  [[Name Value] | Rest] ->
    (do (request-test.raises Name
          (freeze (http.encode-response (value request-test.get)
                    (http.response 200 [[Name Value]] (buffer.new 0)) 1024 0)))
        (request-test.response-field-errors Rest)))

(request-test.response-field-errors [["Content-Length" "0"] ["cOnNeCtIoN" "keep-alive"]
  ["Transfer-Encoding" "chunked"] ["Trailer" "x"] ["Upgrade" "websocket"]
  ["Xc#13;c#10;Bad" "a"] ["X" "ac#13;c#10;Content-Length: 9"] ["X" "ac#0;"]
  ["X" "ac#127;"] ["X Y" "a"]])
(request-test.raises "nonempty bodyless response"
  (freeze (http.encode-response (value request-test.get) (http.response 204 [] (buffer.new 1)) 1024 1)))
(request-test.raises "response body limit"
  (freeze (http.encode-response (value request-test.get) (http.response 200 [] (buffer.new 3)) 1024 2)))
(request-test.raises "response head limit"
  (freeze (http.encode-response (value request-test.get) (http.response 200 [] (buffer.new 0)) 4 0)))
(request-test.raises "informational response is not a final response" (freeze (http.response 100 [] (buffer.new 0))))
(request-test.raises "invalid status" (freeze (http.response 600 [] (buffer.new 0))))
(request-test.raises "real status" (freeze (http.response (+ 199.5 0.5) [] (buffer.new 0))))

(define request-test.feed
  Wire State ->
    (io.endpoint "request fixture" read 128
      (/. Out (let At (<-address State 0)
                   Step (if (= At 0) (<-address State 1) 128)
                   N (io.min Step (io.min (shen-jit.bytes-length Out) (- (buffer.length Wire) At)))
                (if (= N 0)
                    [eof]
                    (do (shen-jit.copy-bytes Out 0 (buffer.owner Wire) At N)
                        (address-> State 0 (+ At N))
                        [read N]))))
      (function io.no-write) (freeze [ok])))

(set request-test.wire (buffer.from-string
  "POST /echo HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;Content-Length: 3c#13;c#10;c#13;c#10;abcNEXT"))

(define request-test.splits
  0 -> true
  N ->
    (let State (io.record [0 N])
         E (request-test.feed (value request-test.wire) State)
         R (io.reader E [])
         F (http.head-reader R 128)
         Head (hd (tl (http.read-head F)))
         Parsed (request-test.ok (http.parse-request Head 3))
         Full (request-test.ok (http.read-body (http.body-reader R Parsed)))
         Tail (request-test.ok (io.read-all R 4))
         _ (io.close E)
         _ (request-test.check "every head/body transport split" ["POST" "abc" "NEXT"]
             (freeze [(http.method Full) (buffer.string (http.body Full)) (buffer.string Tail)]))
      (request-test.splits (- N 1))))

(request-test.splits (buffer.length (value request-test.wire)))

(request-test.check "aborted body retains consumed progress" [true 1 1]
  (freeze
    (let Q (request-test.ok (request-test.parse "POST / HTTP/1.1c#13;c#10;Host: xc#13;c#10;Content-Length: 2c#13;c#10;c#13;c#10;" 2))
         Sent (io.record [false])
         E (io.endpoint "interrupted body" read 1
             (/. Out (if (<-address Sent 0) (error "read interrupted")
                         (do (address-> Sent 0 true) (shen-jit.u8! Out 0 97) [read 1])))
             (function io.no-write) (freeze [ok]))
         R (io.reader E [])
         B (http.body-reader R Q)
         Raised (trap-error (do (http.read-body B) false) (/. X true))
         Again (http.read-body B)
         Got [Raised (io.error-progress (hd (tl Again))) (io.position R)]
         _ (io.close E)
      Got)))

(output "~A passed, ~A failed~%" (value request-test.passed) (value request-test.failed))
