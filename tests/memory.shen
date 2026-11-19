\\ Memory outside the Shen heap: pointers with a length, and lib/memory.shen, against
\\ tests/ffi_lib.c. Run by make test-ffi, from build/, after lib/ffi.shen, lib/native.shen and
\\ lib/memory.shen: a macro applies only to files read after it is defined.

(set memory-test.*passed* 0)
(set memory-test.*failed* 0)

(define memory-test.result
  F -> (trap-error (thaw F) (/. E [error (error-to-string E)])))

(define memory-test.check
  Name Expected F -> (memory-test.compare Name Expected (memory-test.result F)))

(define memory-test.compare
  _ X X -> (set memory-test.*passed* (+ 1 (value memory-test.*passed*)))
  Name Expected Got -> (do (output "FAIL ~A: expected ~S, got ~S~%" Name Expected Got)
                           (set memory-test.*failed* (+ 1 (value memory-test.*failed*)))))

(define memory-test.prefix
  0 _ -> ""
  N S -> (cn (pos S 0) (memory-test.prefix (- N 1) (tlstr S))))

\\ That it raises, with a message starting so.
(define memory-test.raises
  Name Start F -> (memory-test.compare Name Start
                    (trap-error (do (thaw F) no-error)
                                (/. E (memory-test.prefix (string-length Start) (error-to-string E))))))

(define string-length
  "" -> 0
  S -> (+ 1 (string-length (tlstr S))))

\\ ---------------------------------------------------------------------------
\\ A static build cannot load libraries, and so has no memory from C.

(if (= (memory-test.result (freeze (memory.alloc 8))) [error "foreign: this static build cannot load libraries"])
    (do (output "1 passed, 0 failed (a static build)~%") (shen-jit.exit 0))
    skip)

(shen-jit.library t ["./ffi_test.so" "ffi_test.dll"])

\\ ---------------------------------------------------------------------------
\\ Each width, read and written, in memory from lib/memory.shen.

(set m (memory.alloc 16))

(memory-test.check "a block is a pointer" true (freeze (shen-jit.pointer? (value m))))
(memory-test.check "not a byte buffer" false (freeze (shen-jit.bytes? (value m))))
(memory-test.check "its length" 16 (freeze (shen-jit.bytes-length (value m))))
(memory-test.check "all zero" 0 (freeze (shen-jit.u32 (value m) 12)))

(memory-test.check "u8" 200 (freeze (shen-jit.u8 (shen-jit.u8! (value m) 0 200) 0)))
(memory-test.check "u16" 60000 (freeze (shen-jit.u16 (shen-jit.u16! (value m) 0 60000) 0)))
(memory-test.check "u32" 4000000000 (freeze (shen-jit.u32 (shen-jit.u32! (value m) 0 4000000000) 0)))
(memory-test.check "s32" -7 (freeze (shen-jit.s32 (shen-jit.s32! (value m) 0 -7) 0)))
(memory-test.check "s32 as u32" 4294967289 (freeze (shen-jit.u32 (value m) 0)))
(memory-test.check "s64" -9 (freeze (shen-jit.s64 (shen-jit.s64! (value m) 0 -9) 0)))
(memory-test.check "f32" -2.25 (freeze (shen-jit.f32 (shen-jit.f32! (value m) 0 -2.25) 0)))
(memory-test.check "f64" 1.5 (freeze (shen-jit.f64 (shen-jit.f64! (value m) 8 1.5) 8)))
(memory-test.check "f64 from an integer" 3 (freeze (shen-jit.f64 (shen-jit.f64! (value m) 8 3) 8)))
(memory-test.check "a store gives what it stored into" true (freeze (= (shen-jit.u8! (value m) 0 1) (value m))))
(memory-test.check "little-endian" 1 (freeze (shen-jit.u8 (shen-jit.u32! (value m) 0 1) 0)))

