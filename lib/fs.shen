\\ Filesystem operations over our own I/O. Load ffi, buffer, io and io-file first, under (tc -).
\\ Native directory handles never escape a listing; file contents remain io.endpoint operations.

(shen-jit.library fs.adapter
  (trap-error (value fs.*adapter-files*)
    (/. X ["./build/shen-fs.so" "./lib/shen-fs.so" "./shen-fs.so"
           "./build/shen-fs.dll" "./lib/shen-fs.dll" "./shen-fs.dll"])))
(define-foreign fs.c-abi fs.adapter "shen_fs_abi" () --> int32)
(define-foreign-procedure fs.c-stat fs.adapter "shen_fs_stat" 2)
(define-foreign-procedure fs.c-list fs.adapter "shen_fs_list" 3)
(define-foreign-procedure fs.c-rename fs.adapter "shen_fs_rename" 3)
(define-foreign-procedure fs.c-resolve fs.adapter "shen_fs_resolve" 1)

(define-foreign fs.c-mkdir io.file-lib "mkdir" (string int32) --> int32 blocking)
(define-foreign fs.c-wmkdir io.file-lib "_wmkdir" (bytes) --> int32 blocking)
(define-foreign fs.c-unlink io.file-lib (if (io.file-windows?) "_wunlink" "unlink")
  ((if (io.file-windows?) bytes string)) --> int32 blocking)
(define-foreign fs.c-rmdir io.file-lib (if (io.file-windows?) "_wrmdir" "rmdir")
  ((if (io.file-windows?) bytes string)) --> int32 blocking)
(define-foreign fs.c-random-linux io.file-lib "getrandom" (bytes int64 uint32) --> int64 blocking)
(define-foreign fs.c-random-mac io.file-lib "arc4random_buf" (bytes int64) --> void blocking)
(shen-jit.library fs.random-win ["advapi32.dll"])
(define-foreign fs.c-random-win fs.random-win "SystemFunction036" (bytes uint32) --> bool blocking)

\\ Lexical helpers preserve .. and symlinks; resolution shares the file module's home snapshot.
(define fs.checked
  Path ->
    (let _ (if (string? Path) true (error "fs: path must be a string"))
         B (shen-jit.string->bytes Path)
         N (shen-jit.bytes-length B)
         _ (if (and (> N 0) (<= N 1048576)) true (error "fs: path must contain 1..1048576 bytes"))
         _ (io.file-no-nul B 0 N)
      Path))

(define fs.separator?
  Byte -> (or (= Byte 47) (and (io.file-windows?) (= Byte 92))))

(define fs.join
  Base Path ->
    (let _ (fs.checked Path)
         B (shen-jit.string->bytes Path)
         _ (if (string? Base) true (error "fs: base must be a string"))
      (if (or (= Base "") (io.file-absolute? B (shen-jit.bytes-length B)))
          Path
          (let _ (fs.checked Base)
               A (shen-jit.string->bytes Base)
               N (shen-jit.bytes-length A)
            (cn Base (cn (if (fs.separator? (shen-jit.u8 A (- N 1))) "" "/") Path))))))

(define fs.resolve
  Path -> (fs.resolve-home Path (value *home-directory*)))

(define fs.resolve-home
  Path Home ->
    (let Prepared (fs.checked (io.file-path-at (fs.checked Path) Home))
         B (shen-jit.string->bytes Prepared)
      (if (and (not (io.file-windows?)) (io.file-absolute? B (shen-jit.bytes-length B)))
          [ok Prepared]
          (fs.native resolve Prepared (freeze (fs.c-resolve Prepared))))))

(define fs.resolve-at
  Base Path -> (fs.resolve (fs.join Base Path)))

(define fs.resolve-pair
  From To ->
    (let Home (value *home-directory*)
      (io.let-ok A (fs.resolve-home From Home)
                 B (fs.resolve-home To Home)
        [ok (@p A B)])))

