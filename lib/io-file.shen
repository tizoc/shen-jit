\\ Descriptor-backed files for lib/io.shen, over lib/ffi.shen. No kernel streams or FILE pointers.
\\ Load ffi.shen, buffer.shen, io.shen, then this file under (tc -).

(shen.x.namespace io
  (use buffer)
  (use shen-jit)
  (externals [blocking bytes crt define-foreign eof int32 int64 ok pointer posix read-write
    uint32 varargs win32 write written])
  (shadow file read-file)
  (export endpoint file-absolute? file-by-os file-c-close file-c-open file-error file-flags
    file-lib file-make file-native-name file-no-nul file-path-at file-win file-windows? let-ok
    open-file read-file result transfer-result with-input-file with-output-file write-file)

(shen-jit.library file-lib ["libc.so.6" "libSystem.dylib" "ucrtbase.dll"])
(shen-jit.library file-win ["kernel32.dll"])

(define file-windows?
  -> (= (value *os*) "Windows"))

(define file-by-os
  Linux Mac Windows ->
    (let OS (value *os*)
      (cond ((= OS "Linux") Linux)
            ((= OS "macOS") Mac)
            ((= OS "Windows") Windows)
            (true (error "io: unsupported OS ~A" OS)))))

(define-foreign file-c-open file-lib
  (if (file-windows?) "_wopen" "open")
  ((if (file-windows?) bytes string) int32 int32) --> int32 blocking (varargs 2))

(define-foreign file-c-read file-lib
  (if (file-windows?) "_read" "read")
  (int32 bytes (if (file-windows?) uint32 int64)) -->
  (if (file-windows?) int32 int64) blocking)

(define-foreign file-c-write file-lib
  (if (file-windows?) "_write" "write")
  (int32 bytes (if (file-windows?) uint32 int64)) -->
  (if (file-windows?) int32 int64) blocking)

(define-foreign file-c-close file-lib
  (if (file-windows?) "_close" "close")
  (int32) --> int32 blocking)

(define-foreign file-c-strerror file-lib "strerror" (int32) --> string)

(define-foreign file-wide-size file-win "MultiByteToWideChar"
  (int32 int32 string int32 pointer int32) --> int32)

(define-foreign file-wide-fill file-win "MultiByteToWideChar"
  (int32 int32 string int32 bytes int32) --> int32)

(define file-error
  Op Path Code ->
    (native-error Op (if (file-windows?) crt posix) Code Path (file-c-strerror Code)))

\\ Resolve paths here; the home-directory setting is not a dependency on kernel I/O helpers.
(define file-no-nul
  _ I I -> true
  B I End -> (if (= (shen-jit.u8 B I) 0)
                 (error "io: path contains NUL")
                 (file-no-nul B (+ I 1) End)))

(define file-absolute?
  B N ->
    (and (> N 0)
         (or (= (shen-jit.u8 B 0) 47)
             (and (file-windows?)
                  (or (= (shen-jit.u8 B 0) 92)
                      (and (> N 1) (= (shen-jit.u8 B 1) 58)))))))

(define file-path
  Path -> (file-path-at Path (value *home-directory*)))

(define file-path-at
  Path Home ->
    (let _ (if (string? Path) true (error "io: path must be a string"))
         B (shen-jit.string->bytes Path)
         N (shen-jit.bytes-length B)
         _ (if (> N 0) true (error "io: path is empty"))
         _ (file-no-nul B 0 N)
         _ (if (and (file-windows?) (and (> N 1) (= (shen-jit.u8 B 1) 58)))
               (if (and (> N 2) (element? (shen-jit.u8 B 2) [47 92]))
                   true
                   (error "io: Windows drive-relative paths are unsupported"))
               true)
      (if (or (file-absolute? B N) (= Home ""))
          Path
          (let H (shen-jit.string->bytes Home)
               Size (shen-jit.bytes-length H)
               _ (file-no-nul H 0 Size)
               HasSeparator (and (> Size 0)
                                 (or (= (shen-jit.u8 H (- Size 1)) 47)
                                     (and (file-windows?) (= (shen-jit.u8 H (- Size 1)) 92))))
            (cn Home (cn (if HasSeparator "" "/") Path))))))

\\ Linux/macOS: O_CLOEXEC; Windows: _O_BINARY | _O_NOINHERIT.
\\ Mode bits add access, creation, truncation or append; permissions are separate.
(define file-flags
  Mode ->
    (let Base (file-by-os 524288 16777216 32896)
      (+ Base (cond ((= Mode read) 0)
                    ((= Mode read-write) 2)
                    ((= Mode write) (file-by-os 577 1537 769))
                    ((= Mode append) (file-by-os 1089 521 265))
                    (true (error "io: file mode must be read, write, append or read-write"))))))

(define file-native-name
  Path ->
    (if (not (file-windows?))
        [ok Path]
        (let Size (file-wide-size 65001 8 Path -1 [] 0)
             Code (shen-jit.errno)
          (if (= Size 0)
              [error (native-error open win32 Code Path "invalid UTF-8 path")]
              (let Out (shen-jit.bytes (* Size 2))
                   N (file-wide-fill 65001 8 Path -1 Out Size)
                   Last (shen-jit.errno)
                (if (= N 0)
                    [error (native-error open win32 Last Path "path conversion failed")]
                    [ok Out]))))))

\\ A non-memory pointer stores fd+1 solely as a native-resource guard. It is never dereferenced
\\ or passed to C. Image loading clears it, so a saved descriptor cannot alias a new process's fd.
(define file-token
  Fd -> (shen-jit.bytes->pointer (shen-jit.u32! (shen-jit.bytes 8) 0 (+ Fd 1)) 0 file))

(define file-fd
  Token ->
    (let Address (shen-jit.pointer-address Token)
      (if (> Address 0) (- Address 1) (error "io: file endpoint is stale"))))

(define file-read
  Token Path Chunk ->
    (let N (file-c-read (file-fd Token) Chunk (shen-jit.bytes-length Chunk))
         Code (shen-jit.c-errno)
      (cond ((> N 0) [read N])
            ((= N 0) [eof])
            ((= Code 4) (file-read Token Path Chunk))
            (true [error (file-error read Path Code)]))))

(define file-write
  Token Path Chunk ->
    (let N (file-c-write (file-fd Token) Chunk (shen-jit.bytes-length Chunk))
         Code (shen-jit.c-errno)
      (cond ((>= N 0) [written N])
            ((= Code 4) (file-write Token Path Chunk))
            (true [error (file-error write Path Code)]))))

(define file-close
  Token Path ->
    (let Fd (file-fd Token)
         _ (shen-jit.pointer-kill Token)
         Result (file-c-close Fd)
         Code (shen-jit.c-errno)
      (if (= Result 0) [ok] [error (file-error close Path Code)])))

(define file-make
  Path Mode Fd ->
    (let Token (file-token Fd)
         E (endpoint Path (if (= Mode append) write Mode) 65536
                        (/. B (file-read Token Path B))
                        (/. B (file-write Token Path B))
                        (freeze (file-close Token Path)))
      (do (endpoint.guard-> E Token) E)))

(define open-file
  Path Mode ->
    (let Resolved (file-path Path)
         Flags (file-flags Mode)
      (trap-error
        (let-ok Native (file-native-name Resolved)
          (let Fd (file-c-open Native Flags (if (file-windows?) 384 438))
               Code (shen-jit.c-errno)
            (if (< Fd 0)
                [error (file-error open Resolved Code)]
                (shen-jit.on-error (freeze [ok (file-make Resolved Mode Fd)])
                                   (freeze (file-c-close Fd))))))
        (/. X [error (native-error open foreign 0 Resolved (error-to-string X))]))))

\\ File scopes share the core's result and cleanup policy.
(define with-input-file
  Path F -> (let-ok E (open-file Path read) (with-endpoint E F)))

(define with-output-file
  Path F -> (let-ok E (open-file Path write) (with-endpoint E F)))

(define read-file
  Path Limit ->
    (do (buffer.index Limit)
        (with-input-file Path (/. E (read-all (reader E []) Limit)))))

(define file-transfer-finish
  [ok N] [ok] -> [ok N]
  [ok N] [error Error] -> [error (progress Error N) N]
  [error Error N] [ok] -> [error Error N]
  [error Error N] [error Other] -> [error (secondary Error Other) N])

(define write-file-open
  _ [error Error] -> [error Error 0]
  V [ok E] ->
    (let Result (trap-error (write-all E V [])
                   (/. X (do (io.close E) (simple-error (error-to-string X)))))
      (file-transfer-finish Result (io.close E))))

(define write-file
  Path V -> (do (buffer.check V) (write-file-open V (open-file Path write))))

(declare open-file [string --> [symbol --> [result endpoint]]])
(declare with-input-file [string --> [[endpoint --> [result A]] --> [result A]]])
(declare with-output-file [string --> [[endpoint --> [result A]] --> [result A]]])
(declare read-file [string --> [number --> [result buffer.view]]])
(declare write-file [string --> [buffer.view --> transfer-result]])

)