\\ Bounds, at each end and for each way of reading.
(shen-jit.f64! (value m) 8 0)
(memory-test.raises "u8 past the end" "bytes: 16" (freeze (shen-jit.u8 (value m) 16)))
(memory-test.check "the last u8" 0 (freeze (shen-jit.u8 (value m) 15)))
(memory-test.raises "u32 over the end" "bytes: 13" (freeze (shen-jit.u32 (value m) 13)))
(memory-test.check "the last u32" 0 (freeze (shen-jit.u32 (value m) 12)))
(memory-test.raises "s32 over the end" "bytes: 13" (freeze (shen-jit.s32 (value m) 13)))
(memory-test.raises "s64 over the end" "bytes: 9" (freeze (shen-jit.s64 (value m) 9)))
(memory-test.raises "f64 over the end" "bytes: 9" (freeze (shen-jit.f64 (value m) 9)))
(memory-test.raises "a store past the end" "bytes: 16" (freeze (shen-jit.u8! (value m) 16 1)))
(memory-test.raises "a negative index" "bytes: -1" (freeze (shen-jit.u8 (value m) -1)))
(memory-test.raises "an index that is not one" "bytes: a" (freeze (shen-jit.u8 (value m) a)))
(memory-test.raises "too big for u8" "bytes: 256" (freeze (shen-jit.u8! (value m) 0 256)))
(memory-test.raises "too big for s32" "bytes: 2147483648" (freeze (shen-jit.s32! (value m) 0 2147483648)))
(memory-test.raises "not a number" "bytes: a" (freeze (shen-jit.f64! (value m) 0 a)))
(memory-test.raises "s64 past a fixnum" "shen-jit.s64: "
  (freeze (shen-jit.s64 (shen-jit.u32! (shen-jit.u32! (value m) 0 4294967295) 4 2147483647) 0)))

\\ ---------------------------------------------------------------------------
\\ The same compiled code on a buffer, on a pointer, and on neither, in either order.

(define memory-test.read M I -> (shen-jit.u32 M I))
(define memory-test.read-s32 M I -> (shen-jit.s32 M I))
(define memory-test.write M I X -> (shen-jit.u16! M I X))
(define memory-test.length M -> (shen-jit.bytes-length M))

(set b (shen-jit.bytes 8))
(shen-jit.u32! (value b) 4 77)
(shen-jit.u32! (value m) 4 88)
(memory-test.check "compiled, a buffer" 77 (freeze (memory-test.read (value b) 4)))
(memory-test.check "compiled, a pointer" 88 (freeze (memory-test.read (value m) 4)))
(memory-test.check "compiled, a buffer again" 77 (freeze (memory-test.read (value b) 4)))
(memory-test.raises "compiled, neither" "bytes: " (freeze (memory-test.read "abc" 0)))
(memory-test.raises "compiled, past a pointer's end" "bytes: 16" (freeze (memory-test.read (value m) 16)))
(memory-test.check "compiled, a store to a buffer" 5 (freeze (shen-jit.u16 (memory-test.write (value b) 0 5) 0)))
(memory-test.check "compiled, a store to a pointer" 6 (freeze (shen-jit.u16 (memory-test.write (value m) 0 6) 0)))
(memory-test.check "compiled, length of a buffer" 8 (freeze (memory-test.length (value b))))
(memory-test.check "compiled, length of a pointer" 16 (freeze (memory-test.length (value m))))
(shen-jit.s32! (value m) 0 -3)
(memory-test.check "compiled, s32 on a pointer" -3 (freeze (memory-test.read-s32 (value m) 0)))
(shen-jit.s32! (value b) 0 -4)
(memory-test.check "compiled, s32 on a buffer" -4 (freeze (memory-test.read-s32 (value b) 0)))

\\ f64 allocates where it reads: on each, with room and without, for which GC stress leaves little.
(define memory-test.sum-f64
  M I N Acc -> Acc where (>= I N)
  M I N Acc -> (memory-test.sum-f64 M (+ I 8) N (+ Acc (shen-jit.f64 M I))))

