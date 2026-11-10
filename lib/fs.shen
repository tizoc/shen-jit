\\ Filesystem operations over our own I/O. Load ffi, buffer, io and io-file first, under (tc -).
\\ Native directory handles never escape a listing; file contents remain io.endpoint operations.

(shen.x.namespace fs
  (use buffer)
  (use io)
  (use shen-jit)
  (import struct defstruct)
  (externals [blocking bool bytes continue copy crt define-foreign define-foreign-procedure
    depth-limit directory done entry-limit eof fs-options fs-visits int32 int64 io-error library
    lstat mkdir name-byte-limit ok other posix random read-write rename replace resolve rmdir shen
    skip stat stop symlink temp-directory temp-file uint32 unlink void walk win32 write written])
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

\\ Lexical helpers preserve .. and symlinks; resolution shares the file module's home snapshot.
(define checked
  Path ->
    (let _ (if (string? Path) true (error "fs: path must be a string"))
         B (shen-jit.string->bytes Path)
         N (shen-jit.bytes-length B)
         _ (if (and (> N 0) (<= N 1048576)) true (error "fs: path must contain 1..1048576 bytes"))
         _ (io.file-no-nul B 0 N)
      Path))

(define separator?
  Byte -> (or (= Byte 47) (and (io.file-windows?) (= Byte 92))))

(define join
  Base Path ->
    (let _ (checked Path)
         B (shen-jit.string->bytes Path)
         _ (if (string? Base) true (error "fs: base must be a string"))
      (if (or (= Base "") (io.file-absolute? B (shen-jit.bytes-length B)))
          Path
          (let _ (checked Base)
               A (shen-jit.string->bytes Base)
               N (shen-jit.bytes-length A)
            (cn Base (cn (if (separator? (shen-jit.u8 A (- N 1))) "" "/") Path))))))

(define fs.resolve
  Path -> (resolve-home Path (value *home-directory*)))

(define resolve-home
  Path Home ->
    (let Prepared (checked (io.file-path-at (checked Path) Home))
         B (shen-jit.string->bytes Prepared)
      (if (and (not (io.file-windows?)) (io.file-absolute? B (shen-jit.bytes-length B)))
          [ok Prepared]
          (native resolve Prepared (freeze (c-resolve Prepared))))))

(define resolve-at
  Base Path -> (fs.resolve (join Base Path)))

(define resolve-pair
  From To ->
    (let Home (value *home-directory*)
      (io.let-ok A (resolve-home From Home)
                 B (resolve-home To Home)
        [ok (@p A B)])))

(define next-separator
  _ At At -> At
  B At End ->
    (if (separator? (shen-jit.u8 B At))
        At
        (next-separator B (+ At 1) End)))

(define unc?
  B N ->
    (and (io.file-windows?) (> N 1)
         (separator? (shen-jit.u8 B 0))
         (separator? (shen-jit.u8 B 1))))

(define extended-unc?
  B N ->
    (and (unc? B N) (> N 7)
         (= (shen-jit.u8 B 2) 63)
         (separator? (shen-jit.u8 B 3))
         (element? (shen-jit.u8 B 4) [85 117])
         (element? (shen-jit.u8 B 5) [78 110])
         (element? (shen-jit.u8 B 6) [67 99])
         (separator? (shen-jit.u8 B 7))))

(define root-end
  B N ->
    (cond ((extended-unc? B N) (share-end B 8 N))
          ((unc? B N) (share-end B 2 N))
          ((and (io.file-windows?) (> N 2)
                (= (shen-jit.u8 B 1) 58) (separator? (shen-jit.u8 B 2))) 3)
          ((separator? (shen-jit.u8 B 0)) (root-separators B 0 N))
          (true 0)))

(define root-separators
  B At End ->
    (if (and (< At End) (separator? (shen-jit.u8 B At)))
        (root-separators B (+ At 1) End)
        At))

(define share-end
  B Start N ->
    (let Server (next-separator B Start N)
         Share (next-separator B (io.min N (+ Server 1)) N)
      (if (< Share N) (+ Share 1) Share)))

(define trim-end
  B Root End ->
    (if (and (> End Root) (separator? (shen-jit.u8 B (- End 1))))
        (trim-end B Root (- End 1))
        End))

(define last-separator
  _ At 0 -> At
  B At End ->
    (let Next (- End 1)
      (if (separator? (shen-jit.u8 B Next))
          Next
          (last-separator B At Next))))

\\ A path's bytes, where its root ends, where it ends without trailing separators, and its last
\\ separator before that, or -1.
(defstruct split
  bytes
  root
  end
  slash)

(define parts
  Path ->
    (let _ (checked Path)
         B (shen-jit.string->bytes Path)
         Root (root-end B (shen-jit.bytes-length B))
         End (trim-end B Root (shen-jit.bytes-length B))
         Slash (last-separator B -1 End)
      (:split bytes <- B root <- Root end <- End slash <- Slash)))

(define parent
  Path ->
    (let P (parts Path)
         B (split.bytes P)
         Root (split.root P)
         End (split.end P)
         Slash (split.slash P)
      (cond ((<= End Root) (shen-jit.bytes->string B 0 Root))
            ((< Slash 0) ".")
            (true (shen-jit.bytes->string B 0 (if (< Slash Root) Root Slash))))))

(define name
  Path ->
    (let P (parts Path)
         End (split.end P)
         At (+ (split.slash P) 1)
      (if (<= End (split.root P))
          ""
          (shen-jit.bytes->string (split.bytes P) At (- End At)))))

(define last-dot
  _ At 0 -> At
  B At End ->
    (let Next (- End 1)
      (if (= (shen-jit.u8 B Next) 46)
          Next
          (last-dot B At Next))))

(define extension
  Path ->
    (let B (shen-jit.string->bytes (name Path))
         N (shen-jit.bytes-length B)
         Dot (last-dot B -1 N)
      (if (or (<= Dot 0) (= Dot (- N 1)))
          ""
          (shen-jit.bytes->string B Dot (- N Dot)))))

(define domain
  1 -> posix
  2 -> win32
  4 -> limit
  _ -> library)

(define reply
  _ _ Native -> [ok (<-address Native 3)] where (= (<-address Native 0) 0)
  Op Resource Native ->
    [error (io.native-error Op (domain (<-address Native 0))
                           (<-address Native 1) Resource (<-address Native 2))])

(define native
  Op Resource F ->
    (trap-error
      (do (if (= (c-abi) 1) true (error "fs: incompatible adapter ABI; rebuild with make fs"))
          (reply Op Resource (thaw F)))
      (/. X [error (io.native-error Op foreign 0 Resource (error-to-string X))])))

(define kind-number
  0 -> file
  1 -> directory
  2 -> symlink
  _ -> other)

\\ Metadata: modified and accessed are (@p Seconds Nanoseconds).
(defstruct info
  path
  kind
  size
  modified
  accessed)

(define stat-path
  Path Follow ->
    (io.let-ok Raw (native (if Follow stat lstat) Path (freeze (c-stat Path Follow)))
      [ok (:info
            path <- Path
            kind <- (kind-number (<-address Raw 0))
            size <- (<-address Raw 1)
            modified <- (@p (<-address Raw 2) (<-address Raw 3))
            accessed <- (@p (<-address Raw 4) (<-address Raw 5)))]))

(define fs.stat
  Path -> (io.let-ok Resolved (fs.resolve Path) (stat-path Resolved true)))

(define fs.lstat
  Path -> (io.let-ok Resolved (fs.resolve Path) (stat-path Resolved false)))

(define info-check
  Info -> (if (info? Info) Info (error "fs: not metadata")))

(define path
  Info -> (info.path (info-check Info)))

(define kind
  Info -> (info.kind (info-check Info)))

(define size
  Info -> (info.size (info-check Info)))

(define modified
  Info -> (info.modified (info-check Info)))

(define accessed
  Info -> (info.accessed (info-check Info)))

(define absent?
  Error ->
    (or (and (element? (io.error-domain Error) [posix crt]) (element? (io.error-code Error) [2 20]))
        (and (= (io.error-domain Error) win32) (element? (io.error-code Error) [2 3]))))

(define exists-result
  [ok _] -> [ok true]
  [error Error] -> (if (absent? Error) [ok false] [error Error]))

(define exists?
  Path -> (exists-result (fs.stat Path)))

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
      (io.let-ok Resolved (fs.resolve Path)
                 Raw (list-path Resolved (limits.entries Config) (limits.name-bytes Config))
        [ok (<-address Raw 0)])))

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
      (/. X [error (io.native-error walk shen 0 (path Info) (error-to-string X))])))

