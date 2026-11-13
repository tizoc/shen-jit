\\ A small persistent counter API. Load the public HTTP listener, grammar and SQLite libraries first.
\\ Each database connection belongs to the connection's isolate that opens it.

\\ The database keeps a write-ahead log, so that writers do not wait for readers, such as an
\\ export, nor readers for writers.
(define counter-app.initialize
  Path ->
    (do (if (or (= Path "") (= Path ":memory:")) (error "counter app needs a database file") true)
        (sqlite.with-database Path
          (/. Db (do (sqlite.exec Db "PRAGMA journal_mode=WAL")
                     (sqlite.exec Db
                       "CREATE TABLE IF NOT EXISTS counters (
                          name TEXT PRIMARY KEY,
                          value INTEGER NOT NULL CHECK(value BETWEEN 0 AND 1000000000000)
                        )"))))))

(define counter-app.json
  Status Value ->
    (http.response Status [["Content-Type" "application/json"]] (json.encode Value [[byte-limit 65536]])))

(define counter-app.error
  Status Message ->
    (counter-app.json Status [object ["error" Message]]))

(defgrammar counter-app.<name-byte>
  B where (or (and (>= B 65) (<= B 90)) (and (>= B 97) (<= B 122)) (and (>= B 48) (<= B 57)) (= B 45) (= B 95));)
(defgrammar counter-app.<name> (+ counter-app.<name-byte>);)
(defgrammar counter-app.<resource>
  "/health" := [health];
  "/counters.ndjson" := [export];
  "/counters/" (text counter-app.<name>) := [counter counter-app.<name>];
  "/counters" := [counters];)

\\ What a target names: [health], [counters], [export], [counter Name] with a name of at most 64
\\ bytes, or [] for nothing.
(define counter-app.resource
  Target -> (let B (shen-jit.string->bytes Target) N (shen-jit.bytes-length B)
              (if (<= N 74) (grammar.parse-range counter-app.<resource> B 0 N (/. At Message [])) [])))

(define counter-app.row-json
  [Name Value] -> [object ["name" Name] ["value" Value]])

(define counter-app.list
  Db -> (counter-app.json 200
          (map (function counter-app.row-json)
               (sqlite.query Db "SELECT name, value FROM counters ORDER BY name LIMIT 100" []))))

\\ The export owns its statement/database until the response source closes, including HEAD.
(define counter-app.export
  Path ->
    (let Db (sqlite.open Path)
         Stmt (shen-jit.on-error
                (freeze (sqlite.prepare Db "SELECT name, value FROM counters ORDER BY name LIMIT 100"))
                (freeze (sqlite.close Db)))
         State (io.record [Stmt [] 0 false])
      (shen-jit.on-error
        (freeze (http.stream-response 200 [["Content-Type" "application/x-ndjson"]] [chunked]
                  (http.source (/. Maximum D (counter-app.export-next State Maximum D))
                               (freeze (counter-app.export-close Db Stmt)))))
        (freeze (counter-app.export-close Db Stmt)))))

(define counter-app.export-close
  Db Stmt ->
    (let Finalized (trap-error (do (sqlite.finalize Stmt) [ok 0])
                      (/. X [error (io.error close "counter export statement" (error-to-string X)) 0]))
         Closed (trap-error (do (sqlite.close Db) [ok])
                   (/. X [error (io.error close "counter export database" (error-to-string X))]))
      (io.close-combine Finalized Closed)))

\\ State: statement, pending encoded row, next row byte, query exhausted.
\\ A batch owns its bytes; keep only one pending row across sender callbacks.
(define counter-app.export-next
  State Maximum D ->
    (let Limit (io.min (io.capacity Maximum) 16384)
      (counter-app.export-fill State (buffer.builder Limit) Limit D)))

(define counter-app.export-fill
  State Out Limit D ->
    (cond ((deadline.expired? D)
            [error (io.native-error read timeout 0 "counter export" "write deadline expired")])
          ((= (buffer.builder-length Out) Limit) [chunk (buffer.finish Out)])
          ((not (empty? (<-address State 1))) (counter-app.export-copy State Out Limit D))
          ((<-address State 3)
            (if (= (buffer.builder-length Out) 0) [eof] [chunk (buffer.finish Out)]))
          (true (counter-app.export-step State Out Limit D (sqlite.step (<-address State 0))))))

(define counter-app.export-copy
  State Out Limit D ->
    (let Row (<-address State 1)
         At (<-address State 2)
         Left (- (buffer.length Row) At)
         N (io.min Left (- Limit (buffer.builder-length Out)))
      (do (if (= Left 0)
              (do (buffer.append-byte! Out 10) (address-> State 1 []))
              (do (buffer.append! Out (buffer.slice Row At N))
                  (address-> State 2 (+ At N))))
          (counter-app.export-fill State Out Limit D))))

(define counter-app.export-step
  State Out Limit D done ->
    (do (address-> State 3 true) (counter-app.export-fill State Out Limit D))
  State Out Limit D row ->
    (let Row (json.encode (counter-app.row-json (sqlite.row (<-address State 0))) [[byte-limit 4096]])
         _ (address-> State 1 Row)
         _ (address-> State 2 0)
      (counter-app.export-fill State Out Limit D)))

(define counter-app.found
  [] -> (counter-app.error 404 "counter not found")
  [[Value]] -> (counter-app.json 200 [object ["value" Value]]))

(define counter-app.increment
  Db Name ->
    (sqlite.transaction Db
      (freeze
        (do (sqlite.run Db "INSERT OR IGNORE INTO counters (name, value) VALUES (?, 0)" [Name])
            (sqlite.run Db "UPDATE counters SET value = value + 1 WHERE name = ?" [Name])
            (counter-app.found (sqlite.query Db "SELECT value FROM counters WHERE name = ?" [Name]))))))

(define counter-app.value
  Db Name -> (counter-app.found (sqlite.query Db "SELECT value FROM counters WHERE name = ?" [Name])))

(define counter-app.delete
  Db Name -> (if (= (sqlite.run Db "DELETE FROM counters WHERE name = ?" [Name]) 0)
                 (counter-app.error 404 "counter not found")
                 (http.response 204 [] (buffer.new 0))))

(define counter-app.not-allowed
  Methods -> (http.response 405 [["Allow" Methods]] (buffer.new 0)))

\\ One clause for each method on each resource. HEAD is GET, whose body the encoder leaves out.
(define counter-app.serve
  Path "HEAD" Resource -> (counter-app.serve Path "GET" Resource)
  _ "GET" [health] -> (counter-app.json 200 [object ["status" "ok"]])
  Path "GET" [counters] -> (sqlite.with-database Path (function counter-app.list))
  Path "GET" [export] -> (counter-app.export Path)
  Path "GET" [counter Name] -> (sqlite.with-database Path (/. Db (counter-app.value Db Name)))
  Path "POST" [counter Name] -> (sqlite.with-database Path (/. Db (counter-app.increment Db Name)))
  Path "DELETE" [counter Name] -> (sqlite.with-database Path (/. Db (counter-app.delete Db Name)))
  _ _ [counter _] -> (counter-app.not-allowed "GET, HEAD, POST, PUT, DELETE")
  _ _ [_] -> (counter-app.not-allowed "GET, HEAD")
  _ _ [] -> (counter-app.error 404 "route not found"))

(define counter-app.route
  Path Method Target -> (counter-app.serve Path Method (counter-app.resource Target)))

\\ Only PUT on a counter has a body.
(define counter-app.handle
  Path Request -> (counter-app.request Path Request (counter-app.resource (http.target Request))))

(define counter-app.request
  Path Request [counter Name] -> (counter-app.set-request Path Name Request) where (= (http.method Request) "PUT")
  _ Request _ -> (counter-app.error 400 "this route expects an empty body") where (> (http.content-length Request) 0)
  Path Request Resource -> (counter-app.serve Path (http.method Request) Resource))

(define counter-app.lower
  Text ->
    (let B (buffer.from-string Text)
         _ (counter-app.lower-bytes (buffer.owner B) 0 (buffer.length B))
      (buffer.string B)))

(define counter-app.lower-bytes
  _ At At -> true
  B At End ->
    (let Byte (shen-jit.u8 B At)
         _ (if (and (>= Byte 65) (<= Byte 90)) (shen-jit.u8! B At (+ Byte 32)) true)
      (counter-app.lower-bytes B (+ At 1) End)))

(define counter-app.json-type?
  [Value] -> (element? (counter-app.lower Value)
                ["application/json" "application/json; charset=utf-8" "application/json;charset=utf-8"])
  _ -> false)

(define counter-app.json-error
  X ->
    (let Text (error-to-string X)
         B (shen-jit.string->bytes Text)
      (if (and (>= (shen-jit.bytes-length B) 6) (= (shen-jit.bytes->string B 0 6) "json: "))
          [invalid] (simple-error Text))))

(define counter-app.input-value
  [object ["value" Value]] ->
    (let N (json.integer Value) (if (and (>= N 0) (<= N 1000000000000)) [ok N] [invalid]))
  _ -> [invalid])

(define counter-app.set-request
  Path Name Request ->
    (if (counter-app.json-type? (http.header-values Request "content-type"))
        (let Value (trap-error
                      (counter-app.input-value (json.decode (http.body Request) [[byte-limit 4096]]))
                      (function counter-app.json-error))
          (counter-app.set-input Path Name Value))
        (counter-app.error 415 "expected application/json")))

(define counter-app.set-input
  _ _ [invalid] -> (counter-app.error 400 "expected an object with one decimal integer value in 0..1000000000000")
  Path Name [ok N] ->
    (sqlite.with-database Path
      (/. Db (sqlite.transaction Db
               (freeze
                 (do (sqlite.run Db "INSERT OR IGNORE INTO counters (name, value) VALUES (?, 0)" [Name])
                     (sqlite.run Db "UPDATE counters SET value = ? WHERE name = ?" [N Name])
                     (counter-app.found (sqlite.query Db "SELECT value FROM counters WHERE name = ?" [Name]))))))))

(define counter-app.start
  Path Host Port Options ->
    (do (counter-app.initialize Path)
        (http.listen Host Port [counter-app.handle Path] Options)))

\\ Serves until a handler stops the server, each connection in an isolate of its own, holding the
\\ database open meanwhile. Each request opens a connection of its own, and the last connection to
\\ close would checkpoint the log and remove it, which made each write many times slower. A
\\ connection holds the file only once it has read it.
(define counter-app.await
  Path S -> (sqlite.with-database Path
              (/. Db (do (sqlite.query Db "SELECT count(*) FROM counters" [])
                         (counter-app.await-result S (http.run S))))))

(define counter-app.await-result
  _ [ok] -> true
  _ [error Error] -> (error "counter server: ~A" (io.error-message Error)))

(define counter-app.run
  Path Port ->
    (let _ (counter-app.initialize Path)
         S (http.listen "127.0.0.1" Port [counter-app.control Path]
              [[body-limit 4096] [response-body-limit 65536]])
         _ (output "Listening on http://127.0.0.1:~A~%" (http.port S))
      (counter-app.await Path S)))

(define counter-app.control
  Path Request ->
    (if (= (http.target Request) "/shutdown")
        (cond ((not (= (http.method Request) "POST"))
                (http.response 405 [["Allow" "POST"]] (buffer.new 0)))
              ((> (http.content-length Request) 0)
                (counter-app.error 400 "this API expects an empty body"))
              (true (do (http.stop (http.current-server))
                        (http.close-after (counter-app.json 202 [object ["stopping" true]])))))
        (counter-app.handle Path Request)))

(define counter-app.port-number
  Text ->
    (let B (shen-jit.string->bytes Text)
         N (shen-jit.bytes-length B)
      (if (> N 0) (counter-app.port-digits B 0 N 0) (error "empty port"))))

(define counter-app.port-digits
  _ At At N -> N
  B At End N ->
    (let Digit (- (shen-jit.u8 B At) 48)
      (if (and (>= Digit 0) (<= Digit 9) (<= N 6553) (or (< N 6553) (<= Digit 5)))
          (counter-app.port-digits B (+ At 1) End (+ (* N 10) Digit))
          (error "port must be decimal 0..65535"))))

(define counter-app.main
  [_ Path Port] -> (counter-app.run Path (counter-app.port-number Port))
  _ -> (error "usage: shen-jit script example-apps/sqlite-http/run.shen DATABASE PORT"))