(define memory-test.sum-f64-times
  0 _ _ Acc -> Acc
  R M N Acc -> (memory-test.sum-f64-times (- R 1) M N (memory-test.sum-f64 M 0 N Acc)))

(set floats (memory.alloc 16))
(shen-jit.f64! (value floats) 0 1.5)
(shen-jit.f64! (value floats) 8 2.5)
(set bfloats (shen-jit.bytes 16))
(shen-jit.f64! (value bfloats) 0 0.5)
(shen-jit.f64! (value bfloats) 8 1.5)
(memory-test.check "f64 across collections, on a pointer" 40000 (freeze (memory-test.sum-f64-times 10000 (value floats) 16 0)))
(memory-test.check "f64 across collections, on a buffer" 20000 (freeze (memory-test.sum-f64-times 10000 (value bfloats) 16 0)))

\\ Read only: reads as it did, and every way of storing raises, inline or not, and in a copy.
(define memory-test.store-u8 M I X -> (shen-jit.u8! M I X))
(define memory-test.store-u32 M I X -> (shen-jit.u32! M I X))
(define memory-test.store-f64 M I X -> (shen-jit.f64! M I X))

(set fixed (memory.alloc 16))
(shen-jit.u32! (value fixed) 0 88)
(shen-jit.f64! (value fixed) 8 1.5)
(set ro (shen-jit.pointer-read-only (value fixed)))
(memory-test.check "read only, the same memory" 88 (freeze (memory-test.read (value ro) 0)))
(memory-test.check "and its length" 16 (freeze (memory-test.length (value ro))))
(memory-test.check "and as a float" 1.5 (freeze (shen-jit.f64 (value ro) 8)))
(memory-test.check "the pointer it came from stays writable" 9 (freeze (shen-jit.u8 (memory-test.store-u8 (value fixed) 1 9) 1)))
(memory-test.check "which it sees" 9 (freeze (shen-jit.u8 (value ro) 1)))
(memory-test.raises "u8!, compiled" "bytes: " (freeze (memory-test.store-u8 (value ro) 0 1)))
(memory-test.raises "u32!, compiled" "bytes: " (freeze (memory-test.store-u32 (value ro) 0 1)))
(memory-test.raises "f64!, compiled" "bytes: " (freeze (memory-test.store-f64 (value ro) 0 1.5)))
(memory-test.raises "s32!" "bytes: " (freeze (shen-jit.s32! (value ro) 0 1)))
(memory-test.raises "s64!" "bytes: " (freeze (shen-jit.s64! (value ro) 0 1)))
(memory-test.raises "f32!" "bytes: " (freeze (shen-jit.f32! (value ro) 0 1.5)))
(memory-test.raises "a copy into it" "bytes: " (freeze (shen-jit.copy-bytes (value ro) 0 (value fixed) 0 1)))
(memory-test.raises "a pointer field" "shen-jit.pointer!: " (freeze (shen-jit.pointer! (value ro) 0 [])))
(memory-test.raises "and says so" (make-string "bytes: ~S is read only" (value ro)) (freeze (memory-test.store-u8 (value ro) 0 1)))
(memory-test.check "copying out of it is fine" 88 (freeze (shen-jit.u8 (shen-jit.copy-bytes (shen-jit.bytes 4) 0 (value ro) 0 4) 0)))
(memory-test.raises "a sized copy is too" "bytes: " (freeze (memory-test.store-u8 (shen-jit.pointer-sized (value ro) 8) 0 1)))
(memory-test.raises "and a guarded one" "bytes: " (freeze (memory-test.store-u8 (shen-jit.pointer-guard (value ro) r) 0 1)))
(memory-test.check "a store to a writable one, compiled the same" 7 (freeze (shen-jit.u8 (memory-test.store-u8 (value fixed) 2 7) 2)))
(memory-test.check "a store to a buffer, compiled the same" 7 (freeze (shen-jit.u8 (memory-test.store-u8 (shen-jit.bytes 4) 2 7) 2)))
(memory-test.check "f64! to a writable one" 2.5 (freeze (shen-jit.f64 (memory-test.store-f64 (value fixed) 8 2.5) 8)))
(memory-test.check "f64! of an integer" 4 (freeze (shen-jit.f64 (memory-test.store-f64 (value fixed) 8 4) 8)))
(memory-test.check "f64! to a buffer" 2.5 (freeze (shen-jit.f64 (memory-test.store-f64 (shen-jit.bytes 8) 0 2.5) 0)))
(memory-test.raises "f64! past the end" "bytes: 9" (freeze (memory-test.store-f64 (value fixed) 9 2.5)))
(memory-test.raises "f64! of what is no number" "bytes: a" (freeze (memory-test.store-f64 (value fixed) 8 a)))