(define fs.next-separator
  _ At At -> At
  B At End ->
    (if (fs.separator? (shen-jit.u8 B At))
        At
        (fs.next-separator B (+ At 1) End)))

(define fs.unc?
  B N ->
    (and (io.file-windows?) (> N 1)
         (fs.separator? (shen-jit.u8 B 0))
         (fs.separator? (shen-jit.u8 B 1))))

(define fs.extended-unc?
  B N ->
    (and (fs.unc? B N) (> N 7)
         (= (shen-jit.u8 B 2) 63)
         (fs.separator? (shen-jit.u8 B 3))
         (element? (shen-jit.u8 B 4) [85 117])
         (element? (shen-jit.u8 B 5) [78 110])
         (element? (shen-jit.u8 B 6) [67 99])
         (fs.separator? (shen-jit.u8 B 7))))

(define fs.root-end
  B N ->
    (cond ((fs.extended-unc? B N) (fs.share-end B 8 N))
          ((fs.unc? B N) (fs.share-end B 2 N))
          ((and (io.file-windows?) (> N 2)
                (= (shen-jit.u8 B 1) 58) (fs.separator? (shen-jit.u8 B 2))) 3)
          ((fs.separator? (shen-jit.u8 B 0)) (fs.root-separators B 0 N))
          (true 0)))

(define fs.root-separators
  B At End ->
    (if (and (< At End) (fs.separator? (shen-jit.u8 B At)))
        (fs.root-separators B (+ At 1) End)
        At))

(define fs.share-end
  B Start N ->
    (let Server (fs.next-separator B Start N)
         Share (fs.next-separator B (io.min N (+ Server 1)) N)
      (if (< Share N) (+ Share 1) Share)))

(define fs.trim-end
  B Root End ->
    (if (and (> End Root) (fs.separator? (shen-jit.u8 B (- End 1))))
        (fs.trim-end B Root (- End 1))
        End))

(define fs.last-separator
  _ At 0 -> At
  B At End ->
    (let Next (- End 1)
      (if (fs.separator? (shen-jit.u8 B Next))
          Next
          (fs.last-separator B At Next))))

(define fs.parts
  Path ->
    (let _ (fs.checked Path)
         B (shen-jit.string->bytes Path)
         Root (fs.root-end B (shen-jit.bytes-length B))
         End (fs.trim-end B Root (shen-jit.bytes-length B))
         Slash (fs.last-separator B -1 End)
      (io.record [B Root End Slash])))

(define fs.parent
  Path ->
    (let P (fs.parts Path)
         B (<-address P 0)
         Root (<-address P 1)
         End (<-address P 2)
         Slash (<-address P 3)
      (cond ((<= End Root) (shen-jit.bytes->string B 0 Root))
            ((< Slash 0) ".")
            (true (shen-jit.bytes->string B 0 (if (< Slash Root) Root Slash))))))

(define fs.name
  Path ->
    (let P (fs.parts Path)
         End (<-address P 2)
         At (+ (<-address P 3) 1)
      (if (<= End (<-address P 1))
          ""
          (shen-jit.bytes->string (<-address P 0) At (- End At)))))

(define fs.last-dot
  _ At 0 -> At
  B At End ->
    (let Next (- End 1)
      (if (= (shen-jit.u8 B Next) 46)
          Next
          (fs.last-dot B At Next))))

(define fs.extension
  Path ->
    (let B (shen-jit.string->bytes (fs.name Path))
         N (shen-jit.bytes-length B)
         Dot (fs.last-dot B -1 N)
      (if (or (<= Dot 0) (= Dot (- N 1)))
          ""
          (shen-jit.bytes->string B Dot (- N Dot)))))

(define fs.domain
  1 -> posix
  2 -> win32
  4 -> limit
  _ -> library)

(define fs.reply
  _ _ Native -> [ok (<-address Native 3)] where (= (<-address Native 0) 0)
  Op Resource Native ->
    [error (io.native-error Op (fs.domain (<-address Native 0))
                           (<-address Native 1) Resource (<-address Native 2))])

