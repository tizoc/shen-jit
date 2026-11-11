\\ SQLite (lib/sqlite.shen). Run by make test-ffi, after loading lib/ffi.shen and that file. It
\\ needs SQLite's library, which most systems have; where it is missing, it says so and stops.

(set sqlite-test.*passed* 0)
(set sqlite-test.*failed* 0)

(define sqlite-test.result
  F -> (trap-error (thaw F) (/. E [error (error-to-string E)])))

(define sqlite-test.check
  Name Expected F -> (sqlite-test.compare Name Expected (sqlite-test.result F)))

(define sqlite-test.compare
  _ X X -> (set sqlite-test.*passed* (+ 1 (value sqlite-test.*passed*)))
  Name Expected Got -> (do (output "FAIL ~A: expected ~S, got ~S~%" Name Expected Got)
                           (set sqlite-test.*failed* (+ 1 (value sqlite-test.*failed*)))))

(define sqlite-test.prefix
  0 _ -> ""
  N S -> (cn (pos S 0) (sqlite-test.prefix (- N 1) (tlstr S))))

(define sqlite-test.message-starts
  Name Text F -> (sqlite-test.check Name Text
                   (freeze (sqlite-test.prefix (string-length Text) (hd (tl (sqlite-test.result F)))))))

(define string-length
  "" -> 0
  S -> (+ 1 (string-length (tlstr S))))

(set sqlite-test.version (sqlite-test.result (freeze (sqlite.version))))
(if (= (sqlite-test.result (freeze (sqlite.version))) [error "foreign: this static build cannot load libraries"])
    (do (output "1 passed, 0 failed (a static build)~%") (shen-jit.exit 0))
    skip)
(if (cons? (value sqlite-test.version))
    (do (output "1 passed, 0 failed (no SQLite here: ~A)~%" (hd (tl (value sqlite-test.version))))
        (shen-jit.exit 0))
    skip)

(sqlite-test.check "a version" true (freeze (> (string-length (sqlite.version)) 0)))

\\ ---------------------------------------------------------------------------
\\ Each kind of value, in and out.

(set db (sqlite.open ":memory:"))
(define db -> (value db))

(sqlite-test.check "a table" true
  (freeze (sqlite.exec (db) "CREATE TABLE t (a, b); CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")))

(define sqlite-test.round-trip
  V -> (do (sqlite.exec (db) "DELETE FROM t")
           (sqlite.run (db) "INSERT INTO t VALUES (?, 0)" [V])
           (hd (hd (sqlite.query (db) "SELECT a FROM t" [])))))

(sqlite-test.check "an integer" 42 (freeze (sqlite-test.round-trip 42)))
(sqlite-test.check "a negative one" -42 (freeze (sqlite-test.round-trip -42)))
(sqlite-test.check "a large one" 2305843009213693951 (freeze (sqlite-test.round-trip 2305843009213693951)))
(sqlite-test.check "a real" 1.5 (freeze (sqlite-test.round-trip 1.5)))
(sqlite-test.check "a real with no fraction" 7 (freeze (sqlite-test.round-trip (* 3.5 2))))
(sqlite-test.check "binding preserves integer and real storage classes"
  [["integer" "real" "real"]]
  (freeze (sqlite.query (db) "SELECT typeof(?), typeof(?), typeof(?)" [7 (+ 0.5 0.5) 1.5])))
(sqlite-test.check "a string" "hello" (freeze (sqlite-test.round-trip "hello")))
(sqlite-test.check "an empty string" "" (freeze (sqlite-test.round-trip "")))
(sqlite-test.check "NULL" [] (freeze (sqlite-test.round-trip [])))
(sqlite-test.check "true" 1 (freeze (sqlite-test.round-trip true)))
(sqlite-test.check "false" 0 (freeze (sqlite-test.round-trip false)))
(sqlite-test.check "a blob" [3 1 255]
  (freeze (let B (shen-jit.bytes 3)
               Out (sqlite-test.round-trip (shen-jit.u8! (shen-jit.u8! (shen-jit.u8! B 0 1) 1 255) 2 7))
            [(shen-jit.bytes-length Out) (shen-jit.u8 Out 0) (shen-jit.u8 Out 1)])))
(sqlite-test.check "a blob with a NUL" 0
  (freeze (shen-jit.u8 (sqlite-test.round-trip (shen-jit.string->bytes (cn "a" (cn (n->string 0) "b")))) 1)))
(sqlite-test.check "an empty blob" 0 (freeze (shen-jit.bytes-length (sqlite-test.round-trip (shen-jit.bytes 0)))))
(sqlite-test.message-starts "not storable" "sqlite: cannot store" (freeze (sqlite-test.round-trip (cons 1 2))))
(sqlite-test.message-starts "an integer past 62 bits" "foreign: the result"
  (freeze (sqlite.query (db) "SELECT 9223372036854775807" [])))