\\ Float registers, on either kind of memory.
(define-native memory-test.float-double (From To I End)
  (prim T >= I End)
  (jump-if-false T more)
  (return To)
  (label more)
  (f64! To I (* 2 (f64 From I)))
  (prim I + I 8)
  (tail-call memory-test.float-double From To I End))

(set doubled (memory.alloc 16))
(shen-jit.f64! (value fixed) 8 1.5)
(memory-test.check "pointer to pointer, in registers" 3 (freeze (shen-jit.f64 (memory-test.float-double (value fixed) (value doubled) 8 16) 8)))
(memory-test.check "pointer to buffer" 3 (freeze (shen-jit.f64 (memory-test.float-double (value fixed) (shen-jit.bytes 16) 8 16) 8)))
(memory-test.check "read only to pointer" 3 (freeze (shen-jit.f64 (memory-test.float-double (value ro) (value doubled) 8 16) 8)))
(memory-test.raises "a store to one read only raises" "bytes: " (freeze (memory-test.float-double (value fixed) (value ro) 8 16)))
(memory-test.raises "and past the end" "bytes: 16" (freeze (memory-test.float-double (value fixed) (value doubled) 16 24)))

\\ One width through a pointer makes its length a limit, and one read only has none to store by.
(define-native memory-test.limit-load (M I0 N0)
  (word I I0)
  (word N N0)
  (loop top)
  (jump-unless-word (> N 0) done)
  (float X (f64 M I))
  (word N (- N 1))
  (again top)
  (label done)
  (return-word N))
(define-native memory-test.limit-store (M I0 N0)
  (word I I0)
  (word N N0)
  (loop top)
  (jump-unless-word (> N 0) done)
  (f64! M I 1.5)
  (word N (- N 1))
  (again top)
  (label done)
  (return-word N))
(memory-test.check "one width, the last index with room" 0 (freeze (memory-test.limit-load (value fixed) 8 2)))
(memory-test.raises "and not one past it" "bytes: 9" (freeze (memory-test.limit-load (value fixed) 9 2)))
(memory-test.check "the same to store" 0 (freeze (memory-test.limit-store (value doubled) 8 2)))
(memory-test.raises "and not one past it" "bytes: 9" (freeze (memory-test.limit-store (value doubled) 9 2)))
(memory-test.check "read only reads" 0 (freeze (memory-test.limit-load (value ro) 8 2)))
(memory-test.raises "and does not store" (make-string "bytes: ~S is read only" (value ro)) (freeze (memory-test.limit-store (value ro) 0 1)))

(memory.free (value doubled))
(memory-test.raises "as a dead pointer does" "bytes: 0" (freeze (memory-test.float-double (value fixed) (value doubled) 0 8)))
(memory-test.raises "with one width as well" "bytes: 0" (freeze (memory-test.limit-load (value doubled) 0 1)))
(memory.free (value fixed))

\\ A loop works out its memory on the way in, so it must see what C did since.
(define memory-test.kill-then-read
  M 0 Acc -> Acc
  M 1 Acc -> (let K (shen-jit.pointer-kill M) (memory-test.kill-then-read M 0 (+ Acc (shen-jit.u8 M 0))))
  M N Acc -> (memory-test.kill-then-read M (- N 1) (+ Acc (shen-jit.u8 M 0))))