(define fs.native
  Op Resource F ->
    (trap-error
      (do (if (= (fs.c-abi) 1) true (error "fs: incompatible adapter ABI; rebuild with make fs"))
          (fs.reply Op Resource (thaw F)))
      (/. X [error (io.native-error Op foreign 0 Resource (error-to-string X))])))

(define fs.kind-number
  0 -> file
  1 -> directory
  2 -> symlink
  _ -> other)

(define fs.stat-path
  Path Follow ->
    (io.let-ok Raw (fs.native (if Follow stat lstat) Path (freeze (fs.c-stat Path Follow)))
      [ok (io.record [fs.info-state Path (fs.kind-number (<-address Raw 0)) (<-address Raw 1)
                      (@p (<-address Raw 2) (<-address Raw 3))
                      (@p (<-address Raw 4) (<-address Raw 5))])]))

(define fs.stat
  Path -> (io.let-ok Resolved (fs.resolve Path) (fs.stat-path Resolved true)))

(define fs.lstat
  Path -> (io.let-ok Resolved (fs.resolve Path) (fs.stat-path Resolved false)))

(define fs.info-check
  Info -> (if (io.tag? Info fs.info-state) Info (error "fs: not metadata")))

(define fs.path
  Info -> (<-address (fs.info-check Info) 1))

(define fs.kind
  Info -> (<-address (fs.info-check Info) 2))

(define fs.size
  Info -> (<-address (fs.info-check Info) 3))

(define fs.modified
  Info -> (<-address (fs.info-check Info) 4))

(define fs.accessed
  Info -> (<-address (fs.info-check Info) 5))

(define fs.absent?
  Error ->
    (or (and (element? (io.error-domain Error) [posix crt]) (element? (io.error-code Error) [2 20]))
        (and (= (io.error-domain Error) win32) (element? (io.error-code Error) [2 3]))))

(define fs.exists-result
  [ok _] -> [ok true]
  [error Error] -> (if (fs.absent? Error) [ok false] [error Error]))

(define fs.exists?
  Path -> (fs.exists-result (fs.stat Path)))

(define fs.limit
  Value Maximum ->
    (let N (buffer.index Value)
      (if (<= N Maximum) N (error "fs: option exceeds its maximum"))))

(define fs.configure
  Config [] _ _ -> Config
  Config [[Name Value] | Rest] Seen Walk ->
    (let _ (if (element? Name Seen) (error "fs: duplicate option") true)
         I (cond ((= Name entry-limit) 0)
                 ((= Name name-byte-limit) 1)
                 ((and Walk (= Name depth-limit)) 2)
                 (true (error "fs: unknown option")))
         N (fs.limit Value (cond ((= I 0) 1000000) ((= I 1) 67108864) (true 256)))
         _ (address-> Config I N)
      (fs.configure Config Rest [Name | Seen] Walk))
  _ _ _ _ -> (error "fs: options must be [Name Value] pairs"))

(define fs.list-path
  Path Entries Bytes -> (fs.native list Path (freeze (fs.c-list Path Entries Bytes))))

(define fs.list
  Path Options ->
    (let Config (fs.configure (io.record [4096 1048576]) Options [] false)
      (io.let-ok Resolved (fs.resolve Path)
                 Raw (fs.list-path Resolved (<-address Config 0) (<-address Config 1))
        [ok (<-address Raw 0)])))

\\ State counts visited and scheduled entries, and all listed name bytes; stop releases pending lists.
(define fs.visit
  Visit Info Depth ->
    (trap-error
      (fs.visit-result Info (Visit Info Depth))
      (/. X [error (io.native-error walk shen 0 (fs.path Info) (error-to-string X))])))