(define visit-result
  _ continue -> [ok continue]
  _ skip -> [ok skip]
  _ stop -> [ok stop]
  _ [error Error] -> [error Error] where (io.error? Error)
  Info _ -> [error (io.error walk (path Info) "invalid visitor result")])

(define walk-node
  Path Depth Config State Visit ->
    (io.let-ok Info (stat-path Path false)
      (let _ (walk-state.visited-> State (+ (walk-state.visited State) 1))
        (io.let-ok Action (visit Visit Info Depth)
          (cond ((= Action stop) (do (walk-state.stopped-> State true) [ok done]))
                ((or (= Action skip) (not (= (kind Info) directory))
                     (>= Depth (limits.depth Config))) [ok done])
                (true (walk-directory Path Depth Config State Visit)))))))

(define walk-directory
  Path Depth Config State Visit ->
    (let Entries (- (limits.entries Config) (walk-state.scheduled State))
         Bytes (- (limits.name-bytes Config) (walk-state.name-bytes State))
      (io.let-ok Raw (list-path Path Entries Bytes)
        (let Names (<-address Raw 0)
             _ (walk-state.scheduled-> State (+ (walk-state.scheduled State) (length Names)))
             _ (walk-state.name-bytes-> State (+ (walk-state.name-bytes State) (<-address Raw 1)))
          (walk-children Path Names (+ Depth 1) Config State Visit)))))