(set killable (memory.alloc 8))
(memory-test.check "read round a loop" 0 (freeze (memory-test.kill-then-read (value killable) 0 0)))
(memory-test.raises "killed during a loop" "bytes: 0"
                    (freeze (memory-test.kill-then-read (shen-jit.pointer-sized (value killable) 8) 3 0)))

(define memory-test.store-round
  M I N -> M where (>= I N)
  M I N -> (memory-test.store-round (shen-jit.u8! M I 1) (+ I 1) N))
(memory-test.check "stores round a loop" 1 (freeze (shen-jit.u8 (memory-test.store-round (value killable) 0 8) 7)))
(memory-test.raises "and refused on one read only" "bytes: "
                    (freeze (memory-test.store-round (shen-jit.pointer-read-only (value killable)) 0 8)))

(define-native memory-test.word-store-round (M N)
  (word I 0)
  (loop top)
  (jump-unless-word (< I N) done)
  (u8! M I 9)
  (word I (+ I 1))
  (again top)
  (label done)
  (return M))
(memory-test.check "in word registers" 9 (freeze (shen-jit.u8 (memory-test.word-store-round (value killable) 8) 7)))
(memory-test.raises "read only, in word registers" "bytes: "
                    (freeze (memory-test.word-store-round (shen-jit.pointer-read-only (value killable)) 8)))
(memory-test.raises "and past its end" "bytes: 8" (freeze (memory-test.word-store-round (value killable) 9)))
(memory.free (value killable))
(memory-test.raises "and on one freed" "bytes: 0" (freeze (memory-test.word-store-round (value killable) 8)))

\\ Native code written by hand reads it as it reads a buffer.
(define-native memory-test.sum-u32 (M I N Acc)
  (prim Done >= I N)
  (jump-if-false Done more)
  (return Acc)
  (label more)
  (prim X shen-jit.u32 M I)
  (prim Acc + Acc X)
  (prim I + I 4)
  (tail-call memory-test.sum-u32 M I N Acc))

(set sums (memory.alloc 8))
(shen-jit.u32! (value sums) 0 10)
(shen-jit.u32! (value sums) 4 32)
(memory-test.check "native code on a pointer" 42 (freeze (memory-test.sum-u32 (value sums) 0 8 0)))
(memory-test.raises "native code past the end" "bytes: 8" (freeze (memory-test.sum-u32 (value sums) 0 12 0)))
(set bsums (shen-jit.bytes 8))
(shen-jit.u32! (value bsums) 0 40)
(shen-jit.u32! (value bsums) 4 2)
(memory-test.check "native code on a buffer" 42 (freeze (memory-test.sum-u32 (value bsums) 0 8 0)))

\\ ---------------------------------------------------------------------------
\\ Between buffers and pointers.

(set text (memory.alloc 5))
(shen-jit.copy-bytes (value text) 0 (shen-jit.string->bytes "hello") 0 5)
(memory-test.check "copied in, and read as a string" "hello" (freeze (shen-jit.bytes->string (value text) 0 5)))
(memory-test.check "part of it" "ell" (freeze (shen-jit.bytes->string (value text) 1 3)))
(memory-test.check "copied out" "hel"
                   (freeze (shen-jit.bytes->string (shen-jit.copy-bytes (shen-jit.bytes 3) 0 (value text) 0 3) 0 3)))
(memory-test.check "overlapping, within it" "hehlo"
                   (freeze (do (shen-jit.copy-bytes (value text) 2 (value text) 0 1)
                               (shen-jit.copy-bytes (value text) 2 (value text) 0 1)
                               (shen-jit.u8! (value text) 2 104)
                               (shen-jit.bytes->string (value text) 0 5))))