(define fs.visit-result
  _ continue -> [ok continue]
  _ skip -> [ok skip]
  _ stop -> [ok stop]
  _ [error Error] -> [error Error] where (io.error? Error)
  Info _ -> [error (io.error walk (fs.path Info) "invalid visitor result")])

(define fs.walk-node
  Path Depth Config State Visit ->
    (io.let-ok Info (fs.stat-path Path false)
      (let _ (address-> State 0 (+ (<-address State 0) 1))
        (io.let-ok Action (fs.visit Visit Info Depth)
          (cond ((= Action stop) (do (address-> State 3 true) [ok done]))
                ((or (= Action skip) (not (= (fs.kind Info) directory))
                     (>= Depth (<-address Config 2))) [ok done])
                (true (fs.walk-directory Path Depth Config State Visit)))))))

(define fs.walk-directory
  Path Depth Config State Visit ->
    (let Entries (- (<-address Config 0) (<-address State 1))
         Bytes (- (<-address Config 1) (<-address State 2))
      (io.let-ok Raw (fs.list-path Path Entries Bytes)
        (let Names (<-address Raw 0)
             _ (address-> State 1 (+ (<-address State 1) (length Names)))
             _ (address-> State 2 (+ (<-address State 2) (<-address Raw 1)))
          (fs.walk-children Path Names (+ Depth 1) Config State Visit)))))

(define fs.walk-children
  _ [] _ _ _ _ -> [ok done]
  Parent [Name | Rest] Depth Config State Visit ->
    (io.let-ok _ (fs.walk-node (fs.join Parent Name) Depth Config State Visit)
      (if (<-address State 3)
          [ok done]
          (fs.walk-children Parent Rest Depth Config State Visit))))

(define fs.walk-result
  State [ok _] -> [ok (@p (<-address State 0) (<-address State 3))]
  State [error Error] -> [error (io.progress Error (<-address State 0))])

(define fs.walk
  Path Options Visit ->
    (let Config (fs.configure (io.record [10000 16777216 64]) Options [] true)
         _ (if (> (<-address Config 0) 0) true (error "fs: walk entry-limit must include the root"))
         State (io.record [0 1 0 false])
      (io.let-ok Root (fs.resolve Path)
        (fs.walk-result State (fs.walk-node Root 0 Config State Visit)))))

\\ These calls use the same C runtime and UTF-16 conversion as the existing file endpoints.
(define fs.simple
  Op Path F ->
    (let Result (trap-error
                  (io.let-ok Native (io.file-native-name Path)
                    (let RC (F Native)
                         Code (shen-jit.c-errno)
                      (if (= RC 0) [ok] [error (io.file-error Op Path Code)])))
                  (/. X [error (io.native-error Op foreign 0 Path (error-to-string X))]))
      (fs.operation Op Result)))

(define fs.operation
  Op [error [io-error _ Domain Code Path Message Progress Secondary]] ->
    [error [io-error Op Domain Code Path Message Progress Secondary]]
  _ Result -> Result)

(define fs.mkdir-path
  Path Mode ->
    (fs.simple mkdir Path
      (/. Native
        (if (io.file-windows?) (fs.c-wmkdir Native) (fs.c-mkdir Native Mode)))))

(define fs.mkdir
  Path -> (io.let-ok P (fs.resolve Path) (fs.mkdir-path P 511)))

(define fs.remove-file-path
  Path -> (fs.simple unlink Path (function fs.c-unlink)))

(define fs.remove-file
  Path -> (io.let-ok P (fs.resolve Path) (fs.remove-file-path P)))

(define fs.remove-directory
  Path -> (io.let-ok P (fs.resolve Path) (fs.simple rmdir P (function fs.c-rmdir))))

(define fs.rename-path
  From To Replace ->
    (let Resource (cn From (cn " -> " To))
      (io.let-ok _ (fs.native (if Replace replace rename) Resource
                     (freeze (fs.c-rename From To Replace)))
        [ok])))

