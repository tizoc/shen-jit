\\ Files as memory: lib/mmap.shen. Run by make test-ffi, from build/, after lib/ffi.shen, lib/mmap.shen
\\ and lib/handle.shen. It leaves its files in build/.

(set mmap-test.*passed* 0)
(set mmap-test.*failed* 0)

(define mmap-test.result
  F -> (trap-error (thaw F) (/. E [error (error-to-string E)])))

(define mmap-test.check
  Name Expected F -> (mmap-test.compare Name Expected (mmap-test.result F)))

(define mmap-test.compare
  _ X X -> (set mmap-test.*passed* (+ 1 (value mmap-test.*passed*)))
  Name Expected Got -> (do (output "FAIL ~A: expected ~S, got ~S~%" Name Expected Got)
                           (set mmap-test.*failed* (+ 1 (value mmap-test.*failed*)))))

(define mmap-test.prefix
  0 _ -> ""
  N S -> (cn (pos S 0) (mmap-test.prefix (- N 1) (tlstr S))))

(define mmap-test.string-length
  "" -> 0
  S -> (+ 1 (mmap-test.string-length (tlstr S))))

\\ That it raises, with a message starting so.
(define mmap-test.raises
  Name Start F -> (mmap-test.compare Name Start
                    (trap-error (do (thaw F) no-error)
                                (/. E (mmap-test.prefix (mmap-test.string-length Start) (error-to-string E))))))

\\ ---------------------------------------------------------------------------
\\ A static build cannot load libraries.

(if (= (mmap-test.result (freeze (mmap.read "mmap-test-missing.bin"))) [error "foreign: this static build cannot load libraries"])
    (do (output "1 passed, 0 failed (a static build)~%") (shen-jit.exit 0))
    skip)

\\ ---------------------------------------------------------------------------
\\ Files, written and read as Shen does.

(define mmap-test.write-bytes
  _ [] -> done
  S [B | Bs] -> (do (write-byte B S) (mmap-test.write-bytes S Bs)))

(define mmap-test.write-file
  Path Bytes -> (let S (open Path out)
                  (do (mmap-test.write-bytes S Bytes) (close S) Path)))

\\ ---------------------------------------------------------------------------
\\ Reading.

(set path (mmap-test.write-file "mmap-test.bin" [104 101 108 108 111 0 0 0 1 2 3 4]))
(set m (mmap.read (value path)))

(mmap-test.check "it is a pointer" true (freeze (shen-jit.pointer? (value m))))
(mmap-test.check "as long as the file" 12 (freeze (shen-jit.bytes-length (value m))))
(mmap-test.check "a byte" 104 (freeze (shen-jit.u8 (value m) 0)))
(mmap-test.check "the last byte" 4 (freeze (shen-jit.u8 (value m) 11)))
(mmap-test.check "a wider read" 67305985 (freeze (shen-jit.u32 (value m) 8)))
(mmap-test.check "as a string" "hello" (freeze (shen-jit.bytes->string (value m) 0 5)))
(mmap-test.raises "past its end" "bytes: 12" (freeze (shen-jit.u8 (value m) 12)))
(mmap-test.raises "over its end" "bytes: 9" (freeze (shen-jit.u32 (value m) 9)))
(mmap-test.check "copied out" "ell"
                 (freeze (shen-jit.bytes->string (shen-jit.copy-bytes (shen-jit.bytes 3) 0 (value m) 1 3) 0 3)))
(mmap-test.raises "a store raises" (make-string "bytes: ~S is read only" (value m)) (freeze (shen-jit.u8! (value m) 0 1)))
(mmap-test.check "and changes nothing" 104 (freeze (shen-jit.u8 (value m) 0)))
(mmap-test.check "close" true (freeze (mmap.close (value m))))
(mmap-test.raises "used after it" "bytes: 0" (freeze (shen-jit.u8 (value m) 0)))
(mmap-test.check "and has no length" 0 (freeze (shen-jit.bytes-length (value m))))
(mmap-test.raises "closed twice" "foreign: " (freeze (mmap.close (value m))))

\\ A file with a Ctrl-Z at its end keeps it, which Windows takes from a text file opened to write.
(set z (mmap.read-write (mmap-test.write-file "mmap-test-z.bin" [1 26])))
(mmap-test.check "a Ctrl-Z stays" 26 (freeze (shen-jit.u8 (value z) 1)))
(mmap.close (value z))

\\ ---------------------------------------------------------------------------
\\ Writing, seen by the file and by another mapping.

(set w (mmap.read-write (value path)))
(set r (mmap.read (value path)))
(shen-jit.u8! (value w) 0 72)
(mmap-test.check "another mapping sees it" 72 (freeze (shen-jit.u8 (value r) 0)))
(mmap.close (value r))
(mmap.close (value w))
(mmap-test.check "and so does the file" [72 101 108] (freeze (let Bytes (read-file-as-bytelist (value path))
                                                               [(hd Bytes) (hd (tl Bytes)) (hd (tl (tl Bytes)))])))

