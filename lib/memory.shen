\\ Memory outside the Shen heap, in Shen alone over lib/ffi.shen, which has to be loaded first.
\\
\\ A block stays where it is, so C may keep its address, and a blocking call uses it without a
\\ copy. The collector neither copies nor scans it, and does not free it: only memory.free
\\ does, as with malloc in C. A block is a pointer with a length, so what reads a byte buffer
\\ reads it too: shen-jit.u8, shen-jit.f64, shen-jit.copy-bytes and the rest, each checked
\\ against the length. Give it to C as a `pointer`. A saved image holds it dead, and reading one
\\ then raises.
\\
\\   (memory.alloc N)    N bytes, all zero
\\   (memory.free M)     frees M and kills it, so that using it again raises. A copy of M from
\\                       shen-jit.pointer-sized is not killed with it, and must not be used.
\\
\\ For memory from C, see shen-jit.pointer-sized in docs/ffi.md. For memory released once nothing
\\ reaches it, see lib/handle.shen.

(shen.x.namespace memory
  (use shen-jit)
  (externals [define-foreign int64 pointer void])
  (export alloc free)

(shen-jit.library lib ["libc.so.6" "libSystem.dylib" "ucrtbase.dll"])

(define-foreign c-calloc lib "calloc" (int64 int64) --> pointer)
(define-foreign c-free lib "free" (pointer) --> void)

(define alloc
  N -> (let P (c-calloc 1 N)
         (if (empty? P)
             (error "memory.alloc: cannot allocate ~A bytes" N)
             (shen-jit.pointer-sized P N))))

(define free
  M -> (do (c-free M)
           (shen-jit.pointer-kill M)
           true))

)