(define fs.rename
  From To ->
    (io.let-ok Paths (fs.resolve-pair From To)
      (fs.rename-path (fst Paths) (snd Paths) false)))

(define fs.replace
  From To ->
    (io.let-ok Paths (fs.resolve-pair From To)
      (fs.rename-path (fst Paths) (snd Paths) true)))

(define fs.mkdir-existing
  _ [ok] -> [ok]
  Path [error Error] ->
    (if (= (io.error-code Error) 17)
        (io.let-ok Info (fs.stat-path Path true)
          (if (= (fs.kind Info) directory) [ok] [error Error]))
        [error Error]))

(define fs.mkdirs-path
  Path -> (fs.mkdirs-depth Path 256))

(define fs.mkdirs-depth
  Path 0 -> [error (io.native-error mkdir limit 0 Path "parent depth exceeds 256")]
  Path Remaining ->
    (let Parent (fs.parent Path)
      (if (= Parent Path)
          (io.let-ok Info (fs.stat-path Path true)
            (if (= (fs.kind Info) directory)
                [ok]
                [error (io.error mkdir Path "root is not a directory")]))
          (io.let-ok _ (if (= Parent ".") [ok] (fs.mkdirs-depth Parent (- Remaining 1)))
            (fs.mkdir-existing Path (fs.mkdir-path Path 511))))))

(define fs.mkdirs
  Path -> (io.let-ok P (fs.resolve Path) (fs.mkdirs-path P)))

(define fs.random-linux
  Bytes At At -> [ok Bytes]
  Bytes At End ->
    (let Chunk (shen-jit.bytes (- End At))
         N (fs.c-random-linux Chunk (- End At) 0)
         Code (shen-jit.c-errno)
      (cond ((> N 0)
              (do (shen-jit.copy-bytes Bytes At Chunk 0 N)
                  (fs.random-linux Bytes (+ At N) End)))
            ((and (< N 0) (= Code 4)) (fs.random-linux Bytes At End))
            (true [error (io.native-error random posix Code "temporary name"
                                          "secure random generator failed")]))))

(define fs.random-bytes
  ->
    (trap-error
      (let B (shen-jit.bytes 16)
        (cond ((= (value *os*) "Linux") (fs.random-linux B 0 16))
              ((io.file-windows?)
                (if (fs.c-random-win B 16)
                    [ok B]
                    [error (io.error random "temporary name" "secure random generator failed")]))
              (true (do (fs.c-random-mac B 16) [ok B]))))
      (/. X [error (io.native-error random foreign 0 "temporary name" (error-to-string X))])))

(define fs.hex
  _ 16 Acc -> Acc
  B I Acc ->
    (let N (shen-jit.u8 B I)
         Hi (pos "0123456789abcdef" (shen-jit.shift-right N 4))
         Lo (pos "0123456789abcdef" (shen-jit.bit-and N 15))
      (fs.hex B (+ I 1) (cn Acc (cn Hi Lo)))))

(define fs.prefix-byte?
  B -> (or (and (>= B 48) (<= B 57)) (and (>= B 65) (<= B 90))
           (and (>= B 97) (<= B 122)) (element? B [45 46 95])))

(define fs.prefix-range?
  _ At At -> true
  B At End -> (and (fs.prefix-byte? (shen-jit.u8 B At)) (fs.prefix-range? B (+ At 1) End)))

(define fs.prefix
  Prefix ->
    (let _ (fs.checked Prefix)
         B (shen-jit.string->bytes Prefix)
         N (shen-jit.bytes-length B)
      (if (and (<= N 64) (fs.prefix-range? B 0 N))
          Prefix
          (error "fs: temporary prefix must be 1..64 ASCII letters, digits or ._-"))))

(define fs.random-name
  Prefix -> (io.let-ok Bytes (fs.random-bytes) [ok (fs.hex Bytes 0 Prefix)]))

(define fs.temp-open
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
                    (fs.c-unlink Native)
                    (simple-error (error-to-string X)))))))))