(memory-test.raises "a string past the end" "shen-jit.bytes->string: " (freeze (shen-jit.bytes->string (value text) 1 5)))
(memory-test.raises "a copy past the end" "shen-jit.copy-bytes: " (freeze (shen-jit.copy-bytes (value text) 1 (value text) 0 5)))

\\ ---------------------------------------------------------------------------
\\ Memory that C owns: a struct read and written in place.
\\ struct point { double x, y; int32_t id; };   24 bytes

(define-foreign make-points t "make_points" (int32) --> pointer)
(define-foreign sum-x t "sum_x" (pointer int32) --> double)
(define-foreign free-points t "free_points" (pointer) --> void)

(define point-x M I -> (shen-jit.f64 M (* I 24)))
(define set-point-x M I X -> (shen-jit.f64! M (* I 24) X))
(define point-id M I -> (shen-jit.s32 M (+ (* I 24) 16)))

(set p (make-points 3))
(memory-test.raises "a bare pointer cannot be read" "bytes: 0" (freeze (shen-jit.u8 (value p) 0)))
(memory-test.check "a bare pointer has no length" 0 (freeze (shen-jit.bytes-length (value p))))
(set points (shen-jit.pointer-sized (value p) 72))
(memory-test.check "keeps its kind" true (freeze (= (shen-jit.pointer-kind (value points)) (shen-jit.pointer-kind (value p)))))
(memory-test.check "keeps its address" true (freeze (= (shen-jit.pointer-address (value points)) (shen-jit.pointer-address (value p)))))
(memory-test.check "the pointer given stays bare" 0 (freeze (shen-jit.bytes-length (value p))))
(memory-test.check "read a C double" 1.5 (freeze (point-x (value points) 1)))
(memory-test.check "read a negative C int" -1 (freeze (point-id (value points) 0)))
(memory-test.check "and another" 1 (freeze (point-id (value points) 2)))
(memory-test.check "C sees what Shen writes" 12 (freeze (do (set-point-x (value points) 0 8) (sum-x (value points) 3))))
(memory-test.raises "the length stated is the limit" "bytes: 72" (freeze (shen-jit.u8 (value points) 72)))

(memory-test.raises "not a pointer" "shen-jit.pointer-sized: 1" (freeze (shen-jit.pointer-sized 1 8)))
(memory-test.raises "a buffer is not one" "shen-jit.pointer-sized: " (freeze (shen-jit.pointer-sized (value b) 8)))
(memory-test.raises "a negative length" "shen-jit.pointer-sized: -1" (freeze (shen-jit.pointer-sized (value p) -1)))
(memory-test.raises "a length that is not one" "shen-jit.pointer-sized: a" (freeze (shen-jit.pointer-sized (value p) a)))

\\ Killing one pointer kills that one.
(set second (shen-jit.pointer-sized (value p) 8))
(shen-jit.pointer-kill (value second))
(memory-test.raises "a killed pointer cannot be read" "bytes: 0" (freeze (shen-jit.u8 (value second) 0)))
(memory-test.check "and has no length" 0 (freeze (shen-jit.bytes-length (value second))))
(memory-test.raises "or be sized" "shen-jit.pointer-sized: " (freeze (shen-jit.pointer-sized (value second) 8)))
(memory-test.raises "or go to C" "foreign: " (freeze (sum-x (value second) 1)))
(memory-test.check "the others live on" 1.5 (freeze (point-x (value points) 1)))

(shen-jit.pointer-kill (value points))
(memory-test.raises "before C frees it" "bytes: 0" (freeze (point-x (value points) 0)))
(free-points (value p))

\\ ---------------------------------------------------------------------------
\\ Giving it to C, without a copy: C keeps the address, even during a blocking call.

(define-foreign sum-bytes t "sum_bytes" (pointer int64) --> int64)
(define-foreign fill-bytes t "fill_bytes" (pointer int32 int32) --> void blocking)
(define-foreign pointer-in t "pointer_in" (pointer) --> pointer)

