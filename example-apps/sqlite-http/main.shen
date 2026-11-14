\\ A small persistent counter API. Load the public HTTP listener, grammar and SQLite libraries first.

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

\\ The database belongs to one isolate, which holds it open and does each request's work in turn:
\\ SQLite takes one writer at a time and makes the others retry, sleeping a millisecond or more for a
\\ write of tens of microseconds. A handler sends the owning isolate [Job Reply] and waits for [ok
\\ Result] or [error Message]. Db is the path, the owning isolate's send endpoint and the owning
\\ isolate, [Path Requests Owner], which crosses to each connection's isolate; or a path alone, for
\\ which each job opens the database, as the tests do without a server. An export reads through a
\\ connection of its own, which the log lets it hold while the owning isolate writes.
(define counter-app.job
  Db [list] -> (sqlite.query Db "SELECT name, value FROM counters ORDER BY name LIMIT 100" [])
  Db [value Name] -> (sqlite.query Db "SELECT value FROM counters WHERE name = ?" [Name])
  Db [increment Name] ->
    (sqlite.transaction Db
      (freeze
        (do (sqlite.run Db "INSERT OR IGNORE INTO counters (name, value) VALUES (?, 0)" [Name])
            (sqlite.run Db "UPDATE counters SET value = value + 1 WHERE name = ?" [Name])
            (sqlite.query Db "SELECT value FROM counters WHERE name = ?" [Name]))))
  Db [set Name N] ->
    (sqlite.transaction Db
      (freeze
        (do (sqlite.run Db "INSERT OR IGNORE INTO counters (name, value) VALUES (?, 0)" [Name])
            (sqlite.run Db "UPDATE counters SET value = ? WHERE name = ?" [N Name])
            (sqlite.query Db "SELECT value FROM counters WHERE name = ?" [Name]))))
  Db [delete Name] -> (sqlite.run Db "DELETE FROM counters WHERE name = ?" [Name]))

(define counter-app.do
  [_ Requests Owner] Job -> (counter-app.ask Requests Owner Job)
  Path Job -> (sqlite.with-database Path (/. Db (counter-app.job Db Job))))

(define counter-app.path
  [Path _ _] -> Path
  Path -> Path)

\\ It waits for the reply or the owning isolate's end, so that a handler does not wait for ever on an
\\ owner that has gone, as one whose database could not be opened.
(define counter-app.ask
  Requests Owner Job ->
    (let R (channel.new 1)
         M (shen-jit.on-error (freeze (isolate.monitor Owner)) (freeze (channel.close R)))
         Got (shen-jit.finally (freeze (do (channel.send Requests [Job (channel.sender R)])
                                           (channel.receive-any [R M])))
                               (freeze (do (trap-error (channel.close R) (/. X skip))
                                           (trap-error (channel.close M) (/. X skip)))))
      (counter-app.answer R Got)))

(define counter-app.answer
  R [R [ok Result]] -> Result
  R [R [error Message]] -> (simple-error Message)
  _ _ -> (error "the database's owning isolate has ended"))

(define counter-app.owner
  [Path Requests] -> (sqlite.with-database Path (/. Db (counter-app.serve-jobs Db Requests))))

(define counter-app.serve-jobs
  Db Requests -> (counter-app.serve-job Db Requests (channel.next Requests)))

\\ A reply to a handler that has gone, as a killed connection's, is dropped; a kill of the owning
\\ isolate, which the send raises if one came during the job, ends it, closing the database.
(define counter-app.serve-job
  _ _ [closed] -> done
  Db Requests [ok [Job Reply]] ->
    (let Result (trap-error [ok (counter-app.job Db Job)] (/. X [error (error-to-string X)]))
         _ (trap-error (channel.send Reply Result) (function counter-app.gone))
      (counter-app.serve-jobs Db Requests)))

(define counter-app.gone
  X -> (if (= (error-to-string X) "channel closed") skip (simple-error (error-to-string X))))

\\ Starts the owning isolate: [Db Monitor], Db for the handlers and Monitor for the owning isolate's end.
\\ What it makes is kept in Cell, [Requests Owner Monitor], by stores, which do not allocate, under one
\\ cleanup made first, so that a failure anywhere, even making the result, undoes it: before the owning
\\ isolate starts, by closing its channel; after, by closing the send endpoint, which ends it, and once it is
\\ monitored, by waiting for its end.
(define counter-app.open
  Path -> (let Cell (address-> (address-> (address-> (absvector 3) 0 []) 1 []) 2 [])
               R (channel.new 64)
            (shen-jit.on-error
              (freeze (let Requests (counter-app.kept Cell 0 (channel.sender R))
                           I (counter-app.kept Cell 1 (isolate.spawn counter-app.owner [Path (channel.give R)]))
                           Monitor (counter-app.kept Cell 2 (isolate.monitor I))
                        [[Path Requests I] Monitor]))
              (freeze (counter-app.undo-open R Cell)))))

(define counter-app.kept
  Cell I X -> (do (address-> Cell I X) X))

(define counter-app.undo-open
  R Cell -> (cases (empty? (<-address Cell 1)) (channel.close R)
                   (empty? (<-address Cell 2)) (channel.close (<-address Cell 0))
                   true (counter-app.end-owner (<-address Cell 0) (<-address Cell 2))))

(define counter-app.db
  [Db _] -> Db)