(define walk-children
  _ [] _ _ _ _ -> [ok done]
  Parent [Name | Rest] Depth Config State Visit ->
    (io.let-ok _ (walk-node (join Parent Name) Depth Config State Visit)
      (if (walk-state.stopped State)
          [ok done]
          (walk-children Parent Rest Depth Config State Visit))))

(define walk-result
  State [ok _] -> [ok (@p (walk-state.visited State) (walk-state.stopped State))]
  State [error Error] -> [error (io.progress Error (walk-state.visited State))])

\\ The root without trailing separators, which would make lstat follow a linked root.
(define untrailed
  Path -> (let P (parts Path) (shen-jit.bytes->string (split.bytes P) 0 (split.end P))))

(define fs.walk
  Path Options Visit ->
    (let Config (configure (limits.make 10000 16777216 64) Options [] true)
         _ (if (> (limits.entries Config) 0) true (error "fs: walk entry-limit must include the root"))
         State (:walk-state visited <- 0 scheduled <- 1 name-bytes <- 0 stopped <- false)
      (io.let-ok Root (fs.resolve Path)
        (walk-result State (walk-node (untrailed Root) 0 Config State Visit)))))

\\ These calls use the same C runtime and UTF-16 conversion as the existing file endpoints.
(define simple
  Op Path F ->
    (let Result (trap-error
                  (io.let-ok Native (io.file-native-name Path)
                    (let RC (F Native)
                         Code (shen-jit.c-errno)
                      (if (= RC 0) [ok] [error (io.file-error Op Path Code)])))
                  (/. X [error (io.native-error Op foreign 0 Path (error-to-string X))]))
      (operation Op Result)))

(define operation
  Op [error [io-error _ Domain Code Path Message Progress Secondary]] ->
    [error [io-error Op Domain Code Path Message Progress Secondary]]
  _ Result -> Result)

