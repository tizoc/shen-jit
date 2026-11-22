\\ Lexical path operations preserve .. and symlinks.
(shen.x.namespace fs
  (use buffer)
  (use io)
  (use shen-jit)
  (export extension join name parent)

(define checked
  {string --> string}
  Path ->
    (let _ (if (string? Path) true (error "fs: path must be a string"))
         B (shen-jit.string->bytes Path)
         N (shen-jit.bytes-length B)
         _ (if (and (fx> N 0) (fx<= N 1048576)) true (error "fs: path must contain 1..1048576 bytes"))
         _ (io.file-no-nul B 0 N)
      Path))

(define separator?
  {fixnum --> boolean}
  Byte -> (or (= Byte 47) (and (io.file-windows?) (= Byte 92))))

(define join
  {string --> string --> string}
  Base Path ->
    (let _ (checked Path)
         B (shen-jit.string->bytes Path)
         _ (if (string? Base) true (error "fs: base must be a string"))
      (if (or (= Base "") (io.file-absolute? B (shen-jit.bytes-length B)))
          Path
          (let _ (checked Base)
               A (shen-jit.string->bytes Base)
               N (shen-jit.bytes-length A)
            (cn Base (cn (if (separator? (shen-jit.u8 A (fx- N 1))) "" "/") Path))))))

(define next-separator
  {buffer.storage --> fixnum --> fixnum --> fixnum}
  _ At At -> At
  B At End ->
    (if (separator? (shen-jit.u8 B At))
        At
        (next-separator B (fx+ At 1) End)))

(define unc?
  {buffer.storage --> fixnum --> boolean}
  B N ->
    (and (io.file-windows?) (fx> N 1)
         (separator? (shen-jit.u8 B 0))
         (separator? (shen-jit.u8 B 1))))

(define extended-unc?
  {buffer.storage --> fixnum --> boolean}
  B N ->
    (and (unc? B N) (fx> N 7)
         (= (shen-jit.u8 B 2) 63)
         (separator? (shen-jit.u8 B 3))
         (element? (shen-jit.u8 B 4) [85 117])
         (element? (shen-jit.u8 B 5) [78 110])
         (element? (shen-jit.u8 B 6) [67 99])
         (separator? (shen-jit.u8 B 7))))

(define root-separators
  {buffer.storage --> fixnum --> fixnum --> fixnum}
  B At End ->
    (if (and (fx< At End) (separator? (shen-jit.u8 B At)))
        (root-separators B (fx+ At 1) End)
        At))

(define share-end
  {buffer.storage --> fixnum --> fixnum --> fixnum}
  B Start N ->
    (let Server (next-separator B Start N)
         Start-of-share (if (fx< Server N) (fx+ Server 1) N)
         Share (next-separator B Start-of-share N)
      (if (fx< Share N) (fx+ Share 1) Share)))

(define root-end
  {buffer.storage --> fixnum --> fixnum}
  B N ->
    (cases (extended-unc? B N) (share-end B 8 N)
           (unc? B N) (share-end B 2 N)
           (and (io.file-windows?) (fx> N 2)
                (= (shen-jit.u8 B 1) 58) (separator? (shen-jit.u8 B 2))) 3
           (separator? (shen-jit.u8 B 0)) (root-separators B 0 N)
           true 0))

(define trim-end
  {buffer.storage --> fixnum --> fixnum --> fixnum}
  B Root End ->
    (if (and (fx> End Root) (separator? (shen-jit.u8 B (fx- End 1))))
        (trim-end B Root (fx- End 1))
        End))

(define last-separator
  {buffer.storage --> fixnum --> fixnum --> fixnum}
  _ At 0 -> At
  B At End ->
    (let Next (fx- End 1)
      (if (separator? (shen-jit.u8 B Next))
          Next
          (last-separator B At Next))))

(define parts
  {string --> split}
  Path ->
    (let _ (checked Path)
         B (shen-jit.string->bytes Path)
         Root (root-end B (shen-jit.bytes-length B))
         End (trim-end B Root (shen-jit.bytes-length B))
         Slash (last-separator B -1 End)
      (:split bytes <- B root <- Root end <- End slash <- Slash)))

(define parent
  {string --> string}
  Path ->
    (let P (parts Path)
         B (split.bytes P)
         Root (split.root P)
         End (split.end P)
         Slash (split.slash P)
      (cases (fx<= End Root) (shen-jit.bytes->string B 0 Root)
             (fx< Slash 0) "."
             true (shen-jit.bytes->string B 0 (trim-end B Root (if (fx< Slash Root) Root Slash))))))

(define name
  {string --> string}
  Path ->
    (let P (parts Path)
         End (split.end P)
         At (fx+ (split.slash P) 1)
      (if (fx<= End (split.root P))
          ""
          (shen-jit.bytes->string (split.bytes P) At (fx- End At)))))

(define last-dot
  {buffer.storage --> fixnum --> fixnum --> fixnum}
  _ At 0 -> At
  B At End ->
    (let Next (fx- End 1)
      (if (= (shen-jit.u8 B Next) 46)
          Next
          (last-dot B At Next))))

(define extension
  {string --> string}
  Path ->
    (let B (shen-jit.string->bytes (name Path))
         N (shen-jit.bytes-length B)
         Dot (last-dot B -1 N)
      (if (or (fx<= Dot 0) (= Dot (fx- N 1)))
          ""
          (shen-jit.bytes->string B Dot (fx- N Dot)))))

)