(define fs.temp-created
  _ _ _ [ok Value] -> [ok Value]
  Parent Prefix Attempts [error Error] ->
    (if (= (io.error-code Error) 17)
        (fs.temp-file-try Parent Prefix (- Attempts 1))
        [error Error]))

(define fs.temp-file-try
  Parent _ 0 ->
    [error (io.native-error temp-file limit 0 Parent "temporary name collision limit exceeded")]
  Parent Prefix Attempts ->
    (io.let-ok Name (fs.random-name Prefix)
      (fs.temp-created Parent Prefix Attempts (fs.temp-open (fs.join Parent Name)))))

(define fs.temp-file
  Parent Prefix ->
    (do (fs.prefix Prefix)
        (io.let-ok Root (fs.resolve Parent)
          (trap-error (fs.temp-file-try Root Prefix 64)
            (/. X [error (io.native-error temp-file foreign 0 Root (error-to-string X))])))))

(define fs.temp-directory-try
  Parent _ 0 ->
    [error (io.native-error temp-directory limit 0 Parent "temporary name collision limit exceeded")]
  Parent Prefix Attempts ->
    (io.let-ok Name (fs.random-name Prefix)
      (let Path (fs.join Parent Name)
           Result (fs.mkdir-path Path 448)
        (cond ((= Result [ok]) [ok Path])
              ((= (io.error-code (hd (tl Result))) 17)
                (fs.temp-directory-try Parent Prefix (- Attempts 1)))
              (true Result)))))

(define fs.temp-directory
  Parent Prefix ->
    (do (fs.prefix Prefix)
        (io.let-ok Root (fs.resolve Parent)
          (fs.temp-directory-try Root Prefix 64))))

(define fs.with-temp-open
  _ [error Error] -> [error Error]
  F [ok (@p Path E)] ->
    (let Result (io.with-endpoint E (/. Out (F Path Out)))
      (io.finish Result (fs.cleanup-temp Path))))

(define fs.with-temp-file
  Parent Prefix F -> (fs.with-temp-open F (fs.temp-file Parent Prefix)))

(define fs.cleanup-temp
  Path -> (fs.cleaned (fs.remove-file-path Path)))

(define fs.cleaned
  [error Error] -> (if (fs.absent? Error) [ok] [error Error])
  Result -> Result)

(define fs.replace-open
  _ _ [error Error] -> [error Error]
  Path F [ok (@p Temporary E)] ->
    (let Result (io.with-endpoint E F)
         Moved (if (= (hd Result) ok)
                   (io.finish Result (fs.rename-path Temporary Path true))
                   Result)
      (if (= (hd Moved) ok)
          Moved
          (io.finish Moved (fs.cleanup-temp Temporary)))))

(define fs.with-replacement
  Path F ->
    (io.let-ok Resolved (fs.resolve Path)
      (fs.replace-open Resolved F (fs.temp-file-try (fs.parent Resolved) ".shen-" 64))))

(define fs.write-chunk
  _ _ _ End End -> [ok End]
  State E View At End ->
    (let Result (trap-error (io.write-some E (buffer.slice View At (- End At)) [])
                   (/. X [error (io.error write (<-address E 1) (error-to-string X))]))
      (fs.write-step State E View At End Result)))

(define fs.write-step
  State E View At End [written N] ->
    (do (address-> State 0 (+ (<-address State 0) N))
        (fs.write-chunk State E View (+ At N) End))
  State _ _ _ _ [error Error] -> [error (io.progress Error (<-address State 0))])

(define fs.counted
  _ [ok Value] -> [ok Value]
  State [error Error] -> [error (io.progress Error (<-address State 0))])

(define fs.write-replace
  Path View ->
    (let _ (buffer.check View)
         State (io.record [0])
         Result (fs.with-replacement Path
                  (/. E (fs.write-chunk State E View 0 (buffer.length View))))
      (fs.counted State Result)))