(define mkdir-path
  Path Mode ->
    (simple mkdir Path
      (/. Native
        (if (io.file-windows?) (c-wmkdir Native) (c-mkdir Native Mode)))))

(define fs.mkdir
  Path -> (io.let-ok P (fs.resolve Path) (mkdir-path P 511)))

(define remove-file-path
  Path -> (simple unlink Path (function c-unlink)))

(define remove-file
  Path -> (io.let-ok P (fs.resolve Path) (remove-file-path P)))

(define remove-directory
  Path -> (io.let-ok P (fs.resolve Path) (simple rmdir P (function c-rmdir))))

(define rename-path
  From To Replace ->
    (let Resource (cn From (cn " -> " To))
      (io.let-ok _ (native (if Replace replace rename) Resource
                     (freeze (c-rename From To Replace)))
        [ok])))

(define fs.rename
  From To ->
    (io.let-ok Paths (resolve-pair From To)
      (rename-path (fst Paths) (snd Paths) false)))

(define fs.replace
  From To ->
    (io.let-ok Paths (resolve-pair From To)
      (rename-path (fst Paths) (snd Paths) true)))

(define mkdir-existing
  _ [ok] -> [ok]
  Path [error Error] ->
    (if (= (io.error-code Error) 17)
        (io.let-ok Info (stat-path Path true)
          (if (= (kind Info) directory) [ok] [error Error]))
        [error Error]))

(define mkdirs-path
  Path -> (mkdirs-depth Path 256))

(define mkdirs-depth
  Path 0 -> [error (io.native-error mkdir limit 0 Path "parent depth exceeds 256")]
  Path Remaining ->
    (let Parent (parent Path)
      (if (= Parent Path)
          (io.let-ok Info (stat-path Path true)
            (if (= (kind Info) directory)
                [ok]
                [error (io.error mkdir Path "root is not a directory")]))
          (io.let-ok _ (if (= Parent ".") [ok] (mkdirs-depth Parent (- Remaining 1)))
            (mkdir-existing Path (mkdir-path Path 511))))))

(define mkdirs
  Path -> (io.let-ok P (fs.resolve Path) (mkdirs-path P)))

(define random-linux
  Bytes At At -> [ok Bytes]
  Bytes At End ->
    (let Chunk (shen-jit.bytes (- End At))
         N (c-random-linux Chunk (- End At) 0)
         Code (shen-jit.c-errno)
      (cond ((> N 0)
              (do (shen-jit.copy-bytes Bytes At Chunk 0 N)
                  (random-linux Bytes (+ At N) End)))
            ((and (< N 0) (= Code 4)) (random-linux Bytes At End))
            (true [error (io.native-error random posix Code "temporary name"
                                          "secure random generator failed")]))))

(define random-bytes
  ->
    (trap-error
      (let B (shen-jit.bytes 16)
        (cond ((= (value *os*) "Linux") (random-linux B 0 16))
              ((io.file-windows?)
                (if (c-random-win B 16)
                    [ok B]
                    [error (io.error random "temporary name" "secure random generator failed")]))
              (true (do (c-random-mac B 16) [ok B]))))
      (/. X [error (io.native-error random foreign 0 "temporary name" (error-to-string X))])))

(define hex
  _ 16 Acc -> Acc
  B I Acc ->
    (let N (shen-jit.u8 B I)
         Hi (pos "0123456789abcdef" (shen-jit.shift-right N 4))
         Lo (pos "0123456789abcdef" (shen-jit.bit-and N 15))
      (hex B (+ I 1) (cn Acc (cn Hi Lo)))))

(define prefix-byte?
  B -> (or (and (>= B 48) (<= B 57)) (and (>= B 65) (<= B 90))
           (and (>= B 97) (<= B 122)) (element? B [45 46 95])))

(define prefix-range?
  _ At At -> true
  B At End -> (and (prefix-byte? (shen-jit.u8 B At)) (prefix-range? B (+ At 1) End)))

