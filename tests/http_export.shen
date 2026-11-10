\\ The actual SQLite export through the public sender: bounded batches and cleanup on every exit.
(set export-test.passed 0)
(set export-test.failed 0)

(define export-test.check
  Name Expected F ->
    (let Actual (trap-error (thaw F) (/. X [raised (error-to-string X)]))
      (if (= Actual Expected)
          (set export-test.passed (+ 1 (value export-test.passed)))
          (do (set export-test.failed (+ 1 (value export-test.failed)))
              (output "FAIL ~A: wanted ~S, got ~S~%" Name Expected Actual)))))

(define export-test.request
  Method -> (hd (tl (http.parse-request
                     (buffer.from-string (make-string "~A / HTTP/1.1c#13;c#10;Host: localc#13;c#10;c#13;c#10;" Method)) 65536))))

(define export-test.send
  Method Maximum D ->
    (let Response (counter-app.export (value export-test.path))
         Out (buffer.new 131072)
         E (io.output-buffer Out)
         Result (http.send-response E (export-test.request Method) Response D
                  [[response-chunk-size Maximum] [response-body-limit 65536]
                   [response-chunk-count-limit 65536]])
         _ (io.close E)
      [Result Out (http.source-close (http.response-source Response))]))

(define export-test.body
  [[ok N] Out _] ->
    (let E (io.input-buffer (buffer.slice Out 0 N))
         R (io.reader E [[chunk-size 7]])
         _ (http.read-head (http.head-reader R 1024))
         Q (hd (tl (http.parse-request
                    (buffer.from-string "POST / HTTP/1.1c#13;c#10;Host: localc#13;c#10;Transfer-Encoding: chunkedc#13;c#10;c#13;c#10;") 65536)))
         Full (hd (tl (http.read-body (http.body-reader R Q))))
         _ (io.close E)
      (buffer.string (http.body Full))))

(define export-test.seed
  _ 105 -> true
  Db N ->
    (do (sqlite.run Db "INSERT INTO counters(name, value) VALUES (?, ?)" [(make-string "counter-~A" N) N])
        (export-test.seed Db (+ N 1))))

(define export-test.lines
  [] -> ""
  [Row | Rest] -> (cn (json.stringify (counter-app.row-json Row) []) (cn "c#10;" (export-test.lines Rest))))

(define export-test.long-name
  -> (let Bytes (shen-jit.bytes 5000)
          _ (export-test.fill Bytes 0 5000)
       (shen-jit.bytes->string Bytes 0 5000)))

(define export-test.fill
  _ N N -> true
  Bytes At End -> (do (shen-jit.u8! Bytes At 122) (export-test.fill Bytes (+ At 1) End)))

(counter-app.initialize (value export-test.path))
(let Sent (export-test.send "GET" 16 (deadline.after (freeze 0) 1000))
  (do (export-test.check "empty export" "" (freeze (export-test.body Sent)))
      (export-test.check "empty export source closed" [ok] (freeze (hd (tl (tl Sent)))))))

(sqlite.with-database (value export-test.path) (/. Db (export-test.seed Db 0)))
(let Expected (sqlite.with-database (value export-test.path)
                 (/. Db (export-test.lines
                          (sqlite.query Db "SELECT name, value FROM counters ORDER BY name LIMIT 100" []))))
  (map (/. Maximum
         (let Sent (export-test.send "GET" Maximum (deadline.after (freeze 0) 1000))
           (do (export-test.check "all rows survive arbitrary chunk boundaries" Expected
                 (freeze (export-test.body Sent)))
               (export-test.check "successful export closes its database/statement" [ok]
                 (freeze (hd (tl (tl Sent))))))))
    [1 7 31 4096 16384 65536]))

\\ An invalid later row must fail the first batch before any response output, then release the query.
(sqlite.with-database (value export-test.path)
  (/. Db (do (sqlite.exec Db "DELETE FROM counters")
             (sqlite.run Db "INSERT INTO counters VALUES (?, ?)" ["a" 1])
             (sqlite.run Db "INSERT INTO counters VALUES (?, ?)" [(export-test.long-name) 2]))))
(let Sent (export-test.send "HEAD" 16384 (deadline.after (freeze 0) 1000))
  (export-test.check "HEAD closes without encoding or stepping invalid rows" ok (freeze (hd (hd Sent)))))
(let Sent (export-test.send "GET" 16384 (deadline.after (freeze 0) 1000))
     Result (hd Sent)
  (do (export-test.check "invalid row fails before headers" [application 0]
        (freeze [(io.error-domain (hd (tl Result))) (io.error-progress (hd (tl Result)))]))
      (export-test.check "row failure still closes database and statement" [ok]
        (freeze (hd (tl (tl Sent)))))))

(sqlite.with-database (value export-test.path)
  (/. Db (do (sqlite.exec Db "DELETE FROM counters") (export-test.seed Db 0))))
(let Time (io.record [0])
     D (deadline.after (freeze (let N (<-address Time 0) _ (address-> Time 0 (+ N 1)) N)) 8)
     Sent (export-test.send "GET" 16384 D)
     Error (hd (tl (hd Sent)))
  (do (export-test.check "batch construction observes its total deadline" [timeout 0]
        (freeze [(io.error-domain Error) (io.error-progress Error)]))
      (export-test.check "expired batch closes database and statement" [ok]
        (freeze (hd (tl (tl Sent)))))))

(output "~A passed, ~A failed~%" (value export-test.passed) (value export-test.failed))