\\ ---------------------------------------------------------------------------
\\ Rows.

(sqlite-test.check "an insert" 1 (freeze (sqlite.run (db) "INSERT INTO people (name, age) VALUES (?, ?)" ["Ann" 30])))
(sqlite-test.check "its id" 1 (freeze (sqlite.last-insert-id (db))))
(sqlite-test.check "another" 1 (freeze (sqlite.run (db) "INSERT INTO people (name, age) VALUES (?, ?)" ["Bob" 25])))
(sqlite-test.check "and its id" 2 (freeze (sqlite.last-insert-id (db))))
(sqlite-test.check "a query, in order" [["Ann" 30] ["Bob" 25]]
  (freeze (sqlite.query (db) "SELECT name, age FROM people ORDER BY id" [])))
(sqlite-test.check "with a parameter" [["Bob"]]
  (freeze (sqlite.query (db) "SELECT name FROM people WHERE age < ?" [30])))
(sqlite-test.check "with no rows" [] (freeze (sqlite.query (db) "SELECT name FROM people WHERE age < ?" [0])))
(sqlite-test.check "an update's count" 2 (freeze (sqlite.run (db) "UPDATE people SET age = age + 1" [])))

(set seen [])
(sqlite-test.check "each row" true
  (freeze (sqlite.each (db) "SELECT name FROM people ORDER BY id" [] (/. Row (set seen [(hd Row) | (value seen)])))))
(sqlite-test.check "seen in order" ["Bob" "Ann"] (freeze (value seen)))

\\ A statement used twice, with parameters that may move between binding and stepping.
(define sqlite-test.names
  _ [] -> []
  Stmt [Age | Ages] -> (do (sqlite.reset Stmt)
                           (sqlite.bind Stmt [Age])
                           (let Churn (make-string "~A" (vector 100))
                             (sqlite.step Stmt))
                           (let Row (sqlite.row Stmt)
                             [(hd Row) | (sqlite-test.names Stmt Ages)])))
(sqlite-test.check "a statement used twice" ["Ann" "Bob"]
  (freeze (let Stmt (sqlite.prepare (db) "SELECT name FROM people WHERE age = ?")
               Names (sqlite-test.names Stmt [31 26])
            (do (sqlite.finalize Stmt) Names))))

\\ ---------------------------------------------------------------------------
\\ Transactions.

(sqlite-test.check "committed" 7
  (freeze (sqlite.transaction (db) (freeze (do (sqlite.run (db) "UPDATE people SET age = 7 WHERE name = ?" ["Ann"]) 7)))))
(sqlite-test.check "and kept" [[7]] (freeze (sqlite.query (db) "SELECT age FROM people WHERE name = ?" ["Ann"])))
(sqlite-test.check "rolled back, raising what went wrong" [error "no"]
  (freeze (sqlite.transaction (db) (freeze (do (sqlite.run (db) "UPDATE people SET age = 8 WHERE name = ?" ["Ann"])
                                               (simple-error "no"))))))
(sqlite-test.check "and undone" [[7]] (freeze (sqlite.query (db) "SELECT age FROM people WHERE name = ?" ["Ann"])))

\\ ---------------------------------------------------------------------------
\\ What goes wrong.

(sqlite-test.message-starts "bad SQL" "sqlite: near" (freeze (sqlite.query (db) "SELEC 1" [])))
(sqlite-test.message-starts "and in exec" "sqlite: near" (freeze (sqlite.exec (db) "SELEC 1")))
(sqlite-test.message-starts "no table" "sqlite: no such table" (freeze (sqlite.query (db) "SELECT * FROM missing" [])))
(sqlite-test.check "no statement" [error "sqlite: no statement in c#34;-- onlyc#34;"] (freeze (sqlite.query (db) "-- only" [])))
(sqlite-test.check "too few parameters" [error "sqlite: expected 2 parameters, got 1"]
  (freeze (sqlite.query (db) "SELECT ?, ?" [1])))
(sqlite-test.check "too many" [error "sqlite: expected 0 parameters, got 1"]
  (freeze (sqlite.query (db) "SELECT 1" [1])))
(sqlite-test.message-starts "a failed step" "sqlite: UNIQUE constraint"
  (freeze (sqlite.run (db) "INSERT INTO people (id, name) VALUES (1, ?)" ["Dup"])))
(sqlite-test.message-starts "an error in F" "boom"
  (freeze (sqlite.each (db) "SELECT 1" [] (/. Row (simple-error "boom")))))
(sqlite-test.message-starts "cannot open" "sqlite: cannot open /no/such/directory/x.db:"
  (freeze (sqlite.open "/no/such/directory/x.db")))
(sqlite-test.message-starts "a NUL in SQL" "foreign:" (freeze (sqlite.query (db) (cn "SELECT 1" (n->string 0)) [])))