(define prefix
  Prefix ->
    (let _ (checked Prefix)
         B (shen-jit.string->bytes Prefix)
         N (shen-jit.bytes-length B)
      (if (and (<= N 64) (prefix-range? B 0 N))
          Prefix
          (error "fs: temporary prefix must be 1..64 ASCII letters, digits or ._-"))))

(define random-name
  Prefix -> (io.let-ok Bytes (random-bytes) [ok (hex Bytes 0 Prefix)]))

(define temp-open
  Path ->
    (io.let-ok Native (io.file-native-name Path)
      (let Flags (+ (io.file-flags read-write) (io.file-by-os 192 2560 1280))
           Fd (io.file-c-open Native Flags 384)
           Code (shen-jit.c-errno)
        (if (< Fd 0)
            [error (io.file-error temp-file Path Code)]
            (trap-error [ok (@p Path (io.file-make Path read-write Fd))]
              (/. X
                (do (io.file-c-close Fd)
                    (c-unlink Native)
                    (simple-error (error-to-string X)))))))))

(define temp-created
  _ _ _ [ok Value] -> [ok Value]
  Parent Prefix Attempts [error Error] ->
    (if (= (io.error-code Error) 17)
        (temp-file-try Parent Prefix (- Attempts 1))
        [error Error]))

(define temp-file-try
  Parent _ 0 ->
    [error (io.native-error temp-file limit 0 Parent "temporary name collision limit exceeded")]
  Parent Prefix Attempts ->
    (io.let-ok Name (random-name Prefix)
      (temp-created Parent Prefix Attempts (temp-open (join Parent Name)))))

(define fs.temp-file
  Parent Prefix ->
    (do (prefix Prefix)
        (io.let-ok Root (fs.resolve Parent)
          (trap-error (temp-file-try Root Prefix 64)
            (/. X [error (io.native-error temp-file foreign 0 Root (error-to-string X))])))))

(define temp-directory-try
  Parent _ 0 ->
    [error (io.native-error temp-directory limit 0 Parent "temporary name collision limit exceeded")]
  Parent Prefix Attempts ->
    (io.let-ok Name (random-name Prefix)
      (let Path (join Parent Name)
           Result (mkdir-path Path 448)
        (cond ((= Result [ok]) [ok Path])
              ((= (io.error-code (hd (tl Result))) 17)
                (temp-directory-try Parent Prefix (- Attempts 1)))
              (true Result)))))

(define fs.temp-directory
  Parent Prefix ->
    (do (prefix Prefix)
        (io.let-ok Root (fs.resolve Parent)
          (temp-directory-try Root Prefix 64))))

(define with-temp-open
  _ [error Error] -> [error Error]
  F [ok (@p Path E)] ->
    (let Result (io.with-endpoint E (/. Out (F Path Out)))
      (io.finish Result (cleanup-temp Path))))

(define with-temp-file
  Parent Prefix F -> (with-temp-open F (fs.temp-file Parent Prefix)))

(define cleanup-temp
  Path -> (cleaned (remove-file-path Path)))

(define cleaned
  [error Error] -> (if (absent? Error) [ok] [error Error])
  Result -> Result)

(define replace-open
  _ _ [error Error] -> [error Error]
  Path F [ok (@p Temporary E)] ->
    (let Result (io.with-endpoint E F)
         Moved (if (= (hd Result) ok)
                   (io.finish Result (rename-path Temporary Path true))
                   Result)
      (if (= (hd Moved) ok)
          Moved
          (io.finish Moved (cleanup-temp Temporary)))))

(define with-replacement
  Path F ->
    (io.let-ok Resolved (fs.resolve Path)
      (replace-open Resolved F (temp-file-try (parent Resolved) ".shen-" 64))))

(define write-chunk
  _ _ _ End End -> [ok End]
  State E View At End ->
    (let Result (trap-error (io.write-some E (buffer.slice View At (- End At)) [])
                   (/. X [error (io.error write (io.endpoint.name E) (error-to-string X))]))
      (write-step State E View At End Result)))

(define write-step
  State E View At End [written N] ->
    (do (address-> State 0 (+ (<-address State 0) N))
        (write-chunk State E View (+ At N) End))
  State _ _ _ _ [error Error] -> [error (io.progress Error (<-address State 0))])

