\\ SQLite, over the FFI. It stays out of the image until asked for; load it after
\\ lib/ffi.shen, under (tc -), before the code using it:
\\
\\   shen-jit eval -l lib/ffi.shen -l lib/sqlite.shen -l program.shen
\\
\\ (sqlite.with-database "people.db"
\\   (/. Db
\\     (do (sqlite.exec Db "CREATE TABLE IF NOT EXISTS people (name TEXT, age INTEGER)")
\\         (sqlite.run Db "INSERT INTO people VALUES (?, ?)" ["Ann" 30])
\\         (output "~S~%" (sqlite.query Db "SELECT name, age FROM people WHERE age > ?" [20])))))
\\
\\ sqlite.open            (sqlite.open Path), ":memory:" for a database in memory
\\ sqlite.close           raises if a prepared statement is still open
\\ sqlite.with-database   (sqlite.with-database Path F) gives F the database, closed however F ends
\\ sqlite.exec            (sqlite.exec Db Sql) runs statements with no parameters or results
\\ sqlite.run             (sqlite.run Db Sql Params) runs one, and gives the rows it changed
\\ sqlite.query           (sqlite.query Db Sql Params) gives its rows, each a list
\\ sqlite.each            (sqlite.each Db Sql Params F) calls F on each row, keeping none
\\ sqlite.transaction     (sqlite.transaction Db (freeze ...)) commits, or rolls back on an error
\\ sqlite.last-insert-id  (sqlite.last-insert-id Db)
\\ sqlite.version         the library's version, as a string
\\
\\ To use a statement many times: sqlite.prepare, sqlite.bind, sqlite.step, which gives row or
\\ done, sqlite.row, sqlite.reset and sqlite.finalize.
\\
\\ Values go in and come out as Shen values: a number is an INTEGER or a REAL, a string is TEXT,
\\ a byte buffer is a BLOB, and [] is NULL. true and false go in as 1 and 0. An integer past 62
\\ bits raises when it is read.
\\
\\ Errors raise, with SQLite's message. A database or statement that has been closed is dead, and
\\ raises when used. A connection belongs to the isolate that opened it, as a pointer cannot be
\\ sent.

