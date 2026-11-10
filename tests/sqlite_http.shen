(set counter-test.passed 0)
(set counter-test.failed 0)

(define counter-test.check
  Name Expected F ->
    (let Actual (trap-error (thaw F) (/. X [raised (error-to-string X)]))
      (if (= Expected Actual)
          (set counter-test.passed (+ 1 (value counter-test.passed)))
          (do (set counter-test.failed (+ 1 (value counter-test.failed)))
              (output "FAIL ~A: wanted ~S, got ~S~%" Name Expected Actual)))))

(define counter-test.raises?
  F -> (trap-error (do (thaw F) false) (/. X true)))

(define counter-test.response
  Method Target ->
    (let Response (counter-app.route (value counter-test.path) Method Target)
      [(http.buffered-response.status Response) (buffer.string (http.buffered-response.body Response))]))

(counter-app.initialize (value counter-test.path))
(counter-test.check "health" [200 "{c#34;statusc#34;:c#34;okc#34;}"]
  (freeze (counter-test.response "GET" "/health")))
(counter-test.check "health method policy" [405 ""] (freeze (counter-test.response "POST" "/health")))
(counter-test.check "empty list" [200 "[]"] (freeze (counter-test.response "GET" "/counters")))
(counter-test.check "counter creation" [200 "{c#34;valuec#34;:1}"]
  (freeze (counter-test.response "POST" "/counters/hits")))
(counter-test.check "counter increment" [200 "{c#34;valuec#34;:2}"]
  (freeze (counter-test.response "POST" "/counters/hits")))
(counter-test.check "counter read" [200 "{c#34;valuec#34;:2}"]
  (freeze (counter-test.response "GET" "/counters/hits")))
(counter-test.check "bounded counter list" [200 "[{c#34;namec#34;:c#34;hitsc#34;,c#34;valuec#34;:2}]"]
  (freeze (counter-test.response "GET" "/counters")))
(counter-test.check "counter deletion" [204 ""] (freeze (counter-test.response "DELETE" "/counters/hits")))
(counter-test.check "deleted counter" [404 "{c#34;errorc#34;:c#34;counter not foundc#34;}"]
  (freeze (counter-test.response "GET" "/counters/hits")))
(map (/. Target
       (counter-test.check "invalid name" [] (freeze (counter-app.resource Target))))
  ["/counters/" "/counters/a/b" "/counters/a%20b" "/counters/a?b" "/counters/a'b"])
(counter-test.check "in-memory database rejected" true
  (freeze (counter-test.raises? (freeze (counter-app.initialize ":memory:")))))
(counter-test.check "numeric CLI port" 65535 (freeze (counter-app.port-number "65535")))
(counter-test.check "oversized CLI port" true
  (freeze (counter-test.raises? (freeze (counter-app.port-number "65536")))))
(counter-test.check "nondecimal CLI port" true
  (freeze (counter-test.raises? (freeze (counter-app.port-number "80junk")))))
(sqlite.with-database (value counter-test.path)
  (/. Db
    (do (sqlite.run Db "INSERT INTO counters VALUES (?, ?)" ["limit" 1000000000000])
        (counter-test.check "constraint failure propagates" true
          (freeze (counter-test.raises? (freeze (counter-app.increment Db "limit")))))
        (counter-test.check "failed increment rolls back" [[1000000000000]]
          (freeze (sqlite.query Db "SELECT value FROM counters WHERE name = ?" ["limit"]))))))
(define counter-test.put
  Text Type ->
    (let V (buffer.from-string Text)
         Head (buffer.from-string
                (make-string "PUT /counters/body HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;Content-Type: ~Ac#13;c#10;Content-Length: ~Ac#13;c#10;c#13;c#10;"
                  Type (buffer.length V)))
         Q (hd (tl (http.parse-request Head 4096)))
         E (io.input-buffer V)
         Full (hd (tl (http.read-body (http.body-reader (io.reader E []) Q))))
         _ (io.close E)
         Response (counter-app.handle (value counter-test.path) Full)
      [(http.buffered-response.status Response) (buffer.string (http.buffered-response.body Response))]))

(counter-test.check "JSON body updates the database" [200 "{c#34;valuec#34;:42}"]
  (freeze (counter-test.put "{c#34;valuec#34;:42}" "application/json")))
(counter-test.check "JSON media type matching ignores ASCII case" [200 "{c#34;valuec#34;:43}"]
  (freeze (counter-test.put "{c#34;valuec#34;:43}" "APPLICATION/JSON")))
(counter-test.check "invalid JSON gives 400" 400
  (freeze (hd (counter-test.put "{c#34;valuec#34;:" "application/json"))))
(counter-test.check "duplicate JSON members give 400" 400
  (freeze (hd (counter-test.put "{c#34;valuec#34;:1,c#34;valuec#34;:2}" "application/json"))))
(counter-test.check "nonintegral JSON gives 400" 400
  (freeze (hd (counter-test.put "{c#34;valuec#34;:1.0}" "application/json"))))
(counter-test.check "wrong JSON media type gives 415" 415
  (freeze (hd (counter-test.put "{c#34;valuec#34;:1}" "text/plain"))))
(counter-test.check "invalid updates leave the stored value alone" [200 "{c#34;valuec#34;:43}"]
  (freeze (counter-test.response "GET" "/counters/body")))
(output "~A passed, ~A failed~%" (value counter-test.passed) (value counter-test.failed))
