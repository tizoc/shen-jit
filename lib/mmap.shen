\\ Files as memory, over the FFI and with no C of their own. It stays out of the image until asked
\\ for; load it after lib/ffi.shen, under (tc -), before the code using it:
\\
\\   shen-jit eval -l lib/ffi.shen -l lib/mmap.shen -l program.shen
\\
\\ (let M (mmap.read "data.bin")
\\   (do (output "~A bytes, starting ~A~%" (shen-jit.bytes-length M) (shen-jit.u8 M 0))
\\       (mmap.close M)))
\\
\\   (mmap.read Path)        all of a file, as a pointer with a length, read only
\\   (mmap.read-write Path)  all of a file, where what is written reaches the file
\\   (mmap.create Path N)    a new file of N zero bytes, replacing any there, as mmap.read-write
\\   (mmap.close M)          unmaps it and kills M, so that using it again raises. A copy of M from
\\                           shen-jit.pointer-sized is not killed with it, and must not be used.
\\
\\ What reads a byte buffer reads the result, each access checked against the length, and nothing
\\ is read from the file until it is touched. An empty file cannot be mapped, and raises. Errors
\\ raise, with the system's message or, for the mapping itself on Windows, its number.
\\
\\ A store into what mmap.read gives raises. One thing no check can catch ends the process: an
\\ access past the end of a file that something has since made shorter.
\\
\\ It stays mapped until mmap.close, or the end of the process. lib/handle.shen closes it once nothing
\\ reaches it: (handle.wrap (mmap.read Path) (/. M (mmap.close M))).
\\
\\ Windows opens files through its C library too, under its own names, and differs only in the
\\ mapping. Functions are found at their first call, so a system declares what it never calls
\\ without harm.