(shen.x.namespace sqlite
  (use shen-jit)
  (externals [blocking bytes define-foreign done double int32 int64 pointer row skip sqlite3
    sqlite3-statement])
  (shadow bind close fail open run step value version)
  (export bind close each exec finalize last-insert-id open prepare query reset sqlite.row => row
    run step transaction version with-database)

(shen-jit.library lib ["libsqlite3.so.0" "libsqlite3.dylib" "libsqlite3-0.dll" "sqlite3.dll" "winsqlite3.dll"])

(define-foreign version lib "sqlite3_libversion" () --> string)
(define-foreign c-open lib "sqlite3_open" (string bytes) --> int32)
(define-foreign c-close lib "sqlite3_close" (pointer) --> int32)
(define-foreign c-errmsg lib "sqlite3_errmsg" (pointer) --> string)
(define-foreign c-busy-timeout lib "sqlite3_busy_timeout" (pointer int32) --> int32)
(define-foreign c-exec lib "sqlite3_exec" (pointer string pointer pointer pointer) --> int32 blocking)
(define-foreign c-prepare lib "sqlite3_prepare_v2" (pointer string int32 bytes pointer) --> int32)
(define-foreign c-finalize lib "sqlite3_finalize" (pointer) --> int32)
(define-foreign c-reset lib "sqlite3_reset" (pointer) --> int32)
(define-foreign c-clear-bindings lib "sqlite3_clear_bindings" (pointer) --> int32)
(define-foreign c-step lib "sqlite3_step" (pointer) --> int32 blocking)
(define-foreign c-db-handle lib "sqlite3_db_handle" (pointer) --> pointer)
(define-foreign c-parameter-count lib "sqlite3_bind_parameter_count" (pointer) --> int32)
(define-foreign c-bind-int64 lib "sqlite3_bind_int64" (pointer int32 int64) --> int32)
(define-foreign c-bind-double lib "sqlite3_bind_double" (pointer int32 double) --> int32)
(define-foreign c-bind-null lib "sqlite3_bind_null" (pointer int32) --> int32)
\\ The last argument of these two is SQLITE_TRANSIENT, the pointer value -1: SQLite takes a copy.
(define-foreign c-bind-text lib "sqlite3_bind_text" (pointer int32 bytes int32 int64) --> int32)
(define-foreign c-bind-blob lib "sqlite3_bind_blob" (pointer int32 bytes int32 int64) --> int32)
(define-foreign c-column-count lib "sqlite3_column_count" (pointer) --> int32)
(define-foreign c-column-type lib "sqlite3_column_type" (pointer int32) --> int32)
(define-foreign c-column-int64 lib "sqlite3_column_int64" (pointer int32) --> int64)
(define-foreign c-column-double lib "sqlite3_column_double" (pointer int32) --> double)
(define-foreign c-column-text lib "sqlite3_column_text" (pointer int32) --> pointer)
(define-foreign c-column-blob lib "sqlite3_column_blob" (pointer int32) --> pointer)
(define-foreign c-column-bytes lib "sqlite3_column_bytes" (pointer int32) --> int32)
(define-foreign c-changes lib "sqlite3_changes" (pointer) --> int32)
(define-foreign c-last-insert-rowid lib "sqlite3_last_insert_rowid" (pointer) --> int64)
(define-foreign c-autocommit lib "sqlite3_get_autocommit" (pointer) --> int32)

(define fail
  Db -> (error "sqlite: ~A" (c-errmsg Db)))

(define statement-fail
  Stmt -> (fail (c-db-handle Stmt)))

\\ Opening can fail and still give a handle, which holds the message and must be closed.
(define open
  Path -> (let Out (shen-jit.bytes 8)
               Rc (c-open Path Out)
               Db (shen-jit.bytes->pointer Out 0 sqlite3)
            (if (= Rc 0)
                (do (c-busy-timeout Db 5000) Db)
                (let Message (if (= Db []) "out of memory" (c-errmsg Db))
                  (do (c-close Db)
                      (error "sqlite: cannot open ~A: ~A" Path Message))))))

(define close
  Db -> (if (= (c-close Db) 0)
            (do (shen-jit.pointer-kill Db) true)
            (fail Db)))

(define with-database
  Path F -> (let Db (open Path) (shen-jit.finally (freeze (F Db)) (freeze (close Db)))))

(define exec
  Db Sql -> (if (= (c-exec Db Sql [] [] []) 0) true (fail Db)))

(define last-insert-id
  Db -> (c-last-insert-rowid Db))

\\ Statements.

\\ SQL with nothing to run, only a comment for instance, gives no statement.
(define prepare
  Db Sql -> (let Out (shen-jit.bytes 8)
                 Rc (c-prepare Db Sql -1 Out [])
                 Stmt (shen-jit.bytes->pointer Out 0 sqlite3-statement)
              (cases (not (= Rc 0)) (fail Db)
                     (= Stmt []) (error "sqlite: no statement in ~S" Sql)
                     true Stmt)))

(define finalize
  Stmt -> (do (c-finalize Stmt) (shen-jit.pointer-kill Stmt) true))

(define reset
  Stmt -> (do (c-reset Stmt) (c-clear-bindings Stmt) true))

(define bind
  Stmt Params -> (let Wanted (c-parameter-count Stmt)
                   (if (= Wanted (length Params))
                       (bind-from Stmt 1 Params)
                       (error "sqlite: expected ~A parameters, got ~A" Wanted (length Params)))))

(define bind-from
  _ _ [] -> true
  Stmt I [V | Vs] -> (if (= (bind-one Stmt I V) 0)
                         (bind-from Stmt (+ I 1) Vs)
                         (statement-fail Stmt)))

(define bind-one
  Stmt I [] -> (c-bind-null Stmt I)
  Stmt I true -> (c-bind-int64 Stmt I 1)
  Stmt I false -> (c-bind-int64 Stmt I 0)
  Stmt I V -> (let B (shen-jit.string->bytes V) (c-bind-text Stmt I B (shen-jit.bytes-length B) -1))
    where (string? V)
  Stmt I V -> (c-bind-blob Stmt I V (shen-jit.bytes-length V) -1) where (shen-jit.bytes? V)
  Stmt I V -> (c-bind-int64 Stmt I V) where (shen-jit.fixnum? V)
  Stmt I V -> (c-bind-double Stmt I V) where (number? V)
  _ _ V -> (error "sqlite: cannot store ~S" V))

(define step
  Stmt -> (let Rc (c-step Stmt)
            (cases (= Rc 100) row
                   (= Rc 101) done
                   true (statement-fail Stmt))))

(define sqlite.row
  Stmt -> (columns Stmt (- (c-column-count Stmt) 1) []))

(define columns
  _ -1 Row -> Row
  Stmt I Row -> (columns Stmt (- I 1) [(value Stmt I (c-column-type Stmt I)) | Row]))

\\ By SQLite's codes for INTEGER, FLOAT, TEXT and BLOB; 5 is NULL. Text has its length, as it
\\ can hold NUL bytes.
(define value
  Stmt I 1 -> (c-column-int64 Stmt I)
  Stmt I 2 -> (c-column-double Stmt I)
  Stmt I 3 -> (let B (column-bytes Stmt I (c-column-text Stmt I))
                (shen-jit.bytes->string B 0 (shen-jit.bytes-length B)))
  Stmt I 4 -> (column-bytes Stmt I (c-column-blob Stmt I))
  _ _ _ -> [])

\\ The pointer first, then the length, as SQLite asks. An empty blob's pointer is NULL.
(define column-bytes
  Stmt I P -> (let N (c-column-bytes Stmt I)
                (if (= P []) (shen-jit.bytes 0) (shen-jit.pointer->bytes P 0 N))))

\\ One statement, finalized however F ends.
(define with-statement
  Db Sql Params F
  -> (let Stmt (prepare Db Sql)
       (shen-jit.finally (freeze (do (bind Stmt Params) (F Stmt))) (freeze (finalize Stmt)))))

(define query
  Db Sql Params -> (with-statement Db Sql Params (/. Stmt (rows Stmt []))))

(define rows
  Stmt Rows -> (if (= (step Stmt) row)
                   (rows Stmt [(sqlite.row Stmt) | Rows])
                   (reverse Rows)))

(define each
  Db Sql Params F -> (with-statement Db Sql Params (/. Stmt (each-row Stmt F))))

(define each-row
  Stmt F -> (if (= (step Stmt) row)
                (do (F (sqlite.row Stmt)) (each-row Stmt F))
                true))

(define run
  Db Sql Params -> (with-statement Db Sql Params
                     (/. Stmt (do (each-row Stmt (/. Row skip)) (c-changes Db)))))

\\ A COMMIT that fails, as one a deferred constraint stops does, leaves the transaction open, and
\\ some errors end it in SQLite already, as INSERT OR ROLLBACK does: only an open one is rolled back.
(define transaction
  Db F -> (do (exec Db "BEGIN")
              (shen-jit.on-error (freeze (let Result (thaw F) _ (exec Db "COMMIT") Result))
                                 (freeze (if (= (c-autocommit Db) 0) (exec Db "ROLLBACK") skip)))))

)
