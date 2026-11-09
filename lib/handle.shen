\\ Memory that releases itself once nothing reaches it, in Shen alone. It stays out of the image
\\ until asked for, and needs nothing else loaded, though what it wraps comes from a library such
\\ as lib/memory.shen or lib/mmap.shen:
\\
\\   shen-jit eval -l lib/ffi.shen -l lib/memory.shen -l lib/handle.shen -l program.shen
\\
\\ (let H (handle.wrap (memory.alloc 4096) (/. M (memory.free M)))
\\   (shen-jit.f64! H 0 1.5))
\\
\\   (handle.wrap M Release)  a handle on M, a pointer with a length: a new pointer that reads and
\\                            writes the same memory. Once nothing reaches it, (Release M) runs.
\\   (handle.close H)         runs it now, and H then raises when used: true, or false if it ran
\\                            before. A handle on a file should be closed: on Windows, a mapped
\\                            file cannot be deleted.
\\   (handle.sweep)           runs it for each handle that has died, and gives how many.
\\
\\ Release runs in the next call to handle.wrap or handle.sweep after a collection that finds the
\\ handle dead, on whichever thread that is. A program that stops making handles and never calls
\\ handle.sweep leaves the rest to the system when it ends. An error from Release raises in
\\ handle.close and is dropped in handle.sweep, which has no caller to tell.
\\
\\ A copy from shen-jit.pointer-sized keeps its handle alive, unless the handle is closed: it must
\\ not be used after that. Release must not refer to the handle, or the handle will never die. It
\\ may use another handle, which then outlives this one. A handle saved in an image loads dead.
\\
\\ Memory outside the heap brings no collection of its own, so handles count what they hold: past
\\ handle.*limit* bytes, making one collects. That limit is 64 MB, or twice what was left after the
\\ last such collection if that is more.

(shen.x.namespace handle
  (use shen-jit)
  (externals [closed])
  (shadow close release)
  (export close sweep wrap)

(set *held* 0)
(set *limit* 67108864)

(define wrap
  M Release -> (let Record (absvector 2)
                    _ (address-> (address-> Record 0 M) 1 Release)
                    Handle (shen-jit.pointer-guard M Record)
                 (do (set *held* (+ (value *held*) (shen-jit.bytes-length M)))
                     (make-room)
                     Handle)))

(define make-room
  -> (if (> (value *held*) (value *limit*))
         (do (shen-jit.collect)
             (sweep)
             (set *limit* (larger 67108864 (* 2 (value *held*)))))
         (sweep)))

(define larger
  X Y -> (if (> X Y) X Y))

\\ The record stands for the handle: it has no reference back to it, so that the handle can die.
(define release
  Record -> (let Release (<-address Record 1)
              (if (= Release closed)
                  false
                  (let M (<-address Record 0)
                    (do (address-> Record 1 closed)
                        (set *held* (- (value *held*) (shen-jit.bytes-length M)))
                        (Release M)
                        true)))))

(define close
  H -> (let Record (shen-jit.pointer-owner H)
         (if (absvector? Record)
             (do (shen-jit.pointer-kill H)
                 (release Record))
             (error "handle.close: ~S is not a handle" H))))

(define sweep
  -> (release-all (shen-jit.pointers-dead) 0))

(define release-all
  [] N -> N
  [Record | Records] N -> (release-all Records
                                              (if (trap-error (release Record) (/. E true))
                                                  (+ N 1)
                                                  N)))

)
