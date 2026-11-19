\\ Filesystem operations over our own I/O. Module fs.
\\ Native directory handles never escape a listing; file contents remain io.endpoint operations.

(shen.x.namespace fs
  (use buffer)
  (use io)
  (use result)
  (import result let-ok ok err)
  (use shen-jit)
  (import struct defstruct)
  (externals [blocking bool bytes continue copy crt define-foreign define-foreign-procedure
    depth-limit directory done entry-limit int32 int64 library lstat mkdir
    name-byte-limit other posix random read-write rename replace resolve rmdir shen skip stat
    stop symlink temp-directory temp-file uint32 unlink void walk win32 write])
  (shadow copy-file)
  (export *adapter-files* accessed copy-file exists? extension info join kind fs.list => list
    fs.lstat => lstat fs.mkdir => mkdir mkdirs modified name option parent path remove-directory
    remove-file fs.rename => rename fs.replace => replace fs.resolve => resolve resolve-at size
    fs.stat => stat fs.temp-directory => temp-directory fs.temp-file => temp-file visit
    fs.walk => walk with-replacement with-temp-file write-replace)

(shen-jit.library adapter
  (trap-error (value *adapter-files*)
    (/. X ["./build/shen-fs.so" "./lib/shen-fs.so" "./shen-fs.so"
           "./build/shen-fs.dll" "./lib/shen-fs.dll" "./shen-fs.dll"])))
(define-foreign c-abi adapter "shen_fs_abi" () --> int32)
(define-foreign-procedure c-stat adapter "shen_fs_stat" 2)
(define-foreign-procedure c-list adapter "shen_fs_list" 3)
(define-foreign-procedure c-rename adapter "shen_fs_rename" 3)
(define-foreign-procedure c-resolve adapter "shen_fs_resolve" 1)

(define-foreign c-mkdir io.file-lib "mkdir" (string int32) --> int32 blocking)
(define-foreign c-wmkdir io.file-lib "_wmkdir" (bytes) --> int32 blocking)
(define-foreign c-unlink io.file-lib (if (io.file-windows?) "_wunlink" "unlink")
  ((if (io.file-windows?) bytes string)) --> int32 blocking)
(define-foreign c-rmdir io.file-lib (if (io.file-windows?) "_wrmdir" "rmdir")
  ((if (io.file-windows?) bytes string)) --> int32 blocking)
(define-foreign c-random-linux io.file-lib "getrandom" (bytes int64 uint32) --> int64 blocking)
(define-foreign c-random-mac io.file-lib "arc4random_buf" (bytes int64) --> void blocking)
(shen-jit.library random-win ["advapi32.dll"])
(define-foreign c-random-win random-win "SystemFunction036" (bytes uint32) --> bool blocking)

\\ Resolution shares the file module's home snapshot.
(define fs.resolve
  Path -> (resolve-home Path (value *home-directory*)))

(define resolve-home
  Path Home ->
    (let Prepared (checked (io.file-path-at (checked Path) Home))
         B (shen-jit.string->bytes Prepared)
      (if (and (not (io.file-windows?)) (io.file-absolute? B (shen-jit.bytes-length B)))
          (:ok Prepared)
          (native resolve Prepared (freeze (c-resolve Prepared))))))

(define resolve-pair
  From To ->
    (let Home (value *home-directory*)
      (let-ok A (resolve-home From Home)
                 B (resolve-home To Home)
        (:ok (@p A B)))))

\\ A path's bytes, where its root ends, where it ends without trailing separators, and its last
\\ separator before that, or -1.
(defstruct split
  (bytes : buffer.storage)
  (root : fixnum)
  (end : fixnum)
  (slash : fixnum))

(preclude [split.%match])

(define domain
  1 -> posix
  2 -> win32
  4 -> limit
  _ -> library)

(define reply
  _ _ Native -> (:ok (<-address Native 3)) where (= (<-address Native 0) 0)
  Op Resource Native ->
    (:err (io.native-error Op (domain (<-address Native 0))
                           (<-address Native 1) Resource (<-address Native 2))))

(define native
  Op Resource F ->
    (trap-error
      (do (if (= (c-abi) 1) true (error "fs: incompatible adapter ABI; rebuild with make fs"))
          (reply Op Resource (thaw F)))
      (/. X (:err (io.native-error Op foreign 0 Resource (error-to-string X))))))

(define kind-number
  0 -> file
  1 -> directory
  2 -> symlink
  _ -> other)

\\ Metadata: modified and accessed are (@p Seconds Nanoseconds).
(defstruct info
  (path : string)
  (kind : symbol)
  (size : fixnum)
  (modified : (number * number))
  (accessed : (number * number)))

(preclude [info.%match])

(define stat-path
  Path Follow ->
    (let-ok Raw (native (if Follow stat lstat) Path (freeze (c-stat Path Follow)))
      (:ok (:info
            path <- Path
            kind <- (kind-number (<-address Raw 0))
            size <- (<-address Raw 1)
            modified <- (@p (<-address Raw 2) (<-address Raw 3))
            accessed <- (@p (<-address Raw 4) (<-address Raw 5))))))

(define fs.limit
  Value Maximum ->
    (let N (buffer.index Value)
      (if (<= N Maximum) N (error "fs: option exceeds its maximum"))))

\\ The limits of a listing or a walk; a listing has no depth.
(defstruct limits
  (mutable entries)
  (mutable name-bytes)
  (mutable depth))

(define configure
  Config [] _ _ -> Config
  Config [[Name Value] | Rest] Seen Walk ->
    (let _ (if (element? Name Seen) (error "fs: duplicate option") true)
         _ (cond ((= Name entry-limit) (limits.entries-> Config (fs.limit Value 1000000)))
                 ((= Name name-byte-limit) (limits.name-bytes-> Config (fs.limit Value 67108864)))
                 ((and Walk (= Name depth-limit)) (limits.depth-> Config (fs.limit Value 256)))
                 (true (error "fs: unknown option")))
      (configure Config Rest [Name | Seen] Walk))
  _ _ _ _ -> (error "fs: options must be [Name Value] pairs"))

(define list-path
  Path Entries Bytes -> (native list Path (freeze (c-list Path Entries Bytes))))

(define fs.list
  Path Options ->
    (let Config (configure (limits.make 4096 1048576 0) Options [] false)
      (let-ok Resolved (fs.resolve Path)
                 Raw (list-path Resolved (limits.entries Config) (limits.name-bytes Config))
        (:ok (<-address Raw 0)))))

\\ State counts visited and scheduled entries, and all listed name bytes; stop releases pending lists.
(defstruct walk-state
  (mutable visited)
  (mutable scheduled)
  (mutable name-bytes)
  (mutable stopped))

(define visit
  Visit Info Depth ->
    (trap-error
      (visit-result Info (Visit Info Depth))
      (/. X (:err (io.native-error walk shen 0 (path Info) (error-to-string X))))))

(define visit-result
  _ continue -> (:ok continue)
  _ skip -> (:ok skip)
  _ stop -> (:ok stop)
  _ (:err Error) -> (:err Error) where (io.error? Error)
  Info _ -> (:err (io.error walk (path Info) "invalid visitor result")))

(define walk-node
  Path Depth Config State Visit ->
    (let-ok Info (stat-path Path false)
      (let _ (walk-state.visited-> State (+ (walk-state.visited State) 1))
        (let-ok Action (visit Visit Info Depth)
          (cond ((= Action stop) (do (walk-state.stopped-> State true) (:ok done)))
                ((or (= Action skip) (not (= (kind Info) directory))
                     (>= Depth (limits.depth Config))) (:ok done))
                (true (walk-directory Path Depth Config State Visit)))))))

(define walk-directory
  Path Depth Config State Visit ->
    (let Entries (- (limits.entries Config) (walk-state.scheduled State))
         Bytes (- (limits.name-bytes Config) (walk-state.name-bytes State))
      (let-ok Raw (list-path Path Entries Bytes)
        (let Names (<-address Raw 0)
             _ (walk-state.scheduled-> State (+ (walk-state.scheduled State) (length Names)))
             _ (walk-state.name-bytes-> State (+ (walk-state.name-bytes State) (<-address Raw 1)))
          (walk-children Path Names (+ Depth 1) Config State Visit)))))

(define walk-children
  _ [] _ _ _ _ -> (:ok done)
  Parent [Name | Rest] Depth Config State Visit ->
    (let-ok _ (walk-node (join Parent Name) Depth Config State Visit)
      (if (walk-state.stopped State)
          (:ok done)
          (walk-children Parent Rest Depth Config State Visit))))

(define walk-result
  State (:ok _) -> (:ok (@p (walk-state.visited State) (walk-state.stopped State)))
  State (:err Error) -> (:err (io.progress Error (walk-state.visited State))))

\\ The root without trailing separators, which would make lstat follow a linked root.
(define untrailed
  Path -> (let P (parts Path) (shen-jit.bytes->string (split.bytes P) 0 (split.end P))))

(define fs.walk
  Path Options Visit ->
    (let Config (configure (limits.make 10000 16777216 64) Options [] true)
         _ (if (> (limits.entries Config) 0) true (error "fs: walk entry-limit must include the root"))
         State (:walk-state visited <- 0 scheduled <- 1 name-bytes <- 0 stopped <- false)
      (let-ok Root (fs.resolve Path)
        (walk-result State (walk-node (untrailed Root) 0 Config State Visit)))))

\\ These calls use the same C runtime and UTF-16 conversion as the existing file endpoints.
(define simple
  Op Path F ->
    (let Result (trap-error
                  (let-ok Native (io.file-native-name Path)
                    (let RC (F Native)
                         Code (shen-jit.c-errno)
                      (if (= RC 0) (:ok []) (:err (io.file-error Op Path Code)))))
                  (/. X (:err (io.native-error Op foreign 0 Path (error-to-string X)))))
      (operation Op Result)))

(define operation
  Op (:err (:io.error domain <- D code <- C resource <- R message <- M progress <- N secondary <- S ...)) ->
    (:err (:io.error operation <- Op domain <- D code <- C resource <- R message <- M progress <- N secondary <- S))
  _ Result -> Result)

(define mkdir-path
  Path Mode ->
    (simple mkdir Path
      (/. Native
        (if (io.file-windows?) (c-wmkdir Native) (c-mkdir Native Mode)))))

(define remove-file-path
  Path -> (simple unlink Path (function c-unlink)))

(define remove-directory-path
  Path -> (simple rmdir Path (function c-rmdir)))

(define rename-path
  From To Replace ->
    (let Resource (cn From (cn " -> " To))
      (let-ok _ (native (if Replace replace rename) Resource
                     (freeze (c-rename From To Replace)))
        (:ok []))))

(define random-linux
  Bytes At At -> (:ok Bytes)
  Bytes At End ->
    (let Chunk (shen-jit.bytes (- End At))
         N (c-random-linux Chunk (- End At) 0)
         Code (shen-jit.c-errno)
      (cond ((> N 0)
              (do (shen-jit.copy-bytes Bytes At Chunk 0 N)
                  (random-linux Bytes (+ At N) End)))
            ((and (< N 0) (= Code 4)) (random-linux Bytes At End))
            (true (:err (io.native-error random posix Code "temporary name"
                                          "secure random generator failed"))))))

(define random-bytes
  ->
    (trap-error
      (let B (shen-jit.bytes 16)
        (cond ((= (value *os*) "Linux") (random-linux B 0 16))
              ((io.file-windows?)
                (if (c-random-win B 16)
                    (:ok B)
                    (:err (io.error random "temporary name" "secure random generator failed"))))
              (true (do (c-random-mac B 16) (:ok B)))))
      (/. X (:err (io.native-error random foreign 0 "temporary name" (error-to-string X))))))

(define hex
  _ 16 Acc -> Acc
  B I Acc ->
    (let N (shen-jit.u8 B I)
         Hi (pos "0123456789abcdef" (shen-jit.shift-right N 4))
         Lo (pos "0123456789abcdef" (shen-jit.bit-and N 15))
      (hex B (+ I 1) (cn Acc (cn Hi Lo)))))

(define random-name
  Prefix -> (let-ok Bytes (random-bytes) (:ok (hex Bytes 0 Prefix))))

(define temp-open
  Path ->
    (let-ok Native (io.file-native-name Path)
      (let Flags (+ (io.file-flags read-write) (io.file-by-os 192 2560 1280))
           Fd (io.file-c-open Native Flags 384)
           Code (shen-jit.c-errno)
        (if (< Fd 0)
            (:err (io.file-error temp-file Path Code))
            (shen-jit.on-error (freeze (:ok (@p Path (io.file-make Path read-write Fd))))
                               (freeze (do (io.file-c-close Fd) (c-unlink Native))))))))

(define temp-created
  _ _ _ (:ok Value) -> (:ok Value)
  Parent Prefix Attempts (:err Error) ->
    (if (= (io.error-code Error) 17)
        (temp-file-try Parent Prefix (- Attempts 1))
        (:err Error)))

(define temp-file-try
  Parent _ 0 ->
    (:err (io.native-error temp-file limit 0 Parent "temporary name collision limit exceeded"))
  Parent Prefix Attempts ->
    (let-ok Name (random-name Prefix)
      (temp-created Parent Prefix Attempts (temp-open (join Parent Name)))))

(datatype t
  N : number;
  ____________________________
  [entry-limit N] : option;

  N : fixnum;
  ____________________________
  [name-byte-limit N] : option;

  N : number;
  ____________________________
  [depth-limit N] : option;

  ____________________________
  continue : visit;

  ____________________________
  skip : visit;

  ____________________________
  stop : visit;

  E : io.error;
  ============================
  (:err E) : visit;)

\\ The checked filesystem operations cross the native boundary here.
(declare mkdir-path [string --> [number --> [result.t [io.error * result.empty]]]])
(declare remove-directory-path [string --> [result.t [io.error * result.empty]]])
(declare random-name [string --> [result.t [io.error * string]]])
(declare stat-path [string --> [boolean --> [result.t [io.error * info]]]])
(declare remove-file-path [string --> [result.t [io.error * result.empty]]])
(declare rename-path [string --> [string --> [boolean --> [result.t [io.error * result.empty]]]]])
(declare resolve-pair [string --> [string --> [result.t [io.error * [string * string]]]]])
(declare temp-file-try [string --> [string --> [number --> [result.t [io.error * [string * io.endpoint]]]]]])

(declare fs.resolve [string --> [result.t [io.error * string]]])
(declare fs.list [string --> [[list option] --> [result.t [io.error * [list string]]]]])
(declare fs.walk
  [string --> [[list option] -->
    [[info --> [number --> visit]] --> [result.t [io.error * [number * boolean]]]]]])

)
