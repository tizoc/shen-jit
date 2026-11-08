\\ Descriptor-backed files for lib/io.shen, over lib/ffi.shen. No kernel streams or FILE pointers.
\\ Load ffi.shen, buffer.shen, io.shen, then this file under (tc -).

(shen-jit.library io.file-lib ["libc.so.6" "libSystem.dylib" "ucrtbase.dll"])
(shen-jit.library io.file-win ["kernel32.dll"])

(define io.file-windows?
  -> (= (value *os*) "Windows"))

(define io.file-by-os
  Linux Mac Windows ->
    (let OS (value *os*)
      (cond ((= OS "Linux") Linux)
            ((= OS "macOS") Mac)
            ((= OS "Windows") Windows)
            (true (error "io: unsupported OS ~A" OS)))))

(define-foreign io.file-c-open io.file-lib
  (if (io.file-windows?) "_wopen" "open")
  ((if (io.file-windows?) bytes string) int32 int32) --> int32 blocking (varargs 2))

(define-foreign io.file-c-read io.file-lib
  (if (io.file-windows?) "_read" "read")
  (int32 bytes (if (io.file-windows?) uint32 int64)) -->
  (if (io.file-windows?) int32 int64) blocking)

(define-foreign io.file-c-write io.file-lib
  (if (io.file-windows?) "_write" "write")
  (int32 bytes (if (io.file-windows?) uint32 int64)) -->
  (if (io.file-windows?) int32 int64) blocking)

(define-foreign io.file-c-close io.file-lib
  (if (io.file-windows?) "_close" "close")
  (int32) --> int32 blocking)

(define-foreign io.file-c-strerror io.file-lib "strerror" (int32) --> string)

(define-foreign io.file-wide-size io.file-win "MultiByteToWideChar"
  (int32 int32 string int32 pointer int32) --> int32)

(define-foreign io.file-wide-fill io.file-win "MultiByteToWideChar"
  (int32 int32 string int32 bytes int32) --> int32)

(define io.file-error
  Op Path Code ->
    (io.native-error Op (if (io.file-windows?) crt posix) Code Path (io.file-c-strerror Code)))

\\ Resolve paths here; the home-directory setting is not a dependency on kernel I/O helpers.
(define io.file-no-nul
  _ I I -> true
  B I End -> (if (= (shen-jit.u8 B I) 0)
                 (error "io: path contains NUL")
                 (io.file-no-nul B (+ I 1) End)))

(define io.file-absolute?
  B N ->
    (and (> N 0)
         (or (= (shen-jit.u8 B 0) 47)
             (and (io.file-windows?)
                  (or (= (shen-jit.u8 B 0) 92)
                      (and (> N 1) (= (shen-jit.u8 B 1) 58)))))))

(define io.file-path
  Path -> (io.file-path-at Path (value *home-directory*)))

(define io.file-path-at
  Path Home ->
    (let _ (if (string? Path) true (error "io: path must be a string"))
         B (shen-jit.string->bytes Path)
         N (shen-jit.bytes-length B)
         _ (if (> N 0) true (error "io: path is empty"))
         _ (io.file-no-nul B 0 N)
         _ (if (and (io.file-windows?) (and (> N 1) (= (shen-jit.u8 B 1) 58)))
               (if (and (> N 2) (element? (shen-jit.u8 B 2) [47 92]))
                   true
                   (error "io: Windows drive-relative paths are unsupported"))
               true)
      (if (or (io.file-absolute? B N) (= Home ""))
          Path
          (let H (shen-jit.string->bytes Home)
               Size (shen-jit.bytes-length H)
               _ (io.file-no-nul H 0 Size)
               HasSeparator (and (> Size 0)
                                 (or (= (shen-jit.u8 H (- Size 1)) 47)
                                     (and (io.file-windows?) (= (shen-jit.u8 H (- Size 1)) 92))))
            (cn Home (cn (if HasSeparator "" "/") Path))))))

\\ Linux/macOS: O_CLOEXEC; Windows: _O_BINARY | _O_NOINHERIT.
\\ Mode bits add access, creation, truncation or append; permissions are separate.
(define io.file-flags
  Mode ->
    (let Base (io.file-by-os 524288 16777216 32896)
      (+ Base (cond ((= Mode read) 0)
                    ((= Mode read-write) 2)
                    ((= Mode write) (io.file-by-os 577 1537 769))
                    ((= Mode append) (io.file-by-os 1089 521 265))
                    (true (error "io: file mode must be read, write, append or read-write"))))))