(shen.x.namespace mmap
  (use shen-jit)
  (externals [define-foreign int32 int64 pointer])
  (shadow close fail map open read)
  (export close create read read-write)

(shen-jit.library lib ["libc.so.6" "libSystem.dylib" "ucrtbase.dll"])
(shen-jit.library kernel32 ["kernel32.dll"])

(define windows?
  -> (= (value *os*) "Windows"))

(define-foreign c-open lib (if (windows?) "_open" "open") (string int32) --> int32)
(define-foreign c-creat lib (if (windows?) "_creat" "creat") (string int32) --> int32)
(define-foreign c-close lib (if (windows?) "_close" "close") (int32) --> int32)
(define-foreign c-lseek lib (if (windows?) "_lseeki64" "lseek") (int32 int64 int32) --> int64)
(define-foreign c-truncate lib (if (windows?) "_chsize_s" "ftruncate") (int32 int64) --> int32)
(define-foreign c-strerror lib "strerror" (int32) --> string)

(define-foreign c-mmap lib "mmap" (pointer int64 int32 int32 int32 int64) --> pointer)
(define-foreign c-munmap lib "munmap" (pointer int64) --> int32)

(define-foreign c-osfhandle lib "_get_osfhandle" (int32) --> int64)
(define-foreign c-create-mapping kernel32 "CreateFileMappingA" (int64 pointer int32 int32 int32 pointer) --> int64)
(define-foreign c-map-view kernel32 "MapViewOfFile" (int64 int32 int32 int32 int64) --> pointer)
(define-foreign c-unmap-view kernel32 "UnmapViewOfFile" (pointer) --> int32)
(define-foreign c-close-handle kernel32 "CloseHandle" (int64) --> int32)

(define fail
  Path -> (raise Path (shen-jit.c-errno)))

(define raise
  Path Code -> (error "mmap: ~A: ~A" Path (c-strerror Code)))

\\ ---------------------------------------------------------------------------
\\ The mapping. O_RDONLY is 0 and O_RDWR is 2 on every system. Windows also needs _O_BINARY, as it
\\ would otherwise take a Ctrl-Z off the end of a file opened to write.

(define open
  Path Flags -> (c-open Path (if (windows?) (+ Flags 32768) Flags)))

(define read
  Path -> (map Path (open Path 0) false))

(define read-write
  Path -> (map Path (open Path 2) true))

\\ creat gives a descriptor that cannot read, which a mapping needs, so it is opened again. The size
\\ is checked first, as a fixnum: integer? holds for 1.0 too, which the call refuses after creat has
\\ emptied the file.
(define create
  Path N -> (error "mmap: ~A: cannot make a file of ~A bytes" Path N) where (not (and (fixnum? N) (> N 0)))
  Path N -> (let Fd (c-creat Path (if (windows?) 384 420))
              (if (< Fd 0)
                  (fail Path)
                  (do (c-close Fd)
                      (map-sized Path (open Path 2) N)))))

\\ Bit operations take only fixnums, and a real may have no fraction.
(define fixnum?
  V -> (trap-error (= V (shen-jit.bit-or V 0)) (/. E false)))

(define map-sized
  Path Fd _ -> (fail Path) where (< Fd 0)
  Path Fd N -> (if (= 0 (c-truncate Fd N))
                   (map Path Fd true)
                   (let Code (shen-jit.c-errno)
                     (do (c-close Fd) (raise Path Code)))))

\\ The descriptor is closed either way: a mapping does not need it.
(define map
  Path Fd _ -> (fail Path) where (< Fd 0)
  Path Fd Write -> (shen-jit.finally (freeze (map-open Path Fd Write)) (freeze (c-close Fd))))

(define map-open
  Path Fd Write -> (let Length (c-lseek Fd 0 2)
                     (cases (< Length 0) (fail Path)
                            (= Length 0) (error "mmap: ~A is empty, and cannot be mapped" Path)
                            true (access (shen-jit.pointer-sized (view Path Fd Length Write) Length) Write))))

(define access
  M true -> M
  M false -> (shen-jit.pointer-read-only M))

(define view
  Path Fd Length Write -> (if (windows?)
                              (windows-view Path Fd Write)
                              (posix-view Path Fd Length Write)))

\\ PROT_READ is 1, PROT_WRITE is 2, and MAP_SHARED is 1. MAP_FAILED is all ones.
(define posix-view
  Path Fd Length Write -> (let P (c-mmap [] Length (if Write 3 1) 1 Fd 0)
                            (if (= (shen-jit.pointer-address P) -1)
                                (fail Path)
                                P)))

\\ PAGE_READWRITE is 4 and PAGE_READONLY is 2; FILE_MAP_WRITE is 2 and FILE_MAP_READ is 4. A view
\\ keeps its mapping, and sizes of 0 mean all of the file.
(define windows-view
  Path Fd Write -> (let Mapping (c-create-mapping (c-osfhandle Fd) [] (if Write 4 2) 0 0 [])
                     (if (= Mapping 0)
                         (windows-fail Path (shen-jit.errno))
                         (let View (c-map-view Mapping (if Write 2 4) 0 0 0)
                              Code (shen-jit.errno)
                              _ (c-close-handle Mapping)
                           (if (empty? View)
                               (windows-fail Path Code)
                               View)))))

(define windows-fail
  Path Code -> (error "mmap: ~A: error ~A" Path Code))

\\ ---------------------------------------------------------------------------
\\ Closing.

\\ The pointer dies only once its memory has gone back; otherwise this raises, and it stays.
(define close
  M -> (if (= 0 (c-unmap-view M))
           (error "mmap: cannot unmap: error ~A" (shen-jit.errno))
           (closed M))
      where (windows?)
  M -> (if (= 0 (c-munmap M (shen-jit.bytes-length M)))
           (closed M)
           (error "mmap: cannot unmap: ~A" (c-strerror (shen-jit.c-errno)))))

(define closed
  M -> (do (shen-jit.pointer-kill M) true))

)
