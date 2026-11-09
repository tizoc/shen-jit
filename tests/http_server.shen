\\ One-request connection behavior over loopback, including failure before and after output.
(set server-test.passed 0)
(set server-test.failed 0)
(set server-test.calls 0)

(define server-test.check
  Name Expected F ->
    (let Got (trap-error (thaw F) (/. X [raised (error-to-string X)]))
      (if (= Expected Got)
          (set server-test.passed (+ 1 (value server-test.passed)))
          (do (output "FAIL ~A: expected ~S, got ~S~%" Name Expected Got)
              (set server-test.failed (+ 1 (value server-test.failed)))))))

(define server-test.pair
  ->
    (let L (socket.listen "127.0.0.1" 0)
         C (socket.connect "127.0.0.1" (socket.port L))
         S (socket.accept L)
         _ (socket.close L)
      [(io.socket C "HTTP client") (io.socket S "HTTP server")]))

(define server-test.handler
  Request ->
    (do (set server-test.calls (+ 1 (value server-test.calls)))
        (http.response 200 [["Set-Cookie" "a=1"] ["Set-Cookie" "b=2"]
                            ["Date" "Sun, 06 Nov 1994 08:49:37 GMT"]] (http.body Request))))

(define server-test.collect
  R Total Chunks -> (server-test.chunk R Total Chunks (io.read-chunk R)))

(define server-test.chunk
  R Total Chunks [chunk V] -> (server-test.collect R (+ Total (buffer.length V)) [V | Chunks])
  _ Total Chunks _ -> (io.join Total (reverse Chunks)))

(define server-test.exchange
  Wire Options Handler Finish ->
    (let Pair (server-test.pair)
         C (hd Pair)
         S (hd (tl Pair))
         _ (set server-test.calls 0)
         _ (io.write-all C (buffer.from-string Wire) [])
         _ (if Finish (io.shutdown-write C) true)
         Result (http.serve-one S Handler Options)
         Reply (server-test.collect (io.reader C []) 0 [])
         _ (io.close C)
      [Result Reply (value server-test.calls)]))

(define server-test.status
  Exchange ->
    (let V (hd (tl Exchange))
      (if (< (buffer.length V) 12) 0
          (http.decimal (buffer.owner V) 9 12 999))))

(define server-test.rejected
  [] -> true
  [[Wire Options Status] | Rest] ->
    (let Exchange (server-test.exchange Wire Options (function server-test.handler) false)
         Result (hd Exchange)
      (do (server-test.check "rejection status" Status (freeze (server-test.status Exchange)))
          (server-test.check "rejected request never reaches handler" 0 (freeze (hd (tl (tl Exchange)))))
          (server-test.check "rejection remains a failure result" error (freeze (hd Result)))
          (server-test.rejected Rest))))

(if (trap-error (do (socket.close (socket.listen "127.0.0.1" 0)) false)
                (/. X (= (error-to-string X) "foreign: this static build cannot load libraries")))
    (do (output "1 passed, 0 failed (a static build)~%") (shen-jit.exit 0))
    skip)

(let Wire "POST / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;Content-Length: 3c#13;c#10;c#13;c#10;abc"
     Exchange (server-test.exchange Wire [] (function server-test.handler) false)
     Result (hd Exchange)
     Reply (hd (tl Exchange))
  (do (server-test.check "valid request completes before client EOF" 200 (freeze (server-test.status Exchange)))
      (server-test.check "handler runs once" 1 (freeze (hd (tl (tl Exchange)))))
      (server-test.check "wire count" [ok (buffer.length Reply)] (freeze Result))
      (server-test.check "body and repeated response fields"
        "HTTP/1.1 200 OKc#13;c#10;Set-Cookie: a=1c#13;c#10;Set-Cookie: b=2c#13;c#10;Date: Sun, 06 Nov 1994 08:49:37 GMTc#13;c#10;Content-Length: 3c#13;c#10;Connection: closec#13;c#10;c#13;c#10;abc"
        (freeze (buffer.string Reply)))))