(define io.file-native-name
  Path ->
    (if (not (io.file-windows?))
        [ok Path]
        (let Size (io.file-wide-size 65001 8 Path -1 [] 0)
             Code (shen-jit.errno)
          (if (= Size 0)
              [error (io.native-error open win32 Code Path "invalid UTF-8 path")]
              (let Out (shen-jit.bytes (* Size 2))
                   N (io.file-wide-fill 65001 8 Path -1 Out Size)
                   Last (shen-jit.errno)
                (if (= N 0)
                    [error (io.native-error open win32 Last Path "path conversion failed")]
                    [ok Out]))))))

\\ A non-memory pointer stores fd+1 solely as a native-resource guard. It is never dereferenced
\\ or passed to C. Image loading clears it, so a saved descriptor cannot alias a new process's fd.
(define io.file-token
  Fd -> (shen-jit.bytes->pointer (shen-jit.u32! (shen-jit.bytes 8) 0 (+ Fd 1)) 0 io.file))

(define io.file-fd
  Token ->
    (let Address (shen-jit.pointer-address Token)
      (if (> Address 0) (- Address 1) (error "io: file endpoint is stale"))))

(define io.file-read
  Token Path Chunk ->
    (let N (io.file-c-read (io.file-fd Token) Chunk (shen-jit.bytes-length Chunk))
         Code (shen-jit.c-errno)
      (cond ((> N 0) [read N])
            ((= N 0) [eof])
            ((= Code 4) (io.file-read Token Path Chunk))
            (true [error (io.file-error read Path Code)]))))

(define io.file-write
  Token Path Chunk ->
    (let N (io.file-c-write (io.file-fd Token) Chunk (shen-jit.bytes-length Chunk))
         Code (shen-jit.c-errno)
      (cond ((>= N 0) [written N])
            ((= Code 4) (io.file-write Token Path Chunk))
            (true [error (io.file-error write Path Code)]))))

(define io.file-close
  Token Path ->
    (let Fd (io.file-fd Token)
         _ (shen-jit.pointer-kill Token)
         Result (io.file-c-close Fd)
         Code (shen-jit.c-errno)
      (if (= Result 0) [ok] [error (io.file-error close Path Code)])))

(define io.file-make
  Path Mode Fd ->
    (let Token (io.file-token Fd)
         E (io.endpoint Path (if (= Mode append) write Mode) 65536
                        (/. B (io.file-read Token Path B))
                        (/. B (io.file-write Token Path B))
                        (freeze (io.file-close Token Path)))
      (do (address-> E 12 Token) E)))

(define io.open-file
  Path Mode ->
    (let Resolved (io.file-path Path)
         Flags (io.file-flags Mode)
      (trap-error
        (io.let-ok Native (io.file-native-name Resolved)
          (let Fd (io.file-c-open Native Flags (if (io.file-windows?) 384 438))
               Code (shen-jit.c-errno)
            (if (< Fd 0)
                [error (io.file-error open Resolved Code)]
                (trap-error [ok (io.file-make Resolved Mode Fd)]
                  (/. X (do (io.file-c-close Fd) (simple-error (error-to-string X))))))))
        (/. X [error (io.native-error open foreign 0 Resolved (error-to-string X))]))))

\\ File scopes share the core's result and cleanup policy.
(define io.with-input-file
  Path F -> (io.let-ok E (io.open-file Path read) (io.with-endpoint E F)))

(define io.with-output-file
  Path F -> (io.let-ok E (io.open-file Path write) (io.with-endpoint E F)))

(define io.read-file
  Path Limit ->
    (do (buffer.index Limit)
        (io.with-input-file Path (/. E (io.read-all (io.reader E []) Limit)))))

(define io.file-transfer-finish
  [ok N] [ok] -> [ok N]
  [ok N] [error Error] -> [error (io.progress Error N) N]
  [error Error N] [ok] -> [error Error N]
  [error Error N] [error Other] -> [error (io.secondary Error Other) N])

(define io.write-file-open
  _ [error Error] -> [error Error 0]
  V [ok E] ->
    (let Result (trap-error (io.write-all E V [])
                   (/. X (do (io.close E) (simple-error (error-to-string X)))))
      (io.file-transfer-finish Result (io.close E))))

(define io.write-file
  Path V -> (do (buffer.check V) (io.write-file-open V (io.open-file Path write))))

(declare io.open-file [string --> [symbol --> [io.result io.endpoint]]])
(declare io.with-input-file [string --> [[io.endpoint --> [io.result A]] --> [io.result A]]])
(declare io.with-output-file [string --> [[io.endpoint --> [io.result A]] --> [io.result A]]])
(declare io.read-file [string --> [number --> [io.result buffer.view]]])
(declare io.write-file [string --> [buffer.view --> io.transfer-result]])