(set shared (memory.alloc 4))
(shen-jit.u8! (value shared) 0 1)
(shen-jit.u8! (value shared) 3 2)
(memory-test.check "C reads it" 3 (freeze (sum-bytes (value shared) 4)))
(memory-test.check "a blocking call writes it" 28
                   (freeze (do (fill-bytes (value shared) 4 7) (sum-bytes (value shared) 4))))
(memory-test.check "and Shen sees that" 7 (freeze (shen-jit.u8 (value shared) 2)))

\\ ---------------------------------------------------------------------------
\\ Pointer fields.

(set fields (memory.alloc 16))
(memory-test.check "a NULL field is []" [] (freeze (shen-jit.bytes->pointer (value fields) 0 thing)))
(shen-jit.pointer! (value fields) 8 (value shared))
(memory-test.check "a field read back" true
                   (freeze (= (shen-jit.pointer-address (shen-jit.bytes->pointer (value fields) 8 thing))
                              (shen-jit.pointer-address (value shared)))))
(memory-test.check "of the kind asked for" thing (freeze (shen-jit.pointer-kind (shen-jit.bytes->pointer (value fields) 8 thing))))
(memory-test.check "what it reads has no length" 0 (freeze (shen-jit.bytes-length (shen-jit.bytes->pointer (value fields) 8 thing))))
(shen-jit.pointer! (value fields) 0 (value shared))
(memory-test.check "C reads the field" true
                   (freeze (= (shen-jit.pointer-address (pointer-in (value fields))) (shen-jit.pointer-address (value shared)))))
(shen-jit.pointer! (value fields) 8 [])
(memory-test.check "[] writes NULL" [] (freeze (shen-jit.bytes->pointer (value fields) 8 thing)))
(memory-test.raises "not a pointer" "shen-jit.pointer!: 1" (freeze (shen-jit.pointer! (value fields) 0 1)))
(memory-test.raises "past the end" "shen-jit.pointer!: 9" (freeze (shen-jit.pointer! (value fields) 9 [])))
(set buffer-field (shen-jit.bytes 8))
(shen-jit.pointer! (value buffer-field) 0 (value shared))
(memory-test.check "a field in a buffer too" true
                   (freeze (= (shen-jit.pointer-address (shen-jit.bytes->pointer (value buffer-field) 0 thing))
                              (shen-jit.pointer-address (value shared)))))

\\ ---------------------------------------------------------------------------
\\ The collector moves the pointer and leaves the memory where it is.

(define memory-test.churn
  0 Acc -> Acc
  N Acc -> (memory-test.churn (- N 1) [N | (if (> N 2000) [] Acc)]))

(set kept (memory.alloc 8))
(shen-jit.u32! (value kept) 0 123456)
(set address (shen-jit.pointer-address (value kept)))
(memory-test.churn 3000000 [])
(memory-test.check "the length survives a collection" 8 (freeze (shen-jit.bytes-length (value kept))))
(memory-test.check "and so does what is in it" 123456 (freeze (shen-jit.u32 (value kept) 0)))
(memory-test.check "at the same address" true (freeze (= (shen-jit.pointer-address (value kept)) (value address))))

\\ ---------------------------------------------------------------------------
\\ Freeing it.

(set gone (memory.alloc 8))
(memory-test.check "free" true (freeze (memory.free (value gone))))
(memory-test.raises "used after it" "bytes: 0" (freeze (shen-jit.u8 (value gone) 0)))
(memory-test.raises "freed twice" "foreign: " (freeze (memory.free (value gone))))
(memory-test.raises "an impossible size" "memory.alloc: " (freeze (memory.alloc -1)))
(memory-test.raises "not a size" "foreign: " (freeze (memory.alloc a)))
(memory.free (value m))
(memory.free (value sums))
(memory.free (value text))
(memory.free (value shared))
(memory.free (value fields))
(memory.free (value kept))
(memory.free (value floats))

(output "~A passed, ~A failed~%" (value memory-test.*passed*) (value memory-test.*failed*))
