\\ Path operations and scoped file transfers over the decoded native results.
(shen.x.namespace fs
  (use buffer)
  (use io)
  (use option)
  (use result)
  (use shen-jit)
  (import result let-ok ok err)
  (externals [copy crt directory file foreign limit mkdir posix read
    temp-directory temp-file win32 write])
  (shadow copy-file)
  (export copy-file exists? fs.lstat => lstat fs.mkdir => mkdir mkdirs
    fs.rename => rename fs.replace => replace fs.stat => stat
    fs.temp-directory => temp-directory fs.temp-file => temp-file
    remove-directory remove-file with-replacement with-temp-file write-new write-replace)

(define fs.stat
  {string --> (io.result info)}
  Path -> (let-ok Resolved (fs.resolve Path) (stat-path Resolved true)))

(define fs.lstat
  {string --> (io.result info)}
  Path -> (let-ok Resolved (fs.resolve Path) (stat-path Resolved false)))

(define absent?
  {io.error --> boolean}
  Error ->
    (or (and (element? (io.error-domain Error) [posix crt]) (element? (io.error-code Error) [2 20]))
        (and (= (io.error-domain Error) win32) (element? (io.error-code Error) [2 3]))))

(define exists-result
  {(io.result info) --> (io.result boolean)}
  (:ok _) -> (ok true)
  (:err Error) -> (if (absent? Error) (ok false) (:err Error)))

(define exists?
  {string --> (io.result boolean)}
  Path -> (exists-result (fs.stat Path)))

(define remove-file
  {string --> (io.result result.empty)}
  Path -> (let-ok P (fs.resolve Path) (remove-file-path P)))

(define fs.rename
  {string --> string --> (io.result result.empty)}
  From To ->
    (let-ok Paths (resolve-pair From To)
      (rename-path (fst Paths) (snd Paths) false)))

(define fs.replace
  {string --> string --> (io.result result.empty)}
  From To ->
    (let-ok Paths (resolve-pair From To)
      (rename-path (fst Paths) (snd Paths) true)))

(define prefix-byte?
  {fixnum --> boolean}
  B -> (or (and (fx>= B 48) (fx<= B 57)) (and (fx>= B 65) (fx<= B 90))
           (and (fx>= B 97) (fx<= B 122)) (element? B [45 46 95])))

(define prefix-range?
  {buffer.storage --> fixnum --> fixnum --> boolean}
  _ At At -> true
  B At End -> (and (prefix-byte? (shen-jit.u8 B At)) (prefix-range? B (fx+ At 1) End)))

(define prefix
  {string --> string}
  Prefix ->
    (let _ (checked Prefix)
         B (shen-jit.string->bytes Prefix)
         N (shen-jit.bytes-length B)
      (if (and (fx<= N 64) (prefix-range? B 0 N))
          Prefix
          (error "fs: temporary prefix must be 1..64 ASCII letters, digits or ._-"))))

(define fs.temp-file
  {string --> string --> (io.result (string * io.endpoint))}
  Parent Prefix ->
    (do (prefix Prefix)
        (let-ok Root (fs.resolve Parent)
          (trap-error (temp-file-try Root Prefix 64 384)
            (/. X (err (io.native-error temp-file foreign 0 Root (error-to-string X))))))))

(define with-temp-open
  {(string --> io.endpoint --> (io.result A)) --> (io.result (string * io.endpoint)) -->
   (io.result A)}
  _ (:err Error) -> (err Error)
  F (:ok (@p Path E)) ->
    (let Result (io.with-endpoint E (/. Out (F Path Out)))
      (io.finish Result (cleanup-temp Path))))

(define with-temp-file
  {string --> string --> (string --> io.endpoint --> (io.result A)) --> (io.result A)}
  Parent Prefix F -> (with-temp-open F (fs.temp-file Parent Prefix)))

(define cleanup-temp
  {string --> (io.result result.empty)}
  Path -> (cleaned (remove-file-path Path)))

(define cleaned
  {(io.result result.empty) --> (io.result result.empty)}
  (:err Error) -> (if (absent? Error) (ok []) (err Error))
  Result -> Result)

(define replace-open
  {string --> boolean --> (io.endpoint --> (io.result A)) --> (io.result (string * io.endpoint)) -->
   (io.result A)}
  _ _ _ (:err Error) -> (err Error)
  Path Replace F (:ok (@p Temporary E)) ->
    (let Result (io.with-endpoint E F)
         Moved (if (result.ok? Result)
                   (io.finish Result (rename-path Temporary Path Replace))
                   Result)
      (if (result.ok? Moved)
          Moved
          (io.finish Moved (cleanup-temp Temporary)))))

(define with-replacement
  {string --> (io.endpoint --> (io.result A)) --> (io.result A)}
  Path F ->
    (let-ok Resolved (fs.resolve Path)
      (replace-open Resolved true F (temp-file-try (parent Resolved) ".shen-" 64 384))))

(define new-byte-count
  {--> (vector fixnum)}
  -> (fxvector-> (vector 1) 1 0))

\\ Keep the byte count across short writes and failures during scoped cleanup.
(define write-chunk
  {(vector fixnum) --> io.endpoint --> buffer.view --> fixnum --> fixnum --> (io.result fixnum)}
  _ _ _ End End -> (ok End)
  State E View At End ->
    (let Result (trap-error (io.write-some E (buffer.slice View At (fx- End At)) [])
                   (/. X (err (io.error write (io.endpoint.name E) (error-to-string X)))))
      (write-step State E View At End Result)))

(define write-step
  {(vector fixnum) --> io.endpoint --> buffer.view --> fixnum --> fixnum -->
   (io.result fixnum) --> (io.result fixnum)}
  State E View At End (:ok N) ->
    (do (fxvector-> State 1 (fx+ (fx<-vector State 1) N))
        (write-chunk State E View (fx+ At N) End))
  State _ _ _ _ (:err Error) -> (err (io.progress Error (fx<-vector State 1))))

(define counted
  {(vector fixnum) --> (io.result A) --> (io.result A)}
  _ (:ok Value) -> (ok Value)
  State (:err Error) -> (err (io.progress Error (fx<-vector State 1))))

(define write-replace
  {string --> buffer.view --> (io.result fixnum)}
  Path View ->
    (let _ (buffer.check View)
         State (new-byte-count)
         Result (with-replacement Path
                  (/. E (write-chunk State E View 0 (buffer.length View))))
      (counted State Result)))

\\ A new file appears whole or not at all, and an existing name is an error, as for a lock.
(define write-new
  {string --> buffer.view --> fixnum --> (io.result fixnum)}
  Path View Mode ->
    (let _ (buffer.check View)
         Bits (if (fx<= (buffer.index Mode) 4095) Mode (error "fs: mode must be at most 4095"))
         State (new-byte-count)
         Result (let-ok Resolved (fs.resolve Path)
                  (replace-open Resolved false
                    (/. E (write-chunk State E View 0 (buffer.length View)))
                    (temp-file-try (parent Resolved) ".shen-" 64 (fx->number Bits))))
      (counted State Result)))

(define copy-read
  {io.endpoint --> io.endpoint --> buffer.view --> (vector fixnum) --> fixnum --> (io.result fixnum)}
  Input Output Chunk State Limit ->
    (let Read (trap-error (io.read-some Input Chunk [])
                 (/. X (err (io.error read (io.endpoint.name Input) (error-to-string X)))))
      (copy-step Input Output Chunk State Limit Read)))

(define copy-step
  {io.endpoint --> io.endpoint --> buffer.view --> (vector fixnum) --> fixnum -->
   (io.result (option.t fixnum)) --> (io.result fixnum)}
  _ _ _ State _ (:ok []) -> (ok (fx<-vector State 1))
  _ _ _ State _ (:err Error) -> (err (io.progress Error (fx<-vector State 1)))
  Input Output Chunk State Limit (:ok [N]) ->
    (let At (fx<-vector State 1)
      (if (fx> N (fx- Limit At))
          (err (io.progress
                 (io.native-error copy limit 0 "file copy" "copy byte limit exceeded") At))
          (let-ok _ (write-chunk State Output Chunk 0 N)
            (copy-read Input Output Chunk State Limit)))))

(define copy-file
  {string --> string --> fixnum --> (io.result fixnum)}
  From To Limit ->
    (let Maximum (buffer.index Limit)
         State (new-byte-count)
         Result (let-ok Paths (resolve-pair From To)
                  (copy-paths Paths State Maximum))
      (counted State Result)))

(define copy-paths
  {(string * string) --> (vector fixnum) --> fixnum --> (io.result fixnum)}
  (@p Source Target) State Limit ->
    (let-ok Info (stat-path Source true)
      (if (not (= (kind Info) file))
          (err (io.error copy Source "copy source must be a regular file"))
          (let-ok Input (io.open-file Source read)
            (io.with-endpoint Input
              (/. In
                (let Chunk (buffer.new 65536)
                  (with-replacement Target
                    (/. Out (copy-read In Out Chunk State Limit))))))))))

(define fs.mkdir
  {string --> (io.result result.empty)}
  Path -> (let-ok P (fs.resolve Path) (mkdir-path P 511)))

(define remove-directory
  {string --> (io.result result.empty)}
  Path -> (let-ok P (fs.resolve Path) (remove-directory-path P)))

(define mkdir-existing
  {string --> (io.result result.empty) --> (io.result result.empty)}
  _ (:ok []) -> (:ok [])
  Path (:err Error) ->
    (if (= (io.error-code Error) 17)
        (let-ok Info (stat-path Path true)
          (if (= (kind Info) directory) (:ok []) (:err Error)))
        (:err Error)))

(define mkdirs-path
  {string --> (io.result result.empty)}
  Path -> (mkdirs-depth Path 256))

(define mkdirs-depth
  {string --> fixnum --> (io.result result.empty)}
  Path 0 -> (:err (io.native-error mkdir limit 0 Path "parent depth exceeds 256"))
  Path Remaining ->
    (let Parent (parent Path)
      (if (= Parent Path)
          (let-ok Info (stat-path Path true)
            (if (= (kind Info) directory)
                (:ok [])
                (:err (io.error mkdir Path "root is not a directory"))))
          (let-ok _ (mkdirs-parent Parent (fx- Remaining 1))
            (mkdir-existing Path (mkdir-path Path 511))))))

(define mkdirs-parent
  {string --> fixnum --> (io.result result.empty)}
  "." _ -> (ok [])
  Path Remaining -> (mkdirs-depth Path Remaining))

(define mkdirs
  {string --> (io.result result.empty)}
  Path -> (let-ok P (fs.resolve Path) (mkdirs-path P)))

(define temp-directory-try
  {string --> string --> fixnum --> (io.result string)}
  Parent _ 0 ->
    (:err (io.native-error temp-directory limit 0 Parent "temporary name collision limit exceeded"))
  Parent Prefix Attempts ->
    (let-ok Name (random-name Prefix)
      (let Path (join Parent Name)
        (temp-directory-made Parent Prefix Attempts Path (mkdir-path Path 448)))))

(define temp-directory-made
  {string --> string --> fixnum --> string --> (io.result result.empty) --> (io.result string)}
  _ _ _ Path (:ok []) -> (:ok Path)
  Parent Prefix Attempts _ (:err Error)
  -> (if (= (io.error-code Error) 17)
         (temp-directory-try Parent Prefix (fx- Attempts 1))
         (:err Error)))

(define fs.temp-directory
  {string --> string --> (io.result string)}
  Parent Prefix ->
    (do (prefix Prefix)
        (let-ok Root (fs.resolve Parent)
          (temp-directory-try Root Prefix 64))))

)