\\ A statement left open stops close, and every error above has finalized its own.
(set open-statement (sqlite.prepare (db) "SELECT 1"))
(sqlite-test.message-starts "close with a statement open" "sqlite: unable to close" (freeze (sqlite.close (db))))
(sqlite-test.check "finalized" true (freeze (sqlite.finalize (value open-statement))))
(sqlite-test.message-starts "a finalized statement is dead" "foreign:" (freeze (sqlite.step (value open-statement))))
(sqlite-test.check "close" true (freeze (sqlite.close (db))))
(sqlite-test.message-starts "a closed database is dead" "foreign:" (freeze (sqlite.exec (db) "SELECT 1")))
(sqlite-test.message-starts "closed twice" "foreign:" (freeze (sqlite.close (db))))

\\ ---------------------------------------------------------------------------
\\ A file, from two threads with a connection each, which wait for each other inside C while
\\ the lock is free: the threads run in turns only if sqlite.step gives it up.

(set path "sqlite-test.db")
(set file (sqlite.open (value path)))
(sqlite.exec (value file) "CREATE TABLE IF NOT EXISTS n (x); DELETE FROM n")
(sqlite.close (value file))

(define sqlite-test.insert
  _ 0 -> true
  Db N -> (do (sqlite.run Db "INSERT INTO n VALUES (?)" [N]) (sqlite-test.insert Db (- N 1))))

(define sqlite-test.writer
  Name -> (let Db (sqlite.open (value path))
            (do (sqlite.exec Db "PRAGMA synchronous = OFF")
                (sqlite-test.insert Db 20)
                (sqlite.close Db)
                (set Name done))))

(define sqlite-test.wait
  Name -> (if (= (value Name) waiting) (sqlite-test.wait Name) done))

(set first waiting)
(set second waiting)
(thread (freeze (sqlite-test.writer first)))
(thread (freeze (sqlite-test.writer second)))
(sqlite-test.wait first)
(sqlite-test.wait second)
(sqlite-test.check "two writers" [[40]]
  (freeze (let Db (sqlite.open (value path))
               Rows (sqlite.query Db "SELECT count(*) FROM n" [])
            (do (sqlite.close Db) Rows))))

(sqlite-test.check "failed COMMIT rolls back" [[0]]
  (freeze
    (let D (sqlite.open ":memory:")
         _ (sqlite.exec D
             "PRAGMA foreign_keys=ON;
              CREATE TABLE p(x PRIMARY KEY);
              CREATE TABLE c(
                x REFERENCES p(x) DEFERRABLE INITIALLY DEFERRED)")
         _ (sqlite-test.result
             (freeze
               (sqlite.transaction D
                 (freeze
                   (sqlite.run D "INSERT INTO c VALUES(1)" [])))))
         Rows (sqlite.query D "SELECT count(*) FROM c" [])
         _ (sqlite-test.result (freeze (sqlite.exec D "ROLLBACK")))
         _ (sqlite.close D)
      Rows)))

(sqlite-test.check "TEXT preserves embedded NUL" [["ac#0;b"]]
  (freeze
    (let D (sqlite.open ":memory:")
         Rows (sqlite.query D "SELECT CAST(X'610062' AS TEXT)" [])
         _ (sqlite.close D)
      Rows)))

(sqlite-test.message-starts
  "automatic rollback preserves constraint error"
  "sqlite: UNIQUE constraint failed: audit_u.x"
  (freeze
    (let D (sqlite.open ":memory:")
         _ (sqlite.exec D
             "CREATE TABLE audit_u(x UNIQUE);
              INSERT INTO audit_u VALUES(1)")
         R (sqlite-test.result
             (freeze
               (sqlite.transaction D
                 (freeze
                   (sqlite.run D
                     "INSERT OR ROLLBACK INTO audit_u VALUES(1)" [])))))
         _ (sqlite.close D)
      (simple-error (hd (tl R))))))

(sqlite-test.check "TEXT with NUL round-trips" [["ac#0;b"]]
  (freeze (sqlite.with-database ":memory:" (/. D (sqlite.query D "SELECT ?" ["ac#0;b"])))))

(sqlite-test.check "with-database gives F's value" [[1]]
  (freeze (sqlite.with-database ":memory:" (/. D (sqlite.query D "SELECT 1" [])))))

(set sqlite-test.kept [])
(sqlite-test.check "with-database closes and keeps F's error" [[error "inside"] true]
  (freeze
    [(sqlite-test.result
       (freeze (sqlite.with-database ":memory:" (/. D (do (set sqlite-test.kept D) (error "inside"))))))
     (trap-error (do (sqlite.exec (value sqlite-test.kept) "SELECT 1") false) (/. E true))]))

(output "~A passed, ~A failed~%" (value sqlite-test.*passed*) (value sqlite-test.*failed*))