(define counted
  _ [ok Value] -> [ok Value]
  State [error Error] -> [error (io.progress Error (<-address State 0))])

(define write-replace
  Path View ->
    (let _ (buffer.check View)
         State (io.record [0])
         Result (with-replacement Path
                  (/. E (write-chunk State E View 0 (buffer.length View))))
      (counted State Result)))

(define copy-read
  Input Output Chunk State Limit ->
    (let Read (trap-error (io.read-some Input Chunk [])
                 (/. X [error (io.error read (io.endpoint.name Input) (error-to-string X))]))
      (copy-step Input Output Chunk State Limit Read)))

(define copy-step
  _ _ _ State _ [eof] -> [ok (<-address State 0)]
  _ _ _ State _ [error Error] -> [error (io.progress Error (<-address State 0))]
  Input Output Chunk State Limit [read N] ->
    (let At (<-address State 0)
      (if (> N (- Limit At))
          [error (io.progress
                   (io.native-error copy limit 0 "file copy" "copy byte limit exceeded") At)]
          (io.let-ok _ (write-chunk State Output Chunk 0 N)
            (copy-read Input Output Chunk State Limit)))))

(define copy-file
  From To Limit ->
    (let _ (buffer.index Limit)
         State (io.record [0])
         Result (io.let-ok Paths (resolve-pair From To)
                  (copy-paths Paths State Limit))
      (counted State Result)))

(define copy-paths
  (@p Source Target) State Limit ->
    (io.let-ok Info (stat-path Source true)
      (if (not (= (kind Info) file))
          [error (io.error copy Source "copy source must be a regular file")]
          (io.let-ok Input (io.open-file Source read)
            (io.with-endpoint Input
              (/. In
                (let Chunk (buffer.new 65536)
                  (with-replacement Target
                    (/. Out (copy-read In Out Chunk State Limit))))))))))

(datatype fs-options
  N : number;
  ============================
  [entry-limit N] : option;

  N : number;
  ============================
  [name-byte-limit N] : option;

  N : number;
  ============================
  [depth-limit N] : option;)

(datatype fs-visits
  ____________________________
  continue : visit;

  ____________________________
  skip : visit;

  ____________________________
  stop : visit;

  E : io.error;
  ============================
  [error E] : visit;)

(declare join [string --> [string --> string]])
(declare parent [string --> string])
(declare name [string --> string])
(declare extension [string --> string])
(declare fs.resolve [string --> [io.result string]])
(declare resolve-at [string --> [string --> [io.result string]]])
(declare fs.stat [string --> [io.result info]])
(declare fs.lstat [string --> [io.result info]])
(declare exists? [string --> [io.result boolean]])
(declare path [info --> string])
(declare kind [info --> symbol])
(declare size [info --> number])
(declare modified [info --> [number * number]])
(declare accessed [info --> [number * number]])
(declare fs.list [string --> [[list option] --> [io.result [list string]]]])
(declare fs.walk
  [string --> [[list option] -->
    [[info --> [number --> visit]] --> [io.result [number * boolean]]]]])
(declare fs.mkdir [string --> io.close-result])
(declare mkdirs [string --> io.close-result])
(declare remove-file [string --> io.close-result])
(declare remove-directory [string --> io.close-result])
(declare fs.rename [string --> [string --> io.close-result]])
(declare fs.replace [string --> [string --> io.close-result]])
(declare fs.temp-file [string --> [string --> [io.result [string * io.endpoint]]]])
(declare fs.temp-directory [string --> [string --> [io.result string]]])
(declare with-temp-file
  [string --> [string --> [[string --> [io.endpoint --> [io.result A]]] --> [io.result A]]]])
(declare with-replacement [string --> [[io.endpoint --> [io.result A]] --> [io.result A]]])
(declare write-replace [string --> [buffer.view --> [io.result number]]])
(declare copy-file [string --> [string --> [number --> [io.result number]]]])

)
