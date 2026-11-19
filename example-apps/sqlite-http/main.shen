\\ A small persistent counter API. Load the public HTTP listener, grammar and SQLite libraries first.

(shen.x.namespace counter-app
  (import result ok err)
  (use buffer)
  (use counter-app)
  (use deadline)
  (use grammar)
  (use http)
  (use io)
  (use json)
  (use shen-jit)
  (use sqlite)
  (shadow open run)
  (externals [body-limit byte-limit chunked closed counter counters defgrammar delete done export health
    increment invalid io.capacity object response-body-limit row skip text timeout])

\\ The database keeps a write-ahead log, so that writers do not wait for readers, such as an
\\ export, nor readers for writers.
(define initialize
  Path ->
    (do (if (or (= Path "") (= Path ":memory:")) (error "counter app needs a database file") true)
        (sqlite.with-database Path
          (/. Db (do (sqlite.exec Db "PRAGMA journal_mode=WAL")
                     (sqlite.exec Db
                       "CREATE TABLE IF NOT EXISTS counters (
                          name TEXT PRIMARY KEY,
                          value INTEGER NOT NULL CHECK(value BETWEEN 0 AND 1000000000000)
                        )"))))))

(define json
  Status Value ->
    (http.response Status [["Content-Type" "application/json"]] (json.encode Value [[byte-limit 65536]])))

(define counter-app.error
  Status Message ->
    (json Status [object ["error" Message]]))

(defgrammar <name-byte>
  B where (or (and (>= B 65) (<= B 90)) (and (>= B 97) (<= B 122)) (and (>= B 48) (<= B 57)) (= B 45) (= B 95));)
(defgrammar <name> (+ <name-byte>);)
(defgrammar <resource>
  "/health" := [health];
  "/counters.ndjson" := [export];
  "/counters/" (text <name>) := [counter <name>];
  "/counters" := [counters];)

\\ What a target names: [health], [counters], [export], [counter Name] with a name of at most 64
\\ bytes, or [] for nothing.
(define resource
  Target -> (let B (shen-jit.string->bytes Target) N (shen-jit.bytes-length B)
              (if (<= N 74) (grammar.parse-range <resource> B 0 N (/. At Message [])) [])))

(define row-json
  [Name Value] -> [object ["name" Name] ["value" Value]])

\\ The database belongs to one isolate, which holds it open and does each request's work in turn:
\\ SQLite takes one writer at a time and makes the others retry, sleeping a millisecond or more for a
\\ write of tens of microseconds. A handler sends the owning isolate [Job Reply] and waits for
\\ (:ok Result) or (:err Message). Db is the path, the owning isolate's send endpoint and the owning
\\ isolate, [Path Requests Owner], which crosses to each connection's isolate; or a path alone, for
\\ which each job opens the database, as the tests do without a server. An export reads through a
\\ connection of its own, which the log lets it hold while the owning isolate writes.
(define job
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
  [_ Requests Owner] Job -> (ask Requests Owner Job)
  Path Job -> (sqlite.with-database Path (/. Db (job Db Job))))

(define path
  [Path _ _] -> Path
  Path -> Path)

\\ It waits for the reply or the owning isolate's end, so that a handler does not wait for ever on an
\\ owner that has gone, as one whose database could not be opened.
(define ask
  Requests Owner Job ->
    (let R (channel.new 1)
         M (shen-jit.on-error (freeze (isolate.monitor Owner)) (freeze (channel.close R)))
         Got (shen-jit.finally (freeze (do (channel.send Requests [Job (channel.sender R)])
                                           (channel.receive-any [R M])))
                               (freeze (do (trap-error (channel.close R) (/. X skip))
                                           (trap-error (channel.close M) (/. X skip)))))
      (answer R Got)))

(define answer
  R [R (:ok Result)] -> Result
  R [R (:err Message)] -> (simple-error Message)
  _ _ -> (error "the database's owning isolate has ended"))

(define owner
  [Path Requests] -> (sqlite.with-database Path (/. Db (serve-jobs Db Requests))))

(define serve-jobs
  Db Requests -> (serve-job Db Requests (channel.next Requests)))

\\ A reply to a handler that has gone, as a killed connection's, is dropped; a kill of the owning
\\ isolate, which the send raises if one came during the job, ends it, closing the database.
(define serve-job
  _ _ [closed] -> done
  Db Requests (with-externals [ok] [ok [Job Reply]]) ->
    (let Result (trap-error (:ok (job Db Job)) (/. X (:err (error-to-string X))))
         _ (trap-error (channel.send Reply Result) (function gone))
      (serve-jobs Db Requests)))

(define gone
  X -> (if (= (error-to-string X) "channel closed") skip (simple-error (error-to-string X))))

\\ Starts the owning isolate: [Db Monitor], Db for the handlers and Monitor for the owning isolate's end.
\\ If making the result fails, spawn-each kills it, which closes the database, and waits for its end;
\\ its channel is closed, which does nothing once it has gone with the isolate.
(define open
  Path -> (let R (channel.new 64)
            (shen-jit.on-error
              (freeze (let Requests (channel.sender R)
                        (isolate.spawn-each owner [[Path (channel.give R)]]
                          (/. Started [[Path Requests (hd (hd Started))] (tl (hd Started))]))))
              (freeze (channel.close R)))))

(define kept
  Cell I X -> (do (address-> Cell I X) X))

(define db
  [Db _] -> Db)

\\ Ends the owning isolate's stream, which it reads to its end, and waits for it to close the database.
(define counter-app.close
  [[_ Requests _] Monitor] -> (do (channel.close Requests) (channel.receive Monitor) (channel.close Monitor) true))

(define counter-app.list
  Db -> (json 200 (map (function row-json) (counter-app.do Db [list]))))

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
                  (http.source (/. Maximum D (export-next State Maximum D))
                               (freeze (export-close Db Stmt)))))
        (freeze (export-close Db Stmt)))))

(define export-close
  Db Stmt ->
    (let Finalized (trap-error (do (sqlite.finalize Stmt) (:ok []))
                      (/. X (:err (io.error close "counter export statement" (error-to-string X)))))
         Closed (trap-error (do (sqlite.close Db) (:ok []))
                   (/. X (:err (io.error close "counter export database" (error-to-string X)))))
      (io.finish Finalized Closed)))

\\ State: statement, pending encoded row, next row byte, query exhausted.
\\ A batch owns its bytes; keep only one pending row across sender callbacks.
(define export-next
  State Maximum D ->
    (let Limit (io.min (io.capacity Maximum) 16384)
      (export-fill State (buffer.builder Limit) Limit D)))

(define export-fill
  State Out Limit D ->
    (cond ((deadline.expired? D)
            (:err (io.native-error read timeout 0 "counter export" "write deadline expired")))
          ((= (buffer.builder-length Out) Limit) (:ok [(buffer.finish Out)]))
          ((not (empty? (<-address State 1))) (export-copy State Out Limit D))
          ((<-address State 3)
            (if (= (buffer.builder-length Out) 0) (:ok []) (:ok [(buffer.finish Out)])))
          (true (export-step State Out Limit D (sqlite.step (<-address State 0))))))

(define export-copy
  State Out Limit D ->
    (let Row (<-address State 1)
         At (<-address State 2)
         Left (- (buffer.length Row) At)
         N (io.min Left (- Limit (buffer.builder-length Out)))
      (do (if (= Left 0)
              (do (buffer.append-byte! Out 10) (address-> State 1 []))
              (do (buffer.append! Out (buffer.slice Row At N))
                  (address-> State 2 (+ At N))))
          (export-fill State Out Limit D))))

(define export-step
  State Out Limit D done ->
    (do (address-> State 3 true) (export-fill State Out Limit D))
  State Out Limit D row ->
    (let Row (json.encode (row-json (sqlite.row (<-address State 0))) [[byte-limit 4096]])
         _ (address-> State 1 Row)
         _ (address-> State 2 0)
      (export-fill State Out Limit D)))

(define found
  [] -> (counter-app.error 404 "counter not found")
  [[Value]] -> (json 200 [object ["value" Value]]))

(define counter-app.delete
  Db Name -> (if (= (counter-app.do Db [delete Name]) 0)
                 (counter-app.error 404 "counter not found")
                 (http.response 204 [] (buffer.new 0))))

(define not-allowed
  Methods -> (http.response 405 [["Allow" Methods]] (buffer.new 0)))

\\ One clause for each method on each resource. HEAD is GET, whose body the encoder leaves out.
(define serve
  Db "HEAD" Resource -> (serve Db "GET" Resource)
  _ "GET" [health] -> (json 200 [object ["status" "ok"]])
  Db "GET" [counters] -> (counter-app.list Db)
  Db "GET" [export] -> (counter-app.export (path Db))
  Db "GET" [counter Name] -> (found (counter-app.do Db [value Name]))
  Db "POST" [counter Name] -> (found (counter-app.do Db [increment Name]))
  Db "DELETE" [counter Name] -> (counter-app.delete Db Name)
  _ _ [counter _] -> (not-allowed "GET, HEAD, POST, PUT, DELETE")
  _ _ [_] -> (not-allowed "GET, HEAD")
  _ _ [] -> (counter-app.error 404 "route not found"))

(define route
  Db Method Target -> (serve Db Method (resource Target)))

\\ Only PUT on a counter has a body.
(define handle
  Db Request -> (request Db Request (resource (http.target Request))))

(define request
  Db Request [counter Name] -> (set-request Db Name Request) where (= (http.method Request) "PUT")
  _ Request _ -> (counter-app.error 400 "this route expects an empty body") where (> (http.content-length Request) 0)
  Db Request Resource -> (serve Db (http.method Request) Resource))

(define lower
  Text ->
    (let B (buffer.from-string Text)
         _ (lower-bytes (buffer.owner B) 0 (buffer.length B))
      (buffer.string B)))

(define lower-bytes
  _ At At -> true
  B At End ->
    (let Byte (shen-jit.u8 B At)
         _ (if (and (>= Byte 65) (<= Byte 90)) (shen-jit.u8! B At (+ Byte 32)) true)
      (lower-bytes B (+ At 1) End)))

(define json-type?
  [Value] -> (element? (lower Value)
                ["application/json" "application/json; charset=utf-8" "application/json;charset=utf-8"])
  _ -> false)

(define json-error
  X ->
    (let Text (error-to-string X)
         B (shen-jit.string->bytes Text)
      (if (and (>= (shen-jit.bytes-length B) 6) (= (shen-jit.bytes->string B 0 6) "json: "))
          [invalid] (simple-error Text))))

(define input-value
  [object ["value" Value]] ->
    (let N (json.integer Value) (if (and (>= N 0) (<= N 1000000000000)) (:ok N) [invalid]))
  _ -> [invalid])

(define set-request
  Db Name Request ->
    (if (json-type? (http.header-values Request "content-type"))
        (let Value (trap-error
                      (input-value (json.decode (http.body Request) [[byte-limit 4096]]))
                      (function json-error))
          (set-input Db Name Value))
        (counter-app.error 415 "expected application/json")))

(define set-input
  _ _ [invalid] -> (counter-app.error 400 "expected an object with one decimal integer value in 0..1000000000000")
  Db Name (:ok N) -> (found (counter-app.do Db [set Name N])))

\\ The owner, and a server whose handler F is called with Db and the request: [Owner Server]. Each is
\\ kept in Cell as it is made, so that a failure after it, even making the result, stops the server,
\\ which closes its listener, and ends the owning isolate. The grammars compile what is still pending
\\ first, as the program cannot change once the owning isolate runs.
(define start
  Path Host Port F Options ->
    (let _ (initialize Path)
         _ (grammar.finish)
         Cell (address-> (address-> (absvector 2) 0 []) 1 [])
      (shen-jit.on-error
        (freeze (let Owner (kept Cell 0 (open Path))
                     S (kept Cell 1 (http.listen Host Port [F (db Owner)] Options))
                  [Owner S]))
        (freeze (undo-start Cell)))))

\\ The server, never run, closes its listener before allocating anything; the owning isolate ends
\\ even if that raises.
(define undo-start
  Cell -> (shen-jit.finally
            (freeze (if (empty? (<-address Cell 1)) true (do (http.stop (<-address Cell 1)) (http.run (<-address Cell 1)))))
            (freeze (if (empty? (<-address Cell 0)) true (counter-app.close (<-address Cell 0))))))

\\ Serves until a handler stops the server, each connection in an isolate of its own, then ends the
\\ owner. The owner holds the database open meanwhile, so the log stays between requests: the last
\\ connection to close checkpoints it and removes it, which made each write many times slower.
(define await
  Owner S -> (await-result S (shen-jit.finally (freeze (http.run S)) (freeze (counter-app.close Owner)))))

(define await-result
  _ (:ok []) -> true
  _ (:err Error) -> (error "counter server: ~A" (io.error-message Error)))

(define run
  Path Port ->
    (let Started (start Path "127.0.0.1" Port control
                   [[body-limit 4096] [response-body-limit 65536]])
         _ (output "Listening on http://127.0.0.1:~A~%" (http.port (hd (tl Started))))
      (await (hd Started) (hd (tl Started)))))

(define control
  Db Request ->
    (if (= (http.target Request) "/shutdown")
        (cond ((not (= (http.method Request) "POST"))
                (http.response 405 [["Allow" "POST"]] (buffer.new 0)))
              ((> (http.content-length Request) 0)
                (counter-app.error 400 "this API expects an empty body"))
              (true (do (http.stop (http.current-server))
                        (http.close-after (json 202 [object ["stopping" true]])))))
        (handle Db Request)))

(define port-number
  Text ->
    (let B (shen-jit.string->bytes Text)
         N (shen-jit.bytes-length B)
      (if (> N 0) (port-digits B 0 N 0) (error "empty port"))))

(define port-digits
  _ At At N -> N
  B At End N ->
    (let Digit (- (shen-jit.u8 B At) 48)
      (if (and (>= Digit 0) (<= Digit 9) (<= N 6553) (or (< N 6553) (<= Digit 5)))
          (port-digits B (+ At 1) End (+ (* N 10) Digit))
          (error "port must be decimal 0..65535"))))

(define main
  [_ Path Port] -> (run Path (port-number Port))
  _ -> (error "usage: shen-jit script example-apps/sqlite-http/run.shen DATABASE PORT"))

)