(let Seen (io.record [[]])
     Exchange (server-test.exchange
                "POST / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;Transfer-Encoding: chunkedc#13;c#10;c#13;c#10;3;x=yc#13;c#10;abcc#13;c#10;0c#13;c#10;X-End: yesc#13;c#10;c#13;c#10;"
                [] (/. Q (do (address-> Seen 0 [(http.content-length Q) (http.trailers Q)])
                             (server-test.handler Q))) false)
     Reply (hd (tl Exchange))
  (do (server-test.check "chunked request completes before client EOF" 200
        (freeze (server-test.status Exchange)))
      (server-test.check "native handler receives decoded length and separate trailers" [3 [["x-end" "yes"]]]
        (freeze (<-address Seen 0)))
      (server-test.check "native chunked echo body" "abc"
        (freeze (buffer.string (buffer.slice Reply (- (buffer.length Reply) 3) 3))))))

(server-test.rejected
  [["GET / HTTP/1.1c#13;c#10;c#13;c#10;" [] 400]
   ["GET / HTTP/1.0c#13;c#10;Host: localhostc#13;c#10;c#13;c#10;" [] 505]
   ["POST / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;Content-Length: 3c#13;c#10;Content-Length: 3c#13;c#10;c#13;c#10;abc" [] 400]
   ["POST / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;Content-Length: 3c#13;c#10;c#13;c#10;abc" [[body-limit 2]] 413]
   ["POST / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;Content-Length: 3c#13;c#10;Expect: 100-continuec#13;c#10;c#13;c#10;" [] 417]
   ["POST / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;Transfer-Encoding: gzip, chunkedc#13;c#10;c#13;c#10;" [] 501]
   ["GET / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;c#13;c#10;" [[head-limit 32]] 431]
   ["" [[head-timeout 0]] 408]
   ["POST / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;Content-Length: 1c#13;c#10;c#13;c#10;" [[body-timeout 0]] 408]
   ["POST / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;Transfer-Encoding: chunkedc#13;c#10;c#13;c#10;3c#13;c#10;"
    [[body-limit 2]] 413]
   ["POST / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;Transfer-Encoding: chunkedc#13;c#10;c#13;c#10;0c#13;c#10;Content-Type: text/plainc#13;c#10;c#13;c#10;"
    [] 400]
   ["POST / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;Transfer-Encoding: chunkedc#13;c#10;c#13;c#10;"
    [[body-timeout 0]] 408]])

(let Exchange (server-test.exchange
       "POST / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;Content-Length: 5c#13;c#10;c#13;c#10;abc"
       [] (function server-test.handler) true)
     Error (hd (tl (hd Exchange)))
  (do (server-test.check "truncated body sends 400" 400 (freeze (server-test.status Exchange)))
      (server-test.check "truncation keeps consumed progress" 3 (freeze (io.error-progress Error)))))

(let Exchange (server-test.exchange "GET / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;c#13;c#10;"
                 [] (/. Request (error "handler failure")) false)
     Error (hd (tl (hd Exchange)))
  (do (server-test.check "handler exception becomes a single 500" 500 (freeze (server-test.status Exchange)))
      (server-test.check "application details stay in local error" application (freeze (io.error-domain Error)))))

(let Exchange (server-test.exchange "GET / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;c#13;c#10;"
                 [] (/. Request (http.response 200 [["X" "ac#13;c#10;bad"]] (buffer.new 0))) false)
  (server-test.check "invalid application response is rejected before writing" 500
    (freeze (server-test.status Exchange))))

(let Wire "GET / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;c#13;c#10;"
     Exchange (server-test.exchange (cn Wire Wire) [] (function server-test.handler) false)
  (server-test.check "pipelining never dispatches a second request" 1
    (freeze (hd (tl (tl Exchange))))))