\\ ---------------------------------------------------------------------------
\\ Making a file.

(set new (mmap.create "mmap-test-new.bin" 1024))
(mmap-test.check "as long as asked" 1024 (freeze (shen-jit.bytes-length (value new))))
(mmap-test.check "all zero" 0 (freeze (shen-jit.u32 (value new) 1020)))
(shen-jit.f64! (value new) 1016 2.5)
(mmap.close (value new))

(set again (mmap.read "mmap-test-new.bin"))
(mmap-test.check "it is on the disk" 2.5 (freeze (shen-jit.f64 (value again) 1016)))
(mmap-test.check "at that length" 1024 (freeze (length (read-file-as-bytelist "mmap-test-new.bin"))))
(mmap.close (value again))

\\ On Windows, this also shows that closing let go of the file.
(set shorter (mmap.create "mmap-test-new.bin" 8))
(mmap-test.check "it replaces what was there" 8 (freeze (shen-jit.bytes-length (value shorter))))
(mmap-test.check "with zeroes" 0 (freeze (shen-jit.u32 (value shorter) 4)))
(mmap.close (value shorter))

\\ ---------------------------------------------------------------------------
\\ What it refuses. The system words the first, so only the start is the same everywhere.

(mmap-test.raises "no such file" "mmap: mmap-test-missing.bin: " (freeze (mmap.read "mmap-test-missing.bin")))
(mmap-test.raises "or to write" "mmap: mmap-test-missing.bin: " (freeze (mmap.read-write "mmap-test-missing.bin")))
(mmap-test.raises "a place it cannot make" "mmap: mmap-test-no-such-directory/new.bin: "
                  (freeze (mmap.create "mmap-test-no-such-directory/new.bin" 8)))

(mmap-test.write-file "mmap-test-empty.bin" [])
(mmap-test.raises "an empty file" "mmap: mmap-test-empty.bin is empty" (freeze (mmap.read "mmap-test-empty.bin")))
(mmap-test.raises "a length of none" "mmap: mmap-test-empty.bin: cannot make" (freeze (mmap.create "mmap-test-empty.bin" 0)))
(mmap-test.raises "a length that is not one" "mmap: mmap-test-empty.bin: cannot make" (freeze (mmap.create "mmap-test-empty.bin" a)))

\\ ---------------------------------------------------------------------------
\\ As a handle.

(set unmapped 0)

(define mmap-test.handle
  Path -> (handle.wrap (mmap.read Path) (/. M (do (set unmapped (+ 1 (value unmapped))) (mmap.close M)))))

\\ Made deep down, as tests/handle.shen explains.
(define mmap-test.deep
  0 F -> (thaw F)
  N F -> (let R (mmap-test.deep (- N 1) F)
           (if (= N -1) 0 R)))

(define mmap-test.drop
  Path -> (mmap-test.deep 30 (freeze (let H (mmap-test.handle Path)
                                       (do (shen-jit.u8 H 0) 0)))))

(set handle (mmap-test.handle (value path)))
(mmap-test.check "a handle reads the file" 72 (freeze (shen-jit.u8 (value handle) 0)))
(mmap-test.raises "and stays read only" "bytes: " (freeze (shen-jit.u8! (value handle) 0 1)))
(mmap-test.check "closing it" true (freeze (handle.close (value handle))))
(mmap-test.check "unmaps it" 1 (freeze (value unmapped)))

(mmap-test.drop (value path))
(shen-jit.collect)
(handle.sweep)
(shen-jit.collect)
(handle.sweep)
(mmap-test.check "and so does letting it go" 2 (freeze (value unmapped)))

\\ On Windows, this also shows that it let go of the file.
(mmap.close (mmap.create (value path) 4))
(mmap-test.check "which can then be replaced" 4 (freeze (length (read-file-as-bytelist (value path)))))

(mmap-test.check "a size that is a real leaves the file and closes what it opened"
  [true [1 2 3] true]
  (freeze
    (let Path (mmap-test.write-file "mmap-test-real-size.bin" [1 2 3])
         Before (mmap.open Path 0)
         _ (mmap.c-close Before)
         Raised (trap-error (do (mmap.create Path (+ 0.5 0.5)) false) (/. E true))
         After (mmap.open Path 0)
         _ (mmap.c-close After)
      [Raised (read-file-as-bytelist Path) (= Before After)])))

(if (mmap.windows?) skip
  (mmap-test.check "a failed unmap raises, and the pointer stays"
    [true true]
    (freeze
      (let M (mmap.create "mmap-test-unmap-error.bin" 8)
           P (shen-jit.pointer-sized M 0)
           Raised (trap-error (do (mmap.close P) false) (/. E true))
           Live (> (shen-jit.pointer-address P) 0)
           _ (shen-jit.pointer-kill P)
           _ (mmap.close M)
        [Raised Live]))))

(output "~A passed, ~A failed~%" (value mmap-test.*passed*) (value mmap-test.*failed*))