(define fs.copy-read
  Input Output Chunk State Limit ->
    (let Read (trap-error (io.read-some Input Chunk [])
                 (/. X [error (io.error read (<-address Input 1) (error-to-string X))]))
      (fs.copy-step Input Output Chunk State Limit Read)))

(define fs.copy-step
  _ _ _ State _ [eof] -> [ok (<-address State 0)]
  _ _ _ State _ [error Error] -> [error (io.progress Error (<-address State 0))]
  Input Output Chunk State Limit [read N] ->
    (let At (<-address State 0)
      (if (> N (- Limit At))
          [error (io.progress
                   (io.native-error copy limit 0 "file copy" "copy byte limit exceeded") At)]
          (io.let-ok _ (fs.write-chunk State Output Chunk 0 N)
            (fs.copy-read Input Output Chunk State Limit)))))

(define fs.copy-file
  From To Limit ->
    (let _ (buffer.index Limit)
         State (io.record [0])
         Result (io.let-ok Paths (fs.resolve-pair From To)
                  (fs.copy-paths Paths State Limit))
      (fs.counted State Result)))

(define fs.copy-paths
  (@p Source Target) State Limit ->
    (io.let-ok Info (fs.stat-path Source true)
      (if (not (= (fs.kind Info) file))
          [error (io.error copy Source "copy source must be a regular file")]
          (io.let-ok Input (io.open-file Source read)
            (io.with-endpoint Input
              (/. In
                (let Chunk (buffer.new 65536)
                  (fs.with-replacement Target
                    (/. Out (fs.copy-read In Out Chunk State Limit))))))))))

(datatype fs-options
  N : number;
  ============================
  [entry-limit N] : fs.option;

  N : number;
  ============================
  [name-byte-limit N] : fs.option;

  N : number;
  ============================
  [depth-limit N] : fs.option;)

(datatype fs-visits
  ____________________________
  continue : fs.visit;

  ____________________________
  skip : fs.visit;

  ____________________________
  stop : fs.visit;

  E : io.error;
  ============================
  [error E] : fs.visit;)

(declare fs.join [string --> [string --> string]])
(declare fs.parent [string --> string])
(declare fs.name [string --> string])
(declare fs.extension [string --> string])
(declare fs.resolve [string --> [io.result string]])
(declare fs.resolve-at [string --> [string --> [io.result string]]])
(declare fs.stat [string --> [io.result fs.info]])
(declare fs.lstat [string --> [io.result fs.info]])
(declare fs.exists? [string --> [io.result boolean]])
(declare fs.path [fs.info --> string])
(declare fs.kind [fs.info --> symbol])
(declare fs.size [fs.info --> number])
(declare fs.modified [fs.info --> [number * number]])
(declare fs.accessed [fs.info --> [number * number]])
(declare fs.list [string --> [[list fs.option] --> [io.result [list string]]]])
(declare fs.walk
  [string --> [[list fs.option] -->
    [[fs.info --> [number --> fs.visit]] --> [io.result [number * boolean]]]]])
(declare fs.mkdir [string --> io.close-result])
(declare fs.mkdirs [string --> io.close-result])
(declare fs.remove-file [string --> io.close-result])
(declare fs.remove-directory [string --> io.close-result])
(declare fs.rename [string --> [string --> io.close-result]])
(declare fs.replace [string --> [string --> io.close-result]])
(declare fs.temp-file [string --> [string --> [io.result [string * io.endpoint]]]])
(declare fs.temp-directory [string --> [string --> [io.result string]]])
(declare fs.with-temp-file
  [string --> [string --> [[string --> [io.endpoint --> [io.result A]]] --> [io.result A]]]])
(declare fs.with-replacement [string --> [[io.endpoint --> [io.result A]] --> [io.result A]]])
(declare fs.write-replace [string --> [buffer.view --> [io.result number]]])
(declare fs.copy-file [string --> [string --> [number --> [io.result number]]]])