(let Pair (server-test.pair)
     C (hd Pair)
     S (hd (tl Pair))
     Calls (io.record [0])
     Original (io.endpoint.write S)
     _ (io.endpoint.write-> S
         (/. B (let Count (+ 1 (<-address Calls 0)) _ (address-> Calls 0 Count)
                 (if (= Count 1)
                     (Original (shen-jit.copy-bytes (shen-jit.bytes 1) 0 B 0 1))
                     [error (io.native-error write timeout 0 "HTTP server" "forced partial timeout")]))))
     _ (io.write-all C (buffer.from-string "GET / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;c#13;c#10;") [])
     Result (http.serve-one S (/. Request (http.response 200 [] (buffer.from-string "ok"))) [])
     Error (hd (tl Result))
     Reply (server-test.collect (io.reader C []) 0 [])
     _ (io.close C)
  (do (server-test.check "partial response failure retains wire progress" [timeout 1]
        (freeze [(io.error-domain Error) (io.error-progress Error)]))
      (server-test.check "no second response after a partial write" "H" (freeze (buffer.string Reply)))
      (server-test.check "output failure is not retried as an error response" 2 (freeze (<-address Calls 0)))))

(server-test.check "epoch date" "Thu, 01 Jan 1970 00:00:00 GMT" (freeze (http.date-value 0)))
(server-test.check "HTTP date reference" "Sun, 06 Nov 1994 08:49:37 GMT" (freeze (http.date-value 784111777)))
(server-test.check "leap day" "Tue, 29 Feb 2000 00:00:00 GMT" (freeze (http.date-value 951782400)))

(server-test.check "native server supplies a Date when absent" true
  (freeze (http.has-date? (http.buffered-response.fields
                            (http.server-response (http.response 200 [] (buffer.new 0)))))))

(let Text "GET / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;c#13;c#10;"
     Bytes (shen-jit.string->bytes Text)
     N (shen-jit.bytes-length Bytes)
     M (memory.alloc N)
     _ (shen-jit.copy-bytes M 0 Bytes 0 N)
     Parsed (hd (tl (http.parse-request (buffer.wrap M) 0)))
     _ (memory.free M)
  (server-test.check "parsed metadata survives foreign input release" ["GET" ["localhost"]]
    (freeze [(http.method Parsed) (http.header-values Parsed "host")])))

(let M (memory.alloc 3)
     _ (shen-jit.copy-bytes M 0 (shen-jit.string->bytes "abc") 0 3)
     RO (shen-jit.pointer-read-only M)
     Q (hd (tl (http.parse-request
          (buffer.from-string "GET / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;c#13;c#10;") 0)))
     Wire (http.encode-response Q (http.response 200 [] (buffer.wrap RO)) 1024 3)
     _ (shen-jit.pointer-kill RO)
     _ (memory.free M)
  (server-test.check "encoded response owns a foreign read-only body" "abc"
    (freeze (buffer.string (buffer.slice Wire (- (buffer.length Wire) 3) 3)))))

(define server-test.repeat
  Text 0 -> Text
  Text N -> (server-test.repeat (cn Text Text) (- N 1)))

(let Body (buffer.new 32768)
     _ (buffer.u8! Body 32767 255)
     Wire (cn (make-string "POST / HTTP/1.1c#13;c#10;Host: localc#13;c#10;X-Padding: ~Ac#13;c#10;Content-Length: 32768c#13;c#10;c#13;c#10;"
                (server-test.repeat "z" 11)) (buffer.string Body))
     Exchange (server-test.exchange Wire [[read-buffer-size 7]] (function server-test.handler) false)
     Reply (hd (tl Exchange))
  (do (server-test.check "head larger than the reader spans refills" 200
        (freeze (server-test.status Exchange)))
      (server-test.check "binary body larger than the reader is preserved" true
        (freeze (buffer.equal? Body (buffer.slice Reply (- (buffer.length Reply) 32768) 32768))))))

(output "~A passed, ~A failed~%" (value server-test.passed) (value server-test.failed))