\\ Ends the owning isolate's stream, which it reads to its end, and waits for it to close the database.
(define counter-app.close
  [[_ Requests _] Monitor] -> (counter-app.end-owner Requests Monitor))

(define counter-app.end-owner
  Requests Monitor -> (do (channel.close Requests) (channel.receive Monitor) (channel.close Monitor) true))

(define counter-app.list
  Db -> (counter-app.json 200 (map (function counter-app.row-json) (counter-app.do Db [list]))))

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

(define counter-app.delete
  Db Name -> (if (= (counter-app.do Db [delete Name]) 0)
                 (counter-app.error 404 "counter not found")
                 (http.response 204 [] (buffer.new 0))))

(define counter-app.not-allowed
  Methods -> (http.response 405 [["Allow" Methods]] (buffer.new 0)))

\\ One clause for each method on each resource. HEAD is GET, whose body the encoder leaves out.
(define counter-app.serve
  Db "HEAD" Resource -> (counter-app.serve Db "GET" Resource)
  _ "GET" [health] -> (counter-app.json 200 [object ["status" "ok"]])
  Db "GET" [counters] -> (counter-app.list Db)
  Db "GET" [export] -> (counter-app.export (counter-app.path Db))
  Db "GET" [counter Name] -> (counter-app.found (counter-app.do Db [value Name]))
  Db "POST" [counter Name] -> (counter-app.found (counter-app.do Db [increment Name]))
  Db "DELETE" [counter Name] -> (counter-app.delete Db Name)
  _ _ [counter _] -> (counter-app.not-allowed "GET, HEAD, POST, PUT, DELETE")
  _ _ [_] -> (counter-app.not-allowed "GET, HEAD")
  _ _ [] -> (counter-app.error 404 "route not found"))

(define counter-app.route
  Db Method Target -> (counter-app.serve Db Method (counter-app.resource Target)))

\\ Only PUT on a counter has a body.
(define counter-app.handle
  Db Request -> (counter-app.request Db Request (counter-app.resource (http.target Request))))

(define counter-app.request
  Db Request [counter Name] -> (counter-app.set-request Db Name Request) where (= (http.method Request) "PUT")
  _ Request _ -> (counter-app.error 400 "this route expects an empty body") where (> (http.content-length Request) 0)
  Db Request Resource -> (counter-app.serve Db (http.method Request) Resource))

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
  Db Name Request ->
    (if (counter-app.json-type? (http.header-values Request "content-type"))
        (let Value (trap-error
                      (counter-app.input-value (json.decode (http.body Request) [[byte-limit 4096]]))
                      (function counter-app.json-error))
          (counter-app.set-input Db Name Value))
        (counter-app.error 415 "expected application/json")))

(define counter-app.set-input
  _ _ [invalid] -> (counter-app.error 400 "expected an object with one decimal integer value in 0..1000000000000")
  Db Name [ok N] -> (counter-app.found (counter-app.do Db [set Name N])))

\\ The owner, and a server whose handler F is called with Db and the request: [Owner Server]. Each is
\\ kept in Cell as it is made, so that a failure after it, even making the result, stops the server,
\\ which closes its listener, and ends the owning isolate.
(define counter-app.start
  Path Host Port F Options ->
    (let _ (counter-app.initialize Path)
         Cell (address-> (address-> (absvector 2) 0 []) 1 [])
      (shen-jit.on-error
        (freeze (let Owner (counter-app.kept Cell 0 (counter-app.open Path))
                     S (counter-app.kept Cell 1 (http.listen Host Port [F (counter-app.db Owner)] Options))
                  [Owner S]))
        (freeze (counter-app.undo-start Cell)))))

\\ The server, never run, closes its listener before allocating anything; the owning isolate ends
\\ even if that raises.
(define counter-app.undo-start
  Cell -> (shen-jit.finally
            (freeze (if (empty? (<-address Cell 1)) true (do (http.stop (<-address Cell 1)) (http.run (<-address Cell 1)))))
            (freeze (if (empty? (<-address Cell 0)) true (counter-app.close (<-address Cell 0))))))

\\ Serves until a handler stops the server, each connection in an isolate of its own, then ends the
\\ owner. The owner holds the database open meanwhile, so the log stays between requests: the last
\\ connection to close checkpoints it and removes it, which made each write many times slower.
(define counter-app.await
  Owner S -> (counter-app.await-result S (shen-jit.finally (freeze (http.run S)) (freeze (counter-app.close Owner)))))

(define counter-app.await-result
  _ [ok] -> true
  _ [error Error] -> (error "counter server: ~A" (io.error-message Error)))

(define counter-app.run
  Path Port ->
    (let Started (counter-app.start Path "127.0.0.1" Port counter-app.control
                   [[body-limit 4096] [response-body-limit 65536]])
         _ (output "Listening on http://127.0.0.1:~A~%" (http.port (hd (tl Started))))
      (counter-app.await (hd Started) (hd (tl Started)))))

(define counter-app.control
  Db Request ->
    (if (= (http.target Request) "/shutdown")
        (cond ((not (= (http.method Request) "POST"))
                (http.response 405 [["Allow" "POST"]] (buffer.new 0)))
              ((> (http.content-length Request) 0)
                (counter-app.error 400 "this API expects an empty body"))
              (true (do (http.stop (http.current-server))
                        (http.close-after (counter-app.json 202 [object ["stopping" true]])))))
        (counter-app.handle Db Request)))

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
